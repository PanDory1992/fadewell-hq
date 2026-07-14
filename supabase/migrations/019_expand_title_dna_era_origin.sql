-- Extend the literal-title parser only. No year/origin is inferred from style,
-- model, tags or photographs.
create or replace function public.auto_fill_dna_from_new_listing_title()
returns trigger language plpgsql security definer set search_path=public as $$
declare title text:=coalesce(new.live_title,''); lower_title text:=lower(coalesce(new.live_title,'')); old_facts jsonb:=coalesce(new.item_dna->'facts','{}'::jsonb); inferred jsonb:='{}'::jsonb; model_match text[]; size_match text[]; era_match text[];
begin
  if new.listed_on is null or btrim(title)='' then return new; end if;
  if lower_title ~ '\m(levi''s|levis)\M' then inferred:=inferred||jsonb_build_object('brand','Levi''s'); elsif lower_title ~ '\mlee\M' then inferred:=inferred||jsonb_build_object('brand','Lee'); elsif lower_title ~ '\mgap\M' then inferred:=inferred||jsonb_build_object('brand','GAP'); end if;
  model_match:=regexp_match(lower_title,'\m(501|505|508|511|517|550)\M'); if model_match is not null then inferred:=inferred||jsonb_build_object('model',model_match[1]); end if;
  size_match:=regexp_match(upper(title),'\m(W[0-9]{2}\s*L[0-9]{2})\M'); if size_match is not null then inferred:=inferred||jsonb_build_object('tagged_size',regexp_replace(size_match[1],'\s+',' ','g')); end if;
  era_match:=regexp_match(lower_title,'\m((?:19|20)[0-9]{2}|(?:19|20)[0-9]s)\M'); if era_match is not null then inferred:=inferred||jsonb_build_object('era',era_match[1]); end if;
  if lower_title ~ '\mmade in usa\M|\busa\b' then inferred:=inferred||jsonb_build_object('origin','USA'); elsif lower_title ~ '\mmade in japan\M|\bjapan-made\M|\bjapan\b' then inferred:=inferred||jsonb_build_object('origin','Japan'); elsif lower_title ~ '\mmade in mexico\M|\bmexico\b' then inferred:=inferred||jsonb_build_object('origin','Mexico'); elsif lower_title ~ '\mmade in poland\M|\bpoland\b' then inferred:=inferred||jsonb_build_object('origin','Poland'); end if;
  if lower_title ~ '\mstraight\M' then inferred:=inferred||jsonb_build_object('fit','straight'); elsif lower_title ~ '\mtapered?\M' then inferred:=inferred||jsonb_build_object('fit','tapered'); elsif lower_title ~ '\mboot ?cut\M' then inferred:=inferred||jsonb_build_object('fit','bootcut'); end if;
  if inferred='{}'::jsonb then return new; end if;
  new.item_dna:=jsonb_build_object('schema_version',1,'facts',old_facts||inferred,'evidence',coalesce(new.item_dna->'evidence','{}'::jsonb)||jsonb_build_object('auto_from_listing_title',title,'source','VINTED_TITLE'),'updated_at',now(),'updated_by','SYSTEM'); new.item_dna_updated_at:=now(); return new;
end $$;
update public.hq_ledger_items set live_title=live_title where ledger_status='LISTED-BACKLOG' and nullif(btrim(live_title),'') is not null;
