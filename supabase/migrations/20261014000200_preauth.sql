-- Phase 2: Pre-auth purchasing
-- The Preauthorization Purchase Order Form: Sam's Club listings, the form and
-- its lines, drawn signatures tied to a hash of the form, receipts, purchase,
-- receiving (the only step that changes stock) and closing.

create type public.preauth_status as enum (
  'draft', 'awaiting_advisor', 'approved', 'purchased', 'received', 'closed', 'rejected'
);

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------

create table public.vendor_items (
  id uuid primary key default gen_random_uuid(),
  vendor text not null default 'Sam''s Club',
  item_number text,
  url text check (url is null or url ~* '^https://([a-z0-9-]+\.)*samsclub\.com(/|$)'),
  name text not null check (length(btrim(name)) > 0),
  units_per_pack integer not null check (units_per_pack > 0),
  price_cents bigint not null check (price_cents >= 0),
  sale_price_cents bigint check (sale_price_cents >= 0),
  query text,
  source text not null default 'search' check (source in ('search', 'paste')),
  product_id uuid references public.products (id),
  checked_at timestamptz not null default now(),
  checked_by uuid references public.members (id)
);
create unique index vendor_items_item_number_key on public.vendor_items (item_number)
  where item_number is not null;
create index vendor_items_checked_idx on public.vendor_items (checked_at desc);

create sequence public.preauth_number_seq;

create table public.preauths (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique default nextval('public.preauth_number_seq'),
  status public.preauth_status not null default 'draft',
  requester_id uuid not null references public.members (id),
  student_name text not null,
  grade smallint,
  fbla_role text,
  request_date date not null default ((now() at time zone 'America/New_York')::date),
  vendor text not null default 'Sam''s Club',
  website text default 'https://www.samsclub.com',
  purposes text[] not null default '{}'
    check (purposes <@ array['competition', 'event', 'fundraiser', 'supplies', 'other']),
  purpose_other text,
  justification text,
  shipping_cents bigint not null default 0 check (shipping_cents >= 0),
  lines_total_cents bigint not null default 0,
  grand_total_cents bigint not null default 0,
  approved_total_cents bigint,
  purchase_date date,
  receipt_due_date date,
  overdue boolean not null default false,
  notes text,
  reject_comment text,
  overage_approved_by uuid references public.members (id),
  overage_approved_at timestamptz,
  reimbursed_cents bigint,
  reimbursed_to text,
  reimbursed_at timestamptz,
  pdf_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);
create index preauths_status_idx on public.preauths (status);
create trigger preauths_touch before update on public.preauths
  for each row execute function private.touch_updated_at();

create table public.preauth_lines (
  id uuid primary key default gen_random_uuid(),
  preauth_id uuid not null references public.preauths (id),
  line_no integer not null,
  vendor_item_id uuid references public.vendor_items (id),
  product_id uuid references public.products (id),
  new_name text,
  item_number text,
  url text,
  units_per_pack integer not null check (units_per_pack > 0),
  packs integer not null check (packs > 0),
  est_pack_price_cents bigint not null check (est_pack_price_cents >= 0),
  sell_price_cents bigint not null check (sell_price_cents >= 0),
  packs_bought integer check (packs_bought >= 0),
  actual_pack_price_cents bigint check (actual_pack_price_cents >= 0),
  units_received integer check (units_received >= 0),
  substitute_product_id uuid references public.products (id),
  received_unit_cost_cents bigint,
  check (product_id is not null or length(btrim(coalesce(new_name, ''))) > 0),
  unique (preauth_id, line_no)
);

create table public.signatures (
  id uuid primary key default gen_random_uuid(),
  document_type text not null check (document_type in ('preauth', 'handoff')),
  document_id uuid not null,
  role text not null check (role in ('student', 'advisor', 'overage', 'from', 'to')),
  member_id uuid not null references public.members (id),
  typed_name text not null check (length(btrim(typed_name)) > 0),
  strokes jsonb not null,
  image_path text,
  signed_at timestamptz not null default now(),
  doc_hash text,
  voided_at timestamptz
);
create index signatures_document_idx on public.signatures (document_type, document_id);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  preauth_id uuid not null references public.preauths (id),
  file_path text not null,
  total_cents bigint not null check (total_cents >= 0),
  tax_cents bigint not null default 0 check (tax_cents >= 0),
  uploaded_by uuid not null references public.members (id),
  uploaded_at timestamptz not null default now()
);
create index receipts_preauth_idx on public.receipts (preauth_id);
create trigger receipts_append_only before update or delete on public.receipts
  for each row execute function private.forbid_change();

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- SHA-256 of the form's fields and lines. Signatures store it, so any change
-- to what was signed is detectable.
create function public.preauth_hash(p_id uuid) returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to(jsonb_build_object(
    'number', p.number,
    'requester_id', p.requester_id,
    'student_name', p.student_name,
    'grade', p.grade,
    'fbla_role', p.fbla_role,
    'request_date', p.request_date,
    'vendor', p.vendor,
    'website', p.website,
    'purposes', to_jsonb(p.purposes),
    'purpose_other', p.purpose_other,
    'justification', p.justification,
    'shipping_cents', p.shipping_cents,
    'grand_total_cents', p.grand_total_cents,
    'notes', p.notes,
    'lines', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'line_no', l.line_no,
        'vendor_item_id', l.vendor_item_id,
        'product_id', l.product_id,
        'new_name', l.new_name,
        'item_number', l.item_number,
        'url', l.url,
        'units_per_pack', l.units_per_pack,
        'packs', l.packs,
        'est_pack_price_cents', l.est_pack_price_cents,
        'sell_price_cents', l.sell_price_cents
      ) order by l.line_no), '[]'::jsonb)
      from public.preauth_lines l where l.preauth_id = p.id)
  )::text, 'UTF8')), 'hex')
  from public.preauths p
  where p.id = p_id
