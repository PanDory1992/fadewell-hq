import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../supabase/functions/hq-gmail-ingest/index.ts', import.meta.url), 'utf8');

assert.match(source, /createRemoteJWKSet/, 'the intake must verify the Google identity token signature');
assert.match(source, /jwtVerify/, 'the intake must validate Google identity-token claims');
assert.match(source, /accounts\.google\.com/, 'the intake must restrict the token issuer to Google');
assert.match(source, /falka\.falka35@gmail\.com/, 'the intake must accept only the owner mailbox');
assert.match(source, /authorization/i, 'the intake must authenticate the Apps Script request');
assert.match(source, /isTrustedVintedSender/, 'the server must enforce the Vinted sender boundary');
assert.match(source, /record_hq_gmail_evidence/, 'the existing immutable evidence path must be preserved');
assert.match(source, /apply_hq_gmail_intake/, 'the existing guarded ledger intake must be preserved');
assert.match(source, /reconcile_hq_manual_sale_evidence/, 'manual-sale reconciliation must remain active');
assert.match(source, /reconcile_hq_vinted_transaction_message/, 'transaction reconciliation must remain active');
assert.doesNotMatch(source, /GMAIL_CLIENT_ID|GMAIL_CLIENT_SECRET|refresh_token/, 'the new transport must not depend on a custom Google Cloud OAuth client');
assert.doesNotMatch(source, /GMAIL_APPS_SCRIPT_SECRET/, 'the transport must not add a long-lived shared secret');

const appsScript = await readFile(new URL('../apps-script/gmail-intake/Code.gs', import.meta.url), 'utf8');
assert.match(appsScript, /everyMinutes\(5\)/, 'the intake trigger must run every five minutes');
assert.match(appsScript, /LockService/, 'overlapping trigger executions must be prevented');
assert.match(appsScript, /from:no-reply@vinted\.pl/, 'the Gmail query must stay sender-scoped');
assert.match(appsScript, /HQ_INTAKE_CURSOR_MS/, 'the script must keep a replay-safe cursor');
assert.match(appsScript, /ScriptApp\.getIdentityToken\(\)/, 'the script must use a short-lived Google identity token');

const manifest = await readFile(new URL('../apps-script/gmail-intake/appsscript.json', import.meta.url), 'utf8');
const manifestJson = JSON.parse(manifest);
assert.ok(manifestJson.oauthScopes.includes('openid'), 'the manifest must request an OpenID identity token');
assert.ok(manifestJson.oauthScopes.includes('https://www.googleapis.com/auth/userinfo.email'), 'the identity token must include the verified mailbox email');

const systemPage = await readFile(new URL('../web/system.html', import.meta.url), 'utf8');
assert.match(systemPage, /Automatyczny odczyt Apps Script działa co 5 minut/, 'HQ System must describe the active Apps Script transport');
assert.doesNotMatch(systemPage, /hq-gmail-oauth\/authorize/, 'HQ System must not offer the retired OAuth connection');
assert.doesNotMatch(systemPage, /functions\/v1\/hq-gmail-sync/, 'HQ System must not invoke the retired OAuth poller');
assert.doesNotMatch(systemPage, /Połącz Gmail/, 'HQ System must not tell the owner to reconnect the retired integration');

console.log('Gmail ingest boundary contract checks passed');
