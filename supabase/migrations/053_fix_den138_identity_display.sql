-- Correct display artifacts from the user-confirmed DEN-138 identity repair.
-- This changes no money values or listing history.
update public.hq_ledger_items
set name = 'Wrangler Authentics Straight Jeans - Deep Blue - W38 L32 - Comfort Flex',
    last_photo_url = null,
    version = version + 1
where item_id = 'DEN-138';

insert into public.hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
values ('DEN-138','ADJUSTMENT',current_date,null,'Display repair: cleared inherited Levi photo and normalized Wrangler title encoding; no financial values changed.','SYSTEM','identity-repair-20260726-den138-display')
on conflict (external_key) do nothing;
