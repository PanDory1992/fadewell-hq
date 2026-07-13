const url = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
const norm = (v: string | null | undefined) => (v || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();
const text = (part: any): string => part?.mimeType === 'text/plain' && part.body?.data ? new TextDecoder().decode(Uint8Array.from(atob(part.body.data.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0))) : (part?.parts || []).map(text).join('\n');
const money = (body: string, label: string) => { const m=body.match(new RegExp(`${label}\\s*\\n?\\s*(?:zł|zÅ‚|PLN)\\s*([0-9.,]+)`,'i')); const n=Number((m?.[1]||'').replace(',','.')); return Number.isFinite(n)&&n>0?n:null; };
async function rest(path: string, init: RequestInit = {}) { return fetch(`${url}/rest/v1/${path}`, { ...init, headers: { ...headers, ...(init.headers || {}) } }); }
Deno.serve(async () => {
  const connection=await (await rest('hq_email_connections?provider=eq.gmail&select=refresh_token')).json(); if(!connection?.[0]) return Response.json({error:'Gmail is not connected.'},{status:409});
  const state=await (await rest('hq_email_sync_state?provider=eq.gmail&select=started_at')).json(); if(!state?.[0]?.started_at) return Response.json({error:'Gmail baseline is not set.'},{status:409});
  const token=await (await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:connection[0].refresh_token,client_id:Deno.env.get('GMAIL_CLIENT_ID')!,client_secret:Deno.env.get('GMAIL_CLIENT_SECRET')!})})).json();
  const gmail=(path:string)=>fetch(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`,{headers:{authorization:`Bearer ${token.access_token}`}});
  const after=Math.floor(new Date(state[0].started_at).getTime()/1000); const listing=await (await gmail(`messages?q=${encodeURIComponent(`from:no-reply@vinted.pl after:${after}`)}&maxResults=100`)).json(); const ledger=await (await rest('hq_ledger_items?select=item_id,name,live_title,ledger_status&limit=1000')).json();
  let received=0, applied=0, review=0;
  for(const ref of listing.messages||[]) {
    const message=await (await gmail(`messages/${ref.id}?format=full`)).json(); const h=(name:string)=>message.payload.headers.find((x:any)=>x.name?.toLowerCase()===name)?.value||''; const subject=h('subject'), from=h('from'), body=text(message.payload); const trusted=/(?:^|<)no-reply@vinted\.pl>?\s*$/i.test(from.trim());
    let event_type='UNCLASSIFIED',item_title='',amount:number|null=null,transaction:string|null=null;
    if(trusted&&/^Your receipt for/i.test(subject)){event_type='PURCHASE_CONFIRMED';item_title=body.match(/Order\s*\n+([^\n]+)/i)?.[1]?.trim()||'';amount=money(body,'Paid');transaction=body.match(/Transaction ID\s*\n?\s*(\d+)/i)?.[1]||null;}
    else if(trusted&&/^You.ve sold an item on Vinted/i.test(subject)){event_type='SALE_PENDING';const m=body.match(/has bought\s*\n+([^\n]+)\s*\n+\s*(?:zł|zÅ‚|PLN)\s*([0-9.,]+)/i);item_title=m?.[1]?.trim()||'';amount=m?Number(m[2].replace(',','.')):null;}
    else if(trusted&&/^This order is completed/i.test(subject)){event_type='SALE_CONFIRMED';item_title=body.match(/Your sale of (.*?) was completed successfully/i)?.[1]?.trim()||'';amount=money(body,'Transferred to your Vinted Balance');transaction=body.match(/Transaction ID:\s*#?(\d+)/i)?.[1]||null;}
    const matches=ledger.filter((i:any)=>i.ledger_status!=='SOLD'&&[i.live_title,i.name].some((v:string)=>norm(v)&&norm(v)===norm(item_title))); const item=matches.length===1?matches[0]:null; const auto=(event_type==='PURCHASE_CONFIRMED'&&!!item_title&&amount!==null)||(event_type==='SALE_PENDING'&&!!item&&amount!==null);
    const event={source_event_id:ref.id,event_type,state:auto?'AUTO_APPLIED':'NEEDS_REVIEW',occurred_on:new Date(Number(message.internalDate)).toISOString().slice(0,10),item_title:item_title||null,amount,vinted_transaction_id:transaction,matched_item_id:item?.item_id||null,evidence:{subject,from,gmail_message_id:ref.id}};
    const response=await rest('rpc/apply_hq_gmail_intake',{method:'POST',body:JSON.stringify({p:event})}); if(!response.ok) throw new Error(`Gmail event ${ref.id} was not recorded: ${await response.text()}`); const outcome=await response.json(); if(!outcome.duplicate){received++;if(outcome.state==='AUTO_APPLIED')applied++;else review++;}
  }
  return Response.json({received,applied,review});
});
