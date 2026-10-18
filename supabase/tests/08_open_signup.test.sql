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
create function pg_temp.members_with(p_email text) returns integer
language sql security definer as $$
  select count(*)::int from public.members where lower(email) = lower(p_email)
$$;

select plan(24);

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
select ok(can('ring_sales') and can('sell_gift_cards'), 'who can ring sales');
select ok(not can('manage_members') and not can('void_refund'), 'and nothing an officer does');
select is(ensure_member() ->> 'joined', 'false', 'signing in again does not join twice');
select is(pg_temp.members_with('new.person@example.com'), 1, 'one member row');
select throws_like($$ select set_pin(public.current_member_id(), '1234') $$, '%Super Admin sets your first PIN%',
                   'a new cashier cannot set their own first PIN');
select ok(exists (select 1 from member_directory() where display_name = 'new.person'),
          'the register picker shows the new cashier themselves');
select ok(exists (select 1 from member_directory() where role = 'advisor'), 'and the officers who approve things');
select ok(not exists (select 1 from member_directory() where id = pg_temp.member('cashier@example.com')),
          'but not the other cashiers');
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
select lives_ok($$ select set_pin(public.current_member_id(), '1357') $$, 'after which the cashier can change it');
select pg_temp.logout();

select * from finish();
rollback;
