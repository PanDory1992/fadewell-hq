"""Create a dependency-free XLSX workbook for safe manual Vinted-ID matching."""
from __future__ import annotations

import csv, html, zipfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "sheets_sync" / "synced" / "vinted_ledger.csv"
LIVE = ROOT / "outputs" / "vinted-live-wardrobe" / "latest.csv"
OUT = ROOT / "outputs" / "hq_manual_matching" / "HQ_Vinted_Ledger_Matching.xlsx"

def esc(value): return html.escape(str(value or ""), quote=False)
def col(number):
    result=""
    while number:
        number, remainder = divmod(number-1,26); result=chr(65+remainder)+result
    return result
def cell(reference, value, style=None):
    attrs=f' r="{reference}"' + (f' s="{style}"' if style else "")
    return f'<c{attrs} t="inlineStr"><is><t xml:space="preserve">{esc(value)}</t></is></c>'
def sheet_xml(headers, rows, widths=None, validation=None):
    body=[]
    for index, row in enumerate([headers]+rows,1):
        style=1 if index==1 else None
        body.append('<row r="%d">%s</row>'%(index,"".join(cell(f"{col(i)}{index}",value,style) for i,value in enumerate(row,1))))
    cols="" if not widths else "<cols>"+"".join(f'<col min="{i}" max="{i}" width="{width}" customWidth="1"/>' for i,width in enumerate(widths,1))+"</cols>"
    validation_xml="" if not validation else validation
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">{cols}<sheetData>{"".join(body)}</sheetData>{validation_xml}</worksheet>'
def main():
    with LEDGER.open(encoding="utf-8-sig",newline="") as handle: ledger=list(csv.DictReader(handle))
    with LIVE.open(encoding="utf-8-sig",newline="") as handle: live=list(csv.DictReader(handle))
    linked={str(row.get("Vinted_Item_ID") or "") for row in ledger if row.get("Vinted_Item_ID")}
    unlinked=[row for row in live if str(row.get("vinted_item_id")) not in linked]
    listed_candidates=[row for row in ledger if row.get("Status")=="LISTED-BACKLOG" and not row.get("Vinted_Item_ID")]
    all_candidates=[row for row in ledger if not row.get("Vinted_Item_ID")]
    match_headers=["Vinted_Item_ID","Live title","Brand","Size","Price PLN","Views","Likes","Vinted URL","Photo URL","Matched_Item_ID","Match state","Matching note"]
    match_rows=[[r.get("vinted_item_id"),r.get("title"),r.get("brand"),r.get("size"),r.get("price_pln"),r.get("views"),r.get("favourites"),r.get("url"),r.get("photo_url"),"","","" ] for r in unlinked]
    candidate_headers=["Item_ID","Name_Zakupy","Tier","Total_Capital","Purchase date","Listing date","Live title","Listing URL"]
    candidate_rows=[[r.get("Item_ID"),r.get("Name_Zakupy"),r.get("Flip_Tier"),r.get("Total_Capital"),r.get("DATE_OF_PURCHASE"),r.get("DATE_OF_LISTING"),r.get("Live_Title"),r.get("Listing_URL")] for r in listed_candidates]
    all_rows=[[r.get("Item_ID"),r.get("Name_Zakupy"),r.get("Status"),r.get("Flip_Tier"),r.get("Total_Capital"),r.get("DATE_OF_PURCHASE"),r.get("DATE_OF_LISTING"),r.get("Live_Title"),r.get("Listing_URL")] for r in all_candidates]
    readme=[["HQ manual matching", ""],["Purpose", "Match each currently live Vinted listing with exactly one Ledger Item_ID."],["How", "In MATCH_LIVE choose Matched_Item_ID from the dropdown when certain; set Match state to MATCHED, NO_LEDGER or REVIEW; add a note if needed."],["Safety", "Do not alter Vinted_Item_ID, title, prices or source tabs. This workbook does not change Vinted or Google Sheet."],["After matching", "Save this workbook unchanged and give it back to Codex. A validation report will run before any approved Ledger update."],["Generated", datetime.now().strftime("%Y-%m-%d %H:%M")],["Live listings awaiting mapping",len(unlinked)],["Listed Ledger candidates without Vinted ID",len(listed_candidates)],["All Ledger records without Vinted ID",len(all_candidates)]]
    validation=(f'<dataValidations count="2"><dataValidation type="list" allowBlank="1" sqref="J2:J{len(unlinked)+1}"><formula1>\'LEDGER_CANDIDATES\'!$A$2:$A${len(listed_candidates)+1}</formula1></dataValidation><dataValidation type="list" allowBlank="1" sqref="K2:K{len(unlinked)+1}"><formula1>"MATCHED,NO_LEDGER,REVIEW"</formula1></dataValidation></dataValidations>')
    sheets=[sheet_xml(["Field","Value"],readme,[28,110]),sheet_xml(match_headers,match_rows,[16,55,18,12,12,10,10,58,72,18,16,40],validation),sheet_xml(candidate_headers,candidate_rows,[16,52,16,16,16,16,55,58]),sheet_xml(["Item_ID","Name_Zakupy","Status","Tier","Total_Capital","Purchase date","Listing date","Live title","Listing URL"],all_rows,[16,52,20,16,16,16,16,55,58])]
    names=["README","MATCH_LIVE","LEDGER_CANDIDATES","LEDGER_NO_VINTED_ID"]
    OUT.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(OUT,"w",zipfile.ZIP_DEFLATED) as book:
        book.writestr("[Content_Types].xml",'<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,5))+"</Types>")
        book.writestr("_rels/.rels",'<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        book.writestr("xl/workbook.xml",'<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'+''.join(f'<sheet name="{name}" sheetId="{i}" r:id="rId{i}"/>' for i,name in enumerate(names,1))+"</sheets></workbook>")
        book.writestr("xl/_rels/workbook.xml.rels",'<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,5))+'<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
        book.writestr("xl/styles.xml",'<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF3B3327"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border/></borders><cellXfs count="2"><xf fontId="0" fillId="0" borderId="0"/><xf fontId="1" fillId="1" borderId="0" applyFont="1" applyFill="1"/></cellXfs></styleSheet>')
        for index,xml in enumerate(sheets,1): book.writestr(f"xl/worksheets/sheet{index}.xml",xml)
    print(f"Created {OUT} with {len(unlinked)} live listings and {len(listed_candidates)} listed Ledger candidates.")
if __name__=="__main__": main()
