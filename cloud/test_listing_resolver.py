"""Focused safety checks for the conservative Vinted-to-DEN resolver."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from listing_resolver import best_match, marker


def item(item_id="DEN-123", name="Levi's 501 W32 L32", estimate=200):
    return {"item_id": item_id, "name": name, "category": "Jeans", "advantage": "", "estimate_sale_price": estimate}


class ListingResolverTests(unittest.TestCase):
    def test_exact_den_marker_autolinks(self):
        result = best_match({"title": "Levi's #den123", "price_pln": 180}, [item()])
        self.assertTrue(result["auto"])
        self.assertEqual(result["item"]["item_id"], "DEN-123")

    def test_ambiguous_model_and_size_stays_manual(self):
        listing = {"title": "Levi's 501 W32 L32", "price_pln": 200}
        result = best_match(listing, [item("DEN-123"), item("DEN-124")])
        self.assertFalse(result["auto"])
        self.assertEqual(result["confidence"], "MEDIUM")

    def test_title_match_without_size_and_model_never_autolinks(self):
        result = best_match({"title": "Levi's blue jeans", "price_pln": 200}, [item()])
        self.assertFalse(result["auto"])

    def test_marker_normalizes_den_identifier(self):
        self.assertEqual(marker("Proof #DEN-00123"), "DEN-123")


if __name__ == "__main__":
    unittest.main()