$$;

create function private.preauth_signature(p_id uuid, p_role text) returns public.signatures
language sql stable
as $$
  select * from public.signatures
  where document_type = 'preauth' and document_id = p_id and role = p_role and voided_at is null
  order by signed_at desc
  limit 1
$$;

create function private.void_preauth_signatures(p_id uuid, p_reason text) returns integer
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  update public.signatures
     set voided_at = now()
   where document_type = 'preauth' and document_id = p_id and voided_at is null;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform private.write_log('preauth_signatures_voided', 'preauth', p_id::text, null, null,
                              jsonb_build_object('voided', v_n), p_reason);
  end if;
  return v_n;
end
$$;

create function private.preauth_receipts_total(p_id uuid) returns bigint
language sql stable
as $$
  select coalesce(sum(total_cents), 0)::bigint from public.receipts where preauth_id = p_id
$$;

create function private.preauth_needs_overage(p public.preauths) returns boolean
language sql stable
as $$
  select p.approved_total_cents is not null
     and private.preauth_receipts_total(p.id) > p.approved_total_cents
     and p.overage_approved_at is null
$$;

create function private.preauth_summary(p_id uuid) returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'number', p.number, 'status', p.status, 'grand_total_cents', p.grand_total_cents,
    'shipping_cents', p.shipping_cents, 'lines', (select count(*) from public.preauth_lines l where l.preauth_id = p.id))
  from public.preauths p where p.id = p_id
$$;

create function private.insert_signature(
  p_document_type text, p_document_id uuid, p_role text, p_member_id uuid,
  p_typed_name text, p_strokes jsonb, p_image_path text, p_doc_hash text
) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if coalesce(btrim(p_typed_name), '') = '' then
    raise exception 'Type your name under the signature.';
  end if;
  if p_strokes is null or jsonb_typeof(p_strokes) <> 'array' or jsonb_array_length(p_strokes) = 0 then
    raise exception 'Draw a signature first.';
  end if;
  insert into public.signatures (document_type, document_id, role, member_id, typed_name, strokes,
                                 image_path, doc_hash)
  values (p_document_type, p_document_id, p_role, p_member_id, btrim(p_typed_name), p_strokes,
          nullif(p_image_path, ''), p_doc_hash)
  returning id into v_id;
  return v_id;
end
$$;

-------------------------------------------------------------------------------
-- RPC: Sam's Club listings (called by the sams-lookup function with the
-- member's own token, so these checks apply to it too)
-------------------------------------------------------------------------------

create function private.samsclub_item_number(p_url text) returns text
language sql immutable
as $$
  select (regexp_match(coalesce(p_url, ''), '/(?:ip/[^?#]*/)?([0-9]{5,})(?:[/?#]|$)'))[1]
$$;

