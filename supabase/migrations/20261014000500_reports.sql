-- Phase 5: Reports
-- Every number lives here so the math is tested once. Revenue counts
-- completed sales minus refunds, leaves out Training and Pending sales and
-- gift card loads, takes profit from the cost saved on each sale line, and
-- figures margin on known-cost items only. Promo card spending is cost of
-- goods with $0 revenue.

-------------------------------------------------------------------------------
-- Facts
-------------------------------------------------------------------------------

-- One row per product sale line and per refund line in the date range
-- (local dates). Refund rows are negative and dated when the money went back.
create function private.revenue_facts(p_from date, p_to date)
returns table (
  d date,
  sale_id uuid,
  product_id uuid,
  cashier_id uuid,
  sale_type public.sale_type,
  kind text,
  qty integer,
  gross_cents numeric,
  revenue_cents numeric,
  cogs_cents numeric,
  known_cost boolean,
  promo_cost_cents numeric,
  list_value_cents numeric
)
language sql stable
as $$
  select coalesce(s.occurred_on, private.local_date(s.created_at)),
         s.id, l.product_id, s.cashier_id, s.type, 'sale', l.qty,
         (l.qty * l.unit_price_cents)::numeric,
         (l.qty * l.unit_price_cents)::numeric
           * (1 - case when s.subtotal_cents > 0 then s.promo_cents::numeric / s.subtotal_cents else 0 end),
         (l.qty * l.unit_cost_cents)::numeric,
         l.unit_cost_cents is not null,
         (l.qty * l.unit_cost_cents)::numeric
           * (case when s.subtotal_cents > 0 then s.promo_cents::numeric / s.subtotal_cents else 0 end),
         (l.qty * l.list_price_cents)::numeric
  from public.sales s
  join public.sale_lines l on l.sale_id = s.id and l.kind = 'product'
  where s.status = 'completed'
    and s.type <> 'training'
    and coalesce(s.occurred_on, private.local_date(s.created_at)) between p_from and p_to
  union all
  select private.local_date(r.at),
         s.id, l.product_id, s.cashier_id, s.type, 'refund', -rl.qty,
         -rl.amount_cents::numeric,
         -rl.amount_cents::numeric
           * (1 - case when r.amount_cents > 0 then r.promo_cents::numeric / r.amount_cents else 0 end),
         case when r.return_to_shelf then -(rl.qty * rl.unit_cost_cents)::numeric else 0 end,
         rl.unit_cost_cents is not null,
         case when r.return_to_shelf and r.amount_cents > 0
              then -(rl.qty * rl.unit_cost_cents)::numeric * r.promo_cents / r.amount_cents
              else 0 end,
         -(rl.qty * l.list_price_cents)::numeric
  from public.refunds r
  join public.refund_lines rl on rl.refund_id = r.id
  join public.sale_lines l on l.id = rl.sale_line_id
  join public.sales s on s.id = r.sale_id
  where s.type <> 'training'
    and private.local_date(r.at) between p_from and p_to
$$;

create function private.require_reports() returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not (public.can('view_reports') or public.can('preauth_view')) then
    perform private.require('view_reports');
  end if;
end
$$;

create function private.summary(p_from date, p_to date) returns jsonb
language sql stable
as $$
  with f as (select * from private.revenue_facts(p_from, p_to)),
  t as (
    select coalesce(sum(revenue_cents), 0) as revenue,
           coalesce(sum(cogs_cents), 0) as cogs,
           coalesce(sum(revenue_cents) filter (where known_cost), 0) as revenue_known,
           coalesce(sum(cogs_cents) filter (where known_cost), 0) as cogs_known,
           coalesce(sum(revenue_cents) filter (where not known_cost), 0) as revenue_cost_missing,
           coalesce(sum(promo_cost_cents), 0) as promo_cost,
           count(distinct sale_id) filter (where kind = 'sale') as sales_count,
           count(distinct d) filter (where kind = 'sale') as open_days
    from f)
  select jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'revenue_cents', round(t.revenue)::bigint,
    'cogs_cents', round(t.cogs)::bigint,
    'profit_cents', round(t.revenue - t.cogs)::bigint,
    'margin', case when t.revenue_known > 0
                   then round((t.revenue_known - t.cogs_known) / t.revenue_known, 4) end,
    'revenue_cost_missing_cents', round(t.revenue_cost_missing)::bigint,
    'promo_cost_cents', round(t.promo_cost)::bigint,
    'sales_count', t.sales_count,
    'avg_sale_cents', case when t.sales_count > 0 then round(t.revenue / t.sales_count)::bigint end,
    'open_days', t.open_days,
    'revenue_per_open_day_cents', case when t.open_days > 0 then round(t.revenue / t.open_days)::bigint end)
  from t
