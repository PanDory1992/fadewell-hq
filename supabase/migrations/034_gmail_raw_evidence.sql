-- KROK 2: immutable, privacy-redacted Gmail evidence and versioned parse runs.
-- This is evidence intake only. It never changes a DEN or a ledger event.

create table if not exists public.hq_gmail_messages (
  gmail_message_id text primary key,
  gmail_thread_id text not null,
  vinted_transaction_id text,
  sender text not null,
  subject text not null,
  received_at timestamptz not null,
  normalized_body text not null,
  normalized_body_sha256 text not null,
  redaction_version text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.hq_gmail_parse_runs (
  id bigint generated always as identity primary key,
  gmail_message_id text not null references public.hq_gmail_messages(gmail_message_id),
  parser_version text not null,
  event_type text not null,
  extracted_fields jsonb not null,
  created_at timestamptz not null default now(),
  unique (gmail_message_id, parser_version)
);

alter table public.hq_gmail_messages enable row level security;
alter table public.hq_gmail_parse_runs enable row level security;

drop policy if exists "hq owner gmail evidence access" on public.hq_gmail_messages;
create policy "hq owner gmail evidence access" on public.hq_gmail_messages
for select to authenticated using (public.is_hq_owner());

drop policy if exists "hq owner gmail parse run access" on public.hq_gmail_parse_runs;
create policy "hq owner gmail parse run access" on public.hq_gmail_parse_runs
for select to authenticated using (public.is_hq_owner());

create index if not exists hq_gmail_messages_transaction_index
on public.hq_gmail_messages(vinted_transaction_id)
where vinted_transaction_id is not null;

create index if not exists hq_gmail_parse_runs_event_index
on public.hq_gmail_parse_runs(event_type, created_at desc);

create or replace function public.record_hq_gmail_evidence(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  message_id text := nullif(p->>'gmail_message_id','');
  parser text := nullif(p->>'parser_version','');
  inserted_message boolean := false;
  inserted_run boolean := false;
begin
  if message_id is null or parser is null then
    raise exception 'gmail_message_id and parser_version are required';
  end if;
  if nullif(p->>'gmail_thread_id','') is null
     or nullif(p->>'sender','') is null
     or nullif(p->>'subject','') is null
     or nullif(p->>'received_at','') is null
     or nullif(p->>'normalized_body','') is null
     or nullif(p->>'normalized_body_sha256','') is null
     or nullif(p->>'redaction_version','') is null
     or nullif(p->>'event_type','') is null
     or p->'extracted_fields' is null then
    raise exception 'Gmail evidence is incomplete';
  end if;

  insert into public.hq_gmail_messages(
    gmail_message_id,gmail_thread_id,vinted_transaction_id,sender,subject,received_at,
    normalized_body,normalized_body_sha256,redaction_version
  ) values (
    message_id,p->>'gmail_thread_id',nullif(p->>'vinted_transaction_id',''),p->>'sender',
    p->>'subject',(p->>'received_at')::timestamptz,p->>'normalized_body',
    p->>'normalized_body_sha256',p->>'redaction_version'
  ) on conflict (gmail_message_id) do nothing;
  inserted_message := found;

  insert into public.hq_gmail_parse_runs(gmail_message_id,parser_version,event_type,extracted_fields)
  values(message_id,parser,p->>'event_type',p->'extracted_fields')
  on conflict (gmail_message_id,parser_version) do nothing;
  inserted_run := found;

  return jsonb_build_object(
    'gmail_message_id',message_id,
    'message_recorded',inserted_message,
    'parse_run_recorded',inserted_run
  );
end $$;

revoke all on table public.hq_gmail_messages, public.hq_gmail_parse_runs from public;
revoke all on function public.record_hq_gmail_evidence(jsonb) from public;
grant select on table public.hq_gmail_messages, public.hq_gmail_parse_runs to authenticated;
grant execute on function public.record_hq_gmail_evidence(jsonb) to service_role;
