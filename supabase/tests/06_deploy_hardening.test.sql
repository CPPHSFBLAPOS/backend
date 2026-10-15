-- Pre-deploy hardening: explicit read grants, PIN hashes, password sessions,
-- gift card codes, paste lookups, escalating PIN lockouts.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

create function pg_temp.login(p_email text, p_method text default 'otp') returns void
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
    json_build_object('sub', v_uid, 'role', 'authenticated', 'email', lower(p_email),
                      'amr', json_build_array(json_build_object('method', p_method, 'timestamp', 1760000000)))::text,
    true);
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
create function pg_temp.cash(p_cents bigint) returns jsonb
language sql as $$ select jsonb_build_array(jsonb_build_object('method', 'cash', 'amount_cents', p_cents)) $$;
create function pg_temp.lock_left(p_email text) returns interval
language sql security definer as $$
  select pin_locked_until - now() from public.members where lower(email) = lower(p_email)
$$;
create function pg_temp.unlock(p_email text) returns void
language sql security definer as $$
  update public.members set pin_locked_until = now() - interval '1 second' where lower(email) = lower(p_email)
$$;
create function pg_temp.lockouts(p_email text) returns integer
language sql security definer as $$
  select pin_lockouts::int from public.members where lower(email) = lower(p_email)
$$;
create function pg_temp.wrong_five(p_email text) returns text
language sql as $$
  select string_agg(verify_member_pin(pg_temp.member(p_email), '0000') ->> 'error', ',')
  from generate_series(1, 5)
$$;

select plan(39);

-------------------------------------------------------------------------------
-- Reads are granted explicitly; RLS decides the rows
-------------------------------------------------------------------------------
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'v', 'p') and c.relname not in ('members', 'sales')
             and not has_table_privilege('authenticated', c.oid, 'select')),
          0, 'signed-in members can select from every table and view (members and sales by column)');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'v', 'p')
             and (has_table_privilege('anon', c.oid, 'select')
               or has_table_privilege('anon', c.oid, 'insert'))),
          0, 'the anon key reads and writes nothing');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'v', 'p')
             and (has_table_privilege('authenticated', c.oid, 'insert')
               or has_table_privilege('authenticated', c.oid, 'update')
               or has_table_privilege('authenticated', c.oid, 'delete'))),
          0, 'and members write nothing directly');
select ok(has_table_privilege('service_role', 'public.settings', 'select'), 'the service role reads settings');

select pg_temp.login('treasurer@example.com');
select is((select count(*)::int from settings), 1, 'the Treasurer reads settings');
select ok((select count(*) from categories) > 0, 'and categories');
select lives_ok($$ select count(*) from preauths $$, 'and pre-auths');
select lives_ok($$ select count(*) from stock_movements $$, 'and stock movements');
select lives_ok($$ select count(*) from product_stock $$, 'and on-hand counts');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- PIN hashes never leave the database
-------------------------------------------------------------------------------
select pg_temp.login('depedros@cppasd.com');
select throws_ok($$ select pin_hash from members $$, '42501', null, 'not even a Super Admin can read PIN hashes');
select throws_ok($$ select * from members $$, '42501', null, 'or select every column');
select ok((select count(*) from (select id, display_name, role, active from members) m) > 1,
          'the member list itself still reads');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- A password session is nobody
-------------------------------------------------------------------------------
select pg_temp.login('advisor@example.com', 'password');
select ok(whoami() is null, 'someone who signed up with a password and the Advisor''s email is not the Advisor');
select ok(not can('manage_members'), 'and cannot manage members');
select throws_ok($$ select save_member(null, 'evil@example.com', 'Evil', null, 'advisor', true) $$, '42501', null,
                 'or add a Super Admin');
select pg_temp.logout();
select pg_temp.login('advisor@example.com', 'otp');
select is(whoami() ->> 'role', 'advisor', 'the Advisor signing in with an email code is the Advisor');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Gift card codes are officer-only
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select issue_gift_card('promo', 500, 'Volunteer thanks') ->> 'code' as promo \gset
select pg_temp.logout();

