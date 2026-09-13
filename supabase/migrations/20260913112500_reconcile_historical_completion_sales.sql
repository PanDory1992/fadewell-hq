-- Reconcile historical completion messages only when their parsed title has
-- one exact normalized live-title match and that DEN has exactly one existing
-- SALE ledger event in the 31 days before completion. The ledger is read-only;
-- ambiguous or unmatched history remains explicitly unresolved.

create temporary table hq_historical_completion_candidates on commit drop as
with raw as (
  select gm.gmail_message_id,
         i.item_id,
         le.id as ledger_event_id
  from public.hq_gmail_parse_runs p
  join public.hq_gmail_messages gm
    on gm.gmail_message_id = p.gmail_message_id
  join public.hq_ledger_items i
    on lower(regexp_replace(coalesce(i.live_title,''),'[^[:alnum:]]+',' ','g')) =
       lower(regexp_replace(coalesce(p.extracted_fields->'item_title'->>'value',''),'[^[:alnum:]]+',' ','g'))
  join public.hq_ledger_events le
    on le.item_id = i.item_id
   and le.event_type = 'SALE'
   and le.occurred_on between gm.received_at::date - 31 and gm.received_at::date
  where p.event_type = 'SALE_CONFIRMED'
), unique_matches as (
  select gmail_message_id,
         min(item_id) as item_id,
         min(ledger_event_id) as ledger_event_id
  from raw
  group by gmail_message_id
  having count(distinct item_id) = 1
     and count(distinct ledger_event_id) = 1
)
select match.*
from unique_matches match
where not exists (
  select 1
  from public.hq_vinted_transaction_message_current link
  join public.hq_vinted_transaction_state_events state
    on state.transaction_id = link.transaction_id
   and state.state = 'SALE_RECORDED'
  where link.gmail_message_id = match.gmail_message_id
);

update public.hq_external_events event
set matched_item_id = candidate.item_id,
    ledger_event_id = candidate.ledger_event_id,
    evidence = coalesce(event.evidence,'{}'::jsonb) || jsonb_build_object(
      'historical_completion_reconciliation','exact_unique_live_title_and_sale_event_v1',
      'historical_completion_reconciled_at',now()
    )
from pg_temp.hq_historical_completion_candidates candidate
where event.source = 'GMAIL_VINTED'
  and event.source_event_id = candidate.gmail_message_id
  and event.event_type = 'SALE_CONFIRMED';

update public.hq_vinted_transactions tx
set transaction_kind = 'SALE'
from pg_temp.hq_historical_completion_candidates candidate
join public.hq_vinted_transaction_message_current link
  on link.gmail_message_id = candidate.gmail_message_id
where tx.id = link.transaction_id;

insert into public.hq_vinted_transaction_state_events(transaction_id,state,detail)
select link.transaction_id,'SALE_DETECTED',jsonb_build_object(
  'source','historical_gmail_sale_confirmed',
  'supporting_message_id',candidate.gmail_message_id
)
from pg_temp.hq_historical_completion_candidates candidate
join public.hq_vinted_transaction_message_current link
  on link.gmail_message_id = candidate.gmail_message_id
on conflict do nothing;

insert into public.hq_vinted_transaction_state_events(transaction_id,state,detail)
select link.transaction_id,'DEN_MATCHED',jsonb_build_object(
  'item_id',candidate.item_id,
  'source','exact_unique_live_title'
)
from pg_temp.hq_historical_completion_candidates candidate
join public.hq_vinted_transaction_message_current link
  on link.gmail_message_id = candidate.gmail_message_id
on conflict do nothing;

insert into public.hq_vinted_transaction_state_events(transaction_id,state,detail)
select link.transaction_id,'SALE_RECORDED',jsonb_build_object(
  'ledger_event_id',candidate.ledger_event_id,
  'amount',ledger.amount,
  'source','existing_immutable_ledger_sale'
)
from pg_temp.hq_historical_completion_candidates candidate
join public.hq_vinted_transaction_message_current link
  on link.gmail_message_id = candidate.gmail_message_id
join public.hq_ledger_events ledger
  on ledger.id = candidate.ledger_event_id
on conflict do nothing;

insert into public.hq_vinted_transaction_state_events(transaction_id,state,detail)
select link.transaction_id,'CASH_CONFIRMED',jsonb_build_object(
  'vinted_transaction_id',tx.vinted_transaction_id,
  'supporting_message_id',candidate.gmail_message_id,
  'source','trusted_gmail_sale_confirmed'
)
from pg_temp.hq_historical_completion_candidates candidate
join public.hq_vinted_transaction_message_current link
  on link.gmail_message_id = candidate.gmail_message_id
join public.hq_vinted_transactions tx
  on tx.id = link.transaction_id
on conflict do nothing;

select public.record_hq_vinted_daily_quality_report();
