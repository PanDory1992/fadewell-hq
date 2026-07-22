-- 044 reached production but PostgreSQL rejected its update because a local
-- variable shared a name with hq_external_events.matched_item_id. The failed
-- statement rolled back; this replacement only removes that ambiguity.

create or replace function public.reconcile_hq_manual_sale_evidence(p_source_event_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  event_row public.hq_external_events%rowtype;
  candidate_count integer := 0;
  candidate_ledger_event_id bigint;
  candidate_item_id text;
  candidate_amount numeric;
  amount_delta numeric;
begin
  if nullif(p_source_event_id,'') is null then
    raise exception 'Gmail source_event_id is required';
  end if;

  select * into event_row
  from public.hq_external_events
  where source='GMAIL_VINTED' and source_event_id=p_source_event_id
  for update;

  if not found then
    raise exception 'Known Gmail event required';
  end if;

  if event_row.state<>'NEEDS_REVIEW' or event_row.event_type<>'SALE_PENDING'
     or event_row.amount is null or event_row.amount<=0
     or nullif(btrim(event_row.item_title),'') is null or event_row.occurred_at is null then
    return jsonb_build_object('reconciled',false,'state',event_row.state,'reason','not_an_eligible_open_sale_review');
  end if;

  select count(*),min(candidate.id),min(candidate.item_id),min(candidate.amount)
  into candidate_count,candidate_ledger_event_id,candidate_item_id,candidate_amount
  from (
    select le.id,le.item_id,le.amount
    from public.hq_ledger_events le
    join public.hq_ledger_items item on item.item_id=le.item_id
    where le.event_type='SALE'
      and le.source='MANUAL'
      and item.ledger_status='SOLD'
      and le.occurred_on=event_row.occurred_at::date
      and abs(le.amount-event_row.amount)<=0.10
      and lower(regexp_replace(coalesce(item.live_title,item.name,''),'[^[:alnum:]]+',' ','g'))
          = lower(regexp_replace(event_row.item_title,'[^[:alnum:]]+',' ','g'))
  ) candidate;

  if candidate_count<>1 then
    return jsonb_build_object('reconciled',false,'state','NEEDS_REVIEW','candidate_count',candidate_count,'reason','manual_sale_match_not_unique');
  end if;

  amount_delta:=round(event_row.amount-candidate_amount,2);
  update public.hq_external_events
  set state='MANUAL_RESOLVED',
      matched_item_id=candidate_item_id,
      ledger_event_id=candidate_ledger_event_id,
      evidence=coalesce(evidence,'{}'::jsonb)||jsonb_build_object(
        'manual_sale_reconciliation',jsonb_build_object(
          'decision','ALREADY_RECORDED',
          'match_rule','unique normalized live title + same sale date + manual sale amount within 0.10 PLN',
          'ledger_event_id',candidate_ledger_event_id,
          'item_id',candidate_item_id,
          'gmail_amount',event_row.amount,
          'ledger_amount',candidate_amount,
          'amount_delta',amount_delta,
          'reconciled_at',now()
        )
      )
  where source='GMAIL_VINTED' and source_event_id=p_source_event_id;

  return jsonb_build_object('reconciled',true,'state','MANUAL_RESOLVED','ledger_event_id',candidate_ledger_event_id,'item_id',candidate_item_id,'amount_delta',amount_delta);
end $$;

revoke all on function public.reconcile_hq_manual_sale_evidence(text) from public;
grant execute on function public.reconcile_hq_manual_sale_evidence(text) to service_role;
