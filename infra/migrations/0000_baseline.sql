-- Schema baseline — the live cognihire Supabase project (foffzvwmxnsmbixkilxt)
-- as it actually exists, dumped 2026-08-19 via read-only introspection
-- (information_schema, pg_catalog) rather than trusting any prior migration
-- file.
--
-- Why this exists: `candidates`, `roles`, `organizations`, and
-- `interview_codes` — the four most-referenced tables in the codebase — had
-- NO migration file anywhere in this repo before this one. One existing
-- migration said so outright ("Mirror of the live migration ... Not
-- authoritative -- the live database is."). That meant this project could
-- not be rebuilt from source: losing the Supabase project meant losing the
-- schema, full stop. This file is that recovery point.
--
-- This is a BASELINE, not a migration meant to run against THIS project —
-- every object it defines already exists there. Its purpose is a fresh
-- project (a new environment, a disaster-recovery rebuild, or finally
-- standing up a staging environment that isn't the same database as
-- production). Apply migrations 0001 onward after this one only against a
-- database that does NOT already have these objects.
--
-- What's captured: every public-schema table, column, constraint, index,
-- RLS policy, function, and trigger. What's deliberately NOT captured: row
-- data (seed data belongs in demo/seed.py, which already exists and is
-- idempotent), and the two `pg_cron` jobs that call the `reminder-scheduler`
-- and `intake-form-poller` Edge Functions (infra/reminder-scheduler/,
-- infra/intake-form-poller/) on a timer — their `cron.schedule(...)` calls
-- carry a bearer secret as a literal string in the job command, visible to
-- anyone with SELECT on `cron.job`. That secret must never be committed to
-- this repo in plaintext; recreate those two schedules by hand against a new
-- project using a freshly generated secret, matching each function's own
-- `SCHEDULER_SECRET` env var, and note this file does not restore them.
--
-- The `invitations` table below is a live orphan: RLS + policies exist, one
-- Edge/RPC-only redemption flow (`accept_invitation`, `get_redeemable_
-- invitation`) reads and writes it, and it is used from
-- `lib/core/invitations/invitation_store_supabase.dart` — but nothing in
-- `service/` (the FastAPI backend) ever touches it. It duplicates
-- `interview_codes`, which the backend DOES use, with none of that path's
-- attempt-limit or window enforcement. Captured here because it is real,
-- live schema with real RLS policies protecting it — not because its
-- continued existence is endorsed. See the audit note on this table.

-- ============================================================================
-- Extensions this schema depends on
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;   -- gen_random_uuid()
create extension if not exists pg_net with schema extensions;     -- net.http_post(), called from trigger functions below
create extension if not exists pg_cron;                           -- reminder/intake-poll schedules (recreated separately, see above)

-- ============================================================================
-- Tables
-- ============================================================================

create table public.organizations (
  id text primary key default (gen_random_uuid())::text,
  name text not null,
  created_at timestamptz not null default now()
);

create table public.roles (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  title text not null,
  required_skills text[] not null default '{}',
  desirable_skills text[] not null default '{}',
  notes text,
  created_at timestamptz not null default now()
);

create table public.intakes (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  role_id text not null references public.roles(id) on delete cascade,
  name text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'paused', 'closed')),
  google_form_id text,
  application_url text,
  last_polled_response_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create unique index intakes_google_form_idx on public.intakes (google_form_id) where google_form_id is not null;
create index intakes_org_role_idx on public.intakes (organization_id, role_id);

create table public.candidates (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  name text not null,
  email text not null,
  resume_path text,
  created_at timestamptz not null default now(),
  role_id text references public.roles(id),
  preferred_time timestamptz,
  intake_id text references public.intakes(id) on delete set null,
  phone text,
  linkedin_url text,
  years_experience text,
  resume_link text,
  constraint candidates_org_email_unique unique (organization_id, email)
);

