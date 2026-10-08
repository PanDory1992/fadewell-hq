import { createClient } from 'npm:@supabase/supabase-js@2';

const endpoint = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
const db = createClient(endpoint, serviceKey);
const bucket = 'hq-purchase-photos';
const headers = { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': 'https://hq.fadewell.eu', 'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info', 'access-control-allow-methods': 'POST, OPTIONS' };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
const browserHeaders = { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36', 'accept': 'text/html,application/xhtml+xml', 'referer': 'https://www.vinted.pl/' };

function listingId(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !['vinted.pl', 'www.vinted.pl'].includes(url.hostname)) return null;
    return url.pathname.match(/^\/items\/(\d+)(?:-[^/]*)?\/?$/)?.[1] || null;
  } catch { return null; }
}

function listingTitle(page: string): string {
  const raw = page.match(/<title[^>]*>(.*?)<\/title>/is)?.[1] || '';
  return raw.replace(/\s*\|\s*Vinted\s*$/i, '').replace(/&#(x[0-9a-f]+|\d+);/gi, (_, value) => {
    const code = value[0].toLowerCase() === 'x' ? parseInt(value.slice(1), 16) : parseInt(value, 10);
    return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  }).replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&apos;', "'").trim();
}

function firstPhotos(page: string): string[] {
  const found: string[] = [];
  for (const match of page.matchAll(/<link\s+[^>]*rel="preload"[^>]*as="image"[^>]*href="([^"]+)"/gi)) {
    const raw = match[1].replaceAll('&amp;', '&');
    let url: URL;
    try { url = new URL(raw); } catch { continue; }
    if (url.protocol !== 'https:' || !/^images\d*\.vinted\.net$/.test(url.hostname)) {
      if (found.length) break;
      continue;
    }
    if (!found.includes(url.href)) found.push(url.href);
    if (found.length === 3) break;
  }
  return found;
}

function sellerName(page: string, id: string): string | null {
  const escapedMarker = `item_id\\":\\"${id}\\"`;
  let from = 0;
  while (from < page.length) {
    const index = page.indexOf(escapedMarker, from);
    if (index < 0) break;
    const match = page.slice(index + escapedMarker.length, index + escapedMarker.length + 150)
      .match(/^,\\"name\\":\\"([^"\\]{2,80})\\"/);
    if (match) return match[1];
    from = index + escapedMarker.length;
  }
  return null;
}

function validImage(bytes: Uint8Array, type: string): boolean {
  if (bytes.length < 12 || bytes.length > 5_242_880) return false;
  if (type === 'image/jpeg') return bytes[0] === 0xff && bytes[1] === 0xd8;
  if (type === 'image/png') return bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (type === 'image/webp') return new TextDecoder().decode(bytes.slice(0, 4)) === 'RIFF' && new TextDecoder().decode(bytes.slice(8, 12)) === 'WEBP';
  return false;
}

async function reconcileRecentPurchases() {
  const { data, error } = await db.from('hq_purchase_photo_ingest_jobs').select('source_event_id')
    .in('state', ['PENDING', 'NEEDS_REVIEW', 'CAPTURED']).order('created_at', { ascending: false }).limit(50);
  if (error) throw error;
  for (const job of data || []) {
    const result = await db.rpc('match_hq_sourcing_photos', { p_source_event_id: job.source_event_id });
    if (result.error) throw result.error;
  }
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
  const id = listingId(String(input.listing_url || '').trim());
  if (!id) return reply({ error: 'A specific Vinted item URL is required' }, 400);
  const { data: existing, error: lookupError } = await db.from('hq_sourcing_source_captures').select('source_listing_id,photo_paths,captured_at').eq('source_listing_id', id).maybeSingle();
  if (lookupError) return reply({ error: 'Could not read existing capture' }, 500);
  if (existing) {
    try { await reconcileRecentPurchases(); } catch { return reply({ error: 'Saved photos exist, but purchase matching must be retried' }, 500); }
    return reply({ source_listing_id: id, archived: existing.photo_paths.length, captured_at: existing.captured_at, already_captured: true });
  }
  const listingUrl = `https://www.vinted.pl/items/${id}`;
  let page: Response;
  try { page = await fetch(listingUrl, { headers: browserHeaders, signal: AbortSignal.timeout(20_000) }); }
  catch { return reply({ error: 'Vinted listing could not be loaded' }, 422); }
  if (!page.ok) return reply({ error: `Vinted listing unavailable (${page.status})` }, 422);
  const html = await page.text();
  const title = listingTitle(html);
  const photos = firstPhotos(html);
  if (!title || !photos.length) return reply({ error: 'Listing title or original photos unavailable' }, 422);
  const paths: string[] = [];
  for (let index = 0; index < photos.length; index++) {
    let response: Response;
    try { response = await fetch(photos[index], { signal: AbortSignal.timeout(20_000) }); }
    catch { return reply({ error: `Photo ${index + 1} could not be loaded` }, 422); }
    const mime = (response.headers.get('content-type') || '').split(';')[0].toLowerCase();
    if (Number(response.headers.get('content-length') || 0) > 5_242_880) return reply({ error: `Photo ${index + 1} exceeds the size limit` }, 422);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (!response.ok || !validImage(bytes, mime)) return reply({ error: `Photo ${index + 1} is invalid` }, 422);
    const extension = { 'image/webp': 'webp', 'image/jpeg': 'jpg', 'image/png': 'png' }[mime]!;
    const path = `sourcing/${id}/${index + 1}.${extension}`;
    const { error } = await db.storage.from(bucket).upload(path, bytes, { contentType: mime, upsert: false });
    if (error && !/already exists|duplicate/i.test(error.message)) return reply({ error: `Photo ${index + 1} could not be archived` }, 500);
    paths.push(path);
  }
  const { error: saveError } = await db.from('hq_sourcing_source_captures').insert({ source_listing_id: id,
    source_listing_url: listingUrl, listing_title: title, seller_name: sellerName(html, id), photo_paths: paths,
    capture_source: 'HQ_SOURCE_LINK' });
  if (saveError && saveError.code !== '23505') return reply({ error: 'Could not record the captured listing' }, 500);
  try { await reconcileRecentPurchases(); } catch { return reply({ error: 'Photos were saved, but purchase matching must be retried' }, 500); }
  return reply({ source_listing_id: id, title, archived: paths.length, already_captured: false });
});
