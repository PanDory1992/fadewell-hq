-- Observable Gmail intake and a canonical read model for the Money screen.
-- This migration is additive: it does not alter DEN, ledger-event, or evidence history.

alter table public.hq_email_sync_state
  add column if not exists last_attempt_at timestamptz,
  add column if not exists last_success_at timestamptz,
  add column if not exists last_finished_at timestamptz,
  add column if not exists last_error text,
  add column if not exists last_scanned_count integer,
  add column if not exists last_received_count integer,
  add column if not exists last_applied_count integer,
  add column if not exists last_review_count integer,
  add column if not exists last_noise_count integer;

create table if not exists public.hq_email_sync_runs (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('gmail')),
  status text not null check (status in ('RUNNING','SUCCEEDED','FAILED')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  scanned_count integer not null default 0,
  received_count integer not null default 0,
  applied_count integer not null default 0,
  review_count integer not null default 0,
  noise_count integer not null default 0,
  error text,
  created_at timestamptz not null default now()
);

create index if not exists hq_email_sync_runs_provider_started_index
  on public.hq_email_sync_runs(provider, started_at desc);

alter table public.hq_email_sync_runs enable row level security;
drop policy if exists "hq owner email sync runs access" on public.hq_email_sync_runs;
create policy "hq owner email sync runs access" on public.hq_email_sync_runs
  for select to authenticated using (public.is_hq_owner());

revoke all on public.hq_email_sync_runs from public;
grant select on public.hq_email_sync_runs to authenticated;

create or replace function public.hq_money_periods(p_grain text default 'month')
returns table (
  period_start date,
  revenue numeric,
  cost_of_sales numeric,
  realised_profit numeric,
  sale_count integer,
  undated_sale_count integer,
  dated_purchase_spend numeric,
  undated_purchase_capital numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_hq_owner() then
    raise exception 'HQ owner access required';
  end if;
  if p_grain not in ('week','month') then
    raise exception 'p_grain must be week or month';
  end if;

  return query
  with sold as (
    select
      date_trunc(p_grain, sold_on)::date as bucket,
      coalesce(sale_price_arbitrage, sale_price_recycled, 0)::numeric as revenue,
      coalesce(total_capital, 0)::numeric as cost,
      coalesce(net_profit, coalesce(sale_price_arbitrage, sale_price_recycled, 0) - coalesce(total_capital, 0))::numeric as profit
    from public.hq_ledger_items
    where ledger_status = 'SOLD' and sold_on is not null
  ), sold_by_bucket as (
    select bucket, sum(revenue)::numeric as revenue, sum(cost)::numeric as cost,
      sum(profit)::numeric as profit, count(*)::integer as sale_count
    from sold group by bucket
  ), purchases as (
    select date_trunc(p_grain, purchased_on)::date as bucket, coalesce(total_capital, 0)::numeric as capital
    from public.hq_ledger_items
    where purchased_on is not null
  ), purchases_by_bucket as (
    select bucket, sum(capital)::numeric as capital
    from purchases group by bucket
  ), buckets as (
    select bucket from sold_by_bucket union select bucket from purchases_by_bucket
  ), undated as (
    select
      count(*) filter (where ledger_status = 'SOLD' and sold_on is null)::integer as undated_sales,
      coalesce(sum(total_capital) filter (where purchased_on is null), 0)::numeric as undated_purchase_capital
    from public.hq_ledger_items
  )
  select
    b.bucket,
    coalesce(s.revenue, 0)::numeric,
    coalesce(s.cost, 0)::numeric,
    coalesce(s.profit, 0)::numeric,
    coalesce(s.sale_count, 0)::integer,
    u.undated_sales,
    coalesce(p.capital, 0)::numeric,
    u.undated_purchase_capital
  from buckets b
  left join sold_by_bucket s on s.bucket = b.bucket
  left join purchases_by_bucket p on p.bucket = b.bucket
  cross join undated u
  order by b.bucket;
end;
$$;

create or replace function public.hq_money_cash_position()
returns table (cash_in_transit numeric, cash_confirmed numeric, recorded_sale_count integer, confirmed_sale_count integer)
language sql
security definer
set search_path = public
as $$
  with sale_states as (
    select t.id, t.current_state,
      coalesce((
        select e.amount
        from public.hq_vinted_transaction_message_current l
        join public.hq_external_events e on e.source = 'GMAIL_VINTED' and e.source_event_id = l.gmail_message_id
        where l.transaction_id = t.id and e.event_type = 'SALE_PENDING' and e.amount > 0
        order by e.created_at desc
        limit 1
      ), 0)::numeric as amount
    from public.hq_vinted_transaction_current t
    where t.transaction_kind = 'SALE' and public.is_hq_owner()
  )
  select
    coalesce(sum(amount) filter (where current_state = 'SALE_RECORDED'), 0)::numeric,
    coalesce(sum(amount) filter (where current_state = 'CASH_CONFIRMED'), 0)::numeric,
    count(*) filter (where current_state = 'SALE_RECORDED')::integer,
    count(*) filter (where current_state = 'CASH_CONFIRMED')::integer
  from sale_states;
$$;

revoke all on function public.hq_money_periods(text), public.hq_money_cash_position() from public, anon;
grant execute on function public.hq_money_periods(text), public.hq_money_cash_position() to authenticated, service_role;
