-- Final review fixes: retried card sales, pasted pages, sign-in links.
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
    json_build_object('sub', v_uid, 'role', 'authenticated', 'email', lower(p_email),
                      'amr', json_build_array(json_build_object('method', 'otp', 'timestamp', 1760000000)))::text,
    true);
  set local role authenticated;
end
$$;
create function pg_temp.claims(p_uid uuid, p_email text) returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'email', lower(p_email),
                      'amr', json_build_array(json_build_object('method', 'otp', 'timestamp', 1760000000)))::text,
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
create function pg_temp.sell_card(p_uuid uuid, p_shift uuid) returns jsonb
language sql as $$
  select complete_sale(p_uuid, p_shift, 'regular',
                       '[{"kind": "gift_card_load", "amount_cents": 2000}]', pg_temp.cash(2000), 2500)
$$;

select plan(18);

-------------------------------------------------------------------------------
-- A retried gift card sale gets its code back
-------------------------------------------------------------------------------
select gen_random_uuid() as cu \gset
select pg_temp.login('register@example.com');
select (open_shift(pg_temp.member('cashier@example.com'), '3333', 5000) ->> 'shift_id') as shift \gset
select r -> 'new_cards' -> 0 ->> 'code' as card, r -> 'sale' ->> 'number' as sale_no
from pg_temp.sell_card(:'cu', :'shift') r \gset

select r ->> 'duplicate' as dup, r -> 'new_cards' -> 0 ->> 'code' as again, r ->> 'change_cents' as change
from pg_temp.sell_card(:'cu', :'shift') r \gset
select is(:'dup'::text, 'true', 'sending the same sale again does not ring it twice');
select is(:'again'::text, :'card', 'and the register gets the new card''s code back');
select is(:'change'::text, '500', 'with the change the server worked out');
select ok(not (find_sale(:'sale_no'::int) ? 'client_uuid'), 'a sale lookup does not show the client id');
select throws_ok($$ select client_uuid from sales $$, '42501', null,
                 'and nobody can read client ids from the sales table');
select lives_ok($$ select id, number, total_cents from sales $$, 'while the rest of a sale still reads');
select pg_temp.logout();
select is((select count(*)::int from sales where client_uuid = :'cu'), 1, 'there is still one sale');
select ok(not has_function_privilege('authenticated',
            'private.complete_sale_core(uuid, uuid, public.sale_type, jsonb, jsonb, bigint, text, text)', 'execute'),
          'members cannot call the sale core directly');

select pg_temp.login('cashier2@example.com');
select is(pg_temp.sell_card(:'cu', :'shift') -> 'new_cards', '[]'::jsonb,
          'someone off that shift who replays the id gets no codes');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select is(pg_temp.sell_card(:'cu', :'shift') -> 'new_cards' -> 0 ->> 'code', :'card',
          'an officer does');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- A pasted page is always read
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select save_vendor_item('{"url": "https://www.samsclub.com/ip/Water/123456789", "name": "Water 40 pk",
                          "units_per_pack": 40, "price_cents": 499, "source": "search"}') is not null as saved \gset
select is(begin_sams_paste('https://www.samsclub.com/ip/Water/123456789') ->> 'cached', 'false',
          'pasting a page for a saved listing reads the page instead of the saved listing');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Sign-in links follow the email
-------------------------------------------------------------------------------
select pg_temp.login('advisor@example.com');
select is(whoami() ->> 'role', 'advisor', 'the Advisor signs in');
select pg_temp.logout();
select id as advisor_uid from auth.users where email = 'advisor@example.com' \gset

select pg_temp.claims(:'advisor_uid', 'someone-else@example.com');
select ok(whoami() is null, 'a token for the Advisor''s account but another email is nobody');
select pg_temp.logout();

-- The account's email is changed to someone else's.
update auth.users set email = 'attacker@evil.example' where id = :'advisor_uid';
select is((select user_id from members where email = 'advisor@example.com'), null::uuid,
          'changing the account''s email unlinks it from the member');
select pg_temp.claims(:'advisor_uid', 'attacker@evil.example');
select ok(whoami() is null, 'so signing in to that account is nobody');
select ok(not can('manage_members'), 'with no permissions');
select pg_temp.logout();

select pg_temp.login('advisor@example.com');
select is(whoami() ->> 'role', 'advisor', 'the real Advisor signs in to a new account');
select pg_temp.logout();
select isnt((select user_id from members where email = 'advisor@example.com'), :'advisor_uid'::uuid,
            'which is now the linked one');

select * from finish();
rollback;
