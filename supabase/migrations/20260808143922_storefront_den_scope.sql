-- Keep the public storefront aligned with the operational DEN scope.
-- Category exclusions and non-DEN exclusions are intentionally separate.

drop function if exists public.get_fadewell_storefront_health();

create function public.get_fadewell_storefront_health()
returns table (
  published_pairs bigint,
  available_pairs bigint,
  archived_pairs bigint,
  latest_pair_update timestamptz,
  missing_descriptions bigint,
  available_unpublished_pairs bigint,
  action_required_pairs bigint,
  out_of_scope_pairs bigint,
  out_of_den_scope_pairs bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_hq_owner() then raise exception 'HQ owner access required'; end if;
  return query
  with classified as (
    select p.*,
           case
             when p.published then 'PUBLISHED'
             when nullif(btrim(coalesce(p.publication_notes->>'publication_status','')), '') is not null
               then p.publication_notes->>'publication_status'
             when p.garment_type is null and nullif(btrim(coalesce(p.vinted_category,'')), '') is null
               then 'NO_CATEGORY_EVIDENCE'
             when p.garment_type is null then 'OUT_OF_SCOPE_CATEGORY'
             when jsonb_array_length(coalesce(p.publication_notes->'missing_measurements','[]'::jsonb)) > 0
               then 'NEEDS_MEASUREMENT_REVIEW'
             when nullif(btrim(coalesce(p.description_raw,'')), '') is null
               then 'NO_DESCRIPTION'
             when jsonb_array_length(coalesce(p.photos,'[]'::jsonb)) = 0
               then 'NO_PHOTOS'
             else 'UNCLASSIFIED_BLOCKER'
           end as publication_status
    from public.fadewell_storefront_products p
  )
  select
    count(*) filter (where published)::bigint,
    count(*) filter (where published and available and not sold)::bigint,
    count(*) filter (where published and sold)::bigint,
    max(updated_at),
    count(*) filter (where published and nullif(btrim(description_raw),'') is null)::bigint,
    count(*) filter (where available and not sold and not published)::bigint,
    count(*) filter (
      where available and not sold and publication_status not in ('PUBLISHED','OUT_OF_SCOPE_CATEGORY','OUT_OF_SCOPE_DEN')
    )::bigint,
    count(*) filter (where available and not sold and publication_status = 'OUT_OF_SCOPE_CATEGORY')::bigint,
    count(*) filter (where available and not sold and publication_status = 'OUT_OF_SCOPE_DEN')::bigint
  from classified;
end;
$$;

revoke all on function public.get_fadewell_storefront_health()
from public, anon, authenticated;
grant execute on function public.get_fadewell_storefront_health() to authenticated;

create or replace function public.get_fadewell_storefront_completeness()
returns table (
  vinted_item_id text,
  title text,
  vinted_url text,
  garment_type text,
  available boolean,
  sold boolean,
  publication_status text,
  action_required boolean,
  missing_measurements jsonb,
  measurement_issues jsonb,
  blocking_reasons jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_hq_owner() then raise exception 'HQ owner access required'; end if;
  return query
  with classified as (
    select p.*,
           case
             when p.published then 'PUBLISHED'
             when nullif(btrim(coalesce(p.publication_notes->>'publication_status','')), '') is not null
               then p.publication_notes->>'publication_status'
             when p.garment_type is null and nullif(btrim(coalesce(p.vinted_category,'')), '') is null
               then 'NO_CATEGORY_EVIDENCE'
             when p.garment_type is null then 'OUT_OF_SCOPE_CATEGORY'
             when jsonb_array_length(coalesce(p.publication_notes->'missing_measurements','[]'::jsonb)) > 0
               then 'NEEDS_MEASUREMENT_REVIEW'
             when nullif(btrim(coalesce(p.description_raw,'')), '') is null
               then 'NO_DESCRIPTION'
             when jsonb_array_length(coalesce(p.photos,'[]'::jsonb)) = 0
               then 'NO_PHOTOS'
             else 'UNCLASSIFIED_BLOCKER'
           end as derived_publication_status
    from public.fadewell_storefront_products p
  )
  select
    c.vinted_item_id,
    c.title,
    c.vinted_url,
    c.garment_type,
    c.available,
    c.sold,
    c.derived_publication_status,
    (c.available and not c.sold and c.derived_publication_status not in ('PUBLISHED','OUT_OF_SCOPE_CATEGORY','OUT_OF_SCOPE_DEN')),
    coalesce(c.publication_notes->'missing_measurements','[]'::jsonb),
    coalesce(c.publication_notes->'measurement_issues','{}'::jsonb),
    coalesce(c.publication_notes->'blocking_reasons','[]'::jsonb)
  from classified c
  where c.available and not c.sold and not c.published
  order by
    (c.derived_publication_status = 'OUT_OF_SCOPE_CATEGORY'),
    (c.derived_publication_status = 'OUT_OF_SCOPE_DEN'),
    c.title nulls last,
    c.vinted_item_id;
end;
$$;

revoke all on function public.get_fadewell_storefront_completeness()
from public, anon, authenticated;
grant execute on function public.get_fadewell_storefront_completeness() to authenticated;
