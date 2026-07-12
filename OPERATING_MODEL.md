# FADEWELL HQ operating model

Status: **canonical DEN Ledger cut over on 2026-07-12**.

## Final shape

| Layer | Final responsibility | May it change Vinted? |
|---|---|---|
| Vinted collector | Observes public listings, price, views, likes and external photo URLs | No |
| HQ database | Canonical inventory, accounting, operations, audit and decisions | No |
| HQ UI | The working surface for Miki and AI | Only with a later explicit action boundary |
| Offline workspace | Code, schedulers, source snapshots, tests, backups and AI documentation | No |

Google Sheet is a temporary import source. It is not part of the final shape.

## Data ownership

1. `hq_ledger_items` is canonical DEN inventory and accounting, promoted from
   verified import `f494f6b3-05f8-41e2-8cc0-8506752e3710`.
2. Google Sheet is legacy history and REC only; it cannot overwrite HQ.
3. `hq_ledger_import_runs` and `hq_ledger_import_items` remain immutable
   evidence of the cutover source.
4. Vinted pulls produce observations. A missing public listing creates a
   review candidate only; it never books a sale.
5. Operational decisions will be append-only `hq_operational_actions`, kept
   separate from generated observations so an automated sync cannot erase a
   human decision.

## Current automated loop

Every scheduled run executes, in this order:

1. Pull the public Vinted wardrobe.
2. Refresh local HQ observations from canonical HQ Ledger and review candidates.
4. Mirror operational read models to Supabase.
5. Write a health report and read-only linking suggestions.

The loop does **not** write Google Sheet, change Vinted, link listings
automatically, classify a missing listing as sold, or replace canonical Ledger
data.

## Build sequence remaining

1. Add owner-only database access and canonical action write paths.
2. Build the canonical HQ Ledger UI: item, purchase, listing, sale,
   correction and immutable event history.
3. Add HQ-native backups and exports.
4. Add authenticated, read-only Vinted-order research as a bounded separate
   integration; never assume public wardrobe data can prove purchases/sales.
