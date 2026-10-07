-- A purchase receipt queues capture immediately; photos remain safe even when
-- item-to-DEN matching needs a later review (notably same-title bundles).
create table public.hq_purchase_photo_ingest_jobs (
  source_event_id text primary key,
  vinted_transaction_id text not null,
  occurred_on date not null,
  paid_amount numeric not null,
  receipt_title text not null,
  bundle_titles jsonb not null default '[]'::jsonb,
  den_item_ids jsonb not null default '[]'::jsonb,
  state text not null default 'PENDING' check (state in ('PENDING','CAPTURED','NEEDS_REVIEW')),
  attempts integer not null default 0,
  last_attempt_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index hq_purchase_photo_ingest_jobs_pending on public.hq_purchase_photo_ingest_jobs(created_at)
  where state = 'PENDING';
alter table public.hq_purchase_photo_ingest_jobs enable row level security;
create policy "hq owner purchase photo jobs read" on public.hq_purchase_photo_ingest_jobs
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_purchase_photo_ingest_jobs from public, anon;
grant select on public.hq_purchase_photo_ingest_jobs to authenticated;

create table public.hq_purchase_photo_captures (
  source_event_id text not null references public.hq_purchase_photo_ingest_jobs(source_event_id),
  source_listing_id text not null,
  source_listing_url text not null,
  listing_title text,
  photo_paths jsonb not null check (jsonb_typeof(photo_paths) = 'array' and jsonb_array_length(photo_paths) between 1 and 3),
  item_id text references public.hq_ledger_items(item_id),
  captured_at timestamptz not null default now(),
  primary key (source_event_id, source_listing_id)
);
create index hq_purchase_photo_captures_unlinked on public.hq_purchase_photo_captures(source_event_id)
  where item_id is null;
alter table public.hq_purchase_photo_captures enable row level security;
create policy "hq owner purchase photo captures read" on public.hq_purchase_photo_captures
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_purchase_photo_captures from public, anon;
grant select on public.hq_purchase_photo_captures to authenticated;
