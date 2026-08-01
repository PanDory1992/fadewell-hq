-- Public storefront projection. It contains no ledger costs, margin, Gmail,
-- owner identity, or other HQ-only fields.
create table if not exists public.fadewell_storefront_products (
  vinted_item_id text primary key,
  title text,
  brand text,
  size_label text,
  condition_label text,
  garment_type text check (garment_type in ('JEANS', 'TROUSERS')),
  vinted_category text,
  description_raw text,
  measurements jsonb not null default '{}'::jsonb,
  photos jsonb not null default '[]'::jsonb,
  price_pln numeric(12,2),
  vinted_url text not null,
  available boolean not null default true,
  sold boolean not null default false,
  published boolean not null default false,
  publication_notes jsonb not null default '{}'::jsonb,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  sold_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint fadewell_storefront_product_state check (not sold or not available)
);

alter table public.fadewell_storefront_products enable row level security;

drop policy if exists "public reads published storefront" on public.fadewell_storefront_products;
create policy "public reads published storefront"
on public.fadewell_storefront_products
for select
to anon, authenticated
using (published);

revoke all on public.fadewell_storefront_products from anon, authenticated;
grant select (
  vinted_item_id, title, brand, size_label, condition_label, garment_type,
  vinted_category, description_raw, measurements, photos, price_pln,
  vinted_url, available, sold, first_seen_at, last_seen_at, sold_at, updated_at
) on public.fadewell_storefront_products to anon, authenticated;

create index if not exists fadewell_storefront_available_idx
on public.fadewell_storefront_products (available, updated_at desc)
where published;

comment on table public.fadewell_storefront_products is
'Public, whitelisted FADEWELL product facts sourced from Vinted; never store private HQ economics here.';

create or replace function public.sync_fadewell_storefront_sales()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare changed integer;
begin
  update public.fadewell_storefront_products sf
  set available = false,
      sold = true,
      sold_at = coalesce(sf.sold_at, li.sold_on::timestamptz, now()),
      updated_at = now()
  from public.hq_ledger_items li
  where li.vinted_item_id = sf.vinted_item_id
    and li.ledger_status = 'SOLD'
    and (sf.available or not sf.sold);
  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function public.sync_fadewell_storefront_sales() from public, anon, authenticated;
grant execute on function public.sync_fadewell_storefront_sales() to service_role;
