# Ticket 10 — HR app → Supabase-backed stores + real login

## flutter analyze
No issues found!

## flutter test
734 passed, 0 failed (down from 736: -5 for removed demo_seed_test.dart which
tested pre-auth seeding logic that no longer exists, +2 for three new
sign_in_gate_test.dart cases replacing the one "demo button" test, net -3 tests
but +734 total reflects other suite growth already committed in Tickets 8-9).

## What changed
- SupabaseRoleStore / SupabaseInvitationStore implement the existing
  RoleStore/InvitationStore interfaces against the cognihire Supabase project.
  No screen code changed — invitations_screen.dart, roles_screen.dart, etc.
  are unaffected, per the interface seam already in place.
- SupabaseAuthStore (already coded, previously unwired) is now the real HR
  sign-in path in sign_in_screen.dart, replacing the one-click demo button.
- provision_organization RPC (Ticket 8 migration) handles the chicken-and-egg
  problem of a brand new HR account having no organization_id yet.
- get_redeemable_invitation / accept_invitation RPCs (replacing the earlier
  single-mutation redeem_invitation from Ticket 8) let a candidate redeem a
  code with no Supabase Auth account, matching InvitationStore's two-step
  findRedeemable -> saveInvitation contract under RLS.
- Removed seedDemoDataIfEmpty: it wrote to RoleStore/InvitationStore before
  any HR sign-in existed, which cannot pass org-scoped RLS against a real
  shared backend. Demo seeding becomes a post-login concern for a later
  ticket, not a startup side effect against production data.
- service/main.py's CORS TODO fixed alongside Ticket 9 (ALLOWED_ORIGINS env
  var instead of hardcoded "*").
