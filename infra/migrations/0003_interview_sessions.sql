-- Mirror of the live migration "interview_sessions_and_events" +
-- "fix_touch_interview_session_search_path", applied via the Supabase MCP.
-- Not authoritative — the live database is. Kept here for documentation.

create table interview_sessions (
  id text primary key default gen_random_uuid()::text,
  organization_id text not null,
  candidate_id text not null references candidates(id),
  status text not null default 'in_progress'
    check (status in ('not_started', 'in_progress', 'complete', 'abandoned')),
  role_title text not null,
  question_plan jsonb not null default '{}'::jsonb,
  coverage_state jsonb not null default '{}'::jsonb,
  outcomes jsonb not null default '{}'::jsonb,
  current_topic text,
  last_question text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index interview_sessions_candidate_idx on interview_sessions(candidate_id);
create index interview_sessions_org_idx on interview_sessions(organization_id);

create table interview_events (
  id bigint generated always as identity primary key,
  session_id text not null references interview_sessions(id) on delete cascade,
  sequence int not null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (session_id, sequence)
);

create index interview_events_session_idx on interview_events(session_id);

create or replace function touch_interview_session() returns trigger as $$
begin
  new.updated_at = now();
  if new.status in ('complete', 'abandoned') and old.finished_at is null then
    new.finished_at = now();
  end if;
  return new;
end;
$$ language plpgsql;

alter function touch_interview_session() set search_path = public;

create trigger interview_sessions_touch
  before update on interview_sessions
  for each row execute function touch_interview_session();

alter table interview_sessions enable row level security;
alter table interview_events enable row level security;

create policy "org members read own interview sessions" on interview_sessions
  for select using (organization_id = auth_organization_id());
create policy "org members write own interview sessions" on interview_sessions
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own interview sessions" on interview_sessions
  for update using (organization_id = auth_organization_id());

create policy "org members read own interview events" on interview_events
  for select using (
    session_id in (select id from interview_sessions where organization_id = auth_organization_id())
  );
create policy "org members write own interview events" on interview_events
  for insert with check (
    session_id in (select id from interview_sessions where organization_id = auth_organization_id())
  );

revoke execute on function touch_interview_session() from anon, authenticated, public;
