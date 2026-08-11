-- Mirror of the live migration "google_oauth_connections" applied via the
-- Supabase MCP. Not authoritative -- the live database is.
--
-- Per-organization Google OAuth connection (Part 8 of the intake work: each
-- company connects its OWN Google account, not one CogniHire-owned account).
-- Backend/service-role only -- same pattern as app_config: RLS enabled, zero
-- policies, so no anon/authenticated client can read a token directly.
-- Recruiters only ever see {connected, google_account_email} via a status
-- endpoint, never the tokens themselves.

create table public.google_oauth_connections (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id) on delete cascade,
  google_account_email text not null,
  access_token text not null,
  refresh_token text not null,
  token_expires_at timestamptz not null,
  scope text not null,
  connected_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id)
);

alter table public.google_oauth_connections enable row level security;
-- No policies: backend-only configuration, matching app_config.
