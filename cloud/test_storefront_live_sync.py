import os
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("SUPABASE_URL", "https://db.example")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "secret")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import storefront_live_sync as live


class StorefrontLiveSyncTests(unittest.TestCase):
    def test_main_writes_owner_length_into_publishable_storefront_projection(self):
        detail = {'id': 10038070683, 'title': 'A pair', 'category': 'Jeans',
            'description': 'Waist 38 cm\nRise 31 cm\nInseam 79 cm\nLeg opening 18.5 cm',
            'photos': [{'url': 'cover.jpg'}]}
        external_results = {
            'fetch_items': [detail], 'fetch_catalog_paths': {},
            'fetch_owner_measurements': {'10038070683': {
                'overall_length': {'cm': 109, 'source': 'OWNER_CONFIRMED'}}},
            'fetch_storefront_records': [], 'fetch_detail_with_retries': detail,
            'is_den_scope_excluded': False, 'sync_hq_catalog_metadata': 0,
            'recover_missing_recent_sales': ([], []),
            'reconcile_storefront_dna': 0, 'reconcile_storefront_sales': 0,
        }
        with ExitStack() as stack:
            stack.enter_context(patch('storefront_live_sync.cloudscraper.create_scraper'))
            stack.enter_context(patch('storefront_live_sync.time.sleep'))
            for name, result in external_results.items():
                stack.enter_context(patch(f'storefront_live_sync.{name}', return_value=result))
            stack.enter_context(patch('storefront_live_sync.upsert_storefront_catalog_observations'))
            write = stack.enter_context(patch('storefront_live_sync.upsert_storefront_records'))
            stack.enter_context(patch('storefront_live_sync.record_storefront_sync_result'))
            live.main()
            record = write.call_args.args[2][0]
            self.assertTrue(record['published'])
            self.assertEqual(record['measurements']['overall_length']['cm'], 109)
            self.assertEqual(record['description_raw'], detail['description'])

    def test_changed_owner_measurement_refreshes_published_pair_outside_rotating_shard(self):
        existing = {'123': {'published': True,
            'publication_notes': {'publication_status': 'PUBLISHED'},
            'measurements': {'overall_length': {'cm': 107}}}}
        owner = {'123': {'overall_length': {'cm': 109, 'source': 'OWNER_CONFIRMED'}}}
        candidates = live.detail_candidates([{'id': 123}], existing,
            slot=0, shards=2, owner_measurements=owner)
        self.assertEqual([item['id'] for item in candidates], [123])

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
