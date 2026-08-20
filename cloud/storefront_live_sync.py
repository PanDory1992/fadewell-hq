"""Fast, cache-preserving sync for HQ and the public FADEWELL storefront."""
import os
import time
from datetime import datetime, timezone

import cloudscraper
import requests

from storefront_sync import (
    attach_catalog_path, build_storefront_record, category_evidence, fetch_catalog_paths,
    fetch_storefront_records, fetch_vinted_detail,
    record_storefront_sync_result,
    reconcile_storefront_dna, reconcile_storefront_sales, recover_missing_recent_sales,
    is_den_scope_excluded, sync_hq_catalog_metadata,
    upsert_storefront_catalog_observations, upsert_storefront_records,
)
from vinted_snapshot_sync import HEADERS, fetch_items

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
USER_ID = int(os.environ.get("VINTED_USER_ID", "271911480"))
DETAIL_DELAY = float(os.environ.get("VINTED_DETAIL_DELAY_SECONDS", "0.5"))
DETAIL_FETCH_ATTEMPTS = max(1, int(os.environ.get("STOREFRONT_DETAIL_FETCH_ATTEMPTS", "2")))
DETAIL_RETRY_DELAY = float(os.environ.get("STOREFRONT_DETAIL_RETRY_DELAY_SECONDS", "5.0"))
DETAIL_REFRESH_SHARDS = max(1, int(os.environ.get("STOREFRONT_DETAIL_REFRESH_SHARDS", "12")))
ARCHIVE_SOLD_SINCE = os.environ.get("STOREFRONT_ARCHIVE_SOLD_SINCE", "2026-08-01")


def fetch_detail_with_retries(session, item):
    for attempt in range(1, DETAIL_FETCH_ATTEMPTS + 1):
        try:
            return fetch_vinted_detail(session, item)
        except (requests.RequestException, RuntimeError) as error:
            if attempt == DETAIL_FETCH_ATTEMPTS:
                raise
            delay = DETAIL_RETRY_DELAY * attempt
            print(
                f"::warning title=Vinted detail retry::"
                f"Listing {item['id']} was unavailable on attempt {attempt}/"
                f"{DETAIL_FETCH_ATTEMPTS}; retrying in {delay:.0f}s: {error}"
            )
            time.sleep(delay)


def _amount(value):
    value = value.get("amount") if isinstance(value, dict) else value
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None


def _photo_urls(item):
    photos = item.get("photos") or ([item["photo"]] if item.get("photo") else [])
    result = []
    for photo in photos:
        if not isinstance(photo, dict):
            continue
        high = photo.get("high_resolution") or {}
        url = high.get("url") or photo.get("full_size_url") or photo.get("url")
        if url and url not in result:
            result.append(url)
    return result


def catalog_observation(item, captured_at):
    """Return only facts available in the cheap seller-catalog response."""
    return {
        "vinted_item_id": str(item["id"]),
        "title": item.get("title") or None,
        "brand": item.get("brand_title") or None,
        "size_label": item.get("size_title") or None,
        "condition_label": (
            (item.get("status") or {}).get("title")
            if isinstance(item.get("status"), dict)
            else item.get("status") or None
        ),
        "photos": _photo_urls(item),
        "price_pln": _amount(item.get("price")),
        "vinted_url": item.get("url") or f"https://www.vinted.pl/items/{item['id']}",
        "available": True,
        "last_seen_at": captured_at,
        "updated_at": captured_at,
    }


