-- A Vinted HTTP 403 from the Edge egress is a temporary path degradation,
-- not a reason to immediately repeat the same request. Keep the data plane
-- safe, use the independent executor once, then probe Edge next hour.
alter table public.hq_collector_control
  add column if not exists edge_degraded_until timestamptz,
  add column if not exists edge_degraded_reason text,
  add column if not exists last_vinted_403_at timestamptz,
  add column if not exists last_vinted_403_detail jsonb;

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
  select * into control from public.hq_collector_control where collector_key='vinted_live' for update;

  if control.lease_run_id is not null and control.lease_until <= now() then
    update public.hq_collector_runs set status='FAILED', completed_at=now(), error='Collector lease expired before completion.'
      where run_id=control.lease_run_id and status='STARTED';
    failure_count:=control.consecutive_failures+1;
    opened_at:=case when failure_count>=3 then coalesce(control.incident_opened_at,now()) else control.incident_opened_at end;
    update public.hq_collector_control set consecutive_failures=failure_count,incident_open=(failure_count>=3),incident_opened_at=opened_at,last_error='Collector lease expired before completion.',lease_run_id=null,lease_source=null,lease_until=null,updated_at=now() where collector_key='vinted_live';
    select * into control from public.hq_collector_control where collector_key='vinted_live';
  end if;

  if not p_force and p_source='SUPABASE_EDGE' and control.edge_degraded_until is not null and control.edge_degraded_until>now() then
    return jsonb_build_object('accepted',false,'reason','edge_degraded','edge_degraded_until',control.edge_degraded_until,'edge_degraded_reason',control.edge_degraded_reason);
  end if;
  if not p_force and p_stale_after_minutes>0 and control.last_complete_captured_at>=now()-make_interval(mins=>p_stale_after_minutes) then
    return jsonb_build_object('accepted',false,'reason','fresh','last_complete_captured_at',control.last_complete_captured_at);
  end if;
  if control.lease_run_id is not null and control.lease_until>now() then
    return jsonb_build_object('accepted',false,'reason','locked','lease_source',control.lease_source,'lease_until',control.lease_until);
  end if;

  insert into public.hq_collector_runs(run_id,collector_key,source,status) values(new_run_id,'vinted_live',p_source,'STARTED');
  update public.hq_collector_control set lease_run_id=new_run_id,lease_source=p_source,lease_until=now()+interval '12 minutes',last_started_at=now(),updated_at=now() where collector_key='vinted_live';
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
  is_edge_403 boolean;
  degraded_until timestamptz;
begin
  select * into run from public.hq_collector_runs where run_id=p_run_id for update;
  if run.run_id is null then raise exception 'Unknown collector run'; end if;
  if run.status<>'STARTED' then return jsonb_build_object('finished',false,'reason','already_finished','status',run.status); end if;
  select * into control from public.hq_collector_control where collector_key=run.collector_key for update;
  update public.hq_collector_runs set status=case when p_success then 'SUCCESS' else 'FAILED' end,completed_at=now(),captured_at=p_captured_at,item_count=p_item_count,error=case when p_success then null else left(coalesce(p_error,'Unknown collector failure'),2000) end,detail=coalesce(p_detail,'{}'::jsonb) where run_id=p_run_id;

  if p_success then
    update public.hq_collector_control set
      last_success_at=now(),last_complete_captured_at=coalesce(p_captured_at,last_complete_captured_at),last_success_source=run.source,
      consecutive_failures=0,incident_open=false,incident_opened_at=null,last_error=null,
      edge_degraded_until=case when run.source='SUPABASE_EDGE' then null else edge_degraded_until end,
      edge_degraded_reason=case when run.source='SUPABASE_EDGE' then null else edge_degraded_reason end,
      lease_run_id=case when lease_run_id=p_run_id then null else lease_run_id end,lease_source=case when lease_run_id=p_run_id then null else lease_source end,lease_until=case when lease_run_id=p_run_id then null else lease_until end,updated_at=now()
    where collector_key=run.collector_key;
    return jsonb_build_object('finished',true,'success',true,'consecutive_failures',0,'edge_degraded_until',null);
  end if;

  failure_count:=control.consecutive_failures+1;
  opened_at:=case when failure_count>=3 then coalesce(control.incident_opened_at,now()) else control.incident_opened_at end;
  is_edge_403:=run.source='SUPABASE_EDGE' and coalesce(p_error,'') ~ '^Vinted (home|catalog) HTTP 403';
  degraded_until:=date_trunc('hour',now())+interval '1 hour';
  update public.hq_collector_control set
    consecutive_failures=failure_count,incident_open=(failure_count>=3),incident_opened_at=opened_at,last_error=left(coalesce(p_error,'Unknown collector failure'),2000),
    edge_degraded_until=case when is_edge_403 then greatest(coalesce(edge_degraded_until,now()),degraded_until) else edge_degraded_until end,
    edge_degraded_reason=case when is_edge_403 then 'Vinted HTTP 403 from SUPABASE_EDGE' else edge_degraded_reason end,
    last_vinted_403_at=case when is_edge_403 then now() else last_vinted_403_at end,
    last_vinted_403_detail=case when is_edge_403 then coalesce(p_detail,'{}'::jsonb) else last_vinted_403_detail end,
    lease_run_id=case when lease_run_id=p_run_id then null else lease_run_id end,lease_source=case when lease_run_id=p_run_id then null else lease_source end,lease_until=case when lease_run_id=p_run_id then null else lease_until end,updated_at=now()
  where collector_key=run.collector_key;
  return jsonb_build_object('finished',true,'success',false,'consecutive_failures',failure_count,'edge_degraded_until',case when is_edge_403 then degraded_until else control.edge_degraded_until end);