create table public.candidate_ai_profile (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id),
  candidate_id text not null unique references public.candidates(id) on delete cascade,
  processing_status text not null default 'UPLOADED'
    check (processing_status in (
      'UPLOADED', 'TEXT_EXTRACTED', 'STRUCTURED', 'CLAIMS_READY',
      'READY_FOR_INTERVIEW', 'FAILED'
    )),
  resume_text text,
  skills text[] not null default '{}',
  projects text[] not null default '{}',
  experience jsonb,
  claims jsonb,
  claim_extraction_kind text
    check (claim_extraction_kind is null or claim_extraction_kind in ('hosted_llm', 'local_llm', 'heuristic_rule')),
  degraded_reason text,
  embedding_id text,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  understanding_kind text
    check (understanding_kind is null or understanding_kind in ('hosted_llm', 'local_llm', 'heuristic_rule')),
  understanding_degraded_reason text,
  knowledge_profile jsonb
);

create index candidate_ai_profile_org_status_idx on public.candidate_ai_profile (organization_id, processing_status);

create table public.interview_sessions (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id),
  candidate_id text not null references public.candidates(id),
  status text not null default 'in_progress'
    check (status in ('not_started', 'in_progress', 'complete', 'abandoned')),
  role_title text not null,
  question_plan jsonb not null default '{}',
  coverage_state jsonb not null default '{}',
  outcomes jsonb not null default '{}',
  current_topic text,
  last_question text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index interview_sessions_candidate_idx on public.interview_sessions (candidate_id);
create index interview_sessions_org_idx on public.interview_sessions (organization_id);

create table public.interview_events (
  id bigint generated always as identity primary key,
  session_id text not null references public.interview_sessions(id) on delete cascade,
  sequence integer not null,
  event_type text not null,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  constraint interview_events_session_id_sequence_key unique (session_id, sequence)
);

create index interview_events_session_idx on public.interview_events (session_id);

create table public.interview_codes (
  id text primary key default (gen_random_uuid())::text,
  code text not null unique,
  organization_id text not null references public.organizations(id),
  candidate_id text not null references public.candidates(id),
  role_title text not null,
  required_skills text[] not null default '{}',
  difficulty text not null default 'standard',
  available_minutes integer not null default 20,
  status text not null default 'active'
    check (status in ('active', 'used', 'expired', 'revoked')),
  max_attempts integer not null default 3,
  attempts_used integer not null default 0,
  window_start timestamptz,
  window_end timestamptz,
  expires_at timestamptz not null,
  session_id text references public.interview_sessions(id),
  created_at timestamptz not null default now(),
  used_at timestamptz
);

create index interview_codes_candidate_idx on public.interview_codes (candidate_id);
create index interview_codes_code_idx on public.interview_codes (code);
create index interview_codes_org_idx on public.interview_codes (organization_id);

create table public.interview_code_emails (
  id text primary key default (gen_random_uuid())::text,
  code_id text not null references public.interview_codes(id) on delete cascade,
  organization_id text not null references public.organizations(id),
  email_type text not null check (email_type in ('invitation', 'reminder_1h', 'reminder_30m')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts integer not null default 0,
  last_error text,
  last_attempt_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interview_code_emails_code_id_email_type_key unique (code_id, email_type)
);

create index interview_code_emails_code_idx on public.interview_code_emails (code_id);

create table public.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

create table public.google_oauth_connections (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null unique references public.organizations(id) on delete cascade,
  google_account_email text not null,
  access_token text not null,
  refresh_token text not null,
  token_expires_at timestamptz not null,
  scope text not null,
  connected_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ORPHAN — see this file's header note. Duplicates interview_codes via a
-- separate, RPC/Edge-only redemption path with weaker enforcement. Captured
-- as real schema, not endorsed.
create table public.invitations (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  candidate_id text not null references public.candidates(id) on delete cascade,
  role_id text not null references public.roles(id) on delete cascade,
  code text not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'pending', 'accepted')),
  scheduled_at timestamptz,
  code_send_at timestamptz,
  reminder_send_at timestamptz,
  code_sent_at timestamptz,
  reminder_sent_at timestamptz,
  created_at timestamptz not null default now(),
  constraint invitations_organization_id_code_key unique (organization_id, code)
);

