-- Independent watchdog dispatch gate for the Vinted collector fallback.
alter table public.hq_collector_control
  add column if not exists last_watchdog_dispatch_at timestamptz,
  add column if not exists last_watchdog_dispatch_error text;

create or replace function public.claim_hq_vinted_watchdog_dispatch(
  p_stale_after_minutes integer default 35,
  p_cooldown_minutes integer default 10
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  control public.hq_collector_control%rowtype;
begin
  if p_stale_after_minutes < 1 or p_stale_after_minutes > 1440 then
    raise exception 'Invalid stale threshold';
  end if;
  if p_cooldown_minutes < 1 or p_cooldown_minutes > 1440 then
    raise exception 'Invalid dispatch cooldown';
  end if;

  insert into public.hq_collector_control (collector_key)
  values ('vinted_live') on conflict (collector_key) do nothing;

  select * into control from public.hq_collector_control
  where collector_key = 'vinted_live' for update;

  if control.last_complete_captured_at is not null
     and control.last_complete_captured_at >= now() - make_interval(mins => p_stale_after_minutes) then
    return jsonb_build_object(
      'accepted', false,
      'reason', 'fresh',
      'last_complete_captured_at', control.last_complete_captured_at
    );
  end if;

  if control.lease_run_id is not null and control.lease_until > now() then
    return jsonb_build_object(
      'accepted', false,
      'reason', 'locked',
      'lease_source', control.lease_source,
      'lease_until', control.lease_until
    );
  end if;

  if control.last_watchdog_dispatch_at is not null
     and control.last_watchdog_dispatch_at >= now() - make_interval(mins => p_cooldown_minutes) then
    return jsonb_build_object(
      'accepted', false,
      'reason', 'cooldown',
      'last_watchdog_dispatch_at', control.last_watchdog_dispatch_at
    );
  end if;

  update public.hq_collector_control set
    last_watchdog_dispatch_at = now(),
    last_watchdog_dispatch_error = null,
    updated_at = now()
  where collector_key = 'vinted_live';

  return jsonb_build_object(
    'accepted', true,
    'reason', 'stale',
    'last_complete_captured_at', control.last_complete_captured_at,
    'dispatched_at', now()
  );
end;
$$;

create or replace function public.record_hq_vinted_watchdog_dispatch_error(
  p_error text
) returns void
language sql
security definer
set search_path = public
as $$
  update public.hq_collector_control set
    last_watchdog_dispatch_error = left(coalesce(p_error,'Unknown watchdog dispatch failure'),2000),
    consecutive_failures = consecutive_failures + 1,
    incident_open = (consecutive_failures + 1 >= 3),
    incident_opened_at = case
      when consecutive_failures + 1 >= 3 then coalesce(incident_opened_at,now())
      else incident_opened_at
    end,
    last_error = left(coalesce(p_error,'Unknown watchdog dispatch failure'),2000),
    updated_at = now()
  where collector_key = 'vinted_live';
$$;

revoke all on function public.claim_hq_vinted_watchdog_dispatch(integer,integer) from public,anon,authenticated;
revoke all on function public.record_hq_vinted_watchdog_dispatch_error(text) from public,anon,authenticated;
grant execute on function public.claim_hq_vinted_watchdog_dispatch(integer,integer) to service_role;
grant execute on function public.record_hq_vinted_watchdog_dispatch_error(text) to service_role;
