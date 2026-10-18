-- Open sign-up (the owner's decision, replacing the invite-only member list):
--   1. Anyone with an email can sign in. The before-user-created hook only
--      turns away an email that belongs to a deactivated member, so
--      deactivating someone is the block list.
--   2. ensure_member() makes the signed-in person a Cashier the first time.
--   3. Only Super Admins manage members (the Advisor no longer does).
--   4. A Super Admin sets everyone's first PIN, so a new sign-up can't open a
--      shift until someone has looked at them.
--   5. member_directory shows a plain cashier only themselves and the
--      officers, so a stranger who signs up can't list the chapter's students.

-------------------------------------------------------------------------------
-- 1. Sign-up hook: everyone except blocked emails
-------------------------------------------------------------------------------

create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(coalesce(event -> 'user' ->> 'email', event ->> 'email', ''));
begin
  if v_email <> '' and exists (select 1 from public.members where lower(email) = v_email and not active) then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Your access to the store app was removed. Talk to a Super Admin.'));
  end if;
  return '{}'::jsonb;
end
$$;

-------------------------------------------------------------------------------
-- 2. First sign-in makes a Cashier
-------------------------------------------------------------------------------

-- Called by the app after every sign-in when whoami() is empty. Only an
-- email-code session counts (a password session is nobody, see 0900), and the
-- email comes from the verified token, so nobody can join as someone else.
create function public.ensure_member() returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  m public.members;
begin
  if public.current_member_id() is not null then
    return jsonb_build_object('ok', true, 'joined', false, 'me', public.whoami());
  end if;
  if auth.uid() is null or v_email = ''
     or coalesce(auth.jwt() -> 'amr', '[]'::jsonb) @> '[{"method": "password"}]'::jsonb then
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
                              'message', 'Sign in with the code from your email.');
  end if;

  select * into m from public.members where lower(email) = v_email;
  if found then
    if not m.active then
      return jsonb_build_object('ok', false, 'error', 'blocked',
                                'message', 'Your access to the store app was removed. Talk to a Super Admin.');
    end if;
    -- An active member whose row is tied to a different sign-in account.
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
                              'message', 'This email is tied to another sign-in. Talk to a Super Admin.');
  end if;

  begin
    insert into public.members (email, display_name, role, is_super_admin, active, user_id)
    values (v_email, left(split_part(v_email, '@', 1), 60), 'cashier', false, true, auth.uid())
    returning * into m;
  exception when unique_violation then
    -- Two tabs signing in at once: the other one made the member.
    if public.current_member_id() is not null then
      return jsonb_build_object('ok', true, 'joined', false, 'me', public.whoami());
    end if;
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
                              'message', 'This email is tied to another sign-in. Talk to a Super Admin.');
  end;

  perform private.write_log('member_joined', 'member', m.id::text, null, null,
                            jsonb_build_object('email', m.email, 'role', m.role), null, m.id);
  return jsonb_build_object('ok', true, 'joined', true, 'me', public.whoami());
end
$$;

-------------------------------------------------------------------------------
-- 3. Only Super Admins manage members
-------------------------------------------------------------------------------

create or replace function public.role_can(p_role public.member_role, p_super boolean, p_action text)
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select coalesce(case p_action
    when 'ring_sales'       then p_super or p_role is not null
    when 'sell_gift_cards'  then p_super or p_role is not null
    when 'void_refund'      then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'issue_promo'      then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'edit_products'    then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'stock'            then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'preauth_view'     then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'preauth_request'  then p_role in ('president', 'treasurer')
    when 'preauth_approve'  then p_role = 'advisor'
    when 'preauth_purchase' then p_role in ('advisor', 'president', 'treasurer')
    when 'preauth_close'    then p_role = 'advisor'
    when 'receiving'        then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'verify_outage'    then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'view_reports'     then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'view_log'         then p_super or p_role in ('advisor', 'president', 'treasurer')
    when 'manage_members'   then p_super
    when 'change_settings'  then p_super or p_role = 'advisor'
    else false
  end, false)
$$;

-------------------------------------------------------------------------------
-- 4. A Super Admin sets the first PIN
-------------------------------------------------------------------------------

create or replace function public.set_pin(p_member_id uuid, p_pin text) returns void
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me public.members := private.require_member();
begin
  if p_member_id <> me.id and not public.can('manage_members') then
    raise exception 'Permission denied: manage_members' using errcode = '42501';
  end if;
  if p_member_id = me.id and me.pin_hash is null and not public.can('manage_members') then
    raise exception 'A Super Admin sets your first PIN. After that you can change it here.';
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'A PIN is exactly 4 digits.';
  end if;
  update public.members
     set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8)),
         pin_failed_count = 0,
         pin_locked_until = null,
         pin_lockouts = 0
   where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;
  perform private.write_log('pin_set', 'member', p_member_id::text);
end
$$;

-------------------------------------------------------------------------------
-- 5. The register's people picker
-------------------------------------------------------------------------------

-- The Register account, officers and Super Admins pick any cashier. A plain
-- cashier only needs themselves and the people who approve things.
create or replace function public.member_directory() returns table (
  id uuid, display_name text, role public.member_role, is_super_admin boolean, has_pin boolean
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  v_all boolean := me.is_super_admin or me.role in ('advisor', 'president', 'treasurer', 'register');
begin
  return query
    select m.id, m.display_name, m.role, m.is_super_admin, m.pin_hash is not null
    from public.members m
    where m.active
      and (v_all or m.id = me.id or m.is_super_admin or m.role in ('advisor', 'president', 'treasurer'))
    order by m.display_name;
end
$$;

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