$$;

create function private.legacy_summary(p_from date, p_to date) returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'revenue_cents', coalesce(sum(total_cents), 0)::bigint,
    'rows', count(*),
    'open_days', count(distinct private.local_date(sold_at)))
  from public.legacy_sales
  where private.local_date(sold_at) between p_from and p_to
$$;

create function private.school_year_start(p_day date) returns date
language sql immutable
as $$
  select make_date(case when extract(month from p_day) >= 9 then extract(year from p_day)::int
                        else extract(year from p_day)::int - 1 end, 9, 1)
$$;

-------------------------------------------------------------------------------
-- Dashboard
-------------------------------------------------------------------------------

-- Defaults to the school year (September 1 to June 30) and compares with the
-- same period last year, including the imported Base44 history.
create function public.report_dashboard(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_from date;
  v_to date;
  v_now jsonb;
  v_last jsonb;
  v_legacy jsonb;
  v_planned integer;
  v_open_days integer;
  v_rpd bigint;
  v_series jsonb;
begin
  perform private.require('view_reports');
  v_from := coalesce(p_from, private.school_year_start(private.local_today()));
  v_to := coalesce(p_to, make_date(extract(year from v_from)::int + 1, 6, 30));
  if v_to < v_from then
    raise exception 'The end date is before the start date.';
  end if;

  v_now := private.summary(v_from, v_to);
  v_last := private.summary((v_from - interval '1 year')::date, (v_to - interval '1 year')::date);
  v_legacy := private.legacy_summary((v_from - interval '1 year')::date, (v_to - interval '1 year')::date);

  v_open_days := (v_now ->> 'open_days')::integer;
  v_rpd := (v_now ->> 'revenue_per_open_day_cents')::bigint;
  select count(*) into v_planned
    from public.settings s, unnest(s.open_days) od
   where s.id = 1 and od > private.local_today() and od <= v_to;

  select coalesce(jsonb_agg(jsonb_build_object('d', d, 'revenue_cents', round(rev)::bigint) order by d), '[]')
    into v_series
    from (select d, sum(revenue_cents) as rev from private.revenue_facts(v_from, v_to) group by d) x;

  return jsonb_build_object(
    'current', v_now,
    'last_year', v_last || jsonb_build_object(
      'legacy_revenue_cents', (v_legacy ->> 'revenue_cents')::bigint,
      'legacy_open_days', (v_legacy ->> 'open_days')::integer,
      'combined_revenue_cents', (v_last ->> 'revenue_cents')::bigint + (v_legacy ->> 'revenue_cents')::bigint),
    'forecast', case
      when v_open_days < 10 then jsonb_build_object('message', 'Not enough recent sales', 'planned_open_days', v_planned)
      else jsonb_build_object('revenue_cents', v_rpd * v_planned, 'planned_open_days', v_planned,
                              'revenue_per_open_day_cents', v_rpd)
    end,
    'series', v_series);
end
$$;

-------------------------------------------------------------------------------
-- Tabs
-------------------------------------------------------------------------------

create function public.report_products(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with f as (
      select product_id,
             sum(qty) as qty,
             sum(revenue_cents) as revenue,
             sum(cogs_cents) as cogs,
             sum(revenue_cents) filter (where known_cost) as revenue_known,
             sum(cogs_cents) filter (where known_cost) as cogs_known
      from private.revenue_facts(p_from, p_to)
      group by product_id)
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', p.id, 'sku', p.sku, 'name', p.name, 'category', c.name,
             'status', p.status, 'price_cents', p.price_cents, 'avg_cost_cents', p.avg_cost_cents,
             'cost_status', p.cost_status, 'on_hand', private.on_hand(p.id),
             'qty', coalesce(f.qty, 0),
             'revenue_cents', round(coalesce(f.revenue, 0))::bigint,
             'cogs_cents', round(coalesce(f.cogs, 0))::bigint,
             'profit_cents', round(coalesce(f.revenue, 0) - coalesce(f.cogs, 0))::bigint,
             'margin', case when f.revenue_known > 0
                            then round((f.revenue_known - f.cogs_known) / f.revenue_known, 4) end)
           order by coalesce(f.revenue, 0) desc, p.name), '[]'::jsonb)
    from public.products p
    left join public.categories c on c.id = p.category_id
    left join f on f.product_id = p.id
    where p.status = 'active' or f.product_id is not null);
