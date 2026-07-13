-- Item DNA is operational evidence, not a replacement bookkeeping ledger.
-- Existing flip_tier values remain historical imports and are deliberately untouched.
alter table public.hq_ledger_items
  add column if not exists item_dna jsonb not null default '{}'::jsonb,
  add column if not exists item_dna_updated_at timestamptz;

create or replace function public.update_hq_item_dna_owner(p jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  item text:=nullif(p->>'item_id',''); facts jsonb:=coalesce(p->'facts','{}'::jsonb);
  evidence jsonb:=coalesce(p->'evidence','{}'::jsonb); event_key text:=nullif(p->>'external_key','');
begin
  if not public.claim_first_hq_owner() then raise exception 'HQ owner access required'; end if;
  if item is null or not exists(select 1 from hq_ledger_items where item_id=item) then raise exception 'Known DEN Item_ID required'; end if;
  if jsonb_typeof(facts)<>'object' or jsonb_typeof(evidence)<>'object' then raise exception 'Item DNA facts and evidence must be objects'; end if;
  if event_key is null then raise exception 'Item DNA external key required'; end if;
  if exists(select 1 from hq_ledger_events where external_key=event_key) then return jsonb_build_object('duplicate',true,'item_id',item); end if;
  update hq_ledger_items set item_dna=jsonb_build_object('schema_version',1,'facts',facts,'evidence',evidence,'updated_at',now(),'updated_by',auth.uid()),item_dna_updated_at=now(),version=version+1 where item_id=item;
  insert into hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
  values(item,'ADJUSTMENT',current_date,'Item DNA confirmed or corrected. Evidence is stored with the item profile.','MANUAL',event_key);
  return jsonb_build_object('duplicate',false,'item_id',item);
end $$;
revoke all on function public.update_hq_item_dna_owner(jsonb) from public;
grant execute on function public.update_hq_item_dna_owner(jsonb) to authenticated;
