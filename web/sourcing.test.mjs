import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {buildSourcing,policyFor,sizeBand} from './sourcing.js';

const sold=(id,price,cost,soldOn,size='W34 L32')=>({item_id:id,name:`Levis 501 ${size}`,ledger_status:'SOLD',sale_price_arbitrage:price,total_capital:cost,purchased_on:'2026-01-01',listed_on:'2026-01-10',sold_on:soldOn,item_dna:{facts:{brand:"Levi's",model:'501',tagged_size:size}}});
const cells=[
  {cell_id:'green',rule_kind:'SEGMENT',decision:'GREEN',brand_key:'levis',model_key:'501',size_band:'W33-35',priority:40,max_landed_cost:50},
  {cell_id:'small',rule_kind:'SEGMENT',decision:'RED',brand_key:'*',model_key:'*',size_band:'W<=29',priority:100},
  {cell_id:'lee',rule_kind:'SEGMENT',decision:'RED',brand_key:'lee',model_key:'*',size_band:'*',priority:90}
];
const items=[
  sold('DEN-1',160,50,'2026-07-01'),sold('DEN-2',170,55,'2026-07-08'),sold('DEN-3',150,45,'2026-07-15'),
  {item_id:'DEN-4',name:'Levis 501 34/32',ledger_status:'LISTED-BACKLOG',total_capital:50,purchased_on:'2026-06-01'},
  {item_id:'DEN-5',name:'Levis 501 W34 L32',ledger_status:'UNLISTED-BACKLOG',total_capital:35,purchased_on:'2026-08-01'},
  {item_id:'DEN-6',name:'Lee 101 W32 L32',ledger_status:'UNLISTED-BACKLOG',total_capital:40,purchased_on:'2026-08-01',item_dna:{facts:{brand:'Lee',model:'101',tagged_size:'W32 L32'}}},
  {item_id:'DEN-7',name:'Levis 501 W29 L32',ledger_status:'SOLD',sale_price_arbitrage:120,total_capital:30,sold_on:'2026-07-10'}
];
assert.equal(sizeBand(29),'W<=29');assert.equal(sizeBand(30),'W30-32');assert.equal(sizeBand(33),'W33-35');assert.equal(sizeBand(36),'W36+');
const segments=buildSourcing(items,cells,new Date('2026-08-11T12:00:00Z'),120),levis=segments.find(row=>row.f.model==='501'&&row.f.band==='W33-35'),lee=segments.find(row=>row.f.model==='101'),small=segments.find(row=>row.f.band==='W<=29');
assert.equal(levis.action,'OPEN_REPLACEMENT');assert.equal(levis.soldRecent.length,3);assert.equal(levis.listed.length,1);assert.equal(levis.unlisted.length,1);assert.equal(levis.unlistedCapital,35);assert.equal(levis.medianSale,160);assert.equal(levis.medianProfit,110);assert.equal(levis.policy.max_landed_cost,50);
assert.equal(lee.action,'CLOSED');assert.equal(small.action,'CLOSED');assert.equal(policyFor(levis.f,cells).cell_id,'green');
const migration=readFileSync(new URL('../supabase/migrations/20260811143000_sourcing_capacity_gate.sql',import.meta.url),'utf8');
assert.match(migration,/hq_sourcing_gate_current/);assert.match(migration,/ONE_CONFIRMED_SALE_ONE_REPLACEMENT/);assert.match(migration,/hq_sourcing_replacement_queue_current/);assert.match(migration,/hq_capture_sourcing_replacement_release/);for(const den of ['202','264','225','223','285'])assert.match(migration,new RegExp(`DEN-${den}`));
const encodingRepair=readFileSync(new URL('../supabase/migrations/20260811180000_sourcing_utf8_data_repair.sql',import.meta.url),'utf8');
assert.doesNotMatch(encodingRepair,/[^\x00-\x7f]/,'Sourcing repair migration must stay ASCII-only in transport');
assert.match(encodingRepair,/convert_from\(decode\(/);assert.match(encodingRepair,/hq_sourcing_gate_current/);assert.match(encodingRepair,/Sourcing UTF-8 repair incomplete/);
for(const id of ['G-501-33-35','G-505-30-32','G-505-33-35','G-WRANGLER-30-32','G-WRANGLER-33-35','G-550-30-32','G-550-33-35','G-615-30-32','G-615-33-35','R-SMALL-WAIST','R-LEE-GENERIC','R-ORDINARY-219','R-OFF-NICHE','DEN-202','DEN-264','DEN-225','DEN-223','DEN-285'])assert.match(encodingRepair,new RegExp(id));
console.log('Sourcing capacity gate tests passed');
