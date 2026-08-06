# Ticket 1 — Baseline Reality Check (Audit Only)

Date: 2026-08-05. No production code modified.

## Repository Health

- `flutter test`: **681 passing, 3 failing.**
- `flutter analyze`: **clean — "No issues found!"**

### The 3 failing tests
All in `test/preview/ui_preview_test.dart`: `home compact`, `home wide dark`, `home wide light`.
Root cause: **golden-image pixel mismatch** (0.26%, ~924px diff), NOT a crash or logic bug. These are screenshot-comparison tests whose reference PNGs are stale relative to current rendering. This is the "home-screen layout overflow papered over" item from prior memory. **Not a demo blocker** — cosmetic/golden drift only.

## Critical architectural finding: two different apps

`lib/main.dart` is the **actual running app**. It is a single-operator workspace: one `AppShell` with a flat destination list (Dashboard, Candidates, Roles, New session, Resume analysis, Sessions, Reports, Telemetry, Settings). Navigation is by `AppShellController.goTo(label)` and `Navigator.push`.

`lib/app/routes.dart` + `lib/core/rbac/route_guard.dart` (the RBAC table, `RouteResolver`, recruiter vs candidate `/hr/*` `/candidate/*` split) is the **enterprise blueprint's** navigation model. It is **completely unwired** — `grep` for `RouteResolver`/`AppRoutes` across `lib` (excluding the two files themselves) returns **zero references**. It is exercised only by its own unit tests.

**Implication for the roadmap:** the running demo app has NO recruiter/candidate role separation today. It's a single-user tool. Ticket 2 (RBAC wiring) is therefore **not** the next priority — wiring a two-role router into a single-operator app is a large structural change that does not make the current demo stronger. It goes to the backlog. This overturns the tentative Ticket 2 in the plan, exactly as the "verify before modifying" rule intends.

## Demo Workflow Status Map

Mapped against the app that actually runs (`lib/main.dart`), single-operator flow:

| Stage | Status | Notes |
|---|---|---|
| Recruiter creates a job | **Working (as "Roles")** | `RolesScreen` create/save/delete via `roleStore`. No separate "recruiter" identity — it's the operator. |
| Candidate applies / invite | **Missing** | No invitation or candidate-application concept in the running app. Exists only in the unwired blueprint. |
| Resume upload | **Working** | `ResumeAnalysisScreen` + `SessionDraft` read a resume file. |
| Claim extraction | **Working** | `SessionDraft` runs `claim_extractor` on the resume → editable/confirmable claims. Falls back to demo claims if no resume. |
| Interview (identity + adaptive) | **Working** | `InterviewScreen` with enrolled embedding, continuous verification, follow-ups. Enrol-then-interview path present. |
| Evidence collected | **Working** | Claim audit + evidence graph screens driven by the session. |
| Transparent report | **Working** | `ReportsScreen` renders audits (currently shows a sample audit alongside real ones). |

## Top 3 blockers to a clean end-to-end demo

1. **The demo narrative vs. the app's shape.** The plan's Demo Scenario is a recruiter↔candidate two-actor story; the running app is a single operator doing every step. Decision needed (see below) before any workflow ticket makes sense.
2. **No connecting thread from "Roles" → a specific candidate → their interview → their report.** Screens work individually but a job/role is not bound to the session that follows, so the walkthrough doesn't read as one continuous case.
3. **Golden tests fail on any UI touch.** Every future UI ticket will trip these 3 stale goldens, muddying the "tests green" gate. Cheap to regenerate, but must be done deliberately, not silently.

## Ordered implementation backlog (draft — pending the Q below)

```
Priority | Ticket | Workflow Stage | Severity | ETA | Status
P1 | Regenerate 3 stale home goldens so the suite is green | Repo Health | High | 20 min | Open
P2 | Bind a selected Role → New session → its report (one continuous case) | Cross-stage | High | 90 min | Open
P3 | Seed a demo profile (known role + resume + enrolment) for repeatable runs | Demo Mode | Medium | 60 min | Open
```

Backlog (deferred): RBAC/two-role router wiring, invitation/candidate-application flow — both belong to the enterprise blueprint and do not strengthen the single-operator demo.
