# CogniHire — Module Documentation

**Status as of 2026-08-28.** Verified against the repository, not against design documents.
Where a module is only partially wired, this document says so.

---

## System surfaces

CogniHire is four deployed surfaces plus a managed database:

| Surface | Technology | Deployment | Role |
|---|---|---|---|
| `service/` | FastAPI (Python) | Azure VM behind Coolify — `api.cognihire.online` | All backend logic. 42 routes. |
| `portal/` | Next.js 15 / React 19 | Vercel — `cognihire.online` | Candidate experience + recruiter web workspace |
| `lib/` | Flutter (Dart) | Windows desktop | Recruiter application |
| `infra/` | Supabase + Deno edge functions | Supabase (ap-south-1) | Database, storage, intake webhooks, schedulers |

`archive/flutter-candidate-code/` holds the candidate-facing Flutter code removed when the app
became recruiter-only. The candidate experience now lives entirely in `portal/`.

`docker-compose.dev-infra-unused.yml` (Postgres/Redis/MinIO/Caddy) is **not** what runs and is
retained only for a possible future self-hosted path.

---

## Module map

```
                    ┌──────────────────────────────────────┐
   Google Form ──┐  │  M1  Candidate Intake  (4 entrypoints)│
   Forms poller ─┼─▶│      → one pipeline                   │
   Apply page ───┤  └──────────────┬───────────────────────┘
   Portal apply ─┘                 ▼
                    ┌──────────────────────────────────────┐
                    │  M2  Résumé Processing               │
                    │      PDF → text → structured         │
                    └──────────────┬───────────────────────┘
                                   ▼
                    ┌──────────────────────────────────────┐
                    │  M3  Claim Extraction                │
                    │      ┌────────────────────────────┐  │
                    │      │ M13 Grounding Gate         │  │◀── architectural boundary
                    │      │ verbatim-only, no authoring│  │    enforced by test
                    │      └────────────────────────────┘  │
                    └──────────────┬───────────────────────┘
                                   ▼
                    ┌──────────────────────────────────────┐
                    │  M4  Interview Codes + Email         │
                    └──────────────┬───────────────────────┘
                                   ▼
        ┌──────────────────────────┴───────────────────────┐
        ▼                                                   ▼
┌─────────────────────┐                        ┌─────────────────────────┐
│ M6  Candidate Portal│───▶│ M8 Face Check │   │ M5  Interview Engine    │
│     device check    │    │  (presence)   │◀──│     + turn planning     │
│ M7  Voice Interview │◀───────────────────────│                         │
└─────────────────────┘                        └───────────┬─────────────┘
                                                            ▼
                    ┌──────────────────────────────────────┐
                    │  M10 Report Generation               │
                    │      Claim → Evidence → Verdict      │
                    │      (deterministic, not an LLM call)│
                    └──────────────┬───────────────────────┘
                                   ▼
                    ┌──────────────────────────────────────┐
                    │  M9  Recruiter App  — human decides  │
                    └──────────────────────────────────────┘

Cross-cutting: M11 Auth/Tenancy/RBAC · M12 Database/Storage · M13 LLM Gateway + Grounding
               M14 Security Guardrails · M15 Deployment/Infra
```

---

## M1 — Candidate Intake ✅ Implemented

**Four entry points converge on one pipeline.** This is deliberate: multiple ways for a candidate to
arrive, exactly one path they travel afterwards. Adding a second *pipeline* is prohibited; adding a
second *trigger* is fine.

| Entry point | Implementation |
|---|---|
| Google Form (push) | `infra/google-form-apps-script.gs` → `infra/intake-webhook/index.ts` |
| Google Forms (poll) | `infra/intake-form-poller/index.ts`, pg_cron driven |
| Self-hosted apply page | `infra/apply-webhook/index.ts` |
| Portal self-registration | `service/candidates/self_registration.py`, `POST /candidates/apply` |

The webhook resolves `formId` against `intakes.google_form_id`, so organisation and role come from
the intake row rather than from fuzzy title matching (a title-guessing fallback was deliberately
removed). Writes use the service role and bypass RLS by design.

**Files:** `infra/intake-webhook/`, `infra/intake-form-poller/`, `infra/apply-webhook/`,
`service/google_integration/forms.py`, `service/google_integration/oauth.py`,
`lib/features/intakes/intakes_screen.dart`, migration `0008_intakes.sql`.

---

## M2 — Résumé Processing ✅ Implemented

