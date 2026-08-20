import sys
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import storefront_sync as sf


class FakeResponse:
    def __init__(self, status_code=200, payload=None, headers=None, text="", url="https://example.test"):
        self.status_code = status_code
        self._payload = payload if payload is not None else {}
        self.headers = headers or {}
        self.text = text
        self.url = url

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"HTTP {self.status_code}", response=self)


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


class StorefrontSyncTests(unittest.TestCase):
    def test_measurements_are_parsed_and_order_independent(self):
        result = sf.extract_measurements("""Overall length: 108 cm
Waist: 42 cm
Front rise 31cm
Inseam — 80,5 cm
Leg opening: 21 cm
Thigh 30 cm
Hips: 52 cm""")
        self.assertEqual(result["waist"]["cm"], 42)
        self.assertEqual(result["inseam"]["cm"], 80.5)
        self.assertEqual(set(sf.REQUIRED_MEASUREMENTS) - set(result), set())

    def test_measurements_ignore_model_year_and_other_numbers_on_one_line(self):
        result = sf.extract_measurements(
            "Levi's 550 vintage 1995. Waist: 44 cm • Front rise: 30 cm • "
            "Inseam: 86 cm • Leg opening: 17.5 cm • Overall length: 115 cm"
        )
        self.assertEqual(result["waist"]["cm"], 44)
        self.assertEqual(result["rise"]["cm"], 30)
        self.assertEqual(result["leg_opening"]["cm"], 17.5)

    def test_measurement_ranges_and_plain_labels_are_preserved(self):
        result = sf.extract_measurements("Waist: 39\u201341 cm\nRise          29 cm\nLength: 106 cm")
        self.assertEqual(result["waist"]["cm"], 40)
        self.assertEqual(result["waist"]["min_cm"], 39)
        self.assertEqual(result["waist"]["max_cm"], 41)
        self.assertEqual(result["waist"]["display"], "39\u201341 cm")
        self.assertEqual(result["rise"]["cm"], 29)
        self.assertEqual(result["overall_length"]["cm"], 106)

    def test_photo_only_measurements_are_a_visible_review_reason(self):
        record = sf.build_storefront_record({
            "id": 8130234003,
            "catalog": {"title": "Jeans"},
            "description": "Measurements in photo gallery.",
            "photos": [{"url": "https://img.example/big-star.jpg"}],
        })
        self.assertFalse(record["published"])
        self.assertEqual(record["publication_notes"]["publication_status"], "NEEDS_MEASUREMENT_REVIEW")
        self.assertEqual(set(record["publication_notes"]["measurement_issues"].values()), {"PHOTO_ONLY"})

    def test_non_den_scope_is_excluded_without_becoming_measurement_work(self):
        record = sf.build_storefront_record({
            "id": 8130234003,
            "catalog": {"title": "Jeans"},
            "description": "Waist 42 cm\nRise 30 cm\nInseam 80 cm\nLeg opening 20 cm\nOverall length 106 cm",
            "photos": [{"url": "https://img.example/big-star.jpg"}],
        }, scope_excluded=True)
        self.assertFalse(record["published"])
        self.assertEqual(record["publication_notes"]["publication_status"], "OUT_OF_SCOPE_DEN")
        self.assertEqual(record["publication_notes"]["blocking_reasons"], ["NOT_IN_DEN_SCOPE"])
        self.assertEqual(record["publication_notes"]["missing_measurements"], [])
        self.assertNotIn("measurement_issues", record["publication_notes"])

    def test_operational_scope_contains_confirmed_non_den_listings(self):
        self.assertTrue(sf.is_den_scope_excluded("7990892108"))
        self.assertTrue(sf.is_den_scope_excluded("8130234003"))

    def test_non_denim_category_is_excluded_without_becoming_measurement_work(self):
        record = sf.build_storefront_record({
            "id": 900,
            "catalog": {"title": "Men's shirts"},
            "description": "Waist: 40 cm",
            "photos": [{"url": "https://img.example/shirt.jpg"}],
        })
        self.assertFalse(record["published"])
        self.assertEqual(record["publication_notes"]["publication_status"], "OUT_OF_SCOPE_CATEGORY")
        self.assertNotIn("measurement_issues", record["publication_notes"])

    def test_implausible_model_number_is_not_a_measurement(self):
        result = sf.extract_measurements("High-rise Levi's 501 jeans. Rise: 28 cm")
        self.assertEqual(result["rise"]["cm"], 28)
        self.assertNotIn(501, [value["cm"] for value in result.values()])

    def test_waist_does_not_capture_rise_from_fit_prose(self):
        result = sf.extract_measurements("""Fit:
W29 L30 — Sits higher on the waist (29 cm rise) with a tapered leg.

Measurements (measured flat):
• Waist: 39 cm
• Inseam: 78 cm
• Total length: 106 cm
• Leg opening: 17.5 cm
• Front rise: 29 cm""")
        self.assertEqual(result["waist"]["cm"], 39)
        self.assertEqual(result["rise"]["cm"], 29)

    @patch("storefront_sync.requests.post")
    def test_dna_reconciliation_uses_service_only_rpc(self, post):
        post.return_value = FakeResponse(payload=3)
        self.assertEqual(sf.reconcile_storefront_dna("https://db.example/", "secret"), 3)
        self.assertEqual(post.call_args.args[0], "https://db.example/rest/v1/rpc/sync_fadewell_storefront_dna")
        self.assertEqual(post.call_args.kwargs["json"], {})

    @patch("storefront_sync.requests.post")
    def test_catalog_metadata_refreshes_hq_without_identity_or_status_fields(self, post):
        post.return_value = FakeResponse(payload=2)
        changed = sf.sync_hq_catalog_metadata("https://db.example/", "secret", [{
            "vinted_item_id": "123", "title": "A pair", "price_pln": 129,
            "photos": ["one.jpg"], "available": True,
        }])
        self.assertEqual(changed, 2)
        row = post.call_args.kwargs["json"]["p"][0]
        self.assertEqual(row["photo_url"], "one.jpg")
        self.assertNotIn("available", row)
        self.assertNotIn("ledger_status", row)

    @patch("storefront_sync.requests.post")
    def test_storefront_success_marker_is_service_only(self, post):
        post.return_value = FakeResponse()
        sf.record_storefront_sync_result(
            "https://db.example/", "secret", True, catalog_count=122, detail_deferred=2,
        )
        self.assertTrue(post.call_args.kwargs["json"]["p_success"])
        self.assertEqual(post.call_args.kwargs["json"]["p_catalog_count"], 122)
        self.assertEqual(post.call_args.kwargs["json"]["p_detail_deferred"], 2)

    def test_category_comes_from_vinted_not_title(self):
        shorts = {"id": 1, "title": "Perfect vintage jeans", "catalog": {"title": "Denim shorts"}}
        trousers = {"id": 2, "title": "Unhelpful title", "catalog": {"title": "Trousers"}}
        self.assertIsNone(sf.garment_type_from_vinted_category(shorts))
        self.assertEqual(sf.garment_type_from_vinted_category(trousers), "TROUSERS")

    def test_catalog_path_resolves_category_id(self):
        item = sf.attach_catalog_path({"id": 3, "catalog_id": 42}, {"42": ["Men", "Clothing", "Trousers", "Jeans"]})
        self.assertEqual(sf.garment_type_from_vinted_category(item), "JEANS")

    def test_polish_vinted_jeans_category_is_allowed(self):
        item = {"id": 3, "category": {"title": "Mężczyźni Dżinsy straight fit"}}
        self.assertEqual(sf.garment_type_from_vinted_category(item), "JEANS")

    def test_complete_pair_is_publishable(self):
        item = {
            "id": 123,
            "title": "Levi's 501",
            "catalog": {"title": "Jeans"},
            "description": "Waist 42 cm\nRise 31 cm\nInseam 80 cm\nLeg opening 21 cm\nOverall length 108 cm",
            "photos": [{"high_resolution": {"url": "https://img.example/pair.jpg"}}],
            "price": {"amount": "149.00"},
        }
        record = sf.build_storefront_record(item)
        self.assertTrue(record["published"])
        self.assertEqual(record["garment_type"], "JEANS")
        self.assertEqual(record["photos"], ["https://img.example/pair.jpg"])

    def test_missing_required_measurement_stays_unpublished(self):
        item = {"id": 123, "catalog": {"title": "Jeans"}, "description": "Waist 42 cm", "photo": {"url": "x"}}
        record = sf.build_storefront_record(item)
        self.assertFalse(record["published"])
        self.assertIn("inseam", record["publication_notes"]["missing_measurements"])

    def test_confirmed_recent_sale_can_recover_archive_card_from_sold_page(self):
        detail = {
            "id": 9320464487,
            "title": "Levi's 615 Orangetab Vintage Jeans - W33 L32",
            "photos": [{"url": "one.jpg"}, {"url": "two.jpg"}],
            "price": {"amount": "189.00"},
        }
        ledger = {
            "vinted_item_id": "9320464487",
            "listing_url": "https://www.vinted.pl/items/9320464487",
            "live_title": detail["title"],
            "live_list_price": "189.00",
            "sold_on": "2026-08-01",
        }
        record = sf.build_recovered_sold_record(detail, ledger, captured_at="2026-08-02T00:00:00+00:00")
        self.assertTrue(record["published"])
        self.assertTrue(record["sold"])
        self.assertFalse(record["available"])
        self.assertEqual(record["garment_type"], "JEANS")
        self.assertEqual(record["sold_at"], "2026-08-01T00:00:00+00:00")
        self.assertTrue(record["publication_notes"]["archive_recovery"])
        self.assertFalse(record["publication_notes"]["description_recovered"])

    @patch("storefront_sync.requests.get")
    def test_recent_sale_query_has_explicit_archive_cutoff(self, get):
        get.return_value = FakeResponse(payload=[])
        self.assertEqual(sf.fetch_recent_sold_ledger_items("https://db.example/", "secret", "2026-08-01"), [])
        self.assertEqual(get.call_args.kwargs["params"]["sold_on"], "gte.2026-08-01")
        self.assertEqual(get.call_args.kwargs["params"]["ledger_status"], "eq.SOLD")

    def test_archive_rejects_any_pre_august_backfill(self):
        with self.assertRaisesRegex(ValueError, "cannot predate 2026-08-01"):
            sf.fetch_recent_sold_ledger_items("https://db.example/", "secret", "2026-07-31")

    @patch("storefront_sync.time.sleep")
    def test_transient_vinted_response_is_retried(self, sleep):
        session = FakeSession([FakeResponse(429, headers={"Retry-After": "1"}), FakeResponse(200, {"ok": True})])
        response = sf.get_with_retry(session, "https://example.test")
        self.assertEqual(response.json(), {"ok": True})
        self.assertEqual(len(session.calls), 2)
        sleep.assert_called_once_with(1.0)

    @patch("storefront_sync.time.sleep")
    def test_vinted_read_timeout_is_retried(self, sleep):
        session = FakeSession([requests.ReadTimeout("temporary"), FakeResponse(200, {"ok": True})])
        response = sf.get_with_retry(session, "https://example.test")
        self.assertEqual(response.json(), {"ok": True})
        self.assertEqual(len(session.calls), 2)
        sleep.assert_called_once_with(2)

    def test_catalog_refuses_mixed_seller_rows(self):
        session = FakeSession([FakeResponse(200, {
            "items": [{"id": 1, "user": {"id": 999}}],
            "pagination": {"total_pages": 1, "total_entries": 1},
        })])
        with self.assertRaisesRegex(RuntimeError, "mixed-seller"):
            sf.fetch_user_catalog(session, 123)

    def test_vinted_requests_use_browser_identity_headers(self):
        self.assertIn("Mozilla/5.0", sf.VINTED_HEADERS["User-Agent"])
        self.assertEqual(sf.VINTED_HEADERS["Accept-Language"], "pl-PL,pl;q=0.9,en;q=0.7")

    def test_item_page_parser_combines_json_ld_with_full_gallery(self):
        product = {
            "@type": "Product", "name": "A pair", "description": "Waist 40 cm",
            "category": "Mężczyźni Dżinsy straight fit", "image": "main.jpg",
            "offers": {"url": "https://www.vinted.pl/items/123-a-pair", "price": 129},
        }
        flight = json.dumps([1, 'fd:[{"value":{"id":123,"seller_id":7,"photos":[{"url":"one.jpg"},{"full_size_url":"two.jpg"}]}}]'])
        page = f'<script>self.__next_f.push({flight})</script><script type="application/ld+json">{json.dumps(product)}</script>'
        detail = sf.parse_vinted_item_page(page, 123)
        self.assertEqual(detail["description"], "Waist 40 cm")
        self.assertEqual(detail["category"]["title"], "Mężczyźni Dżinsy straight fit")
        self.assertEqual(sf.photo_urls(detail), ["one.jpg", "two.jpg"])

    def test_item_detail_uses_one_public_page_request(self):
        product = {
            "@type": "Product", "name": "A pair", "description": "Waist 40 cm",
            "category": "Men Jeans", "image": "main.jpg",
            "offers": {"url": "https://www.vinted.pl/items/123-a-pair", "price": 129},
        }
        page = f'<script type="application/ld+json">{json.dumps(product)}</script>'
        session = FakeSession([FakeResponse(text=page, url="https://www.vinted.pl/items/123-a-pair")])
        detail = sf.fetch_vinted_detail(session, {"id": 123})
        self.assertEqual(detail["title"], "A pair")
        self.assertEqual(len(session.calls), 1)
        self.assertEqual(session.calls[0][0], "https://www.vinted.pl/items/123")

    def test_http_error_retains_response_for_404_fallback(self):
        response = FakeResponse(404)
        with self.assertRaises(requests.HTTPError) as raised:
            sf.get_with_retry(FakeSession([response]), "https://example.test/catalogs")
        self.assertIs(raised.exception.response, response)


if __name__ == "__main__":
    unittest.main()
