-- The register needs stock on hand to gray out sold-out items, but the
-- stock ledger itself is only readable by officers. This returns products
-- with their on-hand count (and nothing else from the ledger) to any member.

create function public.catalog(p_include_archived boolean default false)
returns table (
  id uuid,
  sku text,
  upc text,
  name text,
  description text,
  category_id uuid,
  price_cents bigint,
  avg_cost_cents bigint,
  cost_status text,
  low_stock_alert integer,
  image_path text,
  smart_snack boolean,
  status text,
  on_hand integer
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_member();
  return query
    select p.id, p.sku, p.upc, p.name, p.description, p.category_id, p.price_cents, p.avg_cost_cents,
           p.cost_status, p.low_stock_alert, p.image_path, p.smart_snack, p.status,
           coalesce(s.on_hand, 0)::integer
    from public.products p
    left join (select product_id, sum(qty) as on_hand from public.stock_movements group by product_id) s
      on s.product_id = p.id
    where p_include_archived or p.status = 'active'
    order by p.name;
end
$$;

revoke execute on function public.catalog(boolean) from public, anon;
grant execute on function public.catalog(boolean) to authenticated, service_role;
