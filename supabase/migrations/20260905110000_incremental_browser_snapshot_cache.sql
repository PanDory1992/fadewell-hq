-- The browser only needs the two newest complete collector cycles to render
-- current live listings and missing-listing checks.  A time-leading partial
-- index keeps that read bounded as snapshot history grows.
create index if not exists hq_listing_snapshots_cloud_captured_at_index
  on public.hq_listing_snapshots (captured_at desc)
  where source in ('github_actions_vinted', 'supabase_edge_vinted');

create index if not exists hq_listing_snapshots_captured_at_index
  on public.hq_listing_snapshots (captured_at desc);

create or replace function public.hq_browser_listing_cycles()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cloud_cycles as (
    select distinct captured_at
    from public.hq_listing_snapshots
    where source in ('github_actions_vinted', 'supabase_edge_vinted')
    order by captured_at desc
    limit 2
  ), fallback_cycles as (
    select distinct captured_at
    from public.hq_listing_snapshots
    where not exists (select 1 from cloud_cycles)
    order by captured_at desc
    limit 2
  ), cycles as (
    select captured_at from cloud_cycles
    union all
    select captured_at from fallback_cycles
  ), rows as (
    select snapshot.*
    from public.hq_listing_snapshots snapshot
    where snapshot.captured_at in (select captured_at from cycles)
      and (
        not exists (select 1 from cloud_cycles)
        or snapshot.source in ('github_actions_vinted', 'supabase_edge_vinted')
      )
    order by snapshot.captured_at desc, snapshot.id desc
  )
  select case when public.is_hq_owner()
    then jsonb_build_object('snapshots', coalesce((select jsonb_agg(to_jsonb(rows)) from rows), '[]'::jsonb))
    else null
  end;
$$;

revoke all on function public.hq_browser_listing_cycles() from public, anon;
grant execute on function public.hq_browser_listing_cycles() to authenticated;
