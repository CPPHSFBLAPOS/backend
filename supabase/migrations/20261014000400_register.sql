-- Phase 3: Register and cash
-- Shifts with a counted drawer, sales (idempotent on client_uuid), payments
-- split across cash and gift/promo cards, voids, refunds, cash handoffs,
-- paper outage entries and training mode.

create type public.sale_type as enum ('regular', 'staff', 'comp', 'outage', 'training');
create type public.sale_status as enum ('completed', 'voided', 'pending', 'rejected');

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------

create sequence public.shift_number_seq;
create sequence public.sale_number_seq;
create sequence public.refund_number_seq;

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique default nextval('public.shift_number_seq'),
  cashier_id uuid not null references public.members (id),
  -- The signed-in account that opened it (usually the shared Register account).
  opened_by uuid not null references public.members (id),
  device text,
  opened_at timestamptz not null default now(),
  opening_cash_cents bigint not null check (opening_cash_cents >= 0),
  opening_breakdown jsonb,
  closed_at timestamptz,
  counted_cash_cents bigint,
  counted_breakdown jsonb,
  expected_cash_cents bigint,
  over_short_cents bigint,
  note text,
  close_officer_id uuid references public.members (id)
);
create unique index shifts_one_open_per_cashier on public.shifts (cashier_id) where closed_at is null;

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique default nextval('public.sale_number_seq'),
  client_uuid uuid not null unique,
  shift_id uuid references public.shifts (id),
  cashier_id uuid not null references public.members (id),
  entered_by uuid references public.members (id),
  type public.sale_type not null default 'regular',
  status public.sale_status not null default 'completed',
  subtotal_cents bigint not null default 0 check (subtotal_cents >= 0),
  load_cents bigint not null default 0 check (load_cents >= 0),
  total_cents bigint not null default 0 check (total_cents >= 0),
  promo_cents bigint not null default 0 check (promo_cents >= 0),
  cash_tendered_cents bigint,
  change_cents bigint,
  -- Never a buyer's name.
  note text,
  reason text,
  occurred_on date,
  outage_photo_path text,
  verified_by uuid references public.members (id),
  verified_at timestamptz,
  verify_note text,
  voided_at timestamptz,
  voided_by uuid references public.members (id),
  void_reason text,
  void_approved_by uuid references public.members (id),
  created_at timestamptz not null default now()
);
create index sales_shift_idx on public.sales (shift_id);
create index sales_created_idx on public.sales (created_at);
create index sales_status_idx on public.sales (status, type);

create table public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id),
  line_no integer not null,
  kind text not null default 'product' check (kind in ('product', 'gift_card_load')),
  product_id uuid references public.products (id),
  gift_card_id uuid references public.gift_cards (id),
  qty integer not null check (qty > 0),
  unit_price_cents bigint not null check (unit_price_cents >= 0),
  list_price_cents bigint not null check (list_price_cents >= 0),
  -- Saved at the moment of sale so past profit never shifts. Null = cost missing.
  unit_cost_cents bigint check (unit_cost_cents >= 0),
  refunded_qty integer not null default 0,
  check (refunded_qty between 0 and qty),
  check ((kind = 'product' and product_id is not null)
      or (kind = 'gift_card_load' and gift_card_id is not null and qty = 1)),
  unique (sale_id, line_no)
);
create index sale_lines_product_idx on public.sale_lines (product_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id),
  method text not null check (method in ('cash', 'gift_card', 'promo_card')),
  amount_cents bigint not null check (amount_cents > 0),
  gift_card_id uuid references public.gift_cards (id),
  check ((method = 'cash') = (gift_card_id is null))
);
create index payments_sale_idx on public.payments (sale_id);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique default nextval('public.refund_number_seq'),
  sale_id uuid not null references public.sales (id),
  shift_id uuid not null references public.shifts (id),
  amount_cents bigint not null check (amount_cents >= 0),
  method text not null check (method in ('cash', 'gift_card', 'promo_card', 'mixed', 'none')),
  cash_cents bigint not null default 0,
  gift_card_cents bigint not null default 0,
  promo_cents bigint not null default 0,
  gift_card_id uuid references public.gift_cards (id),
  return_to_shelf boolean not null,
  reason text not null,
  approved_by uuid references public.members (id),
  by uuid not null references public.members (id),
  at timestamptz not null default now(),
  check (cash_cents + gift_card_cents + promo_cents = amount_cents)
);
create index refunds_sale_idx on public.refunds (sale_id);
create index refunds_shift_idx on public.refunds (shift_id);

create table public.refund_lines (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.refunds (id),
  sale_line_id uuid not null references public.sale_lines (id),
  qty integer not null check (qty > 0),
  amount_cents bigint not null check (amount_cents >= 0),
  unit_cost_cents bigint
);

create table public.cash_handoffs (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts (id),
  amount_cents bigint not null check (amount_cents > 0),
  from_id uuid not null references public.members (id),
  to_id uuid not null references public.members (id),
  from_signature_id uuid references public.signatures (id),
  to_signature_id uuid references public.signatures (id),
  note text,
  at timestamptz not null default now(),
  check (from_id <> to_id)
);

alter table public.gift_card_txns
  add constraint gift_card_txns_sale_fk foreign key (sale_id) references public.sales (id);

-- Money records are never edited after the fact except through RPCs that
-- void or refund. Payments and refund lines never change at all.
create trigger payments_append_only before update or delete on public.payments
  for each row execute function private.forbid_change();
create trigger refunds_append_only before update or delete on public.refunds
  for each row execute function private.forbid_change();
create trigger refund_lines_append_only before update or delete on public.refund_lines
  for each row execute function private.forbid_change();
create trigger cash_handoffs_append_only before update or delete on public.cash_handoffs
  for each row execute function private.forbid_change();
create trigger sales_no_delete before delete on public.sales
  for each row execute function private.forbid_change();
