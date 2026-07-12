"""Create and verify immutable, read-only Ledger staging snapshots for HQ.

The default is local validation only. --push calls one transactional Supabase
RPC after migration 004. It never writes to Google Sheet and never promotes a
staging snapshot into the future canonical HQ Ledger.
"""
from __future__ import annotations

import argparse, csv, hashlib, json, os, uuid
from collections import Counter
from datetime import datetime, timezone, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]; HQ = Path(__file__).resolve().parent
CSV = ROOT / "sheets_sync" / "synced" / "vinted_ledger.csv"; MANIFEST = ROOT / "sheets_sync" / "synced" / "_manifest.json"
REPORT = HQ / "reports" / "ledger_migration_latest.json"
REQUIRED = {"Item_ID","Name_Zakupy","Purchase_Cost","Delivery_Cost","Total_Capital","Status","DATE_OF_PURCHASE","DATE_OF_LISTING","DATE_OF_SALE"}
KNOWN_STATUSES = {"LISTED-BACKLOG","UNLISTED-BACKLOG","SOLD"}

def text(v): return (str(v or "").strip() or None)
def sha(value): return hashlib.sha256(value).hexdigest()
def money(v):
    v = text(v)
    if v is None: return None
    try: return Decimal(v.replace(" ", "").replace(",", ".")).quantize(Decimal("0.01"))
    except InvalidOperation: raise ValueError(f"invalid PLN value {v!r}")
def date(v):
    v = text(v)
    if v is None: return None
    for fmt in ("%d-%m-%Y","%Y-%m-%d"):
        try: return datetime.strptime(v,fmt).date().isoformat()
        except ValueError: pass
    raise ValueError(f"invalid date {v!r}")
def boolean(v):
    v=text(v)
    if v is None: return None
    if v.casefold() in {"tak","yes","true","1"}: return True
    if v.casefold() in {"nie","no","false","0"}: return False
    raise ValueError(f"invalid listed value {v!r}")
def serial(v): return str(v) if isinstance(v,Decimal) else v

def normalise(row, import_id):
    result={
      "item_id":text(row["Item_ID"]),"name":text(row["Name_Zakupy"]),"sourcing_type":text(row.get("Sourcing_Type")),"curation_era":text(row.get("Curation_Era")),
      "purchase_cost":money(row.get("Purchase_Cost")),"delivery_cost":money(row.get("Delivery_Cost")),"total_capital":money(row.get("Total_Capital")),"listed":boolean(row.get("Wystawione")),
      "sale_price_arbitrage":money(row.get("Sale_Price_Arbitrage")),"sale_price_recycled":money(row.get("Sale_Price_Recycled")),"net_profit":money(row.get("Net_Profit")),
      "ledger_status":text(row.get("Status")),"flip_tier":text(row.get("Flip_Tier")),"estimate_range":text(row.get("Est_Sale_Range")),"estimate_sale_price":money(row.get("Est_Sale_Price")),"estimate_net_profit":money(row.get("Est_Net_Profit")),
      "purchased_on":date(row.get("DATE_OF_PURCHASE")),"listed_on":date(row.get("DATE_OF_LISTING")),"sold_on":date(row.get("DATE_OF_SALE")),"category":text(row.get("Kategoria")),"advantage":text(row.get("Atut")),
      "vinted_item_id":text(row.get("Vinted_Item_ID")),"listing_url":text(row.get("Listing_URL")),"live_title":text(row.get("Live_Title")),"live_list_price":money(row.get("Live_List_Price")),"last_live_check_on":date(row.get("Last_Live_Check_Date")),
      "estimate_confidence":text(row.get("Est_Confidence")),"estimate_evidence":text(row.get("Est_Evidence")),"estimate_model_version":text(row.get("Est_Model_Version")),"source_import_id":import_id,"source_row":row
    }
    return {k:serial(v) for k,v in result.items()}

def load():
    manifest=json.loads(MANIFEST.read_text(encoding="utf-8"))["vinted_ledger"]
    if manifest.get("status") != "ok": raise SystemExit("Ledger manifest is not healthy")
    raw=CSV.read_bytes(); digest=sha(raw)
    reader=csv.DictReader(raw.decode("utf-8-sig").splitlines()); fields=reader.fieldnames or []
    if missing:=REQUIRED-set(fields): raise SystemExit(f"Missing Ledger columns: {sorted(missing)}")
    return manifest,list(reader),digest,sha("\x1f".join(fields).encode())

