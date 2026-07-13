"""Create and verify self-contained, checksummed HQ Ledger export bundles.

The export is a backup of HQ's canonical DEN scope, not a replacement for the
Google Sheet while HQ remains in its parallel-validation phase.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

HQ = Path(__file__).resolve().parent
DEFAULT_OUT = HQ / "backups"
TABLES = ("hq_ledger_items", "hq_ledger_events", "hq_external_events")


def load_environment() -> None:
    env_file = HQ / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def fetch_all(table: str, page_size: int = 1000) -> list[dict]:
    """Read all rows with stable pagination; never silently truncate a backup."""
    load_environment()
    url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    rows: list[dict] = []
    start = 0
    while True:
        query = urlencode({"select": "*", "order": "id.asc" if table != "hq_ledger_items" else "item_id.asc", "limit": page_size, "offset": start})
        request = Request(f"{url}/rest/v1/{table}?{query}", headers={"apikey": key, "Authorization": f"Bearer {key}"})
        with urlopen(request, timeout=60) as response:
            page = json.loads(response.read().decode("utf-8"))
        if not isinstance(page, list):
            raise RuntimeError(f"Unexpected {table} response; refusing incomplete export")
        rows.extend(page)
        if len(page) < page_size:
            return rows
        start += len(page)


def make_bundle(rows_by_table: dict[str, list[dict]], created_at: str | None = None) -> dict:
    """Build the portable payload separately so it can be tested offline."""
    missing = set(TABLES) - set(rows_by_table)
    if missing:
        raise ValueError(f"Missing required export tables: {', '.join(sorted(missing))}")
    records = {table: rows_by_table[table] for table in TABLES}
    manifest = {
        "format": "fadewell-hq-canonical-export/v1",
        "created_at": created_at or datetime.now(timezone.utc).isoformat(),
        "scope": "HQ canonical DEN Ledger; Google Sheet remains bookkeeping truth until explicit cutover.",
        "tables": {table: {"row_count": len(records[table]), "sha256": hashlib.sha256(canonical_bytes(records[table])).hexdigest()} for table in TABLES},
    }
    manifest["bundle_sha256"] = hashlib.sha256(canonical_bytes({"manifest": manifest, "records": records})).hexdigest()
    return {"manifest": manifest, "records": records}


def verify_bundle(bundle: dict) -> dict:
    """Return a concise verification result or raise for tampering/truncation."""
    manifest, records = bundle.get("manifest"), bundle.get("records")
    if not isinstance(manifest, dict) or not isinstance(records, dict):
        raise ValueError("Invalid export structure")
    if manifest.get("format") != "fadewell-hq-canonical-export/v1":
        raise ValueError("Unknown export format")
    for table in TABLES:
        rows = records.get(table)
        expected = (manifest.get("tables") or {}).get(table, {})
        if not isinstance(rows, list) or len(rows) != expected.get("row_count"):
            raise ValueError(f"Row-count mismatch for {table}")
        if hashlib.sha256(canonical_bytes(rows)).hexdigest() != expected.get("sha256"):
            raise ValueError(f"Checksum mismatch for {table}")
    expected_bundle = manifest.get("bundle_sha256")
    unsigned_manifest = dict(manifest); unsigned_manifest.pop("bundle_sha256", None)
    actual_bundle = hashlib.sha256(canonical_bytes({"manifest": unsigned_manifest, "records": {table: records[table] for table in TABLES}})).hexdigest()
    if actual_bundle != expected_bundle:
        raise ValueError("Bundle checksum mismatch")
    return {"valid": True, "created_at": manifest.get("created_at"), "row_counts": {table: len(records[table]) for table in TABLES}}


def write_bundle(out_dir: Path = DEFAULT_OUT) -> Path:
    bundle = make_bundle({table: fetch_all(table) for table in TABLES})
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%SZ")
    target = out_dir / f"canonical_export_{stamp}.json"
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, target)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description="Create or verify a FADEWELL HQ canonical export bundle.")
    parser.add_argument("--verify", type=Path, help="verify an existing bundle without network access")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="directory for a new bundle")
    args = parser.parse_args()
    if args.verify:
        result = verify_bundle(json.loads(args.verify.read_text(encoding="utf-8")))
        print(json.dumps(result, ensure_ascii=False))
        return
    target = write_bundle(args.out)
    print(json.dumps({"created": str(target), **verify_bundle(json.loads(target.read_text(encoding="utf-8")))}, ensure_ascii=False))


if __name__ == "__main__":
    main()
