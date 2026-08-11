-- Durable owner-approved experiments. Observations stay in snapshots/Ledger;
-- intent and outcomes live here and in the append-only operational action log.

create table if not exists public.hq_experiments (
  experiment_id text primary key check (experiment_id <> ''),
  experiment_type text not null check (experiment_type in ('PRICE_VELOCITY','PAID_EXPOSURE','SOURCING_POLICY')),
  status text not null check (status in ('DRAFT','APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE','EVALUATE','COMPLETED','STOPPED')),
  objective text not null,
  source_route text,
  metric jsonb not null default '{}'::jsonb,
  baseline jsonb not null default '{}'::jsonb,
  success_rules jsonb not null default '{}'::jsonb,
  max_downside jsonb not null default '{}'::jsonb,
  planned_start_on date,
  planned_end_on date,
  activated_at timestamptz,
  completed_at timestamptz,
  decision text,
  owner_label text not null default 'Miki',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hq_experiment_items (
  experiment_id text not null references public.hq_experiments(experiment_id) on delete cascade,
  item_id text not null references public.hq_ledger_items(item_id),
  role text not null,
  baseline_price numeric(12,2),
  proposed_price numeric(12,2),
  confirmed_price numeric(12,2),
  baseline_favourites integer,
  baseline_observed_at timestamptz,
  execution_confirmed_at timestamptz,
  promotion_spend numeric(12,2),
  sold_on date,
  sale_price numeric(12,2),
  net_profit numeric(12,2),
  capital_released numeric(12,2),
  outcome_status text not null check (outcome_status in ('WAITING_EXECUTION','WAITING_QUOTE','CONDITIONAL','ACTIVE','SOLD','STOPPED')),
  decision text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (experiment_id, item_id),
  check (baseline_price is null or baseline_price > 0),
  check (proposed_price is null or proposed_price > 0),
  check (confirmed_price is null or confirmed_price > 0),
  check (promotion_spend is null or promotion_spend >= 0)
);

alter table public.hq_experiments enable row level security;
alter table public.hq_experiment_items enable row level security;

drop policy if exists "hq owner experiment read" on public.hq_experiments;
create policy "hq owner experiment read" on public.hq_experiments
for select to authenticated using (public.is_hq_owner());

drop policy if exists "hq owner experiment item read" on public.hq_experiment_items;
create policy "hq owner experiment item read" on public.hq_experiment_items
for select to authenticated using (public.is_hq_owner());

revoke all on table public.hq_experiments from public;
revoke all on table public.hq_experiment_items from public;
grant select on table public.hq_experiments to authenticated;
grant select on table public.hq_experiment_items to authenticated;

create index if not exists hq_experiment_items_item_index
  on public.hq_experiment_items(item_id, outcome_status);
create index if not exists hq_experiments_status_index
  on public.hq_experiments(status, planned_end_on);

create or replace function public.record_hq_price_test_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item text := nullif(p->>'item_id', '');
  amount numeric := nullif(p->>'price', '')::numeric;
  external_key text := nullif(p->>'external_key', '');
  observed_price numeric;
  observed_at timestamptz;
  listing_id text;
  listing_url text;
  experiment text;
  action_id bigint;
  action_payload jsonb;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if item is null or amount is null or amount <= 0 or external_key is null then
    raise exception 'Listed DEN, positive proposed price and external key required';
  end if;

  select a.id, a.payload into action_id, action_payload
  from public.hq_operational_actions a
  where a.payload->>'external_key' = external_key limit 1;
  if found then
    return action_payload || jsonb_build_object('action_id', action_id, 'idempotent', true);
  end if;

  select coalesce(s.price_pln, i.live_list_price), s.captured_at,
         i.vinted_item_id, i.listing_url
    into observed_price, observed_at, listing_id, listing_url
  from public.hq_ledger_items i
  left join lateral (
    select snap.price_pln, snap.captured_at
    from public.hq_listing_snapshots snap
    where snap.vinted_item_id = i.vinted_item_id
      and (snap.source like 'github_actions_vinted%' or snap.source like 'supabase_edge_vinted%')
    order by snap.captured_at desc limit 1
  ) s on true
  where i.item_id = item and i.ledger_status = 'LISTED-BACKLOG'
  for update of i;
  if not found then raise exception 'Only an active listed DEN may receive a price proposal'; end if;
  if observed_price is not null and amount = observed_price then
    raise exception 'Proposed price already matches the latest Vinted observation';
  end if;

  select ei.experiment_id into experiment
  from public.hq_experiment_items ei
  join public.hq_experiments e using (experiment_id)
  where ei.item_id = item and ei.proposed_price = amount
    and ei.execution_confirmed_at is null
    and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE')
  order by e.created_at desc limit 1;

  if experiment is null then
    experiment := 'EXP-PRICE-' || to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS') || '-' || replace(item,'DEN-','');
    insert into public.hq_experiments(
      experiment_id, experiment_type, status, objective, source_route,
      metric, success_rules, owner_label, created_by
    ) values (
      experiment, 'PRICE_VELOCITY', 'WAITING_EXECUTION',
      'Owner-approved single-item price test from Pricing cockpit.',
      'HQ Pricing cockpit + Vinted collector',
      '{"primary":"sale"}'::jsonb,
      '{"review":"owner decision after bounded observation"}'::jsonb,
      'Miki', auth.uid()
    );
    insert into public.hq_experiment_items(
      experiment_id, item_id, role, baseline_price, proposed_price,
      baseline_observed_at, outcome_status
    ) values (
      experiment, item, 'PRICE_TREATMENT', observed_price, amount,
      observed_at, 'WAITING_EXECUTION'
    );
  end if;

  select a.id, a.payload into action_id, action_payload
  from public.hq_operational_actions a
  where a.entity_type = 'ITEM' and a.entity_key = item
    and a.action_type = 'PRICE_CHANGE_APPROVED'
    and a.payload->>'experiment_id' = experiment
    and (a.payload->>'proposed_price')::numeric = amount
  order by a.created_at desc limit 1;
  if found then
    return action_payload || jsonb_build_object('action_id', action_id, 'idempotent', true);
  end if;

  action_payload := jsonb_build_object(
    'schema_version', 2, 'external_key', external_key,
    'experiment_id', experiment, 'item_id', item,
    'vinted_item_id', listing_id, 'listing_url', listing_url,
    'observed_price', observed_price, 'observed_at', observed_at,
    'proposed_price', amount, 'state', 'WAITING_EXECUTION',
    'source', 'PRICING_COCKPIT'
  );
  insert into public.hq_operational_actions(entity_type, entity_key, action_type, payload, created_by)
  values ('ITEM', item, 'PRICE_CHANGE_APPROVED', action_payload, auth.uid())
  returning id into action_id;
  return action_payload || jsonb_build_object('action_id', action_id, 'idempotent', false);
end $$;

revoke all on function public.record_hq_price_test_owner(jsonb) from public;
grant execute on function public.record_hq_price_test_owner(jsonb) to authenticated;

create or replace function public.hq_confirm_price_experiment_from_snapshot()
returns trigger language plpgsql security definer set search_path=public as $$
declare matched record;
begin
  if new.price_pln is null or not (
    new.source like 'github_actions_vinted%' or new.source like 'supabase_edge_vinted%'
  ) then return new; end if;

  for matched in
    select ei.experiment_id, ei.item_id
    from public.hq_experiment_items ei
    join public.hq_experiments e using (experiment_id)
    join public.hq_ledger_items i on i.item_id = ei.item_id
    where i.vinted_item_id = new.vinted_item_id
      and ei.proposed_price = new.price_pln
      and ei.execution_confirmed_at is null
      and e.status in ('APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE')
  loop
    update public.hq_experiment_items
    set confirmed_price = new.price_pln,
        execution_confirmed_at = new.captured_at,
        outcome_status = 'ACTIVE', updated_at = now()
    where experiment_id = matched.experiment_id and item_id = matched.item_id
      and execution_confirmed_at is null;
    if found then
      update public.hq_experiments
      set status = 'ACTIVE', activated_at = coalesce(activated_at, new.captured_at), updated_at = now()
      where experiment_id = matched.experiment_id;
      insert into public.hq_operational_actions(entity_type, entity_key, action_type, payload)
      values ('ITEM', matched.item_id, 'PRICE_CHANGE_CONFIRMED', jsonb_build_object(
        'schema_version', 2,
        'external_key', 'confirm:' || matched.experiment_id || ':' || matched.item_id || ':' || new.captured_at,
        'experiment_id', matched.experiment_id, 'item_id', matched.item_id,
        'confirmed_price', new.price_pln, 'confirmed_at', new.captured_at,
        'source', new.source, 'state', 'ACTIVE'
      )) on conflict do nothing;
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists hq_confirm_price_experiment_snapshot on public.hq_listing_snapshots;
create trigger hq_confirm_price_experiment_snapshot
after insert on public.hq_listing_snapshots
for each row execute function public.hq_confirm_price_experiment_from_snapshot();
revoke all on function public.hq_confirm_price_experiment_from_snapshot() from public;

create or replace function public.hq_capture_experiment_sale()
returns trigger language plpgsql security definer set search_path=public as $$
declare matched record; realised numeric;
begin
  if new.ledger_status <> 'SOLD' or old.ledger_status = 'SOLD' then return new; end if;
  realised := coalesce(new.sale_price_arbitrage, new.sale_price_recycled);
  for matched in
    select ei.experiment_id, ei.item_id
    from public.hq_experiment_items ei
    join public.hq_experiments e using (experiment_id)
    where ei.item_id = new.item_id and ei.outcome_status <> 'SOLD'
      and e.status not in ('COMPLETED','STOPPED')
  loop
    update public.hq_experiment_items
    set sold_on = coalesce(new.sold_on, current_date), sale_price = realised,
        net_profit = new.net_profit, capital_released = new.total_capital,
        outcome_status = 'SOLD', updated_at = now()
    where experiment_id = matched.experiment_id and item_id = matched.item_id;
    update public.hq_experiments
    set status = 'ACTIVE', activated_at = coalesce(activated_at, now()), updated_at = now()
    where experiment_id = matched.experiment_id;
    insert into public.hq_operational_actions(entity_type, entity_key, action_type, payload)
    values ('ITEM', matched.item_id, 'EXPERIMENT_ITEM_SOLD', jsonb_build_object(
      'schema_version', 2,
      'external_key', 'sold:' || matched.experiment_id || ':' || matched.item_id,
      'experiment_id', matched.experiment_id, 'item_id', matched.item_id,
      'sold_on', coalesce(new.sold_on, current_date), 'sale_price', realised,
      'net_profit', new.net_profit, 'capital_released', new.total_capital,
      'source', 'HQ_LEDGER', 'state', 'SOLD'
    )) on conflict do nothing;
  end loop;
  return new;
end $$;

drop trigger if exists hq_capture_experiment_sale on public.hq_ledger_items;
create trigger hq_capture_experiment_sale
after update of ledger_status, sale_price_arbitrage, sale_price_recycled, net_profit, sold_on
on public.hq_ledger_items
for each row execute function public.hq_capture_experiment_sale();
revoke all on function public.hq_capture_experiment_sale() from public;

create or replace view public.hq_experiment_progress
with (security_invoker=true) as
with progress as (
  select e.experiment_id, e.experiment_type, e.status, e.objective,
         e.planned_start_on, e.planned_end_on, e.activated_at,
         count(ei.item_id)::integer as item_count,
         count(*) filter (where ei.outcome_status='SOLD')::integer as sold_count,
         count(*) filter (where ei.outcome_status='ACTIVE')::integer as active_count,
         count(*) filter (where ei.outcome_status in ('WAITING_EXECUTION','WAITING_QUOTE','CONDITIONAL'))::integer as waiting_count,
         coalesce(sum(ei.sale_price) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as realised_sales,
         coalesce(sum(ei.net_profit) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as realised_profit,
         coalesce(sum(ei.capital_released) filter (where ei.outcome_status='SOLD'),0)::numeric(12,2) as capital_released,
         coalesce(sum(ei.promotion_spend),0)::numeric(12,2) as promotion_spend
  from public.hq_experiments e
  left join public.hq_experiment_items ei using (experiment_id)
  group by e.experiment_id
)
select p.*,
  case
    when p.status in ('COMPLETED','STOPPED') then p.status
    when p.activated_at is null then 'NOT_STARTED'
    when now() < p.activated_at + interval '7 days' then 'COLLECTING'
    when p.experiment_type='PRICE_VELOCITY' and p.sold_count>=3 then 'RETAIN'
    when p.experiment_type='PRICE_VELOCITY' and p.sold_count between 1 and 2 then 'REVISE'
    when p.experiment_type='PRICE_VELOCITY' then 'STOP'
    when p.experiment_type='PAID_EXPOSURE' and p.sold_count>=1 then 'RETAIN'
    when p.experiment_type='PAID_EXPOSURE' then 'STOP'
    else 'REVIEW'
  end as day_7_gate
from progress p;

revoke all on table public.hq_experiment_progress from public;
grant select on table public.hq_experiment_progress to authenticated;

insert into public.hq_experiments(
  experiment_id, experiment_type, status, objective, source_route,
  metric, baseline, success_rules, max_downside,
  planned_start_on, planned_end_on, owner_label
) values
(
  'EXP-2026-08-11-PRICE-VELOCITY', 'PRICE_VELOCITY', 'WAITING_EXECUTION',
  'Move eight warm listings into historically selling price lanes and test whether existing attention converts into at least three sales within seven days.',
  'Live HQ/Supabase + manual Vinted execution + collector confirmation',
  '{"primary":["cohort_sales","realised_sale_price","recorded_net_profit","capital_released","days_to_sale"]}'::jsonb,
  '{"item_count":8,"combined_favourites":60,"current_list_total":1682,"planned_list_total":1372,"recorded_capital":376.00,"observed_at":"2026-08-10T22:07:03Z"}'::jsonb,
  '{"day_7":{"retain":{"minimum_sales":3},"revise":{"minimum_sales":1,"maximum_sales":2},"stop":{"sales":0,"rule":"no second blind cut"}}}'::jsonb,
  '{"maximum_list_price_concession":310,"currency":"PLN","price_below_recorded_capital":false}'::jsonb,
  '2026-08-11', '2026-08-25', 'Miki'
),
(
  'EXP-2026-08-11-VINTED-BUMP', 'PAID_EXPOSURE', 'WAITING_EXECUTION',
  'Test native three-day national Vinted promotion on correctly priced cold listings and require at least one sale from wave one.',
  'Live HQ/Supabase + native Vinted quote/statistics + manual owner approval',
  '{"primary":["promotion_spend","sale_count","realised_net_profit","spend_per_sale"]}'::jsonb,
  '{"wave_1":["DEN-210","DEN-207"],"conditional_wave_2":["DEN-166"],"observed_at":"2026-08-10T22:07:03Z"}'::jsonb,
  '{"day_7":{"retain":{"minimum_sales":1},"stop":{"sales":0,"likes_or_views_do_not_authorize_repeat":true}}}'::jsonb,
  '{"spend_authorized":false,"requires_live_quote":true,"cap":"expected net profit of one selected pair"}'::jsonb,
  '2026-08-11', '2026-08-18', 'Miki'
)
on conflict (experiment_id) do nothing;

insert into public.hq_experiment_items(
  experiment_id, item_id, role, baseline_price, proposed_price,
  baseline_favourites, baseline_observed_at, outcome_status
) values
('EXP-2026-08-11-PRICE-VELOCITY','DEN-191','PRICE_TREATMENT',199,169,12,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-135','PRICE_TREATMENT',159,139,8,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-158','PRICE_TREATMENT',189,159,8,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-173','PRICE_TREATMENT',179,159,6,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-180','PRICE_TREATMENT',149,129,8,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-193','PRICE_TREATMENT',219,179,6,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-217','PRICE_TREATMENT',279,219,6,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-PRICE-VELOCITY','DEN-228','PRICE_TREATMENT',309,219,6,'2026-08-10T22:07:03Z','WAITING_EXECUTION'),
('EXP-2026-08-11-VINTED-BUMP','DEN-210','EXPOSURE_WAVE_1',129,null,2,'2026-08-10T22:07:03Z','WAITING_QUOTE'),
('EXP-2026-08-11-VINTED-BUMP','DEN-207','EXPOSURE_WAVE_1',139,null,3,'2026-08-10T22:07:03Z','WAITING_QUOTE'),
('EXP-2026-08-11-VINTED-BUMP','DEN-166','EXPOSURE_WAVE_2',179,169,2,'2026-08-10T22:07:03Z','CONDITIONAL')
on conflict (experiment_id, item_id) do nothing;

insert into public.hq_operational_actions(entity_type, entity_key, action_type, payload)
select 'ITEM', ei.item_id, 'PRICE_CHANGE_APPROVED', jsonb_build_object(
  'schema_version',2,'external_key',ei.experiment_id || ':' || ei.item_id || ':approved',
  'experiment_id',ei.experiment_id,'item_id',ei.item_id,
  'observed_price',ei.baseline_price,'observed_at',ei.baseline_observed_at,
  'proposed_price',ei.proposed_price,'state','WAITING_EXECUTION','source','OWNER_APPROVED_PLAN'
)
from public.hq_experiment_items ei
where ei.experiment_id='EXP-2026-08-11-PRICE-VELOCITY'
on conflict do nothing;

insert into public.hq_operational_actions(entity_type, entity_key, action_type, payload)
select 'ITEM', ei.item_id,
  case when ei.role='EXPOSURE_WAVE_1' then 'BUMP_QUOTE_REQUIRED' else 'BUMP_CONDITIONAL' end,
  jsonb_build_object(
    'schema_version',2,'external_key',ei.experiment_id || ':' || ei.item_id || ':exposure',
    'experiment_id',ei.experiment_id,'item_id',ei.item_id,
    'baseline_price',ei.baseline_price,'baseline_favourites',ei.baseline_favourites,
    'state',ei.outcome_status,'source','OWNER_APPROVED_PLAN','spend_authorized',false
  )
from public.hq_experiment_items ei
where ei.experiment_id='EXP-2026-08-11-VINTED-BUMP'
on conflict do nothing;
