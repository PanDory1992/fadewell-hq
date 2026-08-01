create or replace function public.sync_fadewell_storefront_availability(p_live_ids text[])
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare changed integer;
begin
  update public.fadewell_storefront_products
  set available = false,
      updated_at = now()
  where not sold
    and available
    and not (vinted_item_id = any(coalesce(p_live_ids, array[]::text[])));
  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function public.sync_fadewell_storefront_availability(text[]) from public, anon, authenticated;
grant execute on function public.sync_fadewell_storefront_availability(text[]) to service_role;
