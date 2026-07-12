"""Write a machine-readable health report for FADEWELL HQ source freshness."""
from __future__ import annotations

import json, sqlite3
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]; HQ = Path(__file__).resolve().parent
WARDROBE = ROOT / "outputs" / "vinted-live-wardrobe" / "latest.csv"
DB = HQ / "data" / "hq.sqlite"; REPORT = HQ / "reports" / "health_latest.json"
BACKUPS = HQ / "backups"

def age(path):
    return round((datetime.now(timezone.utc) - datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)).total_seconds() / 60, 1) if path.exists() else None

def main():
    backups = sorted(BACKUPS.glob("canonical_ledger_*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    latest_backup = backups[0] if backups else None
    report = {"generated_at": datetime.now(timezone.utc).isoformat(), "sources": {
        "ledger": {"status": "CANONICAL_HQ", "synced_at": (HQ / "cutover.json").exists() and json.loads((HQ / "cutover.json").read_text(encoding="utf-8")).get("cutover_at"), "rows": None},
        "vinted_wardrobe": {"exists": WARDROBE.exists(), "age_minutes": age(WARDROBE)},
        "hq_cache": {"exists": DB.exists(), "age_minutes": age(DB)},
        "canonical_backup": {"exists": latest_backup is not None, "age_minutes": age(latest_backup) if latest_backup else None, "path": str(latest_backup) if latest_backup else None}
    }}
    if DB.exists():
        connection = sqlite3.connect(DB)
        report["hq"] = {"items": connection.execute("select count(*) from items").fetchone()[0],
                        "latest_live": connection.execute("select count(*) from listing_snapshots where captured_at=(select max(captured_at) from listing_snapshots)").fetchone()[0],
                        "open_reviews": connection.execute("select count(*) from review_queue where state='OPEN'").fetchone()[0]}
        connection.close()
    report["healthy"] = (
        report["sources"]["ledger"]["status"] == "CANONICAL_HQ"
        and report["sources"]["vinted_wardrobe"]["age_minutes"] is not None
        and report["sources"]["vinted_wardrobe"]["age_minutes"] <= 360
        and report["sources"]["canonical_backup"]["age_minutes"] is not None
        and report["sources"]["canonical_backup"]["age_minutes"] <= 360
        and report.get("hq", {}).get("items", 0) > 0
    )
    REPORT.parent.mkdir(exist_ok=True); REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"HQ health: {'OK' if report['healthy'] else 'CHECK'} -> {REPORT}")

if __name__ == "__main__": main()
