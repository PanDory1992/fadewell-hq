-- Owner-facing pricing cockpit. Execution reports are append-only evidence;
-- observed prices still change only through future Vinted collector snapshots.

insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
select 'ITEM',ei.item_id,'OWNER_EXECUTION_REPORTED',jsonb_build_object(
  'schema_version',2,
  'external_key',ei.experiment_id || ':' || ei.item_id || ':owner-executed-2026-08-11',
  'experiment_id',ei.experiment_id,
  'item_id',ei.item_id,
  'proposed_price',ei.proposed_price,
  'reported_on','2026-08-11',
  'source','MIKI_DIRECT_CONFIRMATION',
  'state','WAITING_COLLECTOR'
)
from public.hq_experiment_items ei
where ei.experiment_id='EXP-2026-08-11-PRICE-VELOCITY'
  and not exists (
    select 1 from public.hq_operational_actions a
    where a.action_type='OWNER_EXECUTION_REPORTED'
      and a.payload->>'external_key'=ei.experiment_id || ':' || ei.item_id || ':owner-executed-2026-08-11'
  );

create or replace view public.hq_experiment_item_cockpit
with (security_invoker=true) as
select
  ei.experiment_id,
  e.experiment_type,
  e.status as experiment_status,
  e.objective,
  e.planned_start_on,
  e.planned_end_on,
  e.activated_at,
  p.day_7_gate,
  ei.item_id,
  ei.role,
  ei.baseline_price,
  ei.proposed_price,
  ei.confirmed_price,
  ei.baseline_favourites,
  ei.baseline_observed_at,
  ei.execution_confirmed_at,
  ei.promotion_spend,
  ei.sold_on,
  ei.sale_price,
  ei.net_profit,
  ei.capital_released,
  ei.outcome_status,
  i.live_title,
  i.manual_title,
  i.name,
  i.live_list_price,
  i.vinted_item_id,
  i.listing_url,
  exists (
    select 1 from public.hq_operational_actions a
    where a.entity_type='ITEM' and a.entity_key=ei.item_id
      and a.action_type='OWNER_EXECUTION_REPORTED'
      and a.payload->>'experiment_id'=ei.experiment_id
  ) as owner_execution_reported,
  case
    when ei.outcome_status='SOLD' then 'SOLD'
    when ei.outcome_status='ACTIVE' or ei.execution_confirmed_at is not null then 'ACTIVE'
    when ei.outcome_status='WAITING_QUOTE' then 'WAITING_QUOTE'
    when ei.outcome_status='CONDITIONAL' then 'CONDITIONAL'
    when ei.outcome_status='STOPPED' then 'STOPPED'
    when exists (
      select 1 from public.hq_operational_actions a
      where a.entity_type='ITEM' and a.entity_key=ei.item_id
        and a.action_type='OWNER_EXECUTION_REPORTED'
        and a.payload->>'experiment_id'=ei.experiment_id
    ) then 'WAITING_COLLECTOR'
    else 'TO_EXECUTE'
  end as display_state
from public.hq_experiment_items ei
join public.hq_experiments e using (experiment_id)
join public.hq_experiment_progress p using (experiment_id)
join public.hq_ledger_items i using (item_id);

revoke all on table public.hq_experiment_item_cockpit from public;
grant select on table public.hq_experiment_item_cockpit to authenticated;
