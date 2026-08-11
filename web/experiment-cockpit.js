const number=value=>Number(value)||0;

export const displayState={
  TO_EXECUTE:['Do wykonania','Zmień cenę ręcznie na Vinted. HQ nie wykonuje tej zmiany.'],
  WAITING_COLLECTOR:['Czeka na collector','Wykonanie zostało zgłoszone; dopiero kolejny pełny snapshot potwierdzi cenę i uruchomi zegar.'],
  ACTIVE:['Aktywne','Collector potwierdził cenę. Trwa pomiar sprzedaży i uwolnionego kapitału.'],
  SOLD:['Sprzedane','Sprzedaż została potwierdzona w Ledgerze i weszła do wyniku eksperymentu.'],
  WAITING_QUOTE:['Czeka na wycenę','Najpierw potrzebny jest aktualny koszt Podbicia z Vinted; wyświetlenia i polubienia nie są zgodą na zakup.'],
  CONDITIONAL:['Warunkowe','Druga fala pozostaje zamknięta do wyniku pierwszej.'],
  STOPPED:['Zatrzymane','Ta pozycja nie uczestniczy już w eksperymencie.']
};

export const gateCopy={
  NOT_STARTED:'Zegar 7 dni jeszcze nie ruszył',
  COLLECTING:'Zbieranie wyniku do 7. dnia',
  RETAIN:'Próg utrzymania osiągnięty',
  REVISE:'Wynik częściowy — zmień mechanizm, nie tnij w ciemno',
  STOP:'Brak wyniku — zatrzymaj dalsze dokładanie kosztu',
  COMPLETED:'Eksperyment zakończony',
  STOPPED:'Eksperyment zatrzymany',
  REVIEW:'Wymaga decyzji właściciela'
};

export function buildExperimentCockpit(progress=[],rows=[]){
  const byExperiment=new Map(rows.map(row=>[row.experiment_id,[]]));
  rows.forEach(row=>byExperiment.get(row.experiment_id).push(row));
  return progress.map(experiment=>{
    const items=(byExperiment.get(experiment.experiment_id)||[]).sort((a,b)=>String(a.item_id).localeCompare(String(b.item_id)));
    const lanes={TO_EXECUTE:[],WAITING_COLLECTOR:[],ACTIVE:[],SOLD:[],WAITING_QUOTE:[],CONDITIONAL:[],STOPPED:[]};
    items.forEach(item=>(lanes[item.display_state]||lanes.TO_EXECUTE).push(item));
    return{...experiment,items,lanes,gateLabel:gateCopy[experiment.day_7_gate]||experiment.day_7_gate||'—'};
  }).sort((a,b)=>{
    const weight=value=>value==='PRICE_VELOCITY'?0:value==='PAID_EXPOSURE'?1:2;
    return weight(a.experiment_type)-weight(b.experiment_type)||String(a.experiment_id).localeCompare(String(b.experiment_id));
  });
}

export function experimentTotals(experiments=[]){
  return experiments.reduce((totals,experiment)=>({
    experiments:totals.experiments+1,
    items:totals.items+number(experiment.item_count),
    sold:totals.sold+number(experiment.sold_count),
    active:totals.active+number(experiment.active_count),
    waitingCollector:totals.waitingCollector+experiment.lanes.WAITING_COLLECTOR.length,
    toExecute:totals.toExecute+experiment.lanes.TO_EXECUTE.length,
    capitalReleased:totals.capitalReleased+number(experiment.capital_released)
  }),{experiments:0,items:0,sold:0,active:0,waitingCollector:0,toExecute:0,capitalReleased:0});
}
