-- K4-K7: append-only Vinted transaction engine.
-- It adds evidence links and state history only. It never writes to hq_ledger_events.

create table if not exists public.hq_vinted_transactions (
  id uuid primary key default gen_random_uuid(),
  canonical_key text not null unique,
  vinted_transaction_id text unique,
  transaction_kind text not null check (transaction_kind in ('SALE','PURCHASE','OTHER')),
  created_at timestamptz not null default now()
);

create table if not exists public.hq_vinted_transaction_message_links (
  id bigint generated always as identity primary key,
  transaction_id uuid not null references public.hq_vinted_transactions(id),
  gmail_message_id text not null references public.hq_gmail_messages(gmail_message_id),
  link_method text not null check (link_method in ('VINTED_TRANSACTION_ID','PROVISIONAL_MESSAGE','SAFE_TITLE_DEN')),
  confidence text not null check (confidence in ('CONFIRMED','INFERRED')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.hq_vinted_transaction_state_events (
  id bigint generated always as identity primary key,
  transaction_id uuid not null references public.hq_vinted_transactions(id),
  state text not null check (state in ('SALE_DETECTED','DEN_MATCHED','SALE_RECORDED','CASH_CONFIRMED','CANCELLED','RETURNED','DISPUTED')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (transaction_id,state)
);

create table if not exists public.hq_vinted_backfill_runs (
  id uuid primary key default gen_random_uuid(),
  mode text not null check (mode in ('DRY_RUN','APPLY')),
  report jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists public.hq_vinted_daily_quality_reports (
  id bigint generated always as identity primary key,
  report_date date not null unique,
  report jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists hq_vinted_transaction_message_links_message_index on public.hq_vinted_transaction_message_links(gmail_message_id, created_at desc);
create index if not exists hq_vinted_transaction_state_events_transaction_index on public.hq_vinted_transaction_state_events(transaction_id, created_at desc);

alter table public.hq_vinted_transactions enable row level security;
alter table public.hq_vinted_transaction_message_links enable row level security;
alter table public.hq_vinted_transaction_state_events enable row level security;
alter table public.hq_vinted_backfill_runs enable row level security;
alter table public.hq_vinted_daily_quality_reports enable row level security;

drop policy if exists "hq owner vinted transactions access" on public.hq_vinted_transactions;
create policy "hq owner vinted transactions access" on public.hq_vinted_transactions for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner vinted transaction links access" on public.hq_vinted_transaction_message_links;
create policy "hq owner vinted transaction links access" on public.hq_vinted_transaction_message_links for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner vinted transaction states access" on public.hq_vinted_transaction_state_events;
create policy "hq owner vinted transaction states access" on public.hq_vinted_transaction_state_events for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner vinted backfill runs access" on public.hq_vinted_backfill_runs;
create policy "hq owner vinted backfill runs access" on public.hq_vinted_backfill_runs for select to authenticated using (public.is_hq_owner());
drop policy if exists "hq owner vinted daily quality access" on public.hq_vinted_daily_quality_reports;
create policy "hq owner vinted daily quality access" on public.hq_vinted_daily_quality_reports for select to authenticated using (public.is_hq_owner());

-- Latest link wins. A provisional mail is never overwritten: a later safe link
-- is appended and becomes current through this view.
create or replace view public.hq_vinted_transaction_message_current as
select distinct on (gmail_message_id) transaction_id,gmail_message_id,link_method,confidence,detail,created_at
from public.hq_vinted_transaction_message_links
order by gmail_message_id, created_at desc, id desc;

create or replace view public.hq_vinted_transaction_current as
select t.id,t.canonical_key,t.vinted_transaction_id,t.transaction_kind,t.created_at,
       coalesce((select s.state from public.hq_vinted_transaction_state_events s where s.transaction_id=t.id order by s.created_at desc,s.id desc limit 1),'') as current_state,
       coalesce((select max(s.created_at) from public.hq_vinted_transaction_state_events s where s.transaction_id=t.id),t.created_at) as state_updated_at
from public.hq_vinted_transactions t;

create or replace function public.record_hq_vinted_transaction_states()
returns jsonb language plpgsql security definer set search_path = public as $$
declare inserted_count integer := 0;
begin
  -- The order is deliberately explicit: confirmation can never create a ledger entry.
  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'SALE_DETECTED',jsonb_build_object('source','gmail_sale_pending')
  from hq_vinted_transactions t
  where t.transaction_kind='SALE' and exists (
    select 1 from hq_vinted_transaction_message_current l join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
    where l.transaction_id=t.id and e.event_type='SALE_PENDING'
  ) on conflict do nothing;
  get diagnostics inserted_count = row_count;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'DEN_MATCHED',jsonb_build_object('item_id',e.matched_item_id)
  from hq_vinted_transactions t join hq_vinted_transaction_message_current l on l.transaction_id=t.id
  join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
  where t.transaction_kind='SALE' and e.event_type='SALE_PENDING' and e.matched_item_id is not null
  on conflict do nothing;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'SALE_RECORDED',jsonb_build_object('ledger_event_id',e.ledger_event_id,'amount',e.amount)
  from hq_vinted_transactions t join hq_vinted_transaction_message_current l on l.transaction_id=t.id
  join hq_external_events e on e.source_event_id=l.gmail_message_id and e.source='GMAIL_VINTED'
  where t.transaction_kind='SALE' and e.event_type='SALE_PENDING' and e.ledger_event_id is not null and e.amount > 0
  on conflict do nothing;

  insert into hq_vinted_transaction_state_events(transaction_id,state,detail)
  select t.id,'CASH_CONFIRMED',jsonb_build_object('vinted_transaction_id',t.vinted_transaction_id)
  from hq_vinted_transactions t
  where t.transaction_kind='SALE' and t.vinted_transaction_id is not null
    and exists (
      select 1 from hq_vinted_transaction_message_current l join hq_gmail_parse_runs p on p.gmail_message_id=l.gmail_message_id
      where l.transaction_id=t.id and p.event_type='SALE_CONFIRMED'
    )
    and exists (select 1 from hq_vinted_transaction_state_events s where s.transaction_id=t.id and s.state='SALE_RECORDED')
  on conflict do nothing;

  return jsonb_build_object('ok',true);
end $$;

create or replace function public.reconcile_hq_vinted_transaction_message(p_message_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare mail_row record; transaction_row public.hq_vinted_transactions%rowtype; pending_message_id text; candidate_count integer;
begin
  select gm.*, e.event_type,e.item_title,e.amount,e.matched_item_id,e.ledger_event_id,e.state
  into mail_row from hq_gmail_messages gm left join hq_external_events e on e.source='GMAIL_VINTED' and e.source_event_id=gm.gmail_message_id
  where gm.gmail_message_id=p_message_id;
  if not found then raise exception 'Gmail evidence % is not available',p_message_id; end if;

  insert into hq_vinted_transactions(canonical_key,vinted_transaction_id,transaction_kind)
  values (
    case when mail_row.vinted_transaction_id is not null then 'vinted:'||mail_row.vinted_transaction_id else 'gmail:'||mail_row.gmail_message_id end,
    mail_row.vinted_transaction_id,
    case when mail_row.event_type in ('SALE_PENDING','SALE_CONFIRMED') then 'SALE' when mail_row.event_type like 'PURCHASE%' then 'PURCHASE' else 'OTHER' end
  ) on conflict (canonical_key) do update set transaction_kind=case when excluded.transaction_kind='SALE' then 'SALE' else hq_vinted_transactions.transaction_kind end
  returning * into transaction_row;

  insert into hq_vinted_transaction_message_links(transaction_id,gmail_message_id,link_method,confidence,detail)
  select transaction_row.id,mail_row.gmail_message_id,
         case when mail_row.vinted_transaction_id is not null then 'VINTED_TRANSACTION_ID' else 'PROVISIONAL_MESSAGE' end,
         case when mail_row.vinted_transaction_id is not null then 'CONFIRMED' else 'INFERRED' end,
         jsonb_build_object('reason',case when mail_row.vinted_transaction_id is not null then 'exact_vinted_transaction_id' else 'no_transaction_id_in_this_message' end)
  where not exists (select 1 from hq_vinted_transaction_message_links x where x.gmail_message_id=mail_row.gmail_message_id and x.transaction_id=transaction_row.id);

  -- A transaction ID can bridge an earlier pending-sale mail only when one, and
  -- only one, listed DEN already matches the normalized title inside 31 days.
  if mail_row.vinted_transaction_id is not null then
    select count(*),min(candidate.gmail_message_id) into candidate_count,pending_message_id
    from (
      select m2.gmail_message_id
      from hq_gmail_messages m2 join hq_external_events e2 on e2.source='GMAIL_VINTED' and e2.source_event_id=m2.gmail_message_id
      where m2.vinted_transaction_id is null and e2.event_type='SALE_PENDING' and e2.matched_item_id is not null
        and m2.received_at <= mail_row.received_at and mail_row.received_at-m2.received_at <= interval '31 days'
        and lower(regexp_replace(coalesce(e2.item_title,''),'[^[:alnum:]]+',' ','g')) = lower(regexp_replace(coalesce(mail_row.item_title,''),'[^[:alnum:]]+',' ','g'))
    ) candidate;
    if candidate_count=1 then
      insert into hq_vinted_transaction_message_links(transaction_id,gmail_message_id,link_method,confidence,detail)
      select transaction_row.id,pending_message_id,'SAFE_TITLE_DEN','INFERRED',jsonb_build_object('reason','unique_title_on_matched_den_within_31_days','supporting_transaction_id',mail_row.vinted_transaction_id)
      where not exists (select 1 from hq_vinted_transaction_message_links x where x.gmail_message_id=pending_message_id and x.transaction_id=transaction_row.id);
      update hq_vinted_transactions set transaction_kind='SALE' where id=transaction_row.id and transaction_kind<>'SALE';
    end if;
  end if;

  perform public.record_hq_vinted_transaction_states();
  return jsonb_build_object('transaction_id',transaction_row.id,'canonical_key',transaction_row.canonical_key,'vinted_transaction_id',transaction_row.vinted_transaction_id,'safe_pending_candidates',coalesce(candidate_count,0));
end $$;

create or replace function public.dry_run_hq_vinted_transaction_backfill()
returns jsonb language sql security definer set search_path = public as $$
  with mails as (
    select m.gmail_message_id,m.vinted_transaction_id,e.event_type,e.matched_item_id,e.ledger_event_id,e.amount
    from hq_gmail_messages m left join hq_external_events e on e.source='GMAIL_VINTED' and e.source_event_id=m.gmail_message_id
  ), sales as (select * from mails where event_type='SALE_PENDING')
  select jsonb_build_object(
    'gmail_messages',(select count(*) from mails),
    'messages_with_exact_vinted_id',(select count(*) from mails where vinted_transaction_id is not null),
    'sale_pending_messages',(select count(*) from sales),
    'sale_pending_with_unique_den',(select count(*) from sales where matched_item_id is not null),
    'sale_pending_with_ledger_event',(select count(*) from sales where ledger_event_id is not null and amount>0),
    'sale_pending_amount',(select coalesce(sum(amount),0) from sales),
    'ledger_linked_sale_amount',(select coalesce(sum(amount),0) from sales where ledger_event_id is not null and amount>0),
    'note','dry run only; no ledger or evidence history is modified'
  );
$$;

create or replace function public.apply_hq_vinted_transaction_backfill()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; report jsonb;
begin
  report := public.dry_run_hq_vinted_transaction_backfill();
  for r in select gmail_message_id from hq_gmail_messages order by received_at,gmail_message_id loop
    perform public.reconcile_hq_vinted_transaction_message(r.gmail_message_id);
  end loop;
  perform public.record_hq_vinted_transaction_states();
  insert into hq_vinted_backfill_runs(mode,report) values ('APPLY',report);
  return report || jsonb_build_object('applied',true);
end $$;

create or replace view public.hq_vinted_operations_exceptions as
select e.source_event_id as reference_id,'GMAIL_REVIEW' as exception_type,e.created_at,e.event_type,e.item_title,e.amount,e.vinted_transaction_id
from hq_external_events e where e.source='GMAIL_VINTED' and e.state='NEEDS_REVIEW'
union all
select t.canonical_key,'RECORDED_SALE_WITHOUT_CASH',t.state_updated_at,'SALE_PENDING',null,null,t.vinted_transaction_id
from hq_vinted_transaction_current t
where t.current_state='SALE_RECORDED' and t.state_updated_at < now()-interval '21 days';

create or replace function public.record_hq_vinted_daily_quality_report()
returns jsonb language plpgsql security definer set search_path = public as $$
declare report jsonb;
begin
  select jsonb_build_object(
    'gmail_message_count',(select count(*) from hq_gmail_messages where received_at::date=current_date),
    'recognized_mail_count',(select count(distinct gmail_message_id) from hq_gmail_parse_runs where created_at::date=current_date and event_type not in ('UNCLASSIFIED','NOISE')),
    'needs_decision_count',(select count(*) from hq_vinted_operations_exceptions),
    'recorded_sales_without_cash_confirmation',(select count(*) from hq_vinted_transaction_current where current_state='SALE_RECORDED'),
    'completion_without_title_or_sale_link',(select count(distinct p.gmail_message_id) from hq_gmail_parse_runs p join hq_gmail_messages m on m.gmail_message_id=p.gmail_message_id where p.event_type='SALE_CONFIRMED' and (coalesce(p.extracted_fields->'item_title'->>'value','')='' or not exists (select 1 from hq_vinted_transaction_message_current l join hq_vinted_transactions t on t.id=l.transaction_id where l.gmail_message_id=m.gmail_message_id and exists (select 1 from hq_vinted_transaction_state_events s where s.transaction_id=t.id and s.state='SALE_RECORDED')))),
    'unexplained_mail_ledger_delta',(select count(*) from hq_external_events where source='GMAIL_VINTED' and event_type='SALE_PENDING' and ledger_event_id is null and state='AUTO_APPLIED'),
    'generated_at',now()
  ) into report;
  insert into hq_vinted_daily_quality_reports(report_date,report) values(current_date,report)
  on conflict (report_date) do update set report=excluded.report,created_at=now();
  return report;
end $$;

create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid) from cron.job where jobname='hq-vinted-daily-quality-report';
select cron.schedule('hq-vinted-daily-quality-report','10 6 * * *',$$select public.record_hq_vinted_daily_quality_report()$$);

revoke all on table public.hq_vinted_transactions,public.hq_vinted_transaction_message_links,public.hq_vinted_transaction_state_events,public.hq_vinted_backfill_runs,public.hq_vinted_daily_quality_reports from public;
revoke all on function public.record_hq_vinted_transaction_states(),public.reconcile_hq_vinted_transaction_message(text),public.dry_run_hq_vinted_transaction_backfill(),public.apply_hq_vinted_transaction_backfill(),public.record_hq_vinted_daily_quality_report() from public;
grant select on public.hq_vinted_transactions,public.hq_vinted_transaction_message_links,public.hq_vinted_transaction_state_events,public.hq_vinted_backfill_runs,public.hq_vinted_daily_quality_reports,public.hq_vinted_transaction_current,public.hq_vinted_operations_exceptions to authenticated;
grant execute on function public.reconcile_hq_vinted_transaction_message(text),public.apply_hq_vinted_transaction_backfill(),public.record_hq_vinted_daily_quality_report() to service_role;
grant execute on function public.dry_run_hq_vinted_transaction_backfill() to authenticated,service_role;
