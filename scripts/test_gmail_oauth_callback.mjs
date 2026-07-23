import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const source = await readFile(resolve(import.meta.dirname, '../supabase/functions/hq-gmail-oauth/index.ts'), 'utf8');
assert.match(source, /hq-gmail-sync/, 'OAuth must verify the fresh connection immediately.');
assert.match(source, /new URL\(hqSystemUrl\)/, 'OAuth must send the owner back to HQ System.');
assert.match(source, /Response\.redirect\(destination, 303\)/, 'OAuth callback must use a browser redirect.');
assert.doesNotMatch(source, /MoÃ|zostaÃ/, 'OAuth confirmation must not contain mojibake.');
console.log('Gmail OAuth callback regression checks passed');
