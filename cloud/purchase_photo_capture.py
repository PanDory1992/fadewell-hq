"""Capture bought Vinted listing photos for Gmail-created HQ purchase jobs.

The Gmail receipt creates the DEN and the job. This worker uses the buyer's
Vinted session only to resolve that receipt's transaction ID to listing IDs.
Every downloaded photo is retained even when a same-title bundle needs review.
"""

import html
import json
import os
import re
import sys
import unicodedata
from datetime import date, datetime
from urllib.parse import urlparse

import cloudscraper
import requests


HQ_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
HQ_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
COOKIE = os.environ.get("VINTED_BUYER_COOKIE", "")
BUCKET = "hq-purchase-photos"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
ORDER_API = "https://api.vinted.pl/escrow-orders/api/v2/current-user/escrow-orders"
SCRIPT_RE = re.compile(r'self\.__next_f\.push\(\[1,("(?:\\.|[^"\\])*")\]\)', re.S)
PRELOAD_RE = re.compile(r'<link\s+[^>]*rel="preload"[^>]*as="image"[^>]*href="([^"]+)"', re.I)


def normalized(value):
    text = unicodedata.normalize("NFKD", str(value or "").lower())
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def preloaded_orders(page):
    """Read only the server-provided order records, never arbitrary script code."""
    orders = []
    for match in SCRIPT_RE.finditer(page):
        chunk = json.loads(match.group(1))
        marker = '"preloadedOrders":'
        at = chunk.find(marker)
        if at < 0:
            continue
        payload, _ = json.JSONDecoder().raw_decode(chunk[at + len(marker):])
        orders.extend(payload.get("orders", []))
    return orders


def first_product_photos(page):
    urls = []
    for match in PRELOAD_RE.finditer(page):
        image = html.unescape(match.group(1))
        parsed = urlparse(image)
        if parsed.scheme != "https" or not re.fullmatch(r"images\d*\.vinted\.net", parsed.hostname or ""):
            if urls:
                break
            continue
        if image not in urls:
            urls.append(image)
        if len(urls) == 3:
            break
    return urls


def listing_title(page):
    match = re.search(r'<title[^>]*>(.*?)</title>', page, re.I | re.S)
    return html.unescape(re.sub(r"\s*\|\s*Vinted\s*$", "", match.group(1))).strip() if match else ""


class Hq:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({"apikey": HQ_KEY, "Authorization": f"Bearer {HQ_KEY}"})

    def table(self, table, *, params=None, method="GET", payload=None, prefer=None):
        headers = {"Content-Type": "application/json"}
        if prefer:
            headers["Prefer"] = prefer
        response = self.session.request(method, f"{HQ_URL}/rest/v1/{table}", params=params, json=payload, headers=headers, timeout=30)
        response.raise_for_status()
        return response.json() if response.content else None

    def upload(self, path, body, mime):
        response = self.session.post(f"{HQ_URL}/storage/v1/object/{BUCKET}/{path}", data=body,
                                     headers={"Content-Type": mime, "x-upsert": "false"}, timeout=30)
        if response.status_code != 409:
            response.raise_for_status()