end;
$$;

create or replace function public.claim_hq_vinted_watchdog_dispatch(
  p_stale_after_minutes integer default 70,
  p_cooldown_minutes integer default 55
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  control public.hq_collector_control%rowtype;
  is_degraded boolean;
begin
  if p_stale_after_minutes<1 or p_stale_after_minutes>1440 then raise exception 'Invalid stale threshold'; end if;
  if p_cooldown_minutes<1 or p_cooldown_minutes>1440 then raise exception 'Invalid dispatch cooldown'; end if;
  insert into public.hq_collector_control (collector_key) values ('vinted_live') on conflict (collector_key) do nothing;
  select * into control from public.hq_collector_control where collector_key='vinted_live' for update;
  is_degraded:=control.edge_degraded_until is not null and control.edge_degraded_until>now();
  if not is_degraded and control.last_complete_captured_at is not null and control.last_complete_captured_at>=now()-make_interval(mins=>p_stale_after_minutes) then
    return jsonb_build_object('accepted',false,'reason','fresh','last_complete_captured_at',control.last_complete_captured_at);
  end if;
  if control.lease_run_id is not null and control.lease_until>now() then
    return jsonb_build_object('accepted',false,'reason','locked','lease_source',control.lease_source,'lease_until',control.lease_until);
  end if;
  if control.last_watchdog_dispatch_at is not null and control.last_watchdog_dispatch_at>=now()-make_interval(mins=>p_cooldown_minutes) then
    return jsonb_build_object('accepted',false,'reason','cooldown','last_watchdog_dispatch_at',control.last_watchdog_dispatch_at);
  end if;
  update public.hq_collector_control set last_watchdog_dispatch_at=now(),last_watchdog_dispatch_error=null,updated_at=now() where collector_key='vinted_live';
  return jsonb_build_object('accepted',true,'reason',case when is_degraded then 'edge_degraded' else 'stale' end,'last_complete_captured_at',control.last_complete_captured_at,'dispatched_at',now());
end;
$$;

revoke all on function public.begin_hq_collector_run(text,integer,boolean) from public,anon,authenticated;
revoke all on function public.finish_hq_collector_run(uuid,boolean,timestamptz,integer,text,jsonb) from public,anon,authenticated;
revoke all on function public.claim_hq_vinted_watchdog_dispatch(integer,integer) from public,anon,authenticated;
grant execute on function public.begin_hq_collector_run(text,integer,boolean) to service_role;
grant execute on function public.finish_hq_collector_run(uuid,boolean,timestamptz,integer,text,jsonb) to service_role;
grant execute on function public.claim_hq_vinted_watchdog_dispatch(integer,integer) to service_role;

select cron.unschedule(jobid) from cron.job where jobname in ('hq-vinted-primary-every-15-minutes','hq-vinted-primary-hourly');
select cron.schedule(
  'hq-vinted-primary-hourly','7 * * * *',
  $$select net.http_post(
    url := 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-vinted-collector',
    headers := jsonb_build_object('Content-Type','application/json','x-collector-secret',(select decrypted_secret from vault.decrypted_secrets where name='vinted_collector_cron_secret' limit 1)),
    body := '{"source":"SUPABASE_EDGE"}'::jsonb,
    timeout_milliseconds := 145000
  )$$
);
