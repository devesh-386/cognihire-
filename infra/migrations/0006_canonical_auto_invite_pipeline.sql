-- Mirror of the live migration "canonical_auto_invite_pipeline", applied via
-- the Supabase MCP. Not authoritative — the live database is.
--
-- Ticket: canonicalize candidate intake around interview_codes.generate() +
-- notifications/workflow.py (Ticket 21), instead of intake-webhook's private
-- 6-char code + invitations/reminder-scheduler system.
--
-- Two changes:
-- 1. candidates.role_id — intake-webhook already resolves a role by title at
--    submission time but never persisted it, so nothing downstream could
--    tell which role a candidate applied for once the form's request body
--    was gone. Needed so the auto-invite trigger (below) knows what
--    role_title to pass to interview_codes.generate().
-- 2. A best-effort trigger mirroring 0002/0005's resume-processing trigger:
--    fires once, only on the transition into READY_FOR_INTERVIEW, and calls
--    a new internal FastAPI endpoint that reuses the existing code+email
--    machinery. Never blocks or fails the profile update that fires it —
--    same "the state row is the queue, the notification is best-effort"
--    design as the resume trigger.

alter table public.candidates
  add column role_id text references public.roles(id);

-- Verified no existing (organization_id, email) duplicates before adding
-- this — see the SELECT ... GROUP BY ... HAVING count(*) > 1 check run
-- immediately before this migration.
alter table public.candidates
  add constraint candidates_org_email_unique unique (organization_id, email);

-- Placeholder row: value is set by hand via the SQL editor (never through a
-- migration, so it never lands in this file or git history). Empty value
-- means the trigger below silently no-ops, same as an unconfigured
-- ai_gateway_url — auto-invite simply doesn't fire until an operator sets
-- this, rather than erroring.
insert into public.app_config (key, value)
values ('internal_pipeline_secret', '')
on conflict (key) do nothing;

create or replace function public.trigger_auto_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  gateway_url text;
  internal_secret text;
begin
  if new.processing_status is distinct from 'READY_FOR_INTERVIEW' then
    return new;
  end if;
  if old.processing_status is not distinct from 'READY_FOR_INTERVIEW' then
    -- Already was READY_FOR_INTERVIEW (e.g. an unrelated column update) —
    -- only the transition into it should fire this.
    return new;
  end if;

  select value into gateway_url from public.app_config where key = 'ai_gateway_url';
  select value into internal_secret from public.app_config where key = 'internal_pipeline_secret';
  if gateway_url is null or gateway_url = '' or internal_secret is null or internal_secret = '' then
    return new;
  end if;

  begin
    perform net.http_post(
      url := gateway_url || '/internal/candidates/' || new.candidate_id || '/auto-invite',
      body := '{}'::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Internal-Secret', internal_secret
      )
    );
  exception when others then
    -- Deliberately swallowed, same reasoning as trigger_resume_processing:
    -- a candidate reaching READY_FOR_INTERVIEW must never be undone by an
    -- unreachable gateway. The profile row's status is the durable record;
    -- anything READY_FOR_INTERVIEW with no code yet is work a sweeper can
    -- retry later.
    null;
  end;

  return new;
end;
$$;

create trigger candidate_ready_for_interview
  after update of processing_status on public.candidate_ai_profile
  for each row execute function public.trigger_auto_invite();

revoke execute on function public.trigger_auto_invite() from anon, authenticated, public;
