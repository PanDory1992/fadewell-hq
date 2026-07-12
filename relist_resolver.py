"""Read-only relist detector for DEN inventory.

It may propose evidence, never change a Vinted ID. A relist becomes an
automatic link only when HQ has a deterministic listing-intent identity.
"""
from __future__ import annotations

import csv, json, re, sqlite3
from difflib import SequenceMatcher
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]; HQ=Path(__file__).resolve().parent
LIVE=ROOT/"outputs"/"vinted-live-wardrobe"/"latest.csv"; SCOPE=HQ/"operational_scope.json"; OUT=HQ/"reports"/"relist_candidates_latest.json"; DB=HQ/"data"/"hq.sqlite"
def norm(value): return " ".join(re.findall(r"[a-z0-9]+",str(value or "").casefold()))
def similarity(left,right): return round(SequenceMatcher(None,norm(left),norm(right)).ratio(),3)
def main():
    config=json.loads(SCOPE.read_text(encoding="utf-8")); excluded=set(config["excluded_live_vinted_ids"])
    db=sqlite3.connect(DB); db.row_factory=sqlite3.Row
    all_ledger=[{"Item_ID":r["item_id"],"Name_Zakupy":r["name"],"Status":r["ledger_status"],"Vinted_Item_ID":r["vinted_item_id"],"Live_Title":r["live_title"]} for r in db.execute("SELECT item_id,name,ledger_status,vinted_item_id,live_title FROM items")]
    ledger=all_ledger
    with LIVE.open(encoding="utf-8-sig",newline="") as file: live=[row for row in csv.DictReader(file) if str(row.get("vinted_item_id")) not in excluded]
    live_by_id={str(row["vinted_item_id"]):row for row in live}; known_ids={str(row.get("Vinted_Item_ID")) for row in all_ledger if row.get("Vinted_Item_ID")}
    new_live=[row for row in live if str(row["vinted_item_id"]) not in known_ids]
    proposals=[]
    for item in ledger:
        old_id=str(item.get("Vinted_Item_ID") or "")
        if not old_id or old_id in live_by_id or item.get("Status")!="LISTED-BACKLOG": continue
        snapshot=db.execute("select title from listing_snapshots where vinted_item_id=? order by captured_at desc limit 1",(old_id,)).fetchone()
        old_title=(snapshot["title"] if snapshot else None) or item.get("Live_Title") or item.get("Name_Zakupy")
        ranked=sorted(((max(similarity(old_title,row.get("title")),similarity(item.get("Live_Title"),row.get("title"))),row) for row in new_live),reverse=True,key=lambda x:x[0])
        if not ranked: continue
        score,new=ranked[0]; second=ranked[1][0] if len(ranked)>1 else 0; margin=round(score-second,3)
        if score < .8 or margin < .12: continue
        proposals.append({"item_id":item["Item_ID"],"old_vinted_item_id":old_id,"old_title":old_title,"candidate_vinted_item_id":str(new["vinted_item_id"]),"candidate_title":new.get("title"),"score":score,"margin":margin,"state":"EVIDENCE_ONLY","reason":"Public listing data has no immutable Item_ID; do not auto-link."})
    OUT.parent.mkdir(exist_ok=True); OUT.write_text(json.dumps({"candidate_count":len(proposals),"candidates":proposals},ensure_ascii=False,indent=2),encoding="utf-8")
    print(f"Wrote {len(proposals)} evidence-only relist candidates.")
if __name__=="__main__": main()
