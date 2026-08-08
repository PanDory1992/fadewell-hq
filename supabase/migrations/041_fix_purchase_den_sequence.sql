-- Generate the next DEN from the trailing numeric suffix. This deliberately
-- avoids regex backslash escapes, which previously left values such as DEN-001
-- unchanged and caused an integer-cast error during purchase creation.
create or replace function public.apply_hq_ledger_action_owner(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  payload jsonb := coalesce(p, '{}'::jsonb);
  next_item text;
begin
  if auth.uid() is null or not public.is_hq_owner() then
    raise exception 'HQ owner access required';
  end if;

  if payload->>'action_type' = 'PURCHASE'
     and coalesce(payload->>'item_id', '') = '' then
    perform pg_advisory_xact_lock(hashtext('fadewell-hq-den-id'));
    select format(
      'DEN-%s',
      lpad((coalesce(max(substring(item_id from '[0-9]+$')::integer), 0) + 1)::text, 3, '0')
    ) into next_item
    from public.hq_ledger_items
    where item_id ~ '^DEN-[0-9]+$';
    payload := jsonb_set(payload, '{item_id}', to_jsonb(next_item));
  end if;

  return public.apply_hq_ledger_action(payload);
end;
$$;

revoke all on function public.apply_hq_ledger_action_owner(jsonb) from public, anon;
grant execute on function public.apply_hq_ledger_action_owner(jsonb) to authenticated;
