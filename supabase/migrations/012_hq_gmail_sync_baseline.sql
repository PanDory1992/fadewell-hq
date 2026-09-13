-- Start Gmail automation from this moment forward; historical mail is not replayed.
create table if not exists public.hq_email_sync_state (
  provider text primary key check (provider = 'gmail'),
  started_at timestamptz not null,
  updated_at timestamptz not null default now()
);
alter table public.hq_email_sync_state enable row level security;
insert into public.hq_email_sync_state(provider, started_at)
values ('gmail', now())
on conflict (provider) do nothing;
