import {createClient} from 'https://esm.sh/@supabase/supabase-js@2';

export const sb=createClient('https://qgjkxtolyhbwpvncwtkn.supabase.co','sb_publishable_4I4sJO02Tudp00ALX2xbaQ_DHptnBLb');
export const $=id=>document.getElementById(id);
export const safe=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
export const money=value=>value===null||value===undefined||value===''?'—':new Intl.NumberFormat('pl-PL',{style:'currency',currency:'PLN',maximumFractionDigits:0}).format(Number(value));
export const date=value=>value?new Intl.DateTimeFormat('pl-PL',{dateStyle:'medium'}).format(new Date(value)): '—';

const pages=[['index.html','Home'],['ledger.html','Ledger'],['wardrobe.html','Live wardrobe'],['operations.html','Operations'],['actions.html','Action Studio'],['system.html','System']];

export async function shell(active){
  $('nav').innerHTML=pages.map(([href,label])=>`<a class="${href===active?'active':''}" href="${href}">${label}</a>`).join('');
  $('login').onclick=async()=>{
    const {error}=await sb.auth.signInWithOAuth({provider:'github',options:{redirectTo:location.origin+location.pathname}});
    if(error) $('status').textContent=`Logowanie: ${error.message}`;
  };
  $('logout').onclick=async()=>{await sb.auth.signOut(); location.reload();};
  const {data:{session}}=await sb.auth.getSession();
  if(!session){$('status').textContent='Zaloguj się przez GitHub, aby otworzyć prywatny prototyp HQ.';return false;}
  const {data:owner,error}=await sb.rpc('claim_first_hq_owner');
  if(error||!owner){$('status').textContent=error?.message||'To konto nie ma dostępu ownera.';return false;}
  $('login').hidden=true;$('logout').hidden=false;$('status').textContent=session.user.email||'HQ owner';return true;
}

export async function data(){
  const [{data:ledgerItems,error:ledgerError},{data:legacyItems,error:legacyError},{data:snapshots,error:snapshotsError},{data:reviews,error:reviewsError}]=await Promise.all([
    sb.from('hq_ledger_items').select('*').order('item_id'),
    sb.from('hq_items').select('*').order('item_id'),
    sb.from('hq_listing_snapshots').select('*').order('captured_at',{ascending:false}).limit(800),
    sb.from('hq_review_queue').select('*').eq('state','OPEN').order('created_at',{ascending:false})
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
  const latest=new Map();
  (snapshots||[]).forEach(snapshot=>{const id=String(snapshot.vinted_item_id||'');if(id&&!latest.has(id))latest.set(id,snapshot);});
  const live=[...latest.values()];
  return {items,snapshots:live,reviews:reviews||[],source,linked:new Map(items.filter(item=>item.vinted_item_id).map(item=>[String(item.vinted_item_id),item]))};
}

export const statusClass=status=>status==='SOLD'?'sold':status==='LISTED-BACKLOG'?'listed':'unlisted';
export const statusLabel=status=>status==='LISTED-BACKLOG'?'Wystawione':status==='UNLISTED-BACKLOG'?'Do wystawienia':status==='SOLD'?'Sprzedane':status||'—';
export function itemPhoto(item,snapshots){const snapshot=snapshots?.find(row=>String(row.vinted_item_id)===String(item.vinted_item_id));return snapshot?.photo_url||'';}
