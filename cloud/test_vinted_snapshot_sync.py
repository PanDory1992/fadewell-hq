"""Safety tests for Vinted snapshot pagination."""
import os
import sys
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-key")
sys.modules.setdefault("cloudscraper", SimpleNamespace(create_scraper=lambda: None))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vinted_snapshot_sync as sync


class Response:
    def __init__(self, payload):
        self.payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload


class Session:
    def __init__(self, pages):
        self.pages = iter(pages)

    def get(self, *_args, **_kwargs):
        try:
            return Response(next(self.pages))
        except StopIteration as error:
            raise AssertionError("Unexpected extra Vinted request") from error


class RequestsResponse(Response):
    pass


def item(item_id):
    return {"id": item_id, "user": {"id": sync.USER_ID}}


class SnapshotPaginationTests(unittest.TestCase):
    def test_watchdog_uses_35_minute_freshness_gate(self):
        response = RequestsResponse({"accepted": False, "reason": "fresh"})
        with patch.object(sync, "COLLECTOR_MODE", "watchdog"), patch.object(sync, "COLLECTOR_SOURCE", "GITHUB_FALLBACK"), patch.object(sync.requests, "post", return_value=response) as post:
            result = sync.begin_collector_run()
        self.assertFalse(result["accepted"])
        self.assertEqual(post.call_args.kwargs["json"]["p_stale_after_minutes"], 35)
        self.assertFalse(post.call_args.kwargs["json"]["p_force"])

    def test_manual_run_forces_freshness_but_still_uses_database_lease(self):
        response = RequestsResponse({"accepted": True, "run_id": "test"})
        with patch.object(sync, "COLLECTOR_MODE", "manual"), patch.object(sync.requests, "post", return_value=response) as post:
            sync.begin_collector_run()
        self.assertEqual(post.call_args.kwargs["json"]["p_stale_after_minutes"], 0)
        self.assertTrue(post.call_args.kwargs["json"]["p_force"])

    def test_condition_label_preserves_catalog_label(self):
        self.assertEqual(sync.condition_label({"status": "Very good"}), "Very good")
        self.assertEqual(sync.condition_label({"status": {"title": "New with tags"}}), "New with tags")
        self.assertIsNone(sync.condition_label({}))

    def test_fetches_every_advertised_page(self):
        session = Session([
            {},
            {"items": [item(1)], "pagination": {"total_pages": 2, "total_entries": 2, "time": "anchor"}},
            {"items": [item(2)], "pagination": {"total_pages": 2, "total_entries": 2, "time": "anchor"}},
        ])
        self.assertEqual([row["id"] for row in sync.fetch_items(session)], [1, 2])

    def test_rejects_incomplete_advertised_total(self):
        session = Session([
            {},
            {"items": [item(1)], "pagination": {"total_pages": 1, "total_entries": 3}},
        ])
        with self.assertRaisesRegex(RuntimeError, "expected 3 unique items, got 1"):
            list(sync.fetch_items(session, max_passes=1))

    def test_defers_one_item_catalog_gap_to_scoped_guard(self):
        session = Session([
            {},
            {"items": [item(1)], "pagination": {"total_pages": 1, "total_entries": 2}},
        ])
        self.assertEqual([row["id"] for row in sync.fetch_items(session, max_passes=1)], [1])

    def test_recovers_duplicates_across_catalog_passes(self):
        session = Session([
            {},
            {"items": [item(1), item(2)], "pagination": {"total_pages": 2, "total_entries": 3, "time": "a"}},
            {"items": [item(2)], "pagination": {"total_pages": 2, "total_entries": 3, "time": "a"}},
            {"items": [item(1), item(2)], "pagination": {"total_pages": 2, "total_entries": 3, "time": "b"}},
            {"items": [item(3)], "pagination": {"total_pages": 2, "total_entries": 3, "time": "b"}},
        ])
        with patch.object(sync.time, "sleep"):
            self.assertEqual({row["id"] for row in sync.fetch_items(session, max_passes=2)}, {1, 2, 3})

    def test_relist_payload_uses_the_jsonb_rpc_argument(self):
        match = {"item": {"item_id": "DEN-064", "vinted_item_id": "8717257628"}, "score": 107, "reasons": ["exact relist evidence"]}
        listing = {"id": "9405604352", "title": "Lee 101 Rider W30 L32", "price": {"amount": "239.00"}}
        response = SimpleNamespace(raise_for_status=lambda: None)
        with patch.object(sync.requests, "post", return_value=response) as post:
            sync.auto_link(match, listing)
        payload = post.call_args.kwargs["json"]
        self.assertEqual(payload["p"]["item_id"], "DEN-064")
        self.assertTrue(payload["p"]["relist"])


if __name__ == "__main__":
    unittest.main()
