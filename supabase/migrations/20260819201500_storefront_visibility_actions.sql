-- An owner may temporarily remove an active Vinted listing from the public
-- FADEWELL storefront without changing its DEN, Vinted listing or ledger state.

begin;

alter table public.hq_ledger_items
  add column if not exists storefront_hidden boolean not null default false;

comment on column public.hq_ledger_items.storefront_hidden is
  'Owner-controlled exclusion from the public FADEWELL storefront; does not alter Vinted or DEN listing state.';

create or replace function public.is_fadewell_storefront_visible(p_vinted_item_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select not item.storefront_hidden
    from public.hq_ledger_items item
    where item.vinted_item_id = p_vinted_item_id
    order by item.updated_at desc nulls last
    limit 1
  ), true);
$$;

revoke all on function public.is_fadewell_storefront_visible(text) from public;
grant execute on function public.is_fadewell_storefront_visible(text) to anon, authenticated;

drop policy if exists "public reads published storefront" on public.fadewell_storefront_products;
create policy "public reads published storefront"
on public.fadewell_storefront_products
for select
to anon, authenticated
using (published and public.is_fadewell_storefront_visible(vinted_item_id));

create or replace function public.set_hq_storefront_visibility_owner(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  item_key text := nullif(btrim(coalesce(p->>'item_id', '')), '');
  requested_hidden boolean;
  current_hidden boolean;
  current_vinted_id text;
  current_status text;
  event_key text := nullif(btrim(coalesce(p->>'external_key', '')), '');
  reason text := nullif(btrim(coalesce(p->>'note', '')), '');
begin
  if not public.is_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if item_key is null then
    raise exception 'DEN item is required';
  end if;
  if p ? 'hidden' is not true or lower(p->>'hidden') not in ('true', 'false') then
    raise exception 'hidden must be true or false';
  end if;
  requested_hidden := (p->>'hidden')::boolean;

  select storefront_hidden, vinted_item_id, ledger_status
    into current_hidden, current_vinted_id, current_status
  from public.hq_ledger_items
  where item_id = item_key
  for update;
  if not found then
    raise exception 'Unknown canonical Item_ID';
  end if;
  if current_vinted_id is null or current_status <> 'LISTED-BACKLOG' then
    raise exception 'Storefront visibility requires an active listed DEN item';
  end if;
  if current_hidden = requested_hidden then
    return jsonb_build_object(
      'item_id', item_key,
      'vinted_item_id', current_vinted_id,
      'storefront_hidden', current_hidden,
      'idempotent', true
    );
  end if;

  update public.hq_ledger_items
  set storefront_hidden = requested_hidden,
      updated_at = now(),
      version = version + 1
  where item_id = item_key;

  insert into public.hq_ledger_events(
    item_id, event_type, occurred_on, currency, detail, source, external_key
  ) values (
    item_key,
    'ADJUSTMENT',
    current_date,
    'PLN',
    case when requested_hidden then 'STOREFRONT_HIDE' else 'STOREFRONT_REVEAL' end
      || ': public FADEWELL visibility changed without changing the Vinted listing or DEN state'
      || case when reason is null then '' else ' · ' || reason end,
    'MANUAL',
    coalesce(event_key, 'storefront-visibility-' || item_key || '-' || extract(epoch from clock_timestamp())::bigint::text)
  );

  return jsonb_build_object(
    'item_id', item_key,
    'vinted_item_id', current_vinted_id,
    'storefront_hidden', requested_hidden,
    'idempotent', false
  );
end;
$$;

revoke all on function public.set_hq_storefront_visibility_owner(jsonb) from public, anon;
grant execute on function public.set_hq_storefront_visibility_owner(jsonb) to authenticated;

commit;