Pipeline: **upload → text extraction → structured parse → knowledge profile**.

Status ladder recorded in `candidate_ai_profile.processing_status`:

```
UPLOADED → TEXT_EXTRACTED → STRUCTURED → CLAIMS_READY → READY_FOR_INTERVIEW
                                                     ↘ FAILED
```

A deterministic heuristic parser (`service/deterministic/resume_parser.py`) runs when no LLM is
available, so the pipeline degrades rather than stops. Degradation is recorded in
`degraded_reason`, never hidden.

**Files:** `service/deterministic/pdf_extraction.py`, `service/deterministic/resume_parser.py`,
`service/ai/resume_understanding.py`, `service/ai/knowledge_profile.py`,
`service/pipeline/profile_builder.py`. **Endpoint:** `POST /resumes/process`.

---

## M3 — Claim Extraction ✅ Implemented

Converts résumé text into discrete, verifiable claims. The LLM proposes; the grounding gate
(M13) disposes.

Provenance is recorded per extraction as
`claim_extraction_kind ∈ {hosted_llm, local_llm, heuristic_rule}` — a reader of any claim can always
tell how it was produced.

Taxonomy (Dart, `lib/core/interview/question_bank.dart`):
`ClaimType ∈ {builtArtifact, usedTool, heldRole, achievedOutcome}`. Eleven types were proposed and
cut to four on the rule that *a type only exists if it changes the question you would ask*.

**Files:** `service/ai/claim_extraction.py` (runtime), `lib/core/claims/` (recruiter-app path).
**Endpoint:** `POST /extract-claims`.

---

## M4 — Interview Codes and Email Workflow ✅ Implemented

Single-use, expiring, revocable codes plus a staged email workflow.

⚠️ **Two distinct concepts — do not conflate:**
- `interview_codes` — candidate redemption codes. The live interview path.
- `invitations` / `organization_invites` — recruiter-side organisation invitations.

Expiry and revocation are enforced in the database (`0018`, `0019`), not only in application code:
revoking a code stops an interview already in progress.

**Files:** `service/session/interview_codes.py`, `service/session/codes_store.py`,
`service/notifications/{workflow,delivery,provider,store,templates}.py`,
`infra/reminder-scheduler/index.ts` (pg_cron, every 5 min).

---

## M5 — Interview Engine and Turn Planning ✅ Implemented

Plans and runs an adaptive interview. The plan is built from the **knowledge profile and grounded
claims — never from raw résumé text**, which structurally prevents a résumé from injecting
instructions into the planner.

Question plans are **deliberately not persisted** (`service/ai/question_planning.py`).

Session state is event-sourced into `interview_events`, an append-only table with a
sequence-assigning trigger (migration `0011`).

**Files:** `service/ai/question_planning.py`, `service/ai/interview.py`,
`service/ai/answer_analysis.py`, `service/ai/coverage_manager.py`,
`service/ai/evidence_linking.py`, `service/session/interview_session.py`,
`service/session/state_machine.py`.
**Endpoints:** `/interview/start`, `/interview/answer`, `/interview/event`, `/interview/finish`.

---

## M6 — Candidate Portal ✅ Implemented

Next.js 15 / React 19 on Vercel. Candidate journey: **apply → interview code → device check → live
interview → completion**. Also hosts the recruiter web workspace (dashboard, candidates, interviews,
roles, reports, settings) and the marketing/legal pages.

All backend traffic passes through a single boundary module, `portal/lib/gateway.js` — no component
calls the API directly.

**Files:** `portal/app/apply/`, `portal/app/interview/`, `portal/app/(workspace)/`,
`portal/components/candidate/{apply-form,interview-code-form,interview-flow}.tsx`.

---

## M7 — Voice Interview ✅ Implemented

WebSocket relay between the candidate's browser and the OpenAI Realtime API.

**The critical design point:** OpenAI is used **only** as voice activity detection, speech-to-text,
and text-to-speech. `turn_detection.create_response = false` — the Realtime model never decides what
to say. Every spoken question originates from `interview_session.answer()` in M5.

Degrades gracefully: Web Speech API, then typed answers. The typed path is first-class, not a
consolation.

**Files:** `service/session/live_interview.py`, `portal/lib/live-voice-client.js`,
`portal/public/mic-capture-worklet.js` (24 kHz PCM).
**Endpoint:** `WS /interview/live/{session_id}`.

---

## M8 — Face / Identity Verification ⚠️ Partially wired

