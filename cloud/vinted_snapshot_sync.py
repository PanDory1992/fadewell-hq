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
COLLECTOR_MODE = os.environ.get("COLLECTOR_MODE", "manual").lower()
COLLECTOR_SOURCE = os.environ.get("COLLECTOR_SOURCE", "GITHUB_MANUAL")
DB_HEADERS = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*", "Accept-Language": "pl-PL,pl;q=0.9,en;q=0.7",
    "X-Requested-With": "XMLHttpRequest",
}

def amount(value):
    value = value.get("amount") if isinstance(value, dict) else value
    try: return float(str(value).replace(",", "."))
    except (TypeError, ValueError): return None

def condition_label(item):
    """Preserve Vinted's displayed condition verbatim when catalog supplies it."""
    value = item.get("status") or item.get("condition")
    if isinstance(value, dict):
        value = value.get("title") or value.get("name") or value.get("label")
    value = str(value or "").strip()
    return value or None

def _fetch_catalog_pass(session):
    endpoint = "https://www.vinted.pl/api/v2/catalog/items"; page = 1; anchor = time.time(); total_pages = 1; total_entries = None; items = []
    while page <= total_pages:
        response = session.get(endpoint, params={"user_ids[]": USER_ID, "page": page, "per_page": 96, "time": anchor, "order": "newest_first"}, headers=HEADERS, timeout=30)
        response.raise_for_status(); payload = response.json(); batch = payload.get("items") or []
        if any((item.get("user") or {}).get("id") != USER_ID for item in batch): raise RuntimeError("Refusing mixed-seller Vinted response")
        pagination = payload.get("pagination") or {}
        advertised_pages = int(pagination.get("total_pages") or page)
        advertised_entries = pagination.get("total_entries")
        if advertised_pages < page:
            raise RuntimeError(f"Invalid Vinted pagination: page {page} exceeds advertised total {advertised_pages}")
        if advertised_entries is not None:
            advertised_entries = int(advertised_entries)
            if total_entries is not None and total_entries != advertised_entries:
                raise RuntimeError(f"Vinted total changed mid-pull: {total_entries} -> {advertised_entries}")
            total_entries = advertised_entries
        if not batch and page < advertised_pages:
            raise RuntimeError(f"Partial Vinted pagination: page {page}/{advertised_pages} was empty")
        items.extend(batch); total_pages = advertised_pages; anchor = pagination.get("time") or anchor; page += 1
    unique = {int(item["id"]): item for item in items}
    return unique, total_entries

def fetch_items(session=None, max_passes=4):
    """Merge repeated catalog passes before deciding the pull is incomplete.

    Vinted can repeat one or more boundary listings on page 2 while still
    advertising the correct total. Starting the entire workflow again loses
    the useful IDs from the previous pass, so accumulate them inside one pull.
    The scoped recent-snapshot guard in ``main`` remains the final integrity
    check before anything is written to Supabase.
    """
    session = session or cloudscraper.create_scraper()
    session.get("https://www.vinted.pl", headers=HEADERS, timeout=30)
    combined = {}; advertised_total = None; pass_sizes = []
    for attempt in range(1, max_passes + 1):
        unique, total_entries = _fetch_catalog_pass(session)
        combined.update(unique); pass_sizes.append(len(unique))
        if total_entries is not None:
            advertised_total = max(advertised_total or 0, total_entries)
        if advertised_total is None or len(combined) >= advertised_total:
            if attempt > 1:
                print(f"Recovered complete Vinted catalog across {attempt} passes: {len(combined)} unique items")
            return combined.values()
        if attempt < max_passes:
            time.sleep(min(attempt * 2, 5))
    shortfall = advertised_total - len(combined)
    if shortfall <= 1:
        print(f"Vinted advertised {advertised_total}, returned {len(combined)} unique across {max_passes} passes ({pass_sizes}); continuing to scoped snapshot guard")
        return combined.values()
    raise RuntimeError(f"Partial Vinted pagination after {max_passes} passes: expected {advertised_total} unique items, got {len(combined)} ({pass_sizes})")

