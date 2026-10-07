const safe = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));

export async function loadPurchasePhotos(sb) {
  const {data, error} = await sb.from('hq_purchase_source_photos').select('item_id,source_listing_id,source_listing_url,photo_paths,captured_at');
  if (error) throw error;
  const records = data || [];
  const paths = records.flatMap(row => row.photo_paths || []);
  const signed = new Map();
  for (let offset = 0; offset < paths.length; offset += 80) {
    const chunk = paths.slice(offset, offset + 80);
    const result = await sb.storage.from('hq-purchase-photos').createSignedUrls(chunk, 12 * 60 * 60);
    if (result.error) throw result.error;
    (result.data || []).forEach((photo, index) => { if (photo?.signedUrl) signed.set(chunk[index], photo.signedUrl); });
  }
  return new Map(records.map(row => [row.item_id, {...row, urls: (row.photo_paths || []).map(path => signed.get(path)).filter(Boolean)}]));
}

export function purchaseGallery(record) {
  if (!record?.urls?.length) return '';
  return `<div class="purchase-source"><p class="muted small">Oryginalne zdjęcia kupionego ogłoszenia · zapisane w HQ</p><div class="purchase-source-grid">${record.urls.map((url, index) => `<a href="${safe(url)}" target="_blank" rel="noreferrer"><img src="${safe(url)}" alt="Zdjęcie ${index + 1} z ogłoszenia zakupu" loading="lazy"></a>`).join('')}</div><a class="text-link small" href="${safe(record.source_listing_url)}" target="_blank" rel="noreferrer">Oryginalne ogłoszenie Vinted</a></div>`;
}

export function purchaseSourceForm(record) {
  const replacing = Boolean(record?.urls?.length);
  const fields = `<label for="purchaseSourceUrl">Link do ogłoszenia zakupu z Vinted</label><div class="row-actions"><input id="purchaseSourceUrl" type="url" value="${safe(record?.source_listing_url || '')}" placeholder="https://www.vinted.pl/items/…" autocomplete="off"><button id="archivePurchasePhotos" type="button">${replacing ? 'Zapisz poprawione zdjęcia' : 'Zapisz zdjęcia zakupu'}</button></div><label for="purchaseSourceFiles">Wybierz pierwsze dostępne zdjęcia z ogłoszenia w kolejności (maks. 3)</label><input id="purchaseSourceFiles" type="file" accept="image/webp,image/jpeg,image/png" multiple><p id="archivePurchaseStatus" class="muted small">HQ zachowa poprzednią wersję przy korekcie.</p>`;
  return replacing ? `<details class="purchase-source"><summary>Popraw zdjęcia zakupu</summary>${fields}</details>` : `<div class="purchase-source">${fields}</div>`;
}

export function bindPurchaseSourceForm(sb, itemId, record, onSaved) {
  const button = document.getElementById('archivePurchasePhotos');
  if (!button) return;
  button.onclick = async () => {
    const input = document.getElementById('purchaseSourceUrl');
    const status = document.getElementById('archivePurchaseStatus');
    const listingUrl = input.value.trim();
    if (!/^https:\/\/(?:www\.)?vinted\.pl\/items\/\d+/i.test(listingUrl)) { status.textContent = 'Wklej link do konkretnego ogłoszenia Vinted.'; return; }
    button.disabled = true; status.textContent = 'Pobieram i zapisuję zdjęcia…';
    try {
      const files = [...document.getElementById('purchaseSourceFiles').files];
      if (files.length > 3) throw new Error('Wybierz maksymalnie trzy zdjęcia.');
      const images = await Promise.all(files.map(file => new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = () => reject(new Error('Nie udało się odczytać zdjęcia.')); reader.readAsDataURL(file); })));
      const {data, error} = await sb.functions.invoke('hq-purchase-photo-archive', {body: {item_id: itemId, listing_url: listingUrl, images, replace: Boolean(record?.urls?.length)}});
      const response = error?.context && typeof error.context.json === 'function' ? await error.context.json().catch(() => null) : null;
      if (error || data?.error) throw new Error(response?.error || data?.error || error?.message || 'Nie udało się zapisać zdjęć.');
      status.textContent = `Zapisano ${data.archived} zdjęcia.`;
      await onSaved();
    } catch (error) { status.textContent = error.message || String(error); button.disabled = false; }
  };
}
