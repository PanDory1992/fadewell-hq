"""One-time/repeatable backfill of Pair Archive and current storefront facts."""
import os

import cloudscraper
import requests

from storefront_sync import (
    attach_catalog_path, build_storefront_record, fetch_catalog_paths,
    fetch_vinted_detail, reconcile_storefront_sales, upsert_storefront_records,
)

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
HEADERS = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}


def ledger_listings():
    response = requests.get(
        f"{SUPABASE_URL}/rest/v1/hq_ledger_items",
        headers=HEADERS,
        params={"select": "vinted_item_id,ledger_status", "vinted_item_id": "not.is.null", "limit": "1000"},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()


def main():
    session = cloudscraper.create_scraper()
    session.get("https://www.vinted.pl", timeout=30)
    paths = fetch_catalog_paths(session)
    records = []
    failures = []
    for listing in ledger_listings():
        item_id = str(listing["vinted_item_id"])
        try:
            detail = fetch_vinted_detail(session, {"id": item_id})
            detail = attach_catalog_path(detail, paths)
            records.append(build_storefront_record(detail, sold=listing["ledger_status"] == "SOLD"))
        except (requests.RequestException, RuntimeError, ValueError) as error:
            failures.append({"vinted_item_id": item_id, "error": str(error)})
        if len(records) >= 25:
            upsert_storefront_records(SUPABASE_URL, SERVICE_KEY, records)
            records.clear()
    upsert_storefront_records(SUPABASE_URL, SERVICE_KEY, records)
    changed = reconcile_storefront_sales(SUPABASE_URL, SERVICE_KEY)
    print(f"Storefront backfill complete; {len(failures)} Vinted detail failure(s); {changed} sale state(s) reconciled")
    for failure in failures[:20]:
        print(f"Unavailable {failure['vinted_item_id']}: {failure['error']}")
    if failures:
        raise RuntimeError(f"Storefront backfill incomplete for {len(failures)} listing(s)")


if __name__ == "__main__":
    main()
