import {buildExperimentCandidates} from './pricing-candidates.js?v=20260811a';
import {isDenimItem,itemTitle} from './item-title.js?v=20260809-live-title';

const safe=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const money=value=>`${new Intl.NumberFormat('pl-PL',{maximumFractionDigits:0}).format(Number(value)||0)} zł`;
const activeStatuses=new Set(['APPROVED_NOT_STARTED','WAITING_EXECUTION','ACTIVE','EVALUATE']);

const candidateCard=(row,type)=>`<article class="studio-candidate"><div class="row-actions"><b>${safe(row.item.item_id)}</b><span class="badge">${type==='PRICE_VELOCITY'?`${money(row.currentPrice)} → ${money(row.proposedPrice)}`:money(row.currentPrice)}</span></div><h3>${safe(itemTitle(row.item))}</h3><p>${safe(row.reason)}</p><button class="secondary" data-candidate="${safe(row.item.item_id)}" data-type="${type}" data-price="${row.proposedPrice||''}">Dodaj do testu</button></article>`;
const specialCard=row=>`<article class="studio-candidate specialty"><div class="row-actions"><b>${safe(row.item.item_id)}</b><span class="status warning">Wycena specjalna</span></div><h3>${safe(itemTitle(row.item))}</h3><p>${safe(row.reason)}</p><a class="button secondary" href="ledger.html?item=${encodeURIComponent(row.item.item_id)}">Sprawdź parę</a></article>`;

