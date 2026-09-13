-- A deliberate owner decision may replace a still-observed Vinted listing ID
-- after a refresh/relist. Automatic resolution remains guarded by migration 037.

create or replace function public.apply_hq_manual_relink_owner(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  item text := nullif(payload->>'item_id', '');
  requested_vinted_id text := nullif(payload->>'vinted_item_id', '');
  previous_vinted_id text;
  event_date date := coalesce(nullif(payload->>'occurred_on', '')::date, current_date);
  action_amount numeric := nullif(payload->>'amount', '')::numeric;
  event_id bigint;
begin
  if auth.uid() is null or not public.is_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if item is null or item !~ '^DEN-[0-9]+$' or not exists (select 1 from public.hq_ledger_items where item_id = item) then
    raise exception 'Unknown canonical Item_ID';
  end if;
  if requested_vinted_id is null then
    raise exception 'Manual relink requires a Vinted listing ID';
  end if;
  if nullif(payload->>'external_key', '') is null then
    raise exception 'Manual relink requires an external key';
  end if;
  if exists (select 1 from public.hq_ledger_events where external_key = payload->>'external_key') then
    return (select id from public.hq_ledger_events where external_key = payload->>'external_key');
  end if;

  select vinted_item_id into previous_vinted_id
  from public.hq_ledger_items
  where item_id = item
    and ledger_status <> 'SOLD'
  for update;

  if previous_vinted_id is null or previous_vinted_id = requested_vinted_id then
    raise exception 'Manual relink requires a different active listing ID';
  end if;
  if exists (
    select 1
    from public.hq_ledger_items
    where item_id <> item
      and vinted_item_id = requested_vinted_id
      and ledger_status <> 'SOLD'
  ) then
    raise exception 'Vinted listing ID is already linked to another active DEN';
  end if;

  update public.hq_ledger_items
  set vinted_item_id = requested_vinted_id,
      listing_url = coalesce(nullif(payload->>'listing_url', ''), listing_url),
      live_title = coalesce(nullif(payload->>'live_title', ''), live_title),
      live_list_price = coalesce(action_amount, live_list_price),
      version = version + 1
  where item_id = item;

  insert into public.hq_ledger_events(item_id, event_type, occurred_on, amount, detail, source, external_key)
  values (
    item,
    'LISTED',
    event_date,
    action_amount,
    format('Operations: ręcznie potwierdzone odświeżenie oferty %s → %s. %s', previous_vinted_id, requested_vinted_id, coalesce(nullif(payload->>'note', ''), '')),
    'MANUAL',
    payload->>'external_key'
  )
  returning id into event_id;

  return event_id;
end;
$$;

revoke all on function public.apply_hq_manual_relink_owner(jsonb) from public, anon;
grant execute on function public.apply_hq_manual_relink_owner(jsonb) to authenticated;
