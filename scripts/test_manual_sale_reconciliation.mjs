import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root=resolve(import.meta.dirname,'..');
const migration=await readFile(resolve(root,'supabase/migrations/046_normalize_apostrophes_in_manual_sale_reconciliation.sql'),'utf8');
const sync=await readFile(resolve(root,'supabase/functions/hq-gmail-sync/index.ts'),'utf8');

assert.match(migration,/event_row\.state<>'NEEDS_REVIEW'/,'Only an open review may be reconciled.');
assert.match(migration,/event_row\.event_type<>'SALE_PENDING'/,'Only pending-sale mail is eligible.');
assert.match(migration,/le\.source='MANUAL'/,'The match must point to an explicit manual sale.');
assert.match(migration,/item\.ledger_status='SOLD'/,'The matched item must already be sold.');
assert.match(migration,/le\.occurred_on=event_row\.occurred_at::date/,'The sale date must match exactly.');
assert.match(migration,/abs\(le\.amount-event_row\.amount\)<=0\.10/,'Only a ten-grosz rounding difference is accepted.');
assert.match(migration,/replace\(replace\(coalesce\(item\.live_title,item\.name,''\),'’',''\),'''',''\)/,'Curly and straight apostrophes must not split an otherwise exact title.');
assert.match(migration,/candidate_count<>1/,'Ambiguous matches must remain open.');
assert.doesNotMatch(migration,/matched_item_id=matched_item_id/,'The update must not confuse a column with a local variable.');
assert.doesNotMatch(migration,/apply_hq_ledger_action/,'Evidence reconciliation must not write a new ledger sale.');
assert.match(sync,/rpc\/reconcile_hq_manual_sale_evidence/,'The Gmail worker must invoke the reconciliation.');
console.log('Manual-sale Gmail reconciliation regression checks passed');
