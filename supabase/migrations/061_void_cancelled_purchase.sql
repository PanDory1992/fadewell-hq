-- 061_void_cancelled_purchase.sql
-- Complete Void / Un-void purchase support for FADEWELL HQ
-- Preserves append-only event audit history and ensures 100% reversibility.

create or replace function public.apply_hq_void_purchase(p jsonb, p_actor text default 'MANUAL')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  target_item text := nullif(payload->>'item_id', '');
  reason text := nullif(payload->>'reason', '');
  event_key text := coalesce(nullif(payload->>'external_key', ''), gen_random_uuid()::text);
  event_date date := coalesce(nullif(payload->>'occurred_on', '')::date, current_date);
  item_row record;
  previous_snapshot jsonb;
  event_id bigint;
begin
  if target_item is null then
    raise exception 'Void purchase requires an item_id';
  end if;
  if reason is null or length(trim(reason)) < 3 then
    raise exception 'Void purchase requires a reason';
  end if;

  select * into item_row from public.hq_ledger_items where item_id = target_item;
  if not found then
    raise exception 'Item % not found in hq_ledger_items', target_item;
  end if;

  previous_snapshot := jsonb_build_object(
    'previous_ledger_status', item_row.ledger_status,
    'previous_purchase_cost', item_row.purchase_cost,
    'previous_delivery_cost', item_row.delivery_cost,
    'previous_total_capital', item_row.total_capital,
    'previous_name', item_row.name,
    'previous_manual_title', item_row.manual_title,
    'voided_at', now(),
    'reason', reason
  );

  if exists (select 1 from public.hq_ledger_events where external_key = event_key) then
    return jsonb_build_object('duplicate', true, 'item_id', target_item);
  end if;

  insert into public.hq_ledger_events (
    item_id, event_type, occurred_on, amount, currency, detail, source, external_key
  ) values (
    target_item, 'ADJUSTMENT', event_date, 0, 'PLN',
    'ANULOWANIE ZAKUPU (Void): ' || reason || ' [Kopia bezpieczeństwa: status=' || item_row.ledger_status || ', cost=' || coalesce(item_row.purchase_cost::text, '0') || ', total_capital=' || coalesce(item_row.total_capital::text, '0') || ', manual_title=' || coalesce(item_row.manual_title, '') || ']',
    upper(p_actor), event_key
  ) returning id into event_id;

  update public.hq_ledger_items
  set
    ledger_status = 'VOIDED',
    purchase_cost = 0,
    delivery_cost = 0,
    total_capital = 0,
    manual_title = case 
      when manual_title is null or manual_title = '' then '[VOIDED] ' || name
      when manual_title not like '%[VOIDED]%' then '[VOIDED] ' || manual_title
      else manual_title
    end,
    updated_at = now()
  where item_id = target_item;

  update public.hq_external_events
  set state = 'MANUAL_RESOLVED'
  where matched_item_id = target_item;

  return jsonb_build_object('success', true, 'item_id', target_item, 'event_id', event_id, 'previous_state', previous_snapshot);
end;
$$;
