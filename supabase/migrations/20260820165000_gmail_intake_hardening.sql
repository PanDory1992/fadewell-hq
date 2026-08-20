-- Make Gmail intake replay-safe, observable and capable of moving only the
-- explicitly classified Confirmation needed messages to Gmail Trash.

alter table public.hq_email_sync_state
  add column if not exists history_id text,
  add column if not exists can_modify boolean not null default false,
  add column if not exists last_warning text,
  add column if not exists last_trashed_count integer,
  add column if not exists trash_backfill_completed_at timestamptz;

alter table public.hq_email_sync_runs
  add column if not exists trashed_count integer not null default 0;

create or replace function public.record_hq_gmail_trash_result(
  p_message_id text,
  p_succeeded boolean,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(btrim(p_message_id), '') = '' then
    raise exception 'Gmail message id is required';
  end if;

  update public.hq_external_events
  set evidence = coalesce(evidence, '{}'::jsonb) || jsonb_build_object(
    'gmail_trash', jsonb_build_object(
      'succeeded', p_succeeded,
      'attempted_at', now(),
      'error', case when p_succeeded then null else left(coalesce(p_error, 'unknown error'), 500) end
    )
  )
  where source = 'GMAIL_VINTED' and source_event_id = p_message_id;
end;
$$;

revoke all on function public.record_hq_gmail_trash_result(text, boolean, text) from public, anon, authenticated;
grant execute on function public.record_hq_gmail_trash_result(text, boolean, text) to service_role;