create index invitations_org_idx on public.invitations (organization_id);
create index invitations_pending_sends_idx on public.invitations (code_send_at, reminder_send_at)
  where status = 'scheduled';

-- Added by migration 0013 (organization_invites.sql) — the replacement for
-- joining an existing organization by name. See that file for full
-- rationale; repeated here only so this baseline is complete on its own.
create table public.organization_invites (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  email text not null,
  token_hash text not null unique,
  invited_by text,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create index organization_invites_org_idx on public.organization_invites (organization_id);
create unique index organization_invites_live_idx on public.organization_invites (organization_id, lower(email))
  where accepted_at is null;

-- ============================================================================
-- Functions
-- ============================================================================

-- The tenant boundary every RLS policy below calls. Reads app_metadata, NOT
-- user_metadata — see migration 0012_auth_org_from_app_metadata.sql for why
-- that distinction is the entire point of this function.
create or replace function public.auth_organization_id() returns text
  language sql
  stable
  set search_path to 'public', 'pg_temp'
as $function$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'organization_id', '')
$function$;

-- Allocates interview_events.sequence under a per-session advisory lock, so
-- concurrent event writes (the candidate portal fires several client-signal
-- events at once) can't both compute the same next value. See migration
-- 0011_interview_events_sequence_trigger.sql.
create or replace function public.assign_interview_event_sequence() returns trigger
  language plpgsql
  set search_path to 'public'
as $function$
begin
  if new.sequence is null then
    perform pg_advisory_xact_lock(hashtextextended(new.session_id, 0));
    select coalesce(max(sequence), 0) + 1
      into new.sequence
      from interview_events
     where session_id = new.session_id;
  end if;
  return new;
end;
$function$;

create or replace function public.touch_interview_session() returns trigger
  language plpgsql
  set search_path to 'public'
as $function$
begin
  new.updated_at = now();
  if new.status in ('complete', 'abandoned') and old.finished_at is null then
    new.finished_at = now();
  end if;
  return new;
end;
$function$;

create or replace function public.touch_candidate_ai_profile() returns trigger
  language plpgsql
  security definer
  set search_path to ''
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

create or replace function public.touch_interview_code_emails() returns trigger
  language plpgsql
  security definer
  set search_path to ''
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

create or replace function public.check_intake_role_org() returns trigger
  language plpgsql
as $function$
begin
  if new.organization_id <> (select organization_id from public.roles where id = new.role_id) then
    raise exception 'intake.organization_id must match roles.organization_id for role %', new.role_id;
  end if;
  return new;
end;
$function$;

-- Fires when a candidate row gains a resume_path — inserts (or resets) the
-- UPLOADED profile row and, if AI_GATEWAY_URL is configured, kicks off
-- /resumes/process. Swallows a gateway call failure on purpose: the
-- 'UPLOADED' row is the durable queue entry, not the HTTP call.
create or replace function public.trigger_resume_processing() returns trigger
  language plpgsql
  security definer
  set search_path to ''
as $function$
declare
  gateway_url text;
begin
  if new.resume_path is null then
    return new;
  end if;

  insert into public.candidate_ai_profile (organization_id, candidate_id, processing_status)
  values (new.organization_id, new.id, 'UPLOADED')
  on conflict (candidate_id) do update
    set processing_status = 'UPLOADED',
        error = null,
        updated_at = now();

  select value into gateway_url from public.app_config where key = 'ai_gateway_url';
  if gateway_url is null or gateway_url = '' then
    gateway_url := current_setting('app.settings.ai_gateway_url', true);
  end if;
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
    null;
  end;

  return new;
end;
$function$;

