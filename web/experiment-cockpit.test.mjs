import assert from 'node:assert/strict';
import {buildExperimentCockpit,experimentTotals,gateCopy} from './experiment-cockpit.js';

const progress=[{experiment_id:'EXP-PRICE',experiment_type:'PRICE_VELOCITY',item_count:3,sold_count:1,active_count:1,capital_released:40,day_7_gate:'COLLECTING'}];
const rows=[
  {experiment_id:'EXP-PRICE',item_id:'DEN-1',display_state:'WAITING_COLLECTOR'},
  {experiment_id:'EXP-PRICE',item_id:'DEN-2',display_state:'ACTIVE'},
  {experiment_id:'EXP-PRICE',item_id:'DEN-3',display_state:'SOLD'}
];
const cockpit=buildExperimentCockpit(progress,rows);
assert.equal(cockpit.length,1);
assert.equal(cockpit[0].lanes.WAITING_COLLECTOR.length,1);
assert.equal(cockpit[0].lanes.ACTIVE.length,1);
assert.equal(cockpit[0].lanes.SOLD.length,1);
assert.equal(cockpit[0].gateLabel,gateCopy.COLLECTING);
assert.deepEqual(experimentTotals(cockpit),{experiments:1,items:3,sold:1,active:1,waitingCollector:1,toExecute:0,capitalReleased:40});
console.log('Experiment cockpit tests passed');
