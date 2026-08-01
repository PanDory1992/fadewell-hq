-- Publish only the two garment-facing Item DNA facts used by the storefront.
alter table public.fadewell_storefront_products
  add column if not exists dna_tagged_size text,
  add column if not exists dna_fit text;

grant select (dna_tagged_size, dna_fit)
on public.fadewell_storefront_products to anon, authenticated;

comment on column public.fadewell_storefront_products.dna_tagged_size is
'Public tagged W/L size projected from HQ Item DNA; primary storefront size source.';
comment on column public.fadewell_storefront_products.dna_fit is
'Public silhouette fit projected from HQ Item DNA; primary storefront fit source.';

create or replace function public.sync_fadewell_storefront_dna()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare changed integer;
begin
  update public.fadewell_storefront_products sf
  set dna_tagged_size = nullif(btrim(li.item_dna->'facts'->>'tagged_size'), ''),
      dna_fit = nullif(btrim(li.item_dna->'facts'->>'fit'), ''),
      updated_at = now()
  from public.hq_ledger_items li
  where li.vinted_item_id = sf.vinted_item_id
    and (
      sf.dna_tagged_size is distinct from nullif(btrim(li.item_dna->'facts'->>'tagged_size'), '')
      or sf.dna_fit is distinct from nullif(btrim(li.item_dna->'facts'->>'fit'), '')
    );
  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function public.sync_fadewell_storefront_dna() from public, anon, authenticated;
grant execute on function public.sync_fadewell_storefront_dna() to service_role;