create trigger sale_lines_no_delete before delete on public.sale_lines
  for each row execute function private.forbid_change();

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- The open shift, if the caller may work it: the account that opened it, the
-- cashier, or an officer. Takes a share lock so a close waits for sales in
-- flight.
create function private.require_open_shift(p_shift_id uuid, p_for_update boolean default false)
returns public.shifts
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts;
  me uuid := public.current_member_id();
begin
  if p_for_update then
    select * into sh from public.shifts where id = p_shift_id for update;
  else
    select * into sh from public.shifts where id = p_shift_id for share;
  end if;
  if not found then
    raise exception 'Open a shift first.';
  end if;
  if sh.closed_at is not null then
    raise exception 'Shift #% is closed. Open a new shift.', sh.number;
  end if;
  if coalesce(auth.role(), '') <> 'service_role'
     and me is distinct from sh.opened_by and me is distinct from sh.cashier_id
     and not public.can('void_refund') then
    raise exception 'That shift belongs to another register.' using errcode = '42501';
  end if;
  return sh;
end
$$;

-- Expected cash = opening cash + cash sales + cash gift card loads
--                 - cash refunds - cash handoffs.
-- Training sales never touch the drawer; voided sales gave their cash back.
-- Pending outage entries count, since their cash is already in the drawer.
create function private.shift_expected_cash(p_shift_id uuid) returns bigint
language sql stable
as $$
  select sh.opening_cash_cents
       + coalesce((select sum(pay.amount_cents)
                   from public.payments pay
                   join public.sales s on s.id = pay.sale_id
                   where s.shift_id = sh.id and pay.method = 'cash'
                     and s.type <> 'training' and s.status in ('completed', 'pending')), 0)
       - coalesce((select sum(r.cash_cents) from public.refunds r where r.shift_id = sh.id), 0)
       - coalesce((select sum(h.amount_cents) from public.cash_handoffs h where h.shift_id = sh.id), 0)
  from public.shifts sh
  where sh.id = p_shift_id
$$;

-- Who is acting: an officer PIN when the shift's cashier cannot void or
-- refund. Returns null when allowed, or a PIN error to hand back unchanged.
create function private.authorize_void_refund(sh public.shifts, p_officer_id uuid, p_officer_pin text)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v text;
begin
  if private.member_can(sh.cashier_id, 'void_refund') then
    return null;
  end if;
  if p_officer_id is null then
    return jsonb_build_object('ok', false, 'error', 'officer_pin_required',
                              'message', 'An officer must enter their PIN.');
  end if;
  if p_officer_id = sh.cashier_id or not private.member_can(p_officer_id, 'void_refund') then
    return jsonb_build_object('ok', false, 'error', 'not_officer',
                              'message', 'That person cannot approve voids or refunds.');
  end if;
  v := private.check_pin(p_officer_id, p_officer_pin);
  if v <> 'ok' then
    return private.pin_error(v);
  end if;
  return null;
end
$$;

create function private.sale_json(p_sale_id uuid) returns jsonb
language sql stable
as $$
  select to_jsonb(s) || jsonb_build_object(
    'cashier_name', (select display_name from public.members where id = s.cashier_id),
    'lines', (
      select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object(
               'product_name', p.name,
               'card_code', gc.code)
             order by l.line_no), '[]'::jsonb)
      from public.sale_lines l
      left join public.products p on p.id = l.product_id
      left join public.gift_cards gc on gc.id = l.gift_card_id
      where l.sale_id = s.id),
    'payments', (
      select coalesce(jsonb_agg(to_jsonb(pay) || jsonb_build_object('card_code', gc.code)), '[]'::jsonb)
      from public.payments pay
      left join public.gift_cards gc on gc.id = pay.gift_card_id
      where pay.sale_id = s.id),
    'refunds', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.at), '[]'::jsonb)
      from public.refunds r where r.sale_id = s.id))
  from public.sales s
  where s.id = p_sale_id
$$;

-- Follow a deactivated card to the card its balance moved to.
create function private.active_card_for(p_card_id uuid) returns uuid
language plpgsql stable
as $$
declare
  v_id uuid := p_card_id;
  v_status text;
  v_next uuid;
  v_hops integer := 0;
begin
  loop
    select status, replaced_by into v_status, v_next from public.gift_cards where id = v_id;
    exit when v_status = 'active' or v_next is null or v_hops > 20;
    v_id := v_next;
    v_hops := v_hops + 1;
  end loop;
  return v_id;
end
$$;

-------------------------------------------------------------------------------
-- RPC: shifts
-------------------------------------------------------------------------------

