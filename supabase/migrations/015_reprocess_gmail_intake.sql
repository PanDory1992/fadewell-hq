-- A parser correction may turn a previously incomplete Gmail event into a
-- complete, safely applicable record. Preserve auto-applied events as immutable,
-- but let a NEEDS_REVIEW event be replayed exactly once through the same atomic
-- ledger path.
create or replace function public.apply_hq_gmail_intake(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  kind text := p->>'event_type'; source_id text := p->>'source_event_id';
  event_date date := nullif(p->>'occurred_on','')::date;
  event_amount numeric := nullif(p->>'amount','')::numeric;
  item text := nullif(p->>'matched_item_id',''); created_item text; ledger_id bigint;
  old_state text; old_ledger_id bigint; old_item text; was_review boolean := false;
begin
  if coalesce(source_id,'')='' then raise exception 'Gmail source_event_id is required'; end if;
  perform pg_advisory_xact_lock(hashtext('hq-gmail-intake'));
  select state,ledger_event_id,matched_item_id into old_state,old_ledger_id,old_item
    from hq_external_events where source='GMAIL_VINTED' and source_event_id=source_id;
  if found then
    if old_state='AUTO_APPLIED' or (p->>'state')<>'AUTO_APPLIED' then
      return jsonb_build_object('duplicate',true,'state',old_state,'ledger_event_id',old_ledger_id,'item_id',old_item);
    end if;
    was_review := true;
  end if;
  if kind='PURCHASE_CONFIRMED' and (p->>'state')='AUTO_APPLIED' then
    if event_amount is null or event_amount<=0 or coalesce(nullif(trim(p->>'item_title'),''),'')='' then raise exception 'Purchase requires title and positive paid total'; end if;
    select 'DEN-'||lpad((coalesce(max((substring(item_id from '^DEN-([0-9]+)$'))::integer),0)+1)::text,3,'0') into created_item from hq_ledger_items;
    ledger_id:=apply_hq_ledger_action(jsonb_build_object('action_type','PURCHASE','item_id',created_item,'occurred_on',event_date,'name',p->>'item_title','sourcing_type','Vinted purchase','purchase_cost',event_amount,'delivery_cost',0,'total_capital',event_amount,'note','Vinted Gmail purchase receipt '||source_id,'source','VINTED','external_key','gmail-'||source_id)); item:=created_item;
  elsif kind='SALE_PENDING' and (p->>'state')='AUTO_APPLIED' then
    if item is null or event_amount is null or event_amount<=0 or not exists(select 1 from hq_ledger_items where item_id=item and ledger_status<>'SOLD') then raise exception 'Sale requires one unsold canonical DEN and a positive amount'; end if;
    ledger_id:=apply_hq_ledger_action(jsonb_build_object('action_type','SALE','item_id',item,'occurred_on',event_date,'amount',event_amount,'note','Vinted Gmail sale notification '||source_id,'source','VINTED','external_key','gmail-'||source_id));
  elsif (p->>'state')='AUTO_APPLIED' then raise exception 'Only a complete purchase receipt or unambiguous pending sale may auto-apply'; end if;
  if was_review then
    update hq_external_events set vinted_transaction_id=nullif(p->>'vinted_transaction_id',''), event_type=kind, state=p->>'state', occurred_at=event_date, item_title=nullif(p->>'item_title',''), amount=event_amount, matched_item_id=item, ledger_event_id=ledger_id, evidence=coalesce(evidence,'{}'::jsonb)||coalesce(p->'evidence','{}'::jsonb)||jsonb_build_object('reprocessed',true)
      where source='GMAIL_VINTED' and source_event_id=source_id;
  else
    insert into hq_external_events(source,source_event_id,vinted_transaction_id,event_type,state,occurred_at,item_title,amount,matched_item_id,ledger_event_id,evidence)
    values('GMAIL_VINTED',source_id,nullif(p->>'vinted_transaction_id',''),kind,coalesce(p->>'state','NEEDS_REVIEW'),event_date,nullif(p->>'item_title',''),event_amount,item,ledger_id,coalesce(p->'evidence','{}'::jsonb));
  end if;
  return jsonb_build_object('duplicate',false,'state',coalesce(p->>'state','NEEDS_REVIEW'),'ledger_event_id',ledger_id,'item_id',item,'reprocessed',was_review);
end $$;
revoke all on function public.apply_hq_gmail_intake(jsonb) from public;
grant execute on function public.apply_hq_gmail_intake(jsonb) to service_role;
