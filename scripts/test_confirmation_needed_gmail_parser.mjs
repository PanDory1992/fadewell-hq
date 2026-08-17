import assert from 'node:assert/strict';
import { parseVintedMail } from '../supabase/functions/hq-gmail-sync/vinted-parser.mjs';

for (const message of [
  { subject: 'Confirmation needed', body: '' },
  { subject: 'Confirm your order', body: 'Confirm your order for Vintage denim in Vinted.' },
  { subject: 'Vinted', body: 'Confirmation needed' }
]) {
  const parsed = parseVintedMail(message);
  assert.equal(parsed.event_type, 'NOISE');
  assert.equal(parsed.template_id, 'confirmation_needed_trash_en_v1');
}

console.log('Confirmation-needed Gmail parser checks passed');
