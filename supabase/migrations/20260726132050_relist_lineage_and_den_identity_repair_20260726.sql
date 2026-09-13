-- Relist lineage: a Vinted listing is an observation, not the identity of a DEN.
-- The current listing stays on hq_ledger_items; every prior/replacement listing
-- is retained here so that a relist never looks like a sale or a duplicate DEN.

create table if not exists public.hq_vinted_listing_lineage (
  vinted_item_id text primary key,
  item_id text not null references public.hq_ledger_items(item_id),
  state text not null check (state in ('ACTIVE','REPLACED','HISTORICAL')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz,
  replaced_by_vinted_item_id text,
  evidence jsonb not null default '{}'::jsonb,
  resolved_at timestamptz,
  resolved_by text not null default 'SYSTEM'
);
create index if not exists hq_vinted_listing_lineage_item_index
  on public.hq_vinted_listing_lineage(item_id, state);
alter table public.hq_vinted_listing_lineage enable row level security;
drop policy if exists "hq owner listing lineage access" on public.hq_vinted_listing_lineage;
create policy "hq owner listing lineage access" on public.hq_vinted_listing_lineage
  for all to authenticated using (public.is_hq_owner()) with check (public.is_hq_owner());

-- One atomic, service-only operation for a resolver-confirmed relist. It will
-- never take a live listing from another DEN and requires the old ID to be
-- absent from this collector's complete snapshot.
create or replace function public.apply_hq_system_relist(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item text := nullif(p->>'item_id', '');
  old_id text := nullif(p->>'old_vinted_item_id', '');
  new_id text := nullif(p->>'new_vinted_item_id', '');
  observed_ids jsonb := coalesce(p->'observed_listing_ids', '[]'::jsonb);
  event_key text := nullif(p->>'external_key', '');
  event_date date := coalesce(nullif(p->>'occurred_on', '')::date, current_date);
  listed_price numeric := nullif(p->>'amount', '')::numeric;
  current_id text;
  owner_of_new text;
  event_id bigint;
begin
  if item is null or old_id is null or new_id is null or old_id = new_id then
    raise exception 'Relist requires one DEN, one missing old listing and one new listing';
  end if;
  if event_key is null then raise exception 'Relist requires an idempotency key'; end if;
  if exists(select 1 from public.hq_ledger_events where external_key = event_key) then
    return jsonb_build_object('duplicate', true, 'item_id', item, 'vinted_item_id', new_id);
  end if;
  if not exists(select 1 from jsonb_array_elements_text(observed_ids) value where value = new_id) then
    raise exception 'New relist listing is not in the current complete snapshot';
  end if;
  if exists(select 1 from jsonb_array_elements_text(observed_ids) value where value = old_id) then
    raise exception 'Old listing is still in the current complete snapshot';
  end if;

  select vinted_item_id into current_id
  from public.hq_ledger_items where item_id = item and ledger_status = 'LISTED-BACKLOG' for update;
  if current_id is distinct from old_id then
    raise exception 'DEN no longer points to the expected missing listing';
  end if;
  select item_id into owner_of_new from public.hq_ledger_items
  where vinted_item_id = new_id and item_id <> item and ledger_status <> 'SOLD' for update;
  if owner_of_new is not null then
    raise exception 'Relist conflict: new listing is already linked to %', owner_of_new;
  end if;

  update public.hq_ledger_items
  set vinted_item_id = new_id,
      listing_url = coalesce(nullif(p->>'listing_url', ''), listing_url),
      live_title = coalesce(nullif(p->>'live_title', ''), live_title),
      live_list_price = coalesce(listed_price, live_list_price),
      version = version + 1
  where item_id = item;

  insert into public.hq_vinted_listing_lineage(vinted_item_id, item_id, state, last_seen_at, replaced_by_vinted_item_id, evidence, resolved_at)
  values (old_id, item, 'REPLACED', now(), new_id, coalesce(p->'evidence', '{}'::jsonb), now())
  on conflict (vinted_item_id) do update set item_id = excluded.item_id, state = 'REPLACED', last_seen_at = excluded.last_seen_at, replaced_by_vinted_item_id = excluded.replaced_by_vinted_item_id, evidence = excluded.evidence, resolved_at = excluded.resolved_at;
  insert into public.hq_vinted_listing_lineage(vinted_item_id, item_id, state, last_seen_at, evidence, resolved_at)
  values (new_id, item, 'ACTIVE', now(), coalesce(p->'evidence', '{}'::jsonb), now())
  on conflict (vinted_item_id) do update set item_id = excluded.item_id, state = 'ACTIVE', last_seen_at = excluded.last_seen_at, evidence = excluded.evidence, resolved_at = excluded.resolved_at;

  insert into public.hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
  values (item,'LISTED',event_date,listed_price,format('System: verified relist %s to %s; evidence retained in listing lineage.', old_id, new_id),'SYSTEM',event_key)
  returning id into event_id;
  return jsonb_build_object('ok', true, 'event_id', event_id, 'item_id', item, 'vinted_item_id', new_id);
end;
$$;
revoke all on function public.apply_hq_system_relist(jsonb) from public, anon, authenticated;
grant execute on function public.apply_hq_system_relist(jsonb) to service_role;

-- User-confirmed identity repair (2026-07-26). This intentionally preserves
-- audit events and old listing lineage instead of deleting or rewriting history.
do $$
begin
  if exists (select 1 from public.hq_ledger_items where item_id = 'DEN-141')
     and exists (select 1 from public.hq_ledger_items where item_id = 'DEN-138') then
    update public.hq_ledger_items
    set name = 'Wrangler Authentics Straight Jeans – Deep Blue – W38 L32 – Comfort Flex',
        purchase_cost = 36.70,
        delivery_cost = 0,
        total_capital = 36.70,
        listed = false,
        ledger_status = 'UNLISTED-BACKLOG',
        vinted_item_id = null,
        listing_url = null,
        live_title = null,
        live_list_price = null,
        listed_on = null,
        version = version + 1
    where item_id = 'DEN-138';

    update public.hq_ledger_items
    set vinted_item_id = '9494323317',
        listing_url = 'https://www.vinted.pl/items/9494323317',
        live_title = 'Levi’s 512 Slim Tapered Jeans – Optic White – W26 L26 US 7MED – Vintage 1996 Made in USA',
        live_list_price = 199.00,
        listed = true,
        ledger_status = 'LISTED-BACKLOG',
        version = version + 1
    where item_id = 'DEN-141';

    insert into public.hq_vinted_listing_lineage(vinted_item_id,item_id,state,last_seen_at,replaced_by_vinted_item_id,evidence,resolved_at,resolved_by)
    values
      ('9279738596','DEN-141','REPLACED',now(),'9494323317',jsonb_build_object('kind','user_confirmed_identity_repair','reason','obsolete deleted Levi listing'),now(),'MANUAL'),
      ('9494323317','DEN-141','ACTIVE',now(),null,jsonb_build_object('kind','user_confirmed_identity_repair','reason','correct active Levi listing'),now(),'MANUAL'),
      ('8761980027','DEN-138','HISTORICAL',now(),null,jsonb_build_object('kind','user_confirmed_identity_repair','reason','prior Wrangler listing outside current collector scope'),now(),'MANUAL')
    on conflict (vinted_item_id) do update set item_id=excluded.item_id,state=excluded.state,last_seen_at=excluded.last_seen_at,replaced_by_vinted_item_id=excluded.replaced_by_vinted_item_id,evidence=excluded.evidence,resolved_at=excluded.resolved_at,resolved_by=excluded.resolved_by;

    insert into public.hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
    values
      ('DEN-141','LISTED',current_date,199.00,'User-confirmed identity repair: current Levi relist 9494323317 restored to DEN-141; prior listing 9279738596 retained as replaced lineage.','MANUAL','identity-repair-20260726-den141-9494323317'),
      ('DEN-138','ADJUSTMENT',current_date,null,'User-confirmed identity repair: DEN-138 now represents Wrangler Authentics Straight Jeans Deep Blue W38 L32 Comfort Flex. Full capital set to 36.70 PLN; prior excluded listing 8761980027 retained as historical lineage.','MANUAL','identity-repair-20260726-den138-wrangler')
    on conflict (external_key) do nothing;
  end if;
end $$;

drop trigger if exists hq_browser_sync_listing_lineage on public.hq_vinted_listing_lineage;
create trigger hq_browser_sync_listing_lineage after insert or update or delete on public.hq_vinted_listing_lineage
for each row execute function public.hq_record_browser_sync_change();
