-- Gmail review decisions are explicit human actions. They either close a
-- non-DEN message without a ledger mutation, or book one confirmed sale and
-- preserve the original mail as evidence.

do $$
declare constraint_name text;
begin
  for constraint_name in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid=con.conrelid
    join pg_namespace ns on ns.oid=rel.relnamespace
    where ns.nspname='public' and rel.relname='hq_external_events'
      and con.contype='c' and pg_get_constraintdef(con.oid) ilike '%state%'
  loop
    execute format('alter table public.hq_external_events drop constraint %I',constraint_name);
  end loop;
end $$;

alter table public.hq_external_events add constraint hq_external_events_state_check
  check (state in ('NEEDS_REVIEW','AUTO_APPLIED','MANUAL_RESOLVED'));

create or replace function public.resolve_hq_gmail_review_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  source_id text:=nullif(p->>'source_event_id',''); decision text:=nullif(p->>'decision','');
  item text:=nullif(p->>'item_id',''); sale_amount numeric:=nullif(p->>'sale_amount','')::numeric;
  note text:=nullif(btrim(p->>'note'),''); event_row record; ledger_id bigint; event_date date;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if source_id is null or decision not in ('DISMISS','RECORD_SALE') then raise exception 'Known Gmail event and decision are required'; end if;
  select * into event_row from hq_external_events
    where source='GMAIL_VINTED' and source_event_id=source_id for update;
  if not found then raise exception 'Known Gmail event required'; end if;
  if event_row.state<>'NEEDS_REVIEW' then
    return jsonb_build_object('duplicate',true,'state',event_row.state,'item_id',event_row.matched_item_id,'ledger_event_id',event_row.ledger_event_id);
  end if;
  if decision='RECORD_SALE' then
    if event_row.event_type<>'SALE_PENDING' then raise exception 'Only SALE_PENDING can book a sale'; end if;
    if item is null or sale_amount is null or sale_amount<0 then raise exception 'Sale needs one DEN and a non-negative confirmed price'; end if;
    if not exists(select 1 from hq_ledger_items where item_id=item and ledger_status='LISTED-BACKLOG') then raise exception 'Sale must use one active listed DEN'; end if;
    event_date:=coalesce(event_row.occurred_at::date,current_date);
    ledger_id:=apply_hq_ledger_action(jsonb_build_object(
      'action_type','SALE','item_id',item,'occurred_on',event_date,'amount',sale_amount,
      'note',coalesce(note,'Ręcznie potwierdzona sprzedaż na podstawie maila Vinted '||source_id||'.'),
      'source','MANUAL','external_key','gmail-manual-sale-'||source_id
    ));
    update hq_external_events set state='MANUAL_RESOLVED',matched_item_id=item,ledger_event_id=ledger_id,
      evidence=coalesce(evidence,'{}'::jsonb)||jsonb_build_object('manual_resolution',jsonb_build_object(
        'decision','RECORD_SALE','sale_amount',sale_amount,'note',note,'resolved_at',now(),'resolved_by',auth.uid()
      )) where source='GMAIL_VINTED' and source_event_id=source_id;
  else
    update hq_external_events set state='MANUAL_RESOLVED',
      evidence=coalesce(evidence,'{}'::jsonb)||jsonb_build_object('manual_resolution',jsonb_build_object(
        'decision','DISMISS','note',coalesce(note,'Nie dotyczy stocku DEN.'),'resolved_at',now(),'resolved_by',auth.uid()
      )) where source='GMAIL_VINTED' and source_event_id=source_id;
  end if;
  return jsonb_build_object('duplicate',false,'state','MANUAL_RESOLVED','item_id',item,'ledger_event_id',ledger_id);
end $$;

revoke all on function public.resolve_hq_gmail_review_owner(jsonb) from public;
grant execute on function public.resolve_hq_gmail_review_owner(jsonb) to authenticated;
