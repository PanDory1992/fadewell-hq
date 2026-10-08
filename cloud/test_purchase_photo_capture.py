import base64
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import requests

from purchase_photo_capture import Vinted, access_token_expires_soon, first_product_photos, load_session_cookie, main, matching_order, preloaded_orders, save_session_cookie, unique_bundle_mapping


class CaptureTest(unittest.TestCase):
    def test_refresh_rotates_both_tokens_without_logging_them(self):
        session = requests.Session()
        home = MagicMock()
        home.text = '<meta name="csrf-token" content="csrf-probe">falka.falka35'
        renewed = MagicMock()
        renewed.json.return_value = {'access_token': 'new-access', 'refresh_token': 'new-refresh'}
        session.get = MagicMock(return_value=home)
        session.post = MagicMock(return_value=renewed)
        with patch('purchase_photo_capture.cloudscraper.create_scraper', return_value=session):
            buyer = Vinted('access_token_web=old-access; refresh_token_web=old-refresh', force_refresh=True)
        self.assertEqual(session.post.call_args.args[0], 'https://www.vinted.pl/oauth/token')
        self.assertEqual(session.post.call_args.kwargs['json']['refresh_token'], 'old-refresh')
        self.assertEqual(session.post.call_args.kwargs['headers']['X-CSRF-Token'], 'csrf-probe')
        self.assertIn('access_token_web=new-access', buyer.cookie_header())
        self.assertIn('refresh_token_web=new-refresh', buyer.cookie_header())
        self.assertNotIn('old-refresh', buyer.cookie_header())

    def test_encrypted_session_roundtrip_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'session.enc'
            with patch('purchase_photo_capture.COOKIE', 'bootstrap-secret-with-high-entropy-123456789'), \
                 patch('purchase_photo_capture.SESSION_FILE', str(target)):
                save_session_cookie('access_token_web=private; refresh_token_web=renewed')
                self.assertNotIn(b'private', target.read_bytes())
                self.assertEqual(load_session_cookie(), 'access_token_web=private; refresh_token_web=renewed')
                damaged = bytearray(target.read_bytes())
                damaged[-4] ^= 1
                target.write_bytes(damaged)
                with self.assertRaises(Exception):
                    load_session_cookie()

    def test_access_expiry_triggers_refresh_before_cookie_expiry(self):
        payload = base64.urlsafe_b64encode(json.dumps({'exp': int(time.time()) + 3600}).encode()).decode().rstrip('=')
        self.assertTrue(access_token_expires_soon(f'x.{payload}.x'))

    def test_buyer_anon_cookie_uses_scoped_domain_when_home_sets_another(self):
        session = requests.Session()
        session.cookies.set('anon_id', 'home', domain='www.vinted.pl')
        response = MagicMock()
        response.text = 'falka.falka35'
        session.get = MagicMock(return_value=response)
        with patch('purchase_photo_capture.COOKIE', 'access_token_web=test; anon_id=buyer'), \
             patch('purchase_photo_capture.cloudscraper.create_scraper', return_value=session):
            buyer = Vinted()
        self.assertEqual(buyer.api_headers['X-Anon-Id'], 'buyer')

    def test_empty_queue_does_not_need_vinted_session(self):
        class EmptyHq:
            def table(self, *_args, **_kwargs):
                return []
        with patch('purchase_photo_capture.HQ_URL', 'https://example.supabase.co'), \
             patch('purchase_photo_capture.HQ_KEY', 'test'), \
             patch('purchase_photo_capture.COOKIE', ''), \
             patch('purchase_photo_capture.Hq', return_value=EmptyHq()), \
             patch('purchase_photo_capture.Vinted') as vinted:
            main()
            vinted.assert_not_called()

    def test_server_order_payload(self):
        page = '<script>self.__next_f.push([1,"2d:[\\\"x\\\",{\\\"preloadedOrders\\\":{\\\"orders\\\":[{\\\"transactionId\\\":123,\\\"conversationId\\\":\\\"456\\\"}]}}]"])</script>'
        self.assertEqual(preloaded_orders(page)[0]["conversationId"], "456")

    def test_product_preloads_stop_before_avatar(self):
        page = ''.join(f'<link rel="preload" as="image" href="{url}">' for url in (
            'https://images1.vinted.net/t/one.webp', 'https://images1.vinted.net/t/two.webp',
            'https://static.vinted.com/avatar.jpg', 'https://images1.vinted.net/t/unrelated.webp'))
        self.assertEqual(len(first_product_photos(page)), 2)

    def test_transaction_identity_uses_paid_amount_and_date(self):
        job = {"vinted_transaction_id": "123", "paid_amount": 36.20, "occurred_on": "2026-10-06",
               "receipt_title": "Levi's 505", "bundle_titles": []}
        orders = [{"transaction_id": 123, "price": {"amount": "36.20"},
                   "date": "2026-10-06T20:00:00Z", "title": "Levi's 505"}]
        self.assertEqual(matching_order(job, orders), orders[0])

    def test_bundle_mapping_never_uses_vinted_array_position(self):
        self.assertEqual(unique_bundle_mapping(["Wrangler", "Lee"], ["DEN-1", "DEN-2"],
                                               {"99": "Lee", "88": "Wrangler"}),
                         {"99": "DEN-2", "88": "DEN-1"})
        self.assertEqual(unique_bundle_mapping(["Jeans", "Jeans"], ["DEN-1", "DEN-2"],
                                               {"99": "Jeans", "88": "Jeans"}), {})


if __name__ == "__main__":
    unittest.main()
