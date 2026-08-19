import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20260819201500_storefront_visibility_actions.sql', import.meta.url), 'utf8');
const actions = await readFile(new URL('../web/actions.html', import.meta.url), 'utf8');

assert.match(migration, /storefront_hidden boolean not null default false/);
assert.match(migration, /using \(published and public\.is_fadewell_storefront_visible\(vinted_item_id\)\)/);
assert.match(migration, /set_hq_storefront_visibility_owner/);
assert.match(migration, /STOREFRONT_HIDE/);
assert.match(migration, /STOREFRONT_REVEAL/);
assert.match(migration, /HQ owner access required/);
assert.match(actions, /STOREFRONT_HIDE/);
assert.match(actions, /STOREFRONT_REVEAL/);
assert.match(actions, /set_hq_storefront_visibility_owner/);
console.log('Storefront visibility action regression checks passed');
