-- Fix owner visibility for the private HQ Ledger.
--
-- hq_members has RLS enabled. The previous Ledger policy queried that table
-- directly, so an authenticated owner could claim access through the
-- SECURITY DEFINER function but still see zero Ledger rows through RLS.
-- This migration changes access evaluation only; it does not change data.

create or replace function public.is_hq_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.hq_members
    where user_id = auth.uid()
      and role = 'OWNER'
  );
$$;
revoke all on function public.is_hq_owner() from public;
grant execute on function public.is_hq_owner() to authenticated;
drop policy if exists "hq owner ledger item access" on public.hq_ledger_items;
create policy "hq owner ledger item access"
on public.hq_ledger_items
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());
drop policy if exists "hq owner ledger event access" on public.hq_ledger_events;
create policy "hq owner ledger event access"
on public.hq_ledger_events
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());
drop policy if exists "hq member self read" on public.hq_members;
create policy "hq member self read"
on public.hq_members
for select to authenticated
using (user_id = auth.uid());
