import { describe, expect, it } from 'vitest';
import { mapBase44GiftCard, mapBase44Product, mapBase44Sale, parseCsv } from '../netlify/lib/csv.ts';
import { dollarsToCents, formatCents } from '../netlify/lib/money.ts';
import { lineRoi, percent, totalRoi } from '../netlify/lib/roi.ts';
import { corsHeaders, handle, HttpError } from '../netlify/lib/http.ts';
import { bearerToken } from '../netlify/lib/supabase.ts';
import { escapeHtml } from '../netlify/lib/email.ts';

describe('money', () => {
  it('parses dollars into whole cents without floating point drift', () => {
    expect(dollarsToCents('19.98')).toBe(1998);
    expect(dollarsToCents(0.1 + 0.2)).toBe(30);
    expect(dollarsToCents('$1,299.5')).toBe(129950);
    expect(dollarsToCents('1.005')).toBe(101);
    expect(dollarsToCents(-2.5)).toBe(-250);
    expect(dollarsToCents('abc')).toBeNull();
    expect(dollarsToCents('')).toBeNull();
  });

  it('formats cents for display', () => {
    expect(formatCents(123456)).toBe('$1,234.56');
    expect(formatCents(-5)).toBe('-$0.05');
    expect(formatCents(null)).toBe('—');
  });
});

describe('ROI', () => {
  // 2 packs of 24 at $6.00, sold at $1.00 each.
  const line = { units_per_pack: 24, packs: 2, pack_price_cents: 600, sell_price_cents: 100 };

  it('follows the spec formulas for one line', () => {
    const r = lineRoi(line);
    expect(r.units).toBe(48);
    expect(r.cost_cents).toBe(1200);
    expect(r.revenue_cents).toBe(4800);
    expect(r.profit_cents).toBe(3600);
    expect(r.roi).toBe(3);
    expect(r.margin).toBe(0.75);
    expect(r.break_even).toBe(0.25);
    expect(percent(r.break_even)).toBe('25%');
  });

  it('totals lines before dividing', () => {
    const r = totalRoi([line, { units_per_pack: 10, packs: 1, pack_price_cents: 1000, sell_price_cents: 50 }]);
    expect(r.cost_cents).toBe(2200);
    expect(r.revenue_cents).toBe(5300);
    expect(r.profit_cents).toBe(3100);
    expect(r.roi).toBeCloseTo(3100 / 2200);
  });

  it('has no ROI for a free line', () => {
    expect(lineRoi({ units_per_pack: 1, packs: 1, pack_price_cents: 0, sell_price_cents: 0 }).roi).toBeNull();
  });
});

describe('CSV and the Base44 mapping', () => {
  it('reads quoted fields, commas, quotes and CRLF', () => {
    const rows = parseCsv('﻿Name,Price,Notes\r\n"Chips, Nacho",1.00,"said ""hi"""\r\nWater,0.75,\r\n');
    expect(rows).toEqual([
      { name: 'Chips, Nacho', price: '1.00', notes: 'said "hi"' },
      { name: 'Water', price: '0.75', notes: '' },
    ]);
  });

  it('maps a product row to cents', () => {
    expect(mapBase44Product({ name: 'Water', sku: 'W1', price: '1.00', cost: '0.25', stock: '48' })).toMatchObject({
      name: 'Water',
      sku: 'W1',
      price_cents: 100,
      cost_cents: 25,
      stock: 48,
    });
  });

  it('keeps the old customer field only as a short note', () => {
    const sale = mapBase44Sale(
      { created_date: '2025-10-01T15:00:00Z', product_name: 'Water', quantity: '2', price: '1.00', customer: 'Some Buyer' },
      0,
    );
    expect(sale.total_cents).toBe(200);
    expect(sale.note).toBe('Old customer field: Some Buyer');
    expect(Object.keys(sale)).not.toContain('customer');
  });

  it('maps gift card balances', () => {
    expect(mapBase44GiftCard({ code: 'AB-12', balance: '7.50', type: 'Promo' })).toEqual({
      code: 'AB-12',
      type: 'promo',
      balance_cents: 750,
      note: null,
    });
  });
});

describe('http helpers', () => {
  it('reads a bearer token', () => {
    expect(bearerToken(new Request('http://x', { headers: { authorization: 'Bearer abc.def' } }))).toBe('abc.def');
    expect(bearerToken(new Request('http://x'))).toBeNull();
  });

  it('only sends CORS headers to allowed origins', () => {
    process.env.ALLOWED_ORIGINS = 'http://localhost:5173';
    expect(corsHeaders(new Request('http://x', { headers: { origin: 'http://localhost:5173' } }))).toHaveProperty(
      'access-control-allow-origin',
      'http://localhost:5173',
    );
    expect(corsHeaders(new Request('http://x', { headers: { origin: 'https://evil.example' } }))).toEqual({});
  });

  it('turns thrown HttpErrors into JSON responses', async () => {
    const fn = handle(['POST'], async () => {
      throw new HttpError(429, 'Slow down', 'daily_limit');
    });
    const res = await fn(new Request('http://x', { method: 'POST' }));
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: 'daily_limit', message: 'Slow down' });
    expect((await fn(new Request('http://x', { method: 'GET' }))).status).toBe(405);
  });

  it('escapes email HTML', () => {
    expect(escapeHtml('<b>"Tom" & Jerry\'s</b>')).toBe('&lt;b&gt;&quot;Tom&quot; &amp; Jerry&#39;s&lt;/b&gt;');
  });
});
