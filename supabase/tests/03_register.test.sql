-- Phase 3: shifts, sales, voids, refunds, handoffs, outage entries, training.
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

select plan(36);

select pg_temp.login('register@example.com');

-------------------------------------------------------------------------------
-- Opening a shift
-------------------------------------------------------------------------------
select is(open_shift(pg_temp.member('cashier@example.com'), '9999', 5000) ->> 'error', 'pin_wrong',
          'a wrong PIN does not open a shift');
select throws_like($$ select complete_sale(gen_random_uuid(), null, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.cash(100)) $$,
                   '%Open a shift first%', 'no sale without an open shift');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset
select ok(:'shift' is not null, 'the cashier opens a shift with their PIN');
select throws_like($$ select open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) $$,
                   '%already has an open shift%', 'one open shift per cashier');

-------------------------------------------------------------------------------
-- complete_sale: change due, idempotency, stock
-------------------------------------------------------------------------------
select complete_sale('11111111-1111-1111-1111-111111111111', :'shift', 'regular',
                     pg_temp.cart('FBLA-0001', 2), pg_temp.cash(200), 500) as sale_a \gset
select is((:'sale_a'::jsonb ->> 'change_cents')::bigint, 300::bigint, 'change due = cash given - cash due');
select is((:'sale_a'::jsonb -> 'sale' -> 'lines' -> 0 ->> 'unit_cost_cents')::bigint, 25::bigint,
          'the line saves the cost at the moment of sale');
select is(complete_sale('11111111-1111-1111-1111-111111111111', :'shift', 'regular',
                        pg_temp.cart('FBLA-0001', 2), pg_temp.cash(200), 500) ->> 'duplicate', 'true',
          'sending the same sale twice returns the first one');
select is((select count(*)::int from sales where client_uuid = '11111111-1111-1111-1111-111111111111'), 1,
          'complete_sale saves once when sent twice');
select is(pg_temp.on_hand('FBLA-0001'), 46, 'stock dropped once');

select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0006', 5), pg_temp.cash(500)) $$, :'shift'),
                   '%out of stock%', 'items with no stock are rejected');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.cash(50)) $$, :'shift'),
                   '%do not match the total%', 'payments must match the total');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'comp', pg_temp.cart('FBLA-0001', 1), '[]') $$, :'shift'),
                   '%needs a reason%', 'a comp needs a reason');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.cash(100), 50) $$, :'shift'),
                   '%less than the cash due%', 'cash given must cover the cash due');

-------------------------------------------------------------------------------
-- Training mode touches nothing
-------------------------------------------------------------------------------
select complete_sale(gen_random_uuid(), :'shift', 'training', pg_temp.cart('FBLA-0006', 3), pg_temp.cash(300))
  -> 'sale' ->> 'id' as training \gset
select is((select count(*)::int from stock_movements where source_id = :'training'), 0,
          'training sales leave no stock movements');
select is(pg_temp.on_hand('FBLA-0006'), 3, 'training does not change stock');

-------------------------------------------------------------------------------
-- Voids
-------------------------------------------------------------------------------
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0002', 1), pg_temp.cash(175))
  -> 'sale' ->> 'id' as sale_b \gset
select is(pg_temp.on_hand('FBLA-0002'), 23, 'the sale took one sports drink');
select is(void_sale(:'sale_b', :'shift', 'Rang it twice') ->> 'error', 'officer_pin_required',
          'a cashier needs an officer PIN to void');
select is(void_sale(:'sale_b', :'shift', 'Rang it twice', pg_temp.member('treasurer@example.com'), '0000') ->> 'error',
          'pin_wrong', 'a wrong officer PIN does not void');
select is(void_sale(:'sale_b', :'shift', 'Rang it twice', pg_temp.member('treasurer@example.com'), '2222') ->> 'ok',
          'true', 'an officer PIN voids the sale');
select is(pg_temp.on_hand('FBLA-0002'), 24, 'a void restores stock');
select throws_like(format($$ select void_sale(%L, %L, 'again') $$, :'sale_b', :'shift'), '%is voided%',
                   'a sale is voided once');

-------------------------------------------------------------------------------
-- Refunds
-------------------------------------------------------------------------------
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0003', 3), pg_temp.cash(300))
  -> 'sale' ->> 'id' as sale_c \gset
