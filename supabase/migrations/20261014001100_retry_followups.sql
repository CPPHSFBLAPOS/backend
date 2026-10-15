-- Follow-ups to 1000 from its review:
--   1. sales.client_uuid is not readable over the API. A retry with it returns
--      full card codes to the people on that shift, and the shared Register
--      account can see every shift it opened, so the id has to stay with the
--      device that made it.
--   2. A retried sale answers with the change the server worked out, like a
--      first-time sale does.

revoke select on public.sales from authenticated;
grant select (id, number, shift_id, cashier_id, entered_by, type, status, subtotal_cents, load_cents,
              total_cents, promo_cents, cash_tendered_cents, change_cents, note, reason, occurred_on,
              outage_photo_path, verified_by, verified_at, verify_note, voided_at, voided_by, void_reason,
              void_approved_by, created_at)
  on public.sales to authenticated;

create or replace function public.complete_sale(
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
  v_sale jsonb;
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

  v_sale := private.sale_json(v_existing);
  return jsonb_build_object('ok', true, 'duplicate', true, 'change_cents', v_sale -> 'change_cents',
                            'new_cards', v_new_cards, 'sale', v_sale);
end
$$;

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
