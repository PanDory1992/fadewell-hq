-- Persist a high-confidence relist candidate before it is safe to promote.
-- The canonical DEN/listing ID stays unchanged until SYSTEM verifies two
-- complete snapshots or the owner explicitly confirms the candidate.

create table if not exists public.hq_vinted_relist_candidates (
  id bigint generated always as identity primary key,
  item_id text not null,
  old_vinted_item_id text not null,
  new_vinted_item_id text not null,
  state text not null default 'PENDING'
    check (state in ('PENDING', 'CONFIRMED', 'DISMISSED')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz,
  latest_snapshot_at timestamptz,
  last_reason text,
  new_snapshot_count integer not null default 0,
  old_snapshot_count integer not null default 0,
  verified_snapshot_times timestamptz[] not null default '{}',
  new_title text,
  new_price_pln numeric,
  new_photo_url text,
  evidence jsonb not null default '{}'::jsonb,
  resolved_at timestamptz,
  resolved_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (item_id, old_vinted_item_id, new_vinted_item_id)
);

create index if not exists hq_vinted_relist_candidates_pending_index
  on public.hq_vinted_relist_candidates (state, updated_at desc);
create index if not exists hq_vinted_relist_candidates_item_index
  on public.hq_vinted_relist_candidates (item_id, state);

alter table public.hq_vinted_relist_candidates enable row level security;
drop policy if exists "hq owner relist candidate access" on public.hq_vinted_relist_candidates;
create policy "hq owner relist candidate access"
  on public.hq_vinted_relist_candidates
  for select to authenticated
  using (public.is_hq_owner());
grant select on public.hq_vinted_relist_candidates to authenticated;

create or replace function public.record_hq_relist_candidate(
  p jsonb,
  p_reason text,
  p_new_snapshot_count integer,
  p_old_snapshot_count integer,
  p_verified_snapshot_times timestamptz[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  item text := nullif(payload->>'item_id', '');
  old_id text := nullif(payload->>'old_vinted_item_id', '');
  new_id text := coalesce(nullif(payload->>'new_vinted_item_id', ''), nullif(payload->>'vinted_item_id', ''));
  latest_title text;
  latest_price numeric;
  latest_photo text;
  latest_captured_at timestamptz;
  candidate_evidence jsonb;
begin
  if item is null or old_id is null or new_id is null then
    raise exception 'Relist candidate requires one DEN and old/new listing IDs';
  end if;

  select title, price_pln, photo_url, captured_at
  into latest_title, latest_price, latest_photo, latest_captured_at
  from public.hq_listing_snapshots
  where vinted_item_id = new_id
    and visible is distinct from false
  order by captured_at desc, id desc
  limit 1;

  candidate_evidence := coalesce(payload->'evidence', '{}'::jsonb) || jsonb_build_object(
    'pending_reason', p_reason,
    'new_snapshot_count', coalesce(p_new_snapshot_count, 0),
    'old_snapshot_count', coalesce(p_old_snapshot_count, 0),
    'verified_snapshot_times', coalesce(to_jsonb(p_verified_snapshot_times), '[]'::jsonb)
  );

  insert into public.hq_vinted_relist_candidates(
    item_id, old_vinted_item_id, new_vinted_item_id, state,
    first_seen_at, last_seen_at, latest_snapshot_at, last_reason,
    new_snapshot_count, old_snapshot_count, verified_snapshot_times,
    new_title, new_price_pln, new_photo_url, evidence, updated_at
  )
  values (
    item, old_id, new_id, 'PENDING', now(), now(), latest_captured_at,
    p_reason, coalesce(p_new_snapshot_count, 0), coalesce(p_old_snapshot_count, 0),
    coalesce(p_verified_snapshot_times, '{}'), latest_title,
    latest_price, latest_photo, candidate_evidence, now()
  )
  on conflict (item_id, old_vinted_item_id, new_vinted_item_id) do update
  set state = 'PENDING',
      last_seen_at = now(),
      latest_snapshot_at = coalesce(excluded.latest_snapshot_at, public.hq_vinted_relist_candidates.latest_snapshot_at),
      last_reason = excluded.last_reason,
      new_snapshot_count = excluded.new_snapshot_count,
      old_snapshot_count = excluded.old_snapshot_count,
      verified_snapshot_times = excluded.verified_snapshot_times,
      new_title = coalesce(excluded.new_title, public.hq_vinted_relist_candidates.new_title),
      new_price_pln = coalesce(excluded.new_price_pln, public.hq_vinted_relist_candidates.new_price_pln),
      new_photo_url = coalesce(excluded.new_photo_url, public.hq_vinted_relist_candidates.new_photo_url),
      evidence = public.hq_vinted_relist_candidates.evidence || excluded.evidence,
      resolved_at = null,
      resolved_by = null,
      updated_at = now();
end;
$$;

revoke all on function public.record_hq_relist_candidate(jsonb, text, integer, integer, timestamptz[]) from public, anon, authenticated, service_role;

create or replace function public.apply_hq_relist_transition(p jsonb, p_actor text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  item text := nullif(payload->>'item_id', '');
  expected_old_id text := nullif(payload->>'old_vinted_item_id', '');
  new_id text := coalesce(nullif(payload->>'new_vinted_item_id', ''), nullif(payload->>'vinted_item_id', ''));
  event_key text := nullif(payload->>'external_key', '');
  event_date date := coalesce(nullif(payload->>'occurred_on', '')::date, current_date);
  current_id text;
  conflicting_item text;
  cycle_times timestamptz[];
  new_cycle_count integer := 0;
  current_new_count integer := 0;
  old_cycle_count integer := 0;
  current_snapshot record;
  event_id bigint;
  actor text := upper(coalesce(p_actor, ''));
  actor_evidence jsonb;
begin
  if actor not in ('SYSTEM', 'MANUAL') then
    raise exception 'Relist actor must be SYSTEM or MANUAL';
  end if;
  if item is null or expected_old_id is null or new_id is null or expected_old_id = new_id then
    raise exception 'Relist requires one DEN, its current old listing ID, and one different new listing ID';
  end if;
  if event_key is null then
    raise exception 'Relist requires an idempotency key';
  end if;
  if exists (select 1 from public.hq_ledger_events where external_key = event_key) then
    return jsonb_build_object(
      'duplicate', true,
      'event_id', (select id from public.hq_ledger_events where external_key = event_key),
      'item_id', item,
      'vinted_item_id', new_id
    );
  end if;

  select vinted_item_id
  into current_id
  from public.hq_ledger_items
  where item_id = item
    and ledger_status = 'LISTED-BACKLOG'
  for update;

  if current_id is distinct from expected_old_id then
    raise exception 'DEN no longer points to the expected old listing';
  end if;

  select array_agg(captured_at order by captured_at desc)
  into cycle_times
  from (
    select distinct captured_at
    from public.hq_listing_snapshots
    where source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by captured_at desc
    limit 2
  ) cycles;

  if coalesce(cardinality(cycle_times), 0) < 1 then
    perform public.record_hq_relist_candidate(payload, 'waiting_for_first_complete_snapshot', 0, 0, cycle_times);
    return jsonb_build_object('deferred', true, 'reason', 'waiting_for_first_complete_snapshot');
  end if;

  select count(distinct captured_at)
  into new_cycle_count
  from public.hq_listing_snapshots
  where captured_at = any(cycle_times)
    and vinted_item_id = new_id
    and visible is distinct from false;

  select count(*)
  into current_new_count
  from public.hq_listing_snapshots
  where captured_at = cycle_times[1]
    and vinted_item_id = new_id
    and visible is distinct from false;

  select count(distinct captured_at)
  into old_cycle_count
  from public.hq_listing_snapshots
  where captured_at = any(cycle_times)
    and vinted_item_id = expected_old_id
    and visible is distinct from false;

  if actor = 'SYSTEM' and new_cycle_count < 2 then
    perform public.record_hq_relist_candidate(payload, 'replacement_not_stable_in_two_complete_snapshots', new_cycle_count, old_cycle_count, cycle_times);
    return jsonb_build_object('deferred', true, 'reason', 'replacement_not_stable_in_two_complete_snapshots');
  end if;
  if actor = 'SYSTEM' and old_cycle_count > 0 then
    perform public.record_hq_relist_candidate(payload, 'previous_listing_still_live', new_cycle_count, old_cycle_count, cycle_times);
    return jsonb_build_object('deferred', true, 'reason', 'previous_listing_still_live');
  end if;
  if actor = 'MANUAL' and current_new_count < 1 then
    perform public.record_hq_relist_candidate(payload, 'replacement_not_in_latest_complete_snapshot', new_cycle_count, old_cycle_count, cycle_times);
    return jsonb_build_object('deferred', true, 'reason', 'replacement_not_in_latest_complete_snapshot');
  end if;

  select title, price_pln, photo_url, captured_at, source
  into current_snapshot
  from public.hq_listing_snapshots
  where vinted_item_id = new_id
    and captured_at = cycle_times[1]
    and visible is distinct from false
  order by id desc
  limit 1;

  select owner.item_id
  into conflicting_item
  from (
    select item_id
    from public.hq_ledger_items
    where vinted_item_id = new_id
      and item_id <> item
      and ledger_status <> 'SOLD'
    union
    select item_id
    from public.hq_vinted_listing_lineage
    where vinted_item_id = new_id
      and item_id <> item
  ) owner
  limit 1;

  if conflicting_item is not null then
    raise exception 'Relist conflict: replacement listing belongs to %', conflicting_item;
  end if;

  actor_evidence := coalesce(payload->'evidence', '{}'::jsonb) || jsonb_build_object(
    'actor', actor,
    'verified_snapshot_times', to_jsonb(cycle_times),
    'snapshot_source', current_snapshot.source,
    'snapshot_captured_at', current_snapshot.captured_at,
    'new_snapshot_count', new_cycle_count,
    'old_snapshot_count', old_cycle_count
  );

  update public.hq_ledger_items
  set listed = true,
      ledger_status = 'LISTED-BACKLOG',
      vinted_item_id = new_id,
      listing_url = 'https://www.vinted.pl/items/' || new_id,
      live_title = coalesce(current_snapshot.title, live_title),
      live_list_price = coalesce(current_snapshot.price_pln, live_list_price),
      last_live_check_on = current_snapshot.captured_at::date,
      last_photo_url = coalesce(current_snapshot.photo_url, last_photo_url),
      version = version + 1
  where item_id = item;

  insert into public.hq_vinted_listing_lineage(
    vinted_item_id, item_id, state, last_seen_at,
    replaced_by_vinted_item_id, evidence, resolved_at, resolved_by
  )
  values (
    expected_old_id, item, 'REPLACED', now(),
    new_id, actor_evidence, now(), actor
  )
  on conflict (vinted_item_id) do update
  set item_id = excluded.item_id,
      state = 'REPLACED',
      last_seen_at = excluded.last_seen_at,
      replaced_by_vinted_item_id = excluded.replaced_by_vinted_item_id,
      evidence = public.hq_vinted_listing_lineage.evidence || excluded.evidence,
      resolved_at = excluded.resolved_at,
      resolved_by = excluded.resolved_by;

  insert into public.hq_vinted_listing_lineage(
    vinted_item_id, item_id, state, last_seen_at,
    replaced_by_vinted_item_id, evidence, resolved_at, resolved_by
  )
  values (
    new_id, item, 'ACTIVE', current_snapshot.captured_at,
    null, actor_evidence, now(), actor
  )
  on conflict (vinted_item_id) do update
  set item_id = excluded.item_id,
      state = 'ACTIVE',
      last_seen_at = excluded.last_seen_at,
      replaced_by_vinted_item_id = null,
      evidence = public.hq_vinted_listing_lineage.evidence || excluded.evidence,
      resolved_at = excluded.resolved_at,
      resolved_by = excluded.resolved_by;

  insert into public.hq_vinted_relist_candidates(
    item_id, old_vinted_item_id, new_vinted_item_id, state,
    first_seen_at, last_seen_at, latest_snapshot_at, last_reason,
    new_snapshot_count, old_snapshot_count, verified_snapshot_times,
    new_title, new_price_pln, new_photo_url, evidence, resolved_at, resolved_by, updated_at
  )
  values (
    item, expected_old_id, new_id, 'CONFIRMED', now(), now(), current_snapshot.captured_at,
    'confirmed', new_cycle_count, old_cycle_count, coalesce(cycle_times, '{}'),
    current_snapshot.title, current_snapshot.price_pln, current_snapshot.photo_url,
    actor_evidence, now(), actor, now()
  )
  on conflict (item_id, old_vinted_item_id, new_vinted_item_id) do update
  set state = 'CONFIRMED',
      last_seen_at = now(),
      latest_snapshot_at = excluded.latest_snapshot_at,
      last_reason = 'confirmed',
      new_snapshot_count = excluded.new_snapshot_count,
      old_snapshot_count = excluded.old_snapshot_count,
      verified_snapshot_times = excluded.verified_snapshot_times,
      new_title = coalesce(excluded.new_title, public.hq_vinted_relist_candidates.new_title),
      new_price_pln = coalesce(excluded.new_price_pln, public.hq_vinted_relist_candidates.new_price_pln),
      new_photo_url = coalesce(excluded.new_photo_url, public.hq_vinted_relist_candidates.new_photo_url),
      evidence = public.hq_vinted_relist_candidates.evidence || excluded.evidence,
      resolved_at = excluded.resolved_at,
      resolved_by = excluded.resolved_by,
      updated_at = now();

  insert into public.hq_ledger_events(
    item_id, event_type, occurred_on, amount, detail, source, external_key
  )
  values (
    item,
    'LISTED',
    event_date,
    current_snapshot.price_pln,
    case
      when actor = 'SYSTEM'
        then format('System: verified relist %s to %s; two-snapshot evidence retained in listing lineage.', expected_old_id, new_id)
      else format(U&'Operations: potwierdzony relist %s \2192 %s; dowody relistu zapisano w historii.', expected_old_id, new_id)
    end,
    actor,
    event_key
  )
  returning id into event_id;

  return jsonb_build_object(
    'ok', true,
    'event_id', event_id,
    'item_id', item,
    'old_vinted_item_id', expected_old_id,
    'vinted_item_id', new_id,
    'actor', actor
  );
end;
$$;

revoke all on function public.apply_hq_relist_transition(jsonb, text) from public, anon, authenticated, service_role;

create or replace function public.apply_hq_system_relist(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.apply_hq_relist_transition(p, 'SYSTEM');
end;
$$;

revoke all on function public.apply_hq_system_relist(jsonb) from public, anon, authenticated;
grant execute on function public.apply_hq_system_relist(jsonb) to service_role;

create or replace function public.apply_hq_manual_relink_owner(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  item text := nullif(payload->>'item_id', '');
  result jsonb;
begin
  if auth.uid() is null or not public.is_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if item is null or item !~ '^DEN-[0-9]+$' then
    raise exception 'Unknown canonical Item_ID';
  end if;
  if nullif(payload->>'old_vinted_item_id', '') is null then
    raise exception 'Manual relist requires the expected old Vinted listing ID';
  end if;

  result := public.apply_hq_relist_transition(
    payload || jsonb_build_object('evidence', coalesce(payload->'evidence', '{}'::jsonb) || jsonb_build_object('owner_confirmation', true)),
    'MANUAL'
  );
  if coalesce((result->>'deferred')::boolean, false) then
    raise exception 'Relist is not ready: %', result->>'reason';
  end if;
  return (result->>'event_id')::bigint;
end;
$$;

revoke all on function public.apply_hq_manual_relink_owner(jsonb) from public, anon;
grant execute on function public.apply_hq_manual_relink_owner(jsonb) to authenticated;
