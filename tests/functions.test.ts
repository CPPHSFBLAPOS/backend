import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// A fake member client: rpc() answers from a table of canned results.
const rpcResults: Record<string, unknown> = {};
const rpcCalls: Array<[string, unknown]> = [];
const fakeClient = {
  rpc: vi.fn(async (fn: string, args?: unknown) => {
    rpcCalls.push([fn, args]);
    const value = rpcResults[fn];
    if (value instanceof Error) return { data: null, error: { message: value.message, code: 'P0001' } };
    return { data: value, error: null };
  }),
  storage: { from: () => ({ upload: vi.fn(async () => ({ error: null })) }) },
};

vi.mock('../netlify/lib/supabase.ts', async (importOriginal) => {
  const real = await importOriginal<typeof import('../netlify/lib/supabase.ts')>();
  return {
    ...real,
    getCaller: vi.fn(async (_req: Request, permission?: string) => {
      const permissions = ['preauth_view'];
      if (permission && !permissions.includes(permission)) {
        const { HttpError } = await import('../netlify/lib/http.ts');
        throw new HttpError(403, 'nope', 'forbidden');
      }
      return { client: fakeClient, member: { id: 'm1', permissions }, token: 't' };
    }),
  };
});

const { default: samsLookup } = await import('../netlify/functions/sams-lookup.ts');
const { default: notify } = await import('../netlify/functions/notify.ts');
const { default: preauthPdf } = await import('../netlify/functions/preauth-pdf.ts');
const { resetModelCache } = await import('../netlify/lib/sams.ts');

