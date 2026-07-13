import assert from 'node:assert/strict';
import {buildCockpit,estimate,recommendation} from './pricing.js';
const sold=[
 {item_id:'DEN-001',name:'Levis 501 W32',ledger_status:'SOLD',sale_price_arbitrage:150,sold_on:'2026-05-01'},
 {item_id:'DEN-002',name:'Levis 501 W33',ledger_status:'SOLD',sale_price_arbitrage:160,sold_on:'2026-05-10'},
 {item_id:'DEN-003',name:'Levis 501 W32',ledger_status:'SOLD',sale_price_arbitrage:155,sold_on:'2026-05-20'},
 {item_id:'DEN-004',name:'Levis 501 W31',ledger_status:'SOLD',sale_price_arbitrage:165,sold_on:'2026-06-01'},
 {item_id:'DEN-005',name:'Levis 501 W32',ledger_status:'SOLD',sale_price_arbitrage:158,sold_on:'2026-06-10'},
 {item_id:'DEN-006',name:'Levis 501 W34',ledger_status:'SOLD',sale_price_arbitrage:152,sold_on:'2026-06-20'},
 {item_id:'DEN-007',name:'Lee 101 W32',ledger_status:'SOLD',sale_price_arbitrage:120,sold_on:'2026-06-25'},
 {item_id:'DEN-008',name:'Levis 501 W33',ledger_status:'SOLD',sale_price_arbitrage:162,sold_on:'2026-07-01'}
];
const live={item_id:'DEN-200',name:'Levis 501 W32',ledger_status:'LISTED-BACKLOG',vinted_item_id:'1',live_list_price:190,total_capital:40,listed_on:'2026-06-01'};
const model=estimate(live,sold);assert.equal(model.status,'READY');assert.ok(model.center>=150&&model.center<=165);const cockpit=buildCockpit([...sold,live],[{vinted_item_id:'1',captured_at:'2026-06-01T10:00:00Z',price_pln:190,favourites:0,views:10},{vinted_item_id:'1',captured_at:'2026-07-13T10:00:00Z',price_pln:190,favourites:0,views:30}]);assert.equal(cockpit.rows[0].decision.action,'TEST_LOWER');assert.ok(cockpit.rows[0].decision.nextPrice>=live.total_capital);const stale=recommendation(live,model,{latest:{captured_at:'2026-06-01'},snapshotAge:4,price:190},{});assert.equal(stale.action,'OBSERVE');const protectedFloor=recommendation({...live,total_capital:188},model,{latest:{captured_at:'2026-07-12'},snapshotAge:0,price:190,daysLive:30,likesDelta:0},{});assert.equal(protectedFloor.action,'PRESENTATION');console.log('Pricing cockpit tests passed');
