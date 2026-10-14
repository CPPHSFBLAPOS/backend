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
});

describe('the request', () => {
  it('limits web search to samsclub.com with at most 3 searches', () => {
    const body = buildRequest({ mode: 'search', url: 'https://www.samsclub.com/ip/x/123456' }, HAIKU);
    expect(body.tools).toEqual([
      { type: 'web_search_20250305', name: 'web_search', allowed_domains: ['samsclub.com'], max_uses: 3 },
    ]);
    expect(body.model).toBe(HAIKU);
  });

  it('reads pasted text without searching', () => {
    const body = buildRequest({ mode: 'paste', page_text: 'Water 40 pk $5.48' }, SONNET);
    expect('tools' in body).toBe(false);
    expect(JSON.stringify(body.messages)).toContain('Water 40 pk $5.48');
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
});
