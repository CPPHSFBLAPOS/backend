import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  HAIKU,
  SONNET,
  buildRequest,
  callClaude,
  extractJson,
  isSamsClubUrl,
  parseListing,
  pickSearchModel,
  resetModelCache,
} from '../netlify/lib/sams.ts';

const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

describe('isSamsClubUrl', () => {
  it('accepts https samsclub.com pages only', () => {
    expect(isSamsClubUrl('https://www.samsclub.com/ip/Water/13314')).toBe(true);
    expect(isSamsClubUrl('https://samsclub.com/p/x')).toBe(true);
    expect(isSamsClubUrl('http://www.samsclub.com/ip/x')).toBe(false);
    expect(isSamsClubUrl('https://samsclub.com.evil.example/ip')).toBe(false);
    expect(isSamsClubUrl('https://notsamsclub.com/')).toBe(false);
    expect(isSamsClubUrl('nonsense')).toBe(false);
  });
});

describe('parsing the reply', () => {
  it('pulls JSON out of prose or a code fence', () => {
    expect(extractJson('Here you go:\n```json\n{"a": 1}\n```')).toEqual({ a: 1 });
    expect(extractJson('Result {"a": {"b": 2}} done')).toEqual({ a: { b: 2 } });
    expect(() => extractJson('no json here')).toThrow();
  });

  it('validates and converts a listing to cents', () => {
    expect(
      parseListing({
        name: 'Member\'s Mark Purified Water, 16.9 fl oz, 40 pk',
        item_number: 980012345,
        units_per_pack: '40',
        price: 5.48,
        sale_price: 4.98,
        url: 'https://www.samsclub.com/ip/water/980012345',
      }),
    ).toEqual({
      name: 'Member\'s Mark Purified Water, 16.9 fl oz, 40 pk',
      item_number: '980012345',
      units_per_pack: 40,
      price_cents: 548,
      sale_price_cents: 498,
      url: 'https://www.samsclub.com/ip/water/980012345',
    });
  });

  it('rejects a URL outside samsclub.com', () => {
    expect(() =>
      parseListing({ name: 'x', units_per_pack: 1, price: 1, url: 'https://www.walmart.com/ip/1' }),
    ).toThrow(/samsclub/);
  });

  it('rejects a listing without a price or pack size', () => {
    expect(() => parseListing({ name: 'x', units_per_pack: 1, price: null })).toThrow();
    expect(() => parseListing({ name: 'x', units_per_pack: 0, price: 1 })).toThrow();
  });

  it('ignores a "sale" price that is not lower', () => {
    expect(parseListing({ name: 'x', units_per_pack: 2, price: 3, sale_price: 3 }).sale_price_cents).toBeNull();
  });
});

