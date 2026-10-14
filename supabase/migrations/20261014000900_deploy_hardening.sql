-- Fixes from the pre-deploy audit:
--   1. Table reads: grant SELECT explicitly (hosted projects no longer do it).
--   2. members.pin_hash is never readable over the API.
--   3. A password session is never a member (only email codes sign people in).
--   4. Gift card codes are officer-only; sale lookups and a lost card's
--      replacement are masked for cashiers.
--   5. "Paste the page text" lookups get their own entry point.
--   6. Repeated PIN lockouts get longer, and the log says who was guessing.
--   7. gift_card_totals(): the paid-card liability across every card.

-------------------------------------------------------------------------------
-- 1. Table reads
-------------------------------------------------------------------------------

-- Supabase projects created after 2026-05-30 (and every project after
-- 2026-10-30) give the Data API roles no default privileges on new tables in
-- public. Match that everywhere, so a missing grant fails locally too, and
-- grant reads explicitly. Every table has RLS with read policies only, and both
-- views are security_invoker, so SELECT still returns only what a role may see.
-- A migration that adds a table or view must grant SELECT on it the same way.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated, service_role;

grant select on all tables in schema public to authenticated, service_role;

-------------------------------------------------------------------------------
-- 2. PIN hashes stay in the database
-------------------------------------------------------------------------------

-- Escalating lockouts (section 6) need a counter.
alter table public.members add column pin_lockouts smallint not null default 0;

-- Column grants: everything except pin_hash. A 4-digit PIN falls to an offline
-- search in minutes, which would skip the failed-try lockout entirely.
revoke select on public.members from authenticated;
grant select (id, user_id, email, display_name, grade, role, is_super_admin,
              pin_failed_count, pin_locked_until, pin_lockouts, active, created_at, updated_at)
  on public.members to authenticated;

-------------------------------------------------------------------------------
-- 3. Only email-code sessions count as members
-------------------------------------------------------------------------------

-- Sign-ups stay on (the first code creates the auth user), so anyone with the
-- public anon key can call /auth/v1/signup with a member's email and a
-- password before that member first signs in. The member's own code sign-in
-- later confirms the account, and the password would keep working. Treat any
-- session that came from a password as nobody: can(), require(), whoami(),
-- RLS, Storage policies and the Netlify functions all go through here.
-- Refreshed sessions keep their original amr, so code sign-ins are unaffected.
create or replace function public.current_member_id() returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select m.id
  from public.members m
  where m.active
    and not (coalesce(auth.jwt() -> 'amr', '[]'::jsonb) @> '[{"method": "password"}]'::jsonb)
    and (
      m.user_id = auth.uid()
      or (m.user_id is null and auth.uid() is not null
          and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
    )
  order by (m.user_id = auth.uid()) desc nulls last
  limit 1
$$;

-------------------------------------------------------------------------------
-- 4. Gift card codes are bearer credentials
-------------------------------------------------------------------------------

-- A code spends like cash, so only officers list cards. Cashiers still sell,
-- load, redeem and check balances through the register RPCs, which are
-- security definer and look cards up by the code the customer hands over.
drop policy gift_cards_read on public.gift_cards;
create policy gift_cards_read on public.gift_cards for select to authenticated
  using ((select public.can('issue_promo')));
drop policy gift_card_txns_read on public.gift_card_txns;
create policy gift_card_txns_read on public.gift_card_txns for select to authenticated
  using ((select public.can('issue_promo')));

create or replace function private.mask_card_code(p_code text) returns text
language sql stable
set search_path = public, pg_temp
as $$
  select case
    when p_code is null then null
    when public.can('issue_promo') then p_code
    else '••••' || right(p_code, 4)
  end
$$;

-- A lost card is deactivated and its balance moved to a new card. Whoever finds
-- the old card can look it up at the register, so only officers see the new
-- card's code there.
create or replace function private.card_json(c public.gift_cards) returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'type', c.type, 'status', c.status, 'note', c.note,
    'created_at', c.created_at, 'balance_cents', private.card_balance(c.id),
    'replaced_by_code', (select private.mask_card_code(r.code) from public.gift_cards r where r.id = c.replaced_by))
$$;

-- find_sale needs only ring_sales and takes any sale number, so it must not
-- hand out full codes. complete_sale's new_cards keeps the full code for the
-- card the cashier just sold, which the register prints.
create or replace function private.sale_json(p_sale_id uuid) returns jsonb
language sql stable
as $$
  select to_jsonb(s) || jsonb_build_object(
    'cashier_name', (select display_name from public.members where id = s.cashier_id),
    'lines', (
      select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object(
               'product_name', p.name,
               'card_code', private.mask_card_code(gc.code))
             order by l.line_no), '[]'::jsonb)
      from public.sale_lines l
      left join public.products p on p.id = l.product_id
      left join public.gift_cards gc on gc.id = l.gift_card_id
      where l.sale_id = s.id),
    'payments', (
      select coalesce(jsonb_agg(to_jsonb(pay) || jsonb_build_object('card_code', private.mask_card_code(gc.code))), '[]'::jsonb)
      from public.payments pay
      left join public.gift_cards gc on gc.id = pay.gift_card_id
      where pay.sale_id = s.id),
    'refunds', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.at), '[]'::jsonb)
      from public.refunds r where r.sale_id = s.id))
  from public.sales s
  where s.id = p_sale_id
