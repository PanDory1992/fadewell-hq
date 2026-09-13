-- Owner-created price and paid-exposure experiments. HQ stores decisions and
-- evidence; price changes and promotion purchases remain manual on Vinted.

create or replace function public.create_hq_experiment_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  kind text := nullif(p->>'experiment_type','');
  objective_text text := nullif(trim(p->>'objective'),'');
  duration_days integer := coalesce(nullif(p->>'duration_days','')::integer,7);
  success_min integer := coalesce(nullif(p->>'success_min_sales','')::integer,1);
  external_key text := nullif(p->>'external_key','');
  algorithm_version text := coalesce(nullif(p->>'algorithm_version',''),'MANUAL');
  item_rows jsonb := p->'items';
  item_row jsonb;
  item text;
  proposed numeric;
  observed numeric;
  observed_at timestamptz;
  favourites integer;
  capital numeric;
  listing_id text;
  listing_url text;
  experiment text;
  existing_payload jsonb;
  item_count integer;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if kind not in ('PRICE_VELOCITY','PAID_EXPOSURE') then raise exception 'Unsupported experiment type'; end if;
  if objective_text is null then raise exception 'Experiment objective required'; end if;
  if external_key is null then raise exception 'External key required'; end if;
  if duration_days < 7 or duration_days > 30 then raise exception 'Duration must be 7-30 days'; end if;
  if jsonb_typeof(item_rows) <> 'array' then raise exception 'Items array required'; end if;
  item_count := jsonb_array_length(item_rows);
  if item_count < 1 or item_count > 20 then raise exception 'Experiment needs 1-20 items'; end if;
  if success_min < 1 or success_min > item_count then raise exception 'Success threshold must fit cohort size'; end if;

  select payload into existing_payload from public.hq_operational_actions
  where action_type='EXPERIMENT_CREATED' and payload->>'external_key'=external_key limit 1;
  if found then return existing_payload || jsonb_build_object('idempotent',true); end if;

  if (select count(distinct value->>'item_id') from jsonb_array_elements(item_rows)) <> item_count then
    raise exception 'Duplicate item in experiment';
  end if;

  for item_row in select value from jsonb_array_elements(item_rows)
  loop
    item := nullif(item_row->>'item_id','');
    proposed := nullif(item_row->>'proposed_price','')::numeric;
    select coalesce(s.price_pln,i.live_list_price),s.captured_at,coalesce(s.favourites,0),
           coalesce(i.total_capital,0),i.vinted_item_id,i.listing_url
      into observed,observed_at,favourites,capital,listing_id,listing_url
    from public.hq_ledger_items i
    left join lateral (
      select snap.price_pln,snap.captured_at,snap.favourites
      from public.hq_listing_snapshots snap
      where snap.vinted_item_id=i.vinted_item_id
        and (snap.source like 'github_actions_vinted%' or snap.source like 'supabase_edge_vinted%')
      order by snap.captured_at desc limit 1
    ) s on true
    where i.item_id=item and i.ledger_status='LISTED-BACKLOG' and i.vinted_item_id is not null
    for update of i;
    if not found then raise exception 'Only an active listed DEN may enter an experiment: %',item; end if;
    if exists (
      select 1 from public.hq_experiment_items ei join public.hq_experiments e using(experiment_id)
      where ei.item_id=item and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE','EVALUATE')
    ) then raise exception 'Item already belongs to an active experiment: %',item; end if;
    if kind='PRICE_VELOCITY' and (proposed is null or proposed<=0 or proposed=observed or proposed<capital) then
      raise exception 'Price test must differ from live price and stay above recorded capital: %',item;
    end if;
  end loop;

  experiment := 'EXP-' || case when kind='PRICE_VELOCITY' then 'PRICE-' else 'EXPOSURE-' end || to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS');
  insert into public.hq_experiments(
    experiment_id,experiment_type,status,objective,source_route,metric,baseline,
    success_rules,max_downside,planned_start_on,planned_end_on,owner_label,created_by
  ) values (
    experiment,kind,'WAITING_EXECUTION',objective_text,
    'HQ experiment studio + manual Vinted execution + live evidence',
    case when kind='PRICE_VELOCITY' then '{"primary":["sale_count","realised_sale_price","net_profit","capital_released"]}'::jsonb else '{"primary":["promotion_spend","sale_count","net_profit","spend_per_sale"]}'::jsonb end,
    jsonb_build_object('item_count',item_count,'algorithm_version',algorithm_version,'created_at',now()),
    jsonb_build_object('day_7',jsonb_build_object('retain',jsonb_build_object('minimum_sales',success_min),'stop',jsonb_build_object('sales',0))),
    case when kind='PRICE_VELOCITY' then '{"price_below_recorded_capital":false,"second_blind_cut":false}'::jsonb else '{"spend_authorized":false,"requires_live_quote":true,"repeat_requires_sale":true}'::jsonb end,
    current_date,current_date+duration_days,'Miki',auth.uid()
  );

  for item_row in select value from jsonb_array_elements(item_rows)
  loop
    item := item_row->>'item_id';
    proposed := nullif(item_row->>'proposed_price','')::numeric;
    select coalesce(s.price_pln,i.live_list_price),s.captured_at,coalesce(s.favourites,0),i.vinted_item_id,i.listing_url
      into observed,observed_at,favourites,listing_id,listing_url
    from public.hq_ledger_items i
    left join lateral (
      select snap.price_pln,snap.captured_at,snap.favourites
      from public.hq_listing_snapshots snap
      where snap.vinted_item_id=i.vinted_item_id
        and (snap.source like 'github_actions_vinted%' or snap.source like 'supabase_edge_vinted%')
      order by snap.captured_at desc limit 1
    ) s on true where i.item_id=item;
    insert into public.hq_experiment_items(
      experiment_id,item_id,role,baseline_price,proposed_price,baseline_favourites,
      baseline_observed_at,outcome_status
    ) values (
      experiment,item,case when kind='PRICE_VELOCITY' then 'PRICE_TREATMENT' else 'EXPOSURE_WAVE_1' end,
      observed,case when kind='PRICE_VELOCITY' then proposed else null end,favourites,observed_at,
      case when kind='PRICE_VELOCITY' then 'WAITING_EXECUTION' else 'WAITING_QUOTE' end
    );
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
    values ('ITEM',item,case when kind='PRICE_VELOCITY' then 'PRICE_CHANGE_APPROVED' else 'BUMP_QUOTE_REQUIRED' end,
      jsonb_build_object('schema_version',3,'external_key',external_key || ':' || item,'experiment_id',experiment,
        'item_id',item,'vinted_item_id',listing_id,'listing_url',listing_url,'observed_price',observed,
        'observed_at',observed_at,'proposed_price',proposed,'state',case when kind='PRICE_VELOCITY' then 'WAITING_EXECUTION' else 'WAITING_QUOTE' end,
        'source','HQ_EXPERIMENT_STUDIO','spend_authorized',false),auth.uid());
  end loop;

  existing_payload := jsonb_build_object('schema_version',3,'external_key',external_key,'experiment_id',experiment,
    'experiment_type',kind,'item_count',item_count,'state','WAITING_EXECUTION','source','HQ_EXPERIMENT_STUDIO');
  insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
  values ('EXPERIMENT',experiment,'EXPERIMENT_CREATED',existing_payload,auth.uid());
  return existing_payload || jsonb_build_object('idempotent',false);
