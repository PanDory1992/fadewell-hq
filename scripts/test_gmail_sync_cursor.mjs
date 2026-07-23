import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const source = await readFile(resolve(import.meta.dirname, '../supabase/functions/hq-gmail-sync/index.ts'), 'utf8');
assert.match(source, /started_at,last_success_at/, 'The sync must read its successful cursor.');
assert.match(source, /last_success_at \|\| state\[0\]\.started_at/, 'The first run needs the baseline; later runs need the last success.');
assert.match(source, /status=eq\.RUNNING/, 'A manual click must not overlap an active sync.');
assert.match(source, /already_running/, 'An overlapping click must return a clear non-error state.');
console.log('Gmail sync cursor regression checks passed');
