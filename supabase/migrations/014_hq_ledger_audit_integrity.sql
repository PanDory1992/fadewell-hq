-- Ledger history is evidence: append only, and corrections must be new events.
-- This follows 013_harden_gmail_intake.sql and changes neither Google Sheet nor
-- existing HQ rows.

create or replace function public.prevent_hq_ledger_event_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'HQ Ledger events are append-only; add a correcting event instead of changing history';
end;
$$;

drop trigger if exists hq_ledger_events_append_only on public.hq_ledger_events;
create trigger hq_ledger_events_append_only
before update or delete on public.hq_ledger_events
for each row execute function public.prevent_hq_ledger_event_mutation();

create or replace function public.apply_hq_ledger_action(p jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare
  event_id bigint;
  kind text := p->>'action_type';
  item text := p->>'item_id';
  event_date date := nullif(p->>'occurred_on','')::date;
  event_source text := coalesce(nullif(p->>'source',''), 'MANUAL');
  action_amount numeric := nullif(p->>'amount','')::numeric;
begin
  if kind not in ('PURCHASE','LISTED','SALE','ADJUSTMENT') then raise exception 'Invalid action type'; end if;
  if event_source not in ('MIGRATION','VINTED','MANUAL','SYSTEM') then raise exception 'Invalid event source'; end if;
  if p->>'external_key' is not null and exists(select 1 from hq_ledger_events where external_key=p->>'external_key') then
    return (select id from hq_ledger_events where external_key=p->>'external_key');
  end if;
  if kind='PURCHASE' then
    if item !~ '^DEN-[0-9]+$' or exists(select 1 from hq_ledger_items where item_id=item) then raise exception 'PURCHASE requires a new DEN Item_ID'; end if;
    if nullif(btrim(coalesce(p->>'name','')),'') is null then raise exception 'PURCHASE requires a name'; end if;
    if coalesce(nullif(p->>'total_capital','')::numeric, -1) < 0 then raise exception 'PURCHASE requires non-negative total capital'; end if;
    insert into hq_ledger_items(item_id,name,sourcing_type,flip_tier,purchase_cost,delivery_cost,total_capital,ledger_status,purchased_on,source_row,migration_state,version)
    values(item,p->>'name',p->>'sourcing_type',p->>'flip_tier',nullif(p->>'purchase_cost','')::numeric,nullif(p->>'delivery_cost','')::numeric,nullif(p->>'total_capital','')::numeric,'UNLISTED-BACKLOG',event_date,'{}'::jsonb,'CANONICAL',1);
  elsif not exists(select 1 from hq_ledger_items where item_id=item) then
    raise exception 'Unknown canonical Item_ID';
  elsif kind='LISTED' then
    if exists(select 1 from hq_ledger_items where item_id=item and ledger_status='SOLD') then raise exception 'Cannot list an item already marked SOLD'; end if;
    update hq_ledger_items set listed=true,ledger_status='LISTED-BACKLOG',listed_on=coalesce(event_date,listed_on),vinted_item_id=coalesce(nullif(p->>'vinted_item_id',''),vinted_item_id),listing_url=coalesce(nullif(p->>'listing_url',''),listing_url),live_title=coalesce(nullif(p->>'live_title',''),live_title),live_list_price=coalesce(action_amount,live_list_price),version=version+1 where item_id=item;
  elsif kind='SALE' then
    if action_amount is null or action_amount < 0 then raise exception 'SALE requires a non-negative sale price'; end if;
    if exists(select 1 from hq_ledger_items where item_id=item and ledger_status='SOLD') then raise exception 'SALE already recorded; add an ADJUSTMENT with a reason if correction is required'; end if;
    update hq_ledger_items set ledger_status='SOLD',sold_on=coalesce(event_date,sold_on),sale_price_arbitrage=action_amount,net_profit=action_amount-total_capital,version=version+1 where item_id=item;
  elsif nullif(btrim(coalesce(p->>'note','')),'') is null then
    raise exception 'ADJUSTMENT requires a written reason; it does not rewrite prior events';
  end if;
  insert into hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
  values(item,kind,event_date,action_amount,p->>'note',event_source,p->>'external_key') returning id into event_id;
  return event_id;
end $$;
