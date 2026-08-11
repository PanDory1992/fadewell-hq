-- A proposed Vinted price is an operational decision, not an observed listing fact.
-- Preserve the old ledger events, but route every new proposal to the append-only
-- operational action log. The collector remains the only writer of observed price.

create index if not exists hq_operational_actions_entity_created_index
  on public.hq_operational_actions(entity_type, entity_key, created_at desc);

create unique index if not exists hq_operational_actions_external_key_unique
  on public.hq_operational_actions ((payload->>'external_key'))
  where payload ? 'external_key' and coalesce(payload->>'external_key', '') <> '';

drop policy if exists "hq owner operational action read" on public.hq_operational_actions;
create policy "hq owner operational action read"
on public.hq_operational_actions
for select to authenticated
using (public.is_hq_owner());

revoke all on table public.hq_operational_actions from public;
grant select on table public.hq_operational_actions to authenticated;

create or replace function public.record_hq_price_test_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item text := nullif(p->>'item_id', '');
  amount numeric := nullif(p->>'price', '')::numeric;
  external_key text := nullif(p->>'external_key', '');
  observed_price numeric;
  observed_at timestamptz;
  listing_id text;
  listing_url text;
  action_id bigint;
  action_payload jsonb;
begin
  if not public.claim_first_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if item is null or amount is null or amount <= 0 or external_key is null then
    raise exception 'Listed DEN, positive proposed price and external key required';
  end if;

  select a.id, a.payload
    into action_id, action_payload
  from public.hq_operational_actions a
  where a.payload->>'external_key' = external_key
  limit 1;
  if found then
    return action_payload || jsonb_build_object('action_id', action_id, 'idempotent', true);
  end if;

  select coalesce(s.price_pln, i.live_list_price), s.captured_at,
         i.vinted_item_id, i.listing_url
    into observed_price, observed_at, listing_id, listing_url
  from public.hq_ledger_items i
  left join lateral (
    select snap.price_pln, snap.captured_at
    from public.hq_listing_snapshots snap
    where snap.vinted_item_id = i.vinted_item_id
      and snap.source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by snap.captured_at desc
    limit 1
  ) s on true
  where i.item_id = item and i.ledger_status = 'LISTED-BACKLOG'
  for update of i;
  if not found then
    raise exception 'Only an active listed DEN may receive a price proposal';
  end if;
  if observed_price is not null and amount = observed_price then
    raise exception 'Proposed price already matches the latest Vinted observation';
  end if;

  action_payload := jsonb_build_object(
    'schema_version', 1,
    'external_key', external_key,
    'item_id', item,
    'vinted_item_id', listing_id,
    'listing_url', listing_url,
    'observed_price', observed_price,
    'observed_at', observed_at,
    'proposed_price', amount,
    'state', 'WAITING_EXECUTION',
    'source', 'PRICING_COCKPIT'
  );

  insert into public.hq_operational_actions(
    entity_type, entity_key, action_type, payload, created_by
  ) values (
    'ITEM', item, 'PRICE_CHANGE_APPROVED', action_payload, auth.uid()
  ) returning id into action_id;

  return action_payload || jsonb_build_object('action_id', action_id, 'idempotent', false);
end $$;

revoke all on function public.record_hq_price_test_owner(jsonb) from public;
grant execute on function public.record_hq_price_test_owner(jsonb) to authenticated;
