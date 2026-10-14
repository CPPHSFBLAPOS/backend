-- Phase 4 (tables first, so the register can redeem and load cards):
-- gift cards and their ledger. A card's balance is the sum of its
-- transactions; there is no balance column.

create table public.gift_cards (
  id uuid primary key default gen_random_uuid(),
  -- 10 characters without 0, O, 1 or I.
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  type text not null check (type in ('paid', 'promo')),
  status text not null default 'active' check (status in ('active', 'deactivated')),
  issued_by uuid references public.members (id),
  note text,
  legacy_code text,
  replaced_by uuid references public.gift_cards (id),
  created_at timestamptz not null default now(),
  deactivated_at timestamptz
);

create table public.gift_card_txns (
  id bigint generated always as identity primary key,
  card_id uuid not null references public.gift_cards (id),
  type text not null check (type in ('issue', 'load', 'redeem', 'refund', 'void', 'transfer_out',
                                     'transfer_in', 'import')),
  amount_cents bigint not null check (amount_cents <> 0),
  sale_id uuid,
  by uuid references public.members (id),
  at timestamptz not null default now(),
  note text
);
create index gift_card_txns_card_idx on public.gift_card_txns (card_id);
create index gift_card_txns_sale_idx on public.gift_card_txns (sale_id);
create trigger gift_card_txns_append_only before update or delete on public.gift_card_txns
  for each row execute function private.forbid_change();

create view public.gift_card_balance with (security_invoker = true) as
  select c.id as card_id, c.code, c.type, c.status, c.created_at, c.note,
         coalesce(sum(t.amount_cents), 0)::bigint as balance_cents
  from public.gift_cards c
  left join public.gift_card_txns t on t.card_id = c.id
  group by c.id;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Codes come from a cryptographic random source. 256 is a multiple of the
-- 32-character alphabet, so every character is equally likely.
create function private.new_gift_card_code() returns text
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(10);
    v_code := '';
    for i in 0..9 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.gift_cards where code = v_code);
  end loop;
  return v_code;
end
$$;

create function private.normalize_card_code(p_code text) returns text
language sql immutable
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

create function private.card_balance(p_card_id uuid) returns bigint
language sql stable
as $$
  select coalesce(sum(amount_cents), 0)::bigint from public.gift_card_txns where card_id = p_card_id
$$;

-- Locks the card row so two registers cannot spend the same balance at once.
create function private.lock_card(p_code text) returns public.gift_cards
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.gift_cards;
begin
  select * into v from public.gift_cards where code = private.normalize_card_code(p_code) for update;
  if not found then
    raise exception 'No gift card with code %.', private.normalize_card_code(p_code);
  end if;
  if v.status <> 'active' then
    raise exception 'Gift card % is deactivated.', v.code;
  end if;
  return v;
end
$$;

create function private.create_gift_card(p_type text, p_issued_by uuid, p_note text)
returns public.gift_cards
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.gift_cards;
begin
  insert into public.gift_cards (code, type, issued_by, note)
  values (private.new_gift_card_code(), p_type, p_issued_by, nullif(btrim(p_note), ''))
  returning * into v;
  return v;
end
$$;

create function private.card_txn(p_card_id uuid, p_type text, p_amount_cents bigint, p_sale_id uuid,
                                 p_actor_id uuid, p_note text default null)
returns bigint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
  v_balance bigint;
begin
  insert into public.gift_card_txns (card_id, type, amount_cents, sale_id, by, note)
  values (p_card_id, p_type, p_amount_cents, p_sale_id, coalesce(p_actor_id, public.current_member_id()),
          p_note)
  returning id into v_id;
  v_balance := private.card_balance(p_card_id);
  if v_balance < 0 then
    raise exception 'That would take the card below $0.00.';
  end if;
  perform private.write_log('gift_card_' || p_type, 'gift_card', p_card_id::text, p_amount_cents, null,
    jsonb_build_object('txn_id', v_id, 'sale_id', p_sale_id, 'balance_cents', v_balance),
    p_note, p_actor_id);
  return v_id;
end
$$;

create function private.card_json(c public.gift_cards) returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'id', c.id, 'code', c.code, 'type', c.type, 'status', c.status, 'note', c.note,
    'created_at', c.created_at, 'balance_cents', private.card_balance(c.id),
    'replaced_by_code', (select r.code from public.gift_cards r where r.id = c.replaced_by))
$$;

-------------------------------------------------------------------------------
-- RPC
-------------------------------------------------------------------------------

