"""Guarded Google Ledger writeback for Miki-confirmed Vinted identity matches."""
from __future__ import annotations

import argparse, csv, hashlib, json
from datetime import datetime, timezone
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

ROOT=Path(__file__).resolve().parents[1]; SYNC=ROOT/"sheets_sync"; LIVE=ROOT/"outputs"/"vinted-live-wardrobe"/"latest.csv"
OUT=ROOT/"outputs"/"hq_manual_matching"; BACKUPS=OUT/"online-ledger-backups"; PLAN=OUT/"confirmed_match_write_plan.json"; HISTORY=OUT/"relist_identity_history.json"
SPREADSHEET_ID="1f3webEvwvBOrLwwPwnbWcou_xWGiQpg3mTffPf9m9kQ"; SHEET="Master Ledger"
MATCHES={"9376228712":{"item_id":"DEN-185","old_id":"8832297950"},"9376043091":{"item_id":"DEN-039","old_id":"8976763929"},"9371143114":{"item_id":"DEN-236","old_id":""},"9316771455":{"item_id":"DEN-222","old_id":""},"9312661449":{"item_id":"DEN-235","old_id":""},"9290086215":{"item_id":"DEN-207","old_id":""},"9288589445":{"item_id":"DEN-200","old_id":""}}

def service(write):
    token=SYNC/("token_write.json" if write else "token.json")
    scopes=["https://www.googleapis.com/auth/spreadsheets"] if write else ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    creds=Credentials.from_authorized_user_file(token,scopes)
    if creds.expired and creds.refresh_token: creds.refresh(Request())
    if not creds.valid: raise RuntimeError(f"Credentials invalid: {token}")
    return build("sheets","v4",credentials=creds)
def formulas(api):
    all_formulas=[]
    for tab in ("Master Ledger","KPI Dashboard"):
        rows=api.spreadsheets().values().get(spreadsheetId=SPREADSHEET_ID,range=f"'{tab}'!A1:AC1000",valueRenderOption="FORMULA").execute().get("values",[])
        all_formulas += [(tab,r,c,v) for r,row in enumerate(rows,1) for c,v in enumerate(row,1) if isinstance(v,str) and v.startswith("=")]
    return all_formulas,hashlib.sha256(json.dumps(all_formulas,ensure_ascii=False,sort_keys=True).encode()).hexdigest()
def read_live():
    with LIVE.open(encoding="utf-8-sig",newline="") as handle: return {str(row["vinted_item_id"]):row for row in csv.DictReader(handle)}
def build_plan(api):
    raw=api.spreadsheets().values().get(spreadsheetId=SPREADSHEET_ID,range=f"'{SHEET}'!A1:AC1000",valueRenderOption="UNFORMATTED_VALUE").execute().get("values",[])
    headers=raw[0]; by_id={str(row[0]):(number,row+['']*(len(headers)-len(row))) for number,row in enumerate(raw[1:],2) if row and row[0]}
    columns={name:chr(65+index) for index,name in enumerate(headers)}; required=["Vinted_Item_ID","Listing_URL","Live_Title","Live_List_Price","Last_Live_Check_Date"]
    if missing:=set(required)-set(columns): raise RuntimeError(f"Missing live columns: {sorted(missing)}")
    live=read_live(); updates=[]; history=[]
    for vinted_id,match in MATCHES.items():
        if vinted_id not in live: raise RuntimeError(f"Confirmed listing no longer in current live snapshot: {vinted_id}")
        item_id=match["item_id"]
        if item_id not in by_id: raise RuntimeError(f"Item_ID missing online: {item_id}")
        row_number,row=by_id[item_id]; current=str(row[headers.index("Vinted_Item_ID")] or "")
        if current != match["old_id"]: raise RuntimeError(f"{item_id}: expected existing Vinted ID {match['old_id']!r}, found {current!r}")
        detail=live[vinted_id]
        fields={"Vinted_Item_ID":vinted_id,"Listing_URL":detail["url"],"Live_Title":detail["title"],"Live_List_Price":float(detail["price_pln"]),"Last_Live_Check_Date":datetime.now().strftime("%d-%m-%Y")}
        updates.append({"item_id":item_id,"row":row_number,"fields":fields})
        if current: history.append({"item_id":item_id,"previous_vinted_item_id":current,"current_vinted_item_id":vinted_id,"reason":"Miki-confirmed relist identity transition","recorded_at":datetime.now(timezone.utc).isoformat()})
    before_formulas,before_hash=formulas(api)
    return {"created_at":datetime.now(timezone.utc).isoformat(),"updates":updates,"relist_history":history,"raw_values":raw,"formulas":before_formulas,"formula_hash":before_hash}
