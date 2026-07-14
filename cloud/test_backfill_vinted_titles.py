import os, sys, unittest
from types import SimpleNamespace
from pathlib import Path
os.environ.setdefault("SUPABASE_URL","https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY","test-key")
sys.modules.setdefault("cloudscraper",SimpleNamespace(create_scraper=lambda:None))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import backfill_vinted_titles as sync

class TitleParserTests(unittest.TestCase):
    def test_reads_og_title_and_removes_vinted_suffix(self):
        page='<meta property="og:title" content="Levi’s 501 – W32 L32 | Vinted">'
        self.assertEqual(sync.title_from_html(page),'Levi’s 501 – W32 L32')
    def test_rejects_generic_title(self): self.assertIsNone(sync.title_from_html('<title>Vinted</title>'))

if __name__=="__main__": unittest.main()
