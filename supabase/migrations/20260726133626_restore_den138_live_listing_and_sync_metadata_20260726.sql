-- DEN-138's current Vinted listing was accidentally left outside collector
-- scope during the identity repair. Restore it as an active listing.
update public.hq_ledger_items
set listed = true,
    ledger_status = 'LISTED-BACKLOG',
    vinted_item_id = '8761980027',
    listing_url = 'https://www.vinted.pl/items/8761980027',
    live_title = 'Wrangler Authentics Straight Jeans - Deep Blue - W38 L32 - Comfort Flex',
    version = version + 1
where item_id = 'DEN-138';

insert into public.hq_vinted_listing_lineage(vinted_item_id,item_id,state,last_seen_at,evidence,resolved_at,resolved_by)
values ('8761980027','DEN-138','ACTIVE',now(),jsonb_build_object('kind','scope-restoration','reason','current Vinted listing restored to collector scope'),now(),'SYSTEM')
on conflict (vinted_item_id) do update
set item_id=excluded.item_id,state='ACTIVE',last_seen_at=excluded.last_seen_at,evidence=excluded.evidence,resolved_at=excluded.resolved_at,resolved_by=excluded.resolved_by;

insert into public.hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
values ('DEN-138','LISTED',current_date,null,'System repair: restored active Vinted listing 8761980027 to DEN-138 and collector scope.','SYSTEM','identity-repair-20260726-den138-restore-live')
on conflict (external_key) do nothing;

-- Snapshot observations are allowed to refresh only current listing metadata.
-- They cannot change DEN identity, listing assignment, status, or finances.
create or replace function public.sync_hq_live_listing_metadata(p jsonb)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare changed integer;
begin
  update public.hq_ledger_items item
  set live_title = coalesce(feed.title, item.live_title),
      live_list_price = coalesce(feed.price_pln, item.live_list_price),
      last_photo_url = coalesce(nullif(feed.photo_url, ''), item.last_photo_url),
      last_live_check_on = current_date,
      version = item.version + 1
  from jsonb_to_recordset(coalesce(p, '[]'::jsonb)) as feed(vinted_item_id text,title text,price_pln numeric,photo_url text)
  where item.vinted_item_id = feed.vinted_item_id
    and item.ledger_status = 'LISTED-BACKLOG'
    and (item.live_title is distinct from coalesce(feed.title, item.live_title)
      or item.live_list_price is distinct from coalesce(feed.price_pln, item.live_list_price)
      or item.last_photo_url is distinct from coalesce(nullif(feed.photo_url, ''), item.last_photo_url)
      or item.last_live_check_on is distinct from current_date);
  get diagnostics changed = row_count;
  return changed;
end;
$$;
revoke all on function public.sync_hq_live_listing_metadata(jsonb) from public, anon, authenticated;
grant execute on function public.sync_hq_live_listing_metadata(jsonb) to service_role;
