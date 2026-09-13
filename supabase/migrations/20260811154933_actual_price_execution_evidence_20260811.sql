-- A proposed price is decision support, not an exact-match execution command.
-- Confirm any owner-reported, subsequently observed price change and preserve
-- the actual price plus its variance from the proposal.

create or replace function public.hq_confirm_price_experiment_from_snapshot()
returns trigger language plpgsql security definer set search_path=public as $$
declare matched record;
begin
  if new.price_pln is null or not (new.source like 'github_actions_vinted%' or new.source like 'supabase_edge_vinted%') then return new; end if;
  for matched in
    select ei.experiment_id,ei.item_id,ei.baseline_price,ei.proposed_price
    from public.hq_experiment_items ei
    join public.hq_experiments e using(experiment_id)
    join public.hq_ledger_items i on i.item_id=ei.item_id
    join lateral (
      select a.created_at from public.hq_operational_actions a
      where a.entity_type='ITEM' and a.entity_key=ei.item_id
        and a.action_type='OWNER_EXECUTION_REPORTED'
        and a.payload->>'experiment_id'=ei.experiment_id
      order by a.created_at desc limit 1
    ) report on true
    where i.vinted_item_id=new.vinted_item_id
      and new.captured_at>=report.created_at
      and new.price_pln is distinct from ei.baseline_price
      and ei.execution_confirmed_at is null
      and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE')
  loop
    update public.hq_experiment_items set confirmed_price=new.price_pln,execution_confirmed_at=new.captured_at,
      outcome_status='ACTIVE',updated_at=now()
    where experiment_id=matched.experiment_id and item_id=matched.item_id and execution_confirmed_at is null;
    if found then
      insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
      values ('ITEM',matched.item_id,'PRICE_CHANGE_CONFIRMED',jsonb_build_object(
        'schema_version',4,'external_key','confirm-actual:'||matched.experiment_id||':'||matched.item_id||':'||new.captured_at,
        'experiment_id',matched.experiment_id,'item_id',matched.item_id,
        'baseline_price',matched.baseline_price,'proposed_price',matched.proposed_price,
        'confirmed_price',new.price_pln,'confirmed_minus_proposed',new.price_pln-matched.proposed_price,
        'confirmed_minus_baseline',new.price_pln-matched.baseline_price,
        'exact_proposal_match',new.price_pln=matched.proposed_price,
        'confirmed_at',new.captured_at,'source',new.source,'state','ACTIVE_ITEM_COHORT_PENDING'
      )) on conflict do nothing;
    end if;
  end loop;
  return new;
end $$;

revoke all on function public.hq_confirm_price_experiment_from_snapshot() from public;

with candidates as (
  select ei.experiment_id,ei.item_id,ei.baseline_price,ei.proposed_price,
         snap.price_pln,snap.captured_at,snap.source
  from public.hq_experiment_items ei
  join public.hq_experiments e using(experiment_id)
  join public.hq_ledger_items i using(item_id)
  join lateral (
    select s.price_pln,s.captured_at,s.source from public.hq_listing_snapshots s
    where s.vinted_item_id=i.vinted_item_id
      and (s.source like 'github_actions_vinted%' or s.source like 'supabase_edge_vinted%')
    order by s.captured_at desc limit 1
  ) snap on true
  join lateral (
    select a.created_at from public.hq_operational_actions a
    where a.entity_type='ITEM' and a.entity_key=ei.item_id
      and a.action_type='OWNER_EXECUTION_REPORTED'
      and a.payload->>'experiment_id'=ei.experiment_id
    order by a.created_at desc limit 1
  ) report on true
  where e.experiment_type='PRICE_VELOCITY'
    and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE')
    and ei.execution_confirmed_at is null
    and snap.captured_at>=report.created_at
    and snap.price_pln is distinct from ei.baseline_price
), recorded as (
  insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
  select 'ITEM',c.item_id,'PRICE_CHANGE_CONFIRMED',jsonb_build_object(
    'schema_version',4,'external_key','confirm-actual:'||c.experiment_id||':'||c.item_id||':'||c.captured_at,
    'experiment_id',c.experiment_id,'item_id',c.item_id,'baseline_price',c.baseline_price,
    'proposed_price',c.proposed_price,'confirmed_price',c.price_pln,
    'confirmed_minus_proposed',c.price_pln-c.proposed_price,
    'confirmed_minus_baseline',c.price_pln-c.baseline_price,
    'exact_proposal_match',c.price_pln=c.proposed_price,
    'confirmed_at',c.captured_at,'source',c.source,'state','ACTIVE_ITEM_COHORT_PENDING_RECONCILED'
  ) from candidates c on conflict do nothing returning entity_key
)
update public.hq_experiment_items ei set confirmed_price=c.price_pln,execution_confirmed_at=c.captured_at,
  outcome_status='ACTIVE',updated_at=now()
from candidates c where ei.experiment_id=c.experiment_id and ei.item_id=c.item_id;