-- Returns a cached listing checked within the cache window, or reserves one of
-- today's lookups. The function only calls the Claude API after this says ok.
create function public.begin_sams_lookup(p_query text default null, p_url text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  s public.settings;
  v_item_number text := private.samsclub_item_number(p_url);
  v_cached public.vendor_items;
  v_used integer;
begin
  perform private.require('preauth_view');
  if coalesce(btrim(p_query), '') = '' and coalesce(btrim(p_url), '') = '' then
    raise exception 'Give a samsclub.com link or an item name.';
  end if;
  if p_url is not null and btrim(p_url) <> ''
     and p_url !~* '^https://([a-z0-9-]+\.)*samsclub\.com(/|$)' then
    raise exception 'Only samsclub.com links can be looked up.';
  end if;
  select * into s from public.settings where id = 1;

  select * into v_cached
  from public.vendor_items v
  where v.checked_at > now() - make_interval(days => s.sams_cache_days)
    and ((v_item_number is not null and v.item_number = v_item_number)
      or (nullif(btrim(p_url), '') is not null and v.url = btrim(p_url))
      or (nullif(btrim(p_query), '') is not null and lower(v.query) = lower(btrim(p_query))))
  order by v.checked_at desc
  limit 1;
  if found then
    return jsonb_build_object('ok', true, 'cached', true, 'item', to_jsonb(v_cached));
  end if;

  select count(*) into v_used
  from public.log_entries
  where action = 'sams_lookup'
    and at >= (private.local_today()::timestamp at time zone 'America/New_York');
  if v_used >= s.sams_daily_limit then
    return jsonb_build_object('ok', false, 'error', 'daily_limit',
      'message', format('The store has used all %s Sam''s Club lookups for today. Paste the page text or type the item in.', s.sams_daily_limit));
  end if;

  perform private.write_log('sams_lookup', 'vendor_lookup', null, null, null,
                            jsonb_build_object('query', p_query, 'url', p_url));
  return jsonb_build_object('ok', true, 'cached', false, 'remaining', s.sams_daily_limit - v_used - 1);
end
$$;

-- p: {item_number, url, name, units_per_pack, price_cents, sale_price_cents, query, source}
create function public.save_vendor_item(p jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v public.vendor_items;
  v_item_number text := nullif(btrim(p ->> 'item_number'), '');
  v_url text := nullif(btrim(p ->> 'url'), '');
begin
  perform private.require('preauth_view');
  if v_url is not null and v_url !~* '^https://([a-z0-9-]+\.)*samsclub\.com(/|$)' then
    raise exception 'Listings must link to samsclub.com.';
  end if;
  v_item_number := coalesce(v_item_number, private.samsclub_item_number(v_url));

  if v_item_number is not null then
    select * into v from public.vendor_items where item_number = v_item_number for update;
  end if;

  if v.id is null then
    insert into public.vendor_items (item_number, url, name, units_per_pack, price_cents,
                                     sale_price_cents, query, source, checked_by)
    values (v_item_number, v_url, btrim(p ->> 'name'), (p ->> 'units_per_pack')::integer,
            (p ->> 'price_cents')::bigint, (p ->> 'sale_price_cents')::bigint,
            nullif(btrim(p ->> 'query'), ''), coalesce(p ->> 'source', 'search'),
            public.current_member_id())
    returning * into v;
  else
    update public.vendor_items
       set url = coalesce(v_url, url),
           name = btrim(p ->> 'name'),
           units_per_pack = (p ->> 'units_per_pack')::integer,
           price_cents = (p ->> 'price_cents')::bigint,
           sale_price_cents = (p ->> 'sale_price_cents')::bigint,
           query = coalesce(nullif(btrim(p ->> 'query'), ''), query),
           source = coalesce(p ->> 'source', source),
           checked_at = now(),
           checked_by = public.current_member_id()
     where id = v.id
    returning * into v;
  end if;

  perform private.write_log('vendor_item_saved', 'vendor_item', v.id::text, v.price_cents, null,
                            to_jsonb(v));
  return to_jsonb(v);
end
$$;

-------------------------------------------------------------------------------
-- RPC: the form
-------------------------------------------------------------------------------

-- p_form: {vendor, website, purposes[], purpose_other, justification, shipping_cents, notes}
-- p_lines: [{vendor_item_id, product_id, new_name, item_number, url, units_per_pack, packs,
--            est_pack_price_cents, sell_price_cents}]
-- Any edit after a signature voids every signature and returns the form to Draft.
create function public.save_preauth(p_id uuid, p_form jsonb, p_lines jsonb) returns uuid
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  p public.preauths;
  v_id uuid;
  v_old_hash text;
  v_purposes text[];
  v_lines_total bigint;
  v_shipping bigint := coalesce((p_form ->> 'shipping_cents')::bigint, 0);
  r jsonb;
  v_vi public.vendor_items;
  v_n integer := 0;
begin
  perform private.require('preauth_request');

  select coalesce(array_agg(distinct x order by x), '{}') into v_purposes
  from jsonb_array_elements_text(coalesce(p_form -> 'purposes', '[]'::jsonb)) x;
  if 'other' = any (v_purposes) and coalesce(btrim(p_form ->> 'purpose_other'), '') = '' then
    raise exception 'Describe the Other purpose.';
  end if;
  if v_shipping < 0 then
    raise exception 'Shipping cannot be negative.';
  end if;

  if p_id is null then
    insert into public.preauths (requester_id, student_name, grade, fbla_role)
    values (me.id, me.display_name, me.grade, initcap(me.role::text))
    returning * into p;
  else
    select * into p from public.preauths where id = p_id for update;
    if not found then
      raise exception 'Form not found.';
    end if;
    if p.requester_id <> me.id then
      raise exception 'Only the student who started this form can edit it.' using errcode = '42501';
    end if;
    if p.status not in ('draft', 'awaiting_advisor', 'rejected', 'approved') then
      raise exception 'This form is % and can no longer be edited.', replace(p.status::text, '_', ' ');
    end if;
    v_old_hash := public.preauth_hash(p.id);
  end if;
  v_id := p.id;

  update public.preauths
     set vendor = coalesce(nullif(btrim(p_form ->> 'vendor'), ''), 'Sam''s Club'),
         website = nullif(btrim(p_form ->> 'website'), ''),
         purposes = v_purposes,
         purpose_other = case when 'other' = any (v_purposes) then btrim(p_form ->> 'purpose_other') end,
         justification = nullif(btrim(p_form ->> 'justification'), ''),
         shipping_cents = v_shipping,
         notes = nullif(btrim(p_form ->> 'notes'), '')
   where id = v_id;

  delete from public.preauth_lines where preauth_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_n := v_n + 1;
    v_vi := null;
    if nullif(r ->> 'vendor_item_id', '') is not null then
      select * into v_vi from public.vendor_items where id = (r ->> 'vendor_item_id')::uuid;
    end if;
    insert into public.preauth_lines (preauth_id, line_no, vendor_item_id, product_id, new_name,
                                      item_number, url, units_per_pack, packs, est_pack_price_cents,
                                      sell_price_cents)
    values (v_id, v_n, v_vi.id, nullif(r ->> 'product_id', '')::uuid,
            nullif(btrim(r ->> 'new_name'), ''),
            coalesce(nullif(btrim(r ->> 'item_number'), ''), v_vi.item_number),
            coalesce(nullif(btrim(r ->> 'url'), ''), v_vi.url),
            coalesce((r ->> 'units_per_pack')::integer, v_vi.units_per_pack),
            (r ->> 'packs')::integer,
            coalesce((r ->> 'est_pack_price_cents')::bigint,
                     coalesce(v_vi.sale_price_cents, v_vi.price_cents)),
            (r ->> 'sell_price_cents')::bigint);
  end loop;

  select coalesce(sum(packs::bigint * est_pack_price_cents), 0) into v_lines_total
  from public.preauth_lines where preauth_id = v_id;
  update public.preauths
     set lines_total_cents = v_lines_total,
         grand_total_cents = v_lines_total + v_shipping
   where id = v_id;

  if p_id is not null and public.preauth_hash(v_id) is distinct from v_old_hash then
    if private.void_preauth_signatures(v_id, 'Edited after signing') > 0
       or p.status <> 'draft' then
      update public.preauths set status = 'draft', approved_total_cents = null where id = v_id;
    end if;
  end if;

  perform private.write_log(case when p_id is null then 'preauth_created' else 'preauth_saved' end,
    'preauth', v_id::text, (select grand_total_cents from public.preauths where id = v_id),
    null, private.preauth_summary(v_id));
  return v_id;
end
$$;

-- Student signs first (submits the form); only a member with the advisor
-- role can approve. Each signature stores the form's hash at that moment.
create function public.sign_preauth(p_id uuid, p_role text, p_typed_name text, p_strokes jsonb,
                                    p_image_path text default null)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  p public.preauths;
  s public.settings;
  v_hash text;
  v_student public.signatures;
begin
  select * into p from public.preauths where id = p_id for update;
  if not found then
    raise exception 'Form not found.';
  end if;
  select * into s from public.settings where id = 1;
  v_hash := public.preauth_hash(p_id);

  if p_role = 'student' then
    perform private.require('preauth_request');
    if p.requester_id <> me.id then
      raise exception 'Only the student who filled out the form signs as Student.' using errcode = '42501';
    end if;
    if p.status not in ('draft', 'rejected') then
      raise exception 'This form is already signed.';
    end if;
    if not exists (select 1 from public.preauth_lines where preauth_id = p_id) then
      raise exception 'Add at least one item.';
    end if;
    if p.grand_total_cents > s.preauth_limit_cents then
      raise exception 'The grand total is over the $% limit.', to_char(s.preauth_limit_cents / 100.0, 'FM999,990.00');
    end if;
    if cardinality(p.purposes) = 0 then
      raise exception 'Check at least one purpose.';
    end if;
    if coalesce(btrim(p.justification), '') = '' then
      raise exception 'Write a justification.';
    end if;
    perform private.insert_signature('preauth', p_id, 'student', me.id, p_typed_name, p_strokes,
                                     p_image_path, v_hash);
    update public.preauths set status = 'awaiting_advisor', reject_comment = null where id = p_id;
    perform private.write_log('preauth_signed_student', 'preauth', p_id::text, p.grand_total_cents,
                              null, jsonb_build_object('hash', v_hash));
    return jsonb_build_object('ok', true, 'status', 'awaiting_advisor', 'hash', v_hash);

  elsif p_role = 'advisor' then
    perform private.require('preauth_approve');
    if p.status <> 'awaiting_advisor' then
      raise exception 'This form is not waiting for the Advisor.';
    end if;
    v_student := private.preauth_signature(p_id, 'student');
    if v_student.id is null or v_student.doc_hash <> v_hash then
      raise exception 'The form changed after the student signed. It needs a new student signature.';
    end if;
    if p.grand_total_cents > s.preauth_limit_cents then
      raise exception 'The grand total is over the limit.';
    end if;
    perform private.insert_signature('preauth', p_id, 'advisor', me.id, p_typed_name, p_strokes,
                                     p_image_path, v_hash);
    update public.preauths
       set status = 'approved', approved_total_cents = p.grand_total_cents
     where id = p_id;
    perform private.write_log('preauth_approved', 'preauth', p_id::text, p.grand_total_cents,
                              null, jsonb_build_object('hash', v_hash));
    return jsonb_build_object('ok', true, 'status', 'approved', 'hash', v_hash);
  end if;

  raise exception 'Sign as student or advisor.';
end
$$;

create function public.reject_preauth(p_id uuid, p_comment text) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
begin
  perform private.require('preauth_approve');
  if coalesce(btrim(p_comment), '') = '' then
    raise exception 'Rejecting needs a comment.';
  end if;
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status not in ('awaiting_advisor', 'approved') then
    raise exception 'Only a form waiting for approval, or approved and not yet bought, can be rejected.';
  end if;
  perform private.void_preauth_signatures(p_id, 'Rejected');
  update public.preauths
     set status = 'rejected', reject_comment = btrim(p_comment), approved_total_cents = null
   where id = p_id;
  perform private.write_log('preauth_rejected', 'preauth', p_id::text, null,
                            jsonb_build_object('status', p.status), jsonb_build_object('status', 'rejected'),
                            btrim(p_comment));
end
$$;

-- Nothing can be marked Purchased until the Advisor signs. The receipt is due
-- receipt_due_days after the purchase date.
create function public.record_purchase(p_id uuid, p_purchase_date date) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
  v_due date;
begin
  perform private.require('preauth_purchase');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status <> 'approved' then
    raise exception 'Only an approved form can be marked purchased.';
  end if;
  if private.preauth_signature(p_id, 'advisor') is null
     or (private.preauth_signature(p_id, 'advisor')).doc_hash <> public.preauth_hash(p_id) then
    raise exception 'The Advisor has not signed this version of the form.';
  end if;
  if p_purchase_date is null or p_purchase_date > private.local_today() then
    raise exception 'Enter the date of the purchase.';
  end if;
  if p_purchase_date < p.request_date then
    raise exception 'The purchase date is before the form was requested.';
  end if;
  v_due := p_purchase_date + (select receipt_due_days from public.settings where id = 1);
  update public.preauths
     set status = 'purchased', purchase_date = p_purchase_date, receipt_due_date = v_due
   where id = p_id;
  perform private.write_log('preauth_purchased', 'preauth', p_id::text, p.approved_total_cents, null,
                            jsonb_build_object('purchase_date', p_purchase_date, 'receipt_due_date', v_due));
  return jsonb_build_object('ok', true, 'receipt_due_date', v_due);
end
$$;

create function public.add_receipt(p_id uuid, p_file_path text, p_total_cents bigint,
                                   p_tax_cents bigint default 0)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
  v_id uuid;
begin
  perform private.require('preauth_purchase');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status not in ('purchased', 'received') then
    raise exception 'Receipts are added after the purchase is recorded.';
  end if;
  if coalesce(btrim(p_file_path), '') = '' then
    raise exception 'Upload a photo of the receipt.';
  end if;
  if p_total_cents is null or p_total_cents < 0 or coalesce(p_tax_cents, 0) < 0
     or coalesce(p_tax_cents, 0) > p_total_cents then
    raise exception 'Check the receipt total and tax.';
  end if;
  insert into public.receipts (preauth_id, file_path, total_cents, tax_cents, uploaded_by)
  values (p_id, btrim(p_file_path), p_total_cents, coalesce(p_tax_cents, 0), public.current_member_id())
  returning id into v_id;
  update public.preauths set overdue = false where id = p_id;
  select * into p from public.preauths where id = p_id;
  perform private.write_log('preauth_receipt_added', 'preauth', p_id::text, p_total_cents, null,
    jsonb_build_object('receipt_id', v_id, 'tax_cents', p_tax_cents,
                       'receipts_total_cents', private.preauth_receipts_total(p_id)));
  return jsonb_build_object('ok', true, 'receipt_id', v_id,
                            'needs_overage', private.preauth_needs_overage(p));
end
$$;

-- A receipt over the approved total needs the Advisor's sign-off.
create function public.approve_overage(p_id uuid, p_typed_name text, p_strokes jsonb,
                                       p_image_path text default null)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  me public.members := private.require_member();
  p public.preauths;
begin
  perform private.require('preauth_approve');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status not in ('purchased', 'received') then
    raise exception 'There is no purchase to approve an overage for.';
  end if;
  if private.preauth_receipts_total(p_id) <= coalesce(p.approved_total_cents, 0) then
    raise exception 'The receipts are within the approved total.';
  end if;
  perform private.insert_signature('preauth', p_id, 'overage', me.id, p_typed_name, p_strokes,
                                   p_image_path, public.preauth_hash(p_id));
  update public.preauths set overage_approved_by = me.id, overage_approved_at = now() where id = p_id;
  perform private.write_log('preauth_overage_approved', 'preauth', p_id::text,
                            private.preauth_receipts_total(p_id) - p.approved_total_cents);
end
$$;

-- No unauthorized reimbursement: a receipt first, and the Advisor's sign-off
-- when the receipts are over the approved total.
create function public.record_reimbursement(p_id uuid, p_amount_cents bigint, p_paid_to text)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
begin
  perform private.require('preauth_purchase');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status not in ('purchased', 'received', 'closed') then
    raise exception 'Nothing has been purchased on this form.';
  end if;
  if not exists (select 1 from public.receipts where preauth_id = p_id) then
    raise exception 'Upload the receipt before recording a reimbursement.';
  end if;
  if private.preauth_needs_overage(p) then
    raise exception 'The receipts are over the approved total. The Advisor must sign off first.';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0
     or p_amount_cents > private.preauth_receipts_total(p_id) then
    raise exception 'The reimbursement must be more than $0 and no more than the receipts.';
  end if;
  if coalesce(btrim(p_paid_to), '') = '' then
    raise exception 'Say who was reimbursed.';
  end if;
  if p.reimbursed_at is not null then
    raise exception 'A reimbursement is already recorded.';
  end if;
  update public.preauths
     set reimbursed_cents = p_amount_cents, reimbursed_to = btrim(p_paid_to), reimbursed_at = now()
   where id = p_id;
  perform private.write_log('preauth_reimbursed', 'preauth', p_id::text, p_amount_cents, null,
                            jsonb_build_object('paid_to', btrim(p_paid_to)));
end
$$;

-- Receiving: per line, packs bought, actual pack price, units received and an
-- optional substitute. Receipt tax is spread across lines by dollar share, the
-- result posts Receiving movements and updates each product's weighted
-- average cost:
--   new cost = (on hand * old cost + received * receipt cost) / (on hand + received)
create function public.receive_preauth(p_id uuid, p_lines jsonb) returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
  l public.preauth_lines;
  r jsonb;
  v_tax bigint;
  v_base bigint;
  v_allocated bigint := 0;
  v_last_id uuid;
  v_line_cost bigint;
  v_share bigint;
  v_unit_cost bigint;
  v_target uuid;
  v_on_hand integer;
  v_old_cost bigint;
  v_new_cost bigint;
  v_received integer := 0;
begin
  perform private.require('receiving');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status <> 'purchased' then
    raise exception 'Only a purchased form can be received.';
  end if;
  if not exists (select 1 from public.receipts where preauth_id = p_id) then
    raise exception 'A receipt photo is required before receiving.';
  end if;

  for l in select * from public.preauth_lines where preauth_id = p_id order by line_no for update loop
    select x into r from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
     where (x ->> 'line_id')::uuid = l.id;
    if r is null then
      raise exception 'Line % is missing from the receiving entry.', l.line_no;
    end if;
    if (r ->> 'packs_bought')::integer < 0 or (r ->> 'actual_pack_price_cents')::bigint < 0
       or (r ->> 'units_received')::integer < 0 then
      raise exception 'Line %: amounts cannot be negative.', l.line_no;
    end if;
    update public.preauth_lines
       set packs_bought = coalesce((r ->> 'packs_bought')::integer, l.packs),
           actual_pack_price_cents = coalesce((r ->> 'actual_pack_price_cents')::bigint, l.est_pack_price_cents),
           units_received = coalesce((r ->> 'units_received')::integer,
                                     coalesce((r ->> 'packs_bought')::integer, l.packs) * l.units_per_pack),
           substitute_product_id = nullif(r ->> 'substitute_product_id', '')::uuid
     where id = l.id;
  end loop;

  select coalesce(sum(tax_cents), 0) into v_tax from public.receipts where preauth_id = p_id;
  select coalesce(sum(packs_bought::bigint * actual_pack_price_cents), 0)
    into v_base
    from public.preauth_lines
   where preauth_id = p_id and units_received > 0;
  select id into v_last_id
    from public.preauth_lines
   where preauth_id = p_id and units_received > 0
   order by line_no desc limit 1;

  for l in
    select * from public.preauth_lines where preauth_id = p_id and units_received > 0 order by line_no
  loop
    v_line_cost := l.packs_bought::bigint * l.actual_pack_price_cents;
    if v_base = 0 then
      v_share := 0;
    elsif l.id = v_last_id then
      v_share := v_tax - v_allocated;
    else
      v_share := round(v_tax::numeric * v_line_cost / v_base)::bigint;
    end if;
    v_allocated := v_allocated + v_share;
    v_unit_cost := round((v_line_cost + v_share)::numeric / l.units_received)::bigint;

    v_target := coalesce(l.substitute_product_id, l.product_id);
    if v_target is null then
      insert into public.products (name, price_cents)
      values (btrim(l.new_name), l.sell_price_cents)
      returning id into v_target;
      insert into public.price_changes (product_id, old_cents, new_cents, by)
      values (v_target, null, l.sell_price_cents, public.current_member_id());
      perform private.write_log('product_added', 'product', v_target::text, l.sell_price_cents, null,
                                jsonb_build_object('name', l.new_name, 'from_preauth', p.number));
      update public.preauth_lines set product_id = v_target where id = l.id;
    end if;

    select avg_cost_cents into v_old_cost from public.products where id = v_target for update;
    v_on_hand := greatest(private.on_hand(v_target), 0);
    if v_old_cost is null or v_on_hand = 0 then
      v_new_cost := v_unit_cost;
    else
      v_new_cost := round((v_on_hand::numeric * v_old_cost + l.units_received::numeric * v_unit_cost)
                          / (v_on_hand + l.units_received))::bigint;
    end if;
    update public.products set avg_cost_cents = v_new_cost where id = v_target;
    if v_old_cost is distinct from v_new_cost then
      perform private.write_log('cost_updated', 'product', v_target::text, v_new_cost,
                                jsonb_build_object('avg_cost_cents', v_old_cost),
                                jsonb_build_object('avg_cost_cents', v_new_cost), 'Receiving');
    end if;
    perform private.post_movement(v_target, l.units_received, 'receiving', v_unit_cost, 'preauth',
                                  p_id::text, format('Pre-auth #%s', p.number));
    update public.preauth_lines set received_unit_cost_cents = v_unit_cost where id = l.id;
    v_received := v_received + l.units_received;
  end loop;

  update public.preauths set status = 'received' where id = p_id;
  perform private.write_log('preauth_received', 'preauth', p_id::text, v_base + v_tax, null,
                            jsonb_build_object('units', v_received, 'tax_cents', v_tax));
  return jsonb_build_object('ok', true, 'units', v_received);
end
$$;

create function public.close_preauth(p_id uuid) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
begin
  perform private.require('preauth_close');
  select * into p from public.preauths where id = p_id for update;
  if not found or p.status <> 'received' then
    raise exception 'Only a received form can be closed.';
  end if;
  if not exists (select 1 from public.receipts where preauth_id = p_id) then
    raise exception 'Upload the receipt before closing.';
  end if;
  if private.preauth_needs_overage(p) then
    raise exception 'The receipts are over the approved total. Approve the overage first.';
  end if;
  update public.preauths set status = 'closed', closed_at = now() where id = p_id;
  perform private.write_log('preauth_closed', 'preauth', p_id::text, private.preauth_receipts_total(p_id));
end
$$;

-- Stored by the preauth-pdf function after it draws the form.
create function public.set_preauth_pdf(p_id uuid, p_path text) returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require('preauth_view');
  update public.preauths set pdf_path = p_path where id = p_id;
  if not found then
    raise exception 'Form not found.';
  end if;
  perform private.write_log('preauth_pdf_stored', 'preauth', p_id::text, null, null,
                            jsonb_build_object('path', p_path));
end
$$;

-- Daily job: flag purchased forms with no receipt past the due date.
-- Runs as the service role from the daily-reminders function; the Advisor
-- can run it by hand too.
create function public.mark_overdue_preauths() returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_flagged jsonb;
  v_all jsonb;
  r record;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform private.require('preauth_close');
  end if;
  v_flagged := '[]'::jsonb;
  for r in
    select p.id, p.number, p.student_name, p.receipt_due_date
    from public.preauths p
    where p.status = 'purchased'
      and not p.overdue
      and p.receipt_due_date < private.local_today()
      and not exists (select 1 from public.receipts x where x.preauth_id = p.id)
    for update of p
  loop
    update public.preauths set overdue = true where id = r.id;
    perform private.write_log('preauth_overdue', 'preauth', r.id::text, null, null,
                              jsonb_build_object('receipt_due_date', r.receipt_due_date));
    v_flagged := v_flagged || jsonb_build_object('id', r.id, 'number', r.number,
      'student_name', r.student_name, 'receipt_due_date', r.receipt_due_date);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'number', p.number,
           'student_name', p.student_name, 'receipt_due_date', p.receipt_due_date) order by p.number), '[]')
    into v_all
    from public.preauths p where p.overdue and p.status = 'purchased';

  return jsonb_build_object(
    'newly_overdue', v_flagged,
    'overdue', v_all,
    'advisor_emails', (select coalesce(jsonb_agg(email), '[]') from public.members
                       where role = 'advisor' and active));
