-- FADEWELL HQ — immutable, atomic Ledger staging.
-- Run after 001–003. This does not cut over bookkeeping to HQ.

alter table public.hq_ledger_import_runs
  add column if not exists source_sha256 text,
  add column if not exists source_headers_sha256 text,
  add column if not exists completed_at timestamptz,
  add column if not exists failure_detail text;
alter table public.hq_ledger_import_runs
  drop constraint if exists hq_ledger_import_runs_status_check;
alter table public.hq_ledger_import_runs
  add constraint hq_ledger_import_runs_status_check
  check (status in ('STARTED','STAGED','VERIFIED','REJECTED','SUPERSEDED','CUTOVER','FAILED'));
create unique index if not exists hq_ledger_import_source_hash_unique
  on public.hq_ledger_import_runs(source_name, source_sha256)
  where source_sha256 is not null;
-- This is the forensic snapshot. hq_ledger_items is reserved for the future
-- canonical Ledger and is no longer a staging target.
create table if not exists public.hq_ledger_import_items (
  import_id uuid not null references public.hq_ledger_import_runs(import_id) on delete restrict,
  item_id text not null,
  payload jsonb not null,
  source_row_sha256 text not null,
  imported_at timestamptz not null default now(),
  primary key (import_id, item_id),
  unique (import_id, source_row_sha256)
);
create index if not exists hq_ledger_import_items_item_index
  on public.hq_ledger_import_items(item_id);
-- Preserve the already staged 003 baseline as legacy evidence where possible.
insert into public.hq_ledger_import_items(import_id,item_id,payload,source_row_sha256)
select source_import_id, item_id,
       jsonb_build_object('source_row',source_row,'legacy_projection',to_jsonb(public.hq_ledger_items)),
       md5(coalesce(source_row::text,item_id))
from public.hq_ledger_items
where source_import_id is not null
on conflict do nothing;
create or replace function public.hq_set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists hq_ledger_items_set_updated_at on public.hq_ledger_items;
create trigger hq_ledger_items_set_updated_at before update on public.hq_ledger_items
for each row execute function public.hq_set_updated_at();
-- One RPC call means the import header and all item snapshots either arrive
-- together or are rolled back together. Service role only; browser clients
-- cannot stage or promote financial data.
create or replace function public.stage_hq_ledger_import(p_metadata jsonb, p_items jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  run_id uuid := (p_metadata->>'import_id')::uuid;
  existing_id uuid;
  expected_count integer := (p_metadata->>'row_count')::integer;
  actual_count integer;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) <> expected_count then
    raise exception 'Item payload count does not match import metadata';
  end if;
  select import_id into existing_id from hq_ledger_import_runs
    where source_name = p_metadata->>'source_name'
      and source_sha256 = p_metadata->>'source_sha256';
  if existing_id is not null then return existing_id; end if;

  insert into hq_ledger_import_runs(import_id,source_name,source_synced_at,row_count,status,report,source_sha256,source_headers_sha256)
  values(run_id,p_metadata->>'source_name',(p_metadata->>'source_synced_at')::timestamptz,expected_count,
         'STARTED',coalesce(p_metadata->'report','{}'::jsonb),p_metadata->>'source_sha256',p_metadata->>'source_headers_sha256');

  insert into hq_ledger_import_items(import_id,item_id,payload,source_row_sha256)
  select run_id, value->>'item_id', value->'payload', value->>'source_row_sha256'
  from jsonb_array_elements(p_items);
  get diagnostics actual_count = row_count;
  if actual_count <> expected_count then raise exception 'Inserted % rows, expected %', actual_count, expected_count; end if;

  update hq_ledger_import_runs set status='STAGED', completed_at=now() where import_id=run_id;
  return run_id;
end $$;
revoke all on function public.stage_hq_ledger_import(jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.stage_hq_ledger_import(jsonb,jsonb) to service_role;
-- Central, append-only decisions for future online HQ. They are intentionally
-- separate from generated observation queues, so sync never erases a decision.
create table if not exists public.hq_operational_actions (
  id bigint generated always as identity primary key,
  entity_type text not null check (entity_type in ('REVIEW','CAPTURE','ITEM','LISTING')),
  entity_key text not null,
  action_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create index if not exists hq_operational_actions_entity_index
  on public.hq_operational_actions(entity_type,entity_key,created_at desc);
alter table public.hq_ledger_import_items enable row level security;
alter table public.hq_operational_actions enable row level security;
-- No browser policy is intentionally created here. A later owner membership
-- migration grants minimum required access before the public host exists.;
