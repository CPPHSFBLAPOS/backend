// Sam's Club lookup through the Claude API with web search limited to
// samsclub.com. Only product text is ever sent: a link, an item name, or
// pasted page text. Never anything about a student.

import { z } from 'zod';
import { dollarsToCents } from './money.ts';

export const HAIKU = 'claude-haiku-5-5';
export const SONNET = 'claude-sonnet-5-5';
const API = 'https://api.anthropic.com/v1';
const VERSION = '2023-06-01';

export function isSamsClubUrl(value: string | null | undefined): boolean {
  if (!value) return false;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return url.protocol === 'https:' && (host === 'samsclub.com' || host.endsWith('.samsclub.com'));
  } catch {
    return false;
  }
}

const priceSchema = z.union([z.number(), z.string()]).nullable().optional();

export const listingSchema = z.object({
  name: z.string().trim().min(1).max(300),
  item_number: z.union([z.string(), z.number()]).nullable().optional(),
  units_per_pack: z.coerce.number().int().positive().max(100000),
  price: priceSchema,
  sale_price: priceSchema,
  url: z.string().trim().nullable().optional(),
});

export type Listing = {
  name: string;
  item_number: string | null;
  units_per_pack: number;
  price_cents: number;
  sale_price_cents: number | null;
  url: string | null;
};

// Pull the JSON object out of Claude's reply (it may wrap it in prose or a
// code fence despite being asked not to).
export function extractJson(text: string): unknown {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(text);
  const candidate = fenced ? fenced[1] : text;
  const start = candidate.indexOf('{');
  const end = candidate.lastIndexOf('}');
  if (start === -1 || end <= start) throw new Error('No JSON in the reply.');
  return JSON.parse(candidate.slice(start, end + 1));
}

export function parseListing(raw: unknown, fallbackUrl?: string | null): Listing {
  const parsed = listingSchema.parse(raw);
  const url = parsed.url || fallbackUrl || null;
  if (url && !isSamsClubUrl(url)) throw new Error('The listing link is not on samsclub.com.');
  const price = dollarsToCents(parsed.price ?? null);
  if (price === null || price < 0) throw new Error('The listing has no price.');
  const sale = dollarsToCents(parsed.sale_price ?? null);
  const itemNumber = parsed.item_number === null || parsed.item_number === undefined ? null : String(parsed.item_number).trim();
  return {
    name: parsed.name,
    item_number: itemNumber || null,
    units_per_pack: parsed.units_per_pack,
    price_cents: price,
    sale_price_cents: sale !== null && sale >= 0 && sale < price ? sale : null,
    url,
  };
}

// The browser reaches this function through a Netlify proxy that gives up
// after 26 s, so every call to Anthropic has a time limit and the function
// answers with JSON before that cutoff.
export const MODELS_TIMEOUT_MS = 3000;
export const LOOKUP_BUDGET_MS = 20000;

// A real answer from the Models API is kept for an hour; a fallback after a
// slow or failed call only for a few minutes, so one hiccup doesn't pin every
// search to the slower, pricier model.
const MODEL_CACHE_MS = 60 * 60 * 1000;
const FALLBACK_CACHE_MS = 5 * 60 * 1000;
let cachedModel: { model: string; at: number; ttl: number } | null = null;

export function resetModelCache() {
  cachedModel = null;
}

// Haiku 5.5 if the Models API says it supports web search, otherwise Sonnet 5.5.
// A slow or failed Models API call falls back to Sonnet rather than eating
// into the lookup's time budget.
export async function pickSearchModel(apiKey: string, fetchImpl: typeof fetch = fetch): Promise<string> {
  if (cachedModel && Date.now() - cachedModel.at < cachedModel.ttl) return cachedModel.model;
  let model = SONNET;
  let ttl = FALLBACK_CACHE_MS;
  try {
    const res = await fetchImpl(`${API}/models/${HAIKU}`, {
      headers: { 'x-api-key': apiKey, 'anthropic-version': VERSION },
      signal: AbortSignal.timeout(MODELS_TIMEOUT_MS),
    });
    if (res.ok) {
      const info = (await res.json()) as {
        capabilities?: { server_tools?: { web_search?: { supported?: boolean } } };
      };
      if (info.capabilities?.server_tools?.web_search?.supported === true) model = HAIKU;
      ttl = MODEL_CACHE_MS;
    }
  } catch {
    // Timed out or failed: fall through to Sonnet.
  }
  cachedModel = { model, at: Date.now(), ttl };
  return model;
}

