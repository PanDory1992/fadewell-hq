"""Generate read-only, confidence-scored Vinted-to-Ledger link suggestions."""
from __future__ import annotations

import csv, json, re, sqlite3
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]; HQ = Path(__file__).resolve().parent
WARDROBE = ROOT / "outputs" / "vinted-live-wardrobe" / "latest.csv"; DB = HQ / "data" / "hq.sqlite"
JSON_OUT = HQ / "reports" / "link_suggestions_latest.json"; MD_OUT = HQ / "reports" / "link_suggestions_latest.md"
SCOPE = HQ / "operational_scope.json"

def words(value): return set(re.findall(r"[a-z0-9]+", str(value or "").casefold()))
def score(a, b):
    left, right = words(a), words(b)
    if not left or not right: return 0.0
    overlap = len(left & right) / max(len(left), len(right))
    sequence = SequenceMatcher(None, " ".join(sorted(left)), " ".join(sorted(right))).ratio()
    return round(0.7 * overlap + 0.3 * sequence, 3)

def main():
    connection=sqlite3.connect(DB); connection.row_factory=sqlite3.Row
    ledger=[{"Item_ID":r["item_id"],"Name_Zakupy":r["name"],"Status":r["ledger_status"],"Vinted_Item_ID":r["vinted_item_id"]} for r in connection.execute("SELECT item_id,name,ledger_status,vinted_item_id FROM items")]; connection.close()
    with WARDROBE.open(encoding="utf-8-sig", newline="") as file: live = list(csv.DictReader(file))
    excluded = set(json.loads(SCOPE.read_text(encoding="utf-8"))["excluded_live_vinted_ids"])
    known = {str(row.get("Vinted_Item_ID") or "") for row in ledger if row.get("Vinted_Item_ID")}
    candidates = [row for row in ledger if not row.get("Vinted_Item_ID") and row.get("Status") == "LISTED-BACKLOG"]
    suggestions=[]; unlinked_live_count=0
    for listing in live:
        if str(listing.get("vinted_item_id")) in known or str(listing.get("vinted_item_id")) in excluded: continue
        unlinked_live_count += 1
        ranked=sorted(((score(listing.get("title"), item.get("Name_Zakupy")), item) for item in candidates), reverse=True, key=lambda pair: pair[0])
        if not ranked: continue
        best_score,best=ranked[0]; second=ranked[1][0] if len(ranked)>1 else 0.0; margin=round(best_score-second,3)
        # Weak text resemblance is worse than no suggestion: it creates work
        # and could mis-link a financial item. Preserve it as unresolved.
        if best_score < .45: continue
        confidence="HIGH" if best_score >= .82 and margin >= .18 else "MEDIUM" if best_score >= .62 and margin >= .10 else "LOW"
        suggestions.append({"vinted_item_id":str(listing.get("vinted_item_id")),"live_title":listing.get("title"),"listing_url":listing.get("url"),"suggested_item_id":best.get("Item_ID"),"suggested_name":best.get("Name_Zakupy"),"score":best_score,"margin":margin,"confidence":confidence})
    report={"unlinked_live_count":unlinked_live_count,"suggestion_count":len(suggestions),"high_confidence_count":sum(x["confidence"]=="HIGH" for x in suggestions),"suggestions":suggestions}
    JSON_OUT.parent.mkdir(exist_ok=True); JSON_OUT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
    lines=["# HQ link suggestions", "", "Read-only suggestions. Nothing is linked automatically.", "", "| Confidence | Live listing | Suggested Ledger item | Score |", "|---|---|---|---:|"]
    lines += [f"| {x['confidence']} | {x['live_title']} | {x['suggested_item_id']} — {x['suggested_name']} | {x['score']:.3f} |" for x in suggestions]
    MD_OUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print(f"Generated {len(suggestions)} suggestions ({report['high_confidence_count']} high confidence).")

if __name__ == "__main__": main()
