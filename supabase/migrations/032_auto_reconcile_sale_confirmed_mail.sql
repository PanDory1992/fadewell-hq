-- A trusted Vinted completion notice confirms cash availability only. It never
-- creates a second sale: the sale is recorded from SALE_PENDING. Keep the
-- notice as audit evidence, but do not put it in the human review queue.

create or replace function public.apply_hq_gmail_intake(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  kind text := p->>'event_type'; source_id text := p->>'source_event_id';
  event_date date := nullif(p->>'occurred_on','')::date;
  event_amount numeric := nullif(p->>'amount','')::numeric;
  item text := nullif(p->>'matched_item_id',''); created_item text; ledger_id bigint;
  old_state text; old_ledger_id bigint; old_item text; was_review boolean := false;
  bundle_items jsonb := coalesce(p->'bundle_items','[]'::jsonb); bundle_count integer;
  total_grosze integer; base_grosze integer; extra_grosze integer; share numeric;
  bundle_ids jsonb := '[]'::jsonb; bundle_shares jsonb := '[]'::jsonb; bundle_title text; bundle_ledger_id bigint; i integer;
begin
  if coalesce(source_id,'')='' then raise exception 'Gmail source_event_id is required'; end if;
  perform pg_advisory_xact_lock(hashtext('hq-gmail-intake'));
  select state,ledger_event_id,matched_item_id into old_state,old_ledger_id,old_item
    from hq_external_events where source='GMAIL_VINTED' and source_event_id=source_id;
  if found then
    if old_state in ('AUTO_APPLIED','AUTO_DISMISSED','MANUAL_RESOLVED')
       or (p->>'state') not in ('AUTO_APPLIED','AUTO_DISMISSED') then
      return jsonb_build_object('duplicate',true,'state',old_state,'ledger_event_id',old_ledger_id,'item_id',old_item);
    end if;
    was_review := true;
  end if;

  if kind='PURCHASE_BUNDLE' and (p->>'state')='AUTO_APPLIED' then
    bundle_count := jsonb_array_length(bundle_items);
    if bundle_count < 2 or event_amount is null or event_amount <= 0 then raise exception 'Bundle purchase requires at least two item titles and a positive paid total'; end if;
    total_grosze := round(event_amount * 100)::integer; base_grosze := total_grosze / bundle_count; extra_grosze := total_grosze % bundle_count;
    for i in 0..bundle_count-1 loop
      bundle_title := nullif(btrim(bundle_items->>i),''); if bundle_title is null then raise exception 'Bundle purchase item title is required'; end if;
      share := (base_grosze + case when i < extra_grosze then 1 else 0 end)::numeric / 100;
      select 'DEN-'||lpad((coalesce(max((substring(item_id from '^DEN-([0-9]+)$'))::integer),0)+1)::text,3,'0') into created_item from hq_ledger_items;
      ledger_id:=apply_hq_ledger_action(jsonb_build_object('action_type','PURCHASE','item_id',created_item,'occurred_on',event_date,'name',bundle_title,'sourcing_type','Vinted purchase bundle','purchase_cost',share,'delivery_cost',0,'total_capital',share,'note',format('Vinted Gmail bundle receipt %s Â· part %s/%s Â· equal split of paid total',source_id,i+1,bundle_count),'source','VINTED','external_key',format('gmail-%s-bundle-%s',source_id,i+1)));
      if i=0 then item:=created_item; bundle_ledger_id:=ledger_id; end if;
      bundle_ids:=bundle_ids||jsonb_build_array(created_item); bundle_shares:=bundle_shares||jsonb_build_array(share);
    end loop;
    ledger_id:=bundle_ledger_id;
  elsif kind='PURCHASE_CONFIRMED' and (p->>'state')='AUTO_APPLIED' then
    if event_amount is null or event_amount<=0 or coalesce(nullif(trim(p->>'item_title'),''),'')='' then raise exception 'Purchase requires title and positive paid total'; end if;
    select 'DEN-'||lpad((coalesce(max((substring(item_id from '^DEN-([0-9]+)$'))::integer),0)+1)::text,3,'0') into created_item from hq_ledger_items;
    ledger_id:=apply_hq_ledger_action(jsonb_build_object('action_type','PURCHASE','item_id',created_item,'occurred_on',event_date,'name',p->>'item_title','sourcing_type','Vinted purchase','purchase_cost',event_amount,'delivery_cost',0,'total_capital',event_amount,'note','Vinted Gmail purchase receipt '||source_id,'source','VINTED','external_key','gmail-'||source_id)); item:=created_item;
  elsif kind='SALE_PENDING' and (p->>'state')='AUTO_APPLIED' then
    if item is null or event_amount is null or event_amount<=0
       or not exists(select 1 from hq_ledger_items where item_id=item and ledger_status='LISTED-BACKLOG') then
      raise exception 'Sale requires one active listed DEN and a positive amount';
    end if;
    ledger_id:=apply_hq_ledger_action(jsonb_build_object('action_type','SALE','item_id',item,'occurred_on',event_date,'amount',event_amount,'note','Vinted Gmail sale notification '||source_id,'source','VINTED','external_key','gmail-'||source_id));
  elsif kind='SALE_CONFIRMED' and (p->>'state')='AUTO_APPLIED' then
    -- The preceding SALE_PENDING owns the accounting event. This mail is only
    -- an automatically reconciled, auditable confirmation of available cash.
    null;
  elsif kind='NOISE' and (p->>'state')='AUTO_DISMISSED' then
    null;
  elsif (p->>'state')='AUTO_APPLIED' then
    raise exception 'Only a complete purchase receipt, complete bundle receipt, uniquely matched active listed sale or sale completion notice may auto-apply';
  elsif (p->>'state')='AUTO_DISMISSED' then
    raise exception 'Only recognised Vinted noise mail may auto-dismiss';
  end if;

  if was_review then
    update hq_external_events set vinted_transaction_id=nullif(p->>'vinted_transaction_id',''),event_type=kind,state=p->>'state',occurred_at=event_date,item_title=nullif(p->>'item_title',''),amount=event_amount,matched_item_id=item,ledger_event_id=ledger_id,evidence=coalesce(evidence,'{}'::jsonb)||coalesce(p->'evidence','{}'::jsonb)||jsonb_build_object('reprocessed',true)||case when kind='PURCHASE_BUNDLE' then jsonb_build_object('bundle_item_ids',bundle_ids,'bundle_shares',bundle_shares) else '{}'::jsonb end where source='GMAIL_VINTED' and source_event_id=source_id;
  else
    insert into hq_external_events(source,source_event_id,vinted_transaction_id,event_type,state,occurred_at,item_title,amount,matched_item_id,ledger_event_id,evidence)
    values('GMAIL_VINTED',source_id,nullif(p->>'vinted_transaction_id',''),kind,coalesce(p->>'state','NEEDS_REVIEW'),event_date,nullif(p->>'item_title',''),event_amount,item,ledger_id,coalesce(p->'evidence','{}'::jsonb)||case when kind='PURCHASE_BUNDLE' then jsonb_build_object('bundle_item_ids',bundle_ids,'bundle_shares',bundle_shares) else '{}'::jsonb end);
  end if;
  return jsonb_build_object('duplicate',false,'state',coalesce(p->>'state','NEEDS_REVIEW'),'ledger_event_id',ledger_id,'item_id',item,'item_ids',bundle_ids,'bundle_shares',bundle_shares,'reprocessed',was_review);
end $$;

revoke all on function public.apply_hq_gmail_intake(jsonb) from public;
grant execute on function public.apply_hq_gmail_intake(jsonb) to service_role;
