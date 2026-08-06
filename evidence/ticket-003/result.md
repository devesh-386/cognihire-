# Ticket 3 — Name the screened role in the report title

## Objective
Make a role-targeted screening read as one continuous case: the finished report should name the role the candidate was screened for.

## Finding (verify-before-modify)
The connecting thread was already ~90% built: `SessionDraft.targetRole` exists, the setup screen has a role picker, and `effectiveClaims` already reorders the claim queue by the role's required skills. The only gap was that the **saved report title** dropped the role — it showed only the candidate label.

## Change (smallest valuable change, no schema touch)
- Added `SessionDraft.sessionTitle`: appends the role title to the operator's label when a role is picked (`"Jane Doe — Senior Backend"`), else just the label.
- Pointed both interview launch sites in `main.dart` at `sessionTitle` instead of the bare `label`.
- Deliberately did NOT add a role field to `ClaimAudit`/its JSON codec — that would touch the persistence model and risk the suite. The role composes into the existing label instead.

## Verification
- New test `test/session_draft_title_test.dart`: 4 cases (placeholder, label-only, label+role, placeholder+role) — all pass.
- `flutter analyze`: clean.
- Full suite: **688 passing, 0 failing** (684 → +4 new). No regressions.
- Commit: `b2675b9`.

## Not yet done
Manual UI run of the full flow (define role → resume → interview → report) to visually confirm the title renders — pending a live `flutter run` session.
