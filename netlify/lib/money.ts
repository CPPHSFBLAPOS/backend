// Money is whole cents. These helpers only convert at the edges.

export function dollarsToCents(value: number | string | null | undefined): number | null {
  if (value === null || value === undefined || value === '') return null;
  const text = String(value).replace(/[$,\s]/g, '');
  if (!/^-?\d+(\.\d+)?$/.test(text)) return null;
  const [whole, frac = ''] = text.replace('-', '').split('.');
  const cents = Number(whole) * 100 + Number((frac + '00').slice(0, 2)) + (Number(frac[2] ?? 0) >= 5 ? 1 : 0);
  return text.startsWith('-') ? -cents : cents;
}

export function formatCents(cents: number | null | undefined): string {
  if (cents === null || cents === undefined) return '—';
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(Math.round(cents));
  const dollars = Math.floor(abs / 100).toLocaleString('en-US');
  return `${sign}$${dollars}.${String(abs % 100).padStart(2, '0')}`;
}
