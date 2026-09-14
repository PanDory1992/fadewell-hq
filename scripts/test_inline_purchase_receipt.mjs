import assert from 'node:assert/strict';
import { parseVintedMail } from '../supabase/functions/_shared/vinted-gmail-parser.mjs';

const parsed = parseVintedMail({
  subject: 'Your receipt for "Wrangler jeans W31 L32"',
  body: `Your Vinted purchase receipt:
*Seller* [seller redacted]
*Order*
Wrangler jeans W31 L32
*Paid* zł30.95
Item zł20.00
Postage zł7.05
Buyer Protection fee zł3.90
*Payment method* Vinted Balance (zł30.95)
*Payment date* 14/09/2026 12:13
*Transaction ID* 22288370693`,
});

assert.equal(parsed.event_type, 'PURCHASE_CONFIRMED');
assert.equal(parsed.template_id, 'purchase_receipt_en_v1');
assert.equal(parsed.item_title, 'Wrangler jeans W31 L32');
assert.equal(parsed.amount, 30.95);
assert.equal(parsed.transaction_id, '22288370693');
assert.equal(parsed.fields.transaction_date.value, '14/09/2026 12:13');

console.log('Inline Vinted purchase receipt parser checks passed');