-- A cashier starts a shift with their 4-digit PIN and counts the opening cash.
create function public.open_shift(p_cashier_id uuid, p_pin text, p_opening_cash_cents bigint,
                                  p_breakdown jsonb default null, p_device text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  v text;
  v_id uuid;
  v_number integer;
begin
  perform private.require('ring_sales');
  if not private.member_can(p_cashier_id, 'ring_sales') then
    return jsonb_build_object('ok', false, 'error', 'not_cashier', 'message', 'That person cannot ring sales.');
  end if;
  if (select role from public.members where id = p_cashier_id) = 'register' then
    return jsonb_build_object('ok', false, 'error', 'not_cashier',
                              'message', 'Pick the person working the register.');
  end if;
  v := private.check_pin(p_cashier_id, p_pin);
  if v <> 'ok' then
    return private.pin_error(v);
  end if;
  if p_opening_cash_cents is null or p_opening_cash_cents < 0 then
    raise exception 'Count the opening cash.';
  end if;
  if exists (select 1 from public.shifts where cashier_id = p_cashier_id and closed_at is null) then
    raise exception 'That cashier already has an open shift. Close it first.';
  end if;
  insert into public.shifts (cashier_id, opened_by, device, opening_cash_cents, opening_breakdown)
  values (p_cashier_id, me.id, coalesce(nullif(p_device, ''), private.request_device()),
          p_opening_cash_cents, p_breakdown)
  returning id, number into v_id, v_number;
  perform private.write_log('shift_opened', 'shift', v_id::text, p_opening_cash_cents, null,
                            jsonb_build_object('number', v_number, 'opened_by', me.id), null, p_cashier_id);
  return jsonb_build_object('ok', true, 'shift_id', v_id, 'number', v_number);
end
$$;

-- Open shifts this account can work.
create function public.my_open_shifts() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  me uuid := public.current_member_id();
begin
  perform private.require('ring_sales');
  return (
    select coalesce(jsonb_agg(to_jsonb(sh) || jsonb_build_object(
             'cashier_name', m.display_name,
             'cashier_role', m.role,
             'expected_cash_cents', private.shift_expected_cash(sh.id))
           order by sh.opened_at desc), '[]'::jsonb)
    from public.shifts sh
    join public.members m on m.id = sh.cashier_id
    where sh.closed_at is null and (sh.opened_by = me or sh.cashier_id = me));
end
$$;

create function public.shift_summary(p_shift_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts;
  me uuid := public.current_member_id();
begin
  select * into sh from public.shifts where id = p_shift_id;
  if not found then
    raise exception 'Shift not found.';
  end if;
  if me is distinct from sh.opened_by and me is distinct from sh.cashier_id
     and not public.can('view_reports') then
    raise exception 'Permission denied.' using errcode = '42501';
  end if;
  return to_jsonb(sh) || jsonb_build_object(
    'cashier_name', (select display_name from public.members where id = sh.cashier_id),
    'close_officer_name', (select display_name from public.members where id = sh.close_officer_id),
    'expected_cash_cents', coalesce(sh.expected_cash_cents, private.shift_expected_cash(sh.id)),
    'cash_in_cents', coalesce((
        select sum(pay.amount_cents) from public.payments pay
        join public.sales s on s.id = pay.sale_id
        where s.shift_id = sh.id and pay.method = 'cash' and s.type <> 'training'
          and s.status in ('completed', 'pending')), 0),
    'cash_loads_cents', coalesce((
        select sum(s.load_cents) from public.sales s
        where s.shift_id = sh.id and s.type <> 'training' and s.status = 'completed'), 0),
    'cash_refunds_cents', coalesce((select sum(cash_cents) from public.refunds where shift_id = sh.id), 0),
    'handoffs_cents', coalesce((select sum(amount_cents) from public.cash_handoffs where shift_id = sh.id), 0),
    'sales_count', (select count(*) from public.sales s where s.shift_id = sh.id
                     and s.status = 'completed' and s.type <> 'training'),
    'training_count', (select count(*) from public.sales s where s.shift_id = sh.id and s.type = 'training'),
    'voids_count', (select count(*) from public.sales s where s.shift_id = sh.id and s.status = 'voided'),
    'refunds_count', (select count(*) from public.refunds r where r.shift_id = sh.id),
    'sales_total_cents', coalesce((select sum(total_cents) from public.sales s where s.shift_id = sh.id
                                    and s.status = 'completed' and s.type <> 'training'), 0),
    'by_method', (
        select coalesce(jsonb_object_agg(method, amount), '{}'::jsonb) from (
          select pay.method, sum(pay.amount_cents) as amount
          from public.payments pay join public.sales s on s.id = pay.sale_id
          where s.shift_id = sh.id and s.type <> 'training' and s.status in ('completed', 'pending')
          group by pay.method) t),
    'sales', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', s.id, 'number', s.number, 'type', s.type, 'status', s.status,
                 'total_cents', s.total_cents, 'created_at', s.created_at)
               order by s.created_at desc), '[]'::jsonb)
        from public.sales s where s.shift_id = sh.id),
    'handoffs', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', h.id, 'amount_cents', h.amount_cents, 'at', h.at,
                 'from_name', mf.display_name, 'to_name', mt.display_name) order by h.at), '[]'::jsonb)
        from public.cash_handoffs h
        join public.members mf on mf.id = h.from_id
        join public.members mt on mt.id = h.to_id
        where h.shift_id = sh.id));
end
$$;

-- Closing counts the drawer by bill and coin. Over/short beyond the
-- tolerance ($1.00) needs a note and an officer PIN.
-- p_breakdown: [{denom_cents, count}]
create function public.close_shift(p_shift_id uuid, p_breakdown jsonb, p_note text default null,
                                   p_officer_id uuid default null, p_officer_pin text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts := private.require_open_shift(p_shift_id, true);
  s public.settings;
  v_counted bigint;
  v_expected bigint;
  v_over_short bigint;
  v text;
  v_officer uuid := null;
begin
  select * into s from public.settings where id = 1;
  if p_breakdown is null or jsonb_typeof(p_breakdown) <> 'array' then
    raise exception 'Count the drawer by bill and coin.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_breakdown) d
    where (d ->> 'denom_cents')::bigint not in (10000, 5000, 2000, 1000, 500, 200, 100, 50, 25, 10, 5, 1)
       or coalesce((d ->> 'count')::integer, 0) < 0
  ) then
    raise exception 'Unknown bill or coin in the count.';
  end if;
  select coalesce(sum((d ->> 'denom_cents')::bigint * coalesce((d ->> 'count')::integer, 0)), 0)
    into v_counted from jsonb_array_elements(p_breakdown) d;
  v_expected := private.shift_expected_cash(sh.id);
  v_over_short := v_counted - v_expected;

  if abs(v_over_short) > s.over_short_tolerance_cents then
    if coalesce(btrim(p_note), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'note_required',
        'message', 'The drawer is off by more than the tolerance. Add a note.',
        'expected_cash_cents', v_expected, 'counted_cash_cents', v_counted,
        'over_short_cents', v_over_short);
    end if;
    if p_officer_id is null or not private.member_can(p_officer_id, 'void_refund') then
      return jsonb_build_object('ok', false, 'error', 'officer_pin_required',
        'message', 'An officer must enter their PIN to close an over/short drawer.',
        'expected_cash_cents', v_expected, 'counted_cash_cents', v_counted,
        'over_short_cents', v_over_short);
    end if;
    v := private.check_pin(p_officer_id, p_officer_pin);
    if v <> 'ok' then
      return private.pin_error(v);
    end if;
    v_officer := p_officer_id;
  end if;

  update public.shifts
     set closed_at = now(),
         counted_cash_cents = v_counted,
         counted_breakdown = p_breakdown,
         expected_cash_cents = v_expected,
         over_short_cents = v_over_short,
         note = nullif(btrim(p_note), ''),
         close_officer_id = v_officer
   where id = sh.id;
  perform private.write_log('shift_closed', 'shift', sh.id::text, v_over_short, null,
    jsonb_build_object('expected_cash_cents', v_expected, 'counted_cash_cents', v_counted,
                       'over_short_cents', v_over_short, 'officer_id', v_officer),
    nullif(btrim(p_note), ''), sh.cashier_id);
  return jsonb_build_object('ok', true, 'expected_cash_cents', v_expected,
                            'counted_cash_cents', v_counted, 'over_short_cents', v_over_short);
