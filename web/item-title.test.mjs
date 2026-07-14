import assert from 'node:assert/strict';
import {itemTitle} from './item-title.js';

assert.equal(itemTitle({name:'Archiwalny skrót',live_title:'Levi’s 521 Comfort Tapered Jeans'}),'Levi’s 521 Comfort Tapered Jeans');
assert.equal(itemTitle({name:'Archiwalny skrót'}),'Archiwalny skrót');
assert.equal(itemTitle({live_title:'   ',name:'Nazwa zakupu'}),'Nazwa zakupu');
assert.equal(itemTitle({}),'Bez nazwy');
console.log('item-title tests passed');
