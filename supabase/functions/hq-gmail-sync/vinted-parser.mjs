export const VINTED_PARSER_VERSION = '2026-07-15.template.v2';

export const nonEmptyLines = (body) => body.replace(/\r/g, '').split('\n').map((line) => line.replace(/\s+/g, ' ').trim()).filter(Boolean);
const normalized = (value) => value.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();
const field = (value, status = 'CONFIRMED') => ({ value: value ?? null, status: value === null || value === undefined || value === '' ? 'MISSING' : status });
const labelValue = (body, label) => {
  const all = nonEmptyLines(body); const index = all.findIndex((line) => normalized(line) === normalized(label));
  return index >= 0 ? all[index + 1] || null : null;
};
const betweenLabels = (body, start, end) => {
  const all = nonEmptyLines(body); const index = all.findIndex((line) => normalized(line) === normalized(start));
  const stop = index < 0 ? -1 : all.slice(index + 1).findIndex((line) => normalized(line) === normalized(end));
  return index < 0 ? [] : all.slice(index + 1, stop < 0 ? undefined : index + 1 + stop);
};
const money = (value) => {
  const match = value?.match(/([0-9]+[.,][0-9]+)/); const amount = Number((match?.[1] || '').replace(',', '.'));
  return Number.isFinite(amount) && amount > 0 ? amount : null;
};
const moneyAfter = (body, label) => money(labelValue(body, label));
const transactionId = (body) => body.match(/Transaction ID\s*:?\s*#?(\d+)/i)?.[1] || labelValue(body, 'Transaction ID')?.match(/\d+/)?.[0] || null;
const completedTitle = (body) => body.match(/Your sale of\s+([\s\S]*?)\s+was completed successfully/i)?.[1]?.replace(/\s+/g, ' ').trim()
  || (() => { const all = nonEmptyLines(body); const start = all.findIndex((line) => /^Your sale of\s+/i.test(line)); const stop = start < 0 ? -1 : all.slice(start).findIndex((line) => /was completed successfully/i.test(line)); return start >= 0 && stop >= 0 ? all.slice(start, start + stop + 1).join(' ').replace(/^Your sale of\s+/i, '').replace(/\s+was completed successfully\.?$/i, '').trim() : null; })();
const pendingSale = (body) => {
  const match = body.match(/has bought\s*\n+([^\n]+)\s*\n+\s*[^\d\n]*([0-9]+[.,][0-9]+)/i);
  return { title: match?.[1]?.trim() || null, amount: money(match?.[2] || null) };
};
const NOISE_SUBJECT = /(shipping label|etykiet[aę] wysy[łl]kow|new message|nowa wiadomo|added .* to (their )?(favourites|favorites)|dodał.* do ulubionych|left you a review|wystawi[ał].* opini|price drop|obni[żz]ka ceny|newsletter|promo)/i;

const result = (eventType, templateId, values) => ({
  event_type: eventType,
  template_id: templateId,
  fields: {
    transaction_id: field(values.transaction_id),
    item_title: field(values.item_title),
    amount: field(values.amount),
    bundle_items: field(values.bundle_items?.length ? values.bundle_items : null),
    transaction_date: field(values.transaction_date),
    tracking_code: field(values.tracking_code)
  },
  item_title: values.item_title || '',
  amount: values.amount ?? null,
  transaction_id: values.transaction_id || null,
  bundle_items: values.bundle_items || []
});

export const parseVintedMail = ({ subject, body }) => {
  const transaction = transactionId(body);
  if (/^Your receipt for/i.test(subject)) {
    const bundleMatch = subject.match(/Bundle\s+(\d+)\s+items?/i);
    const orderItems = betweenLabels(body, 'Order', 'Paid');
    const bundleItems = bundleMatch && Number(bundleMatch[1]) > 1 ? orderItems.slice(0, Number(bundleMatch[1])) : [];
    const title = bundleItems.length ? bundleItems.join(' · ') : orderItems[0] || null;
    return result(bundleItems.length ? 'PURCHASE_BUNDLE' : 'PURCHASE_CONFIRMED', bundleItems.length ? 'purchase_bundle_receipt_en_v1' : 'purchase_receipt_en_v1', {
      transaction_id: transaction, item_title: title, amount: moneyAfter(body, 'Paid'), bundle_items: bundleItems,
      transaction_date: labelValue(body, 'Payment date')
    });
  }
  if (/^You.ve sold an item on Vinted/i.test(subject)) {
    const sale = pendingSale(body);
    return result('SALE_PENDING', 'sale_pending_en_v1', { transaction_id: transaction, item_title: sale.title, amount: sale.amount });
  }
  if (/^This order is completed/i.test(subject)) {
    return result('SALE_CONFIRMED', 'sale_completed_en_v1', {
      transaction_id: transaction, item_title: completedTitle(body), amount: moneyAfter(body, 'Transferred to your Vinted Balance'), transaction_date: labelValue(body, 'Date')
    });
  }
  if (/shipping label|etykiet[aę] wysy[łl]kow/i.test(subject)) {
    return result('NOISE', 'shipping_label_en_v1', {
      transaction_id: transaction, item_title: labelValue(body, 'Item name'), tracking_code: labelValue(body, 'Tracking code'), transaction_date: labelValue(body, 'Shipment deadline')
    });
  }
  if (/^Confirm your order/i.test(subject)) {
    const title = body.match(/Confirm your order for\s+(.+?)\s+in Vinted\.?$/im)?.[1]?.trim() || null;
    return result('UNCLASSIFIED', 'confirmation_needed_en_v1', { item_title: title });
  }
  if (NOISE_SUBJECT.test(subject)) return result('NOISE', 'noise_subject_en_v1', {});
  return result('UNCLASSIFIED', 'unknown_v1', {});
};
