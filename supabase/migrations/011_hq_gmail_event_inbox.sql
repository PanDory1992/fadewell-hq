-- Private, append-only intake for Gmail-confirmed Vinted events.
-- No mailbox body or buyer PII is required in HQ.

create table if not exists public.hq_email_connections (
  provider text primary key check (provider = 'gmail'),
  email text not null,
  refresh_token text not null,
  scopes text[] not null default '{}',
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.hq_external_events (
  id bigint generated always as identity primary key,
  source text not null check (source in ('GMAIL_VINTED', 'VINTED_LIVE')),
  source_event_id text not null,
  vinted_transaction_id text,
  event_type text not null check (event_type in ('PURCHASE_CONFIRMED','SALE_PENDING','SALE_CONFIRMED','CANCELLATION','RETURN','DELIVERY_PENDING','UNCLASSIFIED')),
  state text not null default 'RECEIVED' check (state in ('RECEIVED','AUTO_APPLIED','NEEDS_REVIEW','IGNORED','FAILED')),
  occurred_at timestamptz,
  item_title text,
  amount numeric(12,2),
  matched_item_id text references public.hq_ledger_items(item_id),
  ledger_event_id bigint references public.hq_ledger_events(id),
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(source, source_event_id)
);
alter table public.hq_email_connections enable row level security;
alter table public.hq_external_events enable row level security;
drop policy if exists "hq owner external event access" on public.hq_external_events;
create policy "hq owner external event access" on public.hq_external_events
for select to authenticated
using (public.is_hq_owner());
create index if not exists hq_external_events_state_index
on public.hq_external_events(state, occurred_at desc);
create index if not exists hq_external_events_transaction_index
on public.hq_external_events(vinted_transaction_id)
where vinted_transaction_id is not null;