end $$;

revoke all on function public.create_hq_experiment_owner(jsonb) from public;
grant execute on function public.create_hq_experiment_owner(jsonb) to authenticated;

create or replace function public.report_hq_experiment_execution_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  experiment text := nullif(p->>'experiment_id','');
  item text := nullif(p->>'item_id','');
  execution_type text := nullif(p->>'execution_type','');
  spend numeric := nullif(p->>'promotion_spend','')::numeric;
  external_key text := nullif(p->>'external_key','');
  kind text;
  proposed numeric;
  payload jsonb;
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
    payload := payload || jsonb_build_object('proposed_price',proposed,'state','WAITING_COLLECTOR');
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
    values ('ITEM',item,'OWNER_EXECUTION_REPORTED',payload,auth.uid());
  elsif execution_type='EXPOSURE' then
    if spend is null or spend<=0 then raise exception 'Actual promotion spend required'; end if;
    update public.hq_experiment_items set promotion_spend=spend,execution_confirmed_at=now(),outcome_status='ACTIVE',updated_at=now()
    where experiment_id=experiment and item_id=item and outcome_status='WAITING_QUOTE';
    if not found then raise exception 'Exposure item is not waiting for purchase confirmation'; end if;
    update public.hq_experiments set status='ACTIVE',activated_at=coalesce(activated_at,now()),updated_at=now()
    where experiment_id=experiment;
    payload := payload || jsonb_build_object('promotion_spend',spend,'state','ACTIVE','purchase_automated',false);
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload,created_by)
    values ('ITEM',item,'BUMP_EXECUTION_REPORTED',payload,auth.uid());
  else raise exception 'Execution type must be PRICE or EXPOSURE';
  end if;
  return payload;
end $$;

revoke all on function public.report_hq_experiment_execution_owner(jsonb) from public;
grant execute on function public.report_hq_experiment_execution_owner(jsonb) to authenticated;

create or replace view public.hq_experiment_progress
with (security_invoker=true) as
with progress as (
  select e.experiment_id,e.experiment_type,e.status,e.objective,e.planned_start_on,e.planned_end_on,e.activated_at,e.success_rules,
         count(ei.item_id)::integer as item_count,
         count(*) filter (where ei.outcome_status='SOLD')::integer as sold_count,
         count(*) filter (where ei.outcome_status='ACTIVE')::integer as active_count,
         count(*) filter (where ei.outcome_status in ('WAITING_EXECUTION','WAITING_QUOTE','CONDITIONAL'))::integer as waiting_count,
         coalesce(sum(ei.sale_price) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as realised_sales,
         coalesce(sum(ei.net_profit) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as realised_profit,
         coalesce(sum(ei.capital_released) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as capital_released,
         coalesce(sum(ei.promotion_spend),0)::numeric(12,2) as promotion_spend
  from public.hq_experiments e left join public.hq_experiment_items ei using(experiment_id)
  group by e.experiment_id
)
select p.experiment_id,p.experiment_type,p.status,p.objective,p.planned_start_on,p.planned_end_on,p.activated_at,
  p.item_count,p.sold_count,p.active_count,p.waiting_count,p.realised_sales,p.realised_profit,p.capital_released,p.promotion_spend,
  case
    when p.status in ('COMPLETED','STOPPED') then p.status
    when p.activated_at is null then 'NOT_STARTED'
    when now()<p.activated_at+interval '7 days' then 'COLLECTING'
    when p.sold_count>=coalesce((p.success_rules#>>'{day_7,retain,minimum_sales}')::integer,1) then 'RETAIN'
    when p.experiment_type='PRICE_VELOCITY' and p.sold_count>0 then 'REVISE'
    else 'STOP'
  end as day_7_gate
from progress p;

revoke all on table public.hq_experiment_progress from public;
grant select on table public.hq_experiment_progress to authenticated;
