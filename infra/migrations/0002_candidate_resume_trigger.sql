-- Fire the resume pipeline when a candidate arrives with a resume.
--
-- Event-driven, not polled — same pg_net mechanism the reminder-scheduler
-- cron already uses in this project.
--
-- ## Why every failure path here is swallowed
--
-- This trigger runs inside the transaction that `apply-webhook` uses to
-- create a candidate. If it raised — gateway not deployed yet, DNS down,
-- pg_net missing, setting unconfigured — the candidate's application would
-- fail with it. A candidate losing their application because an internal AI
-- service was down is a far worse outcome than a profile sitting at
-- 'UPLOADED' until someone reprocesses it. So the profile row is always
-- created (that part is real work and must be durable), and only the
-- notification is best-effort.
--
-- This means an unreachable gateway is INVISIBLE here by design. The profile
-- row is the queue: anything stuck at 'UPLOADED' is work not yet done, and a
-- sweeper/backfill can pick those up. Do not add alerting to this function —
-- add it to whatever reads that state.

create or replace function public.trigger_resume_processing()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  gateway_url text;
begin
  if new.resume_path is null then
    return new;
  end if;

  -- The row is the durable part: created regardless of whether the gateway
  -- can be reached, so no upload is ever silently dropped.
  insert into public.candidate_ai_profile (organization_id, candidate_id, processing_status)
  values (new.organization_id, new.id, 'UPLOADED')
  on conflict (candidate_id) do update
    set processing_status = 'UPLOADED',
        error = null,
        updated_at = now();

  -- Best-effort notification. Unset setting => no call, no error.
  gateway_url := current_setting('app.settings.ai_gateway_url', true);
  if gateway_url is null or gateway_url = '' then
    return new;
  end if;

  begin
    perform net.http_post(
      url := gateway_url || '/resumes/process',
      body := jsonb_build_object('candidate_id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  exception when others then
    -- Deliberately swallowed; see the note above.
    null;
  end;

  return new;
end;
$$;

create trigger candidates_resume_uploaded
  after insert or update of resume_path on public.candidates
  for each row execute function public.trigger_resume_processing();

-- Trigger functions are invoked by the trigger, never by a client. Without
-- this, PostgREST exposes them at /rest/v1/rpc/<name> as SECURITY DEFINER
-- functions any anonymous caller can invoke. Revoking does not affect trigger
-- firing: triggers run as the table owner, not as the calling role.
revoke execute on function public.touch_candidate_ai_profile() from anon, authenticated, public;
revoke execute on function public.trigger_resume_processing() from anon, authenticated, public;
