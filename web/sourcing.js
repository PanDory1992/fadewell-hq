import {isDenimItem,itemTitle} from './item-title.js?v=20260716c';
import {brandKey,resolveBrand} from './dna-normalize.js?v=20260716e';

const n=value=>Number(value)||0;
const sale=item=>item.sale_price_arbitrage??item.sale_price_recycled??null;
const normalise=value=>String(value||'').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g,' ').trim();
const model=value=>normalise(value).match(/\b(\d{3,4})\b/)?.[1]||'';
const waist=value=>{const text=String(value||'').toLowerCase();const match=text.match(/\bw\s?(\d{2})\b/)||text.match(/\b(\d{2})\s*(?:x|\/)\s*\d{2}\b/);return match?Number(match[1]):null;};
const median=values=>{const sorted=[...values].filter(Number.isFinite).sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length?sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2:null;};
const days=(from,to=new Date())=>{if(!from||!to)return null;const a=new Date(from),b=new Date(to);return Number.isNaN(a.getTime())||Number.isNaN(b.getTime())?null:Math.max(0,Math.floor((b-a)/86400000));};
export const sizeBand=value=>value===null?'bez rozmiaru':value<=29?'W<=29':value<=32?'W30-32':value<=35?'W33-35':'W36+';
const fact=item=>{const f=item.item_dna?.facts||{},title=itemTitle(item),brand=resolveBrand(f.brand,title);return{brand,brandKey:brandKey(brand),model:String(f.model||model(title)||''),size:waist(f.tagged_size)||waist(title)};};
const cellMatches=(cell,f)=>cell.rule_kind==='SEGMENT'&&(cell.brand_key==='*'||cell.brand_key===f.brandKey)&&(cell.model_key==='*'||cell.model_key===normalise(f.model))&&(cell.size_band==='*'||cell.size_band===f.band);
export function policyFor(f,cells=[]){return [...cells].filter(cell=>cellMatches(cell,f)).sort((a,b)=>Number(b.priority)-Number(a.priority))[0]||null;}

export function buildSourcing(items,cells=[],now=new Date(),windowDays=120){
  const cutoff=new Date(now.getTime()-windowDays*86400000),grouped=new Map;
  for(const item of items.filter(isDenimItem)){
    const f=fact(item),band=sizeBand(f.size),key=[f.brandKey||'unknown',normalise(f.model)||'unknown',band].join('|');
    if(!grouped.has(key))grouped.set(key,{key,f:{...f,band},items:[]});
    grouped.get(key).items.push(item);
  }
  return[...grouped.values()].map(group=>{
    const soldRecent=group.items.filter(item=>item.ledger_status==='SOLD'&&sale(item)!==null&&item.sold_on&&new Date(item.sold_on)>=cutoff),listed=group.items.filter(item=>item.ledger_status==='LISTED-BACKLOG'),unlisted=group.items.filter(item=>item.ledger_status==='UNLISTED-BACKLOG');
    const salePrices=soldRecent.map(item=>n(sale(item))),profits=soldRecent.map(item=>item.net_profit===null||item.net_profit===undefined?n(sale(item))-n(item.total_capital):n(item.net_profit)),saleDays=soldRecent.map(item=>days(item.listed_on||item.purchased_on,item.sold_on)).filter(value=>value!==null),policy=policyFor(group.f,cells);
    const evidence=soldRecent.length>=3?'READY':'INSUFFICIENT',stockCount=listed.length+unlisted.length;
    let action=evidence==='READY'?'WATCH':'INSUFFICIENT_EVIDENCE';
    if(policy?.decision==='RED')action='CLOSED';
    else if(policy?.decision==='GREEN')action='OPEN_REPLACEMENT';
    return{...group,label:[group.f.brand||'Nieokreślona marka',group.f.model||'bez modelu',group.f.band].join(' · '),soldRecent,listed,unlisted,evidence,policy,action,medianSale:median(salePrices),medianProfit:median(profits),medianDays:median(saleDays),listedCapital:listed.reduce((sum,item)=>sum+n(item.total_capital),0),unlistedCapital:unlisted.reduce((sum,item)=>sum+n(item.total_capital),0),salesToCurrent:stockCount?soldRecent.length/stockCount:null};
  }).sort((a,b)=>({OPEN_REPLACEMENT:0,CLOSED:1,WATCH:2,INSUFFICIENT_EVIDENCE:3}[a.action]-{OPEN_REPLACEMENT:0,CLOSED:1,WATCH:2,INSUFFICIENT_EVIDENCE:3}[b.action])||b.soldRecent.length-a.soldRecent.length||a.label.localeCompare(b.label));
}

export const actionCopy={
  OPEN_REPLACEMENT:['Zielona komórka','Może wejść wyłącznie przez dostępny slot replacement i do zapisanego limitu kosztu.'],
  WATCH:['Obserwuj','Dane nie otwierają zakupu; utrzymuj rozdział między popytem a zalegającym stockiem.'],
  CLOSED:['Zamknięte','Wersjonowana polityka wyklucza ten segment.'],
  INSUFFICIENT_EVIDENCE:['Za mało danych','Mniej niż trzy sprzedaże w ostatnich 120 dniach; brak automatycznej reguły.']
};
