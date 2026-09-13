import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const migration = await readFile(new URL('supabase/migrations/20260913105000_harden_service_rpcs_and_schedule_critical_workflows.sql', root), 'utf8');
const scheduler = await readFile(new URL('supabase/functions/hq-github-scheduler/index.ts', root), 'utf8');

for (const signature of [
  'apply_hq_gmail_intake(jsonb)',
  'record_hq_gmail_evidence(jsonb)',
  'reconcile_hq_vinted_transaction_message(text)',
  'apply_hq_vinted_transaction_backfill()',
]) {
  assert.match(migration, new RegExp(`revoke all on function public\\.${signature.replace(/[()]/g, '\\$&')}`));
}
assert.match(scheduler, /VINTED_COLLECTOR_CRON_SECRET/, 'the scheduler must require the private cron credential');
assert.match(scheduler, /new Set\(\['storefront-sync\.yml', 'gmail-sync-watchdog\.yml'\]\)/, 'the scheduler workflow allow-list must stay closed');
assert.match(scheduler, /GITHUB_WORKFLOW_DISPATCH_TOKEN/, 'the scheduler must use a server-side GitHub token');

for (const retired of [
  'supabase/functions/hq-gmail-sync/index.ts',
  'supabase/functions/hq-gmail-oauth/index.ts',
]) {
  await assert.rejects(access(new URL(retired, root)), `${retired} must remain retired`);
}

console.log('HQ security boundary checks passed');