class Vinted:
    def __init__(self):
        self.session = cloudscraper.create_scraper()
        self.session.headers.update({"User-Agent": USER_AGENT, "Accept-Language": "pl-PL,pl;q=0.9,en;q=0.7"})
        for part in COOKIE.split(";"):
            name, sep, value = part.strip().partition("=")
            if sep and name:
                self.session.cookies.set(name, value, domain=".vinted.pl")
        if not self.session.cookies.get("access_token_web"):
            raise RuntimeError("Vinted buyer session is missing or incomplete")
        home = self.session.get("https://www.vinted.pl", timeout=30)
        home.raise_for_status()
        if 'falka.falka35' not in home.text:
            raise RuntimeError("Vinted buyer session is no longer signed in")
        csrf = re.search(r'<meta\s+name="csrf-token"\s+content="([^"]+)"', home.text)
        self.api_headers = {"Accept": "application/json, text/plain, */*", "Platform": "web", "Locale": "en-PL", "Referer": "https://www.vinted.pl/", "x-next-app": "marketplace-web"}
        anon = self.session.cookies.get("anon_id")
        if anon:
            self.api_headers["X-Anon-Id"] = anon
        if csrf:
            self.api_headers["X-CSRF-Token"] = html.unescape(csrf.group(1))

    def orders(self):
        found = []
        for page in range(1, 6):
            response = self.session.get(ORDER_API, params={"page": page, "per_page": 20, "type": "purchased"},
                                        headers=self.api_headers, timeout=30)
            if response.status_code in (401, 403) and page == 1:
                fallback = self.session.get("https://www.vinted.pl/my_orders?order_type=purchased", timeout=30)
                fallback.raise_for_status()
                recent = preloaded_orders(fallback.text)
                if not recent:
                    raise RuntimeError("Vinted buyer session cannot access order history")
                return recent
            response.raise_for_status()
            payload = response.json()
            batch = payload.get("my_orders", [])
            found.extend(batch)
            if len(batch) < 20:
                break
        return found

    def transaction(self, conversation_id):
        response = self.session.get(f"https://www.vinted.pl/api/v2/conversations/{conversation_id}",
                                    headers={"Accept": "application/json", "Referer": "https://www.vinted.pl/my_orders"}, timeout=30)
        response.raise_for_status()
        payload = response.json()
        return (payload.get("conversation") or payload).get("transaction") or {}

    def listing(self, listing_id):
        response = self.session.get(f"https://www.vinted.pl/items/{listing_id}",
                                    headers={"Accept": "text/html,application/xhtml+xml"}, timeout=30)
        if response.status_code == 404:
            return "", []
        response.raise_for_status()
        page = response.text
        return listing_title(page), first_product_photos(page)

    def photo(self, url):
        parsed = urlparse(url)
        if parsed.scheme != "https" or not re.fullmatch(r"images\d*\.vinted\.net", parsed.hostname or ""):
            raise ValueError("Untrusted photo host")
        response = self.session.get(url, timeout=30)
        response.raise_for_status()
        mime = response.headers.get("Content-Type", "").split(";")[0].lower()
        if mime not in {"image/webp", "image/jpeg", "image/png"} or not 0 < len(response.content) <= 5_242_880:
            raise ValueError("Invalid source image")
        if mime == "image/webp" and not (response.content[:4] == b"RIFF" and response.content[8:12] == b"WEBP"):
            raise ValueError("Invalid WebP image")
        if mime == "image/jpeg" and response.content[:2] != b"\xff\xd8":
            raise ValueError("Invalid JPEG image")
        if mime == "image/png" and response.content[:4] != b"\x89PNG":
            raise ValueError("Invalid PNG image")
        return response.content, mime


def matching_order(job, orders):
    matches = [row for row in orders if str(row.get("transaction_id") or row.get("transactionId")) == str(job["vinted_transaction_id"])]
    if len(matches) != 1:
        raise RuntimeError("Receipt transaction is not uniquely present in buyer order history")
    order = matches[0]
    amount = (order.get("price") or {}).get("amount")
    if amount is None or abs(float(amount) - float(job["paid_amount"])) > 0.02:
        raise RuntimeError("Receipt amount differs from buyer order")
    bought = datetime.fromisoformat(order["date"].replace("Z", "+00:00")).date()
    if abs((bought - date.fromisoformat(job["occurred_on"])).days) > 1:
        raise RuntimeError("Receipt date differs from buyer order")
    if not job["bundle_titles"] and normalized(order.get("title")) != normalized(job["receipt_title"]):
        raise RuntimeError("Receipt title differs from buyer order")
    return order


def unique_bundle_mapping(titles, den_ids, listing_titles):
    """Never use transaction.item_ids order as the DEN order."""
    result = {}
    source = [normalized(title) for title in titles]
    for listing_id, title in listing_titles.items():
        key = normalized(title)
        if key and source.count(key) == 1 and list(map(normalized, listing_titles.values())).count(key) == 1:
            result[listing_id] = den_ids[source.index(key)]
    return result


def update_job(hq, job, state, error=None):
    hq.table("hq_purchase_photo_ingest_jobs", params={"source_event_id": f"eq.{job['source_event_id']}"}, method="PATCH",
             payload={"state": state, "attempts": job["attempts"] + 1, "last_attempt_at": datetime.utcnow().isoformat() + "Z",
                      "last_error": error, "updated_at": datetime.utcnow().isoformat() + "Z"})


