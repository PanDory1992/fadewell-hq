-- A cohort clock starts only when its whole first wave is evidenced. Partial
-- collector confirmation must not turn five of eight price items into day one.

create or replace function public.hq_refresh_experiment_activation_from_item()
returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; current_status text; ready boolean := false; activation_time timestamptz;
begin
  select experiment_type,status into kind,current_status from public.hq_experiments where experiment_id=new.experiment_id;
  if current_status in ('COMPLETED','STOPPED') then return new; end if;
  if kind='PRICE_VELOCITY' then
    ready := not exists(select 1 from public.hq_experiment_items where experiment_id=new.experiment_id and outcome_status='WAITING_EXECUTION')
      and exists(select 1 from public.hq_experiment_items where experiment_id=new.experiment_id and outcome_status in ('ACTIVE','SOLD'));
  elsif kind='PAID_EXPOSURE' then
    ready := not exists(select 1 from public.hq_experiment_items where experiment_id=new.experiment_id and outcome_status='WAITING_QUOTE')
      and exists(select 1 from public.hq_experiment_items where experiment_id=new.experiment_id and outcome_status in ('ACTIVE','SOLD'));
  else return new;
  end if;
  if ready then
    select max(execution_confirmed_at) into activation_time from public.hq_experiment_items
    where experiment_id=new.experiment_id and outcome_status in ('ACTIVE','SOLD');
    update public.hq_experiments set status='ACTIVE',activated_at=coalesce(activated_at,activation_time,now()),updated_at=now()
    where experiment_id=new.experiment_id;
  else
    update public.hq_experiments set status='WAITING_EXECUTION',activated_at=null,updated_at=now()
    where experiment_id=new.experiment_id;
  end if;
  return new;
end $$;

drop trigger if exists hq_refresh_experiment_activation_item on public.hq_experiment_items;
create trigger hq_refresh_experiment_activation_item
after update of outcome_status,execution_confirmed_at on public.hq_experiment_items
for each row execute function public.hq_refresh_experiment_activation_from_item();
revoke all on function public.hq_refresh_experiment_activation_from_item() from public;

create or replace function public.hq_confirm_price_experiment_from_snapshot()
returns trigger language plpgsql security definer set search_path=public as $$
declare matched record;
begin
  if new.price_pln is null or not (new.source like 'github_actions_vinted%' or new.source like 'supabase_edge_vinted%') then return new; end if;
  for matched in
    select ei.experiment_id,ei.item_id
    from public.hq_experiment_items ei join public.hq_experiments e using(experiment_id)
    join public.hq_ledger_items i on i.item_id=ei.item_id
    where i.vinted_item_id=new.vinted_item_id and ei.proposed_price=new.price_pln
      and ei.execution_confirmed_at is null and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE')
  loop
    update public.hq_experiment_items set confirmed_price=new.price_pln,execution_confirmed_at=new.captured_at,
      outcome_status='ACTIVE',updated_at=now()
    where experiment_id=matched.experiment_id and item_id=matched.item_id and execution_confirmed_at is null;
    if found then
      insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
      values ('ITEM',matched.item_id,'PRICE_CHANGE_CONFIRMED',jsonb_build_object(
        'schema_version',3,'external_key','confirm:'||matched.experiment_id||':'||matched.item_id||':'||new.captured_at,
        'experiment_id',matched.experiment_id,'item_id',matched.item_id,'confirmed_price',new.price_pln,
        'confirmed_at',new.captured_at,'source',new.source,'state','ACTIVE_ITEM_COHORT_PENDING'
      )) on conflict do nothing;
    end if;
  end loop;
  return new;
end $$;

revoke all on function public.hq_confirm_price_experiment_from_snapshot() from public;