def verify_online(api):
    raw=api.spreadsheets().values().get(spreadsheetId=SPREADSHEET_ID,range=f"'{SHEET}'!A1:AC1000",valueRenderOption="UNFORMATTED_VALUE").execute().get("values",[])
    headers=raw[0]; id_column=headers.index("Item_ID"); vinted_column=headers.index("Vinted_Item_ID")
    online={str(row[id_column]):row for row in raw[1:] if len(row)>id_column and row[id_column]}
    for vinted_id,match in MATCHES.items():
        row=online.get(match["item_id"],[])
        current=str(row[vinted_column] if len(row)>vinted_column else "")
        if current != vinted_id: raise RuntimeError(f"Post-write ID mismatch for {match['item_id']}: {current!r}")
    return len(MATCHES)
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--apply",action="store_true"); args=parser.parse_args(); api=service(args.apply); plan=build_plan(api)
    OUT.mkdir(parents=True,exist_ok=True); PLAN.write_text(json.dumps({k:v for k,v in plan.items() if k not in {"raw_values","formulas"}},ensure_ascii=False,indent=2),encoding="utf-8")
    if not args.apply: print(json.dumps({"mode":"dry-run","updates":len(plan["updates"]),"plan":str(PLAN)},ensure_ascii=False)); return
    BACKUPS.mkdir(parents=True,exist_ok=True); stamp=datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_UTC"); backup=BACKUPS/f"before_confirmed_matches_{stamp}.json"; backup.write_text(json.dumps({"values":plan["raw_values"],"formulas":plan["formulas"]},ensure_ascii=False),encoding="utf-8")
    data=[]
    for update in plan["updates"]:
        for header,value in update["fields"].items():
            column=chr(65+["Item_ID","Name_Zakupy","Sourcing_Type","Curation_Era","Purchase_Cost","Delivery_Cost","Total_Capital","Wystawione","Sale_Price_Arbitrage","Sale_Price_Recycled","Net_Profit","Status","Flip_Tier","Est_Sale_Range","Est_Sale_Price","Est_Net_Profit","DATE_OF_PURCHASE","DATE_OF_LISTING","DATE_OF_SALE","Kategoria","Atut","Vinted_Item_ID","Listing_URL","Live_Title","Live_List_Price","Last_Live_Check_Date","Est_Confidence","Est_Evidence","Est_Model_Version"].index(header))
            data.append({"range":f"'{SHEET}'!{column}{update['row']}","values":[[value]]})
    api.spreadsheets().values().batchUpdate(spreadsheetId=SPREADSHEET_ID,body={"valueInputOption":"USER_ENTERED","data":data}).execute()
    verified=verify_online(api); after_formulas,after_hash=formulas(api)
    if after_hash != plan["formula_hash"]: raise RuntimeError("Formula hash changed; inspect backup before continuing")
    HISTORY.write_text(json.dumps(plan["relist_history"],ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps({"mode":"applied","updates":len(plan["updates"]),"verified":verified,"backup":str(backup),"history":str(HISTORY),"formulas_unchanged":True},ensure_ascii=False))
if __name__=="__main__": main()
