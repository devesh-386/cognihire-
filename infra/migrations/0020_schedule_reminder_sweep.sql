-- Wire the canonical reminder sweep to a scheduler.
--
-- THE BUG THIS FIXES
-- `notifications/workflow.py::send_due_reminders` — the interview-code
-- reminder logic (Ticket 21) — has been correct and unit-tested since it was
-- written, and has NEVER RUN IN PRODUCTION. Its own docstring says "call this
-- on a timer"; nothing ever did. `POST /email/send-due-reminders` had no
-- caller anywhere in the repo, and `cron.job` held only two entries: the
-- DEPRECATED `reminder-scheduler` Edge Function (Ticket 12, reads the
-- `invitations` table, which the canonicalized intake path stopped writing to
-- — it is now empty, so that job sends nothing and has been returning HTTP
-- 500 "GMAIL_ADDRESS/GMAIL_APP_PASSWORD not configured" every 5 minutes) and
-- the intake-form-poller. Consequence, verified against production:
-- `interview_code_emails` contains only `invitation` rows. Zero `reminder_30m`.
-- Zero `reminder_1h`. Ever.
--
-- THIS IS NOT A SECOND REMINDER SYSTEM. It adds no sending logic, no
-- templates, and no state. It is a timer in front of the ONE canonical
-- implementation that already exists. Everything that makes reminders correct
-- — the ±5 minute due window, the (code_id, email_type) dedupe, the
-- per-candidate failure isolation — stays exactly where it is, in
-- `workflow.py`. Do not add reminder logic here.
--
-- SCHEDULE: every 5 minutes.
-- `_REMINDER_WINDOWS` accepts a code as due when |time_until_interview -
-- target| <= 5 minutes, i.e. a 10-minute-wide window per reminder. A 5-minute
-- cadence therefore lands at least once — usually twice — inside every
-- window, so no reminder can be missed between ticks, while the dedupe below
-- makes the second visit a no-op. A 10-minute cadence would be the theoretical
-- maximum and leaves no margin for a slow tick; 5 matches the existing
-- convention in this database and costs one HTTP call per tick.
--
-- DUPLICATE PREVENTION is unchanged and lives in two places, neither of them
-- here: `email_store.find(code_id, email_type)` short-circuits before sending,
-- and the `interview_code_emails_code_id_email_type_key` UNIQUE constraint is
-- the real guarantee when two ticks race. Re-running this migration is also
-- safe — the unschedule below makes it idempotent.
--
-- TIMEZONE: nothing here is timezone-sensitive. pg_cron ticks in UTC, the
-- endpoint compares `datetime.now(timezone.utc)` against `window_start`, and
-- `window_start` is `timestamptz`. No local time is read or written anywhere
-- on this path.
--
-- SECRET HANDLING: the secret is read from `app_config` at execution time
-- rather than baked into the job command, matching `trigger_auto_invite`
-- (migration 0006). The existing `reminder-scheduler-every-5-min` job embeds
-- its secret as a literal in `cron.job.command`, where anyone with read access
-- to that table can see it; this job deliberately does not repeat that.

-- Idempotent re-run: drop any previous copy of this job first.
select cron.unschedule('reminder-sweep-every-5-min')
where exists (select 1 from cron.job where jobname = 'reminder-sweep-every-5-min');

select cron.schedule(
  'reminder-sweep-every-5-min',
  '*/5 * * * *',
  $job$
    select net.http_post(
      url := (select value from public.app_config where key = 'ai_gateway_url')
             || '/email/send-due-reminders',
      body := '{}'::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Internal-Secret',
        (select value from public.app_config where key = 'internal_pipeline_secret')
      )
    )
    -- Both config rows must exist. Without this guard a missing
    -- `ai_gateway_url` would build the URL as NULL || '/email/...' = NULL and
    -- post nowhere, and a missing secret would send an unauthenticated request
    -- that the endpoint correctly answers 401 — both silent, every 5 minutes,
    -- forever. Posting nothing at all is the honest failure.
    where (select value from public.app_config where key = 'ai_gateway_url') is not null
      and (select value from public.app_config where key = 'ai_gateway_url') <> ''
      and (select value from public.app_config where key = 'internal_pipeline_secret') is not null
      and (select value from public.app_config where key = 'internal_pipeline_secret') <> '';
  $job$
);

-- Retire the deprecated Ticket 12 scheduler.
--
-- It polls the `invitations` table, which the canonicalized intake path no
-- longer writes to (0 rows in production), using its own Gmail SMTP transport
-- that is not configured — so every tick since has been a 500 with nothing to
-- send. Left active it is pure noise in `net._http_response`, and it is a
-- standing invitation for someone to "fix" the wrong reminder system later.
--
-- Unscheduled, NOT deleted: the Edge Function and the `invitations` table
-- both remain in place, so this is reversible with a single cron.schedule
-- call if anything turns out to still depend on it.
select cron.unschedule('reminder-scheduler-every-5-min')
where exists (select 1 from cron.job where jobname = 'reminder-scheduler-every-5-min');
