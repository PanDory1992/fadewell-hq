import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const finance=readFileSync(new URL('./finance.html',import.meta.url),'utf8');
assert.match(finance,/const unknownDate=items=>/);
assert.match(finance,/period_start:null/);
assert.match(finance,/visible=\[undated,/);
assert.match(finance,/'Unknown date'/);
assert.match(finance,/purchase_count:purchases\.length/);
assert.match(finance,/Unknown date zbiera sprzedaże i zakupy bez dokładnej daty/);
assert.match(finance,/const localDate=value=>/);
assert.match(finance,/return localDate\(new Date\(d\.getFullYear\(\),d\.getMonth\(\),1\)\)/);
assert.match(finance,/return localDate\(d\)/);
console.log('Finance unknown-date chart regression checks passed');
