import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {
  MEASUREMENT_FIELDS,
  buildOwnerMeasurementPayload,
  existingOwnerMeasurements,
} from './owner-measurements.js';

assert.deepEqual(MEASUREMENT_FIELDS.map(field=>field.key),[
  'waist','rise','inseam','leg_opening','overall_length',
]);

assert.deepEqual(buildOwnerMeasurementPayload({
  waist:'42',rise:'29,5',inseam:'',leg_opening:'20',overall_length:'109',
}),{waist:42,rise:29.5,leg_opening:20,overall_length:109});

assert.throws(
  ()=>buildOwnerMeasurementPayload({overall_length:'200'}),
  /Długość całkowita.*50.*150/,
);
assert.throws(()=>buildOwnerMeasurementPayload({waist:'abc'}),/Talia/);
assert.throws(()=>buildOwnerMeasurementPayload({rise:'29-30'}),/Stan z przodu/);

assert.deepEqual(existingOwnerMeasurements({measurements:{
  waist:{cm:42,source:'OWNER_CONFIRMED'},
  rise:{cm:29,source:'VINTED_DESCRIPTION'},
  overall_length:{cm:109,source:'OWNER_CONFIRMED'},
}}),{waist:'42',rise:'',inseam:'',leg_opening:'',overall_length:'109'});

const [page,storefront,migration]=await Promise.all([
  readFile(new URL('./item-dna.html',import.meta.url),'utf8'),
  readFile(new URL('./storefront.html',import.meta.url),'utf8'),
  readFile(new URL('../supabase/migrations/20260918013000_owner_measurement_form.sql',import.meta.url),'utf8'),
]);
assert.match(page,/update_hq_owner_measurements/);
assert.match(page,/Storefront pobierze je automatycznie/);
assert.match(storefront,/Uzupełnij pomiary/);
assert.match(storefront,/item-dna\.html\?item=/);
assert.match(migration,/claim_first_hq_owner\(\)/);
assert.match(migration,/source', 'OWNER_CONFIRMED'/);
assert.match(migration,/coalesce\(current_facts->'measurements'.*\|\| confirmed/s);
assert.match(migration,/revoke all on function public\.update_hq_owner_measurements\(jsonb\) from public, anon/);
assert.match(migration,/grant execute on function public\.update_hq_owner_measurements\(jsonb\) to authenticated, service_role/);

console.log('Owner measurement form tests passed');
