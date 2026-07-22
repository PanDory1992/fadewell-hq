const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
import { VINTED_PARSER_VERSION, nonEmptyLines, parseVintedMail } from './vinted-parser.mjs';

const PARSER_VERSION = VINTED_PARSER_VERSION;
const REDACTION_VERSION = 'v1';
const norm = (v: string | null | undefined) => (v || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();
const decode = (value: string) => new TextDecoder().decode(Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)));
const stripHtml = (value: string) => value
  .replace(/<br\s*\/?\s*>/gi, '\n').replace(/<\/(?:p|div|tr|td|th|h[1-6])\s*>/gi, '\n')
  .replace(/<[^>]*>/g, ' ').replace(/&nbsp;/gi, ' ').replace(/&amp;/gi, '&')
  .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)));
const text = (part: any): string => {
  const own = part?.body?.data && /^text\/(plain|html)$/i.test(part?.mimeType || '')
    ? (part.mimeType.toLowerCase() === 'text/html' ? stripHtml(decode(part.body.data)) : decode(part.body.data)) : '';
  return [own, ...(part?.parts || []).map(text)].filter(Boolean).join('\n');
};
const lines = nonEmptyLines;
const safeNormalizedText = (body: string) => {
  const all = lines(body.replace(/https?:\/\/\S+/gi, '[link redacted]'));
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
const sha256 = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), (byte) => byte.toString(16).padStart(2, '0')).join('');
async function rest(path: string, init: RequestInit = {}) { return fetch(`${url}/rest/v1/${path}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }); }
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
  const response = await rest('hq_email_sync_runs', { method: 'POST', headers: { prefer: 'return=representation' }, body: JSON.stringify({ provider: 'gmail', status: 'RUNNING' }) });
  const rows = await readJson(response, 'Gmail sync run creation');
  return rows[0]?.id as string;
};
const finishSyncRun = async (id: string | null, payload: Record<string, unknown>) => {
  if (!id) return;
  const response = await rest(`hq_email_sync_runs?id=eq.${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(payload) });
  if (!response.ok) console.error('Could not finish Gmail sync run', await response.text());
};