end
$$;

-------------------------------------------------------------------------------
-- RPC: reads
-------------------------------------------------------------------------------

create function public.get_preauth(p_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
  v_hash text;
begin
  perform private.require('preauth_view');
  select * into p from public.preauths where id = p_id;
  if not found then
    raise exception 'Form not found.';
  end if;
  v_hash := public.preauth_hash(p_id);
  return to_jsonb(p) || jsonb_build_object(
    'hash', v_hash,
    'receipts_total_cents', private.preauth_receipts_total(p_id),
    'needs_overage', private.preauth_needs_overage(p),
    'lines', (
      select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object(
          'product_name', pr.name,
          'product_price_cents', pr.price_cents,
          'on_hand', case when l.product_id is null then 0 else private.on_hand(l.product_id) end,
          'vendor_checked_at', vi.checked_at,
          'vendor_sale_price_cents', vi.sale_price_cents,
          'vendor_price_cents', vi.price_cents)
        order by l.line_no), '[]'::jsonb)
      from public.preauth_lines l
      left join public.products pr on pr.id = l.product_id
      left join public.vendor_items vi on vi.id = l.vendor_item_id
      where l.preauth_id = p_id),
    'signatures', (
      select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'role', s.role, 'member_id', s.member_id, 'typed_name', s.typed_name,
          'strokes', s.strokes, 'image_path', s.image_path, 'signed_at', s.signed_at,
          'doc_hash', s.doc_hash, 'voided_at', s.voided_at,
          'matches_form', s.doc_hash = v_hash)
        order by s.signed_at), '[]'::jsonb)
      from public.signatures s
      where s.document_type = 'preauth' and s.document_id = p_id),
    'receipts', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.uploaded_at), '[]'::jsonb)
      from public.receipts r where r.preauth_id = p_id));
