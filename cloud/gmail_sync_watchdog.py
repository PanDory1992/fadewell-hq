import os
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
    raise RuntimeError(
        "Apps Script Gmail intake is stale. Check the FADEWELL HQ Gmail Intake "
        "project execution history; the retired OAuth poller will not be restarted."
    )


if __name__ == "__main__":
    main()
