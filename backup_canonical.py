"""Create local timestamped backups of the canonical HQ Ledger; read-only."""
from __future__ import annotations
import hashlib
import json, os
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
HQ=Path(__file__).resolve().parent; OUT=HQ/"backups"
for line in (HQ/".env").read_text(encoding="utf-8").splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        key,value=line.split("=",1); os.environ.setdefault(key.strip(),value.strip())
url=os.environ["SUPABASE_URL"].rstrip("/"); key=os.environ["SUPABASE_SERVICE_ROLE_KEY"]
request=Request(f"{url}/rest/v1/hq_ledger_items?select=*&limit=1000",headers={"apikey":key,"Authorization":f"Bearer {key}"})
with urlopen(request,timeout=60) as response: rows=json.loads(response.read().decode())
OUT.mkdir(exist_ok=True)
stamp=datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%SZ")
payload={"created_at":datetime.now(timezone.utc).isoformat(),"source":"canonical_hq_ledger","row_count":len(rows),"rows":rows}
canonical=json.dumps(payload,ensure_ascii=False,sort_keys=True,separators=(",", ":")).encode("utf-8")
payload["sha256"]=hashlib.sha256(canonical).hexdigest()
target=OUT/f"canonical_ledger_{stamp}.json"
target.write_text(json.dumps(payload,ensure_ascii=False,indent=2),encoding="utf-8")
print(f"Backed up {len(rows)} canonical items -> {target}")
