-- Apps Script now owns the five-minute Gmail intake schedule.
-- Keep the legacy OAuth functions dormant for rollback, but never schedule them.
select cron.unschedule(jobid)
from cron.job
where jobname = 'hq-gmail-sync-every-five-minutes';
