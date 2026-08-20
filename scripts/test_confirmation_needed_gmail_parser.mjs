import assert from 'node:assert/strict';
import { parseVintedMail } from '../supabase/functions/hq-gmail-sync/vinted-parser.mjs';

for (const message of [
  { subject: 'Confirmation needed', body: '' },
  { subject: 'Confirm your order', body: 'Confirm your order for Vintage denim in Vinted.' },
  { subject: 'Vinted', body: 'Confirmation needed' },
  { subject: 'Spodnie jeansowe - Confirmation needed', body: '' },
  { subject: 'Lee traperice – Confirmation needed', body: '' }
]) {
  const parsed = parseVintedMail(message);
  assert.equal(parsed.event_type, 'NOISE');
  assert.equal(parsed.template_id, 'confirmation_needed_trash_en_v1');
}

const prefixed = parseVintedMail({ subject: 'Spodnie jeansowe - Confirmation needed', body: '' });
assert.equal(prefixed.item_title, 'Spodnie jeansowe');
assert.equal(parseVintedMail({ subject: 'Confirmation needed', body: '' }).item_title, '');

console.log('Confirmation-needed Gmail parser checks passed');
