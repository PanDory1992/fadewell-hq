const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
const PARSER_VERSION = '2026-07-15.step2-evidence.v1';
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
const lines = (body: string) => body.replace(/\r/g, '').split('\n').map((line) => line.replace(/\s+/g, ' ').trim()).filter(Boolean);
const afterLabel = (body: string, label: string) => { const all = lines(body); const at = all.findIndex((line) => norm(line) === norm(label)); return at >= 0 ? all[at + 1] || '' : ''; };
const betweenLabels = (body: string, start: string, end: string) => { const all = lines(body); const at = all.findIndex((line) => norm(line) === norm(start)); const stop = at < 0 ? -1 : all.slice(at + 1).findIndex((line) => norm(line) === norm(end)); return at < 0 ? [] : all.slice(at + 1, stop < 0 ? undefined : at + 1 + stop).filter(Boolean); };
const money = (body: string, label: string) => { const value = afterLabel(body, label); const m = value.match(/([0-9]+[.,][0-9]+)/); const n = Number((m?.[1] || '').replace(',', '.')); return Number.isFinite(n) && n > 0 ? n : null; };
const transactionId = (body: string) => body.match(/Transaction ID\s*:?\s*#?(\d+)/i)?.[1] || afterLabel(body, 'Transaction ID').match(/\d+/)?.[0] || null;
const completedSaleTitle = (body: string) => body.match(/Your sale of\s+([\s\S]*?)\s+was completed successfully/i)?.[1]?.replace(/\s+/g, ' ').trim() || '';
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
const field = (value: unknown, status: 'CONFIRMED' | 'PARTIAL' | 'MISSING' = 'CONFIRMED') => ({ value: value ?? null, status: value === null || value === undefined || value === '' ? 'MISSING' : status });
// Known Vinted non-accounting mail. Recorded as auditable evidence, never queued
// for a human, never touches the Ledger. An UNKNOWN subject must still fall
// through to UNCLASSIFIED / NEEDS_REVIEW: fail toward review, not toward silence.
const NOISE = /(shipping label|etykiet[aę] wysy[łl]kow|new message|nowa wiadomo|added .* to (their )?(favourites|favorites)|dodał.* do ulubionych|left you a review|wystawi[ał].* opini|price drop|obni[żz]ka ceny|newsletter|promo)/i;
async function rest(path: string, init: RequestInit = {}) { return fetch(`${url}/rest/v1/${path}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }); }
Deno.serve(async () => {
  const connection=await (await rest('hq_email_connections?provider=eq.gmail&select=refresh_token')).json(); if(!connection?.[0]) return Response.json({error:'Gmail is not connected.'},{status:409});
  const state=await (await rest('hq_email_sync_state?provider=eq.gmail&select=started_at')).json(); if(!state?.[0]?.started_at) return Response.json({error:'Gmail baseline is not set.'},{status:409});
  const token=await (await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:connection[0].refresh_token,client_id:Deno.env.get('GMAIL_CLIENT_ID')!,client_secret:Deno.env.get('GMAIL_CLIENT_SECRET')!})})).json();
  const gmail=(path:string)=>fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`,{headers:{authorization:`Bearer ${token.access_token}`}});
  const after=Math.floor(new Date(state[0].started_at).getTime()/1000); const listing=await (await gmail(`messages?q=${encodeURIComponent(`from:no-reply@vinted.pl after:${after}`)}&maxResults=100`)).json(); const ledger=await (await rest('hq_ledger_items?select=item_id,name,live_title,ledger_status&limit=1000')).json();
  let received=0, applied=0, review=0, noise=0;
  for(const ref of listing.messages||[]) {
    const message=await (await gmail(`messages/${ref.id}?format=full`)).json(); const h=(name:string)=>message.payload.headers.find((x:any)=>x.name?.toLowerCase()===name)?.value||''; const subject=h('subject'), from=h('from'), body=text(message.payload); const trusted=/(?:^|<)no-reply@vinted\.pl>?\s*$/i.test(from.trim()); const receivedAt=new Date(Number(message.internalDate)).toISOString();
    let event_type='UNCLASSIFIED',item_title='',amount:number|null=null,transaction:string|null=null,bundleItems:string[]=[];
    if(trusted&&/^Your receipt for/i.test(subject)){
      const bundleMatch=subject.match(/Bundle\s+(\d+)\s+items?/i); bundleItems=betweenLabels(body,'Order','Paid'); amount=money(body,'Paid'); transaction=transactionId(body);
      if(bundleMatch&&Number(bundleMatch[1])>1){event_type='PURCHASE_BUNDLE';bundleItems=bundleItems.slice(0,Number(bundleMatch[1]));item_title=bundleItems.join(' · ');}
      else {event_type='PURCHASE_CONFIRMED';item_title=bundleItems[0]||'';}
    }
    else if(trusted&&/^You.ve sold an item on Vinted/i.test(subject)){event_type='SALE_PENDING';const m=body.match(/has bought\s*\n+([^\n]+)\s*\n+\s*[^\d\n]*([0-9]+[.,][0-9]+)/i);item_title=m?.[1]?.trim()||'';amount=m?Number(m[2].replace(',','.')):null;transaction=transactionId(body);}
    else if(trusted&&/^This order is completed/i.test(subject)){event_type='SALE_CONFIRMED';item_title=completedSaleTitle(body);amount=money(body,'Transferred to your Vinted Balance');transaction=transactionId(body);}
    else if(trusted&&NOISE.test(subject)){event_type='NOISE';}
    // A machine may book a sale only against a DEN that is actually LISTED on Vinted.
    // LISTED-BACKLOG, not merely "not SOLD" - an unlisted item can never be auto-sold.
    const matches=ledger.filter((i:any)=>i.ledger_status==='LISTED-BACKLOG'&&[i.live_title,i.name].some((v:string)=>norm(v)&&norm(v)===norm(item_title))); const item=matches.length===1?matches[0]:null; const auto=(event_type==='PURCHASE_CONFIRMED'&&!!item_title&&amount!==null)||(event_type==='PURCHASE_BUNDLE'&&bundleItems.length>1&&amount!==null)||(event_type==='SALE_PENDING'&&!!item&&amount!==null&&amount>0)||event_type==='SALE_CONFIRMED';
    const eventState=event_type==='NOISE'?'AUTO_DISMISSED':auto?'AUTO_APPLIED':'NEEDS_REVIEW';
    const normalizedBody=safeNormalizedText(body);
    const extractedFields={transaction_id:field(transaction),item_title:field(item_title),amount:field(amount),bundle_items:field(bundleItems.length?bundleItems:null),gmail_thread_id:field(message.threadId),received_at:field(receivedAt)};
    const evidence={gmail_message_id:ref.id,gmail_thread_id:message.threadId,vinted_transaction_id:transaction,sender:from,subject,received_at:receivedAt,normalized_body:normalizedBody,normalized_body_sha256:await sha256(normalizedBody),redaction_version:REDACTION_VERSION,parser_version:PARSER_VERSION,event_type,extracted_fields:extractedFields};
    const evidenceResponse=await rest('rpc/record_hq_gmail_evidence',{method:'POST',body:JSON.stringify({p:evidence})}); if(!evidenceResponse.ok) throw new Error(`Gmail evidence ${ref.id} was not recorded: ${await evidenceResponse.text()}`);
    const event={
      source_event_id:ref.id,event_type,state:eventState,occurred_on:receivedAt.slice(0,10),
      item_title:item_title||null,amount,vinted_transaction_id:transaction,matched_item_id:item?.item_id||null,
      bundle_items:bundleItems,
      evidence:{
        subject,from,gmail_message_id:ref.id,gmail_thread_id:message.threadId,parser_version:PARSER_VERSION,
        body_sha256:evidence.normalized_body_sha256,bundle_item_count:bundleItems.length||null,
        bundle_item_titles:bundleItems.length?bundleItems:null,item_amount:money(body,'Item'),
        postage:money(body,'Postage'),buyer_protection_fee:money(body,'Buyer Protection fee')
      }
    };
    const response=await rest('rpc/apply_hq_gmail_intake',{method:'POST',body:JSON.stringify({p:event})}); if(!response.ok) throw new Error(`Gmail event ${ref.id} was not recorded: ${await response.text()}`); const outcome=await response.json(); if(!outcome.duplicate){received++;if(outcome.state==='AUTO_APPLIED')applied++;else if(outcome.state==='AUTO_DISMISSED')noise++;else review++;}
  }
  return Response.json({received,applied,review,noise});
});
