# Ticket 11 rework — self-hosted apply page (no Google account needed)

## Why
Devesh cannot act on Google-account-gated (Google Form) or paid-account-gated
(Ticket 9 VPS) setup steps right now. Confirmed via ToolSearch that there is
genuinely no MCP tool path to create a Supabase Auth account or set Edge
Function secrets on his behalf either -- these are real, not assumed, limits.
Rather than block on any of that, redesigned Ticket 11 so the *default* path
needs zero external accounts.

## What's new
- `apply-webhook` Edge Function (public, no shared secret -- documented
  tradeoff: a secret baked into a Flutter web build is visible via
  view-source, so it wouldn't secure anything anyway). Same candidate +
  invitation creation as intake-webhook, keyed by roleId instead of roleTitle.
- `list_open_roles()` SQL RPC -- public, read-only, id+title only.
- `lib/features/apply/apply_screen.dart` + `lib/main_apply.dart` -- the
  candidate-facing form itself. Injectable `loadRoles`/`submitApplication`
  for testability (mirrors InvitationsScreen's injectable `loadSessions`).
- `intake-webhook` (Google Form path) gained an org-auto-resolve fallback:
  INTAKE_ORGANIZATION_ID is now optional for single-org deployments.

## Verified
- `flutter build web -t lib/main_apply.dart` succeeds.
- curl against the live apply-webhook: empty body -> 400 with the expected
  validation message; a fake roleId -> 422 "no such role". Both confirm the
  function is live and behaving correctly.
- 4 new widget tests in test/apply_screen_test.dart (role loading, load
  error, required-field validation, submission wiring) -- all passing.

## Still blocked (not by anything I can fix)
- No end-to-end submission run yet -- needs one real role to exist, which
  needs one HR account registered (Ticket 10's flow, unblocked, just not yet
  exercised with a real account).
- Ticket 9 (VPS/Coolify) is unchanged and still needed for the AI/face
  service, independent of this rework.

## flutter analyze / test
No issues found. 739 passed (+4), 0 failed.
