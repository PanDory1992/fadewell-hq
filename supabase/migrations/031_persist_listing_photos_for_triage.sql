-- Preserve the latest observed listing photo for every linked DEN, including
-- items later returned to the unlisted queue.
create or replace function public.persist_hq_listing_photo()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if nullif(btrim(coalesce(new.photo_url,'')),'') is not null then
    update public.hq_ledger_items
    set last_photo_url=new.photo_url,
        version=version+1
    where vinted_item_id=new.vinted_item_id
      and last_photo_url is distinct from new.photo_url;
  end if;
  return new;
end $$;

drop trigger if exists hq_persist_listing_photo on public.hq_listing_snapshots;
create trigger hq_persist_listing_photo
after insert or update of photo_url on public.hq_listing_snapshots
for each row execute function public.persist_hq_listing_photo();

-- Backfill from retained listing evidence without inventing photos for items
-- that HQ has never observed.
update public.hq_ledger_items item
set last_photo_url=(
      select snapshot.photo_url
      from public.hq_listing_snapshots snapshot
      where snapshot.vinted_item_id=item.vinted_item_id
        and nullif(btrim(coalesce(snapshot.photo_url,'')),'') is not null
      order by snapshot.captured_at desc, snapshot.id desc
      limit 1
    ),
    version=version+1
where item.vinted_item_id is not null
  and item.last_photo_url is distinct from (
    select snapshot.photo_url
    from public.hq_listing_snapshots snapshot
    where snapshot.vinted_item_id=item.vinted_item_id
      and nullif(btrim(coalesce(snapshot.photo_url,'')),'') is not null
    order by snapshot.captured_at desc, snapshot.id desc
    limit 1
  );
