-- Phase 4: gift cards.
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

create function pg_temp.balance(p_code text) returns bigint
language sql security definer as $$
  select coalesce(sum(t.amount_cents), 0)::bigint from public.gift_card_txns t
  join public.gift_cards c on c.id = t.card_id where c.code = p_code
$$;
create function pg_temp.pay(p_method text, p_code text, p_cents bigint) returns jsonb
language sql as $$
  select jsonb_build_array(jsonb_build_object('method', p_method, 'code', p_code, 'amount_cents', p_cents))
$$;

select plan(22);

-------------------------------------------------------------------------------
-- Issuing
-------------------------------------------------------------------------------
select pg_temp.login('cashier@example.com');
select throws_ok($$ select issue_gift_card('promo', 500) $$, '42501', null, 'a cashier cannot issue promo cards');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select issue_gift_card('promo', 500, 'Volunteer thanks') ->> 'code' as promo \gset
select matches(:'promo'::text, '^[A-HJ-NP-Z2-9]{10}$', 'codes are 10 characters without 0, O, 1 or I');
select is((select balance_cents from gift_card_balance where code = :'promo'), 500::bigint,
          'the balance view shows the promo value');
select is((select balance_cents from gift_card_balance where code = :'promo'), pg_temp.balance(:'promo'),
          'balance equals the sum of transactions');
select throws_like($$ select issue_gift_card('paid', 1000) $$, '%Load paid cards at the register%',
                   'paid cards are loaded at the register, where the cash is counted');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Selling, spending, overdrawing
-------------------------------------------------------------------------------
select pg_temp.login('register@example.com');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset
select complete_sale(gen_random_uuid(), :'shift', 'regular',
                     '[{"kind": "gift_card_load", "amount_cents": 2000}]', pg_temp.cash(2000))
  -> 'new_cards' -> 0 ->> 'code' as card \gset
select is(pg_temp.balance(:'card'), 2000::bigint, 'selling a card loads it');
select is((lookup_gift_card(lower(substr(:'card', 1, 5)) || '-' || substr(:'card', 6)) ->> 'balance_cents')::bigint,
          2000::bigint, 'lookup ignores case and dashes');

select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0001', 2),
                     pg_temp.pay('gift_card', :'card', 200)) -> 'sale' ->> 'id' as card_sale \gset
select is(pg_temp.balance(:'card'), 1800::bigint, 'spending takes it off the card');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0010', 7), pg_temp.pay('gift_card', %L, 2100)) $$, :'shift', :'card'),
                   '%only has $18.00%', 'overdrawing fails');
select is(pg_temp.balance(:'card'), 1800::bigint, 'and the balance is unchanged');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', '[{"kind": "gift_card_load", "amount_cents": 500}]', pg_temp.pay('gift_card', %L, 500)) $$, :'shift', :'card'),
                   '%loads are paid in cash%', 'a gift card cannot pay for a gift card load');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.pay('gift_card', %L, 100)) $$, :'shift', :'promo'),
                   '%is a promo card%', 'a promo card is not taken as a paid card');

-------------------------------------------------------------------------------
-- Refunds go back onto the card
-------------------------------------------------------------------------------
select is((refund_sale(:'card_sale', :'shift',
                       jsonb_build_array(jsonb_build_object('sale_line_id',
                         (select id from sale_lines where sale_id = :'card_sale'), 'qty', 1)),
                       true, 'Wrong item', pg_temp.member('treasurer@example.com'), '2222')
           ->> 'gift_card_cents')::bigint, 100::bigint, 'a card-paid refund goes back onto the card');
select is(pg_temp.balance(:'card'), 1900::bigint, 'the card balance went back up');

-------------------------------------------------------------------------------
-- Promo spending is cost of goods with $0 revenue
-------------------------------------------------------------------------------
select complete_sale(gen_random_uuid(), :'shift', 'regular', pg_temp.cart('FBLA-0003', 2),
                     pg_temp.pay('promo_card', :'promo', 200)) -> 'sale' ->> 'id' as promo_sale \gset
select is(pg_temp.balance(:'promo'), 300::bigint, 'the promo card was spent');
select pg_temp.logout();
select is((select round(sum(revenue_cents))::bigint from private.revenue_facts(current_date - 1, current_date + 1)
           where sale_id = :'promo_sale'), 0::bigint, 'promo spending shows $0 revenue');
select is((select round(sum(promo_cost_cents))::bigint from private.revenue_facts(current_date - 1, current_date + 1)
           where sale_id = :'promo_sale'), 90::bigint, 'and records the cost of goods as promo cost');

-------------------------------------------------------------------------------
-- Lost card: deactivate and move the balance
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select deactivate_and_transfer((select id from gift_cards where code = :'card'), 'Lost at lunch')
  -> 'card' ->> 'code' as new_card \gset
select is(pg_temp.balance(:'new_card'), 1900::bigint, 'the balance moved to the new card');
select is(pg_temp.balance(:'card'), 0::bigint, 'the old card is empty');
select throws_like(format($$ select complete_sale(gen_random_uuid(), %L, 'regular', pg_temp.cart('FBLA-0001', 1), pg_temp.pay('gift_card', %L, 100)) $$, :'shift', :'card'),
                   '%is deactivated%', 'the old card cannot be spent');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Base44 balances come over as Import transactions
-------------------------------------------------------------------------------
select pg_temp.login('advisor@example.com');
select is((import_gift_cards('[{"code": "B44-0001", "balance_cents": 750}, {"code": "B44-0002", "balance_cents": 0}]') ->> 'added')::int,
          1, 'cards with money left are imported');
select is((select balance_cents from gift_card_balance g join gift_cards c on c.id = g.card_id
           where c.legacy_code = 'B44-0001'), 750::bigint, 'with their balance');
select pg_temp.logout();

select * from finish();
rollback;