const post = (body: unknown) =>
  new Request('http://localhost/.netlify/functions/x', {
    method: 'POST',
    headers: { authorization: 'Bearer t', 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

const listingReply = {
  content: [
    {
      type: 'text',
      text: '{"name": "Water 40 pk", "item_number": "980012345", "units_per_pack": 40, "price": 5.48, "sale_price": null, "url": "https://www.samsclub.com/ip/water/980012345"}',
    },
  ],
  stop_reason: 'end_turn',
  model: 'claude-haiku-5-5',
};

beforeEach(() => {
  for (const k of Object.keys(rpcResults)) delete rpcResults[k];
  rpcCalls.length = 0;
  resetModelCache();
  process.env.ANTHROPIC_API_KEY = 'test-key';
  delete process.env.RESEND_API_KEY;
});
afterEach(() => vi.unstubAllGlobals());

describe('sams-lookup', () => {
  it('returns a cached listing without calling Claude', async () => {
    rpcResults.begin_sams_lookup = { ok: true, cached: true, item: { id: 'v1' } };
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const res = await samsLookup(post({ mode: 'search', url: 'https://www.samsclub.com/ip/water/980012345' }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ item: { id: 'v1' }, cached: true });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('stops at the daily limit', async () => {
    rpcResults.begin_sams_lookup = { ok: false, error: 'daily_limit', message: 'All 30 used' };
    const res = await samsLookup(post({ mode: 'search', query: 'water' }));
    expect(res.status).toBe(429);
    expect(((await res.json()) as { message: string }).message).toBe('All 30 used');
  });

  it('rejects links outside samsclub.com before spending a lookup', async () => {
    const res = await samsLookup(post({ mode: 'search', url: 'https://www.walmart.com/ip/1' }));
    expect(res.status).toBe(400);
    expect(rpcCalls).toHaveLength(0);
  });

  it('searches, validates and saves the listing', async () => {
    rpcResults.begin_sams_lookup = { ok: true, cached: false, remaining: 29 };
    rpcResults.save_vendor_item = { id: 'v2', name: 'Water 40 pk' };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ capabilities: { server_tools: { web_search: { supported: true } } } })))
      .mockResolvedValueOnce(new Response(JSON.stringify(listingReply)));
    vi.stubGlobal('fetch', fetchMock);

    const res = await samsLookup(post({ mode: 'search', query: 'member\'s mark water 40 pack' }));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ item: { id: 'v2' }, cached: false, remaining: 29 });

    expect(rpcCalls[0]).toEqual(['begin_sams_lookup', { p_query: "member's mark water 40 pack", p_url: null }]);
    const sent = JSON.parse(fetchMock.mock.calls[1][1].body);
    expect(sent.tools[0]).toMatchObject({ allowed_domains: ['samsclub.com'], max_uses: 2 });
    expect(sent).toMatchObject({ max_tokens: 8000, output_config: { effort: 'low' } });
    const saved = rpcCalls.find(([fn]) => fn === 'save_vendor_item')?.[1] as { p: Record<string, unknown> };
    expect(saved.p).toMatchObject({ price_cents: 548, units_per_pack: 40, item_number: '980012345', source: 'search' });
  });

  it('refuses a listing that points off samsclub.com', async () => {
    rpcResults.begin_sams_lookup = { ok: true, cached: false, remaining: 29 };
    const bad = structuredClone(listingReply);
    bad.content[0].text = bad.content[0].text.replace('https://www.samsclub.com', 'https://www.example.com');
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValueOnce(new Response('{}'))
        .mockResolvedValueOnce(new Response(JSON.stringify(bad))),
    );
    const res = await samsLookup(post({ mode: 'search', query: 'water' }));
    expect(res.status).toBe(502);
    expect(rpcCalls.map(([fn]) => fn)).not.toContain('save_vendor_item');
  });

  it('answers 504 with JSON when Claude takes too long', async () => {
    rpcResults.begin_sams_lookup = { ok: true, cached: false, remaining: 29 };
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValueOnce(new Response('{}'))
        .mockRejectedValueOnce(new DOMException('The operation was aborted due to timeout', 'TimeoutError')),
    );
    const res = await samsLookup(post({ mode: 'search', query: 'water' }));
    expect(res.status).toBe(504);
    expect(await res.json()).toMatchObject({ error: 'lookup_timeout' });
    expect(rpcCalls.map(([fn]) => fn)).not.toContain('save_vendor_item');
  });

  it('answers 502 when Claude runs out of room or declines', async () => {
    rpcResults.begin_sams_lookup = { ok: true, cached: false, remaining: 29 };
    for (const stop_reason of ['max_tokens', 'refusal']) {
      resetModelCache();
      vi.stubGlobal(
        'fetch',
        vi
          .fn()
          .mockResolvedValueOnce(new Response('{}'))
          .mockResolvedValueOnce(new Response(JSON.stringify({ ...listingReply, stop_reason }))),
      );
      const res = await samsLookup(post({ mode: 'search', query: 'water' }));
      expect(res.status).toBe(502);
      expect(await res.json()).toMatchObject({ error: 'lookup_failed' });
    }
    expect(rpcCalls.map(([fn]) => fn)).not.toContain('save_vendor_item');
  });
});