-- Fires when candidate_ai_profile.processing_status transitions INTO
-- READY_FOR_INTERVIEW (not merely updates while already there) and calls
-- /internal/candidates/{id}/auto-invite with the shared secret, so the
-- candidate is invited automatically. Also swallows delivery failure —
-- READY_FOR_INTERVIEW is the durable fact; an unreachable gateway must not
-- undo it.
create or replace function public.trigger_auto_invite() returns trigger
  language plpgsql
  security definer
  set search_path to ''
as $function$
declare
  gateway_url text;
  internal_secret text;
begin
  if new.processing_status is distinct from 'READY_FOR_INTERVIEW' then
    return new;
  end if;
  if old.processing_status is not distinct from 'READY_FOR_INTERVIEW' then
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
    null;
  end;

  return new;
end;
$function$;

-- Public, unauthenticated by design (the portal has no login) — the
-- FastAPI backend's own /roles/open route is this same read, exposed over
-- HTTP; this RPC is a second entry point to it used directly by the Flutter
-- app (lib/features/apply/apply_screen.dart).
create or replace function public.list_open_roles() returns table(id text, title text)
  language sql
  security definer
  set search_path to 'public', 'pg_temp'
as $function$
  select id, title from roles order by created_at desc;
$function$;

-- Part of the ORPHAN invitations/ path (see this file's header). Case-
-- insensitive code match, SECURITY DEFINER so an anonymous/candidate-side
-- caller can look up an invitation without needing row access otherwise.
create or replace function public.get_redeemable_invitation(p_code text)
  returns table(
    id text, organization_id text, candidate_id text, role_id text,
    code text, status text, created_at timestamptz,
    candidate_name text, candidate_email text
  )
  language sql
  security definer
  set search_path to 'public', 'pg_temp'
as $function$
  select i.id, i.organization_id, i.candidate_id, i.role_id, i.code, i.status,
         i.created_at, c.name, c.email
  from invitations i join candidates c on c.id = i.candidate_id
  where lower(i.code) = lower(p_code) and i.status = 'pending';
$function$;

-- Part of the ORPHAN invitations/ path. Marks an invitation accepted by
-- code, case-insensitive.
create or replace function public.accept_invitation(p_code text)
  returns table(
    id text, organization_id text, candidate_id text, role_id text,
    code text, status text, created_at timestamptz,
    candidate_name text, candidate_email text
  )
  language plpgsql
  security definer
  set search_path to 'public', 'pg_temp'
as $function$
begin
  return query
    update invitations i set status = 'accepted'
    from candidates c
    where c.id = i.candidate_id and lower(i.code) = lower(p_code) and i.status = 'pending'
    returning i.id, i.organization_id, i.candidate_id, i.role_id, i.code, i.status,
              i.created_at, c.name, c.email;
end;
$function$;

-- Called from the Flutter recruiter app right after registration
-- (lib/main.dart's _provisionOrganization) — currently unreachable from any
-- wired UI button (recruiter registration moved to the web portal; see
-- lib/features/auth/sign_in_screen.dart), but still a live, directly
-- callable RPC. Writes into app_metadata, not user_metadata — see migration
-- 0014_provision_organization_app_metadata.sql. The original version of
-- this function (pre-0014) wrote user_metadata only, which after migration
-- 0012 would have created an organization with no working access to it.
create or replace function public.provision_organization(org_name text) returns text
  language plpgsql
  security definer
  set search_path to 'public', 'pg_temp'
as $function$
declare
  new_org_id text;
begin
  if auth.uid() is null then
    raise exception 'must be signed in';
  end if;

  insert into organizations (name) values (org_name) returning id into new_org_id;

  update auth.users
    set raw_app_meta_data = raw_app_meta_data
      || jsonb_build_object('organization_id', new_org_id, 'role', 'recruiter')
    where id = auth.uid();

  return new_org_id;
end;
$function$;

-- ============================================================================
-- Triggers
-- ============================================================================

create trigger candidate_ai_profile_touch
  before update on public.candidate_ai_profile
  for each row execute function public.touch_candidate_ai_profile();

create trigger candidate_ready_for_interview
  after update on public.candidate_ai_profile
  for each row execute function public.trigger_auto_invite();

create trigger candidates_resume_uploaded
  after insert or update on public.candidates
  for each row execute function public.trigger_resume_processing();

create trigger intakes_role_org_consistency
  before insert or update on public.intakes
  for each row execute function public.check_intake_role_org();

create trigger interview_code_emails_touch
  before update on public.interview_code_emails
  for each row execute function public.touch_interview_code_emails();

create trigger interview_events_assign_sequence
  before insert on public.interview_events
  for each row execute function public.assign_interview_event_sequence();

create trigger interview_sessions_touch
  before update on public.interview_sessions
  for each row execute function public.touch_interview_session();

-- ============================================================================
-- Row Level Security
-- ============================================================================
--
-- Every table below: enabled, no bypass. All policies read
-- auth_organization_id() — see that function's own comment for why this
-- matters (migration 0012). The FastAPI backend uses the service-role key
-- for everything, which bypasses RLS entirely; these policies are what
-- actually protects the Flutter app's direct-to-Supabase reads/writes
-- (lib/core/*/*.dart), which run under the signed-in user's own JWT.

alter table public.organizations enable row level security;
create policy "org members read own org" on public.organizations
  for select using (id = auth_organization_id());

alter table public.roles enable row level security;
create policy "org members read own roles" on public.roles
  for select using (organization_id = auth_organization_id());
create policy "org members write own roles" on public.roles
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own roles" on public.roles
  for update using (organization_id = auth_organization_id());
create policy "org members delete own roles" on public.roles
  for delete using (organization_id = auth_organization_id());

alter table public.intakes enable row level security;
create policy "org members read own intakes" on public.intakes
  for select using (organization_id = auth_organization_id());
create policy "org members write own intakes" on public.intakes
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own intakes" on public.intakes
  for update using (organization_id = auth_organization_id());

alter table public.candidates enable row level security;
create policy "org members read own candidates" on public.candidates
  for select using (organization_id = auth_organization_id());
create policy "org members write own candidates" on public.candidates
  for insert with check (organization_id = auth_organization_id());

alter table public.candidate_ai_profile enable row level security;
create policy "org members read own candidate profiles" on public.candidate_ai_profile
  for select using (organization_id = auth_organization_id());
create policy "org members write own candidate profiles" on public.candidate_ai_profile
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own candidate profiles" on public.candidate_ai_profile
  for update using (organization_id = auth_organization_id());

alter table public.interview_sessions enable row level security;
create policy "org members read own interview sessions" on public.interview_sessions
  for select using (organization_id = auth_organization_id());
create policy "org members write own interview sessions" on public.interview_sessions
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own interview sessions" on public.interview_sessions
  for update using (organization_id = auth_organization_id());

alter table public.interview_events enable row level security;
create policy "org members read own interview events" on public.interview_events
  for select using (
    session_id in (select id from interview_sessions where organization_id = auth_organization_id())
  );
create policy "org members write own interview events" on public.interview_events
  for insert with check (
    session_id in (select id from interview_sessions where organization_id = auth_organization_id())
  );

alter table public.interview_codes enable row level security;
create policy "org members read own interview codes" on public.interview_codes
  for select using (organization_id = auth_organization_id());
create policy "org members write own interview codes" on public.interview_codes
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own interview codes" on public.interview_codes
  for update using (organization_id = auth_organization_id());

alter table public.interview_code_emails enable row level security;
create policy "org members read own interview code emails" on public.interview_code_emails
  for select using (organization_id = auth_organization_id());

alter table public.invitations enable row level security;
create policy "org members read own invitations" on public.invitations
  for select using (organization_id = auth_organization_id());
create policy "org members write own invitations" on public.invitations
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own invitations" on public.invitations
  for update using (organization_id = auth_organization_id());

-- Backend-only, service-role access exclusively — RLS enabled, zero
-- policies, same pattern as the two below.
alter table public.app_config enable row level security;
alter table public.google_oauth_connections enable row level security;
alter table public.organization_invites enable row level security;
