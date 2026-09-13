-- FADEWELL HQ — first operational schema.
-- Run once in Supabase SQL Editor. This does not copy images or alter Vinted.

create table if not exists public.hq_items (
  item_id text primary key,
  name text,
  sourcing_type text,
  tier text,
  total_capital numeric(12,2),
  ledger_status text,
  vinted_item_id text unique,
  listing_url text,
  live_title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.hq_listing_snapshots (
  id bigint generated always as identity primary key,
  vinted_item_id text not null,
  captured_at timestamptz not null,
  title text,
  price_pln numeric(12,2),
  views integer,
  favourites integer,
  visible boolean,
  photo_url text,
  source text not null,
  unique(vinted_item_id, captured_at)
);
create table if not exists public.hq_review_queue (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('UNLINKED_LIVE','MISSING')),
  item_id text references public.hq_items(item_id),
  vinted_item_id text,
  detail text not null,
  state text not null default 'OPEN' check (state in ('OPEN','LINKED','SOLD','RELISTED','HIDDEN','UNKNOWN','STALE_SNAPSHOT')),
  created_at timestamptz not null default now()
);
create unique index if not exists hq_review_open_unique
  on public.hq_review_queue(kind, vinted_item_id) where state = 'OPEN';
create table if not exists public.hq_capture_candidates (
  id bigint generated always as identity primary key,
  url text not null,
  title text,
  price_pln numeric(12,2),
  photo_urls jsonb not null default '[]'::jsonb,
  state text not null default 'NEW' check (state in ('NEW','PROCESSED','DISCARDED')),
  created_at timestamptz not null default now()
);
create index if not exists hq_listing_snapshots_item_time
  on public.hq_listing_snapshots(vinted_item_id, captured_at desc);
alter table public.hq_items enable row level security;
alter table public.hq_listing_snapshots enable row level security;
alter table public.hq_review_queue enable row level security;
alter table public.hq_capture_candidates enable row level security;
-- Dashboard users must sign in; anonymous/public access is intentionally blocked.
create policy "hq authenticated item access" on public.hq_items
  for all to authenticated using (true) with check (true);
create policy "hq authenticated snapshot access" on public.hq_listing_snapshots
  for all to authenticated using (true) with check (true);
create policy "hq authenticated review access" on public.hq_review_queue
  for all to authenticated using (true) with check (true);
create policy "hq authenticated capture access" on public.hq_capture_candidates
  for all to authenticated using (true) with check (true);
