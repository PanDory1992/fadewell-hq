"""Safety tests for Vinted snapshot pagination."""
import os
import sys
import unittest
from types import SimpleNamespace
from pathlib import Path

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
            {"items": [item(1)], "pagination": {"total_pages": 1, "total_entries": 2}},
        ])
        with self.assertRaisesRegex(RuntimeError, "expected 2 unique items, got 1"):
            list(sync.fetch_items(session))

    def test_only_explicit_active_confirmation_becomes_override(self):
        responses = iter([
            RequestsResponse([{"item_id": "DEN-224", "vinted_item_id": "9288606102"}]),
            RequestsResponse([
                {"item_id": "DEN-224", "detail": "Miki manually confirmed this listing is currently active."},
                {"item_id": "DEN-224", "detail": "Ordinary manual mapping."},
            ]),
        ])
        original_get = sync.requests.get
        sync.requests.get = lambda *_args, **_kwargs: next(responses)
        try:
            result = sync.manually_confirmed_missing_listings(set())
        finally:
            sync.requests.get = original_get
        self.assertEqual(result[0]["item_id"], "DEN-224")


if __name__ == "__main__":
    unittest.main()
