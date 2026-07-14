import {itemTitle} from './item-title.js';
const number=value=>Number(value)||0;
const sale=item=>item.sale_price_arbitrage??item.sale_price_recycled??null;
const closePrice=item=>{const value=sale(item);return value===null||value===undefined||value===''?null:number(value);};
const normalise=value=>String(value||'').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g,' ').trim();
const words=value=>new Set(normalise(value).split(' ').filter(word=>word.length>=3&&!['jeans','denim','vintage','spodnie','pants','blue','black','fit','size','with','the','and'].includes(word)));
const median=values=>{const sorted=[...values].sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length?sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2:null;};
const quantile=(values,p)=>{const sorted=[...values].sort((a,b)=>a-b);if(!sorted.length)return null;const index=(sorted.length-1)*p,low=Math.floor(index),high=Math.ceil(index);return sorted[low]+(sorted[high]-sorted[low])*(index-low);};
const weightedQuantile=(rows,p)=>{const sorted=[...rows].filter(row=>row.weight>0&&Number.isFinite(row.price)).sort((a,b)=>a.price-b.price);const total=sorted.reduce((sum,row)=>sum+row.weight,0);if(!total)return null;let seen=0;for(const row of sorted){seen+=row.weight;if(seen>=total*p)return row.price;}return sorted.at(-1).price;};
const size=value=>{const match=normalise(value).match(/\bw\s?(\d{2})\b/);return match?Number(match[1]):null;};
const model=value=>{const match=normalise(value).match(/\b(\d{3,4})\b/);return match?.[1]||null;};
const brand=value=>{const first=words(value).values().next().value||null;if(!first)return null;if(first.startsWith('levi'))return'levis';return first;};
const daysBetween=(from,to=new Date())=>{const date=new Date(from);return Number.isNaN(date.getTime())?null:Math.max(0,Math.floor((to-date)/86400000));};
const recencyWeight=item=>{const days=daysBetween(item.sold_on);return days===null?.55:.55+.45*Math.exp(-days/365);};
const sameSize=(a,b)=>a!==null&&b!==null?Math.max(0,1-Math.abs(a-b)/8):0;

