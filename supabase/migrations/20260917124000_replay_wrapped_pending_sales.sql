-- Repair three observed Apps Script plaintext messages after parser v7.
-- Preserve settled/manual decisions. Book only one exact active DEN match.
do $$
declare
  r record; gm public.hq_gmail_messages%rowtype; parsed jsonb;
  target text; matches integer; state_before text; outcome jsonb;
begin
  perform pg_advisory_xact_lock(hashtext('hq-gmail-intake'));
  for r in select * from (values
    ('1a0a370e85ed79ff','Levi’s 505 Regular Straight Jeans – Taupe Beige – W32 L34 – Like New',113.89::numeric),
    ('1a0aea52e4f4cd4b','Deluxe Lever-Action Corkscrew Wine Set – New & Unused – Professional Rabbit Style – Gift Box',30.00::numeric),
    ('1a0aecf4ec376a63','Levi’s 501 Original Fit Jeans – Dark Indigo – W32 L30 – Vintage Made in Poland 2002',179.10::numeric)
  ) as observed(message_id,title,amount) loop
    select * into gm from public.hq_gmail_messages where gmail_message_id=r.message_id;
    if not found then continue; end if;
    -- Fail closed if retained evidence no longer supports this repair.
    if position(replace(r.title,' ','') in replace(replace(gm.normalized_body,E'\n',''),' ',''))=0
       or position('zł'||r.amount::text in gm.normalized_body)=0 then
      raise exception 'Repair evidence mismatch for %',r.message_id;
    end if;
    select extracted_fields into parsed from public.hq_gmail_parse_runs
      where gmail_message_id=r.message_id order by created_at desc limit 1;
    parsed:=parsed||jsonb_build_object(
      'item_title',jsonb_build_object('value',r.title,'status','CONFIRMED'),
      'amount',jsonb_build_object('value',r.amount,'status','CONFIRMED'));
    perform public.record_hq_gmail_evidence(jsonb_build_object(
      'gmail_message_id',gm.gmail_message_id,'gmail_thread_id',gm.gmail_thread_id,
      'sender',gm.sender,'subject',gm.subject,'received_at',gm.received_at,
      'normalized_body',gm.normalized_body,'normalized_body_sha256',gm.normalized_body_sha256,
      'redaction_version',gm.redaction_version,'parser_version','2026-09-17.template.v7',
      'event_type','SALE_PENDING','extracted_fields',parsed));
    select state into state_before from public.hq_external_events
      where source='GMAIL_VINTED' and source_event_id=r.message_id for update;
    if state_before<>'NEEDS_REVIEW' then continue; end if;
    select count(*),min(item_id) into matches,target from public.hq_ledger_items
      where ledger_status='LISTED-BACKLOG' and (
        btrim(regexp_replace(normalize(lower(coalesce(live_title,'')),NFKD),'[^a-z0-9]+',' ','g'))=
        btrim(regexp_replace(normalize(lower(r.title),NFKD),'[^a-z0-9]+',' ','g')) or
        btrim(regexp_replace(normalize(lower(coalesce(name,'')),NFKD),'[^a-z0-9]+',' ','g'))=
        btrim(regexp_replace(normalize(lower(r.title),NFKD),'[^a-z0-9]+',' ','g')));
    -- Refresh unresolved evidence too, without turning an unmatched item into DEN.
    update public.hq_external_events set item_title=r.title,amount=r.amount,
      evidence=coalesce(evidence,'{}'::jsonb)||jsonb_build_object(
        'parser_repair',jsonb_build_object('migration','20260917124000',
          'previous_item_title',item_title,'previous_amount',amount,'repaired_at',now()),
        'parser_version','2026-09-17.template.v7')
      where source='GMAIL_VINTED' and source_event_id=r.message_id;
    outcome:=public.apply_hq_gmail_intake(jsonb_build_object(
      'source_event_id',r.message_id,'event_type','SALE_PENDING',
      'state',case when matches=1 then 'AUTO_APPLIED' else 'NEEDS_REVIEW' end,
      'occurred_on',gm.received_at::date,'item_title',r.title,'amount',r.amount,
      'matched_item_id',case when matches=1 then target else null end,
      'evidence',jsonb_build_object('parser_version','2026-09-17.template.v7','repair_migration','20260917124000')));
    perform public.reconcile_hq_vinted_transaction_message(r.message_id);
    raise notice 'Replay %: %',r.message_id,outcome;
  end loop;
end $$;
