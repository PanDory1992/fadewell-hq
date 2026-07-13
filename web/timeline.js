const present=value=>value!==null&&value!==undefined&&value!=='';
const when=row=>row.created_at||row.occurred_at||row.captured_at||row.occurred_on||'';
const sortTime=value=>Number.isFinite(Date.parse(value))?Date.parse(value):0;
const ledgerLabel=type=>({PURCHASE:'Zakup',LISTED:'Wystawiono',SALE:'Sprzedano',ADJUSTMENT:'Korekta'}[type]||type||'Zdarzenie Ledgeru');
const ledgerSource=source=>source==='MANUAL'?{label:'Action Studio / ręczna decyzja',kind:'decision'}:source==='MIGRATION'?{label:'Import historyczny',kind:'historical'}:source==='VINTED'?{label:'Vinted',kind:'fact'}:source==='SYSTEM'?{label:'System HQ',kind:'fact'}:{label:source||'Ledger',kind:'fact'};
const gmailLink=id=>id?`https://mail.google.com/mail/u/0/#all/${encodeURIComponent(id)}`:null;
const vintedLink=({listingUrl,vintedItemId})=>listingUrl||(vintedItemId?`https://www.vinted.pl/items/${encodeURIComponent(vintedItemId)}`:null);
const evidence=(label,href=null)=>({label,href});
const externalLabel=event=>event.event_type==='PURCHASE_CONFIRMED'?'Zakup potwierdzony przez Vinted':event.event_type==='SALE_PENDING'?'Kupujący kupił przedmiot':event.event_type==='SALE_CONFIRMED'?'Transakcja zakończona przez Vinted':'Wiadomość Vinted do przeglądu';

function snapshotEntries(snapshots,item){
  const rows=[...(snapshots||[])].sort((a,b)=>sortTime(when(a))-sortTime(when(b)));if(!rows.length)return[];
  const link=vintedLink({listingUrl:item.listing_url,vintedItemId:item.vinted_item_id});
  const sourceFor=row=>String(row.source||'').includes('manual_override')?{label:'Ręczne potwierdzenie aktywności',kind:'decision'}:{label:'Vinted collector',kind:'observation'};
  const initial=rows[0],facts=[];
  if(present(initial.title))facts.push(initial.title);if(present(initial.price_pln))facts.push(`cena: ${Number(initial.price_pln)} PLN`);if(Number(initial.favourites)>0)facts.push(`likes: ${Number(initial.favourites)}`);if(Number(initial.views)>0)facts.push(`wyświetlenia: ${Number(initial.views)}`);
  const output=[{id:`snapshot:${initial.vinted_item_id}:${initial.captured_at}`,at:when(initial),precision:'time',type:'observation',title:'Pierwsza obserwacja oferty',summary:facts.join(' · ')||'Oferta widoczna w kolektorze.',source:sourceFor(initial),evidence:[evidence(`Vinted #${initial.vinted_item_id}`,link)]}];
  let previous=initial;
  for(const row of rows.slice(1)){
    const changes=[];
    if(present(row.price_pln)&&Number(row.price_pln)!==Number(previous.price_pln))changes.push(`cena zauważona: ${Number(previous.price_pln)} → ${Number(row.price_pln)} PLN`);
    if(present(row.favourites)&&Number(row.favourites)!==Number(previous.favourites))changes.push(`likes: ${Number(previous.favourites||0)} → ${Number(row.favourites)}`);
    if(present(row.views)&&Number(row.views)!==Number(previous.views))changes.push(`wyświetlenia: ${Number(previous.views||0)} → ${Number(row.views)}`);
    if(present(row.visible)&&Boolean(row.visible)!==Boolean(previous.visible))changes.push(row.visible?'oferta znów widoczna':'oferta niewidoczna w tym odczycie');
    if(changes.length)output.push({id:`snapshot:${row.vinted_item_id}:${row.captured_at}`,at:when(row),precision:'time',type:'observation',title:'Zmiana zaobserwowana na Vinted',summary:changes.join(' · '),source:sourceFor(row),evidence:[evidence(`Vinted #${row.vinted_item_id}`,link)]});
    previous=row;
  }
  return output;
}

export function buildTimeline({item,ledgerEvents=[],snapshots=[],externalEvents=[]}){
  const externalsByLedger=new Map();
  externalEvents.filter(event=>event.ledger_event_id).forEach(event=>{const key=String(event.ledger_event_id),list=externalsByLedger.get(key)||[];list.push(event);externalsByLedger.set(key,list);});
  const ledger=ledgerEvents.map(event=>{const source=ledgerSource(event.source),attached=externalsByLedger.get(String(event.id))||[],proof=[evidence(`Ledger #${event.id||'—'}`)];attached.forEach(external=>proof.push(evidence(`Gmail #${external.source_event_id}`,gmailLink(external.source_event_id))));return{id:`ledger:${event.id||`${event.event_type}:${when(event)}`}`,at:when(event),precision:event.created_at?'time':'date',type:source.kind,title:ledgerLabel(event.event_type),summary:[present(event.amount)?`${Number(event.amount)} PLN`:null,event.detail].filter(Boolean).join(' · ')||'Zdarzenie zapisane w Ledgerze.',source,evidence:proof};});
  const standaloneGmail=externalEvents.filter(event=>!event.ledger_event_id).map(event=>({id:`gmail:${event.source_event_id}`,at:when(event),precision:event.created_at?'time':'date',type:event.state==='NEEDS_REVIEW'?'review':'fact',title:externalLabel(event),summary:[event.item_title,present(event.amount)?`${Number(event.amount)} PLN`:null,event.state==='NEEDS_REVIEW'?'wymaga przeglądu':''].filter(Boolean).join(' · ')||'Wiadomość zapisana bez automatycznej decyzji.',source:{label:'Gmail / Vinted',kind:event.state==='NEEDS_REVIEW'?'review':'fact'},evidence:[evidence(`Gmail #${event.source_event_id}`,gmailLink(event.source_event_id)),...(event.vinted_transaction_id?[evidence(`Transakcja #${event.vinted_transaction_id}`)]:[])]}));
  return[...ledger,...standaloneGmail,...snapshotEntries(snapshots,item)].sort((a,b)=>sortTime(b.at)-sortTime(a.at));
}
