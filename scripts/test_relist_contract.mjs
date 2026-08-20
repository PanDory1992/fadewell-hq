import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const operations=readFileSync(new URL('../web/operations.html',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/migrations/065_relist_pending_state_machine.sql',import.meta.url),'utf8');
const correction=readFileSync(new URL('../supabase/migrations/20260820143000_correct_relist_identity_and_title_provenance.sql',import.meta.url),'utf8');
const edge=readFileSync(new URL('../supabase/functions/hq-vinted-collector/index.ts',import.meta.url),'utf8');
const sharedResolver=readFileSync(new URL('../supabase/functions/_shared/vinted-resolver.ts',import.meta.url),'utf8');
const hq=readFileSync(new URL('../web/hq.js',import.meta.url),'utf8');
const ledger=readFileSync(new URL('../web/ledger.html',import.meta.url),'utf8');

assert.match(operations,/RELIST PENDING/,'Operations must surface a persisted relist candidate as one relist decision.');
assert.match(operations,/relistPairs\.map\(relistPairCard\)/,'Operations must render paired relists as one action.');
assert.match(operations,/old_vinted_item_id:previousId,new_vinted_item_id:String\(vintedId\)/,'The owner action must send an explicit old-to-new transition.');
assert.match(operations,/item\?\.ledger_status!=='UNLISTED-BACKLOG'&&!isMissing\(item\)/,'The fallback DEN selector must retain missing listed items for a relist.');
assert.match(migration,/limit 2[\s\S]*new_cycle_count < 2/,'The database must require two complete snapshots.');
assert.match(migration,/hq_vinted_listing_lineage/,'Both relist paths must retain listing lineage.');
assert.match(migration,/current_snapshot\.price_pln/,'Live price must come from the verified snapshot.');
assert.match(migration,/hq_vinted_relist_candidates/,'The transition must persist pending and confirmed relist state.');
assert.match(migration,/actor = 'MANUAL' and current_new_count < 1/,'Owner confirmation may proceed after one current complete snapshot.');
assert.match(edge,/apply_hq_system_relist/,'The edge collector must use the atomic system relist RPC.');
assert.match(edge,/resolveNewListings\(live,active\)/,'The edge collector must retry unresolved live listings.');
assert.match(sharedResolver,/item\.live_title/,'The edge resolver must compare against the prior verified live title.');
assert.match(sharedResolver,/item\.manual_title/,'The resolver must compare the last owner title from Ledger.');
assert.match(sharedResolver,/conflictingSize/,'A conflicting waist or length must block automatic identity resolution.');
assert.match(edge,/\.eq\('storefront_hidden',false\)/,'The edge resolver must not auto-relist an owner-hidden DEN.');
assert.match(edge,/tytuł w Ledger przed Vinted/,'Automatic listing events must retain the title transition.');
assert.match(correction,/owner_hidden_requires_manual_resolution/,'The database must reject a stale system relist for an owner-hidden DEN.');
assert.match(correction,/DEN-274/,'The production identity correction must be tracked as a guarded migration.');
assert.match(hq,/Tytuł przed Vinted/,'The item card must expose the last Ledger title before the live Vinted title.');
assert.match(ledger,/installPreviousTitleProvenance/,'Ledger must install title provenance on item cards.');

console.log('Relist contract regression checks passed');
