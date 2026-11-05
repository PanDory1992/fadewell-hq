-- Owner-confirmed personal Vinted listings live in HQ, outside the DEN ledger.
-- Keep historical collector snapshots as evidence; remove REC from live DEN reads.
create table public.hq_rec_vinted_items (
  vinted_item_id text primary key check (vinted_item_id ~ '^[0-9]{6,20}$'),
  rec_id text generated always as ('REC-V-' || vinted_item_id) stored unique,
  title text not null,
  price_pln numeric(12,2),
  photo_url text,
  snapshot_at timestamptz not null,
  decided_at timestamptz not null default now(),
  decided_by uuid not null,
  source text not null default 'OPERATIONS_OWNER',
  note text
);

alter table public.hq_rec_vinted_items enable row level security;
create policy "hq owner reads REC listings" on public.hq_rec_vinted_items
  for select to authenticated using (public.is_hq_owner());
revoke all on public.hq_rec_vinted_items from public, anon, authenticated;
grant select on public.hq_rec_vinted_items to authenticated;

create or replace function public.classify_hq_vinted_listing_rec_owner(p_vinted_item_id text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare
  observed public.hq_listing_snapshots%rowtype;
  latest_cycle timestamptz;
  result text;
begin
  if not public.is_hq_owner() then raise exception 'HQ owner access required'; end if;
  if p_vinted_item_id is null or p_vinted_item_id !~ '^[0-9]{6,20}$' then
    raise exception 'Valid Vinted listing ID required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('hq-rec-vinted:' || p_vinted_item_id, 0));
  select rec_id into result from public.hq_rec_vinted_items
    where vinted_item_id = p_vinted_item_id;
  if found then return result; end if;
  if exists (select 1 from public.hq_ledger_items where vinted_item_id = p_vinted_item_id)
     or exists (select 1 from public.hq_vinted_listing_lineage where vinted_item_id = p_vinted_item_id) then
    raise exception 'Listing is already associated with a DEN item';
  end if;
  if exists (select 1 from public.hq_vinted_relist_candidates
             where new_vinted_item_id = p_vinted_item_id and state = 'PENDING') then
    raise exception 'Listing has a pending DEN relist decision';
  end if;
  select max(captured_at) into latest_cycle from public.hq_listing_snapshots
    where source in ('github_actions_vinted', 'supabase_edge_vinted');
  select * into observed from public.hq_listing_snapshots
    where vinted_item_id = p_vinted_item_id and captured_at = latest_cycle
      and source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by id desc limit 1;
  if not found then raise exception 'Listing is not in the latest complete Vinted snapshot'; end if;
  insert into public.hq_rec_vinted_items
    (vinted_item_id, title, price_pln, photo_url, snapshot_at, decided_by)
  values
    (p_vinted_item_id, coalesce(nullif(observed.title, ''), 'Vinted ' || p_vinted_item_id),
     observed.price_pln, observed.photo_url, observed.captured_at, auth.uid())
  returning rec_id into result;
  update public.fadewell_storefront_products
    set published = false, available = false,
        publication_notes = coalesce(publication_notes, '{}'::jsonb)
          || jsonb_build_object('publication_status', 'OUT_OF_SCOPE_DEN',
                                'scope', 'REC', 'owner_decision_at', now()),
        updated_at = now()
    where vinted_item_id = p_vinted_item_id;
  update public.hq_review_queue set state = 'HIDDEN'
    where vinted_item_id = p_vinted_item_id and state = 'OPEN';
  insert into public.hq_browser_sync_changes(entity, entity_key, operation)
    values ('hq_listing_snapshots', p_vinted_item_id, 'UPDATE');
  return result;
end $$;

revoke all on function public.classify_hq_vinted_listing_rec_owner(text)
  from public, anon, authenticated;
grant execute on function public.classify_hq_vinted_listing_rec_owner(text)
  to authenticated;

create or replace function public.guard_hq_rec_vinted_den_link()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and new.vinted_item_id is not distinct from old.vinted_item_id then
    return new;
  end if;
  if new.vinted_item_id is not null and exists
     (select 1 from public.hq_rec_vinted_items
      where vinted_item_id = new.vinted_item_id) then
    raise exception 'REC Vinted listing cannot be attached to DEN';
  end if;
  return new;
end $$;
create trigger hq_guard_rec_vinted_den_link
  before insert or update of vinted_item_id on public.hq_ledger_items
  for each row execute function public.guard_hq_rec_vinted_den_link();

create or replace function public.hq_browser_listing_cycles()
returns jsonb language sql stable security definer set search_path = public as $$
  with cloud_cycles as (
    select distinct captured_at from public.hq_listing_snapshots
    where source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by captured_at desc limit 2
  ), fallback_cycles as (
    select distinct captured_at from public.hq_listing_snapshots
    where not exists (select 1 from cloud_cycles)
    order by captured_at desc limit 2
  ), cycles as (
    select captured_at from cloud_cycles union all select captured_at from fallback_cycles
  ), rows as (
    select snapshot.* from public.hq_listing_snapshots snapshot
    where snapshot.captured_at in (select captured_at from cycles)
      and (not exists (select 1 from cloud_cycles)
           or snapshot.source in ('github_actions_vinted', 'supabase_edge_vinted'))
      and not exists (select 1 from public.hq_rec_vinted_items rec
                      where rec.vinted_item_id = snapshot.vinted_item_id)
    order by snapshot.captured_at desc, snapshot.id desc
  )
  select case when public.is_hq_owner()
    then jsonb_build_object('snapshots', coalesce((select jsonb_agg(to_jsonb(rows)) from rows), '[]'::jsonb))
    else null end;
$$;
revoke all on function public.hq_browser_listing_cycles() from public, anon;
grant execute on function public.hq_browser_listing_cycles() to authenticated;
