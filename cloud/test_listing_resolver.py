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

    def test_slash_size_and_non_conflicting_attributes_break_a_safe_tie(self):
        listing = {"title": "Levis 501 Redtab Medium Blue W33 L32 Vintage 2000 Made in Poland", "price_pln": 179}
        candidates = [
            item("DEN-219", "Levis 501 33/32 Midblue Vintage", 155),
            item("DEN-225", "Levis 501-0660 33/32 1994 USA Charcoal", 225),
        ]
        result = best_match(listing, candidates)
        self.assertTrue(result["auto"])
        self.assertEqual(result["item"]["item_id"], "DEN-219")

    def test_unique_relist_uses_the_previous_live_title(self):
        listing = {"title": "Levi's 512 Slim Tapered Jeans Optic White W26 L26 US 7MED Vintage 1996 Made in USA", "price_pln": 129}
        relisted = item("DEN-141", "Spodnie", 129)
        relisted.update({"vinted_item_id": "9279738596", "live_title": "Levi's 512 Slim Tapered Jeans Optic White W26 L26 US 7MED Vintage Made in USA"})
        result = best_match(listing, [relisted])
        self.assertTrue(result["auto"])
        self.assertEqual(result["item"]["item_id"], "DEN-141")

    def test_unique_relist_without_model_number_can_autolink(self):
        listing = {"title": "Calvin Klein Vintage Straight Jeans – Mid Blue – W33 L30 – Made in USA", "price_pln": 129}
        relisted = item("DEN-046", "CK 33 USA Skracane", 100)
        relisted.update({"vinted_item_id": "8116225370", "live_title": "Calvin Klein Vintage Straight Jeans – Navy Blue – W33 L30 – Made in USA"})
        result = best_match(listing, [relisted])
        self.assertTrue(result["auto"])
        self.assertEqual(result["item"]["item_id"], "DEN-046")
        self.assertIn("jednoznaczny profil relistu", result["reasons"])

    def test_two_near_identical_relist_candidates_stay_manual(self):
        listing = {"title": "Calvin Klein Vintage Straight Jeans – Mid Blue – W33 L30 – Made in USA", "price_pln": 129}
        candidates = []
        for den, old_id in (("DEN-046", "8116225370"), ("DEN-047", "8116225371")):
            candidate = item(den, "CK 33 USA Skracane", 100)
            candidate.update({"vinted_item_id": old_id, "live_title": "Calvin Klein Vintage Straight Jeans – Navy Blue – W33 L30 – Made in USA"})
            candidates.append(candidate)
        result = best_match(listing, candidates)
        self.assertFalse(result["auto"])

    def test_manual_ledger_title_beats_a_wrong_relist_with_conflicting_length(self):
        listing = {"title": "Levi’s 501 Original Fit Button Fly Jeans - Dark Indigo - W32 L32 - 2006 Red Tab", "price_pln": 189}
        hidden_wrong_relist = item("DEN-093", "Levis 501 32/30 Puchate PL", 150)
        hidden_wrong_relist.update({
            "vinted_item_id": "9342042409",
            "live_title": "Levi’s 501 Original Fit Jeans - Dark Indigo - W32 L30 - Vintage Made in Poland 2002",
            "storefront_hidden": True,
        })
        correct_unlisted = item("DEN-274", "spodnie levis", 160)
        correct_unlisted["manual_title"] = "Levis 501 Dark Blue Indigo 32/32 Perfect"
        result = best_match(listing, [hidden_wrong_relist, correct_unlisted])
        self.assertTrue(result["auto"])
        self.assertEqual(result["item"]["item_id"], "DEN-274")

    def test_relist_with_conflicting_length_never_autolinks(self):
        listing = {"title": "Levi’s 501 Original Fit Jeans - Dark Indigo - W32 L32", "price_pln": 189}
        candidate = item("DEN-093", "Levis 501 32/30 Puchate PL", 150)
        candidate.update({"vinted_item_id": "9342042409", "live_title": "Levi’s 501 Original Fit Jeans - Dark Indigo - W32 L30"})
        result = best_match(listing, [candidate])
        self.assertFalse(result["auto"])
        self.assertIn("sprzeczny pełny rozmiar", result["reasons"])

    def test_marker_normalizes_den_identifier(self):
        self.assertEqual(marker("Proof #DEN-00123"), "DEN-123")


if __name__ == "__main__":
    unittest.main()