def validate(rows, import_id):
    errors=[]; warnings=[]; ids=set(); vinted_ids=set(); capital=Decimal("0.00"); statuses=Counter()
    for number,row in enumerate(rows,2):
      try:
        current=normalise(row,import_id); item_id=current["item_id"]; status=current["ledger_status"]
        if not item_id: errors.append(f"row {number}: blank Item_ID")
        elif item_id in ids: errors.append(f"row {number}: duplicate Item_ID {item_id}")
        else: ids.add(item_id)
        if not current["name"]: errors.append(f"row {number}: blank Name_Zakupy")
        if status not in KNOWN_STATUSES: errors.append(f"row {number}: invalid Status {status!r}")
        statuses[status or "BLANK"]+=1; capital += Decimal(current["total_capital"] or "0")
        vinted=current["vinted_item_id"]
        if vinted and vinted in vinted_ids: errors.append(f"row {number}: duplicate Vinted_Item_ID {vinted}")
        if vinted: vinted_ids.add(vinted)
        p,d,t=(Decimal(current[k] or "0") for k in ("purchase_cost","delivery_cost","total_capital"))
        if abs((p+d)-t)>Decimal("0.01"): errors.append(f"row {number}: Total_Capital does not equal purchase + delivery")
        if current["listed_on"] and current["purchased_on"] and current["listed_on"] < current["purchased_on"]: warnings.append({"item_id":item_id,"code":"LISTING_BEFORE_PURCHASE","detail":f"Sheet row {number}: {current['listed_on']} precedes {current['purchased_on']}","severity":"WARNING"})
        if current["sold_on"] and current["listed_on"] and current["sold_on"] < current["listed_on"]: warnings.append({"item_id":item_id,"code":"SALE_BEFORE_LISTING","detail":f"Sheet row {number}: {current['sold_on']} precedes {current['listed_on']}","severity":"WARNING"})
      except ValueError as error: errors.append(f"row {number}: {error}")
    return {"valid":not errors,"errors":errors,"warnings":warnings,"status_counts":dict(statuses),"capital_total":str(capital.quantize(Decimal("0.01")))}

def credentials():
    path=HQ/".env"
    for line in path.read_text(encoding="utf-8").splitlines() if path.exists() else []:
      if "=" in line and not line.lstrip().startswith("#"):
        key,value=line.split("=",1); os.environ.setdefault(key.strip(),value.strip())
    return os.environ["SUPABASE_URL"].rstrip("/"),os.environ["SUPABASE_SERVICE_ROLE_KEY"]
def call(url,key,path,payload):
    req=Request(f"{url}/rest/v1/{path}",data=json.dumps(payload).encode(),method="POST",headers={"apikey":key,"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    with urlopen(req,timeout=60) as response: return json.loads(response.read().decode() or "null")
def query(url,key,table,params):
    req=Request(f"{url}/rest/v1/{table}?{urlencode(params)}",headers={"apikey":key,"Authorization":f"Bearer {key}"})
    with urlopen(req,timeout=60) as response:return json.loads(response.read().decode())

def main():
  parser=argparse.ArgumentParser(); parser.add_argument("--push",action="store_true"); parser.add_argument("--verify",action="store_true"); args=parser.parse_args()
  if args.push and args.verify: raise SystemExit("Use --push or --verify, not both")
  manifest,rows,source_sha,headers_sha=load(); previous=json.loads(REPORT.read_text(encoding="utf-8")) if REPORT.exists() else None
  if args.push:
    synced=datetime.fromisoformat(manifest["last_synced_utc"])
    if datetime.now(timezone.utc)-synced > timedelta(minutes=30): raise SystemExit("Refusing to stage a Ledger snapshot older than 30 minutes")
  import_id=(previous or {}).get("import_id") if args.verify else str(uuid.uuid4()); report=validate(rows,import_id)
  report.update({"import_id":import_id,"generated_at":datetime.now(timezone.utc).isoformat(),"source_synced_at":manifest["last_synced_utc"],"source_sha256":source_sha,"source_headers_sha256":headers_sha,"row_count":len(rows),"mode":"STAGED"})
  REPORT.parent.mkdir(exist_ok=True); REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
  if not report["valid"]: raise SystemExit(f"Validation failed; see {REPORT}")
  print(f"Validated {len(rows)} rows; capital {report['capital_total']} PLN.")
  if args.verify:
    if not previous or previous.get("source_sha256")!=source_sha: raise SystemExit("Source changed since staging; create a new staging import first")
    url,key=credentials(); remote=query(url,key,"hq_ledger_import_items",{"select":"item_id,payload","import_id":f"eq.{import_id}","limit":"1000"})
    remote_ids={r["item_id"] for r in remote}; expected={normalise(r,import_id)["item_id"] for r in rows}; remote_capital=sum((Decimal(r["payload"]["total_capital"] or "0") for r in remote),Decimal("0"))
    report["remote_verification"]={"remote_rows":len(remote),"missing_item_ids":sorted(expected-remote_ids),"unexpected_item_ids":sorted(remote_ids-expected),"capital_total_match":str(remote_capital.quantize(Decimal("0.01")))==report["capital_total"]}
    report["remote_verification"]["verified"]=len(remote)==len(expected) and not report["remote_verification"]["missing_item_ids"] and not report["remote_verification"]["unexpected_item_ids"] and report["remote_verification"]["capital_total_match"]
    REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    if not report["remote_verification"]["verified"]: raise SystemExit(f"Remote mismatch; see {REPORT}")
    print(f"Verified immutable remote import {import_id}."); return
  if not args.push: print(f"Local-only report: {REPORT}"); return
  url,key=credentials(); metadata={"import_id":import_id,"source_name":"google_sheet_vinted_ledger","source_synced_at":manifest["last_synced_utc"],"row_count":len(rows),"source_sha256":source_sha,"source_headers_sha256":headers_sha,"report":report,"exceptions":report["warnings"]}
  items=[{"item_id":normalise(row,import_id)["item_id"],"payload":normalise(row,import_id),"source_row_sha256":sha(json.dumps(row,ensure_ascii=False,sort_keys=True,separators=(",",":" )).encode())} for row in rows]
  staged=call(url,key,"rpc/stage_hq_ledger_import",{"p_metadata":metadata,"p_items":items})
  report["import_id"]=staged; REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
  print(f"Atomically staged immutable import {staged}. No cutover was performed.")
if __name__=="__main__": main()
