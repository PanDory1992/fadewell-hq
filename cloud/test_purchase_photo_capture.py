import unittest

from purchase_photo_capture import first_product_photos, matching_order, preloaded_orders, unique_bundle_mapping


class CaptureTest(unittest.TestCase):
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
