"""FADEWELL HQ: dependency-free local foundation for the online operating system."""
from __future__ import annotations

import csv
import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timezone, timedelta
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
HQ = Path(__file__).resolve().parent
DB_PATH = HQ / "data" / "hq.sqlite"
LEDGER = ROOT / "sheets_sync" / "synced" / "vinted_ledger.csv"
WARDROBE = ROOT / "outputs" / "vinted-live-wardrobe" / "latest.csv"
SCOPE = HQ / "operational_scope.json"
CUTOVER = HQ / "cutover.json"


def load_environment():
    """Use local .env when present; hosting supplies the same values directly."""
    env_file = HQ / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def scope():
    config = json.loads(SCOPE.read_text(encoding="utf-8"))
    return tuple(config["included_item_prefixes"]), set(config["excluded_live_vinted_ids"])


def canonical_items():
    """Read the authoritative HQ Ledger after cutover; never fall back to Sheet."""
    load_environment()
    url = os.environ["SUPABASE_URL"].rstrip("/"); key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    request = Request(f"{url}/rest/v1/hq_ledger_items?select=*&limit=1000", headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def canonical_action(payload):
    load_environment()
    url=os.environ["SUPABASE_URL"].rstrip("/"); key=os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    request=Request(f"{url}/rest/v1/rpc/apply_hq_ledger_action",data=json.dumps(payload).encode(),method="POST",headers={"apikey":key,"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    with urlopen(request,timeout=60) as response: return response.read().decode("utf-8")


def canonical_events(item_id):
    load_environment()
    url=os.environ["SUPABASE_URL"].rstrip("/"); key=os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    request=Request(f"{url}/rest/v1/hq_ledger_events?select=event_type,occurred_on,amount,detail,source,created_at&item_id=eq.{item_id}&order=created_at.desc",headers={"apikey":key,"Authorization":f"Bearer {key}"})
    with urlopen(request,timeout=60) as response: return json.loads(response.read().decode("utf-8"))


def db():
    DB_PATH.parent.mkdir(exist_ok=True)
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    connection.executescript("""
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS items (
      item_id TEXT PRIMARY KEY, name TEXT, sourcing_type TEXT, tier TEXT,
      total_capital REAL, ledger_status TEXT, vinted_item_id TEXT UNIQUE,
      listing_url TEXT, live_title TEXT, created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS listing_snapshots (
      id INTEGER PRIMARY KEY, vinted_item_id TEXT NOT NULL, captured_at TEXT NOT NULL,
      title TEXT, price_pln REAL, views INTEGER, favourites INTEGER,
      visible INTEGER, photo_url TEXT, source TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS review_queue (
      id INTEGER PRIMARY KEY, kind TEXT NOT NULL, item_id TEXT,
      vinted_item_id TEXT, detail TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'OPEN',
      created_at TEXT NOT NULL, UNIQUE(kind, vinted_item_id, state)
    );
    CREATE TABLE IF NOT EXISTS action_drafts (
      id INTEGER PRIMARY KEY, item_id TEXT NOT NULL, action_type TEXT NOT NULL,
      occurred_on TEXT, amount REAL, note TEXT, state TEXT NOT NULL DEFAULT 'DRAFT',
      created_at TEXT NOT NULL
    );
    """)
    return connection


def number(value):
    try:
        return float(str(value or "").replace(",", "."))
    except ValueError:
        return None


def sync():
    if not WARDROBE.exists():
        raise SystemExit("Run the live wardrobe pull before HQ sync.")
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    connection = db()
    prefixes, excluded_live_ids = scope()
    # REC/personal inventory remains in the Google Ledger only. HQ is the DEN
    # operating system, so remove only its derived operational copies.
    if CUTOVER.exists():
        ledger_rows = canonical_items()
        rec_vinted_ids = set()
    else:
        with LEDGER.open(encoding="utf-8-sig", newline="") as handle:
            ledger_rows = list(csv.DictReader(handle))
        rec_vinted_ids = {str(row.get("Vinted_Item_ID")) for row in ledger_rows if str(row.get("Item_ID") or "").startswith("REC-") and row.get("Vinted_Item_ID")}
    for vinted_id in rec_vinted_ids | excluded_live_ids:
        connection.execute("DELETE FROM listing_snapshots WHERE vinted_item_id=?", (vinted_id,))
        connection.execute("DELETE FROM review_queue WHERE vinted_item_id=?", (vinted_id,))
    connection.execute("DELETE FROM review_queue WHERE item_id LIKE 'REC-%'")
    connection.execute("DELETE FROM items WHERE item_id LIKE 'REC-%'")
    for row in ledger_rows:
        item_id = row.get("item_id") if CUTOVER.exists() else row.get("Item_ID")
        if not item_id or not item_id.startswith(prefixes):
            continue
        connection.execute("""
              INSERT INTO items(item_id,name,sourcing_type,tier,total_capital,ledger_status,
                vinted_item_id,listing_url,live_title,created_at)
              VALUES(?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(item_id) DO UPDATE SET
                name=excluded.name, sourcing_type=excluded.sourcing_type, tier=excluded.tier,
                total_capital=excluded.total_capital, ledger_status=excluded.ledger_status,
                vinted_item_id=COALESCE(excluded.vinted_item_id,items.vinted_item_id),
                listing_url=COALESCE(excluded.listing_url,items.listing_url),
                live_title=COALESCE(excluded.live_title,items.live_title)
            """, (item_id,(row.get("name") if CUTOVER.exists() else row.get("Name_Zakupy")),(row.get("sourcing_type") if CUTOVER.exists() else row.get("Sourcing_Type")),(row.get("flip_tier") if CUTOVER.exists() else row.get("Flip_Tier")),
                  number(row.get("total_capital") if CUTOVER.exists() else row.get("Total_Capital")),(row.get("ledger_status") if CUTOVER.exists() else row.get("Status")),(row.get("vinted_item_id") if CUTOVER.exists() else row.get("Vinted_Item_ID")) or None,
                  (row.get("listing_url") if CUTOVER.exists() else row.get("Listing_URL")) or None,(row.get("live_title") if CUTOVER.exists() else row.get("Live_Title")) or None,now))
    # A stale snapshot may make dozens of legitimate listings look "missing".
    # Import it for viewing, but never generate disappearance reviews from it.
    snapshot_fresh = datetime.now(timezone.utc) - datetime.fromtimestamp(
        WARDROBE.stat().st_mtime, timezone.utc
    ) <= timedelta(hours=6)
    if not snapshot_fresh:
        connection.execute("""UPDATE review_queue SET state='STALE_SNAPSHOT'
          WHERE kind='MISSING' AND state='OPEN'""")
    else:
        # Review rows from before canonical cutover may refer to superseded IDs
        # or historical sold items. Rebuild the live inbox from current truth.
        connection.execute("""DELETE FROM review_queue AS old WHERE old.state='OPEN'
          AND EXISTS (SELECT 1 FROM review_queue AS archived
            WHERE archived.kind=old.kind AND archived.vinted_item_id=old.vinted_item_id
              AND archived.state='STALE_SNAPSHOT')""")
        connection.execute("UPDATE review_queue SET state='STALE_SNAPSHOT' WHERE state='OPEN'")
    live_ids = set()
    with WARDROBE.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            vinted_id = str(row.get("vinted_item_id") or "")
            if not vinted_id or vinted_id in excluded_live_ids:
                continue
            live_ids.add(vinted_id)
            connection.execute("""INSERT INTO listing_snapshots
              (vinted_item_id,captured_at,title,price_pln,views,favourites,visible,photo_url,source)
              VALUES(?,?,?,?,?,?,?,?,?)""", (vinted_id,now,row.get("title"),number(row.get("price_pln")),
                int(row.get("views") or 0),int(row.get("favourites") or 0),1,row.get("photo_url"),"wrapper"))
            known = connection.execute("SELECT item_id FROM items WHERE vinted_item_id=?",(vinted_id,)).fetchone()
            if not known:
                connection.execute("""INSERT OR IGNORE INTO review_queue
                  (kind,vinted_item_id,detail,created_at) VALUES(?,?,?,?)""",
                  ("UNLINKED_LIVE",vinted_id,"Live listing has no Item_ID mapping.",now))
    if snapshot_fresh:
        for item in connection.execute("SELECT item_id,vinted_item_id FROM items WHERE vinted_item_id IS NOT NULL AND ledger_status='LISTED-BACKLOG'"):
            if item["vinted_item_id"] not in live_ids:
                # A human may already have classified this exact disappearance.
                # Do not reopen the same evidence on every scheduled snapshot.
                resolved = connection.execute("""SELECT 1 FROM review_queue
                  WHERE kind='MISSING' AND vinted_item_id=? AND state IN
                  ('SOLD','RELISTED','HIDDEN','UNKNOWN','REVIEWED') LIMIT 1""",
                  (item["vinted_item_id"],)).fetchone()
                if resolved:
                    continue
                connection.execute("""INSERT OR IGNORE INTO review_queue
                  (kind,item_id,vinted_item_id,detail,created_at) VALUES(?,?,?,?,?)""",
                  ("MISSING",item["item_id"],item["vinted_item_id"],
                   "Known live listing missing from current wrapper snapshot; classify sold, relist, hidden, or unknown.",now))
    connection.commit(); connection.close()
    print("FADEWELL HQ synchronised.")


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            return self.respond((HQ / "web" / "home.html").read_text(encoding="utf-8"),"text/html")
        if self.path == "/operations":
            return self.respond((HQ / "web" / "operations.html").read_text(encoding="utf-8"),"text/html")
        if self.path == "/cloud":
            return self.respond((HQ / "web" / "index.html").read_text(encoding="utf-8"),"text/html")
        if self.path == "/ledger":
            return self.respond((HQ / "web" / "ledger.html").read_text(encoding="utf-8"),"text/html")
        if self.path.startswith("/actions"):
            return self.respond((HQ / "web" / "actions.html").read_text(encoding="utf-8"),"text/html")
        if self.path == "/readiness":
            return self.respond((HQ / "web" / "readiness.html").read_text(encoding="utf-8"),"text/html")
        if self.path in {"/api/health", "/api/link-suggestions"}:
            filename = "health_latest.json" if self.path == "/api/health" else "link_suggestions_latest.json"
            report = HQ / "reports" / filename
            if not report.exists(): return self.send_error(404, "Report has not been generated yet")
            return self.respond(report.read_text(encoding="utf-8"), "application/json")
        if self.path == "/api/ledger-stage":
            report_path = HQ / "reports" / "ledger_migration_latest.json"; migration = json.loads(report_path.read_text(encoding="utf-8")) if report_path.exists() else {}
            if CUTOVER.exists():
                fields={"item_id":"Item_ID","name":"Name_Zakupy","ledger_status":"Status","flip_tier":"Flip_Tier","total_capital":"Total_Capital","estimate_sale_price":"Est_Sale_Price","estimate_confidence":"Est_Confidence","listing_url":"Listing_URL","live_list_price":"Live_List_Price","purchased_on":"DATE_OF_PURCHASE","listed_on":"DATE_OF_LISTING","sold_on":"DATE_OF_SALE"}
                rows=[{target:row.get(source) for source,target in fields.items()} for row in canonical_items()]
                return self.respond(json.dumps({"stage":{"import_id":migration.get("import_id"),"verified":True,"source_synced_at":"CANONICAL HQ"},"items":rows}),"application/json")
            with LEDGER.open(encoding="utf-8-sig", newline="") as handle: rows = [row for row in csv.DictReader(handle) if str(row.get("Item_ID") or "").startswith("DEN-")]
            return self.respond(json.dumps({"stage": {"import_id": migration.get("import_id"), "verified": migration.get("remote_verification", {}).get("verified", False), "source_synced_at": migration.get("source_synced_at")}, "items": rows}), "application/json")
        if self.path.startswith("/api/ledger-item/"):
            item_id = self.path.rsplit("/", 1)[-1]
            if CUTOVER.exists():
                source = next((row for row in canonical_items() if row.get("item_id") == item_id), None)
                item = {"Item_ID":source.get("item_id"),"Name_Zakupy":source.get("name"),"Sourcing_Type":source.get("sourcing_type"),"Curation_Era":source.get("curation_era"),"Purchase_Cost":source.get("purchase_cost"),"Delivery_Cost":source.get("delivery_cost"),"Total_Capital":source.get("total_capital"),"Net_Profit":source.get("net_profit"),"Est_Sale_Range":source.get("estimate_range"),"Est_Sale_Price":source.get("estimate_sale_price"),"Est_Net_Profit":source.get("estimate_net_profit"),"Est_Evidence":source.get("estimate_evidence"),"Vinted_Item_ID":source.get("vinted_item_id"),"Listing_URL":source.get("listing_url"),"Live_Title":source.get("live_title")} if source else None
            else:
                with LEDGER.open(encoding="utf-8-sig", newline="") as handle: item = next((row for row in csv.DictReader(handle) if row.get("Item_ID") == item_id and item_id.startswith("DEN-")), None)
            if not item: return self.send_error(404, "Unknown operational Item_ID")
            c = db(); snapshots = c.execute("SELECT captured_at,title,price_pln,views,favourites,photo_url FROM listing_snapshots WHERE vinted_item_id=? ORDER BY captured_at DESC LIMIT 30", (item.get("Vinted_Item_ID"),)).fetchall(); c.close()
            events = canonical_events(item_id) if CUTOVER.exists() else []
            return self.respond(json.dumps({"item": item, "snapshots": [dict(row) for row in snapshots], "events": events}), "application/json")
        if self.path == "/api/action-drafts":
            c=db(); rows=c.execute("SELECT * FROM action_drafts ORDER BY id DESC LIMIT 100").fetchall(); c.close()
            return self.respond(json.dumps([dict(row) for row in rows]), "application/json")
        if self.path == "/api/readiness":
            def report(name):
                path = HQ / "reports" / name
                return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
            migration, health, links, relists = report("ledger_migration_latest.json"), report("health_latest.json"), report("link_suggestions_latest.json"), report("relist_candidates_latest.json")
            gates = [
                {"name":"Immutable staging","ok": migration.get("remote_verification",{}).get("verified",False),"detail":migration.get("import_id","Brak importu")},
                {"name":"Walidacja Ledgeru","ok":migration.get("valid",False),"detail":f"Błędy: {len(migration.get('errors',[]))}; warningi: {len(migration.get('warnings',[]))}"},
                {"name":"Świeżość źródeł","ok":health.get("healthy",False),"detail":health.get("sources",{}).get("ledger",{}).get("synced_at","Brak")},
                {"name":"Nierozstrzygnięte live linki","ok":links.get("unlinked_live_count",0)==0,"detail":str(links.get("unlinked_live_count",0))},
                {"name":"Kandydaci relistów","ok":relists.get("candidate_count",0)==0,"detail":str(relists.get("candidate_count",0))},
                {"name":"REC poza HQ","ok":True,"detail":"Google Ledger only"}
            ]
            return self.respond(json.dumps({"ready":all(g["ok"] for g in gates),"gates":gates,"warnings":migration.get("warnings",[])}),"application/json")
        if self.path == "/api/kpis":
            rows=canonical_items(); unsold=[row for row in rows if row.get("ledger_status") != "SOLD"]; sold=[row for row in rows if row.get("ledger_status") == "SOLD"]
            amount=lambda row,key: float(row.get(key) or 0)
            c=db(); live=c.execute("SELECT COUNT(DISTINCT vinted_item_id) FROM listing_snapshots WHERE captured_at=(SELECT MAX(captured_at) FROM listing_snapshots)").fetchone()[0]; c.close()
            payload={"items":len(rows),"listed":sum(row.get("ledger_status")=="LISTED-BACKLOG" for row in rows),"unlisted":sum(row.get("ledger_status")=="UNLISTED-BACKLOG" for row in rows),"sold":len(sold),"live":live,"capital_unsold":round(sum(amount(row,"total_capital") for row in unsold),2),"sold_revenue":round(sum(amount(row,"sale_price_arbitrage") or amount(row,"sale_price_recycled") for row in sold),2),"sold_profit":round(sum(amount(row,"net_profit") for row in sold),2)}
            return self.respond(json.dumps(payload),"application/json")
        if self.path == "/api/operations":
            c=db(); queue=[dict(row) for row in c.execute("SELECT * FROM review_queue WHERE state='OPEN' ORDER BY created_at DESC").fetchall()]; drafts=[dict(row) for row in c.execute("SELECT * FROM action_drafts WHERE state='DRAFT' ORDER BY created_at DESC").fetchall()]; c.close()
            return self.respond(json.dumps({"queue":queue,"drafts":drafts}),"application/json")
        if self.path == "/api/dashboard":
            c=db(); rows=c.execute("""SELECT i.item_id,i.name,s.title,s.price_pln,s.views,s.favourites,s.photo_url
              FROM listing_snapshots s LEFT JOIN items i ON i.vinted_item_id=s.vinted_item_id
              WHERE s.captured_at=(SELECT MAX(captured_at) FROM listing_snapshots)
              ORDER BY s.favourites DESC,s.views DESC LIMIT 30""").fetchall()
            queue=c.execute("SELECT * FROM review_queue WHERE state='OPEN' ORDER BY id DESC LIMIT 30").fetchall()
            live_count=c.execute("SELECT COUNT(*) FROM listing_snapshots WHERE captured_at=(SELECT MAX(captured_at) FROM listing_snapshots)").fetchone()[0]
            health_file = HQ / "reports" / "health_latest.json"
            health = json.loads(health_file.read_text(encoding="utf-8")) if health_file.exists() else {}
            summary={"items":c.execute("SELECT COUNT(*) FROM items").fetchone()[0],"live":live_count,"reviews":c.execute("SELECT COUNT(*) FROM review_queue WHERE state='OPEN'").fetchone()[0],"source health":"OK" if health.get("healthy") else "CHECK"}
            c.close(); return self.respond(json.dumps({"summary":summary,"items":[dict(x) for x in rows],"queue":[dict(x) for x in queue]}),"application/json")
        self.send_error(404)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self.send_error(400, "Invalid JSON")
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        if self.path == "/api/action-drafts":
            item_id=str(payload.get("item_id") or "").strip(); action_type=str(payload.get("action_type") or "").upper()
            occurred_on=str(payload.get("occurred_on") or "").strip() or None; note=str(payload.get("note") or "").strip() or None
            if not item_id.startswith("DEN-") or action_type not in {"PURCHASE","LISTED","SALE","ADJUSTMENT"}: return self.send_error(400,"Valid DEN Item_ID and action type are required")
            amount=number(payload.get("amount")); c=db(); exists=c.execute("SELECT 1 FROM items WHERE item_id=?",(item_id,)).fetchone()
            if not exists: c.close(); return self.send_error(404,"Unknown Item_ID")
            c.execute("INSERT INTO action_drafts(item_id,action_type,occurred_on,amount,note,created_at) VALUES(?,?,?,?,?,?)",(item_id,action_type,occurred_on,amount,note,now)); c.commit(); c.close()
            return self.respond('{"ok":true,"state":"DRAFT"}',"application/json")
        if self.path == "/api/ledger-actions":
            action_type=str(payload.get("action_type") or "").upper(); item_id=str(payload.get("item_id") or "").strip()
            if action_type == "PURCHASE" and not item_id:
                numbers=[int(row["item_id"].split("-",1)[1]) for row in canonical_items() if str(row.get("item_id","")).startswith("DEN-") and row["item_id"].split("-",1)[1].isdigit()]
                item_id=f"DEN-{max(numbers,default=0)+1:03d}"
            if action_type not in {"PURCHASE","LISTED","SALE","ADJUSTMENT"} or not item_id:
                return self.send_error(400,"Action type and Item_ID are required")
            if action_type == "SALE":
                sale_price = number(payload.get("amount"))
                source = next((row for row in canonical_items() if row.get("item_id") == item_id), None)
                capital = number(source.get("total_capital")) if source else None
                if sale_price is None or sale_price < 0:
                    return self.send_error(400, "SALE requires a valid sale price")
                if capital is None:
                    return self.send_error(400, "Cannot calculate profit: item has no total capital")
                # Net profit is derived from the immutable sale price and the
                # item capital; it is never typed by the operator.
                payload["net_profit"] = round(sale_price - capital, 2)
            payload["action_type"]=action_type; payload["item_id"]=item_id; payload["external_key"]=str(uuid.uuid4())
            try:
                event_id=canonical_action(payload)
                # The local monitor refreshes its cache after an action. The
                # hosted app has no private Vinted snapshot file, so it must
                # still confirm the already-committed canonical action.
                if WARDROBE.exists(): sync()
            except Exception as error: return self.send_error(400,str(error))
            return self.respond(json.dumps({"ok":True,"event_id":event_id,"item_id":item_id}),"application/json")
        if self.path == "/api/link":
            item_id=str(payload.get("item_id") or "").strip(); vinted_id=str(payload.get("vinted_item_id") or "").strip()
            if not item_id or not vinted_id: return self.send_error(400, "Item_ID and Vinted ID are required")
            c=db(); exists=c.execute("SELECT 1 FROM items WHERE item_id=?",(item_id,)).fetchone()
            if not exists: c.close(); return self.send_error(404, "Unknown Item_ID")
            c.execute("UPDATE items SET vinted_item_id=? WHERE item_id=?",(vinted_id,item_id))
            c.execute("UPDATE review_queue SET state='LINKED' WHERE id=?",(payload.get("review_id"),)); c.commit(); c.close()
            return self.respond('{"ok":true}',"application/json")
        if self.path.startswith("/api/review/"):
            review_id=self.path.rsplit('/',1)[-1]; state=str(payload.get("state") or "REVIEWED").upper()
            if state not in {"SOLD","RELISTED","HIDDEN","UNKNOWN","REVIEWED"}: return self.send_error(400,"Invalid state")
            c=db(); c.execute("UPDATE review_queue SET state=? WHERE id=?",(state,review_id)); c.commit(); c.close(); return self.respond('{}',"application/json")
        self.send_error(404)
    def respond(self, body, content_type):
        data=body.encode(); self.send_response(200); self.send_header("Content-Type",content_type+"; charset=utf-8"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self,*args): pass


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv)>1 else "serve"
    if command == "sync": sync()
    elif command == "serve":
        host = os.environ.get("HOST", "127.0.0.1")
        port = int(os.environ.get("PORT", "8765"))
        print(f"FADEWELL HQ: http://{host}:{port}"); ThreadingHTTPServer((host,port),Handler).serve_forever()
    else: raise SystemExit("Use: python app.py [sync|serve]")
