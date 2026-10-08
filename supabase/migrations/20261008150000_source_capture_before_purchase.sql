-- Preserve a viewed Vinted offer before purchase, without retaining a Vinted session.
create table public.hq_sourcing_source_captures (
  source_listing_id text primary key,
  source_listing_url text not null,
  listing_title text not null,
  seller_name text,
  photo_paths jsonb not null check (jsonb_typeof(photo_paths) = 'array' and jsonb_array_length(photo_paths) between 1 and 3),
  captured_at timestamptz not null default now(),
  capture_source text not null default 'HQ_SOURCE_LINK',
  source_event_id text,
  item_id text references public.hq_ledger_items(item_id),
  linked_at timestamptz
);
create index hq_sourcing_source_captures_recent on public.hq_sourcing_source_captures(captured_at desc)
  where source_event_id is null;
alter table public.hq_sourcing_source_captures enable row level security;
create policy "hq owner sourcing capture read" on public.hq_sourcing_source_captures
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_sourcing_source_captures from public, anon;
grant select on public.hq_sourcing_source_captures to authenticated;

alter table public.hq_purchase_photo_ingest_jobs add column seller_name text;

create or replace function public.match_hq_sourcing_photos(p_source_event_id text)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  job public.hq_purchase_photo_ingest_jobs%rowtype;
  candidate public.hq_sourcing_source_captures%rowtype;
  current_photo public.hq_purchase_source_photos%rowtype;
  wanted_title text;
  wanted_den text;
  match_count integer;
  competing_jobs integer;
  linked integer := 0;
  n integer;
begin
  select * into job from public.hq_purchase_photo_ingest_jobs
    where source_event_id = p_source_event_id for update;
  if not found then return 0; end if;
  n := jsonb_array_length(job.den_item_ids);
  if n < 1 then return 0; end if;
  for i in 0..n-1 loop
    wanted_den := job.den_item_ids->>i;
    wanted_title := case when jsonb_array_length(job.bundle_titles) = n then job.bundle_titles->>i else job.receipt_title end;
    if wanted_den !~ '^DEN-[0-9]+$' or nullif(wanted_title, '') is null then continue; end if;
    select count(*) into match_count from public.hq_sourcing_source_captures c
      where (c.source_event_id is null or c.source_event_id = p_source_event_id)
        and c.captured_at::date between job.occurred_on - 30 and job.occurred_on + 30
        and lower(regexp_replace(c.listing_title, '[^[:alnum:]]+', '', 'g')) = lower(regexp_replace(wanted_title, '[^[:alnum:]]+', '', 'g'))
        and (nullif(job.seller_name, '') is null or nullif(c.seller_name, '') is null or lower(c.seller_name) = lower(job.seller_name));
    if match_count <> 1 then continue; end if;
    select * into candidate from public.hq_sourcing_source_captures c
      where (c.source_event_id is null or c.source_event_id = p_source_event_id)
        and c.captured_at::date between job.occurred_on - 30 and job.occurred_on + 30
        and lower(regexp_replace(c.listing_title, '[^[:alnum:]]+', '', 'g')) = lower(regexp_replace(wanted_title, '[^[:alnum:]]+', '', 'g'))
        and (nullif(job.seller_name, '') is null or nullif(c.seller_name, '') is null or lower(c.seller_name) = lower(job.seller_name))
      for update;
    select count(*) into competing_jobs from public.hq_purchase_photo_ingest_jobs other
      where other.source_event_id <> p_source_event_id and other.state <> 'CAPTURED'
        and candidate.captured_at::date between other.occurred_on - 30 and other.occurred_on + 30
        and lower(regexp_replace(wanted_title, '[^[:alnum:]]+', '', 'g')) in (
          select lower(regexp_replace(value, '[^[:alnum:]]+', '', 'g'))
          from jsonb_array_elements_text(case when jsonb_array_length(other.bundle_titles) > 0 then other.bundle_titles else jsonb_build_array(other.receipt_title) end) as titles(value)
        )
        and (nullif(other.seller_name, '') is null or nullif(candidate.seller_name, '') is null or lower(other.seller_name) = lower(candidate.seller_name));
    if competing_jobs > 0 then continue; end if;
    if candidate.source_event_id is not null and candidate.item_id is distinct from wanted_den then continue; end if;
    select * into current_photo from public.hq_purchase_source_photos where item_id = wanted_den;
    if found and current_photo.source_listing_id <> candidate.source_listing_id then continue; end if;
    update public.hq_sourcing_source_captures set source_event_id = p_source_event_id,
      item_id = wanted_den, linked_at = coalesce(linked_at, now())
      where source_listing_id = candidate.source_listing_id
        and (source_event_id is null or source_event_id = p_source_event_id);
    if not found then continue; end if;
    insert into public.hq_purchase_source_photos(item_id,source_listing_id,source_listing_url,photo_paths,capture_source)
      values(wanted_den,candidate.source_listing_id,candidate.source_listing_url,candidate.photo_paths,'SOURCING_BEFORE_PURCHASE')
      on conflict (item_id) do nothing;
    insert into public.hq_purchase_photo_captures(source_event_id,source_listing_id,source_listing_url,listing_title,photo_paths,item_id)
      values(p_source_event_id,candidate.source_listing_id,candidate.source_listing_url,candidate.listing_title,candidate.photo_paths,wanted_den)
      on conflict (source_event_id,source_listing_id) do nothing;
    linked := linked + 1;
  end loop;
  if linked = n then
    update public.hq_purchase_photo_ingest_jobs set state = 'CAPTURED', last_error = null,
      updated_at = now() where source_event_id = p_source_event_id;
  end if;
  return linked;
end;
$$;
revoke all on function public.match_hq_sourcing_photos(text) from public, anon, authenticated;
grant execute on function public.match_hq_sourcing_photos(text) to service_role;