select pg_temp.login('register@example.com');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset
select r -> 'new_cards' -> 0 ->> 'code' as card, r -> 'sale' ->> 'number' as sale_no
from complete_sale(gen_random_uuid(), :'shift', 'regular',
                   '[{"kind": "gift_card_load", "amount_cents": 2000}]', pg_temp.cash(2000)) r \gset
select matches(:'card'::text, '^[A-HJ-NP-Z2-9]{10}$', 'the register gets the full code of the card it just sold');
select is((select count(*)::int from gift_card_balance), 0, 'the Register account lists no gift cards');
select is((select count(*)::int from gift_card_txns), 0, 'or their history');
select is(find_sale(:'sale_no'::int) -> 'lines' -> 0 ->> 'card_code', '••••' || right(:'card', 4),
          'looking up a sale masks the card code');
select is((lookup_gift_card(:'card') ->> 'balance_cents')::bigint, 2000::bigint,
          'a balance check with the card in hand still works');
select pg_temp.logout();

select pg_temp.login('cashier@example.com');
select is((select count(*)::int from gift_cards), 0, 'a cashier lists no gift cards');
select throws_ok($$ select gift_card_totals() $$, '42501', null, 'or sees the totals');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select ok((select count(*) from gift_card_balance where code in (:'card', :'promo')) = 2, 'the Treasurer lists the cards');
select is(find_sale(:'sale_no'::int) -> 'lines' -> 0 ->> 'card_code', :'card', 'and sees full codes on sales');
select is(gift_card_totals(),
          jsonb_build_object('paid_outstanding_cents', 2000, 'promo_outstanding_cents', 500, 'cards_with_balance', 2),
          'gift_card_totals adds up every active card');
select deactivate_and_transfer((select id from gift_cards where code = :'card'), 'Lost at lunch')
  -> 'card' ->> 'code' as new_card \gset
select pg_temp.logout();

select pg_temp.login('register@example.com');
select is(lookup_gift_card(:'card') ->> 'replaced_by_code', '••••' || right(:'new_card', 4),
          'whoever finds a lost card cannot learn the code its money moved to');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- "Paste the page text" lookups
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select is(begin_sams_paste(null) - 'remaining', '{"ok": true, "cached": false}'::jsonb,
          'a paste without a link goes ahead');
select is((select count(*)::int from log_entries where action = 'sams_paste'), 1, 'and is logged');
select is((select count(*)::int from log_entries where action = 'sams_lookup'), 0,
          'without using up a search lookup');
select throws_like($$ select begin_sams_paste('https://example.com/item') $$, '%samsclub.com%',
                   'links to other sites are refused');
select pg_temp.logout();
select pg_temp.login('cashier@example.com');
select throws_ok($$ select begin_sams_paste(null) $$, '42501', null, 'cashiers cannot run lookups');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Each PIN lockout lasts twice as long as the last
-------------------------------------------------------------------------------
select pg_temp.login('register@example.com');
select is(pg_temp.wrong_five('cashier2@example.com'), 'pin_wrong,pin_wrong,pin_wrong,pin_wrong,pin_locked',
          'five wrong tries lock the PIN');
select ok(pg_temp.lock_left('cashier2@example.com') between interval '4 minutes' and interval '5 minutes',
          'for 5 minutes the first time');
select pg_temp.unlock('cashier2@example.com');
select is(pg_temp.wrong_five('cashier2@example.com'), 'pin_wrong,pin_wrong,pin_wrong,pin_wrong,pin_locked',
          'five more wrong tries lock it again');
select ok(pg_temp.lock_left('cashier2@example.com') between interval '9 minutes' and interval '10 minutes',
          'for 10 minutes the second time');
select pg_temp.unlock('cashier2@example.com');
select is(verify_member_pin(pg_temp.member('cashier2@example.com'), '4444') ->> 'ok', 'true',
          'the right PIN works once the lock ends');
select is(pg_temp.lockouts('cashier2@example.com'), 0, 'and starts the count over');
select pg_temp.logout();
select is((select (after ->> 'by')::uuid from log_entries where action = 'pin_locked' order by seq desc limit 1),
          pg_temp.member('register@example.com'), 'the lockout entry names who was guessing');

select * from finish();
rollback;
