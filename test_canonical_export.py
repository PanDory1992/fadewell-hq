import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canonical_export import make_bundle, verify_bundle


class CanonicalExportTests(unittest.TestCase):
    def setUp(self):
        self.rows = {
            "hq_ledger_items": [{"item_id": "DEN-001", "total_capital": 42.0}],
            "hq_ledger_events": [{"id": 1, "item_id": "DEN-001", "event_type": "PURCHASE"}],
            "hq_external_events": [{"id": 7, "source_event_id": "gmail-123", "state": "AUTO_APPLIED"}],
        }

    def test_bundle_verifies_and_reports_all_tables(self):
        bundle = make_bundle(self.rows, "2026-07-13T00:00:00+00:00")
        self.assertEqual(verify_bundle(bundle)["row_counts"], {table: 1 for table in self.rows})

    def test_modified_history_is_detected(self):
        bundle = make_bundle(self.rows)
        changed = copy.deepcopy(bundle)
        changed["records"]["hq_ledger_events"][0]["event_type"] = "SALE"
        with self.assertRaisesRegex(ValueError, "Checksum"):
            verify_bundle(changed)

    def test_missing_table_is_refused(self):
        rows = dict(self.rows); rows.pop("hq_external_events")
        with self.assertRaisesRegex(ValueError, "Missing required"):
            make_bundle(rows)


if __name__ == "__main__":
    unittest.main()
