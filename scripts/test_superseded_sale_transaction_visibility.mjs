import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260913120000_hide_superseded_provisional_transactions.sql', import.meta.url),
  'utf8',
);

assert.match(migration, /create or replace view public\.hq_vinted_transaction_current/i);
assert.match(migration, /or exists\s*\([\s\S]*hq_vinted_transaction_message_current[\s\S]*transaction_id\s*=\s*t\.id/i);
assert.match(migration, /t\.canonical_key not like 'gmail:%'/i);
assert.doesNotMatch(migration, /delete\s+from\s+(?:public\.)?hq_(?:ledger|vinted)/i);
assert.match(migration, /record_hq_vinted_daily_quality_report\(\)/i);

console.log('Superseded provisional sale visibility migration test passed.');
