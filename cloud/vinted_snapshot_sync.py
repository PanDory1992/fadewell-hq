"""Cloud-safe Vinted wardrobe snapshot -> Supabase. Read-only against Vinted."""
from __future__ import annotations

import json, os, time
from datetime import datetime, timezone
from pathlib import Path

import cloudscraper
import requests

ROOT = Path(__file__).resolve().parents[1]
SCOPE = json.loads((ROOT / "operational_scope.json").read_text(encoding="utf-8"))
USER_ID = int(os.environ.get("VINTED_USER_ID", "271911480"))
SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*", "Accept-Language": "pl-PL,pl;q=0.9,en;q=0.7",
    "X-Requested-With": "XMLHttpRequest",
}

def amount(value):
    value = value.get("amount") if isinstance(value, dict) else value
    try: return float(str(value).replace(",", "."))
    except (TypeError, ValueError): return None

def fetch_items():
    session = cloudscraper.create_scraper(); session.get("https://www.vinted.pl", headers=HEADERS, timeout=30)
    endpoint = "https://www.vinted.pl/api/v2/catalog/items"; page = 1; anchor = time.time(); total_pages = 1; items = []
    while page <= total_pages:
        response = session.get(endpoint, params={"user_ids[]": USER_ID, "page": page, "per_page": 96, "time": anchor, "order": "newest_first"}, headers=HEADERS, timeout=30)
        response.raise_for_status(); payload = response.json(); batch = payload.get("items") or []
        if any((item.get("user") or {}).get("id") != USER_ID for item in batch): raise RuntimeError("Refusing mixed-seller Vinted response")
        items.extend(batch); pagination = payload.get("pagination") or {}; total_pages = int(pagination.get("total_pages") or page); anchor = pagination.get("time") or anchor; page += 1
    return {int(item["id"]): item for item in items}.values()

def main():
    excluded = set(SCOPE["excluded_live_vinted_ids"]); captured_at = datetime.now(timezone.utc).isoformat(); rows = []
    for item in fetch_items():
        item_id = str(item["id"])
        if item_id in excluded: continue
        photo = item.get("photo") or {}; high = photo.get("high_resolution") or {}
        rows.append({"vinted_item_id": item_id, "captured_at": captured_at, "title": item.get("title"), "price_pln": amount(item.get("price")), "views": item.get("view_count") or 0, "favourites": item.get("favourite_count") or 0, "visible": bool(item.get("is_visible", True)), "photo_url": high.get("url") or photo.get("url"), "source": "github_actions_vinted"})
    response = requests.post(f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots?on_conflict=vinted_item_id,captured_at", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"}, json=rows, timeout=60)
    response.raise_for_status(); print(f"Uploaded {len(rows)} DEN-scope Vinted snapshots at {captured_at}")

if __name__ == "__main__": main()
