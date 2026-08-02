# FADEWELL storefront operations

The public storefront is a separate projection of public Vinted facts. It is
not a view over the HQ ledger and never contains purchase cost, margin, Gmail
evidence, owner data, or other accounting fields.

## Data flow

1. `.github/workflows/storefront-sync.yml` runs hourly and can also be started
   manually.
2. `cloud/storefront_live_sync.py` reads the complete live wardrobe and Vinted
   detail records.
3. `cloud/storefront_sync.py` accepts only Vinted category evidence for the
   jeans/trousers scope, parses measurements deterministically, and writes the
   whitelisted `fadewell_storefront_products` table.
4. Supabase RLS exposes only rows with `published = true`. A row is publishable
   only with an allowed Vinted category, at least one photo, a description, and
   all baseline measurements: waist, rise, inseam, leg opening, overall length.
5. The website reads this table using the publishable key. All purchasing stays
   on Vinted.

The normal HQ Vinted collector is deliberately independent. A storefront
detail or gallery failure cannot interrupt ledger snapshots or reconciliation.

## Availability states

- A listing returned by the current Vinted wardrobe is `available`.
- A listing absent from the wardrobe becomes unavailable but is not called
  sold.
- Only a canonical `SOLD` state in `hq_ledger_items` marks the public record as
  sold and moves it into the Pair Archive.
- Published sold records are retained permanently.

## Pair-specific condition notes

The original Vinted description remains the evidence source. Storefront
rendering removes the seller-introduction formula, the duplicated measurement
block, and the closing sales clause, but it must retain all pair-specific
condition prose — including a line beginning with `Condition:`. If an archive
record was recovered without its original description, the Pair File states
that the notes were not recovered and points to the archived photographs; it
must not invent condition facts.

## Archive start

There is no historical backfill. The permanent archive floor is 2026-08-01.
Only HQ-confirmed sales on or after that date can be recovered or moved into
the Pair Archive. The workflow passes this date explicitly and the sync code
rejects any earlier cutoff. Old sold listings are not reconstructed from
incomplete evidence.

## Privacy-preserving storefront metrics

The public site sends only a finite event name, a finite page name and an
optional published Vinted item ID. Supabase aggregates those events directly
into daily counters. It stores no raw click rows, cookies, visitor/session IDs,
IP addresses, user agents or device identifiers. Retention is limited to two
years and daily ingestion is capped for the free plan.

The owner-only dashboard is `web/storefront.html`. On an owner/test device,
open any fadewell.eu page once with `?tracking=off` to persistently pause these
counters. Use `?tracking=on` to resume. Normal visitors receive no identifier.

## Verification

Before deployment:

```text
python -m unittest discover -s cloud -p 'test_*.py'
node scripts/check_mojibake.mjs web
git diff --check
```

After deployment, require a green `Sync FADEWELL Storefront` run, verify the
public REST response contains only the documented columns, and test Shop,
Finder, one available Pair File, one sold Pair File, and the Vinted hand-off on
the live domain.

## 30–90 day content operating cadence

- Weekly for the first month: check Search Console sitemap read date, indexed
  Pair File coverage and unexpected crawl exclusions. Do not manually submit
  every Pair URL.
- Monthly: record non-brand queries, impressions, CTR, indexed coverage,
  Pair-to-Vinted click-rate and Finder-to-Pair click-rate. Change prominent
  copy only when at least one full comparison window supports it.
- Every six months: review the measurement, sizing and silhouette guides for
  accuracy; refresh examples and links when the wardrobe vocabulary changes.
- Repurpose verified Pair DNA and archive evidence into Instagram detail posts
  and guide examples. A sold Pair remains a comparison and credibility asset,
  not a dead end.
- Potential backlinks must come from relevant vintage-denim resources,
  Warsaw/local profiles or genuinely useful guide citations. Draft outreach
  first; do not send external messages without owner approval.
