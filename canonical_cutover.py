"""Explicit service-role calls for the guarded HQ Ledger cutover functions."""
from __future__ import annotations

import argparse, json, os
from collections import Counter
from decimal import Decimal
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

HQ=Path(__file__).resolve().parent; REPORT=HQ/"reports"/"ledger_migration_latest.json"
def credentials():
    for line in (HQ/".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key,value=line.split("=",1); os.environ.setdefault(key.strip(),value.strip())
    return os.environ["SUPABASE_URL"].rstrip("/"),os.environ["SUPABASE_SERVICE_ROLE_KEY"]
def call(function, import_id):
    url,key=credentials(); request=Request(f"{url}/rest/v1/rpc/{function}",data=json.dumps({"p_import_id":import_id}).encode(),method="POST",headers={"apikey":key,"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    try:
        with urlopen(request,timeout=60): pass
    except HTTPError as error:
        raise RuntimeError(error.read().decode("utf-8",errors="replace")) from error
def status(import_id):
    url,key=credentials(); headers={"apikey":key,"Authorization":f"Bearer {key}"}
    with urlopen(Request(f"{url}/rest/v1/hq_ledger_items?select=item_id,ledger_status,total_capital&limit=1000",headers=headers),timeout=60) as response: rows=json.loads(response.read().decode())
    with urlopen(Request(f"{url}/rest/v1/hq_ledger_import_runs?select=import_id,status&import_id=eq.{import_id}",headers=headers),timeout=60) as response: run=json.loads(response.read().decode())
    print(json.dumps({"canonical_rows":len(rows),"status_counts":dict(Counter(row["ledger_status"] for row in rows)),"capital_total":str(sum((Decimal(str(row["total_capital"] or 0)) for row in rows),Decimal("0"))),"import":run},ensure_ascii=False))
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--verify",action="store_true"); parser.add_argument("--promote",action="store_true"); parser.add_argument("--status",action="store_true"); parser.add_argument("--confirm-import-id"); args=parser.parse_args()
    if sum((args.verify,args.promote,args.status)) != 1: raise SystemExit("Choose exactly one action")
    import_id=json.loads(REPORT.read_text(encoding="utf-8"))["import_id"]
    if args.status: status(import_id); return
    if args.promote and args.confirm_import_id != import_id: raise SystemExit("Promotion requires --confirm-import-id matching the verified import")
    call("verify_hq_ledger_import" if args.verify else "promote_hq_ledger_import",import_id)
    print(f"{'Verified' if args.verify else 'Promoted'} import {import_id}.")
if __name__=="__main__": main()
