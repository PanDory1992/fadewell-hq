-- Close the legacy authenticated-user gap on HQ operational tables.
-- The browser already requires an HQ owner; these policies make the database
-- boundary match that private-HQ contract for direct API access as well.

drop policy if exists "hq authenticated item access" on public.hq_items;
create policy "hq owner item access"
on public.hq_items
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());

drop policy if exists "hq authenticated snapshot access" on public.hq_listing_snapshots;
create policy "hq owner snapshot access"
on public.hq_listing_snapshots
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());

drop policy if exists "hq authenticated review access" on public.hq_review_queue;
create policy "hq owner review access"
on public.hq_review_queue
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());

drop policy if exists "hq authenticated capture access" on public.hq_capture_candidates;
create policy "hq owner capture access"
on public.hq_capture_candidates
for all to authenticated
using (public.is_hq_owner())
with check (public.is_hq_owner());
