-- Browser cache delta feed. It records metadata only: no ledger values are copied or changed.
create table if not exists public.hq_browser_sync_changes (
  id bigint generated always as identity primary key,
  entity text not null,
  entity_key text not null,
  operation text not null check (operation in ('INSERT','UPDATE','DELETE')),
  changed_at timestamptz not null default now()
);
alter table public.hq_browser_sync_changes enable row level security;
create index if not exists hq_browser_sync_changes_id_index on public.hq_browser_sync_changes(id);

create or replace function public.hq_record_browser_sync_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare payload jsonb;
begin
  if tg_op='DELETE' then payload:=to_jsonb(old); else payload:=to_jsonb(new); end if;
  insert into public.hq_browser_sync_changes(entity,entity_key,operation)
  values (tg_table_name,coalesce(payload->>'item_id',payload->>'id'),tg_op);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists hq_browser_sync_ledger_items on public.hq_ledger_items;
create trigger hq_browser_sync_ledger_items after insert or update or delete on public.hq_ledger_items for each row execute function public.hq_record_browser_sync_change();
drop trigger if exists hq_browser_sync_snapshots on public.hq_listing_snapshots;
create trigger hq_browser_sync_snapshots after insert or update or delete on public.hq_listing_snapshots for each row execute function public.hq_record_browser_sync_change();
drop trigger if exists hq_browser_sync_reviews on public.hq_review_queue;
create trigger hq_browser_sync_reviews after insert or update or delete on public.hq_review_queue for each row execute function public.hq_record_browser_sync_change();
drop trigger if exists hq_browser_sync_ledger_events on public.hq_ledger_events;
create trigger hq_browser_sync_ledger_events after insert or update or delete on public.hq_ledger_events for each row execute function public.hq_record_browser_sync_change();
drop trigger if exists hq_browser_sync_external_events on public.hq_external_events;
create trigger hq_browser_sync_external_events after insert or update or delete on public.hq_external_events for each row execute function public.hq_record_browser_sync_change();

create or replace function public.hq_browser_sync_changes_since(p_after bigint default 0)
returns table(id bigint,entity text,entity_key text,operation text,changed_at timestamptz)
language sql security definer set search_path=public as $$
  select c.id,c.entity,c.entity_key,c.operation,c.changed_at
  from public.hq_browser_sync_changes c
  where public.is_hq_owner() and c.id>p_after
  order by c.id asc limit 500;
$$;
revoke all on table public.hq_browser_sync_changes from public;
grant execute on function public.hq_browser_sync_changes_since(bigint) to authenticated;
