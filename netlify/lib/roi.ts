// ROI on every pre-auth line, from the spec's "ROI on every line" section.
// The frontend has the same math in src/lib/roi.ts; both are unit-tested.

export type RoiLine = {
  units_per_pack: number;
  packs: number;
  pack_price_cents: number;
  sell_price_cents: number;
};

export type Roi = {
  units: number;
  cost_cents: number;
  revenue_cents: number;
  profit_cents: number;
  roi: number | null; // profit / cost
  margin: number | null; // profit / revenue
  break_even: number | null; // cost / revenue: share that must sell to get the money back
};

export function lineRoi(line: RoiLine): Roi {
  const units = line.packs * line.units_per_pack;
  const cost = line.packs * line.pack_price_cents;
  const revenue = units * line.sell_price_cents;
  const profit = revenue - cost;
  return {
    units,
    cost_cents: cost,
    revenue_cents: revenue,
    profit_cents: profit,
    roi: cost > 0 ? profit / cost : null,
    margin: revenue > 0 ? profit / revenue : null,
    break_even: revenue > 0 ? cost / revenue : null,
  };
}

export function totalRoi(lines: RoiLine[]): Roi {
  const sum = lines.map(lineRoi).reduce(
    (a, r) => ({
      units: a.units + r.units,
      cost_cents: a.cost_cents + r.cost_cents,
      revenue_cents: a.revenue_cents + r.revenue_cents,
    }),
    { units: 0, cost_cents: 0, revenue_cents: 0 },
  );
  const profit = sum.revenue_cents - sum.cost_cents;
  return {
    ...sum,
    profit_cents: profit,
    roi: sum.cost_cents > 0 ? profit / sum.cost_cents : null,
    margin: sum.revenue_cents > 0 ? profit / sum.revenue_cents : null,
    break_even: sum.revenue_cents > 0 ? sum.cost_cents / sum.revenue_cents : null,
  };
}

export function percent(value: number | null, digits = 0): string {
  if (value === null || !Number.isFinite(value)) return '—';
  return `${(value * 100).toFixed(digits)}%`;
}
