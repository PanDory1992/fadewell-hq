import {createClient} from 'https://esm.sh/@supabase/supabase-js@2';
export {itemTitle} from './item-title.js';

export const sb=createClient('https://qgjkxtolyhbwpvncwtkn.supabase.co','sb_publishable_4I4sJO02Tudp00ALX2xbaQ_DHptnBLb');
export const $=id=>document.getElementById(id);
export const dateTime=value=>value?new Intl.DateTimeFormat('pl-PL',{dateStyle:'medium',timeStyle:'short'}).format(new Date(value)): '—';
export const safe=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
export const money=value=>value===null||value===undefined||value===''?'—':new Intl.NumberFormat('pl-PL',{style:'currency',currency:'PLN',maximumFractionDigits:0}).format(Number(value));
export const date=value=>value?new Intl.DateTimeFormat('pl-PL',{dateStyle:'medium'}).format(new Date(value)): '—';
export const pendingExternalReviews=events=>(events||[]).filter(event=>event.state==='NEEDS_REVIEW');
export const toast=message=>{const el=document.createElement('div');el.className='toast';el.textContent=message;document.body.append(el);setTimeout(()=>el.remove(),2600)};

const pages=[['index.html','Dziś · Home'],['operations.html','Dziś · Operations'],['kpi.html','Pieniądze · KPI'],['finance.html','Pieniądze · Finanse'],['pricing.html','Pieniądze · Pricing'],['ledger.html','Stock · Ledger'],['wardrobe.html','Stock · Live wardrobe'],['triage.html','Stock · Triage'],['item-dna.html','Stock · Item DNA'],['sourcing.html','Stock · Sourcing'],['actions.html','Akcje · Action Studio'],['system.html','System']];

export async function shell(active){
  if(!document.querySelector('link[href="polish.css"]'))document.head.insertAdjacentHTML('beforeend','<link rel="stylesheet" href="polish.css">');
  $('nav').innerHTML=pages.map(([href,label])=>`<a class="${href===active?'active':''}" href="${href}">${label}</a>`).join('')+`<button class="secondary" id="globalSearch" title="Ctrl+K">⌕</button>`;
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){event.preventDefault();location.href='ledger.html?focus=search';}});
  $('globalSearch').onclick=()=>location.href='ledger.html?focus=search';
  if(active==='index.html')setTimeout(()=>{const notice=document.querySelector('#kpis .notice'),target=$('openCases');if(notice&&target)target.append(notice)},200);
  if(active==='actions.html')setTimeout(()=>{const wrap=$('itemWrap'),select=$('item');if(!wrap||!select||wrap.querySelector('input[data-item-filter]'))return;const input=document.createElement('input');input.dataset.itemFilter='';input.placeholder='Szukaj DEN lub tytułu…';input.setAttribute('aria-label','Szukaj itemu');wrap.insertBefore(input,select);const options=[...select.options].map(option=>({value:option.value,text:option.text}));input.oninput=()=>{const q=input.value.toLowerCase(),previous=select.value;select.innerHTML=options.filter(option=>!q||option.text.toLowerCase().includes(q)).map(option=>`<option value="${option.value}">${option.text}</option>`).join('');select.value=previous;select.dispatchEvent(new Event('change'))}},200);
  if(active==='ledger.html'){document.addEventListener('keydown',event=>{if(!['ArrowLeft','ArrowRight'].includes(event.key)||!$('detail')?.open)return;const current=$('detailBody')?.querySelector('.eyebrow')?.textContent,buttons=[...document.querySelectorAll('#rows button[data-item]')],index=buttons.findIndex(button=>button.dataset.item===current);if(index<0)return;event.preventDefault();buttons[(index+(event.key==='ArrowRight'?1:-1)+buttons.length)%buttons.length]?.click()});setTimeout(()=>{const age=new URLSearchParams(location.search).get('age');if(!age)return;const visible=row=>{const days=Number(row.cells[4]?.textContent.trim());if(age==='bound')return row.cells[4]?.textContent.trim()==='—';if(!Number.isFinite(days))return false;if(age==='0-30')return days<=30;if(age==='31-60')return days>30&&days<=60;if(age==='61-90')return days>60&&days<=90;if(age==='90+')return days>90;return true};[...document.querySelectorAll('#rows tr')].forEach(row=>row.hidden=!visible(row))},350)}
  $('login').onclick=async()=>{
    const {error}=await sb.auth.signInWithOAuth({provider:'github',options:{redirectTo:location.origin+location.pathname}});
    if(error) $('status').textContent=`Logowanie: ${error.message}`;
  };
  $('logout').onclick=async()=>{await sb.auth.signOut(); location.reload();};
  const {data:{session}}=await sb.auth.getSession();
  if(!session){$('status').textContent='Zaloguj się przez GitHub, aby otworzyć prywatny prototyp HQ.';return false;}
  const {data:owner,error}=await sb.rpc('claim_first_hq_owner');
  if(error||!owner){$('status').textContent=error?.message||'To konto nie ma dostępu ownera.';return false;}
  $('login').hidden=true;$('logout').hidden=false;$('status').textContent=session.user.email||'HQ owner';
  if(!['actions.html','operations.html','item-dna.html'].includes(active)){
    let lastRefresh=Date.now();
    window.setInterval(()=>{lastRefresh=Date.now();location.reload();},60000);
    document.addEventListener('visibilitychange',()=>{if(!document.hidden&&Date.now()-lastRefresh>10000){lastRefresh=Date.now();location.reload();}});
  }
  return true;
}

