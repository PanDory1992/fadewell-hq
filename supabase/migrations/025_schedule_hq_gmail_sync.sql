-- Canonical replacement for the legacy root-level 013 schedule migration.
-- Preserve the existing five-minute Gmail intake schedule in the HQ-owned
-- migration history.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid)
from cron.job
where jobname = 'hq-gmail-sync-every-five-minutes';
select cron.schedule(
  'hq-gmail-sync-every-five-minutes',
  '*/5 * * * *',
  $$select net.http_post(
    url := 'https://qgjkxtolyhbwpvncwtkn.supabase.co/functions/v1/hq-gmail-sync',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )$$
);
