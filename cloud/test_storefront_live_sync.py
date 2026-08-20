import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("SUPABASE_URL", "https://db.example")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "secret")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import storefront_live_sync as live


class StorefrontLiveSyncTests(unittest.TestCase):
    def test_catalog_observation_contains_only_safe_live_facts(self):
        result = live.catalog_observation({
            "id": 123,
            "title": "A pair",
            "brand_title": "Lee",
            "size_title": "W30",
            "status": "Very good",
            "photos": [{"high_resolution": {"url": "one.jpg"}}],
            "price": {"amount": "129.00"},
            "url": "https://www.vinted.pl/items/123",
        }, "2026-08-20T00:00:00+00:00")
        self.assertTrue(result["available"])
        self.assertEqual(result["photos"], ["one.jpg"])
        self.assertNotIn("description_raw", result)
        self.assertNotIn("published", result)

    @patch("storefront_live_sync.is_den_scope_excluded", return_value=False)
    def test_detail_candidates_prioritize_new_then_rotate_cache(self, _excluded):
        catalog = [
            {"id": 101, "title": "New", "price": {"amount": "10"}, "photos": []},
            {"id": 102, "title": "Changed", "price": {"amount": "20"}, "photos": []},
            {"id": 103, "title": "Cached", "price": {"amount": "30"}, "photos": []},
        ]
        existing = {
            "102": {"title": "Old", "price_pln": 20, "photos": [], "publication_notes": {"publication_status": "PUBLISHED"}},
            "103": {"title": "Cached", "price_pln": 30, "photos": [], "publication_notes": {"publication_status": "PUBLISHED"}},
        }
        ids = [str(item["id"]) for item in live.detail_candidates(catalog, existing, slot=1, shards=2)]
        self.assertEqual(ids, ["101", "103"])
        self.assertIn("103", ids)

    @patch("storefront_live_sync.is_den_scope_excluded", return_value=True)
    def test_excluded_listing_is_never_detail_fetched(self, _excluded):
        self.assertEqual(live.detail_candidates([{"id": 123}], {}, slot=0, shards=1), [])


if __name__ == "__main__":
    unittest.main()
