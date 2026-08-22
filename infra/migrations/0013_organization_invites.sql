-- Joining an existing organization requires an invitation.
--
-- `/auth/signup` used to look an organization up by NAME and, if it existed,
-- create a confirmed HR account inside it. Organization names are published
-- by the unauthenticated `/roles/open`, so the full path from stranger to
-- full recruiter access to a named company was two HTTP requests and no
-- vulnerability beyond the intended behaviour. Signup now creates a NEW
-- organization only; this table is the sole way into an existing one.
--
-- The token is stored as a SHA-256 hash, not in the clear. `interview_codes`
-- stores its code plainly and that is a defensible call for an 8-character
-- value a candidate types off a screen, but an invite grants standing access
-- to a company's entire hiring pipeline — a database dump should not be a
-- pile of usable invitations. The raw token is returned exactly once, at
-- creation, and never recoverable afterwards.
--
-- `email` is bound at creation and checked at redemption: an invite is for a
-- specific person, not a shareable link that anyone who sees it can spend.
--
-- Backend-only, so RLS is on with zero policies (same pattern as app_config
-- and google_oauth_connections): no anon or authenticated client can read or
-- write an invitation directly. Only the service role, through the API, can.

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

create index organization_invites_org_idx on public.organization_invites(organization_id);

-- One live invite per (org, email): re-inviting someone replaces rather than
-- accumulates, so revoking access does not mean hunting down five rows.
create unique index organization_invites_live_idx
  on public.organization_invites(organization_id, lower(email))
  where accepted_at is null;

alter table public.organization_invites enable row level security;
-- No policies: backend-only, service-role access exclusively.