select (select id from sale_lines where sale_id = :'sale_c') as line_c \gset
select is(refund_sale(:'sale_c', :'shift', jsonb_build_array(jsonb_build_object('sale_line_id', :'line_c', 'qty', 1)),
                      true, 'Stale') ->> 'error', 'officer_pin_required',
          'a cashier cannot refund without an officer PIN');
select is((refund_sale(:'sale_c', :'shift', jsonb_build_array(jsonb_build_object('sale_line_id', :'line_c', 'qty', 1)),
                       true, 'Stale', pg_temp.member('treasurer@example.com'), '2222') ->> 'cash_cents')::bigint,
          100::bigint, 'a partial refund gives back one item''s price in cash');
select is((select refunded_qty from sale_lines where id = :'line_c'), 1, 'the line records 1 refunded');
select is(pg_temp.on_hand('FBLA-0003'), 38, 'Return to shelf puts the item back in stock');
select throws_like(format($$ select refund_sale(%L, %L, jsonb_build_array(jsonb_build_object('sale_line_id', %L, 'qty', 3)), true, 'x', %L, '2222') $$,
                          :'sale_c', :'shift', :'line_c', pg_temp.member('treasurer@example.com')),
                   '%Only 2 of that item%', 'you cannot refund more than was sold');

-------------------------------------------------------------------------------
-- Handoffs and closing: expected cash and over/short
-- 5000 opening + 200 (sale A) + 300 (sale C) - 100 refund - 1000 handoff = 4400
-------------------------------------------------------------------------------
select is((record_handoff(:'shift', 1000, pg_temp.member('cashier@example.com'), '3333',
                          pg_temp.member('treasurer@example.com'), '2222',
                          '{"typed_name": "Casey", "strokes": [{"points": [{"x": 1, "y": 1}]}]}',
                          '{"typed_name": "Taylor", "strokes": [{"points": [{"x": 1, "y": 1}]}]}')
           ->> 'expected_cash_cents')::bigint, 4400::bigint,
          'expected cash = opening + cash sales - cash refunds - handoffs');
select is((close_shift(:'shift', '[{"denom_cents": 2000, "count": 2}, {"denom_cents": 100, "count": 4}]')
           ->> 'over_short_cents')::bigint, 0::bigint, 'the drawer closes at $0.00 over/short');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.cash(100)) $$, :'shift'),
                   '%is closed%', 'no sales on a closed shift');

select (open_shift(pg_temp.member('cashier2@example.com'), '4444', 5000) ->> 'shift_id') as shift2 \gset
select is(close_shift(:'shift2', '[{"denom_cents": 2000, "count": 2}, {"denom_cents": 100, "count": 8}]') ->> 'error',
          'note_required', 'a drawer $2.00 short needs a note');
select is(close_shift(:'shift2', '[{"denom_cents": 2000, "count": 2}, {"denom_cents": 100, "count": 8}]', 'Miscounted change') ->> 'error',
          'officer_pin_required', 'and an officer PIN');
select is((close_shift(:'shift2', '[{"denom_cents": 2000, "count": 2}, {"denom_cents": 100, "count": 8}]', 'Miscounted change',
                       pg_temp.member('treasurer@example.com'), '2222') ->> 'over_short_cents')::bigint,
          -200::bigint, 'over/short = counted - expected');

-------------------------------------------------------------------------------
-- Outage entries stay Pending until a different officer verifies them
-------------------------------------------------------------------------------
select pg_temp.logout();
select pg_temp.login('treasurer@example.com');
select log_outage_sale(gen_random_uuid(), null, (now() at time zone 'America/New_York')::date,
                       pg_temp.cart('FBLA-0008', 4), 'sheet.jpg', 'Wi-Fi down at lunch') -> 'sale' ->> 'id' as outage \gset
select is((select status::text from sales where id = :'outage'), 'pending', 'an outage entry starts Pending');
select throws_ok(format($$ select verify_outage_sale(%L, true) $$, :'outage'), '42501', null,
                 'you cannot verify your own outage entry');
select pg_temp.logout();
select pg_temp.login('advisor@example.com');
select is(verify_outage_sale(:'outage', true) -> 'sale' ->> 'status', 'completed', 'a different officer verifies it');
select is(pg_temp.on_hand('FBLA-0008'), 26, 'stock moves when it is verified');
select pg_temp.logout();

select * from finish();
rollback;
