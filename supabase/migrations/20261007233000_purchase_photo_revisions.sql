-- Preserve previous source-photo evidence when the owner corrects a match.
create table public.hq_purchase_source_photo_revisions (
  id bigint generated always as identity primary key,
  item_id text not null references public.hq_ledger_items(item_id),
  source_listing_id text not null,
  source_listing_url text not null,
  photo_paths jsonb not null,
  captured_at timestamptz not null,
  capture_source text not null,
  superseded_at timestamptz not null default now()
);
alter table public.hq_purchase_source_photo_revisions enable row level security;
create policy "hq owner purchase photo revision read" on public.hq_purchase_source_photo_revisions
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_purchase_source_photo_revisions from public, anon;
grant select on public.hq_purchase_source_photo_revisions to authenticated;