end
$$;

-- Weekly sales = last school year's units / weeks with at least one sale.
-- New-register sales and imported Base44 history both count. With no sales
-- last school year it falls back to the last 365 days.
create function private.weekly_sales(p_product_id uuid) returns jsonb
language plpgsql stable
as $$
declare
  v_sy date := private.school_year_start(private.local_today());
  v_from date := (v_sy - interval '1 year')::date;
  v_to date := make_date(extract(year from v_sy)::int, 6, 30);
  v_units numeric;
  v_weeks integer;
  v_source text := 'last_school_year';
begin
  for i in 1..2 loop
    with days as (
      select coalesce(s.occurred_on, private.local_date(s.created_at)) as d, (l.qty - l.refunded_qty) as units
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
      where l.product_id = p_product_id and s.status = 'completed' and s.type <> 'training'
        and coalesce(s.occurred_on, private.local_date(s.created_at)) between v_from and v_to
      union all
      select private.local_date(ls.sold_at), ls.qty
      from public.legacy_sales ls
      where ls.product_id = p_product_id and private.local_date(ls.sold_at) between v_from and v_to)
    select coalesce(sum(units), 0), count(distinct date_trunc('week', d)) filter (where units > 0)
      into v_units, v_weeks
      from days;
    exit when v_weeks > 0 or i = 2;
    v_from := private.local_today() - 365;
    v_to := private.local_today();
    v_source := 'last_365_days';
  end loop;

  return jsonb_build_object(
    'units', v_units,
    'weeks_with_sales', v_weeks,
    'weekly_sales', case when v_weeks > 0 then round(v_units / v_weeks, 2) else 0 end,
    'window_from', v_from,
    'window_to', v_to,
    'source', case when v_weeks > 0 then v_source else 'none' end);
end
$$;

create function public.product_sales_history(p_product_ids uuid[]) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_reports();
  return (
    select coalesce(jsonb_object_agg(p.id, private.weekly_sales(p.id)
                    || jsonb_build_object('on_hand', private.on_hand(p.id))), '{}'::jsonb)
    from public.products p
    where p.id = any (p_product_ids));
end
$$;

-- Suggest packs = (weekly sales * 6 weeks - on hand) / units per pack, rounded up.
create function public.report_restock() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with base as (
      select p.id, p.sku, p.name, p.price_cents, p.avg_cost_cents, p.low_stock_alert,
             private.on_hand(p.id) as on_hand,
             private.weekly_sales(p.id) as ws,
             coalesce(
               (select vi.units_per_pack from public.vendor_items vi where vi.product_id = p.id
                order by vi.checked_at desc limit 1),
               (select pl.units_per_pack from public.preauth_lines pl where pl.product_id = p.id
                order by pl.id desc limit 1)) as units_per_pack,
             (select jsonb_build_object('vendor_item_id', vi.id, 'name', vi.name, 'url', vi.url,
                                        'price_cents', coalesce(vi.sale_price_cents, vi.price_cents))
                from public.vendor_items vi where vi.product_id = p.id
               order by vi.checked_at desc limit 1) as listing
      from public.products p
      where p.status = 'active')
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', id, 'sku', sku, 'name', name, 'on_hand', on_hand,
             'low_stock_alert', low_stock_alert, 'low', on_hand <= low_stock_alert,
             'weekly_sales', (ws ->> 'weekly_sales')::numeric,
             'weeks_of_supply', case when (ws ->> 'weekly_sales')::numeric > 0
                                     then round(on_hand / (ws ->> 'weekly_sales')::numeric, 1) end,
             'units_per_pack', units_per_pack,
             'suggested_packs', case
                when units_per_pack is null or (ws ->> 'weekly_sales')::numeric = 0 then null
                else greatest(ceil(((ws ->> 'weekly_sales')::numeric * 6 - on_hand) / units_per_pack), 0)::integer
              end,
             'listing', listing,
             'price_cents', price_cents)
           order by (on_hand <= low_stock_alert) desc, name), '[]'::jsonb)
    from base);
