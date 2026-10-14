-- Phase 2: the pre-auth form, signatures, purchase, receipts and receiving.
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
    json_build_object('sub', v_uid, 'role', 'authenticated', 'email', lower(p_email))::text, true);
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
create function pg_temp.product(p_sku text) returns uuid
language sql security definer as $$
  select id from public.products where sku = p_sku
$$;
create function pg_temp.today() returns date
language sql as $$ select (now() at time zone 'America/New_York')::date $$;
-- A one-stroke drawn signature.
create function pg_temp.strokes() returns jsonb
language sql as $$ select '[{"points": [{"x": 1, "y": 2}, {"x": 30, "y": 12}]}]'::jsonb $$;

select plan(40);

-------------------------------------------------------------------------------
-- The $300 limit
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select save_preauth(null,
  '{"purposes": ["fundraiser"], "justification": "Restock for the fall fundraiser", "shipping_cents": 1}',
  jsonb_build_array(jsonb_build_object('new_name', 'Big pack', 'units_per_pack', 10, 'packs', 2,
                                       'est_pack_price_cents', 15000, 'sell_price_cents', 2000))
) as big \gset
select is((select grand_total_cents from preauths where id = :'big'), 30001::bigint,
          'grand total = line totals + shipping');
select throws_like(format($$ select sign_preauth(%L, 'student', 'Taylor', pg_temp.strokes()) $$, :'big'),
                   '%over the $300.00 limit%', 'submitting is blocked above $300');

-------------------------------------------------------------------------------
-- The hash changes when any line changes
-------------------------------------------------------------------------------
select save_preauth(null,
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 2, 'est_pack_price_cents', 600, 'sell_price_cents', 100))
) as p \gset
-- Pretend the form was started a week ago so the purchase can be dated 6 days back.
select pg_temp.logout();
update preauths set request_date = pg_temp.today() - 7 where id = :'p';
select pg_temp.login('treasurer@example.com');
select preauth_hash(:'p') as h1 \gset
select save_preauth(:'p',
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 2, 'est_pack_price_cents', 600, 'sell_price_cents', 100)));
select is(preauth_hash(:'p'), :'h1', 'saving the same content keeps the same hash');
select save_preauth(:'p',
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 3, 'est_pack_price_cents', 600, 'sell_price_cents', 100)));
select isnt(preauth_hash(:'p'), :'h1', 'changing packs changes the hash');
select preauth_hash(:'p') as h2 \gset
select save_preauth(:'p',
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 3, 'est_pack_price_cents', 600, 'sell_price_cents', 125)));
select isnt(preauth_hash(:'p'), :'h2', 'changing the sell price changes the hash');
select save_preauth(:'p',
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 2, 'est_pack_price_cents', 600, 'sell_price_cents', 100)));
select is(preauth_hash(:'p'), :'h1', 'putting the line back restores the hash');

-------------------------------------------------------------------------------
-- An edit after signing voids the signatures and returns the form to Draft
-------------------------------------------------------------------------------
select is(sign_preauth(:'p', 'student', 'Taylor Treasurer', pg_temp.strokes()) ->> 'status', 'awaiting_advisor',
          'the student signature submits the form');
select is((select doc_hash from signatures where document_id = :'p' and role = 'student' and voided_at is null),
          :'h1', 'the signature stores the form hash');
select save_preauth(:'p',
  '{"purposes": ["fundraiser"], "justification": "Water for the fall fundraiser", "notes": "changed"}',
  jsonb_build_array(jsonb_build_object('product_id', pg_temp.product('FBLA-0001'), 'units_per_pack', 24,
                                       'packs', 2, 'est_pack_price_cents', 600, 'sell_price_cents', 100)));
select is((select status::text from preauths where id = :'p'), 'draft', 'an edit returns the form to Draft');
select is((select count(*)::int from signatures where document_id = :'p' and voided_at is null), 0,
          'an edit voids the signatures');
select ok((select count(*) from signatures where document_id = :'p' and voided_at is not null) = 1,
          'the voided signature is kept');
select is(sign_preauth(:'p', 'student', 'Taylor Treasurer', pg_temp.strokes()) ->> 'status', 'awaiting_advisor',
          'the student signs again');
select throws_like(format($$ select record_purchase(%L, pg_temp.today()) $$, :'p'),
                   '%Only an approved form%', 'nothing is purchased before the Advisor signs');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Only the Advisor approves
-------------------------------------------------------------------------------
select pg_temp.login('cashier@example.com');
select throws_ok(format($$ select sign_preauth(%L, 'advisor', 'Casey', pg_temp.strokes()) $$, :'p'),
                 '42501', null, 'a cashier cannot approve');
select pg_temp.logout();
select pg_temp.login('depedros@cppasd.com');
select throws_ok(format($$ select sign_preauth(%L, 'advisor', 'Pres', pg_temp.strokes()) $$, :'p'),
                 '42501', null, 'the President (even as Super Admin) cannot approve');
select pg_temp.logout();
select pg_temp.login('treasurer@example.com');
select throws_ok(format($$ select sign_preauth(%L, 'advisor', 'Taylor', pg_temp.strokes()) $$, :'p'),
                 '42501', null, 'the requester cannot approve their own form');
select pg_temp.logout();

select pg_temp.login('advisor@example.com');
select throws_like(format($$ select reject_preauth(%L, '') $$, :'p'), '%needs a comment%',
                   'rejecting needs a comment');
select is(sign_preauth(:'p', 'advisor', 'Avery Advisor', pg_temp.strokes()) ->> 'status', 'approved',
          'the Advisor approves');
