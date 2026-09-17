import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../apps-script/gmail-intake/Code.gs', import.meta.url), 'utf8');

const makeMessage = ({ id, from = 'Vinted <no-reply@vinted.pl>', date = new Date(Date.now() - 60 * 60 * 1000) }) => ({
  getId: () => id,
  getThread: () => ({ getId: () => `thread-${id}` }),
  getFrom: () => from,
  getSubject: () => `Subject ${id}`,
  getDate: () => date,
  getPlainBody: () => `Body ${id}`,
});

const run = ({ messages = [makeMessage({ id: 'abc123' })], responseCode = 200 } = {}) => {
  const properties = new Map();
  const fetches = [];
  const context = {
    Date,
    JSON,
    Math,
    Error,
    console,
    LockService: { getScriptLock: () => ({ tryLock: () => true, releaseLock: () => {} }) },
    PropertiesService: { getScriptProperties: () => ({
      getProperty: key => properties.get(key) || null,
      setProperty: (key, value) => properties.set(key, String(value)),
      deleteProperty: key => properties.delete(key),
    }) },
    GmailApp: { search: () => [{ getMessages: () => messages }] },
    UrlFetchApp: { fetch: (url, options) => {
      fetches.push({ url, options });
      return { getResponseCode: () => responseCode, getContentText: () => responseCode === 200 ? '{"ok":true}' : '{"error":"failed"}' };
    } },
    ScriptApp: { getIdentityToken: () => 'short-lived-google-identity-token', getProjectTriggers: () => [], newTrigger: () => ({ timeBased: () => ({ everyMinutes: () => ({ create: () => {} }) }) }) },
    Utilities: { sleep: () => {} },
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return { context, properties, fetches };
};

{
  const { context, fetches, properties } = run();
  const result = context.syncVintedMail();
  assert.equal(fetches.length, 1);
  assert.equal(fetches[0].url, 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-gmail-ingest');
  assert.equal(fetches[0].options.headers.Authorization, 'Bearer short-lived-google-identity-token');
  const payload = JSON.parse(fetches[0].options.payload);
  assert.equal(payload.source, 'fadewell_apps_script_v1');
  assert.equal(payload.messages[0].gmail_message_id, 'abc123');
  assert.equal(result.sent, 1);
  assert.ok(Number(properties.get('HQ_INTAKE_CURSOR_MS')) > 0);
}

{
  const { context, fetches } = run({ messages: [
    makeMessage({ id: 'trusted' }),
    makeMessage({ id: 'foreign', from: 'alerts@example.com' }),
  ] });
  context.syncVintedMail();
  const payload = JSON.parse(fetches[0].options.payload);
  assert.deepEqual(payload.messages.map(message => message.gmail_message_id), ['trusted']);
}

{
  const { context, properties } = run({ responseCode: 500 });
  assert.throws(() => context.syncVintedMail(), /failed/);
  assert.equal(properties.has('HQ_INTAKE_CURSOR_MS'), false, 'cursor must not advance after a rejected batch');
}

console.log('Apps Script Gmail intake regression checks passed');
