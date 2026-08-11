import {estimate,listingSignal} from './pricing.js';
import {isDenimItem,itemTitle} from './item-title.js?v=20260809-live-title';

const DAY=86400000;
const number=value=>Number(value)||0;
const text=item=>`${itemTitle(item)} ${JSON.stringify(item.item_dna||{})}`.toLowerCase();
const specialRules=[
  ['selvedge',/selvedge|selvage/],
  ['White Oak / Cone',/white\s*oak|cone\s*(mills|denim)/],
  ['deadstock / NWT',/deadstock|\bnwt\b|new\s+with\s+tags|nowe\s+z\s+metk/],
  ['Big E',/\bbig\s*e\b/],
  ['Orange Tab',/orange\s*tab|orange\s*label|pomara[nń]czow[aey]\s+(tab|metk)/],
  ['limitowana / rzadka',/limited|limitowan|\brare\b|rzadk/]
];

export const specialtySignals=item=>specialRules.filter(([,pattern])=>pattern.test(text(item))).map(([label])=>label);

const recentSale=(item,now,days=120)=>item.sold_on&&now-new Date(item.sold_on)<=days*DAY;
const psychological9=value=>{
  const rounded=Math.max(9,Math.round(number(value)/10)*10-1);
  return rounded;
};
const sameSpecialEvidence=(signals,model)=>model.comparables.filter(row=>signals.some(signal=>specialtySignals(row.item).includes(signal))).length;
const changedRecently=signal=>signal.priceChanges.some(change=>signal.latest&&new Date(signal.latest.captured_at)-new Date(change.captured_at)<=7*DAY);

export function buildExperimentCandidates(items,snapshots,activeItemIds=new Set(),now=new Date()){
  const sold=items.filter(item=>isDenimItem(item)&&item.ledger_status==='SOLD'&&recentSale(item,now)&&number(item.sale_price_arbitrage??item.sale_price_recycled)>0);
  const live=items.filter(item=>isDenimItem(item)&&item.ledger_status==='LISTED-BACKLOG'&&item.vinted_item_id&&!activeItemIds.has(item.item_id));
  const price=[],exposure=[],special=[];
  for(const item of live){
    const model=estimate(item,sold),signal=listingSignal(item,snapshots,now),signals=specialtySignals(item);
    if(!signal.latest||signal.snapshotAge===null||signal.snapshotAge>3||model.status!=='READY')continue;
    const priceNow=number(signal.price||item.live_list_price),capital=number(item.total_capital),days=number(signal.daysLive),likes=number(signal.likes);
    const evidenceCount=model.comparables.length,directCount=number(model.directCount),fairList=psychological9(model.center/.9),recentChange=changedRecently(signal);
    const specialEvidence=signals.length?sameSpecialEvidence(signals,model):0;
    if(signals.length&&specialEvidence<2){
      special.push({item,model,signal,signals,specialEvidence,reason:`Cecha specjalna: ${signals.join(', ')}. Model ma ${specialEvidence} porównywalne sprzedaże z tą samą cechą; zwykły model/marka nie może ustalać ceny.`});
      continue;
    }
    const floor=Math.max(capital,Math.ceil(priceNow*.7));
    const proposed=Math.min(priceNow-10,Math.max(floor,fairList));
    const gap=priceNow-proposed;
    if(evidenceCount>=3&&likes>=4&&days>=14&&!recentChange&&gap>=Math.max(10,priceNow*.08)){
      price.push({item,model,signal,currentPrice:priceNow,proposedPrice:proposed,fairList,gap,score:likes*3+Math.min(days,90)/7+gap/10+directCount*2,reason:`${likes} polubień · ${days} dni live · ${directCount} sprzedaże tego modelu · estymowany środek close ${Math.round(model.center)} zł.`});
      continue;
    }
    if(evidenceCount>=3&&directCount>=2&&days>=21&&likes<=3&&!recentChange&&priceNow<=fairList+10){
      exposure.push({item,model,signal,currentPrice:priceNow,fairList,score:directCount*4+Math.min(days,90)/7+(3-likes)*3,reason:`Cena mieści się w lane modelu (${fairList} zł list) · tylko ${likes} polubień po ${days} dniach · ${directCount} bezpośrednie sprzedaże modelu.`});
    }
  }
  const byScore=(a,b)=>b.score-a.score||String(a.item.item_id).localeCompare(String(b.item.item_id));
  return{price:price.sort(byScore),exposure:exposure.sort(byScore),special:special.sort((a,b)=>String(a.item.item_id).localeCompare(String(b.item.item_id))),meta:{soldComparables:sold.length,liveReviewed:live.length,windowDays:120,algorithmVersion:'FADEWELL-PRICE-EXPOSURE-1.0'}};
}
