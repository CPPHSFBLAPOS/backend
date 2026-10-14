-- Phase 5: a fixture day of sales, refunds, comps and gift card activity
-- whose report totals match numbers worked out by hand.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

create function pg_temp.login(p_email text) returns void
language plpgsql as $$
declare
  v_uid uuid;
begin
  reset role;
  select u.id into v_uid from auth.users u where lower(u.email) = lower(p_email);
  if v_uid is null then
    insert into auth.users (id, email) values (gen_random_uuid(), lower(p_email)) returning id into v_uid;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated', 'email', lower(p_email))::text, true);
  set local role authenticated;
end
$$;
create function pg_temp.logout() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end
$$;
create function pg_temp.member(p_email text) returns uuid
language sql security definer as $$
  select id from public.members where lower(email) = lower(p_email)
$$;
create function pg_temp.product(p_sku text) returns uuid
language sql security definer as $$
  select id from public.products where sku = p_sku
$$;
create function pg_temp.on_hand(p_sku text) returns integer
language sql security definer as $$
  select coalesce(sum(m.qty), 0)::int from public.stock_movements m
  join public.products p on p.id = m.product_id where p.sku = p_sku
$$;
create function pg_temp.cart(p_sku text, p_qty integer) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object('kind', 'product', 'product_id', pg_temp.product(p_sku), 'qty', p_qty))
$$;
create function pg_temp.cash(p_cents bigint) returns jsonb
language sql as $$ select jsonb_build_array(jsonb_build_object('method', 'cash', 'amount_cents', p_cents)) $$;

create function pg_temp.today() returns date
language sql as $$ select (now() at time zone 'America/New_York')::date $$;

select plan(24);

select pg_temp.login('treasurer@example.com');
select issue_gift_card('promo', 200) ->> 'code' as promo \gset
select adjust_stock(pg_temp.product('FBLA-0001'), 2, 'damaged', 'Leaked');
select log_outage_sale(gen_random_uuid(), null, pg_temp.today(), pg_temp.cart('FBLA-0008', 2), 'sheet.jpg');
select pg_temp.logout();

select pg_temp.login('register@example.com');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset

-- S1: 2 water at $1.00 (cost 25c)                      revenue 200, cost 50
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0001', 2), pg_temp.cash(200));
-- S2: 3 chips at $1.00 (cost 45c), one refunded to shelf  revenue 300 - 100, cost 135 - 45
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0003', 3), pg_temp.cash(300))
  -> 'sale' ->> 'id' as s2 \gset
select refund_sale(:'s2', :'shift', jsonb_build_array(jsonb_build_object('sale_line_id',
                   (select id from sale_lines where sale_id = :'s2'), 'qty', 1)), true, 'Crushed',
                   pg_temp.member('treasurer@example.com'), '2222');
-- S3: comp lanyard ($3.00 list, cost $1.20)              revenue 0, cost 120
select complete_sale(gen_random_uuid(), :'shift', 'comp', pg_temp.cart('FBLA-0010', 1), '[]', null, null,
                     'Volunteer thank-you');
-- S4: $10 gift card load + 4 fruit snacks at 75c (22c)   revenue 300, cost 88 (load excluded)
select complete_sale(gen_random_uuid(), :'shift', 'regular',
  jsonb_build_array(jsonb_build_object('kind', 'gift_card_load', 'amount_cents', 1000),
                    jsonb_build_object('kind', 'product', 'product_id', pg_temp.product('FBLA-0005'), 'qty', 4)),
  pg_temp.cash(1300));
-- S5: 2 rice treats on a promo card (cost 30c)           revenue 0, cost 60, promo cost 60
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0004', 2),
  jsonb_build_array(jsonb_build_object('method', 'promo_card', 'code', :'promo', 'amount_cents', 200)));
-- S6: hot cocoa, cost missing                            revenue 100, no cost
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0007', 1), pg_temp.cash(100));
-- Left out: a training sale and a voided sale.
select complete_sale(gen_random_uuid(), :'shift', 'training', pg_temp.cart('FBLA-0001', 5), pg_temp.cash(500));
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0002', 1), pg_temp.cash(175))
  -> 'sale' ->> 'id' as s7 \gset
