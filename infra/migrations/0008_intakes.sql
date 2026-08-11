-- Mirror of the live migration "intakes" applied via the Supabase MCP.
-- Not authoritative -- the live database is. Kept here so schema history is
-- readable from the repo without a Supabase session, matching 0003-0007.
--
-- Multi-tenant intake concept: a specific hiring campaign for a role
-- ("Backend Engineer -- August 2026"), so two campaigns for the same role
-- (or two orgs with the same role title) never collide. Every candidate
-- must have an unambiguous ownership path: organization -> role -> intake.

create table public.intakes (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  role_id text not null references public.roles(id) on delete cascade,
  name text not null,
  status text not null default 'draft'
    check (status in ('draft', 'active', 'paused', 'closed')),
  google_form_id text,
  application_url text,
  last_polled_response_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

-- organization_id is denormalized (matches every other org-scoped table in
-- this schema, e.g. candidate_ai_profile, interview_code_emails) so RLS stays
-- a flat equality check instead of a join -- but denormalization only helps
-- if it can never drift from the truth, so a trigger enforces it can't.
create function public.check_intake_role_org() returns trigger as $$
begin
  if new.organization_id <> (select organization_id from public.roles where id = new.role_id) then
    raise exception 'intake.organization_id must match roles.organization_id for role %', new.role_id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger intakes_role_org_consistency
  before insert or update on public.intakes
  for each row execute function public.check_intake_role_org();

create index intakes_org_role_idx on public.intakes(organization_id, role_id);
create unique index intakes_google_form_idx on public.intakes(google_form_id) where google_form_id is not null;

alter table public.intakes enable row level security;

create policy "org members read own intakes" on public.intakes
  for select using (organization_id = auth_organization_id());
create policy "org members write own intakes" on public.intakes
  for insert with check (organization_id = auth_organization_id());
create policy "org members update own intakes" on public.intakes
  for update using (organization_id = auth_organization_id());
-- No delete policy: closing an intake is status='closed', matching how
-- interview_codes uses status='revoked' instead of row deletion elsewhere
-- in this schema.

-- Nullable permanently: existing candidates predate intakes and stay
-- intake_id = NULL rather than being backfilled into a fabricated intake.
alter table public.candidates
  add column intake_id text references public.intakes(id) on delete set null;

-- Both were plain text with no FK, unlike every other organization_id
-- column in this schema. Additive and safe -- verified zero orphaned
-- organization_id values in either table before adding these.
alter table public.interview_codes
  add constraint interview_codes_organization_id_fkey
  foreign key (organization_id) references public.organizations(id);
alter table public.interview_sessions
  add constraint interview_sessions_organization_id_fkey
  foreign key (organization_id) references public.organizations(id);
