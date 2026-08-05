-- Reconcile provisional sale transactions when a later completion mail is
-- safely linked to the original pending-sale message by title and DEN.
-- This changes transaction state only; it never creates a second ledger sale.

create or replace function public.record_hq_vinted_transaction_states()
returns jsonb language plpgsql security definer set search_path = public as $$
declare inserted_count integer := 0;
begin
  -- The order is deliberately explicit: confirmation can never create a ledger entry.
  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'SALE_DETECTED',jsonb_build_object('source','gmail_sale_pending')
  from hq_vinted_transactions t
  where t.transaction_kind='SALE' and exists (
    select 1 from hq_vinted_transaction_message_current l join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
    where l.transaction_id=t.id and e.event_type='SALE_PENDING'
  ) on conflict do nothing;
  get diagnostics inserted_count = row_count;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'DEN_MATCHED',jsonb_build_object('item_id',e.matched_item_id)
  from hq_vinted_transactions t join hq_vinted_transaction_message_current l on l.transaction_id=t.id
  join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
  where t.transaction_kind='SALE' and e.event_type='SALE_PENDING' and e.matched_item_id is not null
  on conflict do nothing;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'SALE_RECORDED',jsonb_build_object('ledger_event_id',e.ledger_event_id,'amount',e.amount)
  from hq_vinted_transactions t join hq_vinted_transaction_message_current l on l.transaction_id=t.id
  join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
  where t.transaction_kind='SALE' and e.event_type='SALE_PENDING' and e.ledger_event_id is not null and e.amount > 0
  on conflict do nothing;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'CASH_CONFIRMED',jsonb_build_object('vinted_transaction_id',t.vinted_transaction_id)
  from hq_vinted_transactions t
  where t.transaction_kind='SALE' and t.vinted_transaction_id is not null
    and exists (
      select 1 from hq_vinted_transaction_message_current l join hq_gmail_parse_runs p on p.gmail_message_id=l.gmail_message_id
      where l.transaction_id=t.id and p.event_type='SALE_CONFIRMED'
    )
    and exists (select 1 from hq_vinted_transaction_state_events s where s.transaction_id=t.id and s.state='SALE_RECORDED')
  on conflict do nothing;

  -- A later completion mail may be stored as its own Vinted transaction. If
  -- SAFE_TITLE_DEN links it to the original provisional Gmail transaction,
  -- carry the cash confirmation back to that original transaction too.
  -- This is state reconciliation only and deliberately does not touch the ledger.
  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select pending.id,'CASH_CONFIRMED',jsonb_build_object(
    'vinted_transaction_id',confirmed.vinted_transaction_id,
    'confirmed_transaction_id',confirmed.id,
    'supporting_message_id',bridge.gmail_message_id,
    'link_method','SAFE_TITLE_DEN'
  )
  from hq_vinted_transaction_message_links bridge
  join hq_vinted_transactions confirmed on confirmed.id=bridge.transaction_id
  join hq_vinted_transactions pending on pending.canonical_key='gmail:'||bridge.gmail_message_id
  where bridge.link_method='SAFE_TITLE_DEN'
    and confirmed.transaction_kind='SALE'
    and confirmed.vinted_transaction_id is not null
    and exists (select 1 from hq_vinted_transaction_state_events s where s.transaction_id=confirmed.id and s.state='CASH_CONFIRMED')
    and exists (select 1 from hq_vinted_transaction_state_events s where s.transaction_id=pending.id and s.state='SALE_RECORDED')
  on conflict do nothing;

  return jsonb_build_object('ok',true);
end $$;

-- Apply the same reconciliation to already imported history.
select public.record_hq_vinted_transaction_states();

create or replace view public.hq_vinted_operations_exceptions as
select e.source_event_id as reference_id,'GMAIL_REVIEW' as exception_type,e.created_at,e.event_type,e.item_title,e.amount,e.vinted_transaction_id
from hq_external_events e where e.source='GMAIL_VINTED' and e.state='NEEDS_REVIEW'
union all
select t.canonical_key,'RECORDED_SALE_WITHOUT_CASH',t.state_updated_at,'SALE_PENDING',pending_mail.item_title,pending_mail.amount::numeric,t.vinted_transaction_id
from hq_vinted_transaction_current t
left join hq_external_events pending_mail
  on pending_mail.source='GMAIL_VINTED'
 and pending_mail.source_event_id=substring(t.canonical_key from 7)
where t.current_state='SALE_RECORDED'
  and t.state_updated_at < now()-interval '21 days';
