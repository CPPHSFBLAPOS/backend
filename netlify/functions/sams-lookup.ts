import { HttpError, handle, json, readJson, requireEnv } from '../lib/http.ts';
import {
  LOOKUP_BUDGET_MS,
  buildRequest,
  callClaude,
  extractJson,
  isSamsClubUrl,
  parseListing,
  pickSearchModel,
  type LookupInput,
} from '../lib/sams.ts';
import { getCaller, rpc } from '../lib/supabase.ts';

type Body = { mode?: 'search' | 'paste'; query?: string; url?: string; page_text?: string };
type Begin = { ok: boolean; cached?: boolean; item?: unknown; remaining?: number; error?: string; message?: string };

function isTimeout(err: unknown): boolean {
  const name = (err as { name?: unknown } | null)?.name;
  return name === 'AbortError' || name === 'TimeoutError';
}

// POST { mode: 'search', url? , query? } or { mode: 'paste', page_text, url? }
// Takes a samsclub.com link or an item name, reuses a listing checked within
// the cache window, otherwise asks Claude (web search on samsclub.com only),
// validates the JSON and saves the listing to vendor_items.
// The browser's request passes through a Netlify proxy that gives up after
// 26 s, so the Claude call has to finish (or give up) within LOOKUP_BUDGET_MS
// of the request arriving.
export default handle(['POST'], async (req) => {
  const deadline = Date.now() + LOOKUP_BUDGET_MS;
  const { client } = await getCaller(req, 'preauth_view');
  const body = await readJson<Body>(req);
  const mode = body.mode === 'paste' ? 'paste' : 'search';
  const url = body.url?.trim() || null;
  const query = body.query?.trim() || null;

  if (url && !isSamsClubUrl(url)) throw new HttpError(400, 'Only samsclub.com links can be looked up.', 'bad_url');
  if (mode === 'search' && !url && !query) throw new HttpError(400, 'Give a samsclub.com link or an item name.', 'bad_request');
  if (mode === 'paste' && !body.page_text?.trim()) throw new HttpError(400, 'Paste the text of the product page.', 'bad_request');

  // The quota and the cache live in Postgres, checked with the member's token.
  // Search and paste have separate daily caps; both answer in the same shape.
  const begin =
    mode === 'paste'
      ? await rpc<Begin>(client, 'begin_sams_paste', { p_url: url ?? null })
      : await rpc<Begin>(client, 'begin_sams_lookup', { p_query: query, p_url: url });
  if (begin.ok && begin.cached) return json(req, 200, { item: begin.item, cached: true });
  if (!begin.ok) throw new HttpError(429, begin.message ?? 'Daily lookup limit reached.', begin.error ?? 'daily_limit');

  const apiKey = requireEnv('ANTHROPIC_API_KEY');
  const model = mode === 'search' ? await pickSearchModel(apiKey) : undefined;
  const input: LookupInput =
    mode === 'paste' ? { mode, page_text: body.page_text ?? '', url } : { mode, query, url };

  let listing;
  let usedModel: string;
  try {
    const reply = await callClaude(apiKey, buildRequest(input, model ?? ''), fetch, deadline);
    usedModel = reply.model;
    const raw = extractJson(reply.text) as Record<string, unknown>;
    if (raw && typeof raw === 'object' && 'error' in raw) {
      throw new HttpError(404, 'Claude could not find that listing. Paste the page text or type the item in.', 'not_found');
    }
    listing = parseListing(raw, url);
  } catch (err) {
    if (err instanceof HttpError) throw err;
    if (isTimeout(err)) {
      console.error('sams-lookup timed out', err);
      throw new HttpError(504, 'The lookup took too long. Paste the page text or type the item in.', 'lookup_timeout');
    }
    console.error('sams-lookup failed', err);
    throw new HttpError(502, 'The lookup did not return a usable listing. Paste the page text or type the item in.', 'lookup_failed');
  }

  const item = await rpc(client, 'save_vendor_item', {
    p: { ...listing, query: mode === 'paste' ? null : query, source: mode },
  });
  return json(req, 200, { item, cached: false, model: usedModel, remaining: begin.remaining });
});
