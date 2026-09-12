import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const pages = Object.fromEntries(await Promise.all(
  ['oauth', 'privacy', 'terms'].map(async name => [
    name,
    await readFile(new URL(`./${name}.html`, import.meta.url), 'utf8')
  ])
));

assert.match(pages.oauth, /href="privacy\.html"/);
assert.match(pages.oauth, /href="terms\.html"/);
assert.match(pages.privacy, /Google API Services User Data Policy/);
assert.match(pages.privacy, /gmail\.modify/);
assert.match(pages.terms, /href="privacy\.html"/);

for (const [name, html] of Object.entries(pages)) {
  assert.match(html, /<!doctype html>/i, `${name}.html is a standalone document`);
  assert.doesNotMatch(html, /hq\.js|shell\s*\(/, `${name}.html must stay public without HQ authentication`);
}

console.log('OAuth public pages contract passed.');
