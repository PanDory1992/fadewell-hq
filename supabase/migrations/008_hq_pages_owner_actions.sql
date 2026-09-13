-- GitHub Pages action channel: no service-role secret in the browser.
-- Only the authenticated HQ owner may invoke this wrapper.

create or replace function public.apply_hq_ledger_action(p jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare event_id bigint; kind text := p->>'action_type'; item text := p->>'item_id'; event_date date := nullif(p->>'occurred_on','')::date;
begin
  if kind not in ('PURCHASE','LISTED','SALE','ADJUSTMENT') then raise exception 'Invalid action type'; end if;
  if p->>'external_key' is not null and exists(select 1 from hq_ledger_events where external_key=p->>'external_key') then return (select id from hq_ledger_events where external_key=p->>'external_key'); end if;
  if kind='PURCHASE' then
    if item !~ '^DEN-[0-9]+$' or exists(select 1 from hq_ledger_items where item_id=item) then raise exception 'PURCHASE requires a new DEN Item_ID'; end if;
    insert into hq_ledger_items(item_id,name,sourcing_type,flip_tier,purchase_cost,delivery_cost,total_capital,ledger_status,purchased_on,source_row,migration_state,version)
    values(item,p->>'name',p->>'sourcing_type',p->>'flip_tier',nullif(p->>'purchase_cost','')::numeric,nullif(p->>'delivery_cost','')::numeric,nullif(p->>'total_capital','')::numeric,'UNLISTED-BACKLOG',event_date,'{}'::jsonb,'CANONICAL',1);
  elsif not exists(select 1 from hq_ledger_items where item_id=item) then raise exception 'Unknown canonical Item_ID';
  elsif kind='LISTED' then
    update hq_ledger_items set listed=true,ledger_status='LISTED-BACKLOG',listed_on=coalesce(event_date,listed_on),vinted_item_id=coalesce(nullif(p->>'vinted_item_id',''),vinted_item_id),listing_url=coalesce(nullif(p->>'listing_url',''),listing_url),live_title=coalesce(nullif(p->>'live_title',''),live_title),live_list_price=coalesce(nullif(p->>'amount','')::numeric,live_list_price),version=version+1 where item_id=item;
  elsif kind='SALE' then
    if nullif(p->>'amount','') is null then raise exception 'SALE requires a sale price'; end if;
    update hq_ledger_items set ledger_status='SOLD',sold_on=coalesce(event_date,sold_on),sale_price_arbitrage=nullif(p->>'amount','')::numeric,net_profit=nullif(p->>'amount','')::numeric-total_capital,version=version+1 where item_id=item;
  end if;
  insert into hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
  values(item,kind,event_date,nullif(p->>'amount','')::numeric,p->>'note','MANUAL',p->>'external_key') returning id into event_id;
  return event_id;
end $$;
create or replace function public.apply_hq_ledger_action_owner(p jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare payload jsonb := coalesce(p,'{}'::jsonb); next_item text;
begin
  if auth.uid() is null or not exists (select 1 from hq_members where user_id=auth.uid() and role='owner') then raise exception 'HQ owner access required'; end if;
  if payload->>'action_type'='PURCHASE' and coalesce(payload->>'item_id','')='' then
    perform pg_advisory_xact_lock(hashtext('fadewell-hq-den-id'));
    select format('DEN-%s', lpad((coalesce(max(nullif(regexp_replace(item_id,'\\D','','g'),'' )::integer),0)+1)::text,3,'0')) into next_item from hq_ledger_items where item_id ~ '^DEN-[0-9]+$';
    payload := jsonb_set(payload,'{item_id}',to_jsonb(next_item));
  end if;
  return apply_hq_ledger_action(payload);
end $$;
revoke all on function public.apply_hq_ledger_action_owner(jsonb) from public, anon;
grant execute on function public.apply_hq_ledger_action_owner(jsonb) to authenticated;
