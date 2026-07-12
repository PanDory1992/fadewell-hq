"""Push the local FADEWELL HQ operational cache to Supabase with a server-only key."""
import json, os, sqlite3
from pathlib import Path
from urllib.parse import urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "hq.sqlite"
SCOPE = ROOT / "operational_scope.json"
for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines() if (ROOT / ".env").exists() else []:
    if "=" in line and not line.lstrip().startswith("#"):
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())
URL = os.environ.get("SUPABASE_URL", "https://qgjkxtolyhbwpvncwtkn.supabase.co").rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]

def push(table, rows, conflict=None):
    if not rows: return
    endpoint = f"{URL}/rest/v1/{table}"
    if conflict: endpoint += f"?on_conflict={conflict}"
    data = json.dumps(rows, default=str).encode()
    request = Request(endpoint, data=data, method="POST", headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates,return=minimal"
    })
    try:
        with urlopen(request, timeout=30): pass
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Supabase rejected {table}: {detail}") from error

def has_column(table, column):
    """Return False until the matching Supabase migration has been applied."""
    request = Request(f"{URL}/rest/v1/{table}?select={column}&limit=1", headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}"
    })
    try:
        with urlopen(request, timeout=30): return True
    except HTTPError as error:
        if error.code == 400: return False
        raise

def replace_local_rows(table, prefix, rows):
    """Refresh only rows mirrored from this local HQ cache.

    The remote tables use generated identity IDs and a partial uniqueness rule,
    so PostgREST cannot use them as an ON CONFLICT target. These rows are a
    cache of the local operational truth, therefore replacing this namespace is
    deterministic and leaves any future non-local records untouched.
    """
    query = urlencode({"external_key": f"like.{prefix}*"})
    request = Request(f"{URL}/rest/v1/{table}?{query}", method="DELETE", headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}", "Prefer": "return=minimal"
    })
    with urlopen(request, timeout=30): pass
    push(table, rows)

def delete_where(table, query):
    request = Request(f"{URL}/rest/v1/{table}?{urlencode(query)}", method="DELETE", headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}", "Prefer": "return=minimal"
    })
    with urlopen(request, timeout=30): pass

def main():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row
    # The scope file is now the sole operational boundary.  Do not read the
    # legacy Google Ledger during a cloud sync after cutover.
    excluded = set(json.loads(SCOPE.read_text(encoding="utf-8"))["excluded_live_vinted_ids"])
    items = [dict(r) for r in c.execute("SELECT * FROM items")]
    snapshots = [dict(r) for r in c.execute("SELECT vinted_item_id,captured_at,title,price_pln,views,favourites,visible,photo_url,source FROM listing_snapshots")]
    push("hq_items", items, "item_id")
    push("hq_listing_snapshots", snapshots, "vinted_item_id,captured_at")
    if has_column("hq_review_queue", "external_key"):
        reviews = [{
            "external_key": f"local-review-{row['id']}", "kind": row["kind"],
            "item_id": row["item_id"], "vinted_item_id": row["vinted_item_id"],
            "detail": row["detail"], "state": row["state"], "created_at": row["created_at"]
        } for row in c.execute("SELECT * FROM review_queue")]
        replace_local_rows("hq_review_queue", "local-review-", reviews)
        # Capture Purchase was deliberately retired: purchases are canonical
        # Ledger actions, not a parallel inbox. Clean only its local mirror.
        if has_column("hq_capture_candidates", "external_key"):
            delete_where("hq_capture_candidates", {"external_key": "like.local-capture-*"})
        # Keep REC out of the HQ cloud copy; its accounting history remains
        # solely in the transition-source Google Ledger. Reviews go first
        # because hq_review_queue has an item foreign key.
        delete_where("hq_items", {"item_id": "like.REC-*"})
        for offset in range(0, len(excluded), 50):
            batch = list(excluded)[offset:offset+50]
            if batch: delete_where("hq_listing_snapshots", {"vinted_item_id": f"in.({','.join(batch)})"})
        print(f"Supabase synced: {len(items)} items, {len(snapshots)} snapshots and {len(reviews)} reviews.")
    else:
        print(f"Supabase synced: {len(items)} items and {len(snapshots)} snapshots. Operational queue waits for migration 002.")
    c.close()

if __name__ == "__main__": main()