def detail_candidates(catalog_items, existing, *, slot=None, shards=DETAIL_REFRESH_SHARDS):
    """Prioritize new/unfinished rows, then refresh a small rotating shard."""
    slot = int(time.time() // (15 * 60)) % shards if slot is None else int(slot) % shards
    priority, rotation = [], []
    for item in catalog_items:
        item_id = str(item["id"])
        if is_den_scope_excluded(item_id):
            continue
        previous = existing.get(item_id)
        publication_status = (previous or {}).get("publication_notes") or {}
        publication_status = publication_status.get("publication_status")
        unfinished = previous and not previous.get("published") and publication_status not in {
            "PUBLISHED", "OUT_OF_SCOPE_CATEGORY", "OUT_OF_SCOPE_DEN", "NO_CATEGORY_EVIDENCE",
        }
        if not previous or unfinished:
            priority.append(item)
        elif int(item_id) % shards == slot:
            rotation.append(item)
    seen = set()
    return [item for item in priority + rotation if not (str(item["id"]) in seen or seen.add(str(item["id"])))]


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
    captured_at = datetime.now(timezone.utc).isoformat()
    existing = {
        str(row["vinted_item_id"]): row
        for row in fetch_storefront_records(SUPABASE_URL, SERVICE_KEY)
    }
    observations = []
    for item in catalog_items:
        observation = catalog_observation(item, captured_at)
        previous = existing.get(observation["vinted_item_id"]) or {}
        for key in ("title", "brand", "size_label", "condition_label", "photos", "price_pln", "vinted_url"):
            if observation.get(key) in (None, "", []):
                observation[key] = previous.get(key)
        observations.append(observation)
    upsert_storefront_catalog_observations(SUPABASE_URL, SERVICE_KEY, observations)
    hq_changed = sync_hq_catalog_metadata(SUPABASE_URL, SERVICE_KEY, observations)
    records, failures, deferred = [], [], 0
    detail_blocked = False
    candidates = detail_candidates(catalog_items, existing)
    for item in candidates:
        if detail_blocked:
            deferred += 1
            continue
        try:
            detail = attach_catalog_path(fetch_detail_with_retries(session, item), catalog_paths)
            scope_excluded = is_den_scope_excluded(item["id"])
            record = build_storefront_record(detail, scope_excluded=scope_excluded)
            records.append(record)
            if scope_excluded and record["garment_type"]:
                print(f"Excluded from DEN storefront scope: {item['id']} — {record['title']}")
            elif not record["garment_type"]:
                print(
                    f"Unresolved Vinted category for {item['id']}: "
                    f"catalog_id={detail.get('catalog_id')!r}; evidence={category_evidence(detail)!r}"
                )
        except (requests.RequestException, RuntimeError, ValueError) as error:
            failures.append({"id": str(item["id"]), "error": str(error)})
            response = getattr(error, "response", None)
            if response is not None and response.status_code in (403, 429):
                detail_blocked = True
                print(
                    "::warning title=Vinted detail enrichment deferred::"
                    "Vinted is rate-limiting detail pages. Cached descriptions and galleries remain live; "
                    "the next scheduled refresh will resume enrichment."
                )
        time.sleep(DETAIL_DELAY)
    upsert_storefront_records(SUPABASE_URL, SERVICE_KEY, records)
    recovered, recovery_failures = recover_missing_recent_sales(
        session, SUPABASE_URL, SERVICE_KEY, ARCHIVE_SOLD_SINCE,
    )
    dna_changed = reconcile_storefront_dna(SUPABASE_URL, SERVICE_KEY)
    sold_changed = reconcile_storefront_sales(SUPABASE_URL, SERVICE_KEY)
    published = sum(1 for record in records if record["published"])
    action_required = sum(
        1 for record in records
        if record["available"]
        and not record["published"]
        and record["publication_notes"].get("publication_status") not in {
            "OUT_OF_SCOPE_CATEGORY", "NO_CATEGORY_EVIDENCE", "OUT_OF_SCOPE_DEN",
        }
    )
    out_of_scope = sum(
        1 for record in records
        if record["available"] and record["publication_notes"].get("publication_status") in {
            "OUT_OF_SCOPE_CATEGORY", "OUT_OF_SCOPE_DEN",
        }
    )
    all_failures = failures + recovery_failures
    print(f"Storefront sync: {len(catalog_items)} live observations, {hq_changed} HQ rows refreshed, {len(records)} details enriched, {published} publishable, {action_required} action-required, {out_of_scope} out-of-scope, {len(recovered)} sold rows recovered, {len(all_failures)} details deferred, {deferred} skipped behind circuit breaker, {dna_changed} DNA rows updated, {sold_changed} sales reconciled")
    for failure in all_failures[:10]:
        print(f"Detail unavailable {failure['id']}: {failure['error']}")
    if all_failures:
        print(
            "::warning title=Storefront detail cache used::"
            f"{len(all_failures)} detail page(s) were unavailable. Live catalog facts were saved and "
            "the last complete descriptions, measurements and galleries were preserved."
        )
    record_storefront_sync_result(
        SUPABASE_URL, SERVICE_KEY, True,
        catalog_count=len(catalog_items), detail_deferred=len(all_failures) + deferred,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        try:
            record_storefront_sync_result(SUPABASE_URL, SERVICE_KEY, False, error=error)
        except Exception as health_error:
            print(f"Could not record Storefront sync failure: {health_error}")
        raise
