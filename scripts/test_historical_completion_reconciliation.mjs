import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260913112500_reconcile_historical_completion_sales.sql', import.meta.url),
  'utf8',
);

assert.match(migration, /p\.event_type\s*=\s*'SALE_CONFIRMED'/i);
assert.match(migration, /count\(distinct item_id\)\s*=\s*1/i);
assert.match(migration, /count\(distinct ledger_event_id\)\s*=\s*1/i);
assert.match(migration, /le\.occurred_on\s+between\s+gm\.received_at::date\s*-\s*31\s+and\s+gm\.received_at::date/i);
assert.match(migration, /insert into public\.hq_vinted_transaction_state_events/i);
assert.match(migration, /'CASH_CONFIRMED'/i);
assert.doesNotMatch(migration, /(?:insert|update|delete)\s+(?:into\s+|from\s+)?public\.hq_ledger_(?:events|items)/i);

console.log('Historical completion reconciliation migration test passed.');
