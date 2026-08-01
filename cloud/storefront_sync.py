"""Build the public FADEWELL storefront record from Vinted-owned facts only."""
from __future__ import annotations

import re
from datetime import datetime, timezone

import requests


REQUIRED_MEASUREMENTS = ("waist", "rise", "inseam", "leg_opening", "overall_length")
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
    "jeans", "jeansy", "denim trousers", "spodnie jeansowe",
    "trousers", "pants", "spodnie", "chinos", "cargo trousers", "cargo pants",
)
EXCLUDED_CATEGORY_WORDS = ("shorts", "szort", "skirt", "spodnic", "jumpsuit", "kombinezon")


def _ascii(value):
    table = str.maketrans("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", "acelnoszzACELNOSZZ")
    return str(value or "").translate(table).lower().strip()


def extract_measurements(description):
    """Extract centimeters while keeping the original display value."""
    measurements = {}
    for raw_line in str(description or "").splitlines():
        line = _ascii(raw_line)
        for key, aliases in MEASUREMENT_ALIASES.items():
            if key in measurements or not any(re.search(rf"\b{re.escape(alias)}\b", line) for alias in aliases):
                continue
            match = re.search(r"(?<!\d)(\d{1,3}(?:[.,]\d{1,2})?)\s*(?:cm\b)?", line)
            if match:
                value = float(match.group(1).replace(",", "."))
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
    response = session.get(
        "https://www.vinted.pl/api/v2/catalogs",
        headers={"Accept": "application/json, text/plain, */*", "X-Requested-With": "XMLHttpRequest"},
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
    if any(word in evidence for word in ("jeans", "jeansy", "spodnie jeansowe", "denim trousers")):
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


def _amount(value):
    if isinstance(value, dict):
        value = value.get("amount")
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None


def fetch_vinted_detail(session, item):
    """Enrich a catalog item from Vinted's public detail endpoint."""
    item_id = str(item["id"])
    response = session.get(
        f"https://www.vinted.pl/api/v2/items/{item_id}",
        headers={"Accept": "application/json, text/plain, */*", "X-Requested-With": "XMLHttpRequest"},
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    detail = payload.get("item") or payload
    if str(detail.get("id")) != item_id:
        raise RuntimeError(f"Vinted detail identity mismatch for {item_id}")
    merged = dict(item)
    merged.update(detail)
    return merged


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