end
$$;

create function public.report_cash(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return jsonb_build_object(
    'shifts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', sh.id, 'number', sh.number, 'cashier_name', m.display_name,
               'opened_at', sh.opened_at, 'closed_at', sh.closed_at,
               'opening_cash_cents', sh.opening_cash_cents,
               'expected_cash_cents', coalesce(sh.expected_cash_cents, private.shift_expected_cash(sh.id)),
               'counted_cash_cents', sh.counted_cash_cents,
               'over_short_cents', sh.over_short_cents,
               'handoffs_cents', (select coalesce(sum(amount_cents), 0) from public.cash_handoffs h where h.shift_id = sh.id),
               'note', sh.note)
             order by sh.opened_at desc), '[]'::jsonb)
      from public.shifts sh join public.members m on m.id = sh.cashier_id
      where private.local_date(sh.opened_at) between p_from and p_to),
    'total_over_short_cents', (
      select coalesce(sum(over_short_cents), 0) from public.shifts
      where private.local_date(opened_at) between p_from and p_to),
    'handoffs', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', h.at, 'amount_cents', h.amount_cents, 'from_name', mf.display_name,
               'to_name', mt.display_name, 'note', h.note) order by h.at desc), '[]'::jsonb)
      from public.cash_handoffs h
      join public.members mf on mf.id = h.from_id
      join public.members mt on mt.id = h.to_id
      where private.local_date(h.at) between p_from and p_to));
end
$$;

create function public.report_gift_cards(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with tx as (
      select t.*, c.type as card_type
      from public.gift_card_txns t join public.gift_cards c on c.id = t.card_id
      where private.local_date(t.at) between p_from and p_to),
    bal as (
      select c.id, c.code, c.type, c.status, c.created_at, coalesce(sum(t.amount_cents), 0) as balance
      from public.gift_cards c left join public.gift_card_txns t on t.card_id = c.id
      group by c.id)
    select jsonb_build_object(
      'outstanding_paid_cents', (select coalesce(sum(balance), 0) from bal where type = 'paid'),
      'outstanding_promo_cents', (select coalesce(sum(balance), 0) from bal where type = 'promo'),
      'issued_paid_cents', (select coalesce(sum(amount_cents), 0) from tx
                            where card_type = 'paid' and type in ('issue', 'load', 'import')),
      'issued_promo_cents', (select coalesce(sum(amount_cents), 0) from tx
                             where card_type = 'promo' and type in ('issue', 'load', 'import')),
      'redeemed_paid_cents', (select coalesce(-sum(amount_cents), 0) from tx
                              where card_type = 'paid' and type = 'redeem'),
      'redeemed_promo_cents', (select coalesce(-sum(amount_cents), 0) from tx
                               where card_type = 'promo' and type = 'redeem'),
      'returned_cents', (select coalesce(sum(amount_cents), 0) from tx
                         where type in ('refund', 'void') and amount_cents > 0),
      'promo_cost_cents', (select round(coalesce(sum(promo_cost_cents), 0))::bigint
                           from private.revenue_facts(p_from, p_to)),
      'cards_with_balance', (
        select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'type', type,
                 'balance_cents', balance, 'created_at', created_at) order by balance desc), '[]'::jsonb)
        from bal where balance > 0)));
end
$$;

