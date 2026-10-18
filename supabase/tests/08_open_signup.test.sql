-- Open sign-up: anyone joins as a Cashier, Super Admins manage members,
-- deactivating someone blocks them.
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
create function pg_temp.product(p_sku text) returns uuid
language sql security definer as $$
  select id from public.products where sku = p_sku
$$;
create function pg_temp.sign_ins(p_email text) returns integer
language sql security definer as $$
  select count(*)::int from public.log_entries l join public.members m on l.record_id = m.id::text
  where l.action = 'sign_in' and lower(m.email) = lower(p_email)
$$;
create function pg_temp.members_with(p_email text) returns integer
language sql security definer as $$
  select count(*)::int from public.members where lower(email) = lower(p_email)
$$;

select plan(39);

-------------------------------------------------------------------------------
-- The sign-up hook lets anyone in except blocked people
-------------------------------------------------------------------------------
select is(hook_before_user_created('{"user": {"email": "New.Person@example.com"}}'), '{}'::jsonb,
          'a stranger''s email may create an account');
update members set active = false where email = 'cashier2@example.com';
select is(hook_before_user_created('{"user": {"email": "cashier2@example.com"}}') -> 'error' ->> 'http_code', '403',
          'a deactivated member''s email may not');

-------------------------------------------------------------------------------
-- The first sign-in makes a Cashier
-------------------------------------------------------------------------------
select pg_temp.login('new.person@example.com');
select ok(whoami() is null, 'before joining, a new sign-in is nobody');
select ensure_member() as joined \gset
select is(:'joined'::jsonb ->> 'ok', 'true', 'ensure_member succeeds');
select is(:'joined'::jsonb ->> 'joined', 'true', 'and says the member was just created');
select is(:'joined'::jsonb -> 'me' ->> 'role', 'cashier', 'as a Cashier');
select is(whoami() ->> 'display_name', 'new.person', 'named after their email until a Super Admin renames them');
select is(whoami() ->> 'approved', 'false', 'waiting for a Super Admin to approve them');
select is(whoami() -> 'permissions', '[]'::jsonb, 'with no permissions yet');
select ok(not is_member(), 'not counted as a member by read policies');
select is((select count(*)::int from products), 0, 'so they see no catalog');
select throws_like($$ select issue_gift_card('paid') $$, '%Super Admin has to set your PIN%',
                   'and cannot make gift cards');
select throws_ok(format($$ select verify_member_pin(%L, '0000') $$, pg_temp.member('advisor@example.com')),
                 '42501', null, 'or guess an officer''s PIN');
select throws_ok($$ select log_outage_sale(gen_random_uuid(), null, current_date, '[]', 'x.jpg') $$,
                 '42501', null, 'or file outage sales');
select is(ensure_member() ->> 'joined', 'false', 'signing in again does not join twice');
select is(pg_temp.members_with('new.person@example.com'), 1, 'one member row');
select throws_like($$ select set_pin(public.current_member_id(), '1234') $$, '%Super Admin sets your first PIN%',
                   'a new cashier cannot set their own first PIN');
select ok(exists (select 1 from member_directory() where display_name = 'new.person'),
          'the register picker shows the new cashier themselves');
select ok(exists (select 1 from member_directory() where role = 'advisor'), 'and the officers who approve things');
select ok(not exists (select 1 from member_directory() where id = pg_temp.member('cashier@example.com')),
          'but not the other cashiers');
select record_sign_in();
select record_sign_in();
select pg_temp.logout();
select is(pg_temp.sign_ins('new.person@example.com'), 1, 'repeat sign-ins within 10 minutes are logged once');
select pg_temp.login('register@example.com');
select ok(not exists (select 1 from member_directory() where display_name = 'new.person'),
          'the Register''s picker does not show a sign-up waiting for approval');
select pg_temp.logout();
select is((select count(*)::int from log_entries where action = 'member_joined'), 1, 'joining is logged');

-------------------------------------------------------------------------------
-- Password sessions and blocked people don't get in
-------------------------------------------------------------------------------
select pg_temp.login('password.person@example.com', 'password');
select is(ensure_member() ->> 'error', 'not_allowed', 'a password session cannot join');
select pg_temp.logout();
select is(pg_temp.members_with('password.person@example.com'), 0, 'and no member is made');

select pg_temp.login('cashier2@example.com');
select is(ensure_member() ->> 'error', 'blocked', 'a deactivated member is told they were blocked');
select ok(whoami() is null, 'and is nobody');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Only Super Admins manage members
-------------------------------------------------------------------------------
select pg_temp.login('advisor@example.com');
select ok(not can('manage_members'), 'the Advisor no longer manages members');
select throws_ok($$ select * from list_members() $$, '42501', null, 'or lists them');
select pg_temp.logout();

select pg_temp.login('depedros@cppasd.com');
select lives_ok(format($$ select set_pin(%L, '2468') $$, pg_temp.member('new.person@example.com')),
                'a Super Admin sets the new cashier''s first PIN');
select pg_temp.logout();

select pg_temp.login('new.person@example.com');
select is(whoami() ->> 'approved', 'true', 'setting the first PIN approves the new cashier');
select ok(can('ring_sales') and can('sell_gift_cards'), 'who can now ring sales');
select ok(not can('manage_members') and not can('void_refund'), 'but do nothing an officer does');
select lives_ok($$ select set_pin(public.current_member_id(), '1357') $$, 'and can change their own PIN');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Sale lookups only show sales the caller may see
-------------------------------------------------------------------------------
select pg_temp.login('register@example.com');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset
select complete_sale(gen_random_uuid(), :'shift', 'regular',
                     jsonb_build_array(jsonb_build_object('kind', 'product', 'product_id', pg_temp.product('FBLA-0001'), 'qty', 1)),
                     pg_temp.cash(100)) -> 'sale' ->> 'number' as sale_no \gset
select is(find_sale(:'sale_no'::int) ->> 'cashier_name', 'Casey Cashier (test)', 'the Register account looks up any sale');
select pg_temp.logout();
select pg_temp.login('new.person@example.com');
select throws_like(format($$ select find_sale(%s) $$, :'sale_no'), '%No sale%',
                   'a cashier cannot look up a sale from someone else''s shift');
select pg_temp.logout();
select pg_temp.login('cashier@example.com');
select is(find_sale(:'sale_no'::int) ->> 'number', :'sale_no', 'but can look up one from their own shift');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- There is always an active Super Admin
-------------------------------------------------------------------------------
select pg_temp.login('depedros@cppasd.com');
select lives_ok(format($$ select save_member(%L, 'depedroshawn@gmail.com', 'depedroshawn', null, null, false, true) $$,
                       pg_temp.member('depedroshawn@gmail.com')), 'one Super Admin can demote another');
select throws_like(format($$ select save_member(%L, 'depedros@cppasd.com', 'depedros', null, 'president', false, true) $$,
                          pg_temp.member('depedros@cppasd.com')), '%at least one active Super Admin%',
                   'but the last one cannot demote themselves');
select pg_temp.logout();

select * from finish();
rollback;
