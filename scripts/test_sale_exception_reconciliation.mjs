import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(new URL('../supabase/migrations/062_reconcile_sale_cash_exceptions.sql', import.meta.url), 'utf8');
const operations = fs.readFileSync(new URL('../web/operations.html', import.meta.url), 'utf8');
const hq = fs.readFileSync(new URL('../web/hq.js', import.meta.url), 'utf8');

assert.match(migration, /bridge\.link_method='SAFE_TITLE_DEN'/);
assert.match(migration, /pending\.canonical_key='gmail:'\|\|bridge\.gmail_message_id/);
assert.match(migration, /pending\.id,'CASH_CONFIRMED'/);
assert.match(migration, /on conflict do nothing/);
assert.match(migration, /select public\.record_hq_vinted_transaction_states\(\);/);
assert.doesNotMatch(migration, /apply_hq_ledger_action|insert into hq_ledger_events/i);
assert.match(operations, /row\.item_title/);
assert.match(operations, /mail\.google\.com\/mail\/u\/0\/\#all/);
assert.match(operations, /hq\.js\?v=20260820-hidden-missing/);
assert.match(hq, /fadewell-hq-data-v5/);

console.log('sale exception reconciliation checks passed');