export function feature(item){const facts=item.item_dna?.facts||{},title=itemTitle(item);return{brand:brand(facts.brand)||brand(title),model:String(facts.model||model(title)||''),size:size(facts.tagged_size)||size(title),fit:normalise(facts.fit),origin:normalise(facts.origin),wash:normalise(facts.wash),era:normalise(facts.era),condition:normalise(facts.condition),words:words(title)};}
export function comparable(target,candidate){
  const a=feature(target),b=feature(candidate);
  if(!a.brand||a.brand!==b.brand)return null;
  let score=3,reasons=['marka'];
  if(a.model&&a.model===b.model){score+=6;reasons.unshift(`model ${a.model}`);}
  ['fit','origin','condition'].forEach(key=>{if(a[key]&&a[key]===b[key]){score+=1;reasons.push(key);}});
  ['wash','era'].forEach(key=>{if(a[key]&&a[key]===b[key]){score+=.75;reasons.push(key);}});
  const sizeScore=sameSize(a.size,b.size);
  if(sizeScore>=.75){score+=2;reasons.push('rozmiar');}
  const shared=[...a.words].filter(word=>b.words.has(word));
  score+=Math.min(3,shared.length*.75);
  if(shared.length)reasons.push(shared.slice(0,2).join(', '));
  return{score,weight:score*recencyWeight(candidate),reasons};
}
export function estimate(target,sold,options={}){
  const eligible=sold.filter(item=>item.item_id!==options.excludeId&&closePrice(item)!==null);
  const comps=eligible.map(item=>({item,match:comparable(target,item)})).filter(row=>row.match&&row.match.score>=5).map(row=>({price:closePrice(row.item),weight:row.match.weight,item:row.item,match:row.match}));
  const direct=comps.filter(row=>row.match.reasons.includes(`model ${feature(target).model}`));
  const evidence=direct.length>=2?direct:comps;
  if(evidence.length<3)return{status:'INSUFFICIENT',comparables:evidence,reason:'Za mało własnych, porównywalnych sprzedaży.'};
  const center=weightedQuantile(evidence,.5),low=weightedQuantile(evidence,.25),high=weightedQuantile(evidence,.75),directCount=direct.length;
  const confidence=directCount>=5?'HIGH':evidence.length>=5?'MEDIUM':'LOW';
  return{status:'READY',center,low:Math.min(low,center),high:Math.max(high,center),confidence,comparables:evidence,directCount,reason:`${evidence.length} własnych sprzedaży · ${directCount} z tym samym modelem.`};
}
export function calibrate(sold){
  const ordered=[...sold].filter(item=>closePrice(item)!==null&&item.sold_on).sort((a,b)=>String(a.sold_on).localeCompare(String(b.sold_on)));
  const split=Math.floor(ordered.length*.7),train=ordered.slice(0,split),holdout=ordered.slice(split),residuals=[];
  for(const item of holdout){const estimateForHoldout=estimate(item,train);if(estimateForHoldout.status==='READY')residuals.push(Math.abs(closePrice(item)-estimateForHoldout.center));}
  return residuals.length>=6?{status:'CALIBRATED',count:residuals.length,band:quantile(residuals,.8),medianError:median(residuals)}:{status:'PENDING',count:residuals.length,band:null,medianError:null};
}
export function listingHistory(item,snapshots){return snapshots.filter(row=>String(row.vinted_item_id)===String(item.vinted_item_id)).sort((a,b)=>String(a.captured_at).localeCompare(String(b.captured_at)));}
export function listingSignal(item,snapshots){
  const rows=listingHistory(item,snapshots),latest=rows.at(-1),first=rows[0];
  const weekAgo=latest?new Date(new Date(latest.captured_at).getTime()-7*86400000):null;
  const baseline=[...rows].reverse().find(row=>weekAgo&&new Date(row.captured_at)<=weekAgo);
  const priceChanges=rows.filter((row,index)=>index&&number(row.price_pln)!==number(rows[index-1].price_pln));
  const historyDays=latest&&first?daysBetween(first.captured_at,new Date(latest.captured_at)):null;
  return{rows,latest,first,historyDays,likes:latest?number(latest.favourites):null,likesDelta:latest&&baseline?number(latest.favourites)-number(baseline.favourites):null,viewsDelta:null,priceChanges,daysLive:daysBetween(item.listed_on),snapshotAge:latest?daysBetween(latest.captured_at):null,price:number(latest?.price_pln??item.live_list_price),startPrice:number(first?.price_pln??item.live_list_price)};
}
const roundToFive=value=>Math.round(value/5)*5;
const priceText=value=>`${new Intl.NumberFormat('pl-PL',{maximumFractionDigits:0}).format(number(value))} zł`;
export function recommendation(item,model,signal,calibration){
  const floor=number(item.total_capital),price=signal.price;
  if(!signal.latest)return{action:'OBSERVE',priority:10,reason:'Brak aktualnego snapshotu live.',floor};
  if(signal.snapshotAge===null||signal.snapshotAge>3)return{action:'OBSERVE',priority:15,reason:'Snapshot live ma ponad 3 dni; najpierw poczekaj na świeży odczyt collectora.',floor};
  if(model.status!=='READY')return{action:'OBSERVE',priority:20,reason:'Brak wystarczających własnych porównań — bez rady cenowej.',floor};
  const low=Math.max(floor,model.low-(calibration.band||0)),high=model.high+(calibration.band||0),days=signal.daysLive??0;
  if(price<low){
    const next=roundToFive(model.center);
    return{action:'RAISE',priority:85,reason:`Cena ${priceText(price)} jest poniżej estymowanego zakresu ${priceText(low)}–${priceText(high)}. Podnieś ją w stronę środka modelu: ${priceText(next)}.`,floor,low,high,nextPrice:next};
  }
  if(price>high&&days<21)return{action:'OBSERVE',priority:40,reason:`Cena ${priceText(price)} jest powyżej estymowanego zakresu ${priceText(low)}–${priceText(high)}, ale oferta live jest dopiero ${days} dni. Jeszcze nie obniżaj; obserwuj sygnały do 21. dnia.`,floor,low,high};
  if(signal.historyDays>=7&&signal.likesDelta>=2)return{action:'KEEP',priority:75,reason:`Likes rosną (${signal.likesDelta>=0?'+':''}${signal.likesDelta} / ${signal.historyDays} dni) — nie obniżaj jeszcze.`,floor,low,high};
  if(days<14)return{action:'OBSERVE',priority:35,reason:`Oferta live ${days} dni; za wcześnie na wniosek cenowy bez negatywnego sygnału.`,floor,low,high};
  if(price>high){
    const drop=Math.min(10,Math.max(5,roundToFive((price-model.center)/2))),next=price-drop;
    if(next<=floor)return{action:'PRESENTATION',priority:90,reason:'Cena jest wysoko, ale bezpieczna obniżka dotknęłaby kapitału. Najpierw popraw zdjęcie główne lub tytuł.',floor,low,high};
    return{action:'TEST_LOWER',priority:95,reason:`Oferta live ${days} dni · ${signal.likes??0} likes · cena ${priceText(price)} powyżej zakresu ${priceText(low)}–${priceText(high)}. Testuj najmniejszy ruch do ${priceText(next)} (−${priceText(drop)}).`,floor,low,high,nextPrice:next};
  }
  if(days>=21&&signal.likes===0)return{action:'PRESENTATION',priority:80,reason:'0 likes po 21 dniach; najpierw sprawdź zdjęcie główne, tytuł i wymiary.',floor,low,high};
  return{action:'KEEP',priority:55,reason:'Cena mieści się w estymowanym zakresie; obserwuj kolejny tydzień.',floor,low,high};
}
export function buildCockpit(items,snapshots){
  const sold=items.filter(item=>item.ledger_status==='SOLD'&&closePrice(item)!==null),live=items.filter(item=>item.ledger_status==='LISTED-BACKLOG'&&item.vinted_item_id),calibration=calibrate(sold);
  return{calibration,rows:live.map(item=>{const model=estimate(item,sold),signal=listingSignal(item,snapshots),decision=recommendation(item,model,signal,calibration);const range=model.status==='READY'?{low:Math.max(number(item.total_capital),model.low-(calibration.band||0)),center:model.center,high:model.high+(calibration.band||0)}:null;return{item,model,signal,decision,range};}).sort((a,b)=>b.decision.priority-a.decision.priority)};
}
