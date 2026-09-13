-- FADEWELL HQ — canonical Ledger promotion. Run after 001–004.
-- It only installs guarded functions; it does not perform a cutover itself.

alter table public.hq_ledger_items
  add column if not exists canonical_from_import_id uuid,
  add column if not exists version integer not null default 1;
create or replace function public.verify_hq_ledger_import(p_import_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from hq_ledger_import_runs where import_id=p_import_id and status='STAGED') then
    raise exception 'Only a STAGED import may be marked VERIFIED';
  end if;
  if (select count(*) from hq_ledger_import_items where import_id=p_import_id) <>
     (select row_count from hq_ledger_import_runs where import_id=p_import_id) then
    raise exception 'Import row count does not match its header';
  end if;
  update hq_ledger_import_runs set status='VERIFIED' where import_id=p_import_id;
end $$;
create or replace function public.promote_hq_ledger_import(p_import_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if exists (select 1 from hq_ledger_import_runs where status='CUTOVER') then
    raise exception 'HQ already has a cutover import; use a later controlled migration';
  end if;
  if not exists (select 1 from hq_ledger_import_runs where import_id=p_import_id and status='VERIFIED') then
    raise exception 'Import must be VERIFIED before canonical promotion';
  end if;
  if exists (select 1 from hq_ledger_events) then
    raise exception 'Canonical Ledger already has events; refusing replacement';
  end if;
  delete from hq_ledger_items;
  insert into hq_ledger_items(
    item_id,name,sourcing_type,curation_era,purchase_cost,delivery_cost,total_capital,listed,
    sale_price_arbitrage,sale_price_recycled,net_profit,ledger_status,flip_tier,estimate_range,
    estimate_sale_price,estimate_net_profit,purchased_on,listed_on,sold_on,category,advantage,
    vinted_item_id,listing_url,live_title,live_list_price,last_live_check_on,estimate_confidence,
    estimate_evidence,estimate_model_version,source_import_id,source_row,migration_state,
    canonical_from_import_id,version
  )
  select p.item_id, p.payload->>'name', p.payload->>'sourcing_type', p.payload->>'curation_era',
    nullif(p.payload->>'purchase_cost','')::numeric, nullif(p.payload->>'delivery_cost','')::numeric,
    nullif(p.payload->>'total_capital','')::numeric, (p.payload->>'listed')::boolean,
    nullif(p.payload->>'sale_price_arbitrage','')::numeric, nullif(p.payload->>'sale_price_recycled','')::numeric,
    nullif(p.payload->>'net_profit','')::numeric, p.payload->>'ledger_status',p.payload->>'flip_tier',p.payload->>'estimate_range',
    nullif(p.payload->>'estimate_sale_price','')::numeric,nullif(p.payload->>'estimate_net_profit','')::numeric,
    nullif(p.payload->>'purchased_on','')::date,nullif(p.payload->>'listed_on','')::date,nullif(p.payload->>'sold_on','')::date,
    p.payload->>'category',p.payload->>'advantage',p.payload->>'vinted_item_id',p.payload->>'listing_url',p.payload->>'live_title',
    nullif(p.payload->>'live_list_price','')::numeric,nullif(p.payload->>'last_live_check_on','')::date,p.payload->>'estimate_confidence',
    p.payload->>'estimate_evidence',p.payload->>'estimate_model_version',p.import_id,p.payload->'source_row','CANONICAL',p.import_id,1
  from hq_ledger_import_items p where p.import_id=p_import_id and p.item_id like 'DEN-%';
  update hq_ledger_import_runs set status='CUTOVER' where import_id=p_import_id;
end $$;
revoke all on function public.verify_hq_ledger_import(uuid) from public, anon, authenticated;
revoke all on function public.promote_hq_ledger_import(uuid) from public, anon, authenticated;
grant execute on function public.verify_hq_ledger_import(uuid) to service_role;
grant execute on function public.promote_hq_ledger_import(uuid) to service_role;
