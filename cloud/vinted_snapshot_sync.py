"""Cloud-safe Vinted wardrobe snapshot -> Supabase. Read-only against Vinted."""
from __future__ import annotations

import html, json, os, re, time
from datetime import datetime, timezone
from pathlib import Path

import cloudscraper
import requests
from listing_resolver import best_match

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

def recent_reference_scope_count():
    response = requests.get(
        f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots",
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"},
        params={"select": "captured_at", "source": "eq.github_actions_vinted", "order": "captured_at.desc", "limit": "1000"},
        timeout=60,
    )
    response.raise_for_status()
    rows = response.json()
    if not rows:
        return None
    counts = {}
    ordered_cycles = []
    for row in rows:
        captured_at = row.get("captured_at")
        if captured_at not in counts:
            if len(ordered_cycles) == 2:
                break
            counts[captured_at] = 0
            ordered_cycles.append(captured_at)
        counts[captured_at] += 1
    return max(counts[captured_at] for captured_at in ordered_cycles[:2])

def prior_snapshot_ids(vinted_ids):
    if not vinted_ids: return set()
    response = requests.get(f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, params={"select":"vinted_item_id", "vinted_item_id":f"in.({','.join(vinted_ids)})", "order":"captured_at.desc", "limit":"250"}, timeout=60)
    response.raise_for_status()
    return {str(row["vinted_item_id"]) for row in response.json()}

def eligible_unlisted_items():
    response = requests.get(f"{SUPABASE_URL}/rest/v1/hq_ledger_items", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, params={"select":"item_id,name,category,advantage,estimate_sale_price", "ledger_status":"eq.UNLISTED-BACKLOG", "vinted_item_id":"is.null", "limit":"1000"}, timeout=60)
    response.raise_for_status()
    return response.json()

def fetch_new_listing_description(vinted_id):
    """Read public item-page metadata only for a just-discovered listing."""
    session = cloudscraper.create_scraper()
    response = session.get(f"https://www.vinted.pl/items/{vinted_id}", headers={**HEADERS, "Accept":"text/html,application/xhtml+xml"}, timeout=30)
    response.raise_for_status()
    match = re.search(r'<meta name="description" content="([^"]*)"', response.text, re.I)
    return html.unescape(match.group(1)) if match else ""

def auto_link(match, listing):
    item = match["item"]; vinted_id = str(listing["id"]); external_key = f"auto-resolver-link-{vinted_id}"
    payload = {"action_type":"LISTED", "item_id":item["item_id"], "occurred_on":datetime.now(timezone.utc).date().isoformat(), "amount":amount(listing.get("price")), "vinted_item_id":vinted_id, "listing_url":f"https://www.vinted.pl/items/{vinted_id}", "live_title":listing.get("title"), "note":f"SYSTEM auto-resolver: score {match['score']}; {'; '.join(match['reasons'])}", "external_key":external_key}
    response = requests.post(f"{SUPABASE_URL}/rest/v1/rpc/apply_hq_ledger_action", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type":"application/json"}, json=payload, timeout=60)
    response.raise_for_status()
    requests.patch(f"{SUPABASE_URL}/rest/v1/hq_ledger_events", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type":"application/json"}, params={"external_key":f"eq.{external_key}"}, json={"source":"SYSTEM"}, timeout=60).raise_for_status()
    print(f"Auto-linked {vinted_id} -> {item['item_id']} ({match['score']}: {', '.join(match['reasons'])})")

def main():
    excluded = set(SCOPE["excluded_live_vinted_ids"]); captured_at = datetime.now(timezone.utc).isoformat(); rows = []; live_items = []
    for item in fetch_items():
        item_id = str(item["id"])
        if item_id in excluded: continue
        live_items.append(item)
        photo = item.get("photo") or {}; high = photo.get("high_resolution") or {}
        rows.append({"vinted_item_id": item_id, "captured_at": captured_at, "title": item.get("title"), "price_pln": amount(item.get("price")), "views": item.get("view_count") or 0, "favourites": item.get("favourite_count") or 0, "visible": bool(item.get("is_visible", True)), "photo_url": high.get("url") or photo.get("url"), "source": "github_actions_vinted"})
    reference_count = recent_reference_scope_count()
    if reference_count is not None and len(rows) < reference_count - 1:
        raise RuntimeError(f"Refusing partial Vinted snapshot: {len(rows)} DEN items against recent reference {reference_count}; expected at most one removal between runs")
    seen_before = prior_snapshot_ids([str(item["id"]) for item in live_items])
    response = requests.post(f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots?on_conflict=vinted_item_id,captured_at", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"}, json=rows, timeout=60)
    response.raise_for_status(); print(f"Uploaded {len(rows)} DEN-scope Vinted snapshots at {captured_at}")
    candidates = eligible_unlisted_items()
    new_listings = [listing for listing in live_items if str(listing["id"]) not in seen_before]
    for listing in new_listings[:5]:
        listing["description"] = fetch_new_listing_description(listing["id"])
    for listing in new_listings:
        match = best_match(listing, candidates)
        if match and match["auto"]:
            auto_link(match, listing)
            candidates = [item for item in candidates if item["item_id"] != match["item"]["item_id"]]
        elif match:
            print(f"Suggestion only {listing['id']} -> {match['item']['item_id']} ({match['confidence']} {match['score']})")

if __name__ == "__main__": main()
