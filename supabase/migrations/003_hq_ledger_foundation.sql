-- FADEWELL HQ — controlled Ledger migration foundation.
-- This creates staging and future canonical tables only. It does not alter
-- Google Sheet, Vinted, or promote HQ to the source of truth.

create table if not exists public.hq_ledger_import_runs (
  import_id uuid primary key,
  source_name text not null,
  source_synced_at timestamptz not null,
  imported_at timestamptz not null default now(),
  row_count integer not null,
  status text not null check (status in ('STAGED','VERIFIED','REJECTED','CUTOVER')),
  report jsonb not null default '{}'::jsonb
);
create table if not exists public.hq_ledger_items (
  item_id text primary key,
  name text not null,
  sourcing_type text,
  curation_era text,
  purchase_cost numeric(12,2),
  delivery_cost numeric(12,2),
  total_capital numeric(12,2),
  listed boolean,
  sale_price_arbitrage numeric(12,2),
  sale_price_recycled numeric(12,2),
  net_profit numeric(12,2),
  ledger_status text,
  flip_tier text,
  estimate_range text,
  estimate_sale_price numeric(12,2),
  estimate_net_profit numeric(12,2),
  purchased_on date,
  listed_on date,
  sold_on date,
  category text,
  advantage text,
  vinted_item_id text unique,
  listing_url text,
  live_title text,
  live_list_price numeric(12,2),
  last_live_check_on date,
  estimate_confidence text,
  estimate_evidence text,
  estimate_model_version text,
  source_import_id uuid not null references public.hq_ledger_import_runs(import_id),
  source_row jsonb not null,
  migration_state text not null default 'STAGED' check (migration_state in ('STAGED','VERIFIED','CANONICAL','RETIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- The journal is deliberately empty on first import. Existing Sheet rows do
-- not provide enough evidence to invent historical transaction dates/events.
create table if not exists public.hq_ledger_events (
  id bigint generated always as identity primary key,
  item_id text not null references public.hq_ledger_items(item_id),
  event_type text not null check (event_type in ('PURCHASE','LISTED','SALE','ADJUSTMENT','NOTE')),
  occurred_on date,
  amount numeric(12,2),
  currency text not null default 'PLN',
  detail text,
  source text not null check (source in ('MIGRATION','VINTED','MANUAL','SYSTEM')),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
create index if not exists hq_ledger_items_status_index on public.hq_ledger_items(ledger_status);
create index if not exists hq_ledger_events_item_time_index on public.hq_ledger_events(item_id, occurred_on desc);
alter table public.hq_ledger_import_runs enable row level security;
alter table public.hq_ledger_items enable row level security;
alter table public.hq_ledger_events enable row level security;
create policy "hq authenticated ledger import access" on public.hq_ledger_import_runs
  for all to authenticated using (true) with check (true);
create policy "hq authenticated ledger item access" on public.hq_ledger_items
  for all to authenticated using (true) with check (true);
create policy "hq authenticated ledger event access" on public.hq_ledger_events
  for all to authenticated using (true) with check (true);
