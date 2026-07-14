"""One-off, audited recovery of missing Vinted titles for SOLD DEN items."""
from __future__ import annotations

import html, os, re, time

import cloudscraper
import requests

SUPABASE_URL=os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY=os.environ["SUPABASE_SERVICE_ROLE_KEY"]
HEADERS={"apikey":SERVICE_KEY,"Authorization":f"Bearer {SERVICE_KEY}","Content-Type":"application/json"}
VINTED_HEADERS={"User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36","Accept":"text/html,application/xhtml+xml","Accept-Language":"pl-PL,pl;q=0.9,en;q=0.7"}

def title_from_html(page):
    for pattern in (r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)',r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:title["\']',r'<title[^>]*>\s*(.*?)\s*</title>'):
        match=re.search(pattern,page,re.I|re.S)
        if match:
            title=html.unescape(re.sub(r'\s+',' ',match.group(1))).strip()
            title=re.sub(r'\s*[|–-]\s*Vinted\s*$','',title,flags=re.I).strip()
            if title and title.lower() not in {'vinted','not found','page not found'}: return title
    return None

def candidates():
    response=requests.get(f"{SUPABASE_URL}/rest/v1/hq_ledger_items",headers=HEADERS,params={"select":"item_id,vinted_item_id","ledger_status":"eq.SOLD","vinted_item_id":"not.is.null","live_title":"is.null","limit":"1000"},timeout=60)
    response.raise_for_status()
    return response.json()

def apply(item,title):
    vinted_id=str(item["vinted_item_id"])
    payload={"p":{"item_id":item["item_id"],"vinted_item_id":vinted_id,"title":title,"external_key":f"vinted-title-backfill-{item['item_id']}-{vinted_id}"}}
    response=requests.post(f"{SUPABASE_URL}/rest/v1/rpc/backfill_hq_vinted_title",headers=HEADERS,json=payload,timeout=60)
    response.raise_for_status()
    return response.json()

def fetch_title(session,vinted_id):
    """Respect Vinted throttling; a 429 is a pause, never a reason to guess."""
    for attempt in range(4):
        response=session.get(f"https://www.vinted.pl/items/{vinted_id}",headers=VINTED_HEADERS,timeout=30)
        if response.status_code==429:
            wait=30*(attempt+1)
            print(f"Vinted rate limit for {vinted_id}; waiting {wait}s before retry.")
            time.sleep(wait)
            continue
        if response.status_code==404: return None
        response.raise_for_status()
        return title_from_html(response.text)
    return None

def main():
    session=cloudscraper.create_scraper(); rows=candidates(); updated=unavailable=0
    for index,item in enumerate(rows,1):
        vinted_id=str(item["vinted_item_id"])
        try:
            title=fetch_title(session,vinted_id)
            if not title: unavailable+=1; print(f"No trustworthy title for {item['item_id']} / {vinted_id}"); continue
            result=apply(item,title)
            if result.get("updated"): updated+=1; print(f"{item['item_id']} <- {title}")
        except requests.RequestException as error:
            unavailable+=1; print(f"Unavailable {item['item_id']} / {vinted_id}: {error}")
        if index<len(rows): time.sleep(2)
    print(f"Historical title backfill complete: candidates={len(rows)} updated={updated} unavailable={unavailable}")

if __name__=="__main__": main()
