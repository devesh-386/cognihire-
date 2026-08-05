# Ticket 11 — Google Form intake → Supabase

## Deployed
`intake-webhook` Edge Function, ACTIVE, verify_jwt=false (auth is a shared-secret
header instead, since Apps Script cannot mint a Supabase user JWT).
id: 6afef274-d658-461b-ac40-3caba9005bf7

## What it does
Given {secret, name, email, roleTitle, preferredTimeIso, resumeBase64?, resumeFilename?}:
- Checks the shared secret against INTAKE_WEBHOOK_SECRET.
- Resolves roleTitle to a Role in INTAKE_ORGANIZATION_ID (case-insensitive exact match).
- Uploads the résumé to the resumes bucket (if provided).
- Creates a candidates row and a scheduled invitations row with code_send_at =
  scheduled_at - 60min, reminder_send_at = scheduled_at - 30min already computed,
  so Ticket 12's scheduler only has to poll and send.

## Not yet verified end-to-end
Needs a real Google Form + Apps Script trigger (infra/google-form-apps-script.gs)
and the two secrets set (infra/README.md's Ticket 11 section) -- the second secret,
INTAKE_ORGANIZATION_ID, can't be set until Devesh registers an HR account (Ticket 10)
and an organizations row exists. Status: Completed, not yet Verified.

## flutter analyze / test
No issues found. 734 passed, 0 failed (unaffected -- no Dart files touched).
