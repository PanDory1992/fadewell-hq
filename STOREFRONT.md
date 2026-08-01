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

## Archive start

There is no historical backfill. The Pair Archive starts with the storefront
launch: the first sync records only listings available at launch, and a record
moves into the archive only after HQ confirms that pair as sold later. This is
intentional; old sold listings are not reconstructed from incomplete evidence.

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
