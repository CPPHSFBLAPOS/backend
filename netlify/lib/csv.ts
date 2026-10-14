// A small RFC 4180 CSV reader and the Base44 export mapping used by the
// import script. The frontend's Inventory import uses the same rules.

import { dollarsToCents } from './money.ts';

export function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  const src = text.replace(/^\uFEFF/, '');
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"' && src[i + 1] === '"') {
        field += '"';
        i++;
      } else if (ch === '"') {
        quoted = false;
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ',') {
      row.push(field);
      field = '';
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += ch;
    }
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  const nonEmpty = rows.filter((r) => r.some((c) => c.trim() !== ''));
  if (nonEmpty.length === 0) return [];
  const headers = nonEmpty[0].map((h) => h.trim().toLowerCase().replace(/\s+/g, '_'));
  return nonEmpty.slice(1).map((r) => Object.fromEntries(headers.map((h, i) => [h, (r[i] ?? '').trim()])));
}

function pick(row: Record<string, string>, ...names: string[]): string {
  for (const n of names) {
    if (row[n] !== undefined && row[n] !== '') return row[n];
  }
  return '';
}

// Base44 product export: name, sku, category, price, cost, stock, image_url, description
export function mapBase44Product(row: Record<string, string>) {
  return {
    name: pick(row, 'name', 'product_name', 'title'),
    sku: pick(row, 'sku') || null,
    category: pick(row, 'category') || null,
    price_cents: dollarsToCents(pick(row, 'price', 'sell_price')) ?? 0,
    cost_cents: dollarsToCents(pick(row, 'cost', 'unit_cost')),
    stock: Math.max(0, Math.round(Number(pick(row, 'stock', 'quantity', 'qty') || 0))),
    image_url: pick(row, 'image_url', 'image') || null,
    description: pick(row, 'description') || null,
  };
}

// Base44 sales export. The old customer field becomes a note, never a name
// column, and is cut short.
export function mapBase44Sale(row: Record<string, string>, index: number) {
  const qty = Math.max(1, Math.round(Number(pick(row, 'quantity', 'qty') || 1)));
  const unit = dollarsToCents(pick(row, 'unit_price', 'price'));
  const total = dollarsToCents(pick(row, 'total', 'amount', 'total_price')) ?? (unit !== null ? unit * qty : null);
  const when = pick(row, 'sold_at', 'created_date', 'date', 'created_at', 'timestamp');
  const customer = pick(row, 'customer', 'customer_name', 'buyer');
  const note = [pick(row, 'note', 'notes'), customer ? `Old customer field: ${customer.slice(0, 40)}` : '']
    .filter(Boolean)
    .join(' | ');
  return {
    sold_at: when ? new Date(when).toISOString() : null,
    product_name: pick(row, 'product_name', 'product', 'item', 'name') || null,
    sku: pick(row, 'sku') || null,
    qty,
    unit_price_cents: unit,
    total_cents: total,
    note: note || null,
    source_key: pick(row, 'id') || `${when}|${pick(row, 'product_name', 'product', 'item', 'name')}|${index}`,
  };
}

export function mapBase44GiftCard(row: Record<string, string>) {
  return {
    code: pick(row, 'code', 'card_code', 'number') || null,
    type: /promo/i.test(pick(row, 'type')) ? 'promo' : 'paid',
    balance_cents: dollarsToCents(pick(row, 'balance', 'remaining_balance', 'amount')) ?? 0,
    note: pick(row, 'note', 'notes') || null,
  };
}
