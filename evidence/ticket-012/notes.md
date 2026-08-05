# Ticket 12 — scheduler + staged reminder emails

## Deployed
`reminder-scheduler` Edge Function, ACTIVE, verify_jwt=false (shared-secret
header auth, x-scheduler-secret, since pg_cron/pg_net cannot mint a JWT either).
id: f3f41cf1-99ef-4b51-b6e0-bf938b6ec9be

## pg_cron
Job `reminder-scheduler-every-5-min`, schedule `*/5 * * * *`, calls the function
via pg_net http_post. Confirmed registered (`select jobname from cron.job`).

## Security advisors
Re-checked after adding this ticket's function. Found and fixed a real gap:
provision_organization (Ticket 10) was still anon-executable because the earlier
revoke targeted the anon role directly but missed the default PUBLIC grant every
Postgres function gets at creation -- anon inherits through PUBLIC unless PUBLIC
itself is revoked. Fixed (fix_provision_organization_grants migration). Remaining
advisor warnings are the two intentional candidate-facing RPCs
(get_redeemable_invitation, accept_invitation) -- expected, candidates have no
Supabase Auth session.

## Not yet verified end-to-end
Needs GMAIL_ADDRESS/GMAIL_APP_PASSWORD/SCHEDULER_SECRET set via `supabase secrets
set` (Devesh's own Gmail App Password -- not something to paste into chat, see
infra/README.md's Ticket 12 section) and a real invitation with code_send_at in
the past to confirm a send. Status: Completed, not yet Verified.

## flutter analyze / test
No issues found. 734 passed, 0 failed (unaffected -- no Dart files touched).
