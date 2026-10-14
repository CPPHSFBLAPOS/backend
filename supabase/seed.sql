-- Local development data. Every person here is made up (see "Student data"
-- in docs/SPEC.md): build and test with fake names until the district says
-- otherwise. `supabase db reset` loads this after the migrations; it never
-- runs against the hosted project.

begin;

-- Act as the system so the same RPCs the app uses write the log.
select set_config('request.jwt.claims', '{"role": "service_role"}', true);

select public.save_member(null, 'advisor@example.com', 'Avery Advisor (test)', null, 'advisor', false, true);
select public.save_member(null, 'treasurer@example.com', 'Taylor Treasurer (test)', 11, 'treasurer', false, true);
select public.save_member(null, 'cashier@example.com', 'Casey Cashier (test)', 10, 'cashier', false, true);
select public.save_member(null, 'cashier2@example.com', 'Jordan Cashier (test)', 9, 'cashier', false, true);
select public.save_member(null, 'register@example.com', 'Store Register', null, 'register', false, true);

-- Test PINs: advisor 1111, treasurer 2222, cashiers 3333 / 4444, president 5555.
update public.members m
   set pin_hash = extensions.crypt(v.pin, extensions.gen_salt('bf', 8))
  from (values
    ('advisor@example.com', '1111'),
    ('treasurer@example.com', '2222'),
    ('cashier@example.com', '3333'),
    ('cashier2@example.com', '4444'),
    ('depedros@cppasd.com', '5555')
  ) as v (email, pin)
 where lower(m.email) = v.email;

select public.save_category(null, 'Drinks', 1);
select public.save_category(null, 'Snacks', 2);
select public.save_category(null, 'School Supplies', 3);
select public.save_category(null, 'Spirit Wear', 4);

select public.import_products('[
  {"name": "Water Bottle 16.9 oz", "sku": "FBLA-0001", "category": "Drinks", "price_cents": 100, "cost_cents": 25, "stock": 48},
  {"name": "Sports Drink 20 oz", "sku": "FBLA-0002", "category": "Drinks", "price_cents": 175, "cost_cents": 85, "stock": 24},
  {"name": "Nacho Chips 1 oz", "sku": "FBLA-0003", "category": "Snacks", "price_cents": 100, "cost_cents": 45, "stock": 40},
  {"name": "Crispy Rice Treat", "sku": "FBLA-0004", "category": "Snacks", "price_cents": 100, "cost_cents": 30, "stock": 36},
  {"name": "Fruit Snacks", "sku": "FBLA-0005", "category": "Snacks", "price_cents": 75, "cost_cents": 22, "stock": 60},
  {"name": "Granola Bar", "sku": "FBLA-0006", "category": "Snacks", "price_cents": 100, "cost_cents": 35, "stock": 3},
  {"name": "Hot Cocoa Packet", "sku": "FBLA-0007", "category": "Drinks", "price_cents": 100, "stock": 20},
  {"name": "Pencils, 2-pack", "sku": "FBLA-0008", "category": "School Supplies", "price_cents": 50, "cost_cents": 15, "stock": 30},
  {"name": "Blue Pen", "sku": "FBLA-0009", "category": "School Supplies", "price_cents": 75, "cost_cents": 20, "stock": 25},
  {"name": "FBLA Lanyard", "sku": "FBLA-0010", "category": "Spirit Wear", "price_cents": 300, "cost_cents": 120, "stock": 15}
]'::jsonb);
select setval('public.product_sku_seq', 10);

update public.products set smart_snack = true where sku in ('FBLA-0004', 'FBLA-0005', 'FBLA-0006');
update public.products p
   set upc = v.upc
  from (values ('FBLA-0001', '012345678905'), ('FBLA-0002', '012345678912'),
               ('FBLA-0003', '012345678929'), ('FBLA-0004', '012345678936'),
               ('FBLA-0005', '012345678943')) as v (sku, upc)
 where p.sku = v.sku;

-- Open days for the 2026-27 year: weekdays from Sept 8 to June 25.
select public.save_settings(jsonb_build_object('open_days', (
  select jsonb_agg(d::date)
  from generate_series(date '2026-09-08', date '2027-06-25', interval '1 day') d
  where extract(isodow from d) < 6)));

-- A made-up year of Base44 history so reports and ROI have something to show.
select setseed(0.42);
select public.import_legacy_sales((
  select jsonb_agg(jsonb_build_object(
    'sold_at', (d + time '11:30') at time zone 'America/New_York',
    'product_name', p.name,
    'sku', p.sku,
    'qty', q.qty,
    'unit_price_cents', p.price_cents,
    'total_cents', q.qty * p.price_cents,
    'source_key', 'seed-' || to_char(d, 'YYYYMMDD') || '-' || p.sku))
  from generate_series(date '2025-09-08', date '2026-06-19', interval '1 day') d
  cross join public.products p
  cross join lateral (select (floor(random() * 4))::integer as qty) q
  where extract(isodow from d) < 6 and q.qty > 0 and p.sku <> 'FBLA-0007'));

commit;
