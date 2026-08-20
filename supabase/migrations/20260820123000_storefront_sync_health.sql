create table if not exists public.hq_storefront_sync_health (
  singleton boolean primary key default true check (singleton),
  last_attempt_at timestamptz not null default now(),
  last_success_at timestamptz not null default now(),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_catalog_count integer,
  last_detail_deferred integer,
  last_error text
);

insert into public.hq_storefront_sync_health(singleton)
values (true)
on conflict (singleton) do nothing;

alter table public.hq_storefront_sync_health enable row level security;

drop policy if exists "owner reads storefront sync health" on public.hq_storefront_sync_health;
create policy "owner reads storefront sync health"
on public.hq_storefront_sync_health
for select to authenticated
using (public.is_hq_owner());

revoke all on public.hq_storefront_sync_health from public, anon, authenticated;
grant select (
  singleton, last_attempt_at, last_success_at, consecutive_failures,
  last_catalog_count, last_detail_deferred, last_error
) on public.hq_storefront_sync_health to authenticated;
grant select on public.hq_storefront_sync_health to service_role;

create or replace function public.record_fadewell_storefront_sync(
  p_success boolean,
  p_catalog_count integer default null,
  p_detail_deferred integer default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.hq_storefront_sync_health as health(
    singleton, last_attempt_at, last_success_at, consecutive_failures,
    last_catalog_count, last_detail_deferred, last_error
  ) values (
    true, now(), case when p_success then now() else now() end,
    case when p_success then 0 else 1 end,
    p_catalog_count, p_detail_deferred,
    case when p_success then null else left(coalesce(p_error, 'unknown error'), 2000) end
  )
  on conflict (singleton) do update
  set last_attempt_at = now(),
      last_success_at = case when p_success then now() else health.last_success_at end,
      consecutive_failures = case when p_success then 0 else health.consecutive_failures + 1 end,
      last_catalog_count = coalesce(p_catalog_count, health.last_catalog_count),
      last_detail_deferred = coalesce(p_detail_deferred, health.last_detail_deferred),
      last_error = case when p_success then null else left(coalesce(p_error, 'unknown error'), 2000) end
  where health.singleton = excluded.singleton;
end;
$$;

revoke all on function public.record_fadewell_storefront_sync(boolean, integer, integer, text)
from public, anon, authenticated;
grant execute on function public.record_fadewell_storefront_sync(boolean, integer, integer, text)
to service_role;

comment on table public.hq_storefront_sync_health is
'Singleton success marker used to suppress transient GitHub noise while preserving a real stale-data alarm.';
