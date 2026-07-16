const clean=value=>String(value||'').trim().replace(/\s+/g,' ');
export const dnaKey=value=>clean(value).toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[’']/g,'').replace(/[^a-z0-9]+/g,' ').trim();

const brandAliases=new Map([
  ['levis',"Levi's"],['lee','Lee'],['wrangler','Wrangler'],['diesel','Diesel'],
  ['calvin','Calvin Klein'],['calvin klein','Calvin Klein'],['big','Big Star'],['big star','Big Star'],
  ['gap','GAP'],['acne studios','Acne Studios'],['carhartt','Carhartt'],['carhartt wip','Carhartt'],
  ['henry choice','Henry Choice'],['criminal damage','Criminal Damage'],['dickies','Dickies'],
  ['fishbone','Fishbone'],['heritage','Heritage'],['petrol','Petrol'],
]);
export const canonicalBrand=value=>brandAliases.get(dnaKey(value))||clean(value);
export const brandKey=value=>dnaKey(canonicalBrand(value));

const brandPatterns=[
  ['calvin klein','Calvin Klein'],['acne studios','Acne Studios'],['henry choice','Henry Choice'],
  ['criminal damage','Criminal Damage'],['big star','Big Star'],['carhartt wip','Carhartt'],
  ['levis',"Levi's"],['wrangler','Wrangler'],['diesel','Diesel'],['lee','Lee'],['gap','GAP'],
  ['carhartt','Carhartt'],['dickies','Dickies'],['fishbone','Fishbone'],['heritage','Heritage'],['petrol','Petrol'],
];
export function inferBrand(value){const source=` ${dnaKey(value)} `;return brandPatterns.find(([needle])=>source.includes(` ${needle} `))?.[1]||'';}

const originAliases=new Map([
  ['polska','Poland'],['poland','Poland'],['pl','Poland'],
  ['usa','USA'],['us','USA'],['united states','USA'],['united states of america','USA'],['america','USA'],
  ['uk','UK'],['united kingdom','UK'],['england','UK'],['great britain','UK'],['britain','UK'],
  ['turkiye','Turkey'],['turkey','Turkey'],['mexico','Mexico'],['meksyk','Mexico'],
  ['italy','Italy'],['italia','Italy'],['wlochy','Italy'],['japan','Japan'],['japonia','Japan'],
  ['china','China'],['chiny','China'],['pakistan','Pakistan'],['bangladesh','Bangladesh'],
  ['south korea','South Korea'],['korea','South Korea'],['morocco','Morocco'],['maroko','Morocco'],
  ['hungary','Hungary'],['wegry','Hungary'],['belgium','Belgium'],['belgia','Belgium'],
  ['spain','Spain'],['hiszpania','Spain'],['canada','Canada'],['kanada','Canada'],
  ['honduras','Honduras'],['albania','Albania'],['malta','Malta'],['australia','Australia'],
  ['eu','EU'],['asia','Asia'],
]);
export const canonicalOrigin=value=>originAliases.get(dnaKey(value))||clean(value);

const inSet=(key,values)=>values.includes(key);
export function originBucket(value){
  const key=dnaKey(canonicalOrigin(value));
  if(!key)return'';
  if(key==='usa')return'USA';
  if(inSet(key,['canada','mexico']))return'CAN & MEX';
  if(inSet(key,['honduras','guatemala','el salvador','nicaragua','costa rica','panama','colombia','peru','brazil','argentina','chile','ecuador','bolivia','paraguay','uruguay','venezuela','belize','guyana','suriname','french guiana','dominican republic','puerto rico','cuba','haiti']))return'Latin America';
  if(key==='poland')return'Poland';
  if(key==='uk')return'UK';
  if(key==='japan')return'Japan';
  if(inSet(key,['asia','china','pakistan','bangladesh','india','vietnam','cambodia','indonesia','philippines','sri lanka','thailand','laos','myanmar','nepal','malaysia','south korea','north korea','taiwan','hong kong','macau']))return'Asia';
  if(inSet(key,['eu','italy','malta','albania','belgium','hungary','spain','portugal','france','germany','netherlands','czech republic','czechia','slovakia','romania','bulgaria','croatia','slovenia','serbia','bosnia and herzegovina','north macedonia','greece','austria','sweden','norway','denmark','finland','ireland','lithuania','latvia','estonia','turkey','morocco','tunisia','algeria','egypt','jordan','lebanon','israel','palestine','united arab emirates','uae','saudi arabia','bahrain','comoros','djibouti','iraq','kuwait','libya','mauritania','oman','qatar','somalia','sudan','syria','yemen']))return'EU';
  return`Other: ${canonicalOrigin(value)}`;
}

const fitLabels=new Map([
  ['straight','Straight'],['regular straight','Regular Straight'],['tapered','Tapered'],
  ['relaxed tapered','Relaxed Tapered'],['loose tapered','Loose Tapered'],['slim tapered','Slim Tapered'],
  ['regular tapered','Regular Tapered'],['bootcut','Bootcut'],['flare','Flare'],['bootcut flare','Bootcut Flare'],
  ['skinny','Skinny'],['slim','Slim'],['regular slim','Regular Slim'],['regular','Regular'],
  ['relaxed','Relaxed'],['loose','Loose'],['baggy','Baggy'],['wide leg','Wide Leg'],
]);
export const canonicalFit=value=>fitLabels.get(dnaKey(value))||clean(value);
export function fitBucket(value){const key=dnaKey(value);if(!key)return'';if(key.includes('tapered'))return'Tapered';if(key.includes('bootcut')||key.includes('flare'))return'Bootcut / Flare';if(key.includes('straight'))return'Straight';if(key.includes('skinny'))return'Skinny';if(key.includes('slim'))return'Slim';if(key.includes('relaxed')||key.includes('loose')||key.includes('baggy')||key.includes('wide'))return'Relaxed / Loose';if(key.includes('regular'))return'Regular';return canonicalFit(value);}

export function canonicalEra(value){const raw=clean(value),key=dnaKey(raw);if(!key)return'';if(key==='modern')return'Modern';const short=key.match(/^(\d{2})s$/);if(short)return`${Number(short[1])>=30?'19':'20'}${short[1]}s`;const decade=key.match(/^(19|20)\d0s$/);if(decade)return decade[0];return raw;}
export function eraBucket(value){const canonical=canonicalEra(value),year=canonical.match(/\b(19|20)\d{2}\b/)?.[0];if(year)return`${year.slice(0,3)}0s`;const decade=canonical.match(/\b(?:19|20)\d0s\b/)?.[0];if(decade)return decade;return dnaKey(canonical)==='modern'?'Modern':canonical;}

const washLabels=new Map([
  ['mid blue','Mid Blue'],['medium blue','Mid Blue'],['light blue','Light Blue'],['dark blue','Dark Blue'],
  ['dark indigo','Dark Indigo'],['indigo','Indigo'],['navy blue','Navy Blue'],['black','Black'],
  ['grey','Grey'],['gray','Grey'],['charcoal','Charcoal'],['beige','Beige'],['sand','Sand'],['white','White'],
  ['stonewash blue','Stonewash Blue'],['light stonewash blue','Light Stonewash Blue'],
  ['light blue acidwash','Light Blue Acidwash'],['black grey acidwash','Black Grey Acidwash'],
]);
export const canonicalWash=value=>washLabels.get(dnaKey(value))||clean(value);
export function washBucket(value){const key=dnaKey(value);if(!key)return'';if(key.includes('black'))return'Black';if(key.includes('charcoal')||key.includes('grey')||key.includes('gray'))return'Grey';if(key.includes('white'))return'White';if(key.includes('beige')||key.includes('sand')||key.includes('cream')||key.includes('ecru'))return'Beige / Ecru';if(key.includes('light')&&key.includes('blue'))return'Light Blue';if((key.includes('dark')||key.includes('navy'))&&(key.includes('blue')||key.includes('indigo')))return'Dark Blue / Indigo';if(key.includes('blue')||key.includes('indigo'))return'Mid Blue';return canonicalWash(value);}

const conditionLabels=new Map([
  ['bardzo dobry','Bardzo dobry'],['very good','Bardzo dobry'],['dobry','Dobry'],['good','Dobry'],
  ['nowy z metka','Nowy z metką'],['new with tags','Nowy z metką'],['nwt','Nowy z metką'],
  ['nowy bez metki','Nowy bez metki'],['new without tags','Nowy bez metki'],['nwot','Nowy bez metki'],
]);
export const canonicalCondition=value=>conditionLabels.get(dnaKey(value))||clean(value);
export const conditionKey=value=>dnaKey(canonicalCondition(value));

export const canonicalTaggedSize=value=>clean(value).toUpperCase().replace(/W\s+(\d)/g,'W$1').replace(/L\s+(\d)/g,'L$1');
export function canonicalDnaFacts(facts={}){return{...facts,brand:canonicalBrand(facts.brand),model:clean(facts.model),tagged_size:canonicalTaggedSize(facts.tagged_size),wash:canonicalWash(facts.wash),fit:canonicalFit(facts.fit),era:canonicalEra(facts.era),origin:canonicalOrigin(facts.origin),condition:canonicalCondition(facts.condition)};}

export const DNA_SUGGESTIONS={
  brand:["Levi's",'Lee','Wrangler','Diesel','Calvin Klein','Big Star','GAP','Acne Studios','Carhartt','Dickies'],
  fit:['Straight','Regular Straight','Tapered','Relaxed Tapered','Loose Tapered','Slim Tapered','Bootcut','Flare','Skinny','Slim','Regular','Relaxed','Loose','Baggy','Wide Leg'],
  origin:['USA','Canada','Mexico','Honduras','Poland','UK','Italy','Spain','Belgium','Hungary','Malta','Albania','Turkey','Morocco','China','Pakistan','Bangladesh','India','Japan','South Korea','Australia'],
  era:['1980s','1990s','2000s','2010s','2020s','Modern'],
  wash:['Light Blue','Mid Blue','Dark Blue','Dark Indigo','Navy Blue','Stonewash Blue','Black','Charcoal','Grey','Beige','Sand','White'],
  condition:['Nowy z metką','Nowy bez metki','Bardzo dobry','Dobry'],
};
