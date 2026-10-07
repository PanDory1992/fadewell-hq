import { createClient } from 'npm:@supabase/supabase-js@2';

const endpoint = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
const db = createClient(endpoint, serviceKey);
const bucket = 'hq-purchase-photos';
const headers = { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': 'https://hq.fadewell.eu', 'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info', 'access-control-allow-methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

function listingId(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !['vinted.pl', 'www.vinted.pl'].includes(url.hostname)) return null;
    return url.pathname.match(/^\/items\/(\d+)(?:-[^/]*)?\/?$/)?.[1] || null;
  } catch { return null; }
}

function firstPhotos(html: string): string[] {
  const images: string[] = [];
  for (const match of html.matchAll(/<link\s+[^>]*rel="preload"[^>]*as="image"[^>]*href="([^"]+)"/g)) {
    const image = new URL(match[1].replaceAll('&amp;', '&'));
    if (!/^images\d*\.vinted\.net$/.test(image.hostname) || image.protocol !== 'https:') continue;
    if (!images.includes(image.href)) images.push(image.href);
    if (images.length === 3) break;
  }
  return images;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return reply({ error: 'POST required' }, 405);
  const bearer = request.headers.get('authorization') || '';
  if (!/^Bearer\s+\S+$/.test(bearer)) return reply({ error: 'Owner sign-in required' }, 401);
  const ownerClient = createClient(endpoint, anonKey, { global: { headers: { Authorization: bearer } } });
  const { data: owner, error: ownerError } = await ownerClient.rpc('is_hq_owner');
  if (ownerError || owner !== true) return reply({ error: 'HQ owner access required' }, 403);

  let input: Record<string, unknown>;
  try { input = await request.json(); } catch { return reply({ error: 'Invalid JSON' }, 400); }
  const itemId = String(input.item_id || '').trim();
  const rawUrl = String(input.listing_url || '').trim();
  const id = listingId(rawUrl);
  if (!/^DEN-\d+$/.test(itemId) || !id) return reply({ error: 'Known DEN and Vinted item URL required' }, 400);
  const { data: item, error: itemError } = await db.from('hq_ledger_items').select('item_id,ledger_status').eq('item_id', itemId).maybeSingle();
  if (itemError || !item || item.ledger_status === 'VOIDED') return reply({ error: 'Active DEN item required' }, 400);
  const { data: existing, error: existingError } = await db.from('hq_purchase_source_photos').select('item_id,source_listing_id,photo_paths').eq('item_id', itemId).maybeSingle();
  if (existingError) return reply({ error: existingError.message }, 500);
  if (existing) return reply({ error: 'Purchase photos already archived for this DEN; existing evidence was preserved', source_listing_id: existing.source_listing_id }, 409);

  const sourceUrl = `https://www.vinted.pl/items/${id}`;
  const supplied = Array.isArray(input.images) ? input.images : [];
  if (supplied.length > 3) return reply({ error: 'At most three images are allowed' }, 400);
  let photos: string[] = [];
  if (!supplied.length) {
    try {
      const page = await fetch(sourceUrl, { headers: { 'user-agent': 'Mozilla/5.0 (compatible; FADEWELL-HQ/1.0)' } });
      if (!page.ok) return reply({ error: `Vinted listing unavailable (${page.status}); upload the original photos from your browser` }, 422);
      photos = firstPhotos(await page.text());
    } catch { return reply({ error: 'Could not fetch Vinted listing; upload the original photos from your browser' }, 422); }
    if (!photos.length) return reply({ error: 'No original listing photos available; upload them from your browser' }, 422);
  }

  const paths: string[] = [];
  for (let index = 0; index < (supplied.length || photos.length); index++) {
    let type: string;
    let bytes: Uint8Array;
    if (supplied.length) {
      const value = String(supplied[index] || '');
      const match = /^data:(image\/(?:webp|jpeg|png));base64,([A-Za-z0-9+/=]+)$/.exec(value);
      if (!match) return reply({ error: `Photo ${index + 1} must be a JPEG, PNG or WebP file` }, 400);
      type = match[1];
      try { bytes = Uint8Array.from(atob(match[2]), c => c.charCodeAt(0)); } catch { return reply({ error: `Photo ${index + 1} is invalid` }, 400); }
    } else {
      let image: Response;
      try { image = await fetch(photos[index]); } catch { return reply({ error: `Could not fetch photo ${index + 1}` }, 422); }
      type = (image.headers.get('content-type') || '').split(';')[0].toLowerCase();
      if (!image.ok || !['image/webp', 'image/jpeg', 'image/png'].includes(type)) return reply({ error: `Photo ${index + 1} unavailable` }, 422);
      bytes = new Uint8Array(await image.arrayBuffer());
    }
    if (!bytes.length || bytes.length > 5_242_880) return reply({ error: `Photo ${index + 1} has invalid size` }, 422);
    const valid = type === 'image/jpeg' ? bytes[0] === 0xff && bytes[1] === 0xd8 : type === 'image/png' ? bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 : new TextDecoder().decode(bytes.slice(0, 4)) === 'RIFF' && new TextDecoder().decode(bytes.slice(8, 12)) === 'WEBP';
    if (!valid) return reply({ error: `Photo ${index + 1} content does not match its type` }, 400);
    const extension = type === 'image/jpeg' ? 'jpg' : type === 'image/png' ? 'png' : 'webp';
    const path = `${itemId}/${id}/${index + 1}.${extension}`;
    const { error } = await db.storage.from(bucket).upload(path, bytes, { contentType: type, upsert: false });
    if (error && !/already exists|duplicate/i.test(error.message)) return reply({ error: `Photo ${index + 1} archive failed` }, 500);
    paths.push(path);
  }
  const { error: saveError } = await db.from('hq_purchase_source_photos').insert({ item_id: itemId, source_listing_id: id, source_listing_url: sourceUrl, photo_paths: paths, capture_source: supplied.length ? 'OWNER_UPLOADED_VINTED_IMAGES' : 'OWNER_CONFIRMED_VINTED_URL' });
  if (saveError) return reply({ error: saveError.message }, 500);
  return reply({ item_id: itemId, source_listing_id: id, archived: paths.length });
});