create or replace function public.report_hq_experiment_execution_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  experiment text := nullif(p->>'experiment_id',''); item text := nullif(p->>'item_id','');
  execution_type text := nullif(p->>'execution_type',''); spend numeric := nullif(p->>'promotion_spend','')::numeric;
  external_key text := nullif(p->>'external_key',''); kind text; proposed numeric; payload jsonb;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if experiment is null or item is null or external_key is null then raise exception 'Experiment, item and external key required'; end if;
  select e.experiment_type,ei.proposed_price into kind,proposed
  from public.hq_experiments e join public.hq_experiment_items ei using(experiment_id)
  where e.experiment_id=experiment and ei.item_id=item for update of ei;
  if not found then raise exception 'Experiment item not found'; end if;
  if execution_type='PRICE' and kind<>'PRICE_VELOCITY' then raise exception 'Execution type mismatch'; end if;
  if execution_type='EXPOSURE' and kind<>'PAID_EXPOSURE' then raise exception 'Execution type mismatch'; end if;
  payload := jsonb_build_object('schema_version',3,'external_key',external_key,'experiment_id',experiment,
    'item_id',item,'execution_type',execution_type,'reported_at',now(),'source','HQ_EXPERIMENT_STUDIO');
  if execution_type='PRICE' then
    payload := payload||jsonb_build_object('proposed_price',proposed,'state','WAITING_COLLECTOR');
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
    values ('ITEM',item,'OWNER_EXECUTION_REPORTED',payload,auth.uid());
  elsif execution_type='EXPOSURE' then
    if spend is null or spend<=0 then raise exception 'Actual promotion spend required'; end if;
    update public.hq_experiment_items set promotion_spend=spend,execution_confirmed_at=now(),outcome_status='ACTIVE',updated_at=now()
    where experiment_id=experiment and item_id=item and outcome_status='WAITING_QUOTE';
    if not found then raise exception 'Exposure item is not waiting for purchase confirmation'; end if;
    payload := payload||jsonb_build_object('promotion_spend',spend,'state','ACTIVE_ITEM_COHORT_PENDING','purchase_automated',false);
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
    values ('ITEM',item,'BUMP_EXECUTION_REPORTED',payload,auth.uid());
  else raise exception 'Execution type must be PRICE or EXPOSURE';
  end if;
  return payload;
end $$;

revoke all on function public.report_hq_experiment_execution_owner(jsonb) from public;
grant execute on function public.report_hq_experiment_execution_owner(jsonb) to authenticated;

create or replace function public.hq_capture_experiment_sale()
returns trigger language plpgsql security definer set search_path=public as $$
declare matched record; realised numeric;
begin
  if new.ledger_status<>'SOLD' or old.ledger_status='SOLD' then return new; end if;
  realised := coalesce(new.sale_price_arbitrage,new.sale_price_recycled);
  for matched in
    select ei.experiment_id,ei.item_id from public.hq_experiment_items ei
    join public.hq_experiments e using(experiment_id)
    where ei.item_id=new.item_id and ei.outcome_status<>'SOLD' and e.status in ('ACTIVE','EVALUATE')
  loop
    update public.hq_experiment_items set sold_on=coalesce(new.sold_on,current_date),sale_price=realised,
      net_profit=new.net_profit,capital_released=new.total_capital,outcome_status='SOLD',updated_at=now()
    where experiment_id=matched.experiment_id and item_id=matched.item_id;
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
    values ('ITEM',matched.item_id,'EXPERIMENT_ITEM_SOLD',jsonb_build_object(
      'schema_version',3,'external_key','sold:'||matched.experiment_id||':'||matched.item_id,
      'experiment_id',matched.experiment_id,'item_id',matched.item_id,'sold_on',coalesce(new.sold_on,current_date),
      'sale_price',realised,'net_profit',new.net_profit,'capital_released',new.total_capital,
      'source','HQ_LEDGER','state','SOLD'
    )) on conflict do nothing;
  end loop;
  return new;
end $$;

revoke all on function public.hq_capture_experiment_sale() from public;

update public.hq_experiments e set status='WAITING_EXECUTION',activated_at=null,updated_at=now()
where e.status not in ('COMPLETED','STOPPED') and (
  (e.experiment_type='PRICE_VELOCITY' and exists(select 1 from public.hq_experiment_items ei where ei.experiment_id=e.experiment_id and ei.outcome_status='WAITING_EXECUTION'))
  or (e.experiment_type='PAID_EXPOSURE' and exists(select 1 from public.hq_experiment_items ei where ei.experiment_id=e.experiment_id and ei.outcome_status='WAITING_QUOTE'))
);
