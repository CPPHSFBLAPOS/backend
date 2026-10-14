-- Phase 1: Foundation
-- members, settings, categories, products, price history, the stock ledger,
-- the append-only transaction log, roles and the permission check every RLS
-- policy and RPC uses, and the Base44 import entry points.
--
-- Rules (see CLAUDE.md):
--   * Money is integer cents in bigint columns.
--   * The browser never writes tables. Every change is a security definer RPC
--     that checks the caller's role and writes its log_entries row in the
--     same transaction.
--   * RLS is on for every table and denies by default (no write policies).

create extension if not exists pgcrypto with schema extensions;

-- Internal helpers live in a schema the API does not expose.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

create type public.member_role as enum ('advisor', 'president', 'treasurer', 'cashier', 'register');

create type public.movement_type as enum (
  'sale',
  'refund_to_shelf',
  'void',
  'receiving',
  'opening_balance',
  'count_adjustment',
  'damaged',
  'expired',
  'missing',
  'found',
  'import_adjustment'
);

-------------------------------------------------------------------------------
-- Generic guards
-------------------------------------------------------------------------------

create function private.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception '% is append-only: % is not allowed', tg_table_name, tg_op
    using errcode = '42501';
end
$$;

create function private.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- Today's date in the store's time zone. School-day logic uses local dates.
create function private.local_today() returns date
language sql stable as $$
  select (now() at time zone 'America/New_York')::date
$$;

create function private.local_date(ts timestamptz) returns date
language sql stable as $$
  select (ts at time zone 'America/New_York')::date
$$;

-------------------------------------------------------------------------------
-- Members
-------------------------------------------------------------------------------

create table public.members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users (id) on delete set null,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  display_name text not null check (length(btrim(display_name)) > 0),
  grade smallint check (grade between 6 and 12),
  role public.member_role,
  is_super_admin boolean not null default false,
  pin_hash text,
  pin_failed_count smallint not null default 0,
  pin_locked_until timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index members_email_key on public.members (lower(email));
create trigger members_touch before update on public.members
  for each row execute function private.touch_updated_at();

-- The member row for the signed-in user. Falls back to the verified email in
-- the token when the auth user has not been linked yet.
create function public.current_member_id() returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select m.id
  from public.members m
  where m.active
    and (
      m.user_id = auth.uid()
      or (m.user_id is null and auth.uid() is not null
          and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    )
  order by (m.user_id = auth.uid()) desc nulls last
  limit 1
$$;

create function public.is_member() returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select public.current_member_id() is not null
$$;

-- The permission matrix from the spec's "Roles and permissions" section.
-- A Super Admin's own role still decides what they can sign.
create function public.role_can(p_role public.member_role, p_super boolean, p_action text)
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
    when 'manage_members'   then p_super or p_role = 'advisor'
    when 'change_settings'  then p_super or p_role = 'advisor'
    else false
  end, false)
$$;

create function public.permission_actions() returns text[]
language sql immutable
as $$
  select array[
    'ring_sales', 'sell_gift_cards', 'void_refund', 'issue_promo', 'edit_products', 'stock',
    'preauth_view', 'preauth_request', 'preauth_approve', 'preauth_purchase', 'preauth_close',
    'receiving', 'verify_outage', 'view_reports', 'view_log', 'manage_members', 'change_settings'
  ]
$$;

-- "Can the current user do this action?" Every RLS policy and RPC uses it.
-- The service role (scheduled jobs, the import script) acts as the system.
create function public.can(p_action text) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(auth.role() = 'service_role', false)
      or coalesce((
           select public.role_can(m.role, m.is_super_admin, p_action)
           from public.members m
           where m.id = public.current_member_id()
         ), false)
$$;

create function private.member_can(p_member_id uuid, p_action text) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select public.role_can(m.role, m.is_super_admin, p_action)
    from public.members m
    where m.id = p_member_id and m.active
  ), false)
$$;

create function private.require(p_action text) returns void
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.can(p_action) then
    if public.current_member_id() is null and coalesce(auth.role(), '') <> 'service_role' then
      raise exception 'Not a member. Ask the Advisor to add you.' using errcode = '42501';
    end if;
    raise exception 'Permission denied: %', p_action using errcode = '42501';
  end if;
end
$$;

create function private.require_member() returns public.members
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v public.members;
begin
  select * into v from public.members where id = public.current_member_id();
  if not found then
    raise exception 'Not a member. Ask the Advisor to add you.' using errcode = '42501';
  end if;
  return v;
end
$$;

-------------------------------------------------------------------------------
-- Settings and categories
-------------------------------------------------------------------------------

