import assert from 'node:assert/strict';
import {buildExperimentCandidates,specialtySignals} from './pricing-candidates.js';

const sold=Array.from({length:5},(_,i)=>({item_id:`DEN-S${i}`,name:`Levis 501 W${31+i%3}`,ledger_status:'SOLD',sale_price_arbitrage:145+i*5,sold_on:`2026-08-0${i+1}`}));
const snapshots=(id,price,likes,days=30,extra=[])=>[
  {vinted_item_id:id,captured_at:`2026-07-${String(11-days%10).padStart(2,'0')}T10:00:00Z`,price_pln:price,favourites:likes},
  ...extra,
  {vinted_item_id:id,captured_at:'2026-08-10T10:00:00Z',price_pln:price,favourites:likes}
];
const live=(id,price,likes,listed='2026-07-01',name='Levis 501 W32')=>({item_id:id,name,ledger_status:'LISTED-BACKLOG',vinted_item_id:id,live_list_price:price,total_capital:40,listed_on:listed,_likes:likes});
const warm=live('DEN-PRICE',219,6),cold=live('DEN-EXPO',159,2),rare=live('DEN-RARE',269,4,'2026-06-01','Levis 501 White Oak selvedge W32');
const all=[...sold,warm,cold,rare];
const history=[...snapshots(warm.vinted_item_id,219,6),...snapshots(cold.vinted_item_id,159,2),...snapshots(rare.vinted_item_id,269,4)];
const result=buildExperimentCandidates(all,history,new Set(),new Date('2026-08-11T12:00:00Z'));
assert.equal(result.price[0].item.item_id,'DEN-PRICE');
assert.equal(result.exposure[0].item.item_id,'DEN-EXPO');
assert.equal(result.special[0].item.item_id,'DEN-RARE');
assert.ok(specialtySignals(rare).includes('selvedge'));
assert.ok(result.price[0].proposedPrice<219);
assert.equal(buildExperimentCandidates(all,history,new Set(['DEN-PRICE']),new Date('2026-08-11T12:00:00Z')).price.length,0);
const changed=live('DEN-CHANGED',219,6),changedHistory=snapshots(changed.vinted_item_id,219,6,30,[{vinted_item_id:changed.vinted_item_id,captured_at:'2026-08-08T10:00:00Z',price_pln:239,favourites:6}]);
assert.equal(buildExperimentCandidates([...sold,changed],changedHistory,new Set(),new Date('2026-08-11T12:00:00Z')).price.length,0);
console.log('Pricing candidate algorithm tests passed');
