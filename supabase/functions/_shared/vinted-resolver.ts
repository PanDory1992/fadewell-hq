type Item = Record<string, unknown>;
type Listing = Record<string, unknown>;
const STOP = new Set(['jeans','denim','vintage','pants','trousers','fit','blue','black','with','for','the','and','new','size']);
const text = (value: unknown) => String(value ?? '').toLowerCase().replace(/[â€™']/g,'');
const set = (matches: Iterable<string>) => new Set(matches);
const overlap = (a: Set<string>, b: Set<string>) => set([...a].filter(value => b.has(value)));
const tokens = (value: unknown) => set((text(value).match(/[a-z0-9]+/g) || []).filter(token => token.length >= 3 && !STOP.has(token)));
const sizes = (value: unknown) => {
  const source=text(value), found=new Set<string>();
  for(const match of source.matchAll(/\b([wl])\s*([0-9]{2})\b/g)) found.add(`${match[1]}${match[2]}`);
  for(const match of source.matchAll(/\b([0-9]{2})\s*\/\s*([0-9]{2})\b/g)){found.add(`w${match[1]}`);found.add(`l${match[2]}`);}
  return found;
};
const models = (value: unknown) => set([...text(value).matchAll(/\b([0-9]{3,4})\b/g)].map(match=>match[1]));
const families = (value: unknown, definitions: Record<string,RegExp>) => set(Object.entries(definitions).filter(([,pattern])=>pattern.test(text(value))).map(([name])=>name));
const colours = (value: unknown) => families(value,{blue:/\b(?:blue|midblue|mid blue|indigo|navy|stonewash)\b/,black:/\b(?:black|charcoal)\b/,grey:/\b(?:grey|gray)\b/,white:/\b(?:white|ecru|cream|beige)\b/,green:/\b(?:green|olive|smaragd)\b/});
const countries = (value: unknown) => families(value,{poland:/\b(?:poland|polska|pl)\b/,usa:/\b(?:usa|u s a|america)\b/,uk:/\b(?:uk|england|britain)\b/,spain:/\b(?:spain|espana)\b/});
const marker = (value: unknown) => {const found=text(value).match(/#den[-_ ]?0*(\d{1,5})\b/i);return found?`DEN-${String(Number(found[1])).padStart(3,'0')}`:null;};

function score(listing:Listing,item:Item){
  const listingText=`${listing.title||''} ${listing.description||''}`,itemText=`${item.name||''} ${item.category||''} ${item.advantage||''}`;
  if(marker(listingText)===item.item_id)return{item,score:1000,reasons:['marker #den'],strong:true};
  const shared=overlap(tokens(listingText),tokens(itemText)),sameSizes=overlap(sizes(listingText),sizes(itemText)),sameModels=overlap(models(listingText),models(itemText)),listingColours=colours(listingText),itemColours=colours(itemText),listingCountries=countries(listingText),itemCountries=countries(itemText);
  let points=0;const reasons:string[]=[];
  if(shared.size){points+=Math.min(38,8*shared.size);reasons.push(`wspólne słowa: ${[...shared].sort().slice(0,4).join(', ')}`);}
  if(sameSizes.size){points+=22*sameSizes.size;reasons.push(`zgodny rozmiar ${[...sameSizes].sort().join(', ')}`);}
  if(sameModels.size){points+=30;reasons.push(`zgodny model ${[...sameModels].sort().join(', ')}`);}
  if(listingColours.size&&itemColours.size){if(overlap(listingColours,itemColours).size){points+=12;reasons.push('zgodny kolor');}else{points-=20;reasons.push('sprzeczny kolor');}}
  if(listingCountries.size&&itemCountries.size){if(overlap(listingCountries,itemCountries).size){points+=10;reasons.push('zgodny kraj pochodzenia');}else{points-=20;reasons.push('sprzeczny kraj pochodzenia');}}
  const estimate=Number(item.estimate_sale_price),price=Number(listing.price_pln);
  if(estimate>0&&price>0&&Math.abs(price-estimate)/estimate<=.30){points+=5;reasons.push('cena blisko estymaty');}
  return{item,score:points,reasons,strong:sameSizes.size>0&&sameModels.size>0};
}

export function bestMatch(listing:Listing,items:Item[]){
  const matches=items.map(item=>score(listing,item)).sort((a,b)=>b.score-a.score);if(!matches.length||matches[0].score<=0)return null;
  const best=matches[0],runner=matches[1],high=best.score===1000||(best.score>=80&&best.strong&&(!runner||best.score-runner.score>=25));
  return{...best,auto:high,confidence:high?'HIGH':best.score>=35?'MEDIUM':'LOW'};
}
