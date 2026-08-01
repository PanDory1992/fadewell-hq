"""Build the public FADEWELL storefront record from Vinted-owned facts only."""
from __future__ import annotations

import html
import json
import re
import time
from datetime import datetime, timezone

import requests


REQUIRED_MEASUREMENTS = ("waist", "rise", "inseam", "leg_opening", "overall_length")
MEASUREMENT_RANGES = {
    "waist": (20, 80), "rise": (15, 60), "inseam": (30, 130),
    "leg_opening": (8, 60), "overall_length": (50, 150),
    "thigh": (10, 65), "hips": (20, 90),
}
MEASUREMENT_ALIASES = {
    "waist": ("waist", "pas"),
    "rise": ("front rise", "rise", "stan"),
    "inseam": ("inseam", "inside leg", "wewnetrzna nogawka", "nogawka wewnetrzna"),
    "leg_opening": ("leg opening", "hem", "otwor nogawki", "nogawka na dole"),
    "overall_length": ("overall length", "outseam", "total length", "dlugosc calkowita"),
    "thigh": ("thigh", "udo"),
    "hips": ("hips", "hip", "biodra"),
}
ALLOWED_CATEGORY_WORDS = (
    "jeans", "jeansy", "dzinsy", "denim trousers", "spodnie jeansowe",
    "trousers", "pants", "spodnie", "chinos", "cargo trousers", "cargo pants",
)
EXCLUDED_CATEGORY_WORDS = ("shorts", "szort", "skirt", "spodnic", "jumpsuit", "kombinezon")
VINTED_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "pl-PL,pl;q=0.9,en;q=0.7",
    "X-Requested-With": "XMLHttpRequest",
}


def _ascii(value):
    table = str.maketrans("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", "acelnoszzACELNOSZZ")
    return str(value or "").translate(table).lower().strip()


def extract_measurements(description):
    """Extract the value beside each label, never an earlier model/year number."""
    measurements = {}
    text = _ascii(description)
    for key, aliases in MEASUREMENT_ALIASES.items():
        for alias in aliases:
            number = r"(\d{1,3}(?:[.,]\d{1,2})?)\s*cm\b"
            match = re.search(rf"\b{re.escape(alias)}\b\s*[:\-–—]\s*{number}", text)
            if not match:
                match = re.search(
                    rf"(?:^|[\n•*|])\s*{re.escape(alias)}\b[^\w\d\n]{{0,8}}{number}",
                    text,
                    re.MULTILINE,
                )
            if match:
                value = float(match.group(1).replace(",", "."))
                low, high = MEASUREMENT_RANGES[key]
                if low <= value <= high:
                    measurements[key] = {"cm": value, "display": f"{value:g} cm"}
                    break
    return measurements


def category_evidence(item):
    """Return category text supplied by Vinted, never inferred from the title."""
    values = []
    for key in ("catalog", "category"):
        value = item.get(key)
        if isinstance(value, dict):
            values.extend(str(value.get(field) or "") for field in ("title", "name", "slug"))
        elif value:
            values.append(str(value))
    for key in ("catalog_path", "breadcrumbs", "catalogs"):
        value = item.get(key) or []
        if isinstance(value, list):
            for part in value:
                if isinstance(part, dict):
                    values.extend(str(part.get(field) or "") for field in ("title", "name", "slug"))
                elif part:
                    values.append(str(part))
    if item.get("catalog_id"):
        values.append(f"catalog_id:{item['catalog_id']}")
    return " / ".join(dict.fromkeys(value.strip() for value in values if value.strip()))


