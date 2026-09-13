-- Keep detailed collection evidence for 90 days while preserving the latest
-- observation for every listing identity, regardless of age.
create or replace function public.prune_hq_listing_snapshots(p_keep_days integer default 90)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count bigint;
begin
  if p_keep_days <> 90 then
    raise exception 'Listing snapshot retention is fixed at 90 days';
  end if;

  with latest_per_listing as (
    select distinct on (vinted_item_id) id
    from public.hq_listing_snapshots
    order by vinted_item_id, captured_at desc, id desc
  ),
  removed as (
    delete from public.hq_listing_snapshots
    where captured_at < now() - interval '90 days'
      and id not in (select id from latest_per_listing)
    returning id
  )
  select count(*) into deleted_count from removed;

  return deleted_count;
end;
$$;
revoke all on function public.prune_hq_listing_snapshots(integer) from public, anon, authenticated;
grant execute on function public.prune_hq_listing_snapshots(integer) to service_role;
select cron.unschedule(jobid)
from cron.job
where jobname = 'hq-listing-snapshot-retention-daily';
select cron.schedule(
  'hq-listing-snapshot-retention-daily',
  '17 3 * * *',
  $$select public.prune_hq_listing_snapshots(90);$$
);
-- Apply the policy immediately as well as nightly. At rollout this is a
-- no-op when all rows are newer than 90 days.
select public.prune_hq_listing_snapshots(90);