$$;

-------------------------------------------------------------------------------
-- 5. "Paste the page text" lookups
-------------------------------------------------------------------------------

-- begin_sams_lookup needs a query or a link, so paste mode has its own entry
-- point. The search limit's message tells people to paste, so pastes have
-- their own daily count (the same number) instead of sharing the search one.
create function public.begin_sams_paste(p_url text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s public.settings;
  v_url text := nullif(btrim(p_url), '');
  v_item_number text := private.samsclub_item_number(nullif(btrim(p_url), ''));
  v_cached public.vendor_items;
  v_used integer;
begin
  perform private.require('preauth_view');
  if v_url is not null and v_url !~* '^https://([a-z0-9-]+\.)*samsclub\.com(/|$)' then
    raise exception 'Only samsclub.com links can be looked up.';
  end if;
  select * into s from public.settings where id = 1;

  if v_url is not null then
    select * into v_cached
    from public.vendor_items v
    where v.checked_at > now() - make_interval(days => s.sams_cache_days)
      and ((v_item_number is not null and v.item_number = v_item_number) or v.url = v_url)
    order by v.checked_at desc
    limit 1;
    if found then
      return jsonb_build_object('ok', true, 'cached', true, 'item', to_jsonb(v_cached));
    end if;
  end if;

  select count(*) into v_used
  from public.log_entries
  where action = 'sams_paste'
    and at >= (private.local_today()::timestamp at time zone 'America/New_York');
  if v_used >= s.sams_daily_limit then
    return jsonb_build_object('ok', false, 'error', 'daily_limit',
      'message', format('The store has read %s pasted Sam''s Club pages today. Type the item in.', s.sams_daily_limit));
  end if;

  perform private.write_log('sams_paste', 'vendor_lookup', null, null, null,
                            jsonb_build_object('url', v_url));
  return jsonb_build_object('ok', true, 'cached', false, 'remaining', s.sams_daily_limit - v_used - 1);
end
$$;

-------------------------------------------------------------------------------
-- 6. PIN lockouts
-------------------------------------------------------------------------------

-- The first lockout lasts 5 minutes and each one after it doubles, up to a day,
-- so guessing an officer's PIN through verify_member_pin takes months instead
-- of days. A correct PIN or a reset starts over. The log row names the
-- signed-in member who made the fifth wrong try.
create or replace function private.check_pin(p_member_id uuid, p_pin text) returns text
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  m public.members;
  v_fails integer;
  v_lock interval;
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
    if m.pin_failed_count <> 0 or m.pin_locked_until is not null or m.pin_lockouts <> 0 then
      update public.members
         set pin_failed_count = 0, pin_locked_until = null, pin_lockouts = 0
       where id = m.id;
    end if;
    return 'ok';
  end if;

  v_fails := m.pin_failed_count + 1;
  if v_fails >= 5 then
    v_lock := least(interval '5 minutes' * power(2, least(m.pin_lockouts, 12)), interval '24 hours');
    update public.members
       set pin_failed_count = 0,
           pin_locked_until = now() + v_lock,
           pin_lockouts = least(m.pin_lockouts + 1, 1000)
     where id = m.id;
    perform private.write_log('pin_locked', 'member', m.id::text, null, null,
                              jsonb_build_object('by', public.current_member_id(),
                                                 'lockout', m.pin_lockouts + 1,
                                                 'minutes', extract(epoch from v_lock)::integer / 60),
                              '5 wrong PIN tries', m.id);
    return 'locked';
  end if;
  update public.members set pin_failed_count = v_fails where id = m.id;
  return 'wrong';
end
$$;

create or replace function private.pin_error(p_result text) returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'ok', false,
    'error', 'pin_' || p_result,
    'message', case p_result
      when 'wrong' then 'Wrong PIN.'
      when 'locked' then 'Too many wrong tries. That PIN is locked for now. Try again later, or ask the Advisor to reset it.'
      when 'no_pin' then 'That person has no PIN yet. Ask the Advisor to set one.'
      else 'That person is not an active member.'
    end)
$$;

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
-- 7. Gift card liability
-------------------------------------------------------------------------------

-- The Gift cards screen lists the newest cards; the headline total has to
-- cover all of them.
create function public.gift_card_totals() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  perform private.require('issue_promo');
  select jsonb_build_object(
           'paid_outstanding_cents', coalesce(sum(b.balance_cents) filter (where b.type = 'paid'), 0),
           'promo_outstanding_cents', coalesce(sum(b.balance_cents) filter (where b.type = 'promo'), 0),
           'cards_with_balance', count(*) filter (where b.balance_cents > 0))
    into v
  from (
    select c.type, coalesce(sum(t.amount_cents), 0)::bigint as balance_cents
    from public.gift_cards c
    left join public.gift_card_txns t on t.card_id = c.id
    where c.status = 'active'
    group by c.id, c.type
  ) b;
  return v;
end
$$;

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
