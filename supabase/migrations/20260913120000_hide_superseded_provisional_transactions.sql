-- A pending-sale email initially creates a provisional gmail:<message_id>
-- transaction. When a later message supplies the exact Vinted transaction ID,
-- SAFE_TITLE_DEN moves the pending email's current link to the canonical
-- vinted:<transaction_id> transaction. Keep the provisional row and its state
-- history as audit evidence, but stop presenting it as a second active sale.

create or replace view public.hq_vinted_transaction_current as
select t.id,t.canonical_key,t.vinted_transaction_id,t.transaction_kind,t.created_at,
       coalesce((select s.state from public.hq_vinted_transaction_state_events s where s.transaction_id=t.id order by s.created_at desc,s.id desc limit 1),'') as current_state,
       coalesce((select max(s.created_at) from public.hq_vinted_transaction_state_events s where s.transaction_id=t.id),t.created_at) as state_updated_at
from public.hq_vinted_transactions t
where t.canonical_key not like 'gmail:%'
   or exists (
     select 1
     from public.hq_vinted_transaction_message_current current_link
     where current_link.transaction_id = t.id
   );

grant select on public.hq_vinted_transaction_current to authenticated;

-- Refresh today's derived quality snapshot after correcting current-state
-- visibility. This does not write to the ledger or Gmail evidence tables.
select public.record_hq_vinted_daily_quality_report();
