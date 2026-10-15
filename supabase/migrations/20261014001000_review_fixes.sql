-- Fixes from the final pre-deploy review:
--   1. A retried gift card sale gets its new card's code back.
--   2. A pasted Sam's Club page is always read, never swapped for a saved listing.
--   3. A member's link to their sign-in follows the email on both sides.

-------------------------------------------------------------------------------
-- 1. Retried gift card sales
-------------------------------------------------------------------------------

-- complete_sale is idempotent on client_uuid: a retry after a lost response
-- returns the sale that was already saved. That answer had no new_cards, and
-- since 0900 a cashier can't see card codes anywhere else, so a card sold on a
-- flaky connection could leave the register without its code. The retry now
-- carries the codes, but only to an officer or to the people running the same
-- still-open shift, who saw them when the sale went through.
--
-- The original function becomes private.complete_sale_core, unchanged; the
-- public one answers retries itself and hands new sales to it.
alter function public.complete_sale(uuid, uuid, public.sale_type, jsonb, jsonb, bigint, text, text)
  rename to complete_sale_core;
alter function public.complete_sale_core(uuid, uuid, public.sale_type, jsonb, jsonb, bigint, text, text)
  set schema private;

create function public.complete_sale(
  p_client_uuid uuid,
  p_shift_id uuid,
  p_type public.sale_type,
  p_lines jsonb,
  p_payments jsonb default '[]'::jsonb,
  p_cash_tendered_cents bigint default null,
  p_note text default null,
  p_reason text default null
) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_existing uuid;
  v_same_shift boolean;
  v_new_cards jsonb;
begin
  perform private.require('ring_sales');
  if p_client_uuid is null then
    raise exception 'Missing client_uuid.';
  end if;
  perform pg_advisory_xact_lock(hashtext('sale:' || p_client_uuid::text));
  select id into v_existing from public.sales where client_uuid = p_client_uuid;
  if v_existing is null then
    return private.complete_sale_core(p_client_uuid, p_shift_id, p_type, p_lines, p_payments,
                                      p_cash_tendered_cents, p_note, p_reason);
  end if;

  select exists (
    select 1
    from public.sales s
    join public.shifts sh on sh.id = s.shift_id
    where s.id = v_existing
      and sh.id = p_shift_id
      and sh.closed_at is null
      and public.current_member_id() in (sh.opened_by, sh.cashier_id))
    into v_same_shift;

  if v_same_shift or public.can('issue_promo') then
    select coalesce(jsonb_agg(jsonb_build_object('id', gc.id, 'code', gc.code, 'amount_cents', t.amount_cents)
                              order by t.id), '[]'::jsonb)
      into v_new_cards
    from public.gift_card_txns t
    join public.gift_cards gc on gc.id = t.card_id
    where t.sale_id = v_existing and t.type = 'issue';
  else
    v_new_cards := '[]'::jsonb;
  end if;

  return jsonb_build_object('ok', true, 'duplicate', true, 'new_cards', v_new_cards,
                            'sale', private.sale_json(v_existing));
end
$$;

-- The client_uuid is what unlocks a retry, so sale lookups no longer show it.
create or replace function private.sale_json(p_sale_id uuid) returns jsonb
language sql stable
as $$
  select (to_jsonb(s) - 'client_uuid') || jsonb_build_object(
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
-- 2. Pasted pages are always read
-------------------------------------------------------------------------------

-- Someone pastes a page because the saved listing is wrong or stale, so a
-- paste never returns the saved one. save_vendor_item replaces it by item
-- number once the pasted page has been read.
create or replace function public.begin_sams_paste(p_url text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s public.settings;
  v_url text := nullif(btrim(p_url), '');
  v_used integer;
begin
  perform private.require('preauth_view');
  if v_url is not null and v_url !~* '^https://([a-z0-9-]+\.)*samsclub\.com(/|$)' then
    raise exception 'Only samsclub.com links can be looked up.';
  end if;
  select * into s from public.settings where id = 1;

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
-- 3. Sign-in links follow the email
-------------------------------------------------------------------------------

-- A sign-in account (auth user) whose email changes stops being that member.
-- Without this, someone who pre-registered a member's email with a password
-- (0900 already ignores password sessions) could change that account's email
-- to their own, sign in with a code, and still be linked to the member.
create or replace function private.link_auth_user() returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  update public.members
     set user_id = null
   where user_id = new.id
     and lower(email) is distinct from lower(new.email);
  update public.members
     set user_id = new.id
   where user_id is null
     and new.email is not null
     and lower(email) = lower(new.email);
  return new;
end
$$;

-- And the session's verified email has to be the member's, linked or not.
create or replace function public.current_member_id() returns uuid
language sql stable security definer
set search_path = public, pg_temp
as $$
  select m.id
  from public.members m
  where m.active
    and not (coalesce(auth.jwt() -> 'amr', '[]'::jsonb) @> '[{"method": "password"}]'::jsonb)
    and auth.uid() is not null
    and lower(m.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    and (m.user_id = auth.uid() or m.user_id is null)
  order by (m.user_id = auth.uid()) desc nulls last
  limit 1
$$;

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
