-- Only a newly listed DEN may receive literal title-derived DNA.
-- It never overwrites a confirmed field and never infers authenticity, condition,
-- measurements, alterations, rarity, trend or an unstated year.
create or replace function public.auto_fill_dna_from_new_listing_title()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  title text:=coalesce(new.live_title,''); lower_title text:=lower(coalesce(new.live_title,''));
  old_facts jsonb:=coalesce(new.item_dna->'facts','{}'::jsonb); inferred jsonb:='{}'::jsonb;
  model_match text[]; size_match text[];
begin
  if new.listed_on is null or btrim(title)='' then return new; end if;
  if lower_title ~ '\m(levi''s|levis)\M' then inferred:=inferred||jsonb_build_object('brand','Levi''s');
  elsif lower_title ~ '\mlee\M' then inferred:=inferred||jsonb_build_object('brand','Lee');
  elsif lower_title ~ '\mgap\M' then inferred:=inferred||jsonb_build_object('brand','GAP'); end if;
  model_match:=regexp_match(lower_title,'\m(501|505|508|511|517|550)\M'); if model_match is not null then inferred:=inferred||jsonb_build_object('model',model_match[1]); end if;
  size_match:=regexp_match(upper(title),'\m(W[0-9]{2}\s*L[0-9]{2})\M'); if size_match is not null then inferred:=inferred||jsonb_build_object('tagged_size',regexp_replace(size_match[1],'\s+',' ','g')); end if;
  if lower_title ~ '\mmade in usa\M|\busa\b' then inferred:=inferred||jsonb_build_object('origin','USA'); end if;
  if lower_title ~ '\mstraight\M' then inferred:=inferred||jsonb_build_object('fit','straight'); elsif lower_title ~ '\mtapered?\M' then inferred:=inferred||jsonb_build_object('fit','tapered'); elsif lower_title ~ '\mboot ?cut\M' then inferred:=inferred||jsonb_build_object('fit','bootcut'); end if;
  if lower_title ~ '\bdark (blue|indigo)\b' then inferred:=inferred||jsonb_build_object('wash','dark indigo'); elsif lower_title ~ '\bblack\b' then inferred:=inferred||jsonb_build_object('wash','black'); elsif lower_title ~ '\bmedium blue\b' then inferred:=inferred||jsonb_build_object('wash','medium blue'); end if;
  if inferred='{}'::jsonb then return new; end if;
  new.item_dna:=jsonb_build_object('schema_version',1,'facts',old_facts||inferred,'evidence',coalesce(new.item_dna->'evidence','{}'::jsonb)||jsonb_build_object('auto_from_listing_title',title,'source','VINTED_TITLE'),'updated_at',now(),'updated_by','SYSTEM');
  new.item_dna_updated_at:=now();
  return new;
end $$;
drop trigger if exists hq_auto_dna_from_new_listing_title on public.hq_ledger_items;
create trigger hq_auto_dna_from_new_listing_title before update on public.hq_ledger_items for each row execute function public.auto_fill_dna_from_new_listing_title();

-- One safe backfill pass for already-listed DEN items. Existing manual facts win.
update public.hq_ledger_items set live_title=live_title where ledger_status='LISTED-BACKLOG' and nullif(btrim(live_title),'') is not null;
