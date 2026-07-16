import {isDenimItem,itemTitle} from './item-title.js?v=20260716c';
const n=value=>Number(value)||0;
const sale=item=>item.sale_price_arbitrage??item.sale_price_recycled??null;
const normalise=value=>String(value||'').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g,' ').trim();
const words=value=>normalise(value).split(' ').filter(Boolean);
const brand=value=>{const first=words(value).find(word=>word.length>=3);return first?.startsWith('levi')?'Levi\'s':first==='gap'?'GAP':first?first[0].toUpperCase()+first.slice(1):'';};
const model=value=>normalise(value).match(/\b(\d{3,4})\b/)?.[1]||'';
const waist=value=>{const match=normalise(value).match(/\bw\s?(\d{2})\b/);return match?Number(match[1]):null;};
const median=values=>{const sorted=[...values].filter(Number.isFinite).sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length?sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2:null;};
const quantile=(values,p)=>{const sorted=[...values].filter(Number.isFinite).sort((a,b)=>a-b);if(!sorted.length)return null;const index=(sorted.length-1)*p,lo=Math.floor(index),hi=Math.ceil(index);return sorted[lo]+(sorted[hi]-sorted[lo])*(index-lo);};
const days=(from,to=new Date())=>{const a=new Date(from),b=new Date(to);return Number.isNaN(a.getTime())||Number.isNaN(b.getTime())?null:Math.max(0,Math.floor((b-a)/86400000));};
const sizeBand=value=>value===null?'bez rozmiaru':value<=31?'W28–31':value<=34?'W32–34':'W35+';
const mode=values=>{const counts=new Map;for(const value of values.filter(Boolean))counts.set(value,(counts.get(value)||0)+1);return [...counts.entries()].sort((a,b)=>b[1]-a[1])[0]?.[0]||'';};
const fact=item=>{const f=item.item_dna?.facts||{},title=itemTitle(item);return{brand:brand(f.brand)||brand(title),model:String(f.model||model(title)||''),size:waist(f.tagged_size)||waist(title),fit:f.fit||'',origin:f.origin||'',era:f.era||''};};
const labelFor=(f,items)=>{const base=[f.brand||'Nieokreślona marka',f.model||'bez modelu',f.band].filter(Boolean).join(' · ');const facts=items.map(fact),suffix=['fit','origin','era'].map(key=>{const value=mode(facts.map(row=>row[key]));return value&&facts.filter(row=>row[key]===value).length/items.length>=.6?value:'';}).filter(Boolean);return suffix.length?`${base} · ${suffix.join(' · ')}`:base;};
const ageCount=(items,limit)=>items.filter(item=>days(item.purchased_on)>limit).length;

export function buildSourcing(items){
  const grouped=new Map;
  for(const item of items.filter(isDenimItem)){
    const f=fact(item),band=sizeBand(f.size),key=[f.brand||'unknown',f.model||'unknown',band].join('|');
    if(!grouped.has(key))grouped.set(key,{key,f:{...f,band},items:[]});
    grouped.get(key).items.push(item);
  }
  const segments=[...grouped.values()].map(group=>{
    const sold=group.items.filter(item=>item.ledger_status==='SOLD'&&sale(item)!==null&&sale(item)!==''),stock=group.items.filter(item=>item.ledger_status!=='SOLD');
    const profits=sold.map(item=>item.net_profit??(n(sale(item))-n(item.total_capital))),salePrices=sold.map(item=>n(sale(item)),),saleDays=sold.map(item=>days(item.listed_on||item.purchased_on,item.sold_on)).filter(value=>value!==null);
    const soldRate=group.items.length?sold.length/group.items.length:0,medianProfit=median(profits),medianDays=median(saleDays),conservativeSale=quantile(salePrices,.25),capitalCeiling=sold.length>=3&&medianProfit!==null&&medianProfit>0?Math.max(0,conservativeSale-medianProfit):null;
    const completeSegment=Boolean(group.f.brand&&group.f.model&&group.f.band!=='bez rozmiaru');
    const old60=ageCount(stock,60),old90=ageCount(stock,90),evidence=sold.length>=3&&completeSegment?'READY':'INSUFFICIENT';
    let action='INSUFFICIENT';
    if(evidence==='READY'&&medianProfit<=0)action='HOLD';
    else if(evidence==='READY'&&(old90>0||(medianDays!==null&&medianDays>60)||soldRate<.4))action='CAP';
    else if(evidence==='READY')action='BUY_MORE';
    return{...group,label:labelFor(group.f,group.items),purchased:group.items.length,sold,stock,soldRate,medianProfit,medianDays,capitalFrozen:stock.reduce((sum,item)=>sum+n(item.total_capital),0),old30:ageCount(stock,30),old60,old90,conservativeSale,capitalCeiling,evidence,action};
  });
  return segments.sort((a,b)=>a.action.localeCompare(b.action)||b.purchased-a.purchased||a.label.localeCompare(b.label));
}

export const actionCopy={BUY_MORE:['Kupuj częściej','Dodatnia mediana zysku i brak czerwonego sygnału rotacji.'],CAP:['Kupuj tylko do limitu','Segment zarabia, ale ma wolniejszy obrót lub zamrożony stock.'],HOLD:['Wstrzymaj / testuj ostrożnie','Historia nie broni kolejnego zakupu bez nowego dowodu.'],INSUFFICIENT:['Za mało danych','Brak minimum trzech zrealizowanych sprzedaży — bez fałszywej reguły.']};