describe('model choice', () => {
  beforeEach(() => resetModelCache());

  it('uses Haiku when the Models API reports web search support', async () => {
    const fetchMock = vi.fn().mockResolvedValue(ok({ id: HAIKU, capabilities: { server_tools: { web_search: { supported: true } } } }));
    expect(await pickSearchModel('k', fetchMock)).toBe(HAIKU);
    expect(fetchMock.mock.calls[0][0]).toContain(`/v1/models/${HAIKU}`);
  });

  it('falls back to Sonnet otherwise', async () => {
    expect(await pickSearchModel('k', vi.fn().mockResolvedValue(ok({ id: HAIKU })))).toBe(SONNET);
    resetModelCache();
    expect(await pickSearchModel('k', vi.fn().mockRejectedValue(new Error('down')))).toBe(SONNET);
  });

  it('gives the Models API 3 seconds and falls back to Sonnet when it times out', async () => {
    const timeout = vi.spyOn(AbortSignal, 'timeout');
    const fetchMock = vi.fn().mockRejectedValue(new DOMException('The operation was aborted due to timeout', 'TimeoutError'));
    expect(await pickSearchModel('k', fetchMock)).toBe(SONNET);
    expect(timeout).toHaveBeenCalledWith(3000);
    expect(fetchMock.mock.calls[0][1].signal).toBeInstanceOf(AbortSignal);
    timeout.mockRestore();
  });

  it('keeps a fallback after a failed check for minutes, not an hour', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    try {
      vi.setSystemTime(new Date('2026-10-14T12:00:00Z'));
      expect(await pickSearchModel('k', vi.fn().mockRejectedValue(new Error('slow')))).toBe(SONNET);
      vi.setSystemTime(new Date('2026-10-14T12:06:00Z'));
      const supported = vi.fn().mockResolvedValue(ok({ id: HAIKU, capabilities: { server_tools: { web_search: { supported: true } } } }));
      expect(await pickSearchModel('k', supported)).toBe(HAIKU);
      vi.setSystemTime(new Date('2026-10-14T12:50:00Z'));
      const unused = vi.fn();
      expect(await pickSearchModel('k', unused)).toBe(HAIKU);
      expect(unused).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe('the request', () => {
  it('limits web search to samsclub.com with at most 2 searches', () => {
    const body = buildRequest({ mode: 'search', url: 'https://www.samsclub.com/ip/x/123456' }, HAIKU);
    expect(body.tools).toEqual([
      { type: 'web_search_20250305', name: 'web_search', allowed_domains: ['samsclub.com'], max_uses: 2 },
    ]);
    expect(body.model).toBe(HAIKU);
    expect(body.max_tokens).toBe(8000);
    expect(body.output_config).toEqual({ effort: 'low' });
    expect('thinking' in body).toBe(false);
  });

  it('reads pasted text without searching', () => {
    const body = buildRequest({ mode: 'paste', page_text: 'Water 40 pk $5.48' }, SONNET);
    expect('tools' in body).toBe(false);
    expect(JSON.stringify(body.messages)).toContain('Water 40 pk $5.48');
    expect(body.max_tokens).toBe(8000);
    expect(body.output_config).toEqual({ effort: 'low' });
    expect('thinking' in body).toBe(false);
  });

  it('continues a paused turn and joins the text blocks', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(ok({ content: [{ type: 'server_tool_use' }], stop_reason: 'pause_turn', model: HAIKU }))
      .mockResolvedValueOnce(
        ok({ content: [{ type: 'text', text: '{"name":' }, { type: 'text', text: '"x"}' }], stop_reason: 'end_turn', model: HAIKU }),
      );
    const out = await callClaude('k', buildRequest({ mode: 'search', query: 'water' }, HAIKU), fetchMock);
    expect(out.text).toBe('{"name":"x"}');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const second = JSON.parse(fetchMock.mock.calls[1][1].body);
    expect(second.messages).toHaveLength(2);
  });

  it('gives each call only the time left before the deadline, including continuations', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    const timeout = vi.spyOn(AbortSignal, 'timeout');
    try {
      const start = new Date('2026-10-14T12:00:00Z').getTime();
      vi.setSystemTime(start);
      const fetchMock = vi
        .fn()
        .mockImplementationOnce(async () => {
          vi.setSystemTime(start + 3000); // the first call took 3 s
          return ok({ content: [{ type: 'server_tool_use' }], stop_reason: 'pause_turn', model: HAIKU });
        })
        .mockResolvedValueOnce(ok({ content: [{ type: 'text', text: '{}' }], stop_reason: 'end_turn', model: HAIKU }));
      await callClaude('k', buildRequest({ mode: 'search', query: 'water' }, HAIKU), fetchMock, start + 5000);
      expect(timeout.mock.calls.map((c) => c[0])).toEqual([5000, 2000]);
      expect(fetchMock.mock.calls[0][1].signal).toBeInstanceOf(AbortSignal);
      expect(fetchMock.mock.calls[1][1].signal).toBeInstanceOf(AbortSignal);
    } finally {
      timeout.mockRestore();
      vi.useRealTimers();
    }
  });

  it('rejects a reply cut off at max_tokens', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      ok({ content: [{ type: 'text', text: '{"name": "Wat' }], stop_reason: 'max_tokens', model: HAIKU }),
    );
    await expect(callClaude('k', buildRequest({ mode: 'search', query: 'water' }, HAIKU), fetchMock)).rejects.toThrow(
      'Claude ran out of room before answering.',
    );
  });

  it('rejects a refusal', async () => {
    const fetchMock = vi.fn().mockResolvedValue(ok({ content: [], stop_reason: 'refusal', model: HAIKU }));
    await expect(
      callClaude('k', buildRequest({ mode: 'paste', page_text: 'Water 40 pk $5.48' }, HAIKU), fetchMock),
    ).rejects.toThrow('Claude declined the lookup.');
  });

  it('aborts a call that runs past the deadline', async () => {
    // Never answers; only the abort signal ends it.
    const hang = vi.fn(
      (_url: string | URL | Request, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(init.signal?.reason));
        }),
    );
    const started = Date.now();
    const err = await callClaude(
      'k',
      buildRequest({ mode: 'search', query: 'water' }, HAIKU),
      hang as unknown as typeof fetch,
      Date.now() + 10,
    ).catch((e: unknown) => e);
    expect(['TimeoutError', 'AbortError']).toContain((err as Error).name);
    // The 1 s floor applies, not the 20 s default.
    expect(Date.now() - started).toBeLessThan(5000);
  });

  it('stops continuing a paused turn once the deadline has passed', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(ok({ content: [{ type: 'server_tool_use' }], stop_reason: 'pause_turn', model: HAIKU }));
    const err = await callClaude(
      'k',
      buildRequest({ mode: 'search', query: 'water' }, HAIKU),
      fetchMock,
      Date.now() - 1,
    ).catch((e: unknown) => e);
    expect((err as Error).name).toBe('TimeoutError');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