-- Promo cards (Treasurer and up) are issued with their value. Paid cards are
-- issued blank here and loaded at the register, where the cash is counted.
create function public.issue_gift_card(p_type text, p_amount_cents bigint default 0,
                                       p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  c public.gift_cards;
begin
  if p_type = 'promo' then
    perform private.require('issue_promo');
    if coalesce(p_amount_cents, 0) <= 0 then
      raise exception 'A promo card needs an amount.';
    end if;
  elsif p_type = 'paid' then
    perform private.require('sell_gift_cards');
    if coalesce(p_amount_cents, 0) <> 0 then
      raise exception 'Load paid cards at the register so the cash is counted.';
    end if;
  else
    raise exception 'A card is paid or promo.';
  end if;
  c := private.create_gift_card(p_type, public.current_member_id(), p_note);
  perform private.write_log('gift_card_created', 'gift_card', c.id::text, null, null,
                            jsonb_build_object('type', p_type));
  if p_type = 'promo' then
    perform private.card_txn(c.id, 'issue', p_amount_cents, null, null, p_note);
  end if;
  return private.card_json(c);
end
$$;

create function public.reload_gift_card(p_card_id uuid, p_amount_cents bigint, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  c public.gift_cards;
begin
  perform private.require('issue_promo');
  select * into c from public.gift_cards where id = p_card_id for update;
  if not found or c.status <> 'active' then
    raise exception 'That card is not active.';
  end if;
  if c.type <> 'promo' then
    raise exception 'Reload paid cards at the register so the cash is counted.';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'Enter an amount.';
  end if;
  perform private.card_txn(c.id, 'load', p_amount_cents, null, null, p_note);
  return private.card_json(c);
end
$$;

-- Lost card: deactivate it and move its balance to a new card.
create function public.deactivate_and_transfer(p_card_id uuid, p_reason text) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  old public.gift_cards;
  v_new public.gift_cards;
  v_balance bigint;
begin
  perform private.require('void_refund');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Give a reason.';
  end if;
  select * into old from public.gift_cards where id = p_card_id for update;
  if not found or old.status <> 'active' then
    raise exception 'That card is not active.';
  end if;
  v_balance := private.card_balance(old.id);
  v_new := private.create_gift_card(old.type, public.current_member_id(),
                                    format('Replaces %s', old.code));
  if v_balance > 0 then
    perform private.card_txn(old.id, 'transfer_out', -v_balance, null, null, p_reason);
    perform private.card_txn(v_new.id, 'transfer_in', v_balance, null, null, p_reason);
  end if;
  update public.gift_cards
     set status = 'deactivated', replaced_by = v_new.id, deactivated_at = now()
   where id = old.id;
  perform private.write_log('gift_card_deactivated', 'gift_card', old.id::text, v_balance, null,
                            jsonb_build_object('new_card_id', v_new.id), p_reason);
  return jsonb_build_object('old_code', old.code, 'moved_cents', v_balance,
                            'card', private.card_json(v_new));
end
$$;

-- Balance checks happen on the register screen.
create function public.lookup_gift_card(p_code text) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  c public.gift_cards;
begin
  perform private.require('sell_gift_cards');
  select * into c from public.gift_cards where code = private.normalize_card_code(p_code);
  if not found then
    raise exception 'No gift card with code %.', private.normalize_card_code(p_code);
  end if;
  return private.card_json(c);
end
$$;

-- Base44 cards that still have money: rows [{code, type, balance_cents, note}].
-- A Base44 code that does not fit the new format gets a new code; the old one
-- is kept in legacy_code.
create function public.import_gift_cards(p_rows jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  r jsonb;
  v_code text;
  c public.gift_cards;
  v_added integer := 0;
  v_skipped integer := 0;
  v_cards jsonb := '[]'::jsonb;
begin
  perform private.require('change_settings');
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce((r ->> 'balance_cents')::bigint, 0) <= 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_code := private.normalize_card_code(r ->> 'code');
    if exists (select 1 from public.gift_cards where legacy_code = nullif(r ->> 'code', '')
                                                  or code = v_code) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    if v_code !~ '^[A-HJ-NP-Z2-9]{10}$' then
      v_code := private.new_gift_card_code();
    end if;
    insert into public.gift_cards (code, type, issued_by, note, legacy_code)
    values (v_code, coalesce(nullif(r ->> 'type', ''), 'paid'), public.current_member_id(),
            coalesce(nullif(r ->> 'note', ''), 'Imported from Base44'), nullif(r ->> 'code', ''))
    returning * into c;
    perform private.card_txn(c.id, 'import', (r ->> 'balance_cents')::bigint, null, null,
                             'Base44 balance');
    v_added := v_added + 1;
    v_cards := v_cards || jsonb_build_object('legacy_code', r ->> 'code', 'code', c.code);
  end loop;
  perform private.write_log('import_gift_cards', 'import', 'base44', null, null,
                            jsonb_build_object('added', v_added, 'skipped', v_skipped));
  return jsonb_build_object('added', v_added, 'skipped', v_skipped, 'cards', v_cards);
end
$$;

-------------------------------------------------------------------------------
-- RLS
-------------------------------------------------------------------------------

alter table public.gift_cards enable row level security;
alter table public.gift_card_txns enable row level security;

create policy gift_cards_read on public.gift_cards for select to authenticated
  using ((select public.can('sell_gift_cards')));
create policy gift_card_txns_read on public.gift_card_txns for select to authenticated
  using ((select public.can('sell_gift_cards')));

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
