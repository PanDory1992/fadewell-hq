-- A historical Vinted title is an observation, not a replacement for the
-- original purchase shorthand. Only a missing live_title may be filled.
create or replace function public.backfill_hq_vinted_title(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item text:=nullif(p->>'item_id',''); title text:=nullif(btrim(p->>'title'),'');
  vinted_id text:=nullif(p->>'vinted_item_id',''); event_key text:=nullif(p->>'external_key','');
  current record;
begin
  if auth.role()<>'service_role' and not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if item is null or title is null or vinted_id is null or event_key is null then raise exception 'Item, Vinted ID, title and external key are required'; end if;
  if exists(select 1 from hq_ledger_events where external_key=event_key) then return jsonb_build_object('duplicate',true,'item_id',item); end if;
  select item_id,vinted_item_id,live_title into current from hq_ledger_items where item_id=item;
  if current is null then raise exception 'Known DEN Item_ID required'; end if;
  if current.vinted_item_id::text<>vinted_id then raise exception 'Vinted ID does not match this DEN'; end if;
  if nullif(btrim(current.live_title),'') is not null then return jsonb_build_object('skipped',true,'item_id',item,'reason','title_already_present'); end if;
  update hq_ledger_items set live_title=title,listing_url=coalesce(listing_url,'https://www.vinted.pl/items/'||vinted_id),version=version+1 where item_id=item;
  insert into hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
  values(item,'ADJUSTMENT',current_date,'Vinted title backfilled from the public historical listing page.','VINTED',event_key);
  return jsonb_build_object('updated',true,'item_id',item);
end $$;
revoke all on function public.backfill_hq_vinted_title(jsonb) from public;
grant execute on function public.backfill_hq_vinted_title(jsonb) to authenticated, service_role;
