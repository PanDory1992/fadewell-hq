import assert from 'node:assert/strict';
import { parseVintedMail } from '../supabase/functions/_shared/vinted-gmail-parser.mjs';

const subject = 'You’ve sold an item on Vinted';
// Observed Apps Script plain-text shape: image alt text precedes a wrapped title.
const body = `[buyer redacted] has bought
[image: Levi’s 501 Original Fit Jeans – Dark Indigo – W32 L30 – Vintage
Made in Poland 2002]
Levi’s 501 Original Fit Jeans – Dark Indigo – W32 L30 – Vintage Made in
Poland 2002
zł179.10
We will transfer the buyer's payment to your Vinted Balance once the order
is completed.`;
const parsed = parseVintedMail({ subject, body });
assert.equal(parsed.item_title, 'Levi’s 501 Original Fit Jeans – Dark Indigo – W32 L30 – Vintage Made in Poland 2002');
assert.equal(parsed.amount, 179.10);
assert.equal(parsed.event_type, 'SALE_PENDING');
assert.equal(parseVintedMail({ subject, body: '[buyer redacted] has bought\nJeans\nzł0.00' }).amount, null);
assert.equal(parseVintedMail({ subject, body: '[buyer redacted] has bought\nJeans\nWe will transfer the payment\nOther value zł99.00' }).amount, null);
assert.equal(parseVintedMail({ subject, body: '[buyer redacted] has bought\n[image: Jeans]\nzł20.00' }).item_title, '');
console.log('Wrapped pending-sale parser checks passed');
