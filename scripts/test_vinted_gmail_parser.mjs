import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { parseVintedMail } from '../supabase/functions/hq-gmail-sync/vinted-parser.mjs';

const root = resolve(import.meta.dirname, '..');
const fixtureRoot = resolve(root, 'data/private_gmail_fixtures');
const manifest = JSON.parse(await readFile(resolve(fixtureRoot, 'manifest.json'), 'utf8'));
const failures = [];

for (const fixture of manifest.fixtures.filter((fixture) => fixture.observed)) {
  const source = await readFile(resolve(fixtureRoot, fixture.file), 'utf8');
  const separator = source.search(/\r?\n\r?\n/);
  const body = separator < 0 ? '' : source.slice(separator).replace(/^\r?\n\r?\n/, '');
  const parsed = parseVintedMail({ subject: fixture.subject, body });
  for (const [key, expected] of Object.entries(fixture.expected_parse || {})) {
    const actual = key in parsed.fields ? parsed.fields[key].value : parsed[key];
    if (JSON.stringify(actual) !== JSON.stringify(expected)) failures.push(`${fixture.name}: ${key} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}.`);
  }
}

if (failures.length) {
  console.error('Vinted Gmail parser regression failed:\n' + failures.map((failure) => `- ${failure}`).join('\n'));
  process.exit(1);
}
console.log(`Vinted Gmail parser regression passed (${manifest.fixtures.filter((fixture) => fixture.observed).length} observed fixtures).`);
