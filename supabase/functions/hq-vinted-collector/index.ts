import {createClient} from 'npm:@supabase/supabase-js@2';
import {bestMatch} from '../_shared/vinted-resolver.ts';

const projectUrl=Deno.env.get('SUPABASE_URL')!;
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const cronSecret=Deno.env.get('VINTED_COLLECTOR_CRON_SECRET')!;
const userId=Number(Deno.env.get('VINTED_USER_ID')||'271911480');
const db=createClient(projectUrl,serviceKey,{auth:{persistSession:false}});
const excluded=new Set([
  '7916904720','8578229244','8761980027','8916337895','8924480190','8926548628','8837312918','8853691792','8776616695','8729545669','8596372926','8696758529','8646904601','8239444164','7849353377','8163231173','7255147504','8130234003','7983720125','8061503289','8130341023','7990892108','7916971249','7733165472','7588948828'
]);
const headers:Record<string,string>={
  'user-agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  accept:'application/json, text/plain, */*','accept-language':'pl-PL,pl;q=0.9,en;q=0.7','x-requested-with':'XMLHttpRequest'
};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json'}});
const amount=(value:unknown)=>{const raw=value&&typeof value==='object'?'amount' in value?(value as Record<string,unknown>).amount:value:value;const number=Number(String(raw??'').replace(',','.'));return Number.isFinite(number)?number:null;};
const condition=(item:Record<string,unknown>)=>{let value=item.status||item.condition;if(value&&typeof value==='object'){const record=value as Record<string,unknown>;value=record.title||record.name||record.label;}return String(value||'').trim()||null;};
const cookieHeader=(response:Response)=>{
  const splitCombined=(value:string)=>value.split(/,(?=\s*[^;,=]+=[^;,]*)/g);
  const native='getSetCookie' in response.headers?(response.headers as Headers&{getSetCookie:()=>string[]}).getSetCookie():[];
  const values=native.length?native:splitCombined(response.headers.get('set-cookie')||'');
  const cookies=new Map<string,string>();
  for(const value of values){const pair=value.split(';')[0],separator=pair.indexOf('=');if(separator>0)cookies.set(pair.slice(0,separator).trim(),pair.slice(separator+1));}
  return [...cookies].map(([name,value])=>`${name}=${value}`).join('; ');
};

async function catalogPass(cookie:string){
  let page=1,totalPages=1,totalEntries:number|null=null,anchor=Date.now()/1000;const items:Record<string,unknown>[]=[];
  while(page<=totalPages){
    const url=new URL('https://www.vinted.pl/api/v2/catalog/items');url.searchParams.append('user_ids[]',String(userId));url.searchParams.set('page',String(page));url.searchParams.set('per_page','96');url.searchParams.set('time',String(anchor));url.searchParams.set('order','newest_first');
    const response=await fetch(url,{headers:{...headers,cookie,referer:'https://www.vinted.pl/','sec-fetch-dest':'empty','sec-fetch-mode':'cors','sec-fetch-site':'same-origin'},signal:AbortSignal.timeout(30000)});if(!response.ok){const body=(await response.text()).replace(/\s+/g,' ').slice(0,160);const names=cookie.split('; ').map(value=>value.split('=')[0]).filter(Boolean);throw new Error(`Vinted catalog HTTP ${response.status}; cookies=${names.join(',')||'none'}; body=${body}`);}
    const payload=await response.json(),batch=(payload.items||[]) as Record<string,unknown>[];
    if(batch.some(item=>Number((item.user as Record<string,unknown>|undefined)?.id)!==userId))throw new Error('Refusing mixed-seller Vinted response');
    const pagination=payload.pagination||{},advertisedPages=Number(pagination.total_pages||page),advertisedEntries=pagination.total_entries===undefined?null:Number(pagination.total_entries);
    if(advertisedPages<page)throw new Error(`Invalid Vinted pagination: page ${page} exceeds ${advertisedPages}`);
    if(advertisedEntries!==null&&totalEntries!==null&&advertisedEntries!==totalEntries)throw new Error(`Vinted total changed mid-pull: ${totalEntries} -> ${advertisedEntries}`);
    if(!batch.length&&page<advertisedPages)throw new Error(`Partial Vinted pagination: page ${page}/${advertisedPages} was empty`);
    items.push(...batch);totalPages=advertisedPages;totalEntries=advertisedEntries??totalEntries;anchor=Number(pagination.time||anchor);page++;
  }
  return{items:new Map(items.map(item=>[String(item.id),item])),totalEntries};
}

async function fetchItemsOnce(){
  const home=await fetch('https://www.vinted.pl',{headers,signal:AbortSignal.timeout(30000)});if(!home.ok)throw new Error(`Vinted home HTTP ${home.status}`);const cookie=cookieHeader(home);
  const combined=new Map<string,Record<string,unknown>>();let advertisedTotal:number|null=null;const passSizes:number[]=[];
  for(let pass=1;pass<=4;pass++){
    const result=await catalogPass(cookie);for(const [id,item] of result.items)combined.set(id,item);passSizes.push(result.items.size);advertisedTotal=Math.max(advertisedTotal||0,result.totalEntries||0)||null;
    if(advertisedTotal===null||combined.size>=advertisedTotal)return{items:[...combined.values()],passSizes,advertisedTotal};
    if(pass<4)await new Promise(resolve=>setTimeout(resolve,Math.min(pass*2000,5000)));
  }
  const shortfall=(advertisedTotal||combined.size)-combined.size;if(shortfall<=1)return{items:[...combined.values()],passSizes,advertisedTotal};
  throw new Error(`Partial Vinted pagination after 4 passes: expected ${advertisedTotal}, got ${combined.size} (${passSizes.join(',')})`);
}

function retryableVintedError(error:unknown){
  const message=error instanceof Error?error.message:String(error),name=error instanceof Error?error.name:'';
  return name==='TimeoutError'||name==='TypeError'||/^Vinted (?:home|catalog) HTTP (?:403|429|5\d\d)\b/.test(message)||/^Partial Vinted pagination/.test(message)||/^Vinted total changed mid-pull/.test(message);
}

async function fetchItems(){
  let lastError:unknown;
  for(let attempt=1;attempt<=3;attempt++){
    try{return await fetchItemsOnce();}
    catch(error){lastError=error;if(!retryableVintedError(error)||attempt===3)throw error;await new Promise(resolve=>setTimeout(resolve,attempt*2500));}
  }
  throw lastError||new Error('Vinted collection failed without an error');
}

async function referenceCount(){
  const{data,error}=await db.from('hq_listing_snapshots').select('captured_at').in('source',['github_actions_vinted','supabase_edge_vinted']).order('captured_at',{ascending:false}).limit(1000);if(error)throw error;if(!data?.length)return null;
  const counts=new Map<string,number>();for(const row of data){if(!counts.has(row.captured_at)&&counts.size===2)break;counts.set(row.captured_at,(counts.get(row.captured_at)||0)+1);}return Math.max(...counts.values());
}
async function priorIds(ids:string[]){if(!ids.length)return new Set<string>();const{data,error}=await db.from('hq_listing_snapshots').select('vinted_item_id').in('vinted_item_id',ids).order('captured_at',{ascending:false}).limit(250);if(error)throw error;return new Set((data||[]).map(row=>String(row.vinted_item_id)));}
async function description(id:string){try{const response=await fetch(`https://www.vinted.pl/items/${id}`,{headers:{...headers,accept:'text/html,application/xhtml+xml'},signal:AbortSignal.timeout(30000)});if(!response.ok)return'';const html=await response.text();return html.match(/<meta name="description" content="([^"]*)"/i)?.[1]?.replaceAll('&quot;','"').replaceAll('&amp;','&')||'';}catch{return'';}}

async function resolveNewListings(listings:Record<string,unknown>[],activeIds:Set<string>){
  const [{data:unlisted,error:a},{data:listed,error:b}]=await Promise.all([
    db.from('hq_ledger_items').select('item_id,name,category,advantage,estimate_sale_price,vinted_item_id').eq('ledger_status','UNLISTED-BACKLOG').is('vinted_item_id',null).limit(1000),
    db.from('hq_ledger_items').select('item_id,name,category,advantage,estimate_sale_price,vinted_item_id').eq('ledger_status','LISTED-BACKLOG').not('vinted_item_id','is',null).limit(1000)
  ]);if(a||b)throw(a||b);
  let candidates=[...(unlisted||[]),...(listed||[]).filter(item=>!activeIds.has(String(item.vinted_item_id)))];
  for(const [index,listing] of listings.entries()){
    if(index<5)listing.description=await description(String(listing.id));listing.price_pln=amount(listing.price);
    const match=bestMatch(listing,candidates);if(!match?.auto)continue;const item=match.item as Record<string,unknown>,id=String(listing.id),relist=Boolean(item.vinted_item_id&&String(item.vinted_item_id)!==id);
    const{error}=await db.rpc('apply_hq_ledger_action',{p:{action_type:'LISTED',item_id:item.item_id,occurred_on:new Date().toISOString().slice(0,10),amount:amount(listing.price),vinted_item_id:id,listing_url:`https://www.vinted.pl/items/${id}`,live_title:listing.title||null,note:`SYSTEM ${relist?'relist':'auto-resolver'}: score ${match.score}; ${match.reasons.join('; ')}`,source:'SYSTEM',external_key:`auto-resolver-link-${id}`,relist}});if(error)throw error;
    candidates=candidates.filter(candidate=>candidate.item_id!==item.item_id);
  }
}

Deno.serve(async request=>{
  if(request.method!=='POST')return json({error:'Method not allowed'},405);
  if(!cronSecret||request.headers.get('x-collector-secret')!==cronSecret)return json({error:'Forbidden'},403);
  const body=await request.json().catch(()=>({})) as {source?:string};const source=body.source||'SUPABASE_EDGE';
  const{data:lease,error:leaseError}=await db.rpc('begin_hq_collector_run',{p_source:source,p_stale_after_minutes:0,p_force:false});if(leaseError)return json({error:leaseError.message},500);if(!lease.accepted)return json({status:'skipped',...lease});const runId=lease.run_id as string;
  try{
    const result=await fetchItems(),capturedAt=new Date().toISOString(),live=result.items.filter(item=>!excluded.has(String(item.id))),rows=live.map(item=>{const photo=(item.photo||{}) as Record<string,unknown>,high=(photo.high_resolution||{}) as Record<string,unknown>;return{vinted_item_id:String(item.id),captured_at:capturedAt,title:item.title||null,price_pln:amount(item.price),views:Number(item.view_count||0),favourites:Number(item.favourite_count||0),visible:item.is_visible!==false,photo_url:high.url||photo.url||null,condition_label:condition(item),source:'supabase_edge_vinted'};});
    const reference=await referenceCount();if(reference!==null&&rows.length<reference-1)throw new Error(`Refusing partial Vinted snapshot: ${rows.length} DEN items against recent reference ${reference}`);
    const seen=await priorIds(live.map(item=>String(item.id)));const{error:insertError}=await db.from('hq_listing_snapshots').upsert(rows,{onConflict:'vinted_item_id,captured_at'});if(insertError)throw insertError;
    const active=new Set(live.map(item=>String(item.id))),newListings=live.filter(item=>!seen.has(String(item.id)));await resolveNewListings(newListings,active);
    await db.rpc('finish_hq_collector_run',{p_run_id:runId,p_success:true,p_captured_at:capturedAt,p_item_count:rows.length,p_error:null,p_detail:{catalog_total:result.advertisedTotal,pass_sizes:result.passSizes,new_listings:newListings.length}});
    return json({status:'success',captured_at:capturedAt,item_count:rows.length,new_listings:newListings.length,passes:result.passSizes});
  }catch(error){const message=error instanceof Error?error.message:String(error);await db.rpc('finish_hq_collector_run',{p_run_id:runId,p_success:false,p_captured_at:null,p_item_count:null,p_error:message,p_detail:{}});return json({status:'failed',error:message},502);}
});
