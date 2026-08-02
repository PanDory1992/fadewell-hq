-- Anonymous, first-party storefront measurement. Events are aggregated at
-- write time: no visitor, device, cookie, IP, user-agent or session identifier
-- is accepted or retained, and raw click rows do not accumulate.
create table if not exists public.fadewell_storefront_event_counts (
  id bigint generated always as identity primary key,
  event_date date not null default current_date,
  event_type text not null check (event_type in (
    'page_view', 'pair_card_click', 'pair_view', 'vinted_click', 'finder_submit'
  )),
  source_page text not null check (source_page in (
    'home', 'shop', 'finder', 'archive', 'pair'
  )),
  vinted_item_id text references public.fadewell_storefront_products(vinted_item_id)
    on update cascade on delete set null,
  event_count bigint not null default 1 check (event_count > 0),
  last_event_at timestamptz not null default now()
);

create unique index if not exists fadewell_storefront_event_counts_key
on public.fadewell_storefront_event_counts (
  event_date, event_type, source_page, (coalesce(vinted_item_id, ''))
);

create index if not exists fadewell_storefront_event_counts_date_idx
on public.fadewell_storefront_event_counts (event_date desc);

alter table public.fadewell_storefront_event_counts enable row level security;

drop policy if exists "hq owner reads storefront event counts"
on public.fadewell_storefront_event_counts;
create policy "hq owner reads storefront event counts"
on public.fadewell_storefront_event_counts
for select to authenticated
using (public.is_hq_owner());

revoke all on public.fadewell_storefront_event_counts from public, anon, authenticated;
grant select on public.fadewell_storefront_event_counts to authenticated;

create or replace function public.track_fadewell_storefront_event(
  p_event_type text,
  p_source_page text,
  p_vinted_item_id text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  clean_item_id text := nullif(btrim(p_vinted_item_id), '');
begin
  if p_event_type not in ('page_view', 'pair_card_click', 'pair_view', 'vinted_click', 'finder_submit') then
    raise exception 'Unsupported storefront event';
  end if;
  if p_source_page not in ('home', 'shop', 'finder', 'archive', 'pair') then
    raise exception 'Unsupported storefront page';
  end if;
  if clean_item_id is not null
     and not exists (
       select 1 from public.fadewell_storefront_products
       where vinted_item_id = clean_item_id and published
     ) then
    raise exception 'Unknown storefront pair';
  end if;
  if coalesce((
    select sum(event_count) from public.fadewell_storefront_event_counts
    where event_date = current_date
  ), 0) >= 5000 then
    raise exception 'Daily storefront event limit reached';
  end if;

  insert into public.fadewell_storefront_event_counts (
    event_date, event_type, source_page, vinted_item_id, event_count, last_event_at
  ) values (
    current_date, p_event_type, p_source_page, clean_item_id, 1, now()
  )
  on conflict (event_date, event_type, source_page, (coalesce(vinted_item_id, '')))
  do update set
    event_count = public.fadewell_storefront_event_counts.event_count + 1,
    last_event_at = now();

  -- Retain two years of compact daily aggregates. This runs against a small,
  -- date-indexed table and keeps free-plan usage permanently bounded.
  delete from public.fadewell_storefront_event_counts
  where event_date < current_date - 730;
end;
$$;

revoke all on function public.track_fadewell_storefront_event(text, text, text)
from public, anon, authenticated;
grant execute on function public.track_fadewell_storefront_event(text, text, text)
to anon, authenticated;

create or replace view public.fadewell_storefront_funnel_daily
with (security_invoker = true)
as
select
  event_date,
  source_page,
  event_type,
  sum(event_count)::bigint as events
from public.fadewell_storefront_event_counts
group by event_date, source_page, event_type;

revoke all on public.fadewell_storefront_funnel_daily from public, anon, authenticated;
grant select on public.fadewell_storefront_funnel_daily to authenticated;

comment on table public.fadewell_storefront_event_counts is
'Anonymous daily storefront funnel counts. Raw events and visitor identifiers are never stored.';