end
$$;

-- Cash leaving the drawer, confirmed by both people's PINs and signatures.
-- p_from_signature / p_to_signature: {typed_name, strokes, image_path}
create function public.record_handoff(p_shift_id uuid, p_amount_cents bigint,
                                      p_from_id uuid, p_from_pin text,
                                      p_to_id uuid, p_to_pin text,
                                      p_from_signature jsonb, p_to_signature jsonb,
                                      p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts := private.require_open_shift(p_shift_id, true);
  v text;
  v_id uuid := gen_random_uuid();
  v_from_sig uuid;
  v_to_sig uuid;
begin
  if p_from_id is null or p_to_id is null or p_from_id = p_to_id then
    raise exception 'A handoff is between two different people.';
  end if;
  v := private.check_pin(p_from_id, p_from_pin);
  if v <> 'ok' then
    return private.pin_error(v) || jsonb_build_object('who', 'from');
  end if;
  v := private.check_pin(p_to_id, p_to_pin);
  if v <> 'ok' then
    return private.pin_error(v) || jsonb_build_object('who', 'to');
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Enter the amount handed off.';
  end if;
  if p_amount_cents > private.shift_expected_cash(sh.id) then
    raise exception 'That is more than the drawer should hold.';
  end if;
  v_from_sig := private.insert_signature('handoff', v_id, 'from', p_from_id,
                  p_from_signature ->> 'typed_name', p_from_signature -> 'strokes',
                  p_from_signature ->> 'image_path', null);
  v_to_sig := private.insert_signature('handoff', v_id, 'to', p_to_id,
                  p_to_signature ->> 'typed_name', p_to_signature -> 'strokes',
                  p_to_signature ->> 'image_path', null);
  insert into public.cash_handoffs (id, shift_id, amount_cents, from_id, to_id, from_signature_id,
                                    to_signature_id, note)
  values (v_id, sh.id, p_amount_cents, p_from_id, p_to_id, v_from_sig, v_to_sig, nullif(btrim(p_note), ''));
  perform private.write_log('cash_handoff', 'cash_handoff', v_id::text, p_amount_cents, null,
                            jsonb_build_object('shift_id', sh.id, 'from_id', p_from_id, 'to_id', p_to_id),
                            nullif(btrim(p_note), ''), p_from_id);
  return jsonb_build_object('ok', true, 'handoff_id', v_id,
                            'expected_cash_cents', private.shift_expected_cash(sh.id));
end
$$;

-------------------------------------------------------------------------------
-- RPC: sales
-------------------------------------------------------------------------------

-- One transaction: the sale, its lines with unit_cost_cents from the product's
-- current average cost, payments, gift card ledger rows, Sale stock movements
-- and the log entry. Sending the same client_uuid twice saves it once.
--
-- p_lines:    [{kind: 'product', product_id, qty} | {kind: 'gift_card_load', code?, amount_cents}]
-- p_payments: [{method: 'cash', amount_cents} | {method: 'gift_card'|'promo_card', code, amount_cents}]
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
  sh public.shifts;
  v_existing uuid;
  v_sale_id uuid := gen_random_uuid();
  r jsonb;
  pr public.products;
  c public.gift_cards;
  v_qty integer;
  v_on_hand integer;
  v_price bigint;
  v_amount bigint;
  v_line_no integer := 0;
  v_subtotal bigint := 0;
  v_loads bigint := 0;
  v_total bigint;
  v_cash bigint := 0;
  v_gift bigint := 0;
  v_promo bigint := 0;
  v_change bigint := null;
  v_new_cards jsonb := '[]'::jsonb;
  v_has_cards boolean;
begin
  perform private.require('ring_sales');
  if p_client_uuid is null then
    raise exception 'Missing client_uuid.';
  end if;
  perform pg_advisory_xact_lock(hashtext('sale:' || p_client_uuid::text));
  select id into v_existing from public.sales where client_uuid = p_client_uuid;
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'sale', private.sale_json(v_existing));
  end if;

  sh := private.require_open_shift(p_shift_id);

  if p_type = 'outage' then
    raise exception 'Enter paper sales with the outage form.';
  end if;
  if p_type = 'comp' and coalesce(btrim(p_reason), '') = '' then
    raise exception 'A comp needs a reason.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'The cart is empty.';
  end if;
  v_has_cards := exists (select 1 from jsonb_array_elements(p_lines) x where x ->> 'kind' = 'gift_card_load')
              or exists (select 1 from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) x
                         where x ->> 'method' <> 'cash');
  if p_type in ('training', 'comp') and v_has_cards then
    raise exception 'Gift cards are not used in % sales.', p_type;
  end if;

  insert into public.sales (id, client_uuid, shift_id, cashier_id, entered_by, type, status, note, reason)
  values (v_sale_id, p_client_uuid, sh.id, sh.cashier_id, public.current_member_id(), p_type, 'completed',
          nullif(btrim(p_note), ''), nullif(btrim(p_reason), ''));

  -- Product lines, one per product, locked in a fixed order.
  for r in
    select jsonb_build_object('product_id', x ->> 'product_id', 'qty', sum((x ->> 'qty')::integer)) as v
    from jsonb_array_elements(p_lines) x
    where coalesce(x ->> 'kind', 'product') = 'product'
    group by x ->> 'product_id'
    order by x ->> 'product_id'
  loop
    v_qty := (r ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantities must be more than zero.';
    end if;
    select * into pr from public.products where id = (r ->> 'product_id')::uuid for update;
    if not found or pr.status <> 'active' then
      raise exception 'An item in the cart is no longer for sale.';
    end if;
    if p_type <> 'training' then
      v_on_hand := private.on_hand(pr.id);
      if v_on_hand < v_qty then
        raise exception '% is out of stock (% left).', pr.name, greatest(v_on_hand, 0);
      end if;
    end if;
    v_price := case when p_type = 'comp' then 0 else pr.price_cents end;
    v_line_no := v_line_no + 1;
    insert into public.sale_lines (sale_id, line_no, kind, product_id, qty, unit_price_cents,
                                   list_price_cents, unit_cost_cents)
    values (v_sale_id, v_line_no, 'product', pr.id, v_qty, v_price, pr.price_cents, pr.avg_cost_cents);
    v_subtotal := v_subtotal + v_qty * v_price;
    if p_type <> 'training' then
      perform private.post_movement(pr.id, -v_qty, 'sale', pr.avg_cost_cents, 'sale', v_sale_id::text,
                                    null, sh.cashier_id);
    end if;
  end loop;

  -- Gift card loads: cash in, owed by the store, not product revenue.
  for r in select x from jsonb_array_elements(p_lines) x where x ->> 'kind' = 'gift_card_load' loop
    v_amount := (r ->> 'amount_cents')::bigint;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Enter an amount to load.';
    end if;
    if coalesce(btrim(r ->> 'code'), '') = '' then
      c := private.create_gift_card('paid', sh.cashier_id, 'Sold at register');
      v_new_cards := v_new_cards || jsonb_build_object('id', c.id, 'code', c.code, 'amount_cents', v_amount);
      perform private.write_log('gift_card_created', 'gift_card', c.id::text, null, null,
                                jsonb_build_object('type', 'paid'), null, sh.cashier_id);
    else
      c := private.lock_card(r ->> 'code');
      if c.type <> 'paid' then
        raise exception 'Promo cards cannot be loaded at the register.';
      end if;
    end if;
    v_line_no := v_line_no + 1;
    insert into public.sale_lines (sale_id, line_no, kind, gift_card_id, qty, unit_price_cents,
                                   list_price_cents, unit_cost_cents)
    values (v_sale_id, v_line_no, 'gift_card_load', c.id, 1, v_amount, v_amount, null);
    perform private.card_txn(c.id, case when coalesce(btrim(r ->> 'code'), '') = '' then 'issue' else 'load' end,
                             v_amount, v_sale_id, sh.cashier_id);
    v_loads := v_loads + v_amount;
  end loop;

  v_total := v_subtotal + v_loads;

  for r in select x from jsonb_array_elements(coalesce(p_payments, '[]'::jsonb)) x loop
    v_amount := (r ->> 'amount_cents')::bigint;
    if v_amount is null or v_amount <= 0 then
      continue;
    end if;
    if r ->> 'method' = 'cash' then
      insert into public.payments (sale_id, method, amount_cents) values (v_sale_id, 'cash', v_amount);
      v_cash := v_cash + v_amount;
    elsif r ->> 'method' in ('gift_card', 'promo_card') then
      c := private.lock_card(r ->> 'code');
      if (r ->> 'method' = 'gift_card' and c.type <> 'paid')
         or (r ->> 'method' = 'promo_card' and c.type <> 'promo') then
        raise exception 'Card % is a % card.', c.code, c.type;
      end if;
      if private.card_balance(c.id) < v_amount then
        raise exception 'Card % only has $%.', c.code, to_char(private.card_balance(c.id) / 100.0, 'FM999,990.00');
      end if;
      insert into public.payments (sale_id, method, amount_cents, gift_card_id)
      values (v_sale_id, r ->> 'method', v_amount, c.id);
      perform private.card_txn(c.id, 'redeem', -v_amount, v_sale_id, sh.cashier_id);
      if c.type = 'paid' then
        v_gift := v_gift + v_amount;
      else
        v_promo := v_promo + v_amount;
      end if;
    else
      raise exception 'Payments are cash, gift card or promo card.';
    end if;
  end loop;

  if v_cash + v_gift + v_promo <> v_total then
    raise exception 'Payments ($%) do not match the total ($%).',
      to_char((v_cash + v_gift + v_promo) / 100.0, 'FM999,990.00'), to_char(v_total / 100.0, 'FM999,990.00');
  end if;
  if v_gift + v_promo > v_subtotal then
    raise exception 'Gift card loads are paid in cash.';
  end if;
  if p_cash_tendered_cents is not null and v_cash > 0 then
    if p_cash_tendered_cents < v_cash then
      raise exception 'Cash given is less than the cash due.';
    end if;
    v_change := p_cash_tendered_cents - v_cash;
  end if;

  update public.sales
     set subtotal_cents = v_subtotal,
         load_cents = v_loads,
         total_cents = v_total,
         promo_cents = v_promo,
         cash_tendered_cents = case when v_cash > 0 then p_cash_tendered_cents end,
         change_cents = v_change
   where id = v_sale_id;

  perform private.write_log(case when p_type = 'training' then 'training_sale' else 'sale_completed' end,
    'sale', v_sale_id::text, v_total, null,
    jsonb_build_object('type', p_type, 'shift_id', sh.id, 'subtotal_cents', v_subtotal,
                       'load_cents', v_loads, 'cash_cents', v_cash, 'gift_card_cents', v_gift,
                       'promo_cents', v_promo, 'lines', v_line_no),
    nullif(btrim(p_reason), ''), sh.cashier_id);

  return jsonb_build_object('ok', true, 'duplicate', false, 'change_cents', v_change,
                            'new_cards', v_new_cards, 'sale', private.sale_json(v_sale_id));
end
$$;

-- Look up a sale by number for a void or refund.
create function public.find_sale(p_number integer) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  perform private.require('ring_sales');
  select id into v_id from public.sales where number = p_number;
  if v_id is null then
    raise exception 'No sale #%.', p_number;
  end if;
  return private.sale_json(v_id);
end
$$;

-- A void cancels a whole sale in the same shift.
create function public.void_sale(p_sale_id uuid, p_shift_id uuid, p_reason text,
                                 p_officer_id uuid default null, p_officer_pin text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts := private.require_open_shift(p_shift_id);
  s public.sales;
  l record;
  pay record;
  v_err jsonb;
  v_approver uuid;
begin
  perform private.require('ring_sales');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A void needs a reason.';
  end if;
  select * into s from public.sales where id = p_sale_id for update;
  if not found then
    raise exception 'Sale not found.';
  end if;
  if s.shift_id is distinct from sh.id then
    raise exception 'Only sales from this shift can be voided. Use a refund instead.';
  end if;
  if s.status <> 'completed' then
    raise exception 'Sale #% is %.', s.number, s.status;
  end if;
  if exists (select 1 from public.refunds where sale_id = s.id) then
    raise exception 'Sale #% already has a refund. Refund the rest instead.', s.number;
  end if;

  v_err := private.authorize_void_refund(sh, p_officer_id, p_officer_pin);
  if v_err is not null then
    return v_err;
  end if;
  v_approver := case when private.member_can(sh.cashier_id, 'void_refund') then null else p_officer_id end;

  if s.type <> 'training' then
    for l in select * from public.sale_lines where sale_id = s.id and kind = 'product' order by line_no loop
      perform private.post_movement(l.product_id, l.qty, 'void', l.unit_cost_cents, 'sale', s.id::text,
                                    p_reason, sh.cashier_id);
    end loop;
    -- Card money goes back the way it came; loads come back off the card.
    for pay in select * from public.payments where sale_id = s.id and method <> 'cash' loop
      perform private.card_txn(private.active_card_for(pay.gift_card_id), 'void', pay.amount_cents, s.id,
                               sh.cashier_id, 'Void');
    end loop;
    for l in select * from public.sale_lines where sale_id = s.id and kind = 'gift_card_load' loop
      perform private.lock_card((select code from public.gift_cards where id = l.gift_card_id));
      if private.card_balance(l.gift_card_id) < l.unit_price_cents then
        raise exception 'The loaded card has already been spent, so this sale cannot be voided.';
      end if;
      perform private.card_txn(l.gift_card_id, 'void', -l.unit_price_cents, s.id, sh.cashier_id, 'Void');
    end loop;
  end if;

  update public.sales
     set status = 'voided', voided_at = now(), voided_by = sh.cashier_id, void_reason = btrim(p_reason),
         void_approved_by = v_approver
   where id = s.id;
  perform private.write_log('sale_voided', 'sale', s.id::text, s.total_cents,
                            jsonb_build_object('status', 'completed'), jsonb_build_object('status', 'voided',
                            'approved_by', v_approver), btrim(p_reason), sh.cashier_id);
  return jsonb_build_object('ok', true, 'sale', private.sale_json(s.id),
                            'expected_cash_cents', private.shift_expected_cash(sh.id));
end
$$;

-- A refund comes later, whole or by item. Money goes back the way it was
-- paid: onto the gift or promo card first, then cash from this drawer.
-- p_lines: [{sale_line_id, qty}]
create function public.refund_sale(p_sale_id uuid, p_shift_id uuid, p_lines jsonb,
                                   p_return_to_shelf boolean, p_reason text,
                                   p_officer_id uuid default null, p_officer_pin text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  sh public.shifts := private.require_open_shift(p_shift_id);
  s public.sales;
  l public.sale_lines;
  r jsonb;
  pay record;
  v_err jsonb;
  v_refund_id uuid := gen_random_uuid();
  v_qty integer;
  v_items jsonb := '[]'::jsonb;
  v_amount bigint := 0;
  v_remaining bigint;
  v_take bigint;
  v_already bigint;
  v_cash_paid bigint;
  v_cash bigint := 0;
  v_gift bigint := 0;
  v_promo bigint := 0;
  v_first_card uuid;
  v_card uuid;
  v_method text;
  v_shelf boolean := coalesce(p_return_to_shelf, false);
begin
  perform private.require('ring_sales');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A refund needs a reason.';
  end if;
  select * into s from public.sales where id = p_sale_id for update;
  if not found then
    raise exception 'Sale not found.';
  end if;
  if s.status <> 'completed' or s.type = 'training' then
    raise exception 'Sale #% cannot be refunded.', s.number;
  end if;

  v_err := private.authorize_void_refund(sh, p_officer_id, p_officer_pin);
  if v_err is not null then
    return v_err;
  end if;

  -- Check every line first.
  for r in select x from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x loop
    v_qty := (r ->> 'qty')::integer;
    if v_qty is null or v_qty <= 0 then
      continue;
    end if;
    select * into l from public.sale_lines
     where id = (r ->> 'sale_line_id')::uuid and sale_id = s.id and kind = 'product'
     for update;
    if not found then
      raise exception 'That item is not on sale #%.', s.number;
    end if;
    if l.refunded_qty + v_qty > l.qty then
      raise exception 'Only % of that item can still be refunded.', l.qty - l.refunded_qty;
    end if;
    update public.sale_lines set refunded_qty = refunded_qty + v_qty where id = l.id;
    v_items := v_items || jsonb_build_object('sale_line_id', l.id, 'product_id', l.product_id, 'qty', v_qty,
                                             'amount_cents', v_qty * l.unit_price_cents,
                                             'unit_cost_cents', l.unit_cost_cents);
    v_amount := v_amount + v_qty * l.unit_price_cents;
  end loop;
  if jsonb_array_length(v_items) = 0 then
    raise exception 'Pick at least one item to refund.';
  end if;

  -- Allocate the money back: cards first (in payment order), then cash.
  -- Each card refund notes the original card, which may have been replaced.
  v_remaining := v_amount;
  for pay in select * from public.payments where sale_id = s.id and method <> 'cash' order by id loop
    exit when v_remaining = 0;
    select coalesce(sum(t.amount_cents), 0) into v_already
      from public.gift_card_txns t
     where t.sale_id = s.id and t.type = 'refund' and t.note = pay.gift_card_id::text;
    v_take := least(v_remaining, pay.amount_cents - v_already);
    if v_take > 0 then
      v_card := private.active_card_for(pay.gift_card_id);
      perform private.card_txn(v_card, 'refund', v_take, s.id, sh.cashier_id, pay.gift_card_id::text);
      if pay.method = 'gift_card' then
        v_gift := v_gift + v_take;
      else
        v_promo := v_promo + v_take;
      end if;
      v_first_card := coalesce(v_first_card, v_card);
      v_remaining := v_remaining - v_take;
    end if;
  end loop;
  if v_remaining > 0 then
    select coalesce(sum(amount_cents), 0) into v_cash_paid
      from public.payments where sale_id = s.id and method = 'cash';
    v_cash_paid := v_cash_paid - coalesce((select sum(cash_cents) from public.refunds where sale_id = s.id), 0);
    if v_remaining > v_cash_paid then
      raise exception 'That is more than was paid for the sale.';
    end if;
    if v_remaining > private.shift_expected_cash(sh.id) then
      raise exception 'The drawer does not have enough cash for this refund.';
    end if;
    v_cash := v_remaining;
  end if;

  v_method := case
    when v_amount = 0 then 'none'
    when (v_cash > 0)::int + (v_gift > 0)::int + (v_promo > 0)::int > 1 then 'mixed'
    when v_cash > 0 then 'cash'
    when v_gift > 0 then 'gift_card'
    else 'promo_card' end;

  insert into public.refunds (id, sale_id, shift_id, amount_cents, method, cash_cents, gift_card_cents,
                              promo_cents, gift_card_id, return_to_shelf, reason, approved_by, by)
  values (v_refund_id, s.id, sh.id, v_amount, v_method, v_cash, v_gift, v_promo, v_first_card, v_shelf,
          btrim(p_reason),
          case when private.member_can(sh.cashier_id, 'void_refund') then null else p_officer_id end,
          sh.cashier_id);

  for r in select x from jsonb_array_elements(v_items) x loop
    insert into public.refund_lines (refund_id, sale_line_id, qty, amount_cents, unit_cost_cents)
    values (v_refund_id, (r ->> 'sale_line_id')::uuid, (r ->> 'qty')::integer, (r ->> 'amount_cents')::bigint,
            (r ->> 'unit_cost_cents')::bigint);
    if v_shelf then
      perform private.post_movement((r ->> 'product_id')::uuid, (r ->> 'qty')::integer, 'refund_to_shelf',
                                    (r ->> 'unit_cost_cents')::bigint, 'refund', v_refund_id::text,
                                    btrim(p_reason), sh.cashier_id);
    end if;
  end loop;

  perform private.write_log('sale_refunded', 'sale', s.id::text, v_amount, null,
    jsonb_build_object('refund_id', v_refund_id, 'cash_cents', v_cash, 'gift_card_cents', v_gift,
                       'promo_cents', v_promo, 'return_to_shelf', v_shelf),
    btrim(p_reason), sh.cashier_id);
  return jsonb_build_object('ok', true, 'refund_id', v_refund_id, 'amount_cents', v_amount,
                            'cash_cents', v_cash, 'gift_card_cents', v_gift, 'promo_cents', v_promo,
                            'expected_cash_cents', private.shift_expected_cash(sh.id));
end
$$;

-------------------------------------------------------------------------------
-- RPC: outage backup
-------------------------------------------------------------------------------

-- Paper sales entered after an outage, with a photo of the tally sheet.
-- Pending until a different officer verifies it; stock moves on verification.
-- p_lines: [{product_id, qty}]
create function public.log_outage_sale(p_client_uuid uuid, p_shift_id uuid, p_occurred_on date,
                                       p_lines jsonb, p_photo_path text, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  sh public.shifts;
  v_existing uuid;
  v_sale_id uuid := gen_random_uuid();
  r jsonb;
  pr public.products;
  v_line_no integer := 0;
  v_total bigint := 0;
  v_cashier uuid;
begin
  perform private.require('ring_sales');
  perform pg_advisory_xact_lock(hashtext('sale:' || p_client_uuid::text));
  select id into v_existing from public.sales where client_uuid = p_client_uuid;
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'sale', private.sale_json(v_existing));
  end if;
  if coalesce(btrim(p_photo_path), '') = '' then
    raise exception 'A photo of the tally sheet is required.';
  end if;
  if p_occurred_on is null or p_occurred_on > private.local_today() then
    raise exception 'Enter the day of the outage.';
  end if;
  if p_shift_id is not null then
    sh := private.require_open_shift(p_shift_id);
    v_cashier := sh.cashier_id;
  else
    v_cashier := me.id;
  end if;

  insert into public.sales (id, client_uuid, shift_id, cashier_id, entered_by, type, status, note,
                            occurred_on, outage_photo_path)
  values (v_sale_id, p_client_uuid, sh.id, v_cashier, me.id, 'outage', 'pending', nullif(btrim(p_note), ''),
          p_occurred_on, btrim(p_photo_path));

  for r in
    select jsonb_build_object('product_id', x ->> 'product_id', 'qty', sum((x ->> 'qty')::integer)) as v
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
    group by x ->> 'product_id'
    order by x ->> 'product_id'
  loop
    if coalesce((r ->> 'qty')::integer, 0) <= 0 then
      continue;
    end if;
    select * into pr from public.products where id = (r ->> 'product_id')::uuid;
    if not found then
      raise exception 'Unknown product on the tally sheet.';
    end if;
    v_line_no := v_line_no + 1;
    insert into public.sale_lines (sale_id, line_no, kind, product_id, qty, unit_price_cents,
                                   list_price_cents, unit_cost_cents)
    values (v_sale_id, v_line_no, 'product', pr.id, (r ->> 'qty')::integer, pr.price_cents, pr.price_cents,
            pr.avg_cost_cents);
    v_total := v_total + (r ->> 'qty')::integer * pr.price_cents;
  end loop;
  if v_line_no = 0 then
    raise exception 'Enter at least one item from the tally sheet.';
  end if;

  insert into public.payments (sale_id, method, amount_cents)
  select v_sale_id, 'cash', v_total where v_total > 0;
  update public.sales set subtotal_cents = v_total, total_cents = v_total where id = v_sale_id;

  perform private.write_log('outage_sale_logged', 'sale', v_sale_id::text, v_total, null,
    jsonb_build_object('occurred_on', p_occurred_on, 'shift_id', sh.id, 'lines', v_line_no), null, me.id);
  return jsonb_build_object('ok', true, 'duplicate', false, 'sale', private.sale_json(v_sale_id));
end
$$;

create function public.verify_outage_sale(p_sale_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  s public.sales;
  l public.sale_lines;
  v_on_hand integer;
begin
  perform private.require('verify_outage');
  select * into s from public.sales where id = p_sale_id for update;
  if not found or s.type <> 'outage' or s.status <> 'pending' then
    raise exception 'That outage entry is not pending.';
  end if;
  if me.id in (s.cashier_id, s.entered_by) then
    raise exception 'A different officer has to verify your own outage entry.' using errcode = '42501';
  end if;
  if not p_approve and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why the entry is rejected.';
  end if;

  if p_approve then
    for l in select * from public.sale_lines where sale_id = s.id order by line_no loop
      perform 1 from public.products where id = l.product_id for update;
      v_on_hand := private.on_hand(l.product_id);
      if v_on_hand < l.qty then
        raise exception 'The tally sheet sold more % than the ledger has. Count it first.',
          (select name from public.products where id = l.product_id);
      end if;
      perform private.post_movement(l.product_id, -l.qty, 'sale', l.unit_cost_cents, 'sale', s.id::text,
                                    'Outage', s.cashier_id);
    end loop;
  end if;

  update public.sales
     set status = case when p_approve then 'completed'::public.sale_status else 'rejected'::public.sale_status end,
         verified_by = me.id, verified_at = now(), verify_note = nullif(btrim(p_note), '')
   where id = s.id;
  perform private.write_log(case when p_approve then 'outage_sale_verified' else 'outage_sale_rejected' end,
                            'sale', s.id::text, s.total_cents, jsonb_build_object('status', 'pending'),
                            jsonb_build_object('status', case when p_approve then 'completed' else 'rejected' end),
                            nullif(btrim(p_note), ''));
  return jsonb_build_object('ok', true, 'sale', private.sale_json(s.id));
end
$$;

create function public.pending_outage_sales() returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('verify_outage');
  return (select coalesce(jsonb_agg(private.sale_json(s.id) order by s.created_at), '[]'::jsonb)
          from public.sales s where s.type = 'outage' and s.status = 'pending');
end
$$;

-------------------------------------------------------------------------------
-- RLS
-------------------------------------------------------------------------------

alter table public.shifts enable row level security;
alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.payments enable row level security;
alter table public.refunds enable row level security;
alter table public.refund_lines enable row level security;
alter table public.cash_handoffs enable row level security;

create function public.can_see_shift(p_shift_id uuid) returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.shifts sh
    where sh.id = p_shift_id
      and (sh.cashier_id = public.current_member_id() or sh.opened_by = public.current_member_id()))
$$;

create policy shifts_read on public.shifts for select to authenticated
  using ((select public.can('view_reports'))
         or cashier_id = (select public.current_member_id())
         or opened_by = (select public.current_member_id()));
create policy sales_read on public.sales for select to authenticated
  using ((select public.can('view_reports')) or public.can_see_shift(shift_id)
         or cashier_id = (select public.current_member_id()));
create policy sale_lines_read on public.sale_lines for select to authenticated
  using ((select public.can('view_reports'))
         or exists (select 1 from public.sales s where s.id = sale_id));
create policy payments_read on public.payments for select to authenticated
  using ((select public.can('view_reports'))
         or exists (select 1 from public.sales s where s.id = sale_id));
create policy refunds_read on public.refunds for select to authenticated
  using ((select public.can('view_reports')) or public.can_see_shift(shift_id));
create policy refund_lines_read on public.refund_lines for select to authenticated
  using ((select public.can('view_reports'))
         or exists (select 1 from public.refunds r where r.id = refund_id));
create policy cash_handoffs_read on public.cash_handoffs for select to authenticated
  using ((select public.can('view_reports')) or public.can_see_shift(shift_id));

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
