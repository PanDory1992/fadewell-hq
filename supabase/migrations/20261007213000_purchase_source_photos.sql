-- Keep the bought listing's first three photos independent of the resale listing.
create table if not exists public.hq_purchase_source_photos (
  item_id text primary key references public.hq_ledger_items(item_id),
  source_listing_id text not null,
  source_listing_url text not null,
  photo_paths jsonb not null check (jsonb_typeof(photo_paths) = 'array' and jsonb_array_length(photo_paths) between 1 and 3),
  captured_at timestamptz not null default now(),
  capture_source text not null default 'OWNER_CONFIRMED_VINTED_URL'
);

alter table public.hq_purchase_source_photos enable row level security;
create policy "hq owner purchase photo read" on public.hq_purchase_source_photos
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_purchase_source_photos from public, anon;
grant select on public.hq_purchase_source_photos to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hq-purchase-photos', 'hq-purchase-photos', false, 5242880, array['image/webp','image/jpeg','image/png'])
on conflict (id) do nothing;

create policy "hq owner purchase image read" on storage.objects
  for select to authenticated
  using (bucket_id = 'hq-purchase-photos' and public.is_hq_owner());
