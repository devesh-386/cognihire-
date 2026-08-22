-- Tenancy stops trusting a field the user can write.
--
-- `auth_organization_id()` is the single function every RLS policy in this
-- database calls to decide which organization the caller belongs to. It read
-- `user_metadata`, which in GoTrue is the user's OWN metadata: any signed-in
-- user can rewrite it with their own access token
-- (`supabase.auth.updateUser({ data: { organization_id: ... } })`, i.e.
-- PUT /auth/v1/user). So every policy on candidates, candidate_ai_profile,
-- interview_codes, interview_sessions, interview_events, intakes, roles and
-- organizations was keyed on a value the attacker supplies.
--
-- `app_metadata` is the service-role-only counterpart — GoTrue refuses to let
-- a user write it with their own token, and it is carried in the JWT the same
-- way, so policies keep working unchanged. This is the one-line difference
-- between "the token asserts who you are" and "the token grants what you may
-- read".
--
-- The backend (service/main.py `_require_org`) and the Flutter client
-- (lib/core/auth/supabase_auth_store.dart) read the same claim and move in
-- the same commit. No fallback to `user_metadata` is kept anywhere: a
-- fallback would preserve exactly the bypass this migration exists to close.
--
-- ROLLOUT ORDER — this migration is NOT safe to apply on its own:
--   1. Backfill app_metadata for existing users first (additive, breaks
--      nothing):  python tool/migrate_org_to_app_metadata.py
--   2. Apply this migration.
--   3. Deploy the service + client that read app_metadata.
--   4. Sign every existing session out, so no token minted before step 1 is
--      still accepted.
-- Applying this before step 1 leaves RLS resolving NULL for every caller,
-- which fails closed (no rows) rather than open — recoverable, but it is an
-- outage.

create or replace function public.auth_organization_id() returns text
  language sql
  stable
  set search_path to 'public', 'pg_temp'
as $function$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'organization_id', '')
$function$;
