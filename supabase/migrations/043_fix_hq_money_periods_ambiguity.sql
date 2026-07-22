-- The output column names of a PL/pgSQL table-returning function are variables.
-- Qualify CTE fields so PostgreSQL never confuses them with those variables.
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
  if p_grain not in ('week', 'month') then
    raise exception 'p_grain must be week or month';
  end if;

  return query
  with sold as (
    select
      date_trunc(p_grain, i.sold_on)::date as bucket,
      coalesce(i.sale_price_arbitrage, i.sale_price_recycled, 0)::numeric as sale_revenue,
      coalesce(i.total_capital, 0)::numeric as sale_cost,
      coalesce(i.net_profit, coalesce(i.sale_price_arbitrage, i.sale_price_recycled, 0) - coalesce(i.total_capital, 0))::numeric as sale_profit
    from public.hq_ledger_items i
    where i.ledger_status = 'SOLD' and i.sold_on is not null
  ), sold_by_bucket as (
    select s.bucket,
      sum(s.sale_revenue)::numeric as total_revenue,
      sum(s.sale_cost)::numeric as total_cost,
      sum(s.sale_profit)::numeric as total_profit,
      count(*)::integer as total_sales
    from sold s
    group by s.bucket
  ), purchases as (
    select date_trunc(p_grain, i.purchased_on)::date as bucket,
      coalesce(i.total_capital, 0)::numeric as purchase_capital
    from public.hq_ledger_items i
    where i.purchased_on is not null
  ), purchases_by_bucket as (
    select p.bucket, sum(p.purchase_capital)::numeric as total_capital
    from purchases p
    group by p.bucket
  ), buckets as (
    select s.bucket from sold_by_bucket s
    union
    select p.bucket from purchases_by_bucket p
  ), undated as (
    select
      count(*) filter (where i.ledger_status = 'SOLD' and i.sold_on is null)::integer as total_undated_sales,
      coalesce(sum(i.total_capital) filter (where i.purchased_on is null), 0)::numeric as total_undated_purchase_capital
    from public.hq_ledger_items i
  )
  select
    b.bucket,
    coalesce(s.total_revenue, 0)::numeric,
    coalesce(s.total_cost, 0)::numeric,
    coalesce(s.total_profit, 0)::numeric,
    coalesce(s.total_sales, 0)::integer,
    u.total_undated_sales,
    coalesce(p.total_capital, 0)::numeric,
    u.total_undated_purchase_capital
  from buckets b
  left join sold_by_bucket s on s.bucket = b.bucket
  left join purchases_by_bucket p on p.bucket = b.bucket
  cross join undated u
  order by b.bucket;
end;
$$;

revoke all on function public.hq_money_periods(text) from public, anon;
grant execute on function public.hq_money_periods(text) to authenticated, service_role;
