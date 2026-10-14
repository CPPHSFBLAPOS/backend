-- Storage buckets. Receipts, signatures, outage sheets and pre-auth PDFs are
-- private and shown through short-lived signed URLs; product images can be
-- read publicly. Uploads go straight from the browser; nothing is replaced or
-- deleted (no update or delete policies).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-images', 'product-images', true, 5242880, array['image/png', 'image/jpeg', 'image/webp']),
  ('receipts', 'receipts', false, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/heic', 'application/pdf']),
  ('signatures', 'signatures', false, 1048576, array['image/png']),
  ('outage-sheets', 'outage-sheets', false, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/heic']),
  ('preauth-pdfs', 'preauth-pdfs', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

create policy "product images are public" on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');
create policy "officers upload product images" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (select public.can('edit_products')));

create policy "officers read receipts" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (select public.can('preauth_view')));
create policy "purchasers upload receipts" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (select public.can('preauth_purchase')));

create policy "officers read signatures" on storage.objects for select to authenticated
  using (bucket_id = 'signatures' and (select public.can('preauth_view')));
create policy "members upload signatures" on storage.objects for insert to authenticated
  with check (bucket_id = 'signatures' and (select public.is_member()));

create policy "officers read outage sheets" on storage.objects for select to authenticated
  using (bucket_id = 'outage-sheets' and (select public.can('verify_outage')));
create policy "registers upload outage sheets" on storage.objects for insert to authenticated
  with check (bucket_id = 'outage-sheets' and (select public.can('ring_sales')));

create policy "officers read pre-auth PDFs" on storage.objects for select to authenticated
  using (bucket_id = 'preauth-pdfs' and (select public.can('preauth_view')));
create policy "officers store pre-auth PDFs" on storage.objects for insert to authenticated
  with check (bucket_id = 'preauth-pdfs' and (select public.can('preauth_view')));
