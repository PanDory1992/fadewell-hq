create or replace function public.record_hq_price_test_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare item text:=nullif(p->>'item_id',''); amount numeric:=nullif(p->>'price','')::numeric; old_price numeric; event_id bigint;
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if item is null or amount is null or amount<0 then raise exception 'Listed DEN and non-negative price required'; end if;
  select live_list_price into old_price from hq_ledger_items where item_id=item and ledger_status='LISTED-BACKLOG' for update;
  if not found then raise exception 'Only an active listed DEN may receive a price test'; end if;
  update hq_ledger_items set live_list_price=amount,version=version+1 where item_id=item;
  insert into hq_ledger_events(item_id,event_type,occurred_on,amount,detail,source,external_key)
  values(item,'ADJUSTMENT',current_date,amount,format('Price test recorded: %s zł → %s zł.',coalesce(old_price,0),amount),'MANUAL',nullif(p->>'external_key','')) returning id into event_id;
  return jsonb_build_object('event_id',event_id,'old_price',old_price,'price',amount);
end $$;
revoke all on function public.record_hq_price_test_owner(jsonb) from public;
grant execute on function public.record_hq_price_test_owner(jsonb) to authenticated;
