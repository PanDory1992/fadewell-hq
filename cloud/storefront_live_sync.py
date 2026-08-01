"""Independent hourly sync for the public FADEWELL storefront."""
import os
import time

import cloudscraper
import requests

from storefront_sync import (
    attach_catalog_path, build_storefront_record, category_evidence, fetch_catalog_paths,
    fetch_vinted_detail, reconcile_storefront_availability,
    reconcile_storefront_sales, upsert_storefront_records,
)
from vinted_snapshot_sync import HEADERS, fetch_items

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
USER_ID = int(os.environ.get("VINTED_USER_ID", "271911480"))
DETAIL_DELAY = float(os.environ.get("VINTED_DETAIL_DELAY_SECONDS", "0.35"))


def main():
    session = cloudscraper.create_scraper()
    session.get("https://www.vinted.pl", headers=HEADERS, timeout=30)
    catalog_items = list(fetch_items(session=session))
    try:
        catalog_paths = fetch_catalog_paths(session)
    except requests.HTTPError as error:
        if error.response is None or error.response.status_code != 404:
            raise
        catalog_paths = {}
        print("Vinted catalog tree endpoint is unavailable; using category evidence from item details")
    records, failures = [], []
    for item in catalog_items:
        try:
            detail = attach_catalog_path(fetch_vinted_detail(session, item), catalog_paths)
            record = build_storefront_record(detail)
            records.append(record)
            if not record["garment_type"]:
                print(
                    f"Unresolved Vinted category for {item['id']}: "
                    f"catalog_id={detail.get('catalog_id')!r}; evidence={category_evidence(detail)!r}"
                )
        except (requests.RequestException, RuntimeError, ValueError) as error:
            failures.append({"id": str(item["id"]), "error": str(error)})
        time.sleep(DETAIL_DELAY)
    upsert_storefront_records(SUPABASE_URL, SERVICE_KEY, records)
    reconcile_storefront_availability(SUPABASE_URL, SERVICE_KEY, [item["id"] for item in catalog_items])
    sold_changed = reconcile_storefront_sales(SUPABASE_URL, SERVICE_KEY)
    published = sum(1 for record in records if record["published"])
    print(f"Storefront sync: {len(records)} enriched, {published} publishable, {len(failures)} failed, {sold_changed} sales reconciled")
    for failure in failures[:10]:
        print(f"Detail unavailable {failure['id']}: {failure['error']}")
    if failures:
        raise RuntimeError(f"Storefront detail sync incomplete for {len(failures)} current listing(s)")


if __name__ == "__main__":
    main()
