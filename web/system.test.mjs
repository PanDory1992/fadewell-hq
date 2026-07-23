import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const system=readFileSync(new URL('./system.html',import.meta.url),'utf8');
const operations=readFileSync(new URL('./operations.html',import.meta.url),'utf8');
assert.match(system,/Poczta Vinted/);
assert.match(system,/Ostatnia udana synchronizacja:/);
assert.match(system,/Połączenie OAuth jest potwierdzone/);
assert.match(system,/POŁĄCZONO — TRWA PIERWSZA SYNCHRONIZACJA/);
assert.match(system,/aktualnie otwarte/);
assert.match(system,/BŁĄD SYNCHRONIZACJI/);
assert.match(system,/WYMAGA PONOWNEGO POŁĄCZENIA/);
assert.match(operations,/Stan połączenia Gmail jest w System/);
assert.match(operations,/Kolejka transakcji/);
console.log('System Gmail health UX regression checks passed');
