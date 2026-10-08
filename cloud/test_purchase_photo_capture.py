import unittest
from unittest.mock import MagicMock, patch

import requests

from purchase_photo_capture import Vinted, first_product_photos, main, matching_order, preloaded_orders, unique_bundle_mapping


class CaptureTest(unittest.TestCase):
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