end
$$;

-- Who to email about a form. Only for officers and the Advisor.
create function public.preauth_contacts(p_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  p public.preauths;
begin
  perform private.require('preauth_view');
  select * into p from public.preauths where id = p_id;
  if not found then
    raise exception 'Form not found.';
  end if;
  return jsonb_build_object(
    'id', p.id,
    'number', p.number,
    'status', p.status,
    'student_name', p.student_name,
    'grand_total_cents', p.grand_total_cents,
    'reject_comment', p.reject_comment,
    'receipt_due_date', p.receipt_due_date,
    'pdf_path', p.pdf_path,
    'requester_email', (select email from public.members where id = p.requester_id),
    'advisor_emails', (select coalesce(jsonb_agg(email), '[]') from public.members
                       where role = 'advisor' and active),
    'signer_emails', (select coalesce(jsonb_agg(distinct m.email), '[]')
                      from public.signatures s join public.members m on m.id = s.member_id
                      where s.document_type = 'preauth' and s.document_id = p.id
                        and s.voided_at is null));
end
$$;

-------------------------------------------------------------------------------
-- RLS
-------------------------------------------------------------------------------

alter table public.vendor_items enable row level security;
alter table public.preauths enable row level security;
alter table public.preauth_lines enable row level security;
alter table public.signatures enable row level security;
alter table public.receipts enable row level security;

create policy vendor_items_read on public.vendor_items for select to authenticated
  using ((select public.can('preauth_view')));
create policy preauths_read on public.preauths for select to authenticated
  using ((select public.can('preauth_view')));
create policy preauth_lines_read on public.preauth_lines for select to authenticated
  using ((select public.can('preauth_view')));
create policy signatures_read on public.signatures for select to authenticated
  using ((select public.can('preauth_view')) or member_id = (select public.current_member_id()));
create policy receipts_read on public.receipts for select to authenticated
  using ((select public.can('preauth_view')));

revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated, service_role;
revoke execute on all functions in schema private from public, anon, authenticated;
