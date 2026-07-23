import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const operations=readFileSync(new URL('../web/operations.html',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/migrations/049_fix_manual_relink_event_encoding.sql',import.meta.url),'utf8');

assert.match(operations,/note:relist\?'':`Operations: potwierdzone połączenie live listingu/,'The browser must not append the relink sentence a second time.');
assert.match(migration,/U&'Operations: r\\0119cznie potwierdzone od\\015Bwie\\017Cenie oferty %s \\2192 %s\.'/,'The database must construct Polish text with Unicode escapes.');
assert.match(migration,/Technical text correction for ledger event 333; no business values changed\./,'The legacy text repair must be append-only and explicit.');
assert.match(migration,/external_key = 'system:manual-relink-text-correction:333'/,'The technical correction must be idempotent.');
assert.match(operations,/technicalCorrectionKey='system:manual-relink-text-correction:333'/,'The technical correction must not clutter operational activity.');
assert.doesNotMatch(migration,/ręcznie|odświeżenie/,'The SQL migration itself must remain encoding-safe.');

console.log('Manual relink encoding regression checks passed');