export async function data(){
  const [{data:ledgerItems,error:ledgerError},{data:legacyItems,error:legacyError},{data:snapshots,error:snapshotsError},{data:reviews,error:reviewsError},{data:events,error:eventsError},{data:gmailEvents,error:gmailError},{data:allGmailReviews,error:gmailReviewError}]=await Promise.all([
    sb.from('hq_ledger_items').select('*').order('item_id'),
    sb.from('hq_items').select('*').order('item_id'),
    sb.from('hq_listing_snapshots').select('*').order('captured_at',{ascending:false}).limit(800),
    sb.from('hq_review_queue').select('*').eq('state','OPEN').order('created_at',{ascending:false}),
    sb.from('hq_ledger_events').select('item_id,event_type,occurred_on,amount,detail,source,created_at,external_key').order('created_at',{ascending:false}).limit(30),
    sb.from('hq_external_events').select('source_event_id,event_type,state,occurred_at,item_title,amount,vinted_transaction_id,evidence,created_at').eq('source','GMAIL_VINTED').order('created_at',{ascending:false}).limit(20),
    sb.from('hq_external_events').select('source_event_id,event_type,state,occurred_at,item_title,amount,vinted_transaction_id,evidence,created_at').eq('source','GMAIL_VINTED').eq('state','NEEDS_REVIEW').order('created_at',{ascending:false}).limit(1000)
  ]);
  if(snapshotsError||reviewsError) throw (snapshotsError||reviewsError);
  if(ledgerError&&legacyError) throw ledgerError;
  const source=(ledgerItems||[]).length?'ledger':(legacyItems||[]).length?'legacy':'empty';
  const items=source==='ledger'?(ledgerItems||[]):(legacyItems||[]).map(item=>({
    ...item,
    flip_tier:item.flip_tier||item.tier||null,
    estimate_range:item.estimate_range||null,
    estimate_sale_price:item.estimate_sale_price??null,
    estimate_net_profit:item.estimate_net_profit??null,
    purchased_on:item.purchased_on||null,
    listed_on:item.listed_on||null,
    sold_on:item.sold_on||null,
    live_list_price:item.live_list_price??null
  }));
  const allSnapshots=snapshots||[];
  const cloudSnapshots=allSnapshots.filter(snapshot=>String(snapshot.source||'').startsWith('github_actions_vinted'));
  const cyclePool=cloudSnapshots.length?cloudSnapshots:allSnapshots;
  const cycleTimes=[...new Set(cyclePool.map(snapshot=>snapshot.captured_at).filter(Boolean))].sort().reverse();
  const latestCapturedAt=cycleTimes[0]||'';
  const previousCapturedAt=cycleTimes[1]||'';
  const latestCycle=cyclePool.filter(snapshot=>snapshot.captured_at===latestCapturedAt);
  const previousCycle=cyclePool.filter(snapshot=>snapshot.captured_at===previousCapturedAt);
  const linked=new Map(items.filter(item=>item.vinted_item_id).map(item=>[String(item.vinted_item_id),item]));
  const latestIds=new Set(latestCycle.map(snapshot=>String(snapshot.vinted_item_id)));
  const previousIds=new Set(previousCycle.map(snapshot=>String(snapshot.vinted_item_id)));
  const liveById=new Map(latestCycle.map(snapshot=>[String(snapshot.vinted_item_id),snapshot]));
  const pendingConfirmation=[];
  previousCycle.forEach(snapshot=>{
    const id=String(snapshot.vinted_item_id);
    const item=linked.get(id);
    if(!latestIds.has(id)&&item?.ledger_status!=='SOLD'){
      liveById.set(id,{...snapshot,pending_confirmation:true});
      pendingConfirmation.push(id);
    }
  });
  const live=[...liveById.values()].filter(snapshot=>linked.get(String(snapshot.vinted_item_id))?.ledger_status!=='SOLD');
  const missing=previousCapturedAt?items.filter(item=>item.ledger_status==='LISTED-BACKLOG'&&item.vinted_item_id&&!latestIds.has(String(item.vinted_item_id))&&!previousIds.has(String(item.vinted_item_id))):[];
  const pendingGmailReviews=gmailReviewError?pendingExternalReviews(gmailEvents):allGmailReviews||[];
  const visibleGmailEvents=[...(gmailEvents||[])];
  pendingGmailReviews.forEach(event=>{if(!visibleGmailEvents.some(row=>row.source_event_id===event.source_event_id))visibleGmailEvents.push(event)});
  return {items,snapshots:live,reviews:reviews||[],events:events||[],eventsError,gmailEvents:visibleGmailEvents,gmailError:gmailError||gmailReviewError,pendingGmailReviews,source,linked,missing,latestCapturedAt,previousCapturedAt,pendingConfirmation};
}

export const statusClass=status=>status==='SOLD'?'sold':status==='LISTED-BACKLOG'?'listed':'unlisted';
export const statusLabel=status=>status==='LISTED-BACKLOG'?'Wystawione':status==='UNLISTED-BACKLOG'?'Do wystawienia':status==='SOLD'?'Sprzedane':status||'—';
export function itemPhoto(item,snapshots){const snapshot=snapshots?.find(row=>String(row.vinted_item_id)===String(item.vinted_item_id));return snapshot?.photo_url||item.last_photo_url||'';}
