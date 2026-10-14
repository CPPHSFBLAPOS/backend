-- Phase 1: roles, RLS, the append-only log, stock ledger, PINs.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

-- Test helpers: sign in as a member (by email) or sign out.
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

select plan(55);

-------------------------------------------------------------------------------
-- The permission matrix
-------------------------------------------------------------------------------
select ok(role_can('cashier', false, 'ring_sales'), 'a cashier can ring sales');
select ok(not role_can('cashier', false, 'void_refund'), 'a cashier cannot void without an officer');
select ok(role_can('treasurer', false, 'issue_promo'), 'the Treasurer can issue promo cards');
select ok(not role_can('cashier', false, 'issue_promo'), 'a cashier cannot issue promo cards');
select ok(role_can('advisor', false, 'preauth_approve'), 'the Advisor approves pre-auths');
select ok(not role_can('president', true, 'preauth_approve'), 'a Super Admin President still cannot approve');
select ok(not role_can(null, true, 'preauth_request'), 'a Super Admin with no role cannot sign as Student');
select ok(role_can(null, true, 'manage_members'), 'a Super Admin manages members');
select ok(not role_can('president', false, 'manage_members'), 'the President does not manage members');
select ok(not role_can('register', false, 'view_reports'), 'the Register account cannot see reports');

-------------------------------------------------------------------------------
-- A cashier cannot read members or other people's log entries
-------------------------------------------------------------------------------
select pg_temp.login('cashier@example.com');
select is((select count(*)::int from members where lower(email) <> 'cashier@example.com'), 0,
          'a cashier cannot read other members');
select is((select count(*)::int from members), 1, 'a cashier can read their own member row');
select is((select count(*)::int from log_entries
           where actor_id is distinct from pg_temp.member('cashier@example.com')), 0,
          'a cashier cannot read other people''s log entries');
select throws_ok($$ select * from list_members() $$, '42501', null, 'a cashier cannot list members');
select ok((select count(*) from products) > 0, 'a cashier can read products');
select is((select count(*)::int from stock_movements), 0, 'a cashier cannot read the stock ledger');
select is((select on_hand from catalog() where sku = 'FBLA-0001'), 48, 'but catalog() shows them stock on hand');

-------------------------------------------------------------------------------
-- log_entries is append-only for every role
-------------------------------------------------------------------------------
select throws_ok($$ update log_entries set reason = 'x' $$, '42501', null, 'authenticated cannot UPDATE log_entries');
select throws_ok($$ delete from log_entries $$, '42501', null, 'authenticated cannot DELETE log_entries');
select throws_ok($$ insert into log_entries (action, hash) values ('fake', 'x') $$, '42501', null,
                 'authenticated cannot INSERT log_entries directly');
select pg_temp.logout();

set local role anon;
select throws_ok($$ update log_entries set reason = 'x' $$, '42501', null, 'anon cannot UPDATE log_entries');
select throws_ok($$ delete from log_entries $$, '42501', null, 'anon cannot DELETE log_entries');
reset role;

set local role service_role;
select throws_ok($$ update log_entries set reason = 'x' $$, '42501', null, 'service_role cannot UPDATE log_entries');
select throws_ok($$ delete from log_entries $$, '42501', null, 'service_role cannot DELETE log_entries');
reset role;

select throws_ok($$ update log_entries set reason = 'x' $$, '42501', null, 'the table owner cannot UPDATE log_entries');
select throws_ok($$ delete from log_entries $$, '42501', null, 'the table owner cannot DELETE log_entries');
select throws_ok($$ truncate log_entries $$, '42501', null, 'the table owner cannot TRUNCATE log_entries');

-------------------------------------------------------------------------------
-- verify_log() catches a row someone with table-owner rights changed
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select is((verify_log() ->> 'ok')::boolean, true, 'the seeded log chain verifies');
select pg_temp.logout();

alter table log_entries disable trigger log_entries_append_only;
update log_entries set amount_cents = coalesce(amount_cents, 0) + 1 where seq = 5;
alter table log_entries enable trigger log_entries_append_only;