create table public.settings (
  id smallint primary key default 1 check (id = 1),
  store_name text not null default 'CPPHS FBLA Store',
  float_cents bigint not null default 5000 check (float_cents >= 0),
  over_short_tolerance_cents bigint not null default 100 check (over_short_tolerance_cents >= 0),
  preauth_limit_cents bigint not null default 30000 check (preauth_limit_cents > 0),
  preauth_warn_cents bigint not null default 2000 check (preauth_warn_cents >= 0),
  receipt_due_days integer not null default 5 check (receipt_due_days > 0),
  school_year_start date not null default date '2026-09-01',
  open_days date[] not null default '{}',
  sams_daily_limit integer not null default 30 check (sams_daily_limit >= 0),
  sams_cache_days integer not null default 7 check (sams_cache_days >= 0),
  updated_at timestamptz not null default now()
);
insert into public.settings default values;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index categories_name_key on public.categories (lower(name));

-------------------------------------------------------------------------------
-- Products, prices, stock ledger
-------------------------------------------------------------------------------

create sequence public.product_sku_seq;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique default ('FBLA-' || lpad(nextval('public.product_sku_seq')::text, 4, '0')),
  upc text unique check (upc is null or upc ~ '^[0-9A-Za-z-]{4,32}$'),
  name text not null check (length(btrim(name)) > 0),
  description text,
  category_id uuid references public.categories (id),
  price_cents bigint not null check (price_cents >= 0),
  avg_cost_cents bigint check (avg_cost_cents >= 0),
  cost_status text generated always as (case when avg_cost_cents is null then 'missing' else 'known' end) stored,
  low_stock_alert integer not null default 5 check (low_stock_alert >= 0),
  image_path text,
  smart_snack boolean not null default false,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger products_touch before update on public.products
  for each row execute function private.touch_updated_at();

create table public.price_changes (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products (id),
  old_cents bigint,
  new_cents bigint not null,
  by uuid references public.members (id),
  at timestamptz not null default now()
);
create index price_changes_product_idx on public.price_changes (product_id, at desc);

create table public.stock_movements (
  id bigint generated always as identity primary key,
  product_id uuid not null references public.products (id),
  qty integer not null check (qty <> 0),
  type public.movement_type not null,
  unit_cost_cents bigint check (unit_cost_cents >= 0),
  source_type text,
  source_id text,
  reason text,
  by uuid references public.members (id),
  at timestamptz not null default now()
);
create index stock_movements_product_idx on public.stock_movements (product_id);
create index stock_movements_at_idx on public.stock_movements (at);

create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function private.forbid_change();
create trigger price_changes_append_only before update or delete on public.price_changes
  for each row execute function private.forbid_change();

-- Stock on hand is the sum of the ledger. There is no editable stock column.
create view public.product_stock with (security_invoker = true) as
  select p.id as product_id, coalesce(sum(m.qty), 0)::integer as on_hand
  from public.products p
  left join public.stock_movements m on m.product_id = p.id
  group by p.id;

create function private.on_hand(p_product_id uuid) returns integer
language sql stable
as $$
  select coalesce(sum(qty), 0)::integer from public.stock_movements where product_id = p_product_id
$$;

-------------------------------------------------------------------------------
-- Stock counts
-------------------------------------------------------------------------------

create table public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('quick', 'full')),
  status text not null default 'open' check (status in ('open', 'approved', 'cancelled')),
  started_by uuid not null references public.members (id),
  started_at timestamptz not null default now(),
  approved_by uuid references public.members (id),
  approved_at timestamptz,
  note text
);

create table public.stock_count_lines (
  count_id uuid not null references public.stock_counts (id),
  product_id uuid not null references public.products (id),
  expected integer not null,
  counted integer check (counted >= 0),
  counted_by uuid references public.members (id),
  counted_at timestamptz,
  primary key (count_id, product_id)
);

-------------------------------------------------------------------------------
-- Legacy Base44 sales history (read-only after import)
-------------------------------------------------------------------------------

create table public.legacy_sales (
  id bigint generated always as identity primary key,
  sold_at timestamptz not null,
  product_id uuid references public.products (id),
  product_name text,
  sku text,
  qty integer not null default 1,
  unit_price_cents bigint,
  total_cents bigint not null,
  -- Base44's old customer field is kept here as a note, never as a name.
  note text,
  source_key text not null unique,
  imported_at timestamptz not null default now(),
  imported_by uuid references public.members (id)
);
create index legacy_sales_sold_at_idx on public.legacy_sales (sold_at);
create trigger legacy_sales_append_only before update or delete on public.legacy_sales
  for each row execute function private.forbid_change();

-------------------------------------------------------------------------------
-- Transaction log: append-only, hash-chained
-------------------------------------------------------------------------------

create table public.log_entries (
  seq bigint primary key,
  at timestamptz not null default now(),
  actor_id uuid references public.members (id),
  role text,
  device text,
  action text not null,
  record_type text,
  record_id text,
  amount_cents bigint,
  before jsonb,
  after jsonb,
  reason text,
  prev_hash text,
  hash text not null
);
create index log_entries_at_idx on public.log_entries (at);
create index log_entries_action_idx on public.log_entries (action);
create index log_entries_actor_idx on public.log_entries (actor_id);
create index log_entries_record_idx on public.log_entries (record_type, record_id);

