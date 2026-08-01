-- Repair the row published before the parser required an explicit measurement label.
-- The retained description states Waist: 39 cm; W29 is the tagged size.
update public.fadewell_storefront_products
set measurements = jsonb_set(
      measurements,
      '{waist}',
      jsonb_build_object('cm', 39, 'display', '39 cm'),
      true
    ),
    publication_notes = coalesce(publication_notes, '{}'::jsonb)
      || jsonb_build_object('waist_correction', 'description_measurement_label'),
    updated_at = now()
where vinted_item_id = '8916337895'
  and measurements #>> '{waist,cm}' in ('29', '29.0')
  and description_raw ilike '%Waist: 39 cm%';
