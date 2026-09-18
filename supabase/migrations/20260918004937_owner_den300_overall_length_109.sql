do $$
declare target_count integer;
begin
  if exists(select 1 from public.hq_ledger_events where external_key='owner-den300-overall-length-109-20260918') then return; end if;
  select count(*) into target_count from public.hq_ledger_items where item_id='DEN-300' and vinted_item_id='10038070683';
  if target_count <> 1 then raise exception 'DEN-300 identity guard failed'; end if;
  if exists(select 1 from public.hq_ledger_items where item_id='DEN-300' and item_dna #> '{facts,measurements,overall_length}' is not null) then raise exception 'Existing manual measurement requires review'; end if;
  update public.hq_ledger_items
  set item_dna=jsonb_set(
        jsonb_set(item_dna,'{facts}',coalesce(item_dna->'facts','{}'::jsonb)||jsonb_build_object('measurements',coalesce(item_dna#>'{facts,measurements}','{}'::jsonb)||jsonb_build_object('overall_length',jsonb_build_object('cm',109,'min_cm',109,'max_cm',109,'display','109 cm','source','OWNER_CONFIRMED')))),
        '{evidence}',coalesce(item_dna->'evidence','{}'::jsonb)||jsonb_build_object('owner_measurement_confirmation',jsonb_build_object('field','overall_length','cm',109,'confirmed_on','2026-09-18','source','OWNER_CHAT'))
      )||jsonb_build_object('updated_at',now(),'updated_by','OWNER_CONFIRMED'),
      item_dna_updated_at=now(),version=version+1
  where item_id='DEN-300' and vinted_item_id='10038070683';
  insert into public.hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
  values('DEN-300','ADJUSTMENT','2026-09-18','Owner confirmed overall length: 109 cm. Stored in Item DNA; no Vinted description or accounting amounts changed.','MANUAL','owner-den300-overall-length-109-20260918');
end $$;
