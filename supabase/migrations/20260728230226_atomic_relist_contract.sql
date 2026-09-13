-- One relist contract for both automation and an owner-confirmed fallback.
-- A transition is allowed only when the replacement is visible in the two
-- latest complete snapshots, the previous listing is absent from both, and
-- neither the current ledger nor historical lineage belongs to another DEN.

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

  select array_agg(captured_at order by captured_at desc)
  into cycle_times
  from (
    select distinct captured_at
    from public.hq_listing_snapshots
    where source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by captured_at desc
    limit 2
  ) cycles;

  if coalesce(cardinality(cycle_times), 0) < 2 then
    return jsonb_build_object('deferred', true, 'reason', 'waiting_for_two_complete_snapshots');
  end if;

  select count(distinct captured_at)
  into new_cycle_count
  from public.hq_listing_snapshots
  where captured_at = any(cycle_times)
    and vinted_item_id = new_id
    and visible is distinct from false;

  select count(distinct captured_at)
  into old_cycle_count
  from public.hq_listing_snapshots
  where captured_at = any(cycle_times)
    and vinted_item_id = expected_old_id
    and visible is distinct from false;

  if new_cycle_count < 2 then
    return jsonb_build_object('deferred', true, 'reason', 'replacement_not_stable_in_two_complete_snapshots');
  end if;
  if old_cycle_count > 0 then
    return jsonb_build_object('deferred', true, 'reason', 'previous_listing_still_live');
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

  select title, price_pln, photo_url, captured_at, source
  into current_snapshot
  from public.hq_listing_snapshots
  where vinted_item_id = new_id
    and captured_at = cycle_times[1]
    and visible is distinct from false
  order by id desc
  limit 1;

  actor_evidence := coalesce(payload->'evidence', '{}'::jsonb) || jsonb_build_object(
    'actor', actor,
    'verified_snapshot_times', to_jsonb(cycle_times),
    'snapshot_source', current_snapshot.source,
    'snapshot_captured_at', current_snapshot.captured_at
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
      else format(U&'Operations: potwierdzony relist %s \2192 %s; dowody z dw\00F3ch snapshot\00F3w zapisano w historii.', expected_old_id, new_id)
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
    'vinted_item_id', new_id
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

  result := public.apply_hq_relist_transition(payload, 'MANUAL');
  if coalesce((result->>'deferred')::boolean, false) then
    raise exception 'Relist is not ready: %', result->>'reason';
  end if;
  return (result->>'event_id')::bigint;
end;
$$;

revoke all on function public.apply_hq_manual_relink_owner(jsonb) from public, anon;
grant execute on function public.apply_hq_manual_relink_owner(jsonb) to authenticated;
