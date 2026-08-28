-- Retry the two fire-and-forget handoffs in the intake pipeline.
--
-- THE BUG THIS FIXES
-- `trigger_resume_processing` (0005) and `trigger_auto_invite` (0006) both
-- hand off with `net.http_post` wrapped in `exception when others then null`.
-- That swallow is correct and deliberate — a candidate reaching
-- READY_FOR_INTERVIEW must not be rolled back because the gateway blinked —
-- but pg_net is fire-and-forget: the trigger returns success the moment the
-- request is QUEUED, and never learns whether it was delivered. If the API is
-- down, redeploying, rate-limited, or answers 5xx, the row simply stops
-- moving. Nothing retries it. Nothing reports it.
--
-- 0006's own comment already names the missing piece:
--   "anything READY_FOR_INTERVIEW with no code yet is work a sweeper can
--    retry later."
-- This is that sweeper. It was never written.
--
-- Verified in production: candidate `cand-intake-f30a0d41` has sat at
-- processing_status='UPLOADED' with a resume attached since 2026-08-10 — 18
-- days — because one HTTP POST didn't land. A second candidate sat stuck from
-- 08-09 until 08-18. Every downstream stage (claims → code → invitation
-- email → reminder) is gated behind this, so a stalled row is a silently
-- dropped applicant.
--
-- DESIGN: re-drive the EXISTING endpoints. No new pipeline, no new state
-- machine, no duplicate of the processing logic. The sweep only re-sends the
-- same request the trigger already sent, so it is safe by construction:
--   * `/resumes/process` recomputes the profile in place (upsert on
--     candidate_id) — re-running it is idempotent.
--   * `/internal/candidates/{id}/auto-invite` returns the EXISTING code when a
--     live one is present ("status":"existing", main.py) instead of minting a
--     second one, so a redundant sweep cannot produce duplicate codes or
--     duplicate invitation emails.

create or replace function public.sweep_stalled_pipeline()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  gateway_url text;
  internal_secret text;
  resumes_retried int := 0;
  invites_retried int := 0;
  target record;
begin
  select value into gateway_url from public.app_config where key = 'ai_gateway_url';
  select value into internal_secret from public.app_config where key = 'internal_pipeline_secret';
  if gateway_url is null or gateway_url = '' then
    return jsonb_build_object('skipped', 'ai_gateway_url not configured');
  end if;

  -- (1) Résumé processing that stopped moving.
  --
  -- `updated_at < now() - 10 min` is the stall signal: a healthy run walks
  -- UPLOADED -> TEXT_EXTRACTED -> STRUCTURED -> CLAIMS_READY ->
  -- READY_FOR_INTERVIEW in seconds, touching updated_at at each step, so
  -- anything untouched for 10 minutes is not "in progress", it is stuck.
  --
  -- FAILED is deliberately NOT retried: that status means the service
  -- examined this résumé and rejected it (unreadable PDF, etc.). Retrying it
  -- every 10 minutes forever would be a hot loop that never converges, and it
  -- would overwrite a real diagnosis with a retry. A human re-uploads instead.
  --
  -- The 7-day floor stops the sweep from re-driving abandoned rows for the
  -- lifetime of the database; LIMIT 10 keeps a backlog from exceeding
  -- /resumes/process's rate limit of 20 per window.
  for target in
    select p.candidate_id
    from public.candidate_ai_profile p
    join public.candidates c on c.id = p.candidate_id
    where p.processing_status in ('UPLOADED', 'TEXT_EXTRACTED', 'STRUCTURED', 'CLAIMS_READY')
      and c.resume_path is not null
      and p.updated_at < now() - interval '10 minutes'
      and p.updated_at > now() - interval '7 days'
    order by p.updated_at asc
    limit 10
  loop
    begin
      perform net.http_post(
        url := gateway_url || '/resumes/process',
        body := jsonb_build_object('candidate_id', target.candidate_id),
        headers := jsonb_build_object('Content-Type', 'application/json')
      );
      resumes_retried := resumes_retried + 1;
    exception when others then
      -- One unreachable gateway must not abort the rest of the batch, exactly
      -- as in send_due_reminders' per-code isolation.
      null;
    end;
  end loop;

  -- (2) READY_FOR_INTERVIEW with no live code — the case 0006 predicted.
  --
  -- "Live" means not expired: a candidate whose only code has lapsed should
  -- get a fresh one, which is precisely what auto-invite does when it finds no
  -- unexpired code. Where a live code DOES exist, auto-invite short-circuits
  -- to "existing" without sending another email.
  for target in
    select p.candidate_id
    from public.candidate_ai_profile p
    where p.processing_status = 'READY_FOR_INTERVIEW'
      and p.updated_at > now() - interval '7 days'
      and not exists (
        select 1 from public.interview_codes ic
        where ic.candidate_id = p.candidate_id
          and ic.status in ('active', 'used')
          and ic.expires_at > now()
      )
    order by p.updated_at asc
    limit 10
  loop
    begin
      if internal_secret is null or internal_secret = '' then
        exit;
      end if;
      perform net.http_post(
        url := gateway_url || '/internal/candidates/' || target.candidate_id || '/auto-invite',
        body := '{}'::jsonb,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'X-Internal-Secret', internal_secret
        )
      );
      invites_retried := invites_retried + 1;
    exception when others then
      null;
    end;
  end loop;

  -- Returned, not just counted, so `cron.job_run_details.return_message`
  -- carries the outcome of every tick — the observability that was missing
  -- when a stalled candidate produced no signal anywhere.
  return jsonb_build_object(
    'resumes_retried', resumes_retried,
    'invites_retried', invites_retried,
    'swept_at', now()
  );
end;
$$;

revoke execute on function public.sweep_stalled_pipeline() from anon, authenticated, public;

-- Every 10 minutes: frequent enough that a transient gateway blip costs a
-- candidate minutes rather than days, infrequent enough that the 10-minute
-- stall threshold above is never evaluated against a row that is simply
-- mid-flight.
select cron.unschedule('sweep-stalled-pipeline-every-10-min')
where exists (select 1 from cron.job where jobname = 'sweep-stalled-pipeline-every-10-min');

select cron.schedule(
  'sweep-stalled-pipeline-every-10-min',
  '*/10 * * * *',
  $job$ select public.sweep_stalled_pipeline(); $job$
);
