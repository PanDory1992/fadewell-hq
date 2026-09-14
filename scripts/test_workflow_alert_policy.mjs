import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const storefront = readFileSync(new URL('../.github/workflows/storefront-sync.yml', import.meta.url), 'utf8');
const failedRefreshBlock = storefront.match(/- name: Suppress a transient failure[\s\S]*?(?=\n\s*- name:)/)?.[0] || '';

assert.match(failedRefreshBlock, /continue-on-error:\s*true/, 'A stale Storefront must remain visible without failing every 15-minute workflow dispatch.');
assert.match(storefront, /Keep persistent failure visible without notification spam/, 'Persistent Storefront failures must remain visible as workflow warnings.');

console.log('Workflow alert policy checks passed');
