// Import Base44's CSV exports into the new store.
//
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
//     npm run import:base44 -- --products products.csv --sales sales.csv --gift-cards cards.csv
//
// Products become products with Opening balance movements (skipped when the
// SKU already exists), sales go into legacy_sales, and gift cards that still
// have money come over as Import transactions dated today. Everything goes
// through the same RPCs the app uses, so every row is logged.

import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { mapBase44GiftCard, mapBase44Product, mapBase44Sale, parseCsv } from '../netlify/lib/csv.ts';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}

function chunks<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.');
  process.exit(1);
}
const supabase = createClient(url, key, {
  auth: { persistSession: false },
  global: { headers: { 'x-fbla-device': 'import-script' } },
});

async function call(fn: string, rows: unknown[]) {
  let added = 0;
  let skipped = 0;
  for (const batch of chunks(rows, 500)) {
    const { data, error } = await supabase.rpc(fn, { p_rows: batch });
    if (error) throw new Error(`${fn}: ${error.message}`);
    added += data.added;
    skipped += data.skipped;
  }
  console.log(`${fn}: ${added} added, ${skipped} skipped`);
}

const productsFile = arg('products');
const salesFile = arg('sales');
const cardsFile = arg('gift-cards');
if (!productsFile && !salesFile && !cardsFile) {
  console.error('Pass --products, --sales and/or --gift-cards with CSV paths.');
  process.exit(1);
}

if (productsFile) {
  const rows = parseCsv(readFileSync(productsFile, 'utf8')).map(mapBase44Product).filter((r) => r.name);
  await call('import_products', rows);
}
if (salesFile) {
  const rows = parseCsv(readFileSync(salesFile, 'utf8'))
    .map(mapBase44Sale)
    .filter((r) => r.sold_at && r.total_cents !== null);
  await call('import_legacy_sales', rows);
}
if (cardsFile) {
  const rows = parseCsv(readFileSync(cardsFile, 'utf8')).map(mapBase44GiftCard).filter((r) => r.balance_cents > 0);
  await call('import_gift_cards', rows);
}
