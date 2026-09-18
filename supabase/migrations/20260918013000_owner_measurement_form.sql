-- Authenticated HQ form for exact, owner-confirmed Storefront measurements.
-- This merges field-level facts and evidence; it never edits Vinted content.
create or replace function public.update_hq_owner_measurements(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item text := nullif(btrim(p->>'item_id'), '');
  supplied jsonb := coalesce(p->'measurements', '{}'::jsonb);
  event_key text := nullif(btrim(p->>'external_key'), '');
  current_dna jsonb;
  current_facts jsonb;
  current_evidence jsonb;
  confirmed jsonb := '{}'::jsonb;
  confirmations jsonb := '{}'::jsonb;
  measurement record;
  value_cm numeric;
  minimum_cm numeric;
  maximum_cm numeric;
  display_cm text;
begin
  if not public.claim_first_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if item is null then raise exception 'Known DEN Item_ID required'; end if;
  if jsonb_typeof(supplied) <> 'object' or supplied = '{}'::jsonb then
    raise exception 'At least one measurement is required';
  end if;
  if event_key is null then raise exception 'Measurement external key required'; end if;
  if exists(select 1 from public.hq_ledger_events where external_key = event_key) then
    return jsonb_build_object('duplicate', true, 'item_id', item);
  end if;

  select item_dna into current_dna
  from public.hq_ledger_items
  where item_id = item
  for update;
  if not found then raise exception 'Known DEN Item_ID required'; end if;

  for measurement in select key, value from jsonb_each(supplied) loop
    if measurement.key not in ('waist','rise','inseam','leg_opening','overall_length') then
      raise exception 'Unsupported measurement: %', measurement.key;
    end if;
    if jsonb_typeof(measurement.value) <> 'number' then
      raise exception 'Measurement % must be one numeric cm value', measurement.key;
    end if;
    value_cm := round((measurement.value #>> '{}')::numeric, 2);
    minimum_cm := case measurement.key
      when 'waist' then 20 when 'rise' then 15 when 'inseam' then 30
      when 'leg_opening' then 8 when 'overall_length' then 50 end;
    maximum_cm := case measurement.key
      when 'waist' then 80 when 'rise' then 60 when 'inseam' then 130
      when 'leg_opening' then 60 when 'overall_length' then 150 end;
    if value_cm < minimum_cm or value_cm > maximum_cm then
      raise exception 'Measurement % must be between % and % cm', measurement.key, minimum_cm, maximum_cm;
    end if;
    display_cm := to_char(value_cm, 'FM999990.##') || ' cm';
    confirmed := confirmed || jsonb_build_object(measurement.key, jsonb_build_object(
      'cm', value_cm, 'min_cm', value_cm, 'max_cm', value_cm,
      'display', display_cm, 'source', 'OWNER_CONFIRMED'
    ));
    confirmations := confirmations || jsonb_build_object(measurement.key, jsonb_build_object(
      'cm', value_cm, 'confirmed_at', now(), 'source', 'OWNER_HQ_FORM',
      'external_key', event_key
    ));
  end loop;

  current_dna := coalesce(current_dna, '{}'::jsonb);
  current_facts := coalesce(current_dna->'facts', '{}'::jsonb);
  current_facts := jsonb_set(
    current_facts,
    '{measurements}',
    coalesce(current_facts->'measurements', '{}'::jsonb) || confirmed,
    true
  );
  current_evidence := coalesce(current_dna->'evidence', '{}'::jsonb);
  current_evidence := jsonb_set(
    current_evidence,
    '{owner_measurement_confirmations}',
    coalesce(current_evidence->'owner_measurement_confirmations', '{}'::jsonb) || confirmations,
    true
  );

  update public.hq_ledger_items
  set item_dna = jsonb_set(
        jsonb_set(current_dna, '{facts}', current_facts, true),
        '{evidence}', current_evidence, true
      ) || jsonb_build_object('schema_version', 1, 'updated_at', now(), 'updated_by', auth.uid()),
      item_dna_updated_at = now(),
      version = version + 1
  where item_id = item;

  insert into public.hq_ledger_events(item_id,event_type,occurred_on,detail,source,external_key)
  values(
    item,'ADJUSTMENT',current_date,
    'Owner confirmed Storefront measurements in HQ. Vinted content and accounting amounts were not changed.',
    'MANUAL',event_key
  );
  return jsonb_build_object('duplicate', false, 'item_id', item, 'measurements', confirmed);
end
$$;

revoke all on function public.update_hq_owner_measurements(jsonb) from public, anon;
grant execute on function public.update_hq_owner_measurements(jsonb) to authenticated, service_role;
