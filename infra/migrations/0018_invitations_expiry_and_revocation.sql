-- Harden `invitations` to the same enforcement bar as `interview_codes`
-- (revocation, expiry) — user decision this session, after confirming
-- invitations_screen.dart is a live, wired feature, not the orphan an
-- earlier audit believed.
--
-- `invitations` has THREE independent producers/consumers, not one:
--   1. invitations_screen.dart (Flutter, HR manual invite) — inserts
--      status='pending' directly, redeemed via the accept_invitation/
--      get_redeemable_invitation SECURITY DEFINER RPCs (candidates have
--      no auth session at all).
--   2. infra/apply-webhook (Edge Function, public, no shared secret by
--      design — see its own header comment) — inserts status='scheduled'
--      with scheduled_at/code_send_at/reminder_send_at.
--   3. infra/reminder-scheduler (Edge Function, pg_cron every 5 min,
--      SCHEDULER_SECRET-gated) — polls scheduled/pending rows and sends
--      the code/reminder emails, advancing scheduled -> pending.
--
-- `expires_at` is nullable, not backfilled: existing rows and anything the
-- two Edge Functions insert without it keep working exactly as before
-- (nullable = "no expiry", the same as never having this column). Only
-- new code that explicitly sets it gains the protection. `revoked` needs
-- no new RPC — HR already has RLS UPDATE access to invitations
-- (`org members update own invitations`), so revoking is a plain
-- authenticated status update; once a row leaves 'scheduled'/'pending' the
-- reminder-scheduler's own status filters already exclude it from ever
-- emailing a revoked invitation, no Edge Function change required for that
-- half.

alter table invitations
  add column expires_at timestamptz;

alter table invitations drop constraint invitations_status_check;
alter table invitations add constraint invitations_status_check
  check (status in ('scheduled', 'pending', 'accepted', 'revoked'));