def recent_reference_scope_count():
    response = requests.get(
        f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots",
        headers=DB_HEADERS,
        params={"select": "captured_at", "source": "in.(github_actions_vinted,supabase_edge_vinted)", "order": "captured_at.desc", "limit": "1000"},
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

def begin_collector_run():
    response = requests.post(
        f"{SUPABASE_URL}/rest/v1/rpc/begin_hq_collector_run",
        headers={**DB_HEADERS, "Content-Type": "application/json"},
        json={
            "p_source": COLLECTOR_SOURCE,
            "p_stale_after_minutes": 35 if COLLECTOR_MODE == "watchdog" else 0,
            "p_force": COLLECTOR_MODE == "manual",
        }, timeout=60,
    )
    response.raise_for_status()
    return response.json()

def finish_collector_run(run_id, success, captured_at=None, item_count=None, error=None, detail=None):
    response = requests.post(
        f"{SUPABASE_URL}/rest/v1/rpc/finish_hq_collector_run",
        headers={**DB_HEADERS, "Content-Type": "application/json"},
        json={"p_run_id": run_id, "p_success": success, "p_captured_at": captured_at,
              "p_item_count": item_count, "p_error": error, "p_detail": detail or {}}, timeout=60,
    )
    response.raise_for_status()
    return response.json()

def eligible_unlisted_items():
    response = requests.get(f"{SUPABASE_URL}/rest/v1/hq_ledger_items", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, params={"select":"item_id,name,category,advantage,estimate_sale_price", "ledger_status":"eq.UNLISTED-BACKLOG", "vinted_item_id":"is.null", "limit":"1000"}, timeout=60)
    response.raise_for_status()
    return response.json()

def eligible_relist_items(active_vinted_ids):
    response = requests.get(f"{SUPABASE_URL}/rest/v1/hq_ledger_items", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, params={"select":"item_id,name,category,advantage,estimate_sale_price,vinted_item_id", "ledger_status":"eq.LISTED-BACKLOG", "vinted_item_id":"not.is.null", "limit":"1000"}, timeout=60)
    response.raise_for_status()
    return [item for item in response.json() if str(item["vinted_item_id"]) not in active_vinted_ids]

def fetch_new_listing_description(vinted_id):
    """Read public item-page metadata only for a just-discovered listing."""
    # The catalog snapshot is still useful when an individual item page is
    # blocked or temporarily unavailable. A missing description must therefore
    # lower matching evidence, never discard the whole observation cycle.
    try:
        session = cloudscraper.create_scraper()
        response = session.get(f"https://www.vinted.pl/items/{vinted_id}", headers={**HEADERS, "Accept":"text/html,application/xhtml+xml"}, timeout=30)
        response.raise_for_status()
        match = re.search(r'<meta name="description" content="([^"]*)"', response.text, re.I)
        return html.unescape(match.group(1)) if match else ""
    except requests.RequestException as error:
        print(f"Description unavailable for {vinted_id}; leaving it for manual review: {error}")
        return ""

def auto_link(match, listing):
    item = match["item"]; vinted_id = str(listing["id"]); external_key = f"auto-resolver-link-{vinted_id}"
    relist = bool(item.get("vinted_item_id") and str(item["vinted_item_id"]) != vinted_id)
    payload = {"action_type":"LISTED", "item_id":item["item_id"], "occurred_on":datetime.now(timezone.utc).date().isoformat(), "amount":amount(listing.get("price")), "vinted_item_id":vinted_id, "listing_url":f"https://www.vinted.pl/items/{vinted_id}", "live_title":listing.get("title"), "note":f"SYSTEM {'relist' if relist else 'auto-resolver'}: score {match['score']}; {'; '.join(match['reasons'])}", "source":"SYSTEM", "external_key":external_key, "relist":relist}
    response = requests.post(f"{SUPABASE_URL}/rest/v1/rpc/apply_hq_ledger_action", headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}", "Content-Type":"application/json"}, json={"p": payload}, timeout=60)
    response.raise_for_status()
    print(f"Auto-linked {vinted_id} -> {item['item_id']} ({match['score']}: {', '.join(match['reasons'])})")

def main():
    lease = begin_collector_run()
    if not lease.get("accepted"):
        print(f"Collector skipped safely: {lease.get('reason')} ({lease})")
        return
    run_id = lease["run_id"]
    try:
        excluded = set(SCOPE["excluded_live_vinted_ids"]); captured_at = datetime.now(timezone.utc).isoformat(); rows = []; live_items = []
        for item in fetch_items():
            item_id = str(item["id"])
            if item_id in excluded: continue
            live_items.append(item)
            photo = item.get("photo") or {}; high = photo.get("high_resolution") or {}
            rows.append({"vinted_item_id": item_id, "captured_at": captured_at, "title": item.get("title"), "price_pln": amount(item.get("price")), "views": item.get("view_count") or 0, "favourites": item.get("favourite_count") or 0, "visible": bool(item.get("is_visible", True)), "photo_url": high.get("url") or photo.get("url"), "condition_label": condition_label(item), "source": "github_actions_vinted"})
        reference_count = recent_reference_scope_count()
        if reference_count is not None and len(rows) < reference_count - 1:
            raise RuntimeError(f"Refusing partial Vinted snapshot: {len(rows)} DEN items against recent reference {reference_count}; expected at most one removal between runs")
        seen_before = prior_snapshot_ids([str(item["id"]) for item in live_items])
        response = requests.post(f"{SUPABASE_URL}/rest/v1/hq_listing_snapshots?on_conflict=vinted_item_id,captured_at", headers={**DB_HEADERS, "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"}, json=rows, timeout=60)
        response.raise_for_status(); print(f"Uploaded {len(rows)} DEN-scope Vinted snapshots at {captured_at}")
        active_vinted_ids = {str(listing["id"]) for listing in live_items}
        candidates = eligible_unlisted_items() + eligible_relist_items(active_vinted_ids)
        new_listings = [listing for listing in live_items if str(listing["id"]) not in seen_before]
        description_limit = 5
        for listing in new_listings[:description_limit]:
            listing["description"] = fetch_new_listing_description(listing["id"])
        if len(new_listings) > description_limit:
            print(f"{len(new_listings) - description_limit} new listings were not page-read this cycle; title-only matching remains manual-review only.")
        for listing in new_listings:
            match = best_match(listing, candidates)
            if match and match["auto"]:
                auto_link(match, listing)
                candidates = [item for item in candidates if item["item_id"] != match["item"]["item_id"]]
            elif match:
                print(f"Suggestion only {listing['id']} -> {match['item']['item_id']} ({match['confidence']} {match['score']})")
        finish_collector_run(run_id, True, captured_at, len(rows), detail={"new_listings": len(new_listings)})
    except Exception as error:
        try: finish_collector_run(run_id, False, error=str(error))
        except Exception as finish_error: print(f"Could not record collector failure: {finish_error}")
        raise

if __name__ == "__main__": main()