def fetch_catalog_paths(session):
    """Map Vinted catalog IDs to their Vinted-provided breadcrumb labels."""
    response = get_with_retry(
        session,
        "https://www.vinted.pl/api/v2/catalogs",
        headers=VINTED_HEADERS,
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    roots = payload.get("catalogs") or payload.get("items") or []
    paths = {}

    def visit(node, parents):
        if not isinstance(node, dict):
            return
        label = node.get("title") or node.get("name") or node.get("slug")
        path = parents + ([str(label)] if label else [])
        if node.get("id") is not None:
            paths[str(node["id"])] = path
        for key in ("catalogs", "children", "subcatalogs"):
            for child in node.get(key) or []:
                visit(child, path)

    for root in roots:
        visit(root, [])
    return paths


def get_with_retry(session, url, *, attempts=4, **kwargs):
    """Retry transient Vinted responses and connection failures."""
    last_response = None
    for attempt in range(1, attempts + 1):
        try:
            response = session.get(url, **kwargs)
        except requests.RequestException:
            if attempt >= attempts:
                raise
            time.sleep(min(2 ** attempt, 15))
            continue
        last_response = response
        if response.status_code not in (429, 500, 502, 503, 504):
            response.raise_for_status()
            return response
        if attempt < attempts:
            retry_after = response.headers.get("Retry-After") if getattr(response, "headers", None) else None
            try:
                delay = min(float(retry_after), 60) if retry_after is not None else min(2 ** attempt, 15)
            except (TypeError, ValueError):
                delay = min(2 ** attempt, 15)
            time.sleep(delay)
    last_response.raise_for_status()
    return last_response


def fetch_user_catalog(session, user_id):
    """Fetch a complete seller wardrobe without accepting mixed-user rows."""
    page, total_pages, items = 1, 1, []
    while page <= total_pages:
        response = get_with_retry(
            session,
            "https://www.vinted.pl/api/v2/catalog/items",
            params={"user_ids[]": int(user_id), "page": page, "per_page": 96, "order": "newest_first"},
            headers=VINTED_HEADERS,
            timeout=30,
        )
        payload = response.json()
        batch = payload.get("items") or []
        if any(int((item.get("user") or {}).get("id") or 0) != int(user_id) for item in batch):
            raise RuntimeError("Refusing mixed-seller Vinted response")
        pagination = payload.get("pagination") or {}
        total_pages = int(pagination.get("total_pages") or page)
        if not batch and page < total_pages:
            raise RuntimeError(f"Partial storefront pagination at page {page}/{total_pages}")
        items.extend(batch)
        page += 1
    unique = {str(item["id"]): item for item in items}
    advertised = payload.get("pagination", {}).get("total_entries") if items else 0
    if advertised is not None and len(unique) < int(advertised):
        raise RuntimeError(f"Partial storefront catalog: expected {advertised}, received {len(unique)}")
    return list(unique.values())


def attach_catalog_path(item, paths):
    result = dict(item)
    path = paths.get(str(item.get("catalog_id")))
    if path:
        result["catalog_path"] = path
    return result


def garment_type_from_vinted_category(item):
    evidence = _ascii(category_evidence(item))
    if not evidence or any(word in evidence for word in EXCLUDED_CATEGORY_WORDS):
        return None
    if any(word in evidence for word in ("jeans", "jeansy", "dzinsy", "spodnie jeansowe", "denim trousers")):
        return "JEANS"
    if any(word in evidence for word in ALLOWED_CATEGORY_WORDS):
        return "TROUSERS"
    return None


def photo_urls(item):
    photos = item.get("photos") or []
    if not photos and item.get("photo"):
        photos = [item["photo"]]
    urls = []
    for photo in photos:
        if not isinstance(photo, dict):
            continue
        high = photo.get("high_resolution") or {}
        url = high.get("url") or photo.get("full_size_url") or photo.get("url")
        if url and url not in urls:
            urls.append(url)
    return urls


def _label(item, key, fallback=None):
    value = item.get(key)
    if isinstance(value, dict):
        value = value.get("title") or value.get("name") or value.get("label")
    return str(value or fallback or "").strip() or None


def build_storefront_record(item, captured_at=None, sold=False):
    description = str(item.get("description") or "").strip()
    measurements = extract_measurements(description)
    garment_type = garment_type_from_vinted_category(item)
    photos = photo_urls(item)
    now = captured_at or datetime.now(timezone.utc).isoformat()
    missing = [key for key in REQUIRED_MEASUREMENTS if key not in measurements]
    publishable = bool(garment_type and description and photos and not missing)
    return {
        "vinted_item_id": str(item["id"]),
        "title": _label(item, "title"),
        "brand": _label(item, "brand_title") or _label(item, "brand"),
        "size_label": _label(item, "size_title") or _label(item, "size"),
        "condition_label": _label(item, "status") or _label(item, "condition"),
        "garment_type": garment_type,
        "vinted_category": category_evidence(item) or None,
        "description_raw": description or None,
        "measurements": measurements,
        "photos": photos,
        "price_pln": _amount(item.get("price")),
        "vinted_url": item.get("url") or f"https://www.vinted.pl/items/{item['id']}",
        "available": not sold,
        "sold": bool(sold),
        "published": publishable,
        "last_seen_at": now,
        "updated_at": now,
        "publication_notes": {"missing_measurements": missing, "has_category": bool(garment_type)},
    }


def build_recovered_sold_record(detail, ledger_item, captured_at=None):
    """Build an archive-only record when a sale predates its storefront copy.

    The public sold page can retain the title, price and gallery while omitting
    description/category data. A confirmed recent HQ sale is the state
    authority; missing facts stay missing and are called out in provenance.
    """
    merged = dict(detail or {})
    merged.setdefault("id", ledger_item["vinted_item_id"])
    merged.setdefault("title", ledger_item.get("live_title"))
    merged.setdefault("url", ledger_item.get("listing_url"))
    merged.setdefault("price", {"amount": ledger_item.get("live_list_price")})
    if not photo_urls(merged) and ledger_item.get("last_photo_url"):
        merged["photos"] = [{"url": ledger_item["last_photo_url"]}]
    record = build_storefront_record(merged, captured_at=captured_at, sold=True)
    title_evidence = _ascii(record.get("title"))
    if not record["garment_type"]:
        if any(word in title_evidence for word in ("jeans", "jeansy", "dzinsy", "denim")):
            record["garment_type"] = "JEANS"
        elif any(word in title_evidence for word in ("trousers", "pants", "spodnie")):
            record["garment_type"] = "TROUSERS"
    record["available"] = False
    record["sold"] = True
    sold_on = str(ledger_item.get("sold_on") or "").strip()
    record["sold_at"] = f"{sold_on}T00:00:00+00:00" if re.fullmatch(r"\d{4}-\d{2}-\d{2}", sold_on) else None
    record["published"] = bool(record["title"] and record["photos"] and record["garment_type"])
    record["publication_notes"] = {
        **record["publication_notes"],
        "archive_recovery": True,
        "source": "confirmed_recent_hq_sale_and_public_vinted_page" if detail else "confirmed_recent_hq_sale",
        "description_recovered": bool(record["description_raw"]),
    }
    return record


def _amount(value):
    if isinstance(value, dict):
        value = value.get("amount")
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None


def fetch_vinted_detail(session, item):
    """Enrich one listing from its public item page.

    Vinted's former JSON item endpoint now returns 404. Calling it before every
    page doubled the request rate and caused avoidable 429 responses during a
    complete wardrobe sync.
    """
    item_id = str(item["id"])
    page = get_with_retry(
        session,
        f"https://www.vinted.pl/items/{item_id}",
        attempts=7,
        headers={**VINTED_HEADERS, "Accept": "text/html,application/xhtml+xml"},
        timeout=30,
    )
    detail = parse_vinted_item_page(page.text, item_id)
    detail.setdefault("url", getattr(page, "url", f"https://www.vinted.pl/items/{item_id}"))
    if str(detail.get("id")) != item_id:
        raise RuntimeError(f"Vinted detail identity mismatch for {item_id}")
    merged = dict(item)
    merged.update(detail)
    return merged


def parse_vinted_item_page(page_html, expected_id):
    """Read public Product JSON-LD and the pair's React flight record."""
    expected_id = str(expected_id)
    product = None
    for block in re.findall(
        r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
        str(page_html or ""),
        re.I | re.S,
    ):
        try:
            candidate = json.loads(html.unescape(block))
        except (TypeError, ValueError):
            continue
        if isinstance(candidate, dict) and candidate.get("@type") == "Product":
            product = candidate
            break

    flight_item = None
    decoder = json.JSONDecoder()
    for script_argument in re.findall(
        r"<script>\s*self\.__next_f\.push\((\[.*?\])\)\s*</script>",
        str(page_html or ""),
        re.I | re.S,
    ):
        try:
            frame = json.loads(script_argument)
        except (TypeError, ValueError):
            continue
        if len(frame) < 2 or not isinstance(frame[1], str):
            continue
        match = re.search(rf'\{{"id":{re.escape(expected_id)},"seller_id":', frame[1])
        if not match:
            continue
        try:
            candidate, _ = decoder.raw_decode(frame[1][match.start():])
        except (TypeError, ValueError):
            continue
        if str(candidate.get("id")) == expected_id:
            flight_item = candidate
            break

    detail = dict(flight_item or {})
    if product:
        detail.setdefault("id", int(expected_id))
        detail.setdefault("title", product.get("name"))
        detail.setdefault("description", product.get("description"))
        detail.setdefault("category", {"title": product.get("category")})
        detail.setdefault("url", (product.get("offers") or {}).get("url"))
        detail.setdefault("price", {"amount": (product.get("offers") or {}).get("price")})
        if not detail.get("photos") and product.get("image"):
            images = product["image"] if isinstance(product["image"], list) else [product["image"]]
            detail["photos"] = [{"url": url} for url in images]
    if not detail:
        raise RuntimeError(f"No public product data found on Vinted item page {expected_id}")
    return detail


def upsert_storefront_records(supabase_url, service_key, records):
    if not records:
        return
    response = requests.post(
        f"{supabase_url.rstrip('/')}/rest/v1/fadewell_storefront_products?on_conflict=vinted_item_id",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates,return=minimal",
        },
        json=records,
        timeout=60,
    )
    response.raise_for_status()