def process(hq, vinted, orders, job):
    order = matching_order(job, orders)
    transaction = vinted.transaction(order.get("conversation_id") or order.get("conversationId"))
    if str(transaction.get("id")) != str(job["vinted_transaction_id"]):
        raise RuntimeError("Conversation belongs to a different purchase transaction")
    ids = [str(value) for value in transaction.get("item_ids") or []]
    if not ids or any(not re.fullmatch(r"\d+", value) for value in ids) or len(ids) != len(job["den_item_ids"]):
        raise RuntimeError("Buyer transaction item count differs from Gmail purchase")
    listing_data = {}
    for listing_id in ids:
        title, photos = vinted.listing(listing_id)
        if not photos and len(ids) == 1:
            fallback = (transaction.get("item_photo") or {}).get("full_size_url")
            if fallback:
                photos = [fallback]
        listing_data[listing_id] = (title, photos)
    if len(ids) == 1:
        mapping = {ids[0]: job["den_item_ids"][0]}
    else:
        mapping = unique_bundle_mapping(job["bundle_titles"], job["den_item_ids"],
                                        {item_id: item[0] for item_id, item in listing_data.items()})
    linked = 0
    for listing_id, (title, photos) in listing_data.items():
        if not photos:
            continue
        paths = []
        for number, image_url in enumerate(photos[:3], 1):
            body, mime = vinted.photo(image_url)
            extension = {"image/webp": "webp", "image/jpeg": "jpg", "image/png": "png"}[mime]
            path = f"capture/{job['source_event_id']}/{listing_id}/{number}.{extension}"
            hq.upload(path, body, mime)
            paths.append(path)
        den_id = mapping.get(listing_id)
        hq.table("hq_purchase_photo_captures?on_conflict=source_event_id,source_listing_id", method="POST",
                 prefer="resolution=ignore-duplicates", payload={"source_event_id": job["source_event_id"],
                 "source_listing_id": listing_id, "source_listing_url": f"https://www.vinted.pl/items/{listing_id}",
                 "listing_title": title or None, "photo_paths": paths, "item_id": den_id})
        if den_id:
            existing = hq.table("hq_purchase_source_photos", params={"select": "source_listing_id", "item_id": f"eq.{den_id}"})
            if existing and str(existing[0]["source_listing_id"]) != listing_id:
                raise RuntimeError("DEN already has source photos from another listing")
            if not existing:
                hq.table("hq_purchase_source_photos?on_conflict=item_id", method="POST", prefer="resolution=ignore-duplicates",
                         payload={"item_id": den_id, "source_listing_id": listing_id,
                         "source_listing_url": f"https://www.vinted.pl/items/{listing_id}",
                         "photo_paths": paths, "capture_source": "GMAIL_VINTED_PURCHASE"})
            linked += 1
    if linked == len(ids):
        update_job(hq, job, "CAPTURED")
    else:
        update_job(hq, job, "NEEDS_REVIEW", f"Captured {sum(bool(x[1]) for x in listing_data.values())}/{len(ids)} listings; linked {linked}/{len(ids)} to DEN")
    return linked, len(ids)


def main():
    if not HQ_URL or not HQ_KEY:
        raise RuntimeError("HQ service credentials are not configured")
    hq = Hq()
    probe_transaction_id = os.environ.get("VINTED_PROBE_TRANSACTION_ID", "").strip()
    if probe_transaction_id:
        if not re.fullmatch(r"\d+", probe_transaction_id):
            raise ValueError("Probe transaction ID must be numeric")
        if not COOKIE:
            raise RuntimeError("Vinted buyer session is not configured")
        vinted = Vinted()
        matches = [row for row in vinted.orders() if str(row.get("transaction_id") or row.get("transactionId")) == probe_transaction_id]
        if len(matches) != 1:
            raise RuntimeError("Probe transaction is not uniquely present in buyer order history")
        transaction = vinted.transaction(matches[0].get("conversation_id") or matches[0].get("conversationId"))
        if str(transaction.get("id")) != probe_transaction_id:
            raise RuntimeError("Probe conversation belongs to another transaction")
        ids = [str(value) for value in transaction.get("item_ids") or []]
        if not ids:
            raise RuntimeError("Probe transaction has no listing IDs")
        counts = []
        for listing_id in ids:
            _, urls = vinted.listing(listing_id)
            counts.append(len(urls))
        print(f"Vinted buyer access confirmed: {len(ids)} listing(s), photo counts {counts}")
        return
    jobs = hq.table("hq_purchase_photo_ingest_jobs", params={"select": "*", "state": "eq.PENDING", "order": "created_at.asc", "limit": "30"})
    if not jobs:
        print("No pending purchase-photo jobs")
        return
    if not COOKIE:
        raise RuntimeError("Vinted buyer session is not configured")
    vinted = Vinted()
    orders = vinted.orders()
    failed = 0
    for job in jobs:
        try:
            linked, total = process(hq, vinted, orders, job)
            print(f"{job['source_event_id']}: captured and linked {linked}/{total}")
        except Exception as error:
            failed += 1
            message = str(error)[:300]
            state = "NEEDS_REVIEW" if job["attempts"] >= 2 else "PENDING"
            update_job(hq, job, state, message)
            print(f"{job['source_event_id']}: {state}: {message}", file=sys.stderr)
    if failed:
        raise RuntimeError(f"{failed} purchase-photo jobs could not be completed")


if __name__ == "__main__":
    main()
