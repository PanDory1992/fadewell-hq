-- Close accidental PostgREST execution paths around server-owned mutation and
-- maintenance functions. Browser-owner RPCs remain authenticated and keep
-- their internal owner check; public storefront helpers remain unchanged.

revoke all on function public.apply_hq_gmail_intake(jsonb) from public, anon, authenticated;
revoke all on function public.apply_hq_vinted_transaction_backfill() from public, anon, authenticated;
revoke all on function public.auto_fill_dna_from_live_listing_observation() from public, anon, authenticated;
revoke all on function public.auto_fill_dna_from_new_listing_title() from public, anon, authenticated;
revoke all on function public.dry_run_hq_vinted_transaction_backfill() from public, anon, authenticated;
revoke all on function public.enrich_hq_listing_event_title_provenance() from public, anon, authenticated;
revoke all on function public.hq_capture_experiment_sale() from public, anon, authenticated;
revoke all on function public.hq_capture_sourcing_replacement_release() from public, anon, authenticated;
revoke all on function public.hq_confirm_price_experiment_from_snapshot() from public, anon, authenticated;
revoke all on function public.hq_record_browser_sync_change() from public, anon, authenticated;
revoke all on function public.hq_refresh_experiment_activation_from_item() from public, anon, authenticated;
revoke all on function public.persist_hq_listing_photo() from public, anon, authenticated;
revoke all on function public.reconcile_hq_manual_sale_evidence(text) from public, anon, authenticated;
revoke all on function public.reconcile_hq_vinted_transaction_message(text) from public, anon, authenticated;
revoke all on function public.record_hq_gmail_evidence(jsonb) from public, anon, authenticated;
revoke all on function public.record_hq_vinted_daily_quality_report() from public, anon, authenticated;
revoke all on function public.record_hq_vinted_transaction_states() from public, anon, authenticated;

grant execute on function public.apply_hq_gmail_intake(jsonb) to service_role;
grant execute on function public.apply_hq_vinted_transaction_backfill() to service_role;
grant execute on function public.auto_fill_dna_from_live_listing_observation() to service_role;
grant execute on function public.auto_fill_dna_from_new_listing_title() to service_role;
grant execute on function public.dry_run_hq_vinted_transaction_backfill() to service_role;
grant execute on function public.enrich_hq_listing_event_title_provenance() to service_role;
grant execute on function public.hq_capture_experiment_sale() to service_role;
grant execute on function public.hq_capture_sourcing_replacement_release() to service_role;
grant execute on function public.hq_confirm_price_experiment_from_snapshot() to service_role;
grant execute on function public.hq_record_browser_sync_change() to service_role;
grant execute on function public.hq_refresh_experiment_activation_from_item() to service_role;
grant execute on function public.persist_hq_listing_photo() to service_role;
grant execute on function public.reconcile_hq_manual_sale_evidence(text) to service_role;
grant execute on function public.reconcile_hq_vinted_transaction_message(text) to service_role;
grant execute on function public.record_hq_gmail_evidence(jsonb) to service_role;
grant execute on function public.record_hq_vinted_daily_quality_report() to service_role;
grant execute on function public.record_hq_vinted_transaction_states() to service_role;

revoke all on function public.claim_first_hq_owner() from public, anon;
revoke all on function public.backfill_hq_vinted_title(jsonb) from public, anon;
revoke all on function public.create_hq_experiment_owner(jsonb) from public, anon;
revoke all on function public.hq_browser_sync_changes_since(bigint) from public, anon;
revoke all on function public.record_hq_price_test_owner(jsonb) from public, anon;
revoke all on function public.report_hq_experiment_execution_owner(jsonb) from public, anon;
revoke all on function public.resolve_hq_gmail_review_owner(jsonb) from public, anon;
revoke all on function public.set_hq_purchase_before_owner(jsonb) from public, anon;
revoke all on function public.update_hq_item_dna_owner(jsonb) from public, anon;

grant execute on function public.claim_first_hq_owner() to authenticated, service_role;
grant execute on function public.backfill_hq_vinted_title(jsonb) to authenticated, service_role;
grant execute on function public.create_hq_experiment_owner(jsonb) to authenticated, service_role;
grant execute on function public.hq_browser_sync_changes_since(bigint) to authenticated, service_role;
grant execute on function public.record_hq_price_test_owner(jsonb) to authenticated, service_role;
grant execute on function public.report_hq_experiment_execution_owner(jsonb) to authenticated, service_role;
grant execute on function public.resolve_hq_gmail_review_owner(jsonb) to authenticated, service_role;
grant execute on function public.set_hq_purchase_before_owner(jsonb) to authenticated, service_role;
grant execute on function public.update_hq_item_dna_owner(jsonb) to authenticated, service_role;

-- Preserve evidence while closing abandoned historical attempts honestly.
update public.hq_email_sync_runs
set status = 'FAILED',
    finished_at = now(),
    error = 'Stale RUNNING record closed during the 2026-09-13 reliability repair; actual completion is unknown.'
where status = 'RUNNING' and started_at < now() - interval '30 minutes';

-- Re-run only the idempotent, evidence-based transaction linker. It never
-- invents a sale or cash confirmation without an eligible Gmail message.
do $$
declare message record;
begin
  for message in select gmail_message_id from public.hq_gmail_messages order by received_at, gmail_message_id loop
    perform public.reconcile_hq_vinted_transaction_message(message.gmail_message_id);
  end loop;
  perform public.record_hq_vinted_transaction_states();
end $$;

-- GitHub scheduled events are best-effort. Supabase cron now owns the clock
-- and dispatches the existing, tested workflows through a narrow Edge gate.
select cron.unschedule(jobid)
from cron.job
where jobname in ('hq-storefront-workflow-every-15-minutes', 'hq-gmail-watchdog-workflow-every-15-minutes');

select cron.schedule(
  'hq-storefront-workflow-every-15-minutes',
  '2,17,32,47 * * * *',
  $$select net.http_post(
    url := 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-github-scheduler',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='vinted_collector_cron_secret' limit 1)
    ),
    body := '{"workflow":"storefront-sync.yml"}'::jsonb,
    timeout_milliseconds := 20000
  )$$
);

select cron.schedule(
  'hq-gmail-watchdog-workflow-every-15-minutes',
  '7,22,37,52 * * * *',
  $$select net.http_post(
    url := 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-github-scheduler',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='vinted_collector_cron_secret' limit 1)
    ),
    body := '{"workflow":"gmail-sync-watchdog.yml"}'::jsonb,
    timeout_milliseconds := 20000
  )$$
);
