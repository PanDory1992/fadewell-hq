import os
import time
from datetime import datetime, timezone

MAX_AGE_MINUTES = 12


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def is_stale(last_success_at, now=None, max_age_minutes=MAX_AGE_MINUTES):
    observed = parse_time(last_success_at)
    if observed is None:
        return True
    current = now or datetime.now(timezone.utc)
    return (current - observed).total_seconds() > max_age_minutes * 60


def main():
    import requests

    base = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    headers = {"apikey": key, "authorization": f"Bearer {key}"}
    state_url = f"{base}/rest/v1/hq_email_sync_state?provider=eq.gmail&select=last_success_at,last_error"
    response = requests.get(state_url, headers=headers, timeout=20)
    response.raise_for_status()
    rows = response.json()
    before = rows[0].get("last_success_at") if rows else None
    if not is_stale(before):
        print(f"Gmail sync is fresh: {before}")
        return

    sync_url = f"{base}/functions/v1/hq-gmail-sync"
    last_error = None
    for attempt in range(1, 4):
        try:
            run = requests.post(sync_url, headers=headers, json={"source": "GITHUB_WATCHDOG"}, timeout=90)
            if run.status_code not in (200, 202):
                raise RuntimeError(f"HTTP {run.status_code}: {run.text[:500]}")
            time.sleep(3)
            check = requests.get(state_url, headers=headers, timeout=20)
            check.raise_for_status()
            current_rows = check.json()
            after = current_rows[0].get("last_success_at") if current_rows else None
            if after and after != before and not is_stale(after):
                print(f"Gmail watchdog recovered the sync: {after}")
                return
            last_error = f"sync returned {run.status_code}, but freshness did not advance"
        except Exception as error:
            last_error = str(error)
        if attempt < 3:
            time.sleep(attempt * 15)
    raise RuntimeError(f"Gmail remained stale after three recovery attempts: {last_error}")


if __name__ == "__main__":
    main()
