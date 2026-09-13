-- Private HQ access: the first authenticated GitHub user claims owner role.
create table if not exists public.hq_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('OWNER')),
  created_at timestamptz not null default now()
);
alter table public.hq_members enable row level security;
create or replace function public.claim_first_hq_owner()
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from hq_members) then
    insert into hq_members(user_id,role) values(auth.uid(),'OWNER'); return true;
  end if;
  return exists(select 1 from hq_members where user_id=auth.uid() and role='OWNER');
end $$;
grant execute on function public.claim_first_hq_owner() to authenticated;
drop policy if exists "hq authenticated ledger item access" on public.hq_ledger_items;
drop policy if exists "hq authenticated ledger event access" on public.hq_ledger_events;
create policy "hq owner ledger item access" on public.hq_ledger_items for all to authenticated
  using (exists(select 1 from hq_members where user_id=auth.uid() and role='OWNER'))
  with check (exists(select 1 from hq_members where user_id=auth.uid() and role='OWNER'));
create policy "hq owner ledger event access" on public.hq_ledger_events for all to authenticated
  using (exists(select 1 from hq_members where user_id=auth.uid() and role='OWNER'))
  with check (exists(select 1 from hq_members where user_id=auth.uid() and role='OWNER'));