-- The canonical form of an entry that its hash covers. Times are hashed as
-- epoch microseconds so the hash does not depend on the session time zone.
create function public.log_entry_hash(e public.log_entries) returns text
language sql immutable
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to(
    coalesce(e.prev_hash, '') || jsonb_build_object(
      'seq', e.seq,
      'at', (extract(epoch from e.at) * 1000000)::bigint,
      'actor_id', e.actor_id,
      'role', e.role,
      'device', e.device,
      'action', e.action,
      'record_type', e.record_type,
      'record_id', e.record_id,
      'amount_cents', e.amount_cents,
      'before', e.before,
      'after', e.after,
      'reason', e.reason
    )::text, 'UTF8')), 'hex')
$$;

create function private.log_entries_chain() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_last record;
begin
  -- One writer at a time so seq and the chain stay in order.
  perform pg_advisory_xact_lock(hashtext('public.log_entries'));
  select seq, hash into v_last from public.log_entries order by seq desc limit 1;
  new.seq := coalesce(v_last.seq, 0) + 1;
  new.prev_hash := v_last.hash;
  new.at := clock_timestamp();
  new.hash := public.log_entry_hash(new);
  return new;
end
$$;

create trigger log_entries_chain before insert on public.log_entries
  for each row execute function private.log_entries_chain();
create trigger log_entries_append_only before update or delete on public.log_entries
  for each row execute function private.forbid_change();
create trigger log_entries_no_truncate before truncate on public.log_entries
  for each statement execute function private.forbid_change();

-- Device name sent by the app in the x-fbla-device header (PostgREST exposes
-- request headers as a setting).
create function private.request_device() returns text
language plpgsql stable
as $$
declare
  v text;
begin
  v := nullif(current_setting('request.headers', true), '');
  if v is null then
    return null;
  end if;
  return left(coalesce(v::jsonb ->> 'x-fbla-device', v::jsonb ->> 'user-agent'), 120);
exception when others then
  return null;
end
$$;

create function private.write_log(
  p_action text,
  p_record_type text,
  p_record_id text,
  p_amount_cents bigint default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_reason text default null,
  p_actor_id uuid default null
) returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := coalesce(p_actor_id, public.current_member_id());
  v_role text;
  v_seq bigint;
begin
  if v_actor is not null then
    select coalesce(m.role::text, case when m.is_super_admin then 'super_admin' end)
      into v_role from public.members m where m.id = v_actor;
  elsif coalesce(auth.role(), '') = 'service_role' then
    v_role := 'system';
  end if;

  insert into public.log_entries (actor_id, role, device, action, record_type, record_id,
                                  amount_cents, before, after, reason)
  values (v_actor, v_role, private.request_device(), p_action, p_record_type, p_record_id,
          p_amount_cents, p_before, p_after, p_reason)
  returning seq into v_seq;
  return v_seq;
end
$$;

-------------------------------------------------------------------------------
-- PINs
-------------------------------------------------------------------------------

-- Returns 'ok', 'wrong', 'locked', 'no_pin' or 'inactive'. Callers must not
-- raise after a failed check, or the failed-try counter would roll back.
create function private.check_pin(p_member_id uuid, p_pin text) returns text
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  m public.members;
  v_fails integer;
begin
  select * into m from public.members where id = p_member_id for update;
  if not found or not m.active then
    return 'inactive';
  end if;
  if m.pin_hash is null then
    return 'no_pin';
  end if;
  if m.pin_locked_until is not null and m.pin_locked_until > now() then
    return 'locked';
  end if;
  if p_pin is not null and extensions.crypt(p_pin, m.pin_hash) = m.pin_hash then
    if m.pin_failed_count <> 0 or m.pin_locked_until is not null then
      update public.members set pin_failed_count = 0, pin_locked_until = null where id = m.id;
    end if;
    return 'ok';
  end if;

  v_fails := m.pin_failed_count + 1;
  if v_fails >= 5 then
    update public.members
       set pin_failed_count = 0, pin_locked_until = now() + interval '5 minutes'
     where id = m.id;
    perform private.write_log('pin_locked', 'member', m.id::text, null, null, null,
                              '5 wrong PIN tries', m.id);
    return 'locked';
  end if;
  update public.members set pin_failed_count = v_fails where id = m.id;
  return 'wrong';
end
$$;

create function private.pin_error(p_result text) returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'ok', false,
    'error', 'pin_' || p_result,
    'message', case p_result
      when 'wrong' then 'Wrong PIN.'
      when 'locked' then 'Too many wrong tries. That PIN is locked for 5 minutes.'
      when 'no_pin' then 'That person has no PIN yet. Ask the Advisor to set one.'
      else 'That person is not an active member.'
    end)
$$;

-------------------------------------------------------------------------------
-- Auth: link members to auth users; only listed emails get in
-------------------------------------------------------------------------------

create function private.link_auth_user() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update public.members
     set user_id = new.id
   where user_id is null
     and new.email is not null
     and lower(email) = lower(new.email);
  return new;
end
$$;

create trigger on_auth_user_created after insert or update of email on auth.users
  for each row execute function private.link_auth_user();