Deno.serve(async () => {
  const startedAt = new Date().toISOString();
  let runId: string | null = null;
  let scanned = 0, received = 0, applied = 0, review = 0, noise = 0;
  try {
    await patchSyncState({ last_attempt_at: startedAt, last_error: null });
    runId = await createSyncRun();
    const connection = await readJson(await rest('hq_email_connections?provider=eq.gmail&select=refresh_token'), 'Gmail connection lookup');
    if (!connection?.[0]) throw new Error('Gmail is not connected.');
    const state = await readJson(await rest('hq_email_sync_state?provider=eq.gmail&select=started_at'), 'Gmail baseline lookup');
    if (!state?.[0]?.started_at) throw new Error('Gmail baseline is not set.');
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: connection[0].refresh_token, client_id: Deno.env.get('GMAIL_CLIENT_ID')!, client_secret: Deno.env.get('GMAIL_CLIENT_SECRET')! }) });
    const token = await readJson(tokenResponse, 'Gmail token refresh');
    if (!token.access_token) throw new Error('Gmail token refresh returned no access token.');
    const gmail = async (path: string) => readJson(await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`, { headers: { authorization: `Bearer ${token.access_token}` } }), `Gmail API ${path.split('?')[0]}`);
    const after = Math.floor(new Date(state[0].started_at).getTime() / 1000);
    const refs: Array<{ id: string }> = [];
    let pageToken = '';
    do {
      const params = new URLSearchParams({ q: `from:no-reply@vinted.pl after:${after}`, maxResults: '100' });
      if (pageToken) params.set('pageToken', pageToken);
      const listing = await gmail(`messages?${params.toString()}`);
      refs.push(...(listing.messages || []));
      pageToken = listing.nextPageToken || '';
    } while (pageToken);
    const ledger = await readJson(await rest('hq_ledger_items?select=item_id,name,live_title,ledger_status&limit=1000'), 'HQ ledger lookup');
    scanned = refs.length;
    for(const ref of refs) {
    const message=await gmail(`messages/${ref.id}?format=full`); const h=(name:string)=>message.payload.headers.find((x:any)=>x.name?.toLowerCase()===name)?.value||''; const subject=h('subject'), from=h('from'), body=text(message.payload); const trusted=/(?:^|<)no-reply@vinted\.pl>?\s*$/i.test(from.trim()); const receivedAt=new Date(Number(message.internalDate)).toISOString();
    const parsed=trusted?parseVintedMail({subject,body}):parseVintedMail({subject:'',body:''});
    const event_type=parsed.event_type,item_title=parsed.item_title,amount=parsed.amount,transaction=parsed.transaction_id,bundleItems=parsed.bundle_items;
    // A machine may book a sale only against a DEN that is actually LISTED on Vinted.
    // LISTED-BACKLOG, not merely "not SOLD" - an unlisted item can never be auto-sold.
    const matches=ledger.filter((i:any)=>i.ledger_status==='LISTED-BACKLOG'&&[i.live_title,i.name].some((v:string)=>norm(v)&&norm(v)===norm(item_title))); const item=matches.length===1?matches[0]:null; const isShippingLabel=parsed.template_id==='shipping_label_subject_v1';
    const auto=(event_type==='PURCHASE_CONFIRMED'&&!!item_title&&amount!==null)||(event_type==='PURCHASE_BUNDLE'&&bundleItems.length>1&&amount!==null)||(event_type==='SALE_PENDING'&&!!item&&amount!==null&&amount>0)||event_type==='SALE_CONFIRMED';
    const eventState=(event_type==='NOISE'||isShippingLabel)?'AUTO_DISMISSED':auto?'AUTO_APPLIED':'NEEDS_REVIEW';
    const normalizedBody=safeNormalizedText(body);
    const extractedFields={...parsed.fields,template_id:{value:parsed.template_id,status:'CONFIRMED'},gmail_thread_id:{value:message.threadId,status:'CONFIRMED'},received_at:{value:receivedAt,status:'CONFIRMED'}};
    const evidence={gmail_message_id:ref.id,gmail_thread_id:message.threadId,vinted_transaction_id:transaction,sender:from,subject,received_at:receivedAt,normalized_body:normalizedBody,normalized_body_sha256:await sha256(normalizedBody),redaction_version:REDACTION_VERSION,parser_version:PARSER_VERSION,event_type,extracted_fields:extractedFields};
    const evidenceResponse=await rest('rpc/record_hq_gmail_evidence',{method:'POST',body:JSON.stringify({p:evidence})}); if(!evidenceResponse.ok) throw new Error(`Gmail evidence ${ref.id} was not recorded: ${await evidenceResponse.text()}`);
    const event={
      source_event_id:ref.id,event_type,state:eventState,occurred_on:receivedAt.slice(0,10),
      item_title:item_title||null,amount,vinted_transaction_id:transaction,matched_item_id:item?.item_id||null,
      bundle_items:bundleItems,
      evidence:{
        subject,from,gmail_message_id:ref.id,gmail_thread_id:message.threadId,parser_version:PARSER_VERSION,
        body_sha256:evidence.normalized_body_sha256,bundle_item_count:bundleItems.length||null,
        bundle_item_titles:bundleItems.length?bundleItems:null,template_id:parsed.template_id
      }
    };
    const response=await rest('rpc/apply_hq_gmail_intake',{method:'POST',body:JSON.stringify({p:event})}); if(!response.ok) throw new Error(`Gmail event ${ref.id} was not recorded: ${await response.text()}`); const outcome=await response.json();
    const transactionResponse=await rest('rpc/reconcile_hq_vinted_transaction_message',{method:'POST',body:JSON.stringify({p_message_id:ref.id})}); if(!transactionResponse.ok) throw new Error(`Vinted transaction evidence ${ref.id} was not reconciled: ${await transactionResponse.text()}`);
    if(!outcome.duplicate){received++;if(outcome.state==='AUTO_APPLIED')applied++;else if(outcome.state==='AUTO_DISMISSED')noise++;else review++;}
    }
    const finishedAt = new Date().toISOString();
    await patchSyncState({ last_success_at: finishedAt, last_finished_at: finishedAt, last_error: null, last_scanned_count: scanned, last_received_count: received, last_applied_count: applied, last_review_count: review, last_noise_count: noise });
    await finishSyncRun(runId, { status: 'SUCCEEDED', finished_at: finishedAt, scanned_count: scanned, received_count: received, applied_count: applied, review_count: review, noise_count: noise, error: null });
    return Response.json({ scanned, received, applied, review, noise });
  } catch (error) {
    const finishedAt = new Date().toISOString();
    const message = String(error instanceof Error ? error.message : error).slice(0, 2000);
    console.error('Gmail sync failed', message);
    try { await patchSyncState({ last_finished_at: finishedAt, last_error: message, last_scanned_count: scanned, last_received_count: received, last_applied_count: applied, last_review_count: review, last_noise_count: noise }); } catch (healthError) { console.error('Could not record Gmail sync failure', String(healthError)); }
    await finishSyncRun(runId, { status: 'FAILED', finished_at: finishedAt, scanned_count: scanned, received_count: received, applied_count: applied, review_count: review, noise_count: noise, error: message });
    return Response.json({ error: message, scanned, received, applied, review, noise }, { status: 500 });
  }
});
