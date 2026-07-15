import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const fixtureRoot = resolve(root, 'data/private_gmail_fixtures');
const manifest = JSON.parse(await readFile(resolve(fixtureRoot, 'manifest.json'), 'utf8'));

const forbidden = [
  'falka.falka35', 'mikit', 'Sokołowska', 'Warszawa', '01-142',
  '20867307537', '20939269580', '20929466259', 'pejzazclothes123', 'dajakaja123',
];
const required = ['purchase_single', 'purchase_bundle', 'sale_pending', 'sale_completed', 'shipping_label_en'];
const failures = [];

if (manifest.version !== 1 || manifest.fixture_policy !== 'private_anonymized_real_mail') {
  failures.push('Manifest does not declare the required private fixture policy.');
}
for (const name of required) {
  if (!manifest.fixtures.some((fixture) => fixture.name === name && fixture.observed === true)) {
    failures.push(`Missing observed required fixture: ${name}`);
  }
}
for (const fixture of manifest.fixtures) {
  const body = await readFile(resolve(fixtureRoot, fixture.file), 'utf8');
  if (!body.includes('From: Team Vinted <no-reply@vinted.pl>')) failures.push(`${fixture.name}: missing trusted sender shape.`);
  if (!body.includes(`Subject: ${fixture.subject}`)) failures.push(`${fixture.name}: subject differs from manifest.`);
  for (const value of forbidden) if (body.toLowerCase().includes(value.toLowerCase())) failures.push(`${fixture.name}: contains non-anonymized value '${value}'.`);
  for (const expected of fixture.expect) if (!body.includes(expected)) failures.push(`${fixture.name}: missing expected structure '${expected}'.`);
}

if (failures.length) {
  console.error('Private Gmail fixture gate failed:\n' + failures.map((failure) => `- ${failure}`).join('\n'));
  process.exit(1);
}
console.log(`Private Gmail fixture gate passed (${manifest.fixtures.length} observed fixtures; ${manifest.coverage_gaps.length} known gaps).`);