select is((select approved_total_cents from preauths where id = :'p'), 1200::bigint,
          'the approved total is the grand total');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Purchase, receipt due date and the overdue flag
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select is((record_purchase(:'p', pg_temp.today() - 6) ->> 'receipt_due_date')::date, pg_temp.today() - 1,
          'the receipt is due 5 days after the purchase date');
select throws_like(format($$ select record_reimbursement(%L, 1200, 'Taylor') $$, :'p'),
                   '%Upload the receipt%', 'no reimbursement without a receipt');
select throws_like(format($$ select receive_preauth(%L, '[]') $$, :'p'),
                   '%receipt photo is required%', 'no receiving without a receipt');
select pg_temp.logout();

select pg_temp.login('advisor@example.com');
select is(jsonb_array_length(mark_overdue_preauths() -> 'newly_overdue'), 1, 'the daily job flags it on day 6');
select ok((select overdue from preauths where id = :'p'), 'the form shows Overdue');
select is(jsonb_array_length(mark_overdue_preauths() -> 'newly_overdue'), 0, 'it is flagged once');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- A receipt over the approved total needs the Advisor's sign-off
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select is((add_receipt(:'p', :'p' || '/receipt.jpg', 1296, 96) ->> 'needs_overage')::boolean, true,
          'a receipt over the approved total needs sign-off');
select ok(not (select overdue from preauths where id = :'p'), 'uploading the receipt clears Overdue');
select throws_like(format($$ select record_reimbursement(%L, 1296, 'Taylor') $$, :'p'),
                   '%Advisor must sign off%', 'no reimbursement over the approved total without sign-off');
select pg_temp.logout();

select pg_temp.login('advisor@example.com');
select lives_ok(format($$ select approve_overage(%L, 'Avery Advisor', pg_temp.strokes()) $$, :'p'),
                'the Advisor signs off on the overage');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select lives_ok(format($$ select record_reimbursement(%L, 1296, 'Taylor Treasurer') $$, :'p'),
                'the reimbursement can be recorded now');

-------------------------------------------------------------------------------
-- Receiving updates stock and the weighted average cost
-- On hand 48 at 25c. 2 packs of 24 at $6.00 plus $0.96 tax = 1296c / 48 = 27c.
-- New cost = (48 * 25 + 48 * 27) / 96 = 26c.
-------------------------------------------------------------------------------
select is((receive_preauth(:'p', jsonb_build_array(jsonb_build_object(
            'line_id', (select id from preauth_lines where preauth_id = :'p'),
            'packs_bought', 2, 'actual_pack_price_cents', 600, 'units_received', 48))) ->> 'units')::int, 48,
          'receiving posts 48 units');
select is((select received_unit_cost_cents from preauth_lines where preauth_id = :'p'), 27::bigint,
          'tax is spread into the unit cost');
select is((select avg_cost_cents from products where sku = 'FBLA-0001'), 26::bigint,
          'the product cost is the weighted average');
select is((select on_hand from product_stock where product_id = pg_temp.product('FBLA-0001')), 96,
          'stock goes up only at Received');
select is((select type::text from stock_movements where source_id = :'p'), 'receiving',
          'it is a Receiving movement');
select pg_temp.logout();

select pg_temp.login('advisor@example.com');
select lives_ok(format($$ select close_preauth(%L) $$, :'p'), 'the Advisor closes the form');
select is((select status::text from preauths where id = :'p'), 'closed', 'the form is closed');
select pg_temp.logout();

select pg_temp.login('treasurer@example.com');
select throws_like(format($$ select save_preauth(%L, '{}', '[]') $$, :'p'), '%can no longer be edited%',
                   'a closed form is locked');
select pg_temp.logout();

-------------------------------------------------------------------------------
-- Tax spread by dollar share across two lines, and new items become products
-------------------------------------------------------------------------------
select pg_temp.login('treasurer@example.com');
select save_preauth(null,
  '{"purposes": ["supplies"], "justification": "Supplies"}',
  jsonb_build_array(
    jsonb_build_object('product_id', pg_temp.product('FBLA-0008'), 'units_per_pack', 10, 'packs', 2,
                       'est_pack_price_cents', 600, 'sell_price_cents', 50),
    jsonb_build_object('new_name', 'Highlighter', 'units_per_pack', 12, 'packs', 1,
                       'est_pack_price_cents', 600, 'sell_price_cents', 100))
) as q \gset
select sign_preauth(:'q', 'student', 'Taylor Treasurer', pg_temp.strokes());
select pg_temp.logout();
select pg_temp.login('advisor@example.com');
select sign_preauth(:'q', 'advisor', 'Avery Advisor', pg_temp.strokes());
select pg_temp.logout();
select pg_temp.login('treasurer@example.com');
select record_purchase(:'q', pg_temp.today());
select add_receipt(:'q', :'q' || '/r.jpg', 1890, 90);
select receive_preauth(:'q', (
  select jsonb_agg(jsonb_build_object('line_id', id, 'packs_bought', packs, 'actual_pack_price_cents', 600,
                                      'units_received', packs * units_per_pack))
  from preauth_lines where preauth_id = :'q'));
-- Line 1 is $12.00 of $18.00, so it takes $0.60 of the $0.90 tax: (1200 + 60) / 20 = 63c.
select is((select received_unit_cost_cents from preauth_lines where preauth_id = :'q' and line_no = 1),
          63::bigint, 'tax is spread across lines by dollar share');
select is((select count(*)::int from products where name = 'Highlighter' and price_cents = 100), 1,
          'a new item becomes a product at its selling price');
select pg_temp.logout();

select * from finish();
rollback;
