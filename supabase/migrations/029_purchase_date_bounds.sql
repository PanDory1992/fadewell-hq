-- A known upper bound preserves uncertainty without inventing purchased_on.
alter table public.hq_ledger_items
  add column if not exists purchased_before date,
  add column if not exists purchase_date_precision text;

alter table public.hq_ledger_items drop constraint if exists hq_purchase_date_precision_check;
alter table public.hq_ledger_items add constraint hq_purchase_date_precision_check
  check (purchase_date_precision is null or purchase_date_precision in ('EXACT','BEFORE'));

create or replace function public.set_hq_purchase_before_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare bound date:=nullif(p->>'purchased_before','')::date; changed integer;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if bound is null then raise exception 'purchased_before is required'; end if;
  with changed_items as (
    update hq_ledger_items set purchased_before=bound,purchase_date_precision='BEFORE',version=version+1
    where ledger_status<>'SOLD' and purchased_on is null and purchased_before is null
    returning item_id
  )
  insert into hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
  select item_id,'ADJUSTMENT',current_date,format('Purchase-date bound confirmed by Miki: bought before %s; exact purchase date remains unknown.',bound),'MANUAL','purchase-before-'||bound||'-'||item_id from changed_items;
  get diagnostics changed=row_count;
  return jsonb_build_object('changed',changed,'purchased_before',bound);
end $$;
revoke all on function public.set_hq_purchase_before_owner(jsonb) from public;
grant execute on function public.set_hq_purchase_before_owner(jsonb) to authenticated;

-- Approved factual bound: all currently undated stock was bought before June 2026.
with changed_items as (
  update public.hq_ledger_items set purchased_before='2026-06-01',purchase_date_precision='BEFORE',version=version+1
  where ledger_status<>'SOLD' and purchased_on is null and purchased_before is null
  returning item_id
)
insert into public.hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
select item_id,'ADJUSTMENT',current_date,'Purchase-date bound confirmed by Miki: bought before 2026-06-01; exact purchase date remains unknown.','MANUAL','purchase-before-2026-06-01-'||item_id from changed_items;