select pg_temp.login('treasurer@example.com');
select is((verify_log() ->> 'ok')::boolean, false, 'verify_log() catches a changed row');
select is((verify_log() ->> 'first_bad_seq')::int, 5, 'and names the changed entry');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Stock on hand equals the sum of movements after a mix of changes
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select is(adjust_stock(pg_temp.product('FBLA-0001'), 3, 'damaged', 'Dropped'), 45, 'Damaged takes stock out');
select is(adjust_stock(pg_temp.product('FBLA-0001'), 2, 'found', null), 47, 'Found puts stock back');
select throws_like($$ select adjust_stock(pg_temp.product('FBLA-0006'), 10, 'missing', null) $$,
                   'Only 3 on hand.', 'stock cannot go below zero');

select start_count('quick') as count_id \gset
select save_count_line(:'count_id', product_id, expected) from stock_count_lines where count_id = :'count_id';
select save_count_line(:'count_id', pg_temp.product('FBLA-0001'), 50);
select is(approve_count(:'count_id'), 1, 'approving the count posts one adjustment');
select is((select on_hand from product_stock where product_id = pg_temp.product('FBLA-0001')), 50,
          'the count set the stock to what was counted');
select is((select sum(qty)::int from stock_movements where product_id = pg_temp.product('FBLA-0001')), 50,
          'stock equals the sum of its movements');
select is((select count(*)::int from stock_movements where product_id = pg_temp.product('FBLA-0001')), 4,
          'opening balance, damaged, found and the count adjustment are all in the ledger');
select throws_ok($$ update stock_movements set qty = 1 $$, '42501', null, 'movements cannot be edited');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- A non-member cannot call any RPC
-------------------------------------------------------------------------------
select pg_temp.login('stranger@example.com');
select is(whoami(), null, 'whoami() is null for a non-member');
select is((select count(*)::int from products), 0, 'a non-member reads no products');
select throws_ok($$ select save_product(null, 'X', null, 100) $$, '42501', null, 'non-member: save_product');
select throws_ok($$ select record_sign_in() $$, '42501', null, 'non-member: record_sign_in');
select throws_ok($$ select * from member_directory() $$, '42501', null, 'non-member: member_directory');
select throws_ok($$ select adjust_stock(pg_temp.product('FBLA-0001'), 1, 'found') $$, '42501', null, 'non-member: adjust_stock');
select throws_ok($$ select save_member(null, 'x@example.com', 'X') $$, '42501', null, 'non-member: save_member');
select throws_ok($$ select verify_log() $$, '42501', null, 'non-member: verify_log');
select throws_ok($$ select save_preauth(null, '{}', '[]') $$, '42501', null, 'non-member: save_preauth');
select throws_ok($$ select begin_sams_lookup('water') $$, '42501', null, 'non-member: begin_sams_lookup');
select throws_ok($$ select open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) $$, '42501', null, 'non-member: open_shift');
select throws_ok($$ select complete_sale(gen_random_uuid(), null, 'regular', '[]') $$, '42501', null, 'non-member: complete_sale');
select throws_ok($$ select issue_gift_card('promo', 500) $$, '42501', null, 'non-member: issue_gift_card');
select throws_ok($$ select lookup_gift_card('ABCDEFGHJK') $$, '42501', null, 'non-member: lookup_gift_card');
select throws_ok($$ select report_dashboard() $$, '42501', null, 'non-member: report_dashboard');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- PINs: 5 wrong tries lock that cashier out
-------------------------------------------------------------------------------
select pg_temp.login('register@example.com');
select is((select string_agg(verify_member_pin(pg_temp.member('cashier2@example.com'), '0000') ->> 'error', ',')
           from generate_series(1, 5)),
          'pin_wrong,pin_wrong,pin_wrong,pin_wrong,pin_locked', 'the fifth wrong PIN locks the cashier');
select is(verify_member_pin(pg_temp.member('cashier2@example.com'), '4444') ->> 'error', 'pin_locked',
          'the right PIN does not work while locked');
select pg_temp.logout();

select * from finish();
rollback;
