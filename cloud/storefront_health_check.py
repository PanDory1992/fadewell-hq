"""Fail only when the last usable Storefront projection is genuinely stale."""
from __future__ import annotations

import argparse
import os
from datetime import datetime, timezone

import requests


def latest_projection_age_minutes(supabase_url, service_key):
    response = requests.get(
        f"{supabase_url.rstrip('/')}/rest/v1/hq_storefront_sync_health",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
        params={"select": "last_success_at,consecutive_failures", "singleton": "eq.true", "limit": "1"},
        timeout=60,
    )
    response.raise_for_status()
    rows = response.json()
    if not rows or not rows[0].get("last_success_at"):
        raise RuntimeError("Storefront sync has no successful freshness marker")
    observed = datetime.fromisoformat(str(rows[0]["last_success_at"]).replace("Z", "+00:00"))
    age = (datetime.now(timezone.utc) - observed).total_seconds() / 60
    return age, int(rows[0].get("consecutive_failures") or 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-age-minutes", type=float, default=75)
    args = parser.parse_args()
    age, failures = latest_projection_age_minutes(
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"],
    )
    if age > args.max_age_minutes:
        raise RuntimeError(
            f"Storefront projection is {age:.0f} minutes old after {failures} failed refresh cycle(s); human attention is required"
        )
    print(
        f"::warning title=Transient Storefront refresh failure::"
        f"The last complete public projection is {age:.0f} minutes old after {failures} failed cycle(s) and remains safe. "
        "A later scheduled run will retry automatically."
    )


if __name__ == "__main__":
    main()