**Read this section carefully before presenting it.**

**What is implemented and live:** `POST /face/analyze` decodes the frame with OpenCV, measures
brightness and sharpness, runs InsightFace `buffalo_l` (detection + recognition only), and returns a
512-dimensional embedding. Body capped at 8 MB, rate-limited.

**What the production path actually uses:** `portal/components/candidate/interview-flow.tsx`
(~line 143) keeps only `{face_detected, engine_available, brightness, sharpness}` and **discards the
embedding**. In production this is a **presence and capture-quality gate at device check** — not
continuous identity verification.

**What exists but is not on the live path:** the complete matching stack in `lib/core/verification/`
— `identity_matcher.dart` (cosine similarity, threshold, display confidence),
`verification_session.dart` (jittered 15–25 s re-check loop, strike counter),
`platt_scaler.dart`, `biometric_metrics.dart`. Fully unit-tested; no construction site on the
candidate path.

**The threshold is now calibrated** on LFW (0.1266; FAR 0.030 / FRR 0.034 — see `DATASET.md` §3.1),
which closes a deliverable promised at Review 2. **Wiring the calibrated matcher into the portal
session is the single largest remaining piece of work.**

The `VerificationResult` type is a sealed `Verified` / `Mismatch` / `Unchecked`. `Unchecked` carries
a reason and has **no similarity field at all**, so a failed measurement is structurally incapable of
being read as a pass.

---

## M9 — Recruiter Application ✅ Implemented

Flutter desktop, recruiter-only. Dashboard, roles, candidates, invitations, intakes, interview
sessions, reports, audit, reviewer, evidence graph, settings.

`lib/app/routes.dart` still declares `/candidate/*` routes; these are permission-table rows retained
for the RBAC test, not live screens.

**Build note:** `lib/core/config.dart` defaults every URL to localhost. A plain
`flutter build windows --release` silently bakes those in and produces an executable that can never
reach production. Always:

```bash
flutter build windows --release --dart-define=FACE_SERVICE_URL=https://api.cognihire.online --dart-define=PORTAL_URL=https://cognihire.online
```

---

## M10 — Report Generation ✅ Implemented

**Deliberately not a model call.** `service/ai/report_generation.py` reshapes evidence-linking output
into per-topic **Claim → Evidence → Verdict** rows plus explicitly uncovered topics.

No score. No ranking. No hire recommendation. Verdicts are
`substantiated / notDemonstrated / contradicted / notExamined` — and `notExamined` exists precisely
so that "we did not measure this" can never be silently rendered as "this passed."

**Files:** `service/ai/report_generation.py`, `portal/app/(workspace)/reports/[sessionId]/page.tsx`,
`lib/features/reports/`, `lib/core/export/audit_export.dart`.
**Endpoints:** `GET /interview/report/{session_id}`, `GET /reports`.

---

## M11 — Authentication, Tenancy and RBAC ✅ Implemented

**Default-deny ASGI middleware** (`service/security/access_control.py`) with an explicit, reviewed
`PUBLIC_PATHS` list. Matching happens on the ASGI scope, so **a newly added route is private unless
someone deliberately lists it** — the failure mode is a locked door, not an open one.

Tenancy: `organization_id` lives in Supabase `app_metadata` (not user-editable metadata) and is read
by `_require_org()`. Row-level security policies enforce org scoping at the database.

**Files:** `service/security/access_control.py`, `service/security/rate_limit.py`,
`lib/core/rbac/{permission,permissions,route_guard}.dart`, migrations `0012`, `0014`.

---

## M12 — Database and Storage ✅ Implemented

Supabase PostgreSQL, **13 tables across 20 migrations** (`0000_baseline` → `0019`):

`organizations` · `roles` · `candidates` · `candidate_ai_profile` · `interview_sessions` ·
`interview_events` · `interview_codes` · `interview_code_emails` · `invitations` ·
`organization_invites` · `intakes` · `google_oauth_connections` · `app_config`

Résumé binaries in Supabase Storage, org-scoped. Google OAuth tokens encrypted at rest
(`service/security/token_crypto.py`).

**Files:** `infra/migrations/`, `service/pipeline/supabase_store.py`.

---

## M13 — LLM Gateway and Grounding Gate ✅ Implemented

**The architectural centrepiece of the project.**

`service/ai/provider.py` is the **only** module permitted to contact a model vendor. Default
`gpt-4o-mini`; Ollama `qwen2.5:7b` as the alternate. Retries on 429/5xx with backoff capped at 5 s,
because a candidate is waiting live.

