import assert from 'node:assert/strict';
import {isDenimItem,itemTitle} from './item-title.js';

assert.equal(itemTitle({name:'Archive shorthand',live_title:'Vinted title',manual_title:'HQ manual title'}),'Vinted title');

assert.equal(itemTitle({name:'Archiwalny skrót',live_title:'Levi’s 521 Comfort Tapered Jeans'}),'Levi’s 521 Comfort Tapered Jeans');
assert.equal(itemTitle({name:'Archiwalny skrót'}),'Archiwalny skrót');
assert.equal(itemTitle({live_title:'   ',name:'Nazwa zakupu'}),'Nazwa zakupu');
assert.equal(itemTitle({}),'Bez nazwy');
assert.equal(isDenimItem({live_title:'Vintage Wool Mohair Womens Coat'}),false);
assert.equal(isDenimItem({name:'Buty Converse Szare'}),false);
assert.equal(isDenimItem({name:'GAP XXL Katana Dziecko Nwot'}),false);
assert.equal(isDenimItem({live_title:"Levi’s 566 Regular Straight Vintage 1995 – W32 L32"}),true);
assert.equal(isDenimItem({name:'Levis'}),true);
assert.equal(isDenimItem({name:'Spodnie damskie'}),true);
console.log('item-title tests passed');
