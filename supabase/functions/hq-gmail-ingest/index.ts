import { VINTED_PARSER_VERSION, nonEmptyLines, parseVintedMail } from '../hq-gmail-sync/vinted-parser.mjs';

const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
const jsonHeaders = { 'content-type': 'application/json; charset=utf-8' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: jsonHeaders });
const REDACTION_VERSION = 'v1';
const MAX_MESSAGES = 50;
const MAX_BODY_LENGTH = 750_000;

type IncomingMessage = {
  gmail_message_id: string;
  gmail_thread_id: string;
  sender: string;
  subject: string;
  received_at: string;
  body: string;
};

const isTrustedVintedSender = (value: string) => /(?:^|<)no-reply@vinted\.pl>?\s*$/i.test(String(value || '').trim());
const norm = (value: string | null | undefined) => (value || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();
const safeNormalizedText = (body: string) => {
  const all = nonEmptyLines(body.replace(/https?:\/\/\S+/gi, '[link redacted]'));
  const safe: string[] = []; let redactAddressBlock = false; let redactSeller = false;
  for (const line of all) {
    if (/^Vinted,\s*UAB$/i.test(line)) { redactAddressBlock = true; continue; }
    if (redactAddressBlock && /^Item price\s*:/i.test(line)) redactAddressBlock = false;
    if (redactAddressBlock) continue;
    if (/^Seller$/i.test(line)) { safe.push(line); redactSeller = true; continue; }
    if (redactSeller) { safe.push('[seller redacted]'); redactSeller = false; continue; }
    if (/^Hello\s+/i.test(line)) { safe.push('Hello [account redacted]'); continue; }
    if (/^[^,]+, your sale is complete\.?$/i.test(line)) { safe.push('[buyer redacted], your sale is complete.'); continue; }
    if (/^.+\s+has bought$/i.test(line)) { safe.push('[buyer redacted] has bought'); continue; }
    safe.push(line.replace(/\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b/g, '[email redacted]'));
  }
  return safe.join('\n');
};
const sha256 = async (value: string) => Array.from(
  new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))),
  byte => byte.toString(16).padStart(2, '0')
).join('');
async function rest(path: string, init: RequestInit = {}) {
  return fetch(`${url}/rest/v1/${path}`, { ...init, headers: { ...headers, ...(init.headers || {}) } });
}
const readJson = async (response: Response, label: string) => {
  const payload = await response.json();
  if (!response.ok) throw new Error(`${label} failed: ${typeof payload === 'string' ? payload : JSON.stringify(payload)}`);
  return payload;
};
const patchSyncState = async (payload: Record<string, unknown>) => {
  const response = await rest('hq_email_sync_state?provider=eq.gmail', { method: 'PATCH', body: JSON.stringify(payload) });
  if (!response.ok) throw new Error(`Could not update Gmail sync health: ${await response.text()}`);
};
const createSyncRun = async () => {
  const response = await rest('hq_email_sync_runs', {
    method: 'POST', headers: { prefer: 'return=representation' },
    body: JSON.stringify({ provider: 'gmail', status: 'RUNNING' })
  });
  const rows = await readJson(response, 'Gmail ingest run creation');
  return rows[0]?.id as string;
};
const finishSyncRun = async (id: string | null, payload: Record<string, unknown>) => {
  if (!id) return;
  const response = await rest(`hq_email_sync_runs?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(payload) });
  if (!response.ok) console.error('Could not finish Gmail ingest run', await response.text());
};
const validateMessage = (value: unknown): IncomingMessage => {
  if (!value || typeof value !== 'object') throw new Error('Each Gmail message must be an object.');
  const message = value as Record<string, unknown>;
  const required = ['gmail_message_id', 'gmail_thread_id', 'sender', 'subject', 'received_at', 'body'];
  for (const field of required) if (typeof message[field] !== 'string' || !message[field]) throw new Error(`Missing Gmail message field: ${field}`);
  if (!/^[a-zA-Z0-9_-]{6,200}$/.test(String(message.gmail_message_id))) throw new Error('Invalid Gmail message ID.');
  if (!isTrustedVintedSender(String(message.sender))) throw new Error('Only no-reply@vinted.pl messages are accepted.');
  if (String(message.body).length > MAX_BODY_LENGTH) throw new Error('Gmail message body is too large.');
  const received = new Date(String(message.received_at));
  if (!Number.isFinite(received.getTime())) throw new Error('Invalid Gmail received_at value.');
  if (received.getTime() > Date.now() + 5 * 60 * 1000) throw new Error('Gmail received_at cannot be in the future.');
  return message as IncomingMessage;
};

Deno.serve(async request => {
  if (request.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);
  const authorization = request.headers.get('authorization') || '';
  if (!/^Bearer\s+\S+$/i.test(authorization)) return reply({ error: 'Unauthorized.' }, 401);
  const identityResponse = await fetch('https://openidconnect.googleapis.com/v1/userinfo', { headers: { authorization } });
  if (!identityResponse.ok) return reply({ error: 'Google identity verification failed.' }, 401);
  const identity = await identityResponse.json();
  if (identity.email !== 'falka.falka35@gmail.com' || identity.email_verified !== true) return reply({ error: 'Unauthorized Gmail account.' }, 403);

  const startedAt = new Date().toISOString();
  let runId: string | null = null;
  let scanned = 0, received = 0, applied = 0, review = 0, noise = 0;
  try {
    const payload = await request.json();
    if (payload?.source !== 'fadewell_apps_script_v1') throw new Error('Unknown Gmail intake source.');
    if (!Array.isArray(payload.messages) || payload.messages.length > MAX_MESSAGES) throw new Error(`messages must contain at most ${MAX_MESSAGES} entries.`);
    const messages = payload.messages.map(validateMessage);
    if (new Set(messages.map(message => message.gmail_message_id)).size !== messages.length) throw new Error('Duplicate Gmail message IDs in one batch.');

    await patchSyncState({ last_attempt_at: startedAt, last_error: null });
    runId = await createSyncRun();
    const ledger = await readJson(await rest('hq_ledger_items?select=item_id,name,live_title,ledger_status&limit=1000'), 'HQ ledger lookup');
    scanned = messages.length;

    for (const message of messages) {
      const parsed = parseVintedMail({ subject: message.subject, body: message.body });
      const eventType = parsed.event_type, itemTitle = parsed.item_title, amount = parsed.amount;
      const transaction = parsed.transaction_id, bundleItems = parsed.bundle_items;
      const matches = ledger.filter((item: any) => item.ledger_status === 'LISTED-BACKLOG' && [item.live_title, item.name].some((value: string) => norm(value) && norm(value) === norm(itemTitle)));
      const item = matches.length === 1 ? matches[0] : null;
      const isShippingLabel = parsed.template_id === 'shipping_label_subject_v1';
      const auto = (eventType === 'PURCHASE_CONFIRMED' && !!itemTitle && amount !== null)
        || (eventType === 'PURCHASE_BUNDLE' && bundleItems.length > 1 && amount !== null)
        || (eventType === 'SALE_PENDING' && !!item && amount !== null && amount > 0)
        || eventType === 'SALE_CONFIRMED';
      const eventState = (eventType === 'NOISE' || isShippingLabel) ? 'AUTO_DISMISSED' : auto ? 'AUTO_APPLIED' : 'NEEDS_REVIEW';
      const normalizedBody = safeNormalizedText(message.body);
      const bodyHash = await sha256(normalizedBody);
      const extractedFields = {
        ...parsed.fields,
        template_id: { value: parsed.template_id, status: 'CONFIRMED' },
        gmail_thread_id: { value: message.gmail_thread_id, status: 'CONFIRMED' },
        received_at: { value: message.received_at, status: 'CONFIRMED' }
      };
      const evidence = {
        gmail_message_id: message.gmail_message_id,
        gmail_thread_id: message.gmail_thread_id,
        vinted_transaction_id: transaction,
        sender: message.sender,
        subject: message.subject,
        received_at: message.received_at,
        normalized_body: normalizedBody,
        normalized_body_sha256: bodyHash,
        redaction_version: REDACTION_VERSION,
        parser_version: VINTED_PARSER_VERSION,
        event_type: eventType,
        extracted_fields: extractedFields
      };
      const evidenceResponse = await rest('rpc/record_hq_gmail_evidence', { method: 'POST', body: JSON.stringify({ p: evidence }) });
      if (!evidenceResponse.ok) throw new Error(`Gmail evidence ${message.gmail_message_id} was not recorded: ${await evidenceResponse.text()}`);
      const event = {
        source_event_id: message.gmail_message_id,
        event_type: eventType,
        state: eventState,
        occurred_on: message.received_at.slice(0, 10),
        item_title: itemTitle || null,
        amount,
        vinted_transaction_id: transaction,
        matched_item_id: item?.item_id || null,
        bundle_items: bundleItems,
        evidence: {
          subject: message.subject,
          from: message.sender,
          gmail_message_id: message.gmail_message_id,
          gmail_thread_id: message.gmail_thread_id,
          parser_version: VINTED_PARSER_VERSION,
          body_sha256: bodyHash,
          bundle_item_count: bundleItems.length || null,
          bundle_item_titles: bundleItems.length ? bundleItems : null,
          template_id: parsed.template_id,
          transport: 'apps_script'
        }
      };
      const intakeResponse = await rest('rpc/apply_hq_gmail_intake', { method: 'POST', body: JSON.stringify({ p: event }) });
      if (!intakeResponse.ok) throw new Error(`Gmail event ${message.gmail_message_id} was not recorded: ${await intakeResponse.text()}`);
      const outcome = await intakeResponse.json();
      let resolvedState = outcome.state;
      if (eventType === 'SALE_PENDING' && outcome.state === 'NEEDS_REVIEW') {
        const reconciliation = await rest('rpc/reconcile_hq_manual_sale_evidence', { method: 'POST', body: JSON.stringify({ p_source_event_id: message.gmail_message_id }) });
        const reconciliationOutcome = await readJson(reconciliation, `Manual-sale reconciliation ${message.gmail_message_id}`);
        resolvedState = reconciliationOutcome.state || resolvedState;
      }
      const transactionResponse = await rest('rpc/reconcile_hq_vinted_transaction_message', { method: 'POST', body: JSON.stringify({ p_message_id: message.gmail_message_id }) });
      if (!transactionResponse.ok) throw new Error(`Vinted transaction evidence ${message.gmail_message_id} was not reconciled: ${await transactionResponse.text()}`);
      if (!outcome.duplicate) {
        received += 1;
        if (resolvedState === 'AUTO_APPLIED') applied += 1;
        else if (resolvedState === 'AUTO_DISMISSED') noise += 1;
        else if (resolvedState === 'NEEDS_REVIEW') review += 1;
      }
    }

    const finishedAt = new Date().toISOString();
    const counts = { last_scanned_count: scanned, last_received_count: received, last_applied_count: applied, last_review_count: review, last_noise_count: noise, last_trashed_count: 0 };
    await patchSyncState({ last_success_at: finishedAt, last_finished_at: finishedAt, last_error: null, ...counts });
    await finishSyncRun(runId, { status: 'SUCCEEDED', finished_at: finishedAt, scanned_count: scanned, received_count: received, applied_count: applied, review_count: review, noise_count: noise, trashed_count: 0, error: null });
    return reply({ ok: true, scanned, received, applied, review, noise });
  } catch (error) {
    const finishedAt = new Date().toISOString();
    const message = String(error instanceof Error ? error.message : error).slice(0, 2000);
    console.error('Apps Script Gmail ingest failed', message);
    try { await patchSyncState({ last_finished_at: finishedAt, last_error: message, last_scanned_count: scanned, last_received_count: received, last_applied_count: applied, last_review_count: review, last_noise_count: noise, last_trashed_count: 0 }); } catch (healthError) { console.error('Could not record Gmail ingest failure', String(healthError)); }
    await finishSyncRun(runId, { status: 'FAILED', finished_at: finishedAt, scanned_count: scanned, received_count: received, applied_count: applied, review_count: review, noise_count: noise, trashed_count: 0, error: message });
    return reply({ error: message, scanned, received, applied, review, noise }, 500);
  }
});