export function mountExperimentStudio(root,{items,snapshots,experimentRows,sb}){
  const activeIds=new Set(experimentRows.filter(row=>activeStatuses.has(row.experiment_status)).map(row=>row.item_id));
  const candidates=buildExperimentCandidates(items,snapshots,activeIds);
  const eligible=items.filter(item=>isDenimItem(item)&&item.ledger_status==='LISTED-BACKLOG'&&item.vinted_item_id&&!activeIds.has(item.item_id)).sort((a,b)=>String(a.item_id).localeCompare(String(b.item_id)));
  const state={type:'PRICE_VELOCITY',selected:new Map()};
  root.innerHTML=`<div class="section-title"><div><div class="eyebrow">Studio eksperymentów · algorytm ${safe(candidates.meta.algorithmVersion)}</div><h2>Wybierz mechanizm, nie kolejną ręczną analizę</h2><p class="muted small">Model używa ${candidates.meta.soldComparables} sprzedaży z ostatnich ${candidates.meta.windowDays} dni i sprawdził ${candidates.meta.liveReviewed} aktywnych par poza trwającymi testami. Niczego nie zmienia ani nie kupuje na Vinted.</p></div></div>
  <div class="studio-lanes">
    <section><h3>Cena <span class="lane-count">${candidates.price.length}</span></h3><p class="muted small">Ciepłe oferty, wystarczające porównania, brak zmiany ceny przez 7 dni.</p>${candidates.price.map(row=>candidateCard(row,'PRICE_VELOCITY')).join('')||'<p class="empty small">Brak nowych kandydatów.</p>'}</section>
    <section><h3>Płatna ekspozycja <span class="lane-count">${candidates.exposure.length}</span></h3><p class="muted small">Cena już pasuje do popytu, oferta jest zimna, model ma własne sprzedaże.</p>${candidates.exposure.map(row=>candidateCard(row,'PAID_EXPOSURE')).join('')||'<p class="empty small">Brak nowych kandydatów.</p>'}</section>
    <section><h3>Wycena specjalna <span class="lane-count">${candidates.special.length}</span></h3><p class="muted small">Cecha kolekcjonerska blokuje automatyczną obniżkę.</p>${candidates.special.map(specialCard).join('')||'<p class="empty small">Brak wyjątków.</p>'}</section>
  </div>
  <section class="studio-builder">
    <div><div class="eyebrow">Nowy eksperyment</div><h2 id="draftTitle">Szkic pusty</h2><p class="muted small">Możesz użyć rekomendacji wyżej albo dodać dowolną wolną parę ręcznie.</p></div>
    <div class="studio-controls"><label>Mechanizm<select id="studioType"><option value="PRICE_VELOCITY">Test ceny</option><option value="PAID_EXPOSURE">Płatna ekspozycja</option></select></label><label>Dodaj parę<select id="studioItem"><option value="">Wybierz DEN…</option>${eligible.map(item=>`<option value="${safe(item.item_id)}">${safe(item.item_id)} · ${safe(itemTitle(item))}</option>`).join('')}</select></label><button id="studioAdd" class="secondary">Dodaj</button></div>
    <div id="studioDraft" class="studio-draft"><p class="empty">Nie wybrano żadnej pary.</p></div>
    <div class="studio-controls"><label>Cel<input id="studioObjective" value="Sprawdzić, czy wybrany mechanizm prowadzi do sprzedaży w ograniczonym oknie."></label><label>Długość<select id="studioDuration"><option value="7">7 dni</option><option value="14">14 dni</option><option value="21">21 dni</option></select></label><label>Próg sukcesu<input id="studioSuccess" type="number" min="1" value="1"></label><button id="studioCreate">Utwórz eksperyment</button></div>
    <p id="studioMessage" class="muted small"></p>
  </section>`;

  const byId=new Map(eligible.map(item=>[item.item_id,item]));
  const renderDraft=()=>{
    root.querySelector('#draftTitle').textContent=state.selected.size?`${state.selected.size} par w szkicu`:'Szkic pusty';
    root.querySelector('#studioDraft').innerHTML=state.selected.size?[...state.selected.values()].map(row=>`<div class="draft-row"><div><b>${safe(row.item.item_id)}</b><span>${safe(itemTitle(row.item))}</span></div>${state.type==='PRICE_VELOCITY'?`<label>Cena testowa<input data-draft-price="${safe(row.item.item_id)}" type="number" min="1" value="${row.price||''}"></label>`:'<span class="muted small">Koszt wpiszesz po zakupie Podbicia na Vinted.</span>'}<button class="secondary" data-remove="${safe(row.item.item_id)}">Usuń</button></div>`).join(''):'<p class="empty">Nie wybrano żadnej pary.</p>';
    root.querySelectorAll('[data-remove]').forEach(button=>button.onclick=()=>{state.selected.delete(button.dataset.remove);renderDraft()});
  };
  const changeType=value=>{if(value!==state.type){state.type=value;state.selected.clear();renderDraft()}};
  root.querySelector('#studioType').onchange=event=>changeType(event.target.value);
  root.querySelector('#studioAdd').onclick=()=>{const id=root.querySelector('#studioItem').value,item=byId.get(id);if(item)state.selected.set(id,{item,price:''});renderDraft()};
  root.querySelectorAll('[data-candidate]').forEach(button=>button.onclick=()=>{changeType(button.dataset.type);root.querySelector('#studioType').value=state.type;const item=byId.get(button.dataset.candidate);if(item)state.selected.set(item.item_id,{item,price:button.dataset.price});renderDraft();root.querySelector('.studio-builder').scrollIntoView({behavior:'smooth',block:'center'})});
  root.querySelector('#studioCreate').onclick=async event=>{
    const button=event.currentTarget,message=root.querySelector('#studioMessage');message.textContent='';
    const draft=[...state.selected.values()].map(row=>({item_id:row.item.item_id,proposed_price:state.type==='PRICE_VELOCITY'?Number(root.querySelector(`[data-draft-price="${row.item.item_id}"]`)?.value):null}));
    if(!draft.length){message.textContent='Najpierw dodaj co najmniej jedną parę.';return}
    if(state.type==='PRICE_VELOCITY'&&draft.some(row=>!row.proposed_price)){message.textContent='Każda para w teście ceny potrzebuje ceny testowej.';return}
    button.disabled=true;message.textContent='Tworzę eksperyment…';
    const payload={experiment_type:state.type,objective:root.querySelector('#studioObjective').value.trim(),duration_days:Number(root.querySelector('#studioDuration').value),success_min_sales:Number(root.querySelector('#studioSuccess').value),external_key:crypto.randomUUID(),algorithm_version:candidates.meta.algorithmVersion,items:draft};
    const {error}=await sb.rpc('create_hq_experiment_owner',{p:payload});
    if(error){button.disabled=false;message.textContent=`Nie utworzono: ${error.message}`;return}
    message.textContent='Eksperyment utworzony. Odświeżam HQ…';setTimeout(()=>location.reload(),500);
  };
}