def fetch_recent_sold_ledger_items(supabase_url, service_key, sold_since):
    response = requests.get(
        f"{supabase_url.rstrip('/')}/rest/v1/hq_ledger_items",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
        params={
            "select": "item_id,vinted_item_id,listing_url,live_title,live_list_price,last_photo_url,sold_on",
            "ledger_status": "eq.SOLD",
            "sold_on": f"gte.{sold_since}",
            "vinted_item_id": "not.is.null",
        },
        timeout=60,
    )
    response.raise_for_status()
    return response.json()


def fetch_storefront_product_ids(supabase_url, service_key):
    response = requests.get(
        f"{supabase_url.rstrip('/')}/rest/v1/fadewell_storefront_products",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
        params={"select": "vinted_item_id"},
        timeout=60,
    )
    response.raise_for_status()
    return {str(row["vinted_item_id"]) for row in response.json()}


def recover_missing_recent_sales(session, supabase_url, service_key, sold_since):
    existing_ids = fetch_storefront_product_ids(supabase_url, service_key)
    sold_items = fetch_recent_sold_ledger_items(supabase_url, service_key, sold_since)
    records, failures = [], []
    for ledger_item in sold_items:
        item_id = str(ledger_item["vinted_item_id"])
        if item_id in existing_ids:
            continue
        try:
            detail = fetch_vinted_detail(session, {"id": item_id})
        except (requests.RequestException, RuntimeError, ValueError):
            detail = {}
        record = build_recovered_sold_record(detail, ledger_item)
        if record["published"]:
            records.append(record)
        else:
            failures.append({"id": item_id, "error": "insufficient public evidence for archive card"})
    upsert_storefront_records(supabase_url, service_key, records)
    return records, failures


def reconcile_storefront_sales(supabase_url, service_key):
    response = requests.post(
        f"{supabase_url.rstrip('/')}/rest/v1/rpc/sync_fadewell_storefront_sales",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        },
        json={},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()


def reconcile_storefront_dna(supabase_url, service_key):
    response = requests.post(
        f"{supabase_url.rstrip('/')}/rest/v1/rpc/sync_fadewell_storefront_dna",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        },
        json={},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()


def reconcile_storefront_availability(supabase_url, service_key, live_ids):
    response = requests.post(
        f"{supabase_url.rstrip('/')}/rest/v1/rpc/sync_fadewell_storefront_availability",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}", "Content-Type": "application/json"},
        json={"p_live_ids": [str(item_id) for item_id in live_ids]},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()
