-- Publish the remaining garment-facing Item DNA facts needed by product cards.
alter table public.fadewell_storefront_products
  add column if not exists dna_origin text,
  add column if not exists dna_era text,
  add column if not exists dna_color text;

grant select (dna_origin, dna_era, dna_color)
on public.fadewell_storefront_products to anon, authenticated;

comment on column public.fadewell_storefront_products.dna_origin is
'Public production country projected from HQ Item DNA.';
comment on column public.fadewell_storefront_products.dna_era is
'Public production year or era projected from HQ Item DNA.';
comment on column public.fadewell_storefront_products.dna_color is
'Public wash or colour projected from HQ Item DNA.';

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
      dna_origin = nullif(btrim(li.item_dna->'facts'->>'origin'), ''),
      dna_era = nullif(btrim(li.item_dna->'facts'->>'era'), ''),
      dna_color = nullif(btrim(li.item_dna->'facts'->>'wash'), ''),
      updated_at = now()
  from public.hq_ledger_items li
  where li.vinted_item_id = sf.vinted_item_id
    and (
      sf.dna_tagged_size is distinct from nullif(btrim(li.item_dna->'facts'->>'tagged_size'), '')
      or sf.dna_fit is distinct from nullif(btrim(li.item_dna->'facts'->>'fit'), '')
      or sf.dna_origin is distinct from nullif(btrim(li.item_dna->'facts'->>'origin'), '')
      or sf.dna_era is distinct from nullif(btrim(li.item_dna->'facts'->>'era'), '')
      or sf.dna_color is distinct from nullif(btrim(li.item_dna->'facts'->>'wash'), '')
    );
  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function public.sync_fadewell_storefront_dna() from public, anon, authenticated;
grant execute on function public.sync_fadewell_storefront_dna() to service_role;
