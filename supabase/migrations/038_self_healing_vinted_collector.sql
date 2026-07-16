-- Shared lease, health state and run audit for every Vinted collector path.
create table if not exists public.hq_collector_control (
  collector_key text primary key,
  lease_run_id uuid,
  lease_source text,
  lease_until timestamptz,
  last_started_at timestamptz,
  last_success_at timestamptz,
  last_complete_captured_at timestamptz,
  last_success_source text,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  incident_open boolean not null default false,
  incident_opened_at timestamptz,
  last_error text,
  updated_at timestamptz not null default now()
);

create table if not exists public.hq_collector_runs (
  run_id uuid primary key default gen_random_uuid(),
  collector_key text not null references public.hq_collector_control(collector_key),
  source text not null,
  status text not null check (status in ('STARTED','SUCCESS','FAILED')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  captured_at timestamptz,
  item_count integer,
  error text,
  detail jsonb not null default '{}'::jsonb
);

create index if not exists hq_collector_runs_recent_idx
  on public.hq_collector_runs (collector_key, started_at desc);

alter table public.hq_collector_control enable row level security;
alter table public.hq_collector_runs enable row level security;

drop policy if exists "hq owner collector control access" on public.hq_collector_control;
create policy "hq owner collector control access" on public.hq_collector_control
for select to authenticated using (public.is_hq_owner());

drop policy if exists "hq owner collector run access" on public.hq_collector_runs;
create policy "hq owner collector run access" on public.hq_collector_runs
for select to authenticated using (public.is_hq_owner());

insert into public.hq_collector_control (
  collector_key,last_success_at,last_complete_captured_at,last_success_source
)
select
  'vinted_live', max(captured_at), max(captured_at),
  (array_agg(source order by captured_at desc))[1]
from public.hq_listing_snapshots
where source in ('github_actions_vinted','supabase_edge_vinted')
on conflict (collector_key) do nothing;

create or replace function public.begin_hq_collector_run(
  p_source text,
  p_stale_after_minutes integer default 0,
  p_force boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  control public.hq_collector_control%rowtype;
  new_run_id uuid := gen_random_uuid();
  failure_count integer;
  opened_at timestamptz;
begin
  if coalesce(btrim(p_source),'') = '' then raise exception 'Collector source is required'; end if;
  if p_stale_after_minutes < 0 or p_stale_after_minutes > 1440 then raise exception 'Invalid stale threshold'; end if;

  insert into public.hq_collector_control (collector_key)
  values ('vinted_live') on conflict (collector_key) do nothing;

  select * into control from public.hq_collector_control
  where collector_key = 'vinted_live' for update;

  -- A dead worker cannot retain the lease forever. Convert its expired lease
  -- into a real failed run before allowing the next recovery attempt.
  if control.lease_run_id is not null and control.lease_until <= now() then
    update public.hq_collector_runs
      set status='FAILED', completed_at=now(), error='Collector lease expired before completion.'
      where run_id=control.lease_run_id and status='STARTED';
    failure_count := control.consecutive_failures + 1;
    opened_at := case when failure_count >= 3 then coalesce(control.incident_opened_at,now()) else control.incident_opened_at end;
    update public.hq_collector_control set
      consecutive_failures=failure_count,
      incident_open=(failure_count >= 3),
      incident_opened_at=opened_at,
      last_error='Collector lease expired before completion.',
      lease_run_id=null, lease_source=null, lease_until=null, updated_at=now()
    where collector_key='vinted_live';
    select * into control from public.hq_collector_control where collector_key='vinted_live';
  end if;

  if not p_force and p_stale_after_minutes > 0
     and control.last_complete_captured_at >= now() - make_interval(mins => p_stale_after_minutes) then
    return jsonb_build_object('accepted',false,'reason','fresh','last_complete_captured_at',control.last_complete_captured_at);
  end if;

  if control.lease_run_id is not null and control.lease_until > now() then
    return jsonb_build_object('accepted',false,'reason','locked','lease_source',control.lease_source,'lease_until',control.lease_until);
  end if;

  insert into public.hq_collector_runs(run_id,collector_key,source,status)
  values(new_run_id,'vinted_live',p_source,'STARTED');
  update public.hq_collector_control set
    lease_run_id=new_run_id, lease_source=p_source,
    lease_until=now()+interval '12 minutes', last_started_at=now(), updated_at=now()
  where collector_key='vinted_live';
  return jsonb_build_object('accepted',true,'run_id',new_run_id,'lease_until',now()+interval '12 minutes');
end;
$$;

create or replace function public.finish_hq_collector_run(
  p_run_id uuid,
  p_success boolean,
  p_captured_at timestamptz default null,
  p_item_count integer default null,
  p_error text default null,
  p_detail jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  control public.hq_collector_control%rowtype;
  run public.hq_collector_runs%rowtype;
  failure_count integer;
  opened_at timestamptz;
begin
  select * into run from public.hq_collector_runs where run_id=p_run_id for update;
  if run.run_id is null then raise exception 'Unknown collector run'; end if;
  if run.status <> 'STARTED' then return jsonb_build_object('finished',false,'reason','already_finished','status',run.status); end if;
  select * into control from public.hq_collector_control where collector_key=run.collector_key for update;

  update public.hq_collector_runs set
    status=case when p_success then 'SUCCESS' else 'FAILED' end,
    completed_at=now(), captured_at=p_captured_at, item_count=p_item_count,
    error=case when p_success then null else left(coalesce(p_error,'Unknown collector failure'),2000) end,
    detail=coalesce(p_detail,'{}'::jsonb)
  where run_id=p_run_id;

  if p_success then
    update public.hq_collector_control set
      last_success_at=now(),
      last_complete_captured_at=coalesce(p_captured_at,last_complete_captured_at),
      last_success_source=run.source,
      consecutive_failures=0, incident_open=false, incident_opened_at=null,
      last_error=null,
      lease_run_id=case when lease_run_id=p_run_id then null else lease_run_id end,
      lease_source=case when lease_run_id=p_run_id then null else lease_source end,
      lease_until=case when lease_run_id=p_run_id then null else lease_until end,
      updated_at=now()
    where collector_key=run.collector_key;
  else
    failure_count := control.consecutive_failures + 1;
    opened_at := case when failure_count >= 3 then coalesce(control.incident_opened_at,now()) else control.incident_opened_at end;
    update public.hq_collector_control set
      consecutive_failures=failure_count,
      incident_open=(failure_count >= 3), incident_opened_at=opened_at,
      last_error=left(coalesce(p_error,'Unknown collector failure'),2000),
      lease_run_id=case when lease_run_id=p_run_id then null else lease_run_id end,
      lease_source=case when lease_run_id=p_run_id then null else lease_source end,
      lease_until=case when lease_run_id=p_run_id then null else lease_until end,
      updated_at=now()
    where collector_key=run.collector_key;
  end if;
  return jsonb_build_object('finished',true,'success',p_success,'consecutive_failures',case when p_success then 0 else failure_count end);
end;
$$;

revoke all on function public.begin_hq_collector_run(text,integer,boolean) from public,anon,authenticated;
revoke all on function public.finish_hq_collector_run(uuid,boolean,timestamptz,integer,text,jsonb) from public,anon,authenticated;
grant execute on function public.begin_hq_collector_run(text,integer,boolean) to service_role;
grant execute on function public.finish_hq_collector_run(uuid,boolean,timestamptz,integer,text,jsonb) to service_role;
grant select on public.hq_collector_control,public.hq_collector_runs to authenticated;

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

select cron.unschedule(jobid) from cron.job where jobname='hq-vinted-primary-every-15-minutes';
select cron.schedule(
  'hq-vinted-primary-every-15-minutes',
  '*/15 * * * *',
  $$select net.http_post(
    url := 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-vinted-collector',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'x-collector-secret',(select decrypted_secret from vault.decrypted_secrets where name='vinted_collector_cron_secret' limit 1)
    ),
    body := '{"source":"SUPABASE_EDGE"}'::jsonb,
    timeout_milliseconds := 145000
  )$$
);

select cron.unschedule(jobid) from cron.job where jobname='hq-collector-run-retention-daily';
select cron.schedule(
  'hq-collector-run-retention-daily','23 3 * * *',
  $$delete from public.hq_collector_runs where started_at < now()-interval '30 days'$$
);