`service/deterministic/grounding.py` is the gate. It performs clause-scoped matching with negation
and hedge rejection — "I have *not* worked with Kubernetes" does not become a Kubernetes claim — and
contrastive-conjunction splitting.

**The invariant: the AI may select claim text; it may never author it.**

This is enforced structurally, not by discipline: `grounding.py` is **forbidden from importing
`service/ai/`**, and `service/test_architecture_boundary.py` **fails CI** if anyone tries. The
guarantee is a property of the build, not of anyone's care.

---

## M14 — Security Guardrails ✅ Implemented

| Control | Implementation |
|---|---|
| Default-deny routing | `access_control.py` middleware |
| Rate limiting | `rate_limit.py`, per-route |
| Token encryption at rest | `token_crypto.py` |
| Signed OAuth state | `_sign_state` / `_verify_state`, expiring + single-use |
| Internal route auth | `INTERNAL_AUTOINVITE_SECRET` |
| Demo route gating | `_require_non_production()` |
| Production boot refusal | Service refuses to start without `PORTAL_URL` |
| Upload bounds | 8 MB frame cap, path-traversal-safe filenames |
| WebSocket origin check | on `/interview/live/` |

**Audit result (2026-08-24, `.gstack/security-reports/`):** 10 findings — 5 HIGH, 5 MEDIUM —
**9 fixed, 1 mitigated**, each with OWASP category, `file:line`, and fixing commit. Attack surface:
17 public endpoints, 23 authenticated, 3 upload paths, 5 integrations, 1 WebSocket.

CI guardrails (`.github/workflows/guardrails.yml`) fail the build on a planted composite-score field
(ED-46 vocabulary ban) and on a planted evidence↔disposition join (ED-45).

---

## M15 — Deployment and Infrastructure ✅ Implemented

| Component | Detail |
|---|---|
| Backend | Docker on Azure VM behind Coolify, `docker-compose.api.yml` |
| Dependencies | Hash-pinned `requirements.lock` |
| Model cache | Named volume `insightface-models:/root/.insightface` (~300 MB) |
| Frontend | Vercel, `portal/.env.production` |
| CI | `.github/workflows/test.yml` + `guardrails.yml` |
| CD | `deploy.yml`, gated on Tests via `workflow_run` |

The deploy workflow asserts freshness **twice** — the VM-local `/health` must report the exact
deployed `git_sha`, and then the public endpoint must too. A build that silently failed to replace
the running container cannot report success.

---

## Implementation status summary

| # | Module | Status |
|---|---|---|
| M1 | Candidate Intake | ✅ Implemented (4 entry points) |
| M2 | Résumé Processing | ✅ Implemented |
| M3 | Claim Extraction | ✅ Implemented |
| M4 | Interview Codes + Email | ✅ Implemented |
| M5 | Interview Engine | ✅ Implemented |
| M6 | Candidate Portal | ✅ Implemented |
| M7 | Voice Interview | ✅ Implemented (with typed fallback) |
| M8 | Face / Identity Verification | ⚠️ **Partially wired** — presence gate live; calibrated matcher not yet on the candidate path |
| M9 | Recruiter Application | ✅ Implemented |
| M10 | Report Generation | ✅ Implemented (deterministic by design) |
| M11 | Auth / Tenancy / RBAC | ✅ Implemented |
| M12 | Database / Storage | ✅ Implemented |
| M13 | LLM Gateway + Grounding | ✅ Implemented, boundary test-enforced |
| M14 | Security Guardrails | ✅ Implemented, externally audited |
| M15 | Deployment / Infra | ✅ Implemented |

**Test coverage:** 689 Dart tests, 417 Python tests, 6 portal tests. `flutter analyze` clean.
CI green on `main`.

---

## Known gaps, stated openly

1. **M8 is a presence gate in production.** The calibrated matcher is built, tested, and now has
   real FAR/FRR numbers behind it — but it is not wired into the portal session. Do not describe the
   system as performing continuous identity verification today.
2. **The résumé-fit model is not on the runtime path** (`DATASET.md` §3.2). Production similarity
   uses an unfitted `_MATCH_FLOOR = 0.5`.
3. **Portal test coverage is one file.** The candidate surface carries the least automated testing.
4. **No recruiter validation interviews yet** — the largest untested product assumption, carried
   over from the Review 2 way-forward plan.