const SYSTEM = `You read Sam's Club product listings for a high school store that is deciding what to buy.
Reply with only one JSON object and nothing else:
{"name": string, "item_number": string|null, "units_per_pack": integer, "price": number, "sale_price": number|null, "url": string|null}
- price is the regular price in US dollars for one pack, as listed online.
- sale_price is a current instant-savings or sale price for one pack, or null.
- units_per_pack is how many individual items are in one pack (for example 24 for a 24-count case).
- url must be the samsclub.com product page you used, or null.
If you cannot find the listing, reply {"error": "not found"}.`;

export type LookupInput =
  | { mode: 'search'; query?: string | null; url?: string | null }
  | { mode: 'paste'; page_text: string; url?: string | null };

// Room for the model's own reasoning plus the short JSON answer; low effort
// keeps a simple read-and-report job fast.
const MAX_TOKENS = 8000;
const OUTPUT_CONFIG = { effort: 'low' } as const;

export function buildRequest(input: LookupInput, model: string) {
  if (input.mode === 'paste') {
    return {
      model: HAIKU,
      max_tokens: MAX_TOKENS,
      output_config: OUTPUT_CONFIG,
      system: SYSTEM,
      messages: [
        {
          role: 'user',
          content: `Here is the text of a Sam's Club product page${input.url ? ` (${input.url})` : ''}. Read it; do not search.\n\n${input.page_text.slice(0, 30000)}`,
        },
      ],
    };
  }
  const ask = input.url
    ? `Look up this Sam's Club listing and report it: ${input.url}`
    : `Find the Sam's Club listing for: ${input.query}`;
  return {
    model,
    max_tokens: MAX_TOKENS,
    output_config: OUTPUT_CONFIG,
    system: SYSTEM,
    tools: [{ type: 'web_search_20250305', name: 'web_search', allowed_domains: ['samsclub.com'], max_uses: 2 }],
    messages: [{ role: 'user', content: ask }],
  };
}

type ContentBlock = { type: string; text?: string };
type MessageResponse = { content: ContentBlock[]; stop_reason: string; model: string };

function timeoutError(message: string): Error {
  const err = new Error(message);
  err.name = 'TimeoutError';
  return err;
}

// Sends the request and returns the reply's text. Each Messages API call
// (including each pause_turn continuation) is aborted at `deadline`, a
// Date.now()-style timestamp; a timeout rejects with a TimeoutError or
// AbortError.
export async function callClaude(
  apiKey: string,
  body: ReturnType<typeof buildRequest>,
  fetchImpl: typeof fetch = fetch,
  deadline: number = Date.now() + LOOKUP_BUDGET_MS,
): Promise<{ text: string; model: string }> {
  const messages: Array<{ role: string; content: unknown }> = [...body.messages];
  // A long search turn can pause; send it back to continue (a few times at most).
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0 && Date.now() >= deadline) {
      throw timeoutError('The search took too long. Try pasting the page text instead.');
    }
    const res = await fetchImpl(`${API}/messages`, {
      method: 'POST',
      headers: { 'x-api-key': apiKey, 'anthropic-version': VERSION, 'content-type': 'application/json' },
      body: JSON.stringify({ ...body, messages }),
      signal: AbortSignal.timeout(Math.max(1000, deadline - Date.now())),
    });
    if (!res.ok) {
      const detail = await res.text();
      throw new Error(`Claude API ${res.status}: ${detail.slice(0, 300)}`);
    }
    const data = (await res.json()) as MessageResponse;
    if (data.stop_reason === 'pause_turn') {
      messages.push({ role: 'assistant', content: data.content });
      continue;
    }
    if (data.stop_reason === 'max_tokens') throw new Error('Claude ran out of room before answering.');
    if (data.stop_reason === 'refusal') throw new Error('Claude declined the lookup.');
    const text = data.content
      .filter((b) => b.type === 'text' && typeof b.text === 'string')
      .map((b) => b.text)
      .join('');
    return { text, model: data.model };
  }
  throw new Error('The search took too long. Try pasting the page text instead.');
}