-- Supabase Auth "before user created" hook: anyone not on the member list is
-- turned away before an account is made. Enabled in supabase/config.toml.
create function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(coalesce(event -> 'user' ->> 'email', event ->> 'email', ''));
begin
  if v_email = '' then
    return '{}'::jsonb;
  end if;
  if exists (select 1 from public.members where lower(email) = v_email and active) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Ask the Advisor to add you.'));
end
$$;

-------------------------------------------------------------------------------
-- RPC: identity, members, PINs
-------------------------------------------------------------------------------

create function private.member_json(m public.members) returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'id', m.id,
    'email', m.email,
    'display_name', m.display_name,
    'grade', m.grade,
    'role', m.role,
    'is_super_admin', m.is_super_admin,
    'active', m.active,
    'has_pin', m.pin_hash is not null,
    'linked', m.user_id is not null
  )
$$;

-- The signed-in member and what they may do, or null for a non-member.
create function public.whoami() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  m public.members;
begin
  select * into m from public.members where id = public.current_member_id();
  if not found then
    return null;
  end if;
  return private.member_json(m) || jsonb_build_object(
    'permissions', (
      select coalesce(jsonb_agg(a), '[]'::jsonb)
      from unnest(public.permission_actions()) a
      where public.role_can(m.role, m.is_super_admin, a)
    ));
end
$$;

create function public.record_sign_in() returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  m public.members := private.require_member();
begin
  if m.user_id is null then
    update public.members set user_id = auth.uid() where id = m.id;
  end if;
  perform private.write_log('sign_in', 'member', m.id::text);
end
$$;

-- Names and roles for pickers (cashier list, signers). No emails.
create function public.member_directory() returns table (
  id uuid, display_name text, role public.member_role, is_super_admin boolean, has_pin boolean
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_member();
  return query
    select m.id, m.display_name, m.role, m.is_super_admin, m.pin_hash is not null
    from public.members m
    where m.active
    order by m.display_name;
end
$$;

create function public.list_members() returns setof jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('manage_members');
  return query
    select private.member_json(m) from public.members m order by m.active desc, m.display_name;
end
$$;

create function public.save_member(
  p_id uuid,
  p_email text,
  p_display_name text,
  p_grade integer default null,
  p_role public.member_role default null,
  p_is_super_admin boolean default false,
  p_active boolean default true
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members;
  old public.members;
  v_id uuid;
  v_after public.members;
begin
  perform private.require('manage_members');
  select * into me from public.members where id = public.current_member_id();

  if p_id is null then
    if coalesce(p_is_super_admin, false) and not coalesce(me.is_super_admin, false)
       and coalesce(auth.role(), '') <> 'service_role' then
      raise exception 'Only a Super Admin can grant Super Admin.' using errcode = '42501';
    end if;
    insert into public.members (email, display_name, grade, role, is_super_admin, active)
    values (btrim(p_email), btrim(p_display_name), p_grade, p_role,
            coalesce(p_is_super_admin, false), coalesce(p_active, true))
    returning id into v_id;
  else
    select * into old from public.members where id = p_id for update;
    if not found then
      raise exception 'Member not found.';
    end if;
    if old.is_super_admin is distinct from coalesce(p_is_super_admin, false)
       and not coalesce(me.is_super_admin, false)
       and coalesce(auth.role(), '') <> 'service_role' then
      raise exception 'Only a Super Admin can change the Super Admin flag.' using errcode = '42501';
    end if;
    if p_id = me.id and not coalesce(p_active, true) then
      raise exception 'You cannot deactivate yourself.';
    end if;
    update public.members
       set email = btrim(p_email),
           display_name = btrim(p_display_name),
           grade = p_grade,
           role = p_role,
           is_super_admin = coalesce(p_is_super_admin, false),
           active = coalesce(p_active, true),
           user_id = case when lower(old.email) = lower(btrim(p_email)) then user_id end
     where id = p_id;
    v_id := p_id;
  end if;

  -- Link to an existing auth account with this email, if there is one.
  update public.members m
     set user_id = u.id
    from auth.users u
   where m.id = v_id and m.user_id is null and lower(u.email) = lower(m.email)
     and not exists (select 1 from public.members o where o.user_id = u.id);

  select * into v_after from public.members where id = v_id;
  perform private.write_log(
    case when p_id is null then 'member_added'
         when old.role is distinct from v_after.role then 'member_role_changed'
         else 'member_updated' end,
    'member', v_id::text, null,
    case when p_id is null then null else private.member_json(old) end,
    private.member_json(v_after));
  return v_id;
end
$$;

-- Set or reset a 4-digit PIN. Admins can set anyone's; members can set their own.
create function public.set_pin(p_member_id uuid, p_pin text) returns void
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me public.members := private.require_member();
begin
  if p_member_id <> me.id and not public.can('manage_members') then
    raise exception 'Permission denied: manage_members' using errcode = '42501';
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'A PIN is exactly 4 digits.';
  end if;
  update public.members
     set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8)),
         pin_failed_count = 0,
         pin_locked_until = null
   where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;
  perform private.write_log('pin_set', 'member', p_member_id::text);
