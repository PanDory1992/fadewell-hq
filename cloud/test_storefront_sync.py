import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import storefront_sync as sf


class StorefrontSyncTests(unittest.TestCase):
    def test_measurements_are_parsed_and_order_independent(self):
        result = sf.extract_measurements("""Overall length: 108 cm
Waist: 42 cm
Front rise 31cm
Inseam — 80,5 cm
Leg opening: 21 cm
Thigh 30 cm
Hips: 52 cm""")
        self.assertEqual(result["waist"]["cm"], 42)
        self.assertEqual(result["inseam"]["cm"], 80.5)
        self.assertEqual(set(sf.REQUIRED_MEASUREMENTS) - set(result), set())

    def test_category_comes_from_vinted_not_title(self):
        shorts = {"id": 1, "title": "Perfect vintage jeans", "catalog": {"title": "Denim shorts"}}
        trousers = {"id": 2, "title": "Unhelpful title", "catalog": {"title": "Trousers"}}
        self.assertIsNone(sf.garment_type_from_vinted_category(shorts))
        self.assertEqual(sf.garment_type_from_vinted_category(trousers), "TROUSERS")

    def test_catalog_path_resolves_category_id(self):
        item = sf.attach_catalog_path({"id": 3, "catalog_id": 42}, {"42": ["Men", "Clothing", "Trousers", "Jeans"]})
        self.assertEqual(sf.garment_type_from_vinted_category(item), "JEANS")

    def test_complete_pair_is_publishable(self):
        item = {
            "id": 123,
            "title": "Levi's 501",
            "catalog": {"title": "Jeans"},
            "description": "Waist 42 cm\nRise 31 cm\nInseam 80 cm\nLeg opening 21 cm\nOverall length 108 cm",
            "photos": [{"high_resolution": {"url": "https://img.example/pair.jpg"}}],
            "price": {"amount": "149.00"},
        }
        record = sf.build_storefront_record(item)
        self.assertTrue(record["published"])
        self.assertEqual(record["garment_type"], "JEANS")
        self.assertEqual(record["photos"], ["https://img.example/pair.jpg"])

    def test_missing_required_measurement_stays_unpublished(self):
        item = {"id": 123, "catalog": {"title": "Jeans"}, "description": "Waist 42 cm", "photo": {"url": "x"}}
        record = sf.build_storefront_record(item)
        self.assertFalse(record["published"])
        self.assertIn("inseam", record["publication_notes"]["missing_measurements"])


if __name__ == "__main__":
    unittest.main()
