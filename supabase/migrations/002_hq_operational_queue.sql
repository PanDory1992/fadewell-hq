-- FADEWELL HQ — stable keys for mirroring the local operational queue.
-- Run after 20260712_001_fadewell_hq.sql. It does not touch Vinted or Google Ledger.

alter table public.hq_review_queue
  add column if not exists external_key text;
alter table public.hq_capture_candidates
  add column if not exists external_key text;
create unique index if not exists hq_review_external_key_unique
  on public.hq_review_queue(external_key) where external_key is not null;
create unique index if not exists hq_capture_external_key_unique
  on public.hq_capture_candidates(external_key) where external_key is not null;