end
$$;

-- Check a PIN without doing anything else (used by the register to confirm a
-- cashier before showing their screen).
create function public.verify_member_pin(p_member_id uuid, p_pin text) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  perform private.require('ring_sales');
  v := private.check_pin(p_member_id, p_pin);
  if v <> 'ok' then
    return private.pin_error(v);
  end if;
  return jsonb_build_object('ok', true);
end
$$;

-------------------------------------------------------------------------------
-- RPC: settings and categories
-------------------------------------------------------------------------------

create function public.save_settings(p jsonb) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  old public.settings;
  v_after public.settings;
begin
  perform private.require('change_settings');
  select * into old from public.settings where id = 1 for update;
  update public.settings set
    store_name = coalesce(p ->> 'store_name', store_name),
    float_cents = coalesce((p ->> 'float_cents')::bigint, float_cents),
    over_short_tolerance_cents = coalesce((p ->> 'over_short_tolerance_cents')::bigint, over_short_tolerance_cents),
    preauth_limit_cents = coalesce((p ->> 'preauth_limit_cents')::bigint, preauth_limit_cents),
    preauth_warn_cents = coalesce((p ->> 'preauth_warn_cents')::bigint, preauth_warn_cents),
    receipt_due_days = coalesce((p ->> 'receipt_due_days')::integer, receipt_due_days),
    school_year_start = coalesce((p ->> 'school_year_start')::date, school_year_start),
    open_days = coalesce(
      (select array_agg(d::date order by d::date) from jsonb_array_elements_text(p -> 'open_days') d),
      case when p ? 'open_days' then '{}'::date[] end,
      open_days),
    sams_daily_limit = coalesce((p ->> 'sams_daily_limit')::integer, sams_daily_limit),
    sams_cache_days = coalesce((p ->> 'sams_cache_days')::integer, sams_cache_days),
    updated_at = now()
  where id = 1;
  select * into v_after from public.settings where id = 1;
  perform private.write_log('settings_changed', 'settings', '1', null,
                            to_jsonb(old) - 'updated_at', to_jsonb(v_after) - 'updated_at');
end
$$;

create function public.save_category(p_id uuid, p_name text, p_sort_order integer default 0,
                                     p_active boolean default true)
returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  old public.categories;
  v_id uuid;
begin
  perform private.require('edit_products');
  if p_id is null then
    insert into public.categories (name, sort_order, active)
    values (btrim(p_name), coalesce(p_sort_order, 0), coalesce(p_active, true))
    returning id into v_id;
  else
    select * into old from public.categories where id = p_id for update;
    if not found then
      raise exception 'Category not found.';
    end if;
    update public.categories
       set name = btrim(p_name), sort_order = coalesce(p_sort_order, 0), active = coalesce(p_active, true)
     where id = p_id;
    v_id := p_id;
  end if;
  perform private.write_log(case when p_id is null then 'category_added' else 'category_updated' end,
    'category', v_id::text, null, to_jsonb(old),
    (select to_jsonb(c) from public.categories c where c.id = v_id));
  return v_id;
end
$$;

-------------------------------------------------------------------------------
-- RPC: products and prices
-------------------------------------------------------------------------------

create function private.change_price(p_product_id uuid, p_new_cents bigint) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old bigint;
begin
  if p_new_cents is null or p_new_cents < 0 then
    raise exception 'Price must be zero or more.';
  end if;
  select price_cents into v_old from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.';
  end if;
  if v_old = p_new_cents then
    return;
  end if;
  update public.products set price_cents = p_new_cents where id = p_product_id;
  insert into public.price_changes (product_id, old_cents, new_cents, by)
  values (p_product_id, v_old, p_new_cents, public.current_member_id());
  perform private.write_log('price_changed', 'product', p_product_id::text, p_new_cents,
                            jsonb_build_object('price_cents', v_old),
                            jsonb_build_object('price_cents', p_new_cents));
end
$$;

create function public.change_price(p_product_id uuid, p_new_cents bigint) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('edit_products');
  perform private.change_price(p_product_id, p_new_cents);
end
$$;