select void_sale(:'s7', :'shift', 'Rang wrong item', pg_temp.member('treasurer@example.com'), '2222');
-- Drawer: 5000 + 200 + 300 + 1300 + 100 - 100 = 6800
select is((close_shift(:'shift', '[{"denom_cents": 2000, "count": 3}, {"denom_cents": 100, "count": 8}]')
          ->> 'over_short_cents')::bigint, 0::bigint, 'the fixture drawer balances at 6800');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select report_dashboard(pg_temp.today(), pg_temp.today()) as dash \gset

-- revenue = 200 + 300 - 100 + 0 + 300 + 0 + 100 = 800
select is((:'dash'::jsonb -> 'current' ->> 'revenue_cents')::bigint, 800::bigint, 'revenue');
-- cost = 50 + 135 - 45 + 120 + 88 + 60 = 408
select is((:'dash'::jsonb -> 'current' ->> 'cogs_cents')::bigint, 408::bigint, 'cost of goods');
select is((:'dash'::jsonb -> 'current' ->> 'profit_cents')::bigint, 392::bigint, 'profit');
-- margin on known-cost items only: (700 - 408) / 700
select is((:'dash'::jsonb -> 'current' ->> 'margin')::numeric, 0.4171, 'margin leaves out cost-missing items');
select is((:'dash'::jsonb -> 'current' ->> 'revenue_cost_missing_cents')::bigint, 100::bigint,
          'cost-missing revenue is shown separately');
select is((:'dash'::jsonb -> 'current' ->> 'sales_count')::int, 6, 'sales count leaves out training and voids');
select is((:'dash'::jsonb -> 'current' ->> 'avg_sale_cents')::bigint, 133::bigint, 'average sale');
select is((:'dash'::jsonb -> 'current' ->> 'open_days')::int, 1, 'open days');
select is((:'dash'::jsonb -> 'current' ->> 'promo_cost_cents')::bigint, 60::bigint, 'promo cost');
select is(:'dash'::jsonb -> 'forecast' ->> 'message', 'Not enough recent sales',
          'no forecast with under 10 open days');
select ok((:'dash'::jsonb -> 'last_year' ->> 'combined_revenue_cents')::bigint
          = (:'dash'::jsonb -> 'last_year' ->> 'legacy_revenue_cents')::bigint
          + (:'dash'::jsonb -> 'last_year' ->> 'revenue_cents')::bigint,
          'last year combines the new register and Base44 history');

select report_products(pg_temp.today(), pg_temp.today()) as products \gset
select is((select (x ->> 'qty')::int from jsonb_array_elements(:'products'::jsonb) x where x ->> 'sku' = 'FBLA-0003'),
          2, 'products: chips net of the refund');
select is((select (x ->> 'profit_cents')::bigint from jsonb_array_elements(:'products'::jsonb) x where x ->> 'sku' = 'FBLA-0003'),
          110::bigint, 'products: chips profit 200 - 90');

select report_gift_cards(pg_temp.today(), pg_temp.today()) as gc \gset
select is((:'gc'::jsonb ->> 'issued_paid_cents')::bigint, 1000::bigint, 'gift cards: paid issued');
select is((:'gc'::jsonb ->> 'issued_promo_cents')::bigint, 200::bigint, 'gift cards: promo issued');
select is((:'gc'::jsonb ->> 'redeemed_promo_cents')::bigint, 200::bigint, 'gift cards: promo redeemed');
select is((:'gc'::jsonb ->> 'outstanding_paid_cents')::bigint, 1000::bigint, 'gift cards: owed on paid cards');
select is((:'gc'::jsonb ->> 'promo_cost_cents')::bigint, 60::bigint, 'gift cards: promo cost');

select report_staff_comps(pg_temp.today(), pg_temp.today()) as sc \gset
select is((:'sc'::jsonb ->> 'comp_cost_cents')::bigint, 120::bigint, 'comps: cost');
select is((:'sc'::jsonb ->> 'comp_list_value_cents')::bigint, 300::bigint, 'comps: list value');

select is((report_shrink(pg_temp.today(), pg_temp.today()) ->> 'total_value_cents')::bigint, -50::bigint,
          'shrink: 2 damaged water at 25c');
select is((report_cash(pg_temp.today(), pg_temp.today()) ->> 'total_over_short_cents')::bigint, 0::bigint,
          'cash: over/short');
select is((report_purchasing(pg_temp.today(), pg_temp.today()) ->> 'count')::int, 0, 'purchasing: no forms today');
select pg_temp.logout();

select * from finish();
rollback;
