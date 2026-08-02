-- Phase 2 keeps the same privacy boundary: daily aggregate counters only.
-- The vocabulary is finite, so arbitrary client strings cannot create
-- unbounded rows on the Supabase free plan.
alter table public.fadewell_storefront_event_counts
  drop constraint if exists fadewell_storefront_event_counts_event_type_check;
alter table public.fadewell_storefront_event_counts
  add constraint fadewell_storefront_event_counts_event_type_check check (event_type in (
    'page_view', 'browse_shop', 'open_finder', 'finder_start', 'finder_submit',
    'finder_result_click', 'finder_empty', 'pair_card_click', 'pair_view',
    'vinted_click', 'currency_toggle', 'archive_view', 'engaged_view',
    'scroll_75', 'storefront_error'
  ));

alter table public.fadewell_storefront_event_counts
  drop constraint if exists fadewell_storefront_event_counts_source_page_check;
alter table public.fadewell_storefront_event_counts
  add constraint fadewell_storefront_event_counts_source_page_check check (source_page in (
    'home', 'shop', 'finder', 'archive', 'pair', 'guides'
  ));

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
  if p_event_type not in (
    'page_view', 'browse_shop', 'open_finder', 'finder_start', 'finder_submit',
    'finder_result_click', 'finder_empty', 'pair_card_click', 'pair_view',
    'vinted_click', 'currency_toggle', 'archive_view', 'engaged_view',
    'scroll_75', 'storefront_error'
  ) then raise exception 'Unsupported storefront event'; end if;
  if p_source_page not in ('home', 'shop', 'finder', 'archive', 'pair', 'guides') then
    raise exception 'Unsupported storefront page';
  end if;
  if clean_item_id is not null and not exists (
    select 1 from public.fadewell_storefront_products
    where vinted_item_id = clean_item_id and published
  ) then raise exception 'Unknown storefront pair'; end if;
  if coalesce((select sum(event_count) from public.fadewell_storefront_event_counts where event_date=current_date),0) >= 5000 then
    raise exception 'Daily storefront event limit reached';
  end if;

  insert into public.fadewell_storefront_event_counts
    (event_date,event_type,source_page,vinted_item_id,event_count,last_event_at)
  values (current_date,p_event_type,p_source_page,clean_item_id,1,now())
  on conflict (event_date,event_type,source_page,(coalesce(vinted_item_id,'')))
  do update set event_count=public.fadewell_storefront_event_counts.event_count+1,last_event_at=now();

  delete from public.fadewell_storefront_event_counts
  where event_date < current_date-730;
end;
$$;

revoke all on function public.track_fadewell_storefront_event(text,text,text)
from public, anon, authenticated;
grant execute on function public.track_fadewell_storefront_event(text,text,text)
to anon, authenticated;

create or replace view public.fadewell_storefront_funnel_pairs
with (security_invoker=true) as
select c.event_date,c.event_type,c.source_page,c.vinted_item_id,
       p.title,p.available,p.sold,sum(c.event_count)::bigint as events,
       max(c.last_event_at) as last_event_at
from public.fadewell_storefront_event_counts c
left join public.fadewell_storefront_products p on p.vinted_item_id=c.vinted_item_id
group by c.event_date,c.event_type,c.source_page,c.vinted_item_id,p.title,p.available,p.sold;

revoke all on public.fadewell_storefront_funnel_pairs from public,anon,authenticated;
grant select on public.fadewell_storefront_funnel_pairs to authenticated;

create or replace view public.fadewell_storefront_health
with (security_invoker=true) as
select count(*) filter (where published)::bigint as published_pairs,
       count(*) filter (where published and available and not sold)::bigint as available_pairs,
       count(*) filter (where published and sold)::bigint as archived_pairs,
       max(updated_at) filter (where published) as latest_pair_update,
       count(*) filter (where published and nullif(btrim(description_raw),'') is null)::bigint as missing_descriptions
from public.fadewell_storefront_products;

revoke all on public.fadewell_storefront_health from public,anon,authenticated;
grant select on public.fadewell_storefront_health to authenticated;

comment on view public.fadewell_storefront_funnel_pairs is
'Owner-only aggregate storefront funnel by day and pair; no visitor identifiers.';
