# Ledger migration to FADEWELL HQ

Status: **CUTOVER COMPLETE for operational DEN Ledger.**

## Final authority

Supabase-backed FADEWELL HQ is the canonical transactional Ledger for DEN.
The local workspace is code and automation. Google Sheet is read-only legacy
history and REC only.

## What is preserved in the first import

Every current Sheet row is copied to `hq_ledger_items`, including costs, sale
values, profit, statuses, dates, Vinted IDs/URLs, live fields and estimate
audit fields. `source_row` keeps the exact imported record for audit.

No historical journal events are invented. The existing Sheet has incomplete
dates, so the future `hq_ledger_events` journal starts empty and is populated
only from supported facts after cutover.

Migration 004 replaces mutable staging with an immutable import snapshot per
run and an atomic database RPC. The earlier 003 staging copy is retained only
as legacy evidence; do not use it for a new import.

## Cutover gates

1. Fresh Sheet read succeeds and importer validation has zero errors.
2. Row count, unique Item_IDs, Vinted IDs, status counts and total capital
   match the source snapshot.
3. A human reviews all unresolved identity links and migration exceptions.
4. HQ can create/edit an item, purchase, listing, sale and correction with an
   immutable audit entry.
5. Backup exports are created, then Miki explicitly approves cutover.

The verified cutover import is `f494f6b3-05f8-41e2-8cc0-8506752e3710`. New HQ
actions must never write back to Google Sheet by default.
