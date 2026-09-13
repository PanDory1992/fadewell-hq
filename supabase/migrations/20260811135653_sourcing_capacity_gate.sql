-- Versioned sourcing policy: live capacity metrics decide whether new sourcing is open.
-- Replacement slots are earned by confirmed Ledger sales and consumed automatically
-- when a queued backlog DEN becomes listed.

create table if not exists public.hq_sourcing_policies (
  policy_id text primary key,
  version_label text not null,
  status text not null check (status in ('DRAFT','ACTIVE','RETIRED')),
  effective_from date not null,
  effective_until date,
  max_unlisted_count integer not null check (max_unlisted_count >= 0),
  max_unlisted_capital numeric(12,2) not null check (max_unlisted_capital >= 0),
  slot_rule text not null default 'ONE_CONFIRMED_SALE_ONE_REPLACEMENT',
  source_route text,
  owner_label text not null default 'Miki',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists hq_one_active_sourcing_policy
  on public.hq_sourcing_policies(status) where status='ACTIVE';

create table if not exists public.hq_sourcing_policy_cells (
  policy_id text not null references public.hq_sourcing_policies(policy_id) on delete cascade,
  cell_id text not null,
  rule_kind text not null check (rule_kind in ('SEGMENT','GUARDRAIL')),
  decision text not null check (decision in ('GREEN','RED')),
  brand_key text not null default '*',
  model_key text not null default '*',
  size_band text not null default '*',
  expected_sell_min numeric(12,2),
  expected_sell_max numeric(12,2),
  max_landed_cost numeric(12,2),
  qualifier text,
  rationale text not null,
  priority integer not null default 0,
  primary key (policy_id,cell_id)
);

create table if not exists public.hq_sourcing_replacement_candidates (
  policy_id text not null references public.hq_sourcing_policies(policy_id) on delete cascade,
  item_id text not null references public.hq_ledger_items(item_id),
  queue_rank integer not null check (queue_rank > 0),
  demand_cell text not null,
  required_check text not null,
  status text not null default 'QUEUED' check (status in ('QUEUED','RELEASED','SKIPPED')),
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (policy_id,item_id),
  unique (policy_id,queue_rank)
);

alter table public.hq_sourcing_policies enable row level security;
alter table public.hq_sourcing_policy_cells enable row level security;
alter table public.hq_sourcing_replacement_candidates enable row level security;

drop policy if exists "hq owner sourcing policy read" on public.hq_sourcing_policies;
create policy "hq owner sourcing policy read" on public.hq_sourcing_policies
for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner sourcing cells read" on public.hq_sourcing_policy_cells;
create policy "hq owner sourcing cells read" on public.hq_sourcing_policy_cells
for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner sourcing candidates read" on public.hq_sourcing_replacement_candidates;
create policy "hq owner sourcing candidates read" on public.hq_sourcing_replacement_candidates
for select to authenticated using (public.is_hq_owner());

revoke all on table public.hq_sourcing_policies from public;
revoke all on table public.hq_sourcing_policy_cells from public;
revoke all on table public.hq_sourcing_replacement_candidates from public;
grant select on table public.hq_sourcing_policies to authenticated;
grant select on table public.hq_sourcing_policy_cells to authenticated;
grant select on table public.hq_sourcing_replacement_candidates to authenticated;

create or replace view public.hq_sourcing_gate_current
with (security_invoker=true) as
with active_policy as (
  select * from public.hq_sourcing_policies where status='ACTIVE' order by effective_from desc limit 1
), metrics as (
  select
    count(*) filter (where ledger_status='LISTED-BACKLOG')::integer as listed_count,
    count(*) filter (where ledger_status='UNLISTED-BACKLOG')::integer as unlisted_count,
    coalesce(sum(total_capital) filter (where ledger_status='UNLISTED-BACKLOG'),0)::numeric(12,2) as unlisted_capital
  from public.hq_ledger_items
), flow as (
  select p.policy_id,
    (select count(*) from public.hq_ledger_items i where i.ledger_status='SOLD' and i.sold_on>=p.effective_from)::integer as sales_since_policy,
    (select count(*) from public.hq_sourcing_replacement_candidates c where c.policy_id=p.policy_id and c.status='RELEASED')::integer as replacements_released
  from active_policy p
)
select p.policy_id,p.version_label,p.effective_from,p.effective_until,p.max_unlisted_count,p.max_unlisted_capital,p.slot_rule,
  m.listed_count,m.unlisted_count,m.unlisted_capital,f.sales_since_policy,f.replacements_released,
  (f.sales_since_policy-f.replacements_released)::integer as slot_balance,
  greatest(f.sales_since_policy-f.replacements_released,0)::integer as available_replacement_slots,
  (m.unlisted_count>p.max_unlisted_count) as count_over_limit,
  (m.unlisted_capital>p.max_unlisted_capital) as capital_over_limit,
  case when m.unlisted_count>p.max_unlisted_count or m.unlisted_capital>p.max_unlisted_capital then 'REPLACEMENT_ONLY' else 'OPEN' end as gate_state,
  case when m.unlisted_count>p.max_unlisted_count or m.unlisted_capital>p.max_unlisted_capital
    then 'Nowy sourcing zamknięty. Każda potwierdzona sprzedaż otwiera jeden slot dla kolejnej pary z backlogu.'
    else 'Backlog mieści się w limicie polityki; sourcing może wrócić wyłącznie w zielonych komórkach.' end as gate_reason
from active_policy p cross join metrics m join flow f using (policy_id);

revoke all on table public.hq_sourcing_gate_current from public;
grant select on table public.hq_sourcing_gate_current to authenticated;

create or replace view public.hq_sourcing_replacement_queue_current
with (security_invoker=true) as
with queued as (
  select c.policy_id,c.item_id,row_number() over (partition by c.policy_id order by c.queue_rank)::integer as active_rank
  from public.hq_sourcing_replacement_candidates c where c.status='QUEUED'
)
select c.policy_id,c.item_id,c.queue_rank,q.active_rank,c.demand_cell,c.required_check,c.status,c.released_at,
  i.ledger_status,i.total_capital,i.purchased_on,i.live_title,i.manual_title,i.name,i.item_dna,
  cell.decision as policy_decision,cell.expected_sell_min,cell.expected_sell_max,cell.max_landed_cost,cell.qualifier,
  g.gate_state,g.available_replacement_slots,g.slot_balance,
  case
    when c.status='RELEASED' then 'RELEASED'
    when c.status='SKIPPED' then 'SKIPPED'
    when q.active_rank<=g.available_replacement_slots then 'CHECK_REQUIRED'
    else 'WAITING_SLOT'
  end as queue_state,
  case when cell.max_landed_cost is not null and i.total_capital>cell.max_landed_cost then true else false end as economics_flag
from public.hq_sourcing_replacement_candidates c
join public.hq_ledger_items i using (item_id)
join public.hq_sourcing_gate_current g using (policy_id)
left join queued q using (policy_id,item_id)
left join public.hq_sourcing_policy_cells cell on cell.policy_id=c.policy_id and cell.cell_id=c.demand_cell;

revoke all on table public.hq_sourcing_replacement_queue_current from public;
grant select on table public.hq_sourcing_replacement_queue_current to authenticated;

create or replace function public.hq_capture_sourcing_replacement_release()
returns trigger language plpgsql security definer set search_path=public as $$
declare candidate record; balance integer;
begin
  if new.ledger_status<>'LISTED-BACKLOG' or old.ledger_status='LISTED-BACKLOG' then return new; end if;
  select c.policy_id,c.item_id into candidate
  from public.hq_sourcing_replacement_candidates c
  join public.hq_sourcing_policies p using (policy_id)
  where c.item_id=new.item_id and c.status='QUEUED' and p.status='ACTIVE'
  order by c.queue_rank limit 1;
  if not found then return new; end if;
  select slot_balance into balance from public.hq_sourcing_gate_current where policy_id=candidate.policy_id;
  update public.hq_sourcing_replacement_candidates
  set status='RELEASED',released_at=now(),updated_at=now()
  where policy_id=candidate.policy_id and item_id=candidate.item_id and status='QUEUED';
  if found then
    insert into public.hq_operational_actions(entity_type,entity_key,action_type,payload)
    values ('ITEM',new.item_id,case when coalesce(balance,0)>0 then 'SOURCING_REPLACEMENT_RELEASED' else 'SOURCING_GATE_EXCEPTION' end,jsonb_build_object(
      'schema_version',1,'policy_id',candidate.policy_id,'item_id',new.item_id,
      'slot_balance_before',balance,'listed_on',coalesce(new.listed_on,current_date),
      'source','HQ_LEDGER_STATUS','state','RELEASED'
    ));
  end if;
  return new;
end $$;

drop trigger if exists hq_capture_sourcing_candidate_release on public.hq_ledger_items;
create trigger hq_capture_sourcing_candidate_release
after update of ledger_status on public.hq_ledger_items
for each row execute function public.hq_capture_sourcing_replacement_release();
revoke all on function public.hq_capture_sourcing_replacement_release() from public;

insert into public.hq_sourcing_policies(policy_id,version_label,status,effective_from,effective_until,max_unlisted_count,max_unlisted_capital,source_route)
values ('SRC-2026-08-11-V1','V1 · 30 sales / 30 days','ACTIVE','2026-08-11','2026-09-10',50,2000,'VINTED_30_SALES_BLOCKERS_AND_PLAN_2026-08-11')
on conflict (policy_id) do nothing;

insert into public.hq_sourcing_policy_cells(policy_id,cell_id,rule_kind,decision,brand_key,model_key,size_band,expected_sell_min,expected_sell_max,max_landed_cost,qualifier,rationale,priority) values
('SRC-2026-08-11-V1','G-501-33-35','SEGMENT','GREEN','levis','501','W33-35',139,179,50,null,'Najmocniejsza powtarzalna komórka; tylko w ramach slotu replacement.',40),
('SRC-2026-08-11-V1','G-505-30-32','SEGMENT','GREEN','levis','505','W30-32',119,159,45,null,'Powtarzalny model w centralnym paśmie rozmiaru.',35),
('SRC-2026-08-11-V1','G-505-33-35','SEGMENT','GREEN','levis','505','W33-35',119,159,45,null,'Powtarzalny model w centralnym paśmie rozmiaru.',35),
('SRC-2026-08-11-V1','G-WRANGLER-30-32','SEGMENT','GREEN','wrangler','*','W30-32',109,139,35,null,'Wrangler tylko z niskim kosztem wejścia.',30),
('SRC-2026-08-11-V1','G-WRANGLER-33-35','SEGMENT','GREEN','wrangler','*','W33-35',109,139,35,null,'Wrangler tylko z niskim kosztem wejścia.',30),
('SRC-2026-08-11-V1','G-550-30-32','SEGMENT','GREEN','levis','550','W30-32',159,199,50,'Wymagany realny wyróżnik: era, pochodzenie, wash albo stan.','Nie kupuj zwykłej pary tylko dlatego, że ma numer 550.',25),
('SRC-2026-08-11-V1','G-550-33-35','SEGMENT','GREEN','levis','550','W33-35',159,199,50,'Wymagany realny wyróżnik: era, pochodzenie, wash albo stan.','Nie kupuj zwykłej pary tylko dlatego, że ma numer 550.',25),
('SRC-2026-08-11-V1','G-615-30-32','SEGMENT','GREEN','levis','615','W30-32',159,199,50,'Wymagany realny wyróżnik: era, pochodzenie, wash albo stan.','615 tylko jako para wyraźnie lepsza od zwykłego stocku.',25),
('SRC-2026-08-11-V1','G-615-33-35','SEGMENT','GREEN','levis','615','W33-35',159,199,50,'Wymagany realny wyróżnik: era, pochodzenie, wash albo stan.','615 tylko jako para wyraźnie lepsza od zwykłego stocku.',25),
('SRC-2026-08-11-V1','R-SMALL-WAIST','SEGMENT','RED','*','*','W<=29',null,null,null,null,'Rozmiar poza bieżącym rdzeniem popytu.',100),
('SRC-2026-08-11-V1','R-LEE-GENERIC','SEGMENT','RED','lee','*','*',null,null,null,'Wyjątek wymaga konkretnego kolekcjonerskiego dowodu.','Generyczny Lee pozostaje zamknięty.',90),
('SRC-2026-08-11-V1','R-ORDINARY-219','GUARDRAIL','RED','*','*','*',null,219,null,'Nie dotyczy pary z udokumentowanym rzadkim wyróżnikiem.','Zwykła para wymagająca ceny powyżej 219 zł nie wchodzi do sourcingu.',80),
('SRC-2026-08-11-V1','R-OFF-NICHE','GUARDRAIL','RED','*','*','*',null,null,null,null,'Off-niche zamknięte, gdy backlog przekracza limit.',70)
on conflict (policy_id,cell_id) do nothing;

insert into public.hq_sourcing_replacement_candidates(policy_id,item_id,queue_rank,demand_cell,required_check) values
('SRC-2026-08-11-V1','DEN-202',1,'G-501-33-35','Sprawdź stan i zapach; opis zakupu zawiera sygnał „Smród”.'),
('SRC-2026-08-11-V1','DEN-264',2,'G-501-33-35','Uzupełnij pomiary i potwierdź gotowość prezentacji.'),
('SRC-2026-08-11-V1','DEN-225',3,'G-501-33-35','Uzupełnij pomiary i potwierdź stan przed zdjęciami.'),
('SRC-2026-08-11-V1','DEN-223',4,'G-505-33-35','Kapitał przekracza nowy limit komórki; sprawdź stan i realną cenę wyjścia.'),
('SRC-2026-08-11-V1','DEN-285',5,'G-WRANGLER-30-32','Uzupełnij pomiary i potwierdź gotowość prezentacji.')
on conflict (policy_id,item_id) do nothing;
