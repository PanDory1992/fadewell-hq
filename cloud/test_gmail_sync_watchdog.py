import unittest
from datetime import datetime, timedelta, timezone

from cloud.gmail_sync_watchdog import is_stale


class GmailSyncWatchdogTest(unittest.TestCase):
    def test_missing_success_is_stale(self):
        self.assertTrue(is_stale(None))

    def test_recent_success_is_fresh(self):
        now = datetime(2026, 8, 20, 16, 0, tzinfo=timezone.utc)
        self.assertFalse(is_stale((now - timedelta(minutes=11)).isoformat(), now=now))

    def test_old_success_is_stale(self):
        now = datetime(2026, 8, 20, 16, 0, tzinfo=timezone.utc)
        self.assertTrue(is_stale((now - timedelta(minutes=13)).isoformat(), now=now))


if __name__ == "__main__":
    unittest.main()