create function public.save_product(
  p_id uuid,
  p_name text,
  p_category_id uuid,
  p_price_cents bigint,
  p_upc text default null,
  p_low_stock_alert integer default 5,
  p_smart_snack boolean default false,
  p_image_path text default null,
  p_description text default null
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  old public.products;
  v_id uuid;
begin
  perform private.require('edit_products');
  if p_id is null then
    insert into public.products (name, category_id, price_cents, upc, low_stock_alert,
                                 smart_snack, image_path, description)
    values (btrim(p_name), p_category_id, p_price_cents, nullif(btrim(p_upc), ''),
            coalesce(p_low_stock_alert, 5), coalesce(p_smart_snack, false),
            nullif(p_image_path, ''), nullif(btrim(p_description), ''))
    returning id into v_id;
    insert into public.price_changes (product_id, old_cents, new_cents, by)
    values (v_id, null, p_price_cents, public.current_member_id());
    perform private.write_log('product_added', 'product', v_id::text, p_price_cents, null,
      (select to_jsonb(p) from public.products p where p.id = v_id));
  else
    select * into old from public.products where id = p_id for update;
    if not found then
      raise exception 'Product not found.';
    end if;
    update public.products
       set name = btrim(p_name),
           category_id = p_category_id,
           upc = nullif(btrim(p_upc), ''),
           low_stock_alert = coalesce(p_low_stock_alert, 5),
           smart_snack = coalesce(p_smart_snack, false),
           image_path = nullif(p_image_path, ''),
           description = nullif(btrim(p_description), '')
     where id = p_id;
    perform private.change_price(p_id, p_price_cents);
    v_id := p_id;
    perform private.write_log('product_updated', 'product', v_id::text, null,
      to_jsonb(old) - 'updated_at',
      (select to_jsonb(p) - 'updated_at' from public.products p where p.id = v_id));
  end if;
  return v_id;
end
$$;

create function public.archive_product(p_product_id uuid, p_archive boolean default true) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('edit_products');
  update public.products
     set status = case when p_archive then 'archived' else 'active' end
   where id = p_product_id;
  if not found then
    raise exception 'Product not found.';
  end if;
  perform private.write_log(case when p_archive then 'product_archived' else 'product_restored' end,
                            'product', p_product_id::text);
end
$$;

-- Officers can enter a known cost for a product that shows "Cost missing".
-- Receiving keeps it current after that.
create function public.set_product_cost(p_product_id uuid, p_cost_cents bigint, p_reason text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_old bigint;
begin
  perform private.require('edit_products');
  if p_cost_cents is null or p_cost_cents < 0 then
    raise exception 'Cost must be zero or more.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reason is required.';
  end if;
  select avg_cost_cents into v_old from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.';
  end if;
  update public.products set avg_cost_cents = p_cost_cents where id = p_product_id;
  perform private.write_log('cost_set', 'product', p_product_id::text, p_cost_cents,
                            jsonb_build_object('avg_cost_cents', v_old),
                            jsonb_build_object('avg_cost_cents', p_cost_cents), p_reason);
end
$$;

-------------------------------------------------------------------------------
-- RPC: stock
-------------------------------------------------------------------------------

create function private.post_movement(
  p_product_id uuid,
  p_qty integer,
  p_type public.movement_type,
  p_unit_cost_cents bigint,
  p_source_type text,
  p_source_id text,
  p_reason text,
  p_actor_id uuid default null
) returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  insert into public.stock_movements (product_id, qty, type, unit_cost_cents, source_type, source_id,
                                      reason, by)
  values (p_product_id, p_qty, p_type, p_unit_cost_cents, p_source_type, p_source_id, p_reason,
          coalesce(p_actor_id, public.current_member_id()))
  returning id into v_id;
  perform private.write_log('stock_' || p_type::text, 'product', p_product_id::text,
    case when p_unit_cost_cents is null then null else p_unit_cost_cents * p_qty end,
    null,
    jsonb_build_object('movement_id', v_id, 'qty', p_qty, 'unit_cost_cents', p_unit_cost_cents,
                       'source_type', p_source_type, 'source_id', p_source_id),
    p_reason, p_actor_id);
  return v_id;
end
$$;

create function public.adjust_stock(p_product_id uuid, p_qty integer, p_type public.movement_type,
                                    p_reason text default null)
returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_cost bigint;
  v_qty integer;
  v_on_hand integer;
begin
  perform private.require('stock');
  if p_qty is null or p_qty = 0 then
    raise exception 'Quantity must not be zero.';
  end if;
  v_qty := case
    when p_type in ('damaged', 'expired', 'missing') then -abs(p_qty)
    when p_type = 'found' then abs(p_qty)
    when p_type = 'count_adjustment' then p_qty
    else null
  end;
  if v_qty is null then
    raise exception 'Use Damaged, Expired, Missing, Found or Count correction.';
  end if;
  select avg_cost_cents into v_cost from public.products where id = p_product_id for update;
  if not found then
    raise exception 'Product not found.';
  end if;
  v_on_hand := private.on_hand(p_product_id);
  if v_on_hand + v_qty < 0 then
    raise exception 'Only % on hand.', v_on_hand;
  end if;
  perform private.post_movement(p_product_id, v_qty, p_type, v_cost, 'adjustment', null,
                                nullif(btrim(p_reason), ''));
  return v_on_hand + v_qty;
end
$$;

create function public.start_count(p_kind text, p_note text default null) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  perform private.require('stock');
  if p_kind not in ('quick', 'full') then
    raise exception 'A count is quick or full.';
  end if;
  insert into public.stock_counts (kind, started_by, note)
  values (p_kind, public.current_member_id(), p_note)
  returning id into v_id;

  if p_kind = 'full' then
    insert into public.stock_count_lines (count_id, product_id, expected)
    select v_id, p.id, private.on_hand(p.id)
    from public.products p where p.status = 'active';
  else
    -- The 10 fastest sellers over the last 30 days (by stock leaving on sales).
    insert into public.stock_count_lines (count_id, product_id, expected)
    select v_id, p.id, private.on_hand(p.id)
    from public.products p
    left join lateral (
      select coalesce(-sum(m.qty), 0) as sold
      from public.stock_movements m
      where m.product_id = p.id and m.type = 'sale' and m.at > now() - interval '30 days'
    ) s on true
    where p.status = 'active'
    order by s.sold desc, p.name
    limit 10;
  end if;

  perform private.write_log('count_started', 'stock_count', v_id::text, null, null,
                            jsonb_build_object('kind', p_kind));
  return v_id;
end
$$;

create function public.save_count_line(p_count_id uuid, p_product_id uuid, p_counted integer)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('stock');
  if not exists (select 1 from public.stock_counts where id = p_count_id and status = 'open') then
    raise exception 'That count is not open.';
  end if;
  if p_counted is not null and p_counted < 0 then
    raise exception 'Counts are zero or more.';
  end if;
  update public.stock_count_lines
     set counted = p_counted, counted_by = public.current_member_id(), counted_at = now()
   where count_id = p_count_id and product_id = p_product_id;
  if not found then
    raise exception 'That product is not on this count.';
  end if;
end
$$;

-- Approving posts a Count adjustment for every counted line that differs
-- from what was expected when the count started.
create function public.approve_count(p_count_id uuid) returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  c public.stock_counts;
  l record;
  v_n integer := 0;
begin
  perform private.require('stock');
  select * into c from public.stock_counts where id = p_count_id for update;
  if not found or c.status <> 'open' then
    raise exception 'That count is not open.';
  end if;
  if exists (select 1 from public.stock_count_lines where count_id = p_count_id and counted is null) then
    raise exception 'Every line needs a count before approving.';
  end if;
  for l in
    select scl.*, p.avg_cost_cents
    from public.stock_count_lines scl
    join public.products p on p.id = scl.product_id
    where scl.count_id = p_count_id and scl.counted <> scl.expected
  loop
    perform private.post_movement(l.product_id, l.counted - l.expected, 'count_adjustment',
                                  l.avg_cost_cents, 'stock_count', p_count_id::text, 'Count');
    v_n := v_n + 1;
  end loop;
  update public.stock_counts
     set status = 'approved', approved_by = public.current_member_id(), approved_at = now()
   where id = p_count_id;
  perform private.write_log('count_approved', 'stock_count', p_count_id::text, null, null,
                            jsonb_build_object('adjustments', v_n));
  return v_n;
end
$$;

create function public.cancel_count(p_count_id uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('stock');
  update public.stock_counts set status = 'cancelled' where id = p_count_id and status = 'open';
  if not found then
    raise exception 'That count is not open.';
  end if;
  perform private.write_log('count_cancelled', 'stock_count', p_count_id::text);
end
$$;

-------------------------------------------------------------------------------
-- RPC: Base44 import
-------------------------------------------------------------------------------

-- rows: [{name, sku, category, price_cents, cost_cents, stock, image_url, description}]
-- Products whose SKU already exists are skipped, so running it twice is safe.
create function public.import_products(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r jsonb;
  v_cat uuid;
  v_id uuid;
  v_sku text;
  v_stock integer;
  v_added integer := 0;
  v_skipped integer := 0;
begin
  perform private.require('edit_products');
  perform private.require('stock');
  for r in select * from jsonb_array_elements(p_rows) loop
    v_sku := nullif(btrim(r ->> 'sku'), '');
    if v_sku is not null and exists (select 1 from public.products where sku = v_sku) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    if coalesce(btrim(r ->> 'name'), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      select id into v_cat from public.categories where lower(name) = lower(btrim(r ->> 'category'));
      if v_cat is null then
        insert into public.categories (name) values (btrim(r ->> 'category')) returning id into v_cat;
      end if;
    end if;

    insert into public.products (sku, name, category_id, price_cents, avg_cost_cents, image_path, description)
    values (coalesce(v_sku, 'FBLA-' || lpad(nextval('public.product_sku_seq')::text, 4, '0')),
            btrim(r ->> 'name'), v_cat, coalesce((r ->> 'price_cents')::bigint, 0),
            (r ->> 'cost_cents')::bigint, nullif(r ->> 'image_url', ''), nullif(r ->> 'description', ''))
    returning id into v_id;
    insert into public.price_changes (product_id, old_cents, new_cents, by)
    values (v_id, null, coalesce((r ->> 'price_cents')::bigint, 0), public.current_member_id());

    v_stock := coalesce((r ->> 'stock')::numeric, 0)::integer;
    if v_stock > 0 then
      perform private.post_movement(v_id, v_stock, 'opening_balance', (r ->> 'cost_cents')::bigint,
                                    'import', 'base44', 'Base44 import');
    end if;
    v_added := v_added + 1;
  end loop;

  perform private.write_log('import_products', 'import', 'base44', null, null,
                            jsonb_build_object('added', v_added, 'skipped', v_skipped));
  return jsonb_build_object('added', v_added, 'skipped', v_skipped);
end
$$;

-- rows: [{sold_at, product_name, sku, qty, unit_price_cents, total_cents, note, source_key}]
create function public.import_legacy_sales(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_added integer;
  v_total integer;
begin
  perform private.require('edit_products');
  v_total := jsonb_array_length(p_rows);
  with ins as (
    insert into public.legacy_sales (sold_at, product_id, product_name, sku, qty, unit_price_cents,
                                     total_cents, note, source_key, imported_by)
    select (r ->> 'sold_at')::timestamptz,
           (select p.id from public.products p
             where (nullif(r ->> 'sku', '') is not null and p.sku = r ->> 'sku')
                or lower(p.name) = lower(r ->> 'product_name')
             order by (p.sku = r ->> 'sku') desc nulls last limit 1),
           r ->> 'product_name',
           nullif(r ->> 'sku', ''),
           coalesce((r ->> 'qty')::numeric, 1)::integer,
           (r ->> 'unit_price_cents')::bigint,
           (r ->> 'total_cents')::bigint,
           nullif(r ->> 'note', ''),
           coalesce(nullif(r ->> 'source_key', ''), md5(r::text)),
           public.current_member_id()
    from jsonb_array_elements(p_rows) r
    where (r ->> 'sold_at') is not null and (r ->> 'total_cents') is not null
    on conflict (source_key) do nothing
    returning 1
  )
  select count(*) into v_added from ins;

  perform private.write_log('import_legacy_sales', 'import', 'base44', null, null,
                            jsonb_build_object('added', v_added, 'skipped', v_total - v_added));
  return jsonb_build_object('added', v_added, 'skipped', v_total - v_added);
end
$$;

-------------------------------------------------------------------------------
-- RPC: transaction log check
-------------------------------------------------------------------------------

-- Rechecks the numbering and the hash chain from the first entry.
create function public.verify_log() returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  e public.log_entries;
  v_expected_seq bigint := 1;
  v_prev_hash text := null;
  v_checked bigint := 0;
  v_problem text := null;
  v_bad_seq bigint := null;
begin
  perform private.require('view_log');
  for e in select * from public.log_entries order by seq loop
    if e.seq <> v_expected_seq then
      v_problem := format('Entry numbers jump from %s to %s.', v_expected_seq - 1, e.seq);
      v_bad_seq := e.seq;
      exit;
    end if;
    if e.prev_hash is distinct from v_prev_hash then
      v_problem := format('Entry %s does not point at the hash of entry %s.', e.seq, e.seq - 1);
      v_bad_seq := e.seq;
      exit;
    end if;
    if e.hash <> public.log_entry_hash(e) then
      v_problem := format('Entry %s was changed after it was written.', e.seq);
      v_bad_seq := e.seq;
      exit;
    end if;
    v_prev_hash := e.hash;
    v_expected_seq := v_expected_seq + 1;
    v_checked := v_checked + 1;
  end loop;

  perform private.write_log('log_checked', 'log', null, null, null,
    jsonb_build_object('ok', v_problem is null, 'checked', v_checked, 'first_bad_seq', v_bad_seq));
  return jsonb_build_object('ok', v_problem is null, 'checked', v_checked,
                            'first_bad_seq', v_bad_seq, 'problem', v_problem);
end
$$;

-------------------------------------------------------------------------------
-- Row-level security: read policies only. Writes go through RPCs.
-------------------------------------------------------------------------------

alter table public.members enable row level security;
alter table public.settings enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.price_changes enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_counts enable row level security;
alter table public.stock_count_lines enable row level security;
alter table public.legacy_sales enable row level security;
alter table public.log_entries enable row level security;

create policy members_read on public.members for select to authenticated
  using (id = (select public.current_member_id()) or (select public.can('manage_members')));
create policy settings_read on public.settings for select to authenticated
  using ((select public.is_member()));
create policy categories_read on public.categories for select to authenticated
  using ((select public.is_member()));
create policy products_read on public.products for select to authenticated
  using ((select public.is_member()));
create policy price_changes_read on public.price_changes for select to authenticated
  using ((select public.can('edit_products')) or (select public.can('view_reports')));
create policy stock_movements_read on public.stock_movements for select to authenticated
  using ((select public.can('stock')) or (select public.can('view_reports')));
create policy stock_counts_read on public.stock_counts for select to authenticated
  using ((select public.can('stock')));
create policy stock_count_lines_read on public.stock_count_lines for select to authenticated
  using ((select public.can('stock')));
create policy legacy_sales_read on public.legacy_sales for select to authenticated
  using ((select public.can('view_reports')));
create policy log_entries_read on public.log_entries for select to authenticated
  using ((select public.can('view_log')) or actor_id = (select public.current_member_id()));

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
revoke all on public.log_entries from public, anon, authenticated, service_role;
grant select on public.log_entries to authenticated, service_role;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon, authenticated;

grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated;
grant usage on schema public to supabase_auth_admin;
grant select on public.members to supabase_auth_admin;
create policy members_auth_hook_read on public.members for select to supabase_auth_admin using (true);