describe('sams-lookup paste mode', () => {
  const link = 'https://www.samsclub.com/ip/water/980012345';
  const page = "Member's Mark Purified Water 40 pk $5.48 Item 980012345";

  it('uses begin_sams_paste with the link, reads the text and saves the listing', async () => {
    rpcResults.begin_sams_paste = { ok: true, cached: false, remaining: 9 };
    rpcResults.save_vendor_item = { id: 'v3', name: 'Water 40 pk' };
    const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(listingReply)));
    vi.stubGlobal('fetch', fetchMock);

    const res = await samsLookup(post({ mode: 'paste', page_text: page, url: link }));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ item: { id: 'v3' }, cached: false, remaining: 9 });

    expect(rpcCalls[0]).toEqual(['begin_sams_paste', { p_url: link }]);
    expect(rpcCalls.map(([fn]) => fn)).not.toContain('begin_sams_lookup');
    // One call: no Models API lookup and no web search for pasted text.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const sent = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(sent.tools).toBeUndefined();
    expect(sent).toMatchObject({ max_tokens: 8000, output_config: { effort: 'low' } });
    expect(JSON.stringify(sent.messages)).toContain(page);
    const saved = rpcCalls.find(([fn]) => fn === 'save_vendor_item')?.[1] as { p: Record<string, unknown> };
    expect(saved.p).toMatchObject({ price_cents: 548, source: 'paste', query: null });
  });

  it('passes a null link when none was given', async () => {
    rpcResults.begin_sams_paste = { ok: true, cached: false, remaining: 9 };
    rpcResults.save_vendor_item = { id: 'v4' };
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(JSON.stringify(listingReply))));
    const res = await samsLookup(post({ mode: 'paste', page_text: page }));
    expect(res.status).toBe(200);
    expect(rpcCalls[0]).toEqual(['begin_sams_paste', { p_url: null }]);
  });

  it('returns a recently checked listing without calling Claude', async () => {
    rpcResults.begin_sams_paste = { ok: true, cached: true, item: { id: 'v1' } };
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const res = await samsLookup(post({ mode: 'paste', page_text: page, url: link }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ item: { id: 'v1' }, cached: true });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('stops at the paste daily limit', async () => {
    rpcResults.begin_sams_paste = { ok: false, error: 'daily_limit', message: 'All 20 pastes used' };
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const res = await samsLookup(post({ mode: 'paste', page_text: page }));
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: 'daily_limit', message: 'All 20 pastes used' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('needs page text before spending a paste', async () => {
    const res = await samsLookup(post({ mode: 'paste', page_text: '   ', url: link }));
    expect(res.status).toBe(400);
    expect(rpcCalls).toHaveLength(0);
  });
});

describe('notify', () => {
  const contacts = {
    id: 'p1',
    number: 7,
    status: 'awaiting_advisor',
    student_name: 'Taylor',
    grand_total_cents: 1200,
    reject_comment: null,
    requester_email: 'taylor@example.com',
    advisor_emails: ['advisor@example.com'],
  };

  it('emails the Advisor when a form is submitted', async () => {
    rpcResults.preauth_contacts = contacts;
    const res = await notify(post({ preauth_id: 'p1', event: 'submitted' }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, sent: false, recipients: 1 });
  });

  it('refuses an event that does not match the current status', async () => {
    rpcResults.preauth_contacts = { ...contacts, status: 'draft' };
    const res = await notify(post({ preauth_id: 'p1', event: 'approved' }));
    expect(res.status).toBe(409);
  });
});

describe('preauth-pdf', () => {
  it('draws, stores and records the PDF', async () => {
    rpcResults.get_preauth = {
      number: 3,
      status: 'approved',
      student_name: 'Taylor Treasurer (test)',
      grade: 11,
      fbla_role: 'Treasurer',
      request_date: '2026-10-14',
      vendor: "Sam's Club",
      website: 'https://www.samsclub.com',
      purposes: ['fundraiser'],
      purpose_other: null,
      justification: 'Water sells out every week.',
      shipping_cents: 0,
      lines_total_cents: 1200,
      grand_total_cents: 1200,
      approved_total_cents: 1200,
      purchase_date: null,
      receipt_due_date: null,
      receipts_total_cents: 0,
      reimbursed_cents: null,
      reimbursed_to: null,
      notes: null,
      hash: 'abc',
      lines: [],
      signatures: [],
    };
    rpcResults.set_preauth_pdf = null;
    rpcResults.preauth_contacts = { number: 3, signer_emails: ['a@example.com'] };
    const res = await preauthPdf(post({ preauth_id: 'p3', stage: 'approved' }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { path: string };
    expect(body.path).toMatch(/^p3\/preauth-3-approved-\d+\.pdf$/);
    expect(rpcCalls.map(([fn]) => fn)).toContain('set_preauth_pdf');
  });
});
