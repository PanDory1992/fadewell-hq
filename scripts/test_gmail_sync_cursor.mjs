import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const source = await readFile(resolve(import.meta.dirname, '../supabase/functions/hq-gmail-sync/index.ts'), 'utf8');
assert.match(source, /started_at,last_success_at,history_id/, 'The sync must read both the durable Gmail history cursor and its timestamp fallback.');
assert.match(source, /historyTypes:\s*'messageAdded'/, 'Normal runs must use Gmail History message additions, not a completion-time cursor.');
assert.match(source, /if\(!trusted\) continue;/, 'Account-wide Gmail History entries from non-Vinted senders must be discarded before parser or database intake.');
assert.doesNotMatch(source, /trusted\?parseVintedMail/, 'Untrusted mail must not be converted into an empty UNCLASSIFIED review item.');
assert.match(source, /HISTORY_FALLBACK_OVERLAP_SECONDS/, 'An expired history cursor must replay a bounded overlap.');
assert.match(source, /in:anywhere from:no-reply@vinted\.pl after:/, 'Fallback replay must include already-trashed messages and still restrict the sender.');
assert.match(source, /nextHistoryId/, 'The history cursor must advance only after processing succeeds.');
assert.match(source, /status=eq\.RUNNING/, 'A manual click must not overlap an active sync.');
assert.match(source, /already_running/, 'An overlapping click must return a clear non-error state.');
assert.match(source, /messages\/\$\{ref\.id\}\/trash/, 'Confirmation-needed messages must use the Gmail Trash endpoint.');
assert.match(source, /record_hq_gmail_trash_result/, 'Every Gmail Trash attempt must be audited.');
console.log('Gmail sync cursor regression checks passed');