create function public.report_shrink(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with m as (
      select sm.*, p.name, p.sku
      from public.stock_movements sm join public.products p on p.id = sm.product_id
      where sm.type in ('damaged', 'expired', 'missing', 'found', 'count_adjustment')
        and private.local_date(sm.at) between p_from and p_to)
    select jsonb_build_object(
      'total_value_cents', (select coalesce(sum(qty * unit_cost_cents), 0) from m),
      'by_type', (select coalesce(jsonb_object_agg(type, jsonb_build_object(
                     'qty', q, 'value_cents', v)), '{}'::jsonb)
                  from (select type, sum(qty) q, coalesce(sum(qty * unit_cost_cents), 0) v from m group by type) x),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'at', at, 'product_id', product_id, 'name', name, 'sku', sku, 'type', type, 'qty', qty,
                 'value_cents', qty * unit_cost_cents, 'reason', reason) order by at desc), '[]'::jsonb)
               from m)));
end
$$;

create function public.report_purchasing(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_reports();
  return (
    with p as (
      select pa.*, private.preauth_receipts_total(pa.id) as receipts_total
      from public.preauths pa
      where pa.request_date between p_from and p_to)
    select jsonb_build_object(
      'count', (select count(*) from p),
      'approved_cents', (select coalesce(sum(approved_total_cents), 0) from p
                         where status in ('approved', 'purchased', 'received', 'closed')),
      'spent_cents', (select coalesce(sum(receipts_total), 0) from p),
      'overdue', (select count(*) from p where overdue),
      'by_status', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                    from (select status, count(*) n from p group by status) x),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', id, 'number', number, 'student_name', student_name, 'status', status,
                 'request_date', request_date, 'grand_total_cents', grand_total_cents,
                 'approved_total_cents', approved_total_cents, 'receipts_total_cents', receipts_total,
                 'purchase_date', purchase_date, 'receipt_due_date', receipt_due_date, 'overdue', overdue)
               order by number desc), '[]'::jsonb) from p)));
end
$$;

create function public.report_staff_comps(p_from date, p_to date) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with f as (select * from private.revenue_facts(p_from, p_to))
    select jsonb_build_object(
      'by_cashier', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'cashier_id', x.cashier_id, 'name', m.display_name, 'sales', x.sales,
                 'revenue_cents', round(x.revenue)::bigint) order by x.revenue desc), '[]'::jsonb)
        from (select cashier_id, count(distinct sale_id) filter (where kind = 'sale') sales,
                     sum(revenue_cents) revenue
              from f group by cashier_id) x
        join public.members m on m.id = x.cashier_id),
      'staff_and_comps', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'sale_id', s.id, 'number', s.number, 'type', s.type, 'at', s.created_at,
                 'cashier_name', m.display_name, 'reason', s.reason, 'note', s.note,
                 'list_value_cents', (select sum(qty * list_price_cents) from public.sale_lines l
                                       where l.sale_id = s.id and l.kind = 'product'),
                 'charged_cents', s.subtotal_cents,
                 'cost_cents', (select sum(qty * unit_cost_cents) from public.sale_lines l
                                 where l.sale_id = s.id and l.kind = 'product'))
               order by s.created_at desc), '[]'::jsonb)
        from public.sales s join public.members m on m.id = s.cashier_id
        where s.type in ('staff', 'comp') and s.status = 'completed'
          and private.local_date(s.created_at) between p_from and p_to),
      'comp_cost_cents', (select round(coalesce(sum(cogs_cents), 0))::bigint from f where sale_type = 'comp'),
      'comp_list_value_cents', (select round(coalesce(sum(list_value_cents), 0))::bigint
                                from f where sale_type = 'comp')));
end
$$;

-- Stock value at average cost, for the year-end report.
create function public.report_inventory_value() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('view_reports');
  return (
    with b as (
      select p.id, p.name, p.sku, p.avg_cost_cents, private.on_hand(p.id) as on_hand
      from public.products p where p.status = 'active')
    select jsonb_build_object(
      'value_cents', (select coalesce(sum(on_hand * avg_cost_cents), 0) from b
                      where avg_cost_cents is not null and on_hand > 0),
      'units', (select coalesce(sum(on_hand), 0) from b where on_hand > 0),
      'cost_missing_products', (select count(*) from b where avg_cost_cents is null and on_hand > 0)));
end
$$;

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
