# CogniHire — Architecture Discovery Report

**Generated:** 2026-07-31 · **Scope:** `C:\claude\cognihire` as it exists on disk right now · **Method:** direct code reading + 4 parallel independent audits, all citations verified against source, `file:line` throughout.

**Ground rules followed:** no marketing language, no vision summary. Implemented is called implemented. Planned-but-not-built is called planned. Mocked/synthetic is called mocked/synthetic. Dead code is called dead. Nothing here is guessed — where something couldn't be verified in the time available, that is stated explicitly rather than inferred.

**Repo stats:** 104 files / 24,885 LOC under `lib/`, 63 test files / 10,622 LOC under `test/`, single squashed git commit (`b55acba`, no incremental history to audit), 1 Python service (`service/`) for face embeddings + offline ML training.

---

## THE ONE FINDING THAT CHANGES HOW YOU SHOULD READ EVERYTHING ELSE

Before the section-by-section audit: there are **two parallel, non-overlapping architectures** in this repo, and the difference matters enormously for planning.

**Architecture A — what actually runs.** `lib/main.dart` → `HomeScreen` → `AppShell` (a manual `IndexedStack` + `Navigator.push` mix, no router). No login screen. No `Principal`. Every screen is reachable by anyone who opens the app.

**Architecture B — a fully built, fully tested, completely disconnected RBAC system.** `lib/app/routes.dart` (224 LOC, a full route table with per-route permission requirements) + `lib/core/rbac/route_guard.dart` (110 LOC, a `RouteResolver` that is the stated "single choke point" for access control) + `lib/core/auth/*` (`auth_store.dart`, `in_memory_auth_store.dart`, `principal.dart`, `user_role.dart` — 443 LOC) + `lib/core/rbac/permission.dart` + `permissions.dart` (170 LOC, a deny-by-default permission matrix). Backed by two substantial test files (`test/permissions_test.dart` 255 LOC, `test/route_guard_test.dart` 183 LOC) that pass and genuinely verify the matrix and the guard logic.

**Verified directly:** `grep -rln "AppRoutes\.\|RouteResolver\|routes.dart" lib` (excluding the files that define these things) returns **nothing**. `lib/main.dart` does not import `lib/app/routes.dart`, `lib/core/rbac/route_guard.dart`, or anything under `lib/core/auth/`. The only importer of `routes.dart` is `route_guard.dart`; the only importer of `route_guard.dart` is its own test.

**What this means concretely:** the RBAC/permissions engineering work you'd otherwise need to design from scratch (Section 15's "RBAC" ask) is already done, well-tested, and sitting on the shelf unused. The gap is not "design RBAC" — it's "wire it in, and put a real `AuthStore` behind it" (see next section). Every navigation/security finding below about "no enforcement" refers to Architecture A, the one users actually experience.

---

## 1. High-Level Overview

**What CogniHire currently is:** a single-tenant Flutter desktop/web app (no login) that runs a scripted interview flow — resume upload → LLM-assisted claim extraction (grounded against the resume text) → an interview screen with continuous face-verification and keystroke-telemetry-triggered follow-ups → a non-scored, per-claim evidence audit stored as local JSON files. A companion Python FastAPI service does face embedding (InsightFace). A local Ollama instance does claim extraction and (in a separate, also-real code path) live interview turn generation.

**Current architecture:** layered Flutter app — `lib/core/*` (pure-Dart domain logic, no Flutter/`dart:io` imports where possible, deliberately testable without a widget tree) feeding `lib/features/*` (screens) through `lib/main.dart` (composition root) and `lib/ui/*` (a real design-token system + shell chrome). No backend server beyond the two local services (Ollama, the face-embedding FastAPI app) — everything else is a Flutter desktop/web process reading and writing local files.

**Current workflow (as actually wired):** New session → optional face enrolment → resume upload → Ollama-based claim extraction with a grounding gate (falls back to a heuristic extractor, disclosed, if Ollama is unreachable) → candidate reviews/edits/confirms claims → interview session (the *older* `InterviewScreen`, not the newer, unused `LiveInterviewScreen` — see Navigation section) with continuous identity re-checks and rule-based follow-ups on suspicious typing patterns → session ends → `ClaimAuditBuilder` produces a deterministic, non-LLM per-claim verdict set → saved as a plaintext JSON file → viewable/exportable, with drill-down into an evidence graph and a separate ML "sufficiency" view.

**Fully working:** claim extraction + grounding (real Ollama call, real fallback, real substring-grounding check); question bank (fully static rule-based ladder); persistence (JSON files, atomic write, corruption-surfaced-not-hidden); RBAC matrix and route-guard logic (real, tested, just unused); identity matching (cosine similarity, tested, documented threshold caveat); hash-chained session event log (tamper-evident, documented as not tamper-proof); role-based claim-queue prioritization (shipped this session — see below); dashboard/workspace stats (computed live from stored audits, no fabricated numbers).

**Partially working:** the live interview turn generation (`LiveTurnClient`) is real and functional against Ollama, but its "last answer score" input is a hardcoded constant `1` (`scoring_agent.txt` exists on disk but is never wired to a call site) — meaning the model's stated difficulty-adjustment and re-ask-suppression rules run on permanently fake data. The interview grounding check only covers the `quote` field of a turn, not `say`/`kind`/`difficulty_delta`/`why`.

**Placeholder / prototype:** `LiveInterviewScreen` (1,013 LOC, the single largest interview-related file) is fully built with mic UI, presence indicators, TTS wiring — and is never instantiated by the shipping app. It only runs via a standalone dev harness (`lib/dev/live_interview_demo.dart`). If you've been thinking of this as "the interview screen," it isn't the one a user sees.

**Mocked:** `InMemoryAuthStore` — plaintext passwords in a `Map`, compared with `==`, no persistence across restarts, explicitly self-documented as "a test double... not a login system." The entire ML sufficiency-scoring layer (`lib/core/ml/`, 1,801 LOC) is trained and validated **only on synthetic data**; `isValidatedOnRealData = false` is hardcoded and there is no `fitReal()` constructor anywhere. `report_agent.txt` (an LLM report-summary prompt) has no discoverable call site in the app at all.

**Missing entirely:** real authentication (no `SupabaseAuthStore` or equivalent exists anywhere in the repo — only referenced in a comment as "the one that ships"); encryption at rest; liveness/anti-spoof detection for face verification; multi-tenancy; a real router; notifications; a calendar/scheduling feature; any cloud backend.

---

## 2. Folder Structure

```
lib/
  app/                    Route table (AppRoutes) — orphaned, see finding above
  core/                   Pure(ish)-Dart domain logic, no UI
    auth/                 Principal/UserRole/AuthStore + InMemoryAuthStore — orphaned, unused by main.dart
    claims/                Claim model, extractors (Ollama + heuristic fallback), ClaimAudit
    design/                app_theme.dart — the ThemeExtension-based token/color system
    export/                Audit export to HTML (+ platform-specific writer/stub pair)
    features/              NOT UI features — this is the ML "feature vector" assembly layer (confusingly named
                           the same as lib/features/; feature_registry.dart, feature_assembler.dart, feature_vector.dart)
    graph/                 Evidence graph model, codec, and audit→graph builder
    integrity/             Violation rules + tracker for process/typing anomalies
    interview/             Question bank (static), FollowUp generator, LiveTurnClient (Ollama-backed)
    ml/                    Sufficiency model, calibration, conformal prediction, attribution, guards — all synthetic-data-only
    persistence/            AuditStore abstraction + JSON-file implementation + codec + store factory (io/stub split for web)
    privacy/                Candidate-id HMAC pseudonymization, text scrubber
    rbac/                  Permission enum, AccessPolicy matrix, RouteResolver — orphaned, unused by main.dart
    roles/                 Role model, coverage report, claim-priority ordering (this session's addition), RoleStore
    session/               SessionDraft (ChangeNotifier), SessionEventLog (hash chain)
    telemetry/              Keystroke capture/event/classification, process telemetry
    verification/           Face engine HTTP client, IdentityMatcher, VerificationSession, Platt scaler, biometric metrics
    workspace/              Cross-session aggregation (WorkspaceStats, WorkspaceLoader) for the dashboard
  dev/                     Standalone dev harness (live_interview_demo.dart) — not part of the shipping app
  features/                Screens, one subfolder per destination
    analysis/               Resume analysis / claim review screen
    audit/                  Claim audit (report) screen
    candidates/              Candidate list + candidate profile screen (two screens, one file)
    common/                  Shared empty-state widget
    dashboard/               Workspace dashboard screen
    enrolment/               Face enrolment screen + controller
    graph/                  Evidence graph screen + layout algorithm
    interview/               InterviewScreen (used) + LiveInterviewScreen (unused/dev-only) + controllers
    reports/                 Reports listing screen
    resume/                  Resume file picking, upload UI, text extraction
    reviewer/                Model decision (ML sufficiency) screen
    roles/                  Roles screen (create/edit roles, coverage view)
    session/                 Verification status card widget
    sessions/                Session history screen
    settings/                Settings screen
    task/                   "Telemetry" screen (rail label doesn't match file/class name — see Navigation section)
  ui/                      Shared design system: app_shell.dart (chrome/nav), components.dart, patterns.dart
                           (component catalogue — 1,487 LOC), tokens.dart (spacing/breakpoint/typography constants)
  main.dart                Composition root — the actual navigation graph lives here
test/                      63 files, 10,622 LOC — unit + widget tests, mirrors lib/ roughly 1:1 for core logic
service/                   Python FastAPI face-embedding service + offline ML trainer
  main.py                  InsightFace buffalo_l wrapper, CORS wide open (allow_origins=["*"])
  ml/                      train.py, synthetic.py, split.py, calibration.py, metrics.py, export_model.py
                           — trains the model whose weights are checked into assets/ml/sufficiency_model.json
tool/                      CLI utilities: corpus_eval.dart, calibrate_threshold.dart (this session's addition),
                           corpus_prep.py, ollama_smoke.dart
prompts/                   4 .txt prompt files — 2 of the 4 are NOT wired to any code path (see AI Pipeline section)
assets/ml/                 Checked-in model weights (sufficiency_model.json) + held-out metrics report
android/, windows/, web/    Standard Flutter platform scaffolding
```

---

## 3. Features Audit

| Feature | Status | Notes |
|---|---|---|
| Dashboard | **Implemented** | Live-computed from `WorkspaceStats` over stored audits (`lib/features/dashboard/dashboard_screen.dart`, 524 LOC). No hardcoded/fabricated metrics — the file's own doc comment explicitly lists what the design mockup wanted (a "Hiring Score 88/100" card, an "AI Accuracy 99.4%" card, a shortlist counter, an AI optimization tip, calendar sync) and states each was removed because nothing backs it. |
| Resume Analysis | **Implemented** | `lib/features/analysis/resume_analysis_screen.dart` (643 LOC) + `lib/features/resume/*`. Real PDF/.docx text extraction (Syncfusion + archive/xml, on-device only). |
| Claim Extraction | **Implemented**, with a real fallback | `OllamaClaimExtractor` (Ollama, `qwen2.5:7b`, `temperature: 0`) with `HeuristicClaimExtractor` as a disclosed fallback on any failure. |
| Grounding Gate | **Implemented** | Exact-substring (whitespace-normalized, case-insensitive) check of every returned claim against the source resume text. No fuzzy matching by design. |
| Interview | **Implemented** (the screen users see) / **Prototype, unused** (`LiveInterviewScreen`) | `InterviewScreen` (521 LOC) is what's actually pushed. `LiveInterviewScreen` (1,013 LOC) is fully built but never instantiated outside `lib/dev/live_interview_demo.dart`. |
| Reports | **Implemented** | `lib/features/reports/reports_screen.dart` (303 LOC), lists stored sessions. |
| Roles | **Implemented** | Role CRUD + coverage report against a session's claims; this session added role-based claim-queue prioritization on top. |
| Sessions | **Implemented** | Session history list, backed by real persistence. |
| Candidates | **Implemented** | List + profile screens (in one 1,026-LOC file — see Widget Tree section for the split recommendation). |
| Authentication | **Mocked / not production** | `InMemoryAuthStore` only; no real backend; not wired into the running app at all (`main.dart` has no sign-in flow). |
| Settings | **Implemented** | Theme, storage location display, misc preferences. |
| Storage | **Implemented** | Plaintext JSON files, atomic write-then-rename, corruption surfaced not hidden. No encryption. |
| Notifications | **Missing** | No push/in-app notification system found anywhere. |
| Analytics | **Implemented, narrow scope** | `WorkspaceStats` computes real dashboard figures from stored audits; nothing beyond that (no event analytics pipeline, no funnel tracking). |
| Evidence Graph | **Implemented** | Real graph model with a deliberately-absent `strength()`/`score()` method (guarded against by design), per-claim (not per-session) scope. |
| Claim Audit | **Implemented** | Deterministic, non-LLM, no numeric score by design (cites NYC LL144 / EU AI Act directly in the source doc comment). |
| Hash Chain | **Implemented, with a stated limitation** | Tamper-evident (SHA-256 chained events), explicitly **not** tamper-proof — a full-file rewrite with recomputed hashes would pass verification; no external anchor exists. |
| Identity Verification | **Implemented, with a stated limitation** | Real cosine-similarity face matching on a jittered interval; threshold (0.50) is reasoned but not validated on real FAR/FRR data (tooling for that calibration was built this session — `tool/calibrate_threshold.dart` — but real paired data was never collected). **No liveness detection at all.** |
| Typing Metrics | **Implemented** | 3 rule-based trigger patterns (`bulkInsert`, `pauseThenBulk`, `immediateAnswer`), feeding adaptive follow-ups. |
| Voice | **Partially implemented** | TTS (`flutter_tts`) and STT (`speech_to_text`) are wired into `LiveInterviewScreen` — which, per above, is not the screen users actually reach. |
| Camera | **Implemented** | Real `camera`/`camera_windows` integration for enrolment and interview verification frames. |
| Face Enrolment | **Implemented** | Real capture flow with face-size rejection and guidance. |
| ML Sufficiency Model | **Prototype / synthetic-only** | Full logistic-regression + isotonic calibration + conformal prediction + exact attribution pipeline — all trained and validated on fabricated data. `decision_from_audit.dart` hardcodes `presentedAsAboutRealPerson: false` with no override parameter — a genuine code-level guard against overstating this to a real audience. |
| RBAC | **Implemented, but disconnected** | See the top-of-report finding — fully built and tested, not wired into `main.dart`. |

---

## 4. Current Navigation

**No real router exists.** No `go_router`, no `onGenerateRoute`, no named-route table wired to the UI (the *unused* `lib/app/routes.dart` table is the closest thing, and it isn't consulted by the navigation code that actually runs). Navigation is two mechanisms:

1. **Shell destination switch** — `lib/ui/app_shell.dart`'s `_AppShellState` holds a manual `IndexedStack` over `AppShell.destinations`, lazily built (only materialized once visited). Cross-jumps go through `AppShellController.of(context)?.goTo(label)` — **a string-keyed lookup**; a typo in a label is a silent no-op, not a compile error.
2. **Stack pushes** — bare `Navigator.of(context).push(MaterialPageRoute(...))` for anything that "takes over the screen": enrolment, interview, claim audit, evidence graph, model decision, candidate profile, session detail.

**Destination map** (from `lib/main.dart`):

| Screen | Reached via | Finished? |
|---|---|---|
| Dashboard | Rail item | Finished |
| Candidates | Rail item | Finished |
| Roles | Rail item | Finished |
| New session (setup form) | Rail item / multiple CTAs | Finished |
| Resume analysis | Rail item + "Add a resume" link from setup | Finished |
| Sessions (history) | Rail item | Finished |
| Reports | Rail item | Finished |
| "Telemetry" (rail label) → `TaskScreen` class | Rail item | Finished, but **rail label doesn't match the underlying file/class name** (`task_screen.dart`) — a real naming-audit finding (Section 35) |
| Settings | Rail item + notice-bell taps | Finished |
| Enrolment | Programmatic push, one-shot flow | Finished |
| Interview (`InterviewScreen`) | Push from setup screen | Finished — this is the live one |
| Claim audit | Push from Interview at session end | Finished |
| Evidence graph | Push from inside Claim Audit (per-claim) — **not reachable from the rail at all** | Finished, but buried two pushes deep |
| Model decision | Push from inside Claim Audit | Finished, same burial issue |
| `LiveInterviewScreen` | **Only from `lib/dev/live_interview_demo.dart`, a standalone dev entry point** | Built but dead in the shipping app |

**Placeholders:** none found as inert/no-op destinations — a prior version reportedly had some and the code's own comments say they were removed rather than left as stubs (spot-checked in `app_shell.dart`'s top bar — bell, help, search, primary action are all wired to real callbacks).

---

## 5. Current UI

**Design system: real, token-based, mostly-but-not-fully consistent.**

- Spacing scale: `Spacing.xs/sm/md/lg/xl/xxl/xxxl` = 4/8/12/16/24/32/48, plus `section`=48, `hero`=80.
- Radii: `Radii.control`=8, `surface`=16, `pill`=999.
- Color: `EvidenceColors` and `BrandAccents` as `ThemeExtension`s, `AppTheme.light`/`dark`.
- Typography: tabular-figure/slashed-zero numeric variants specifically so comparable numbers align.
- Breakpoints: `Breakpoints.compact`=700px, `expanded`=1080px — a genuine two-tier responsive system, not just a fixed desktop build.

**Components:** `lib/ui/patterns.dart` (1,487 LOC) is a flat catalogue of ~18 presentational widgets (`MetricCard`, `RingGauge`, `RadarChart`, `FunnelChart`, `SparkBars`, `Tag`, `Monogram`, `DropZone`, etc.) — no business logic inside it, geometry correctly pushed into `CustomPainter`s where needed. Size is a navigability cost, not an architecture smell; it should be split into per-family files (charts / rows / misc) with no logic changes required.

**Responsive behavior:** genuine — the shell switches `NavigationRail` ↔ bottom `NavigationBar` at the compact breakpoint, and `ShellPage`'s header stacks title/actions vertically below 700px specifically to fix a documented real overflow bug ("Good afternoon" wrapping letter-by-letter was an actual observed failure, not a hypothetical one). Only ~8 of 104 lib files reference `MediaQuery`/`LayoutBuilder`/`Breakpoints` at all — the shell and 4 feature screens opt in; the rest rely on flexible layout (`Column`/`Wrap`) without explicit breakpoint branching, which is untested screen-by-screen.

**UI problems / technical debt:**
- Hardcoded `Color(0x...)` values bypass the two `ThemeExtension`s in `evidence_graph_screen.dart` (3 instances) and duplicated identically (not shared) between `live_interview_screen.dart:483` and `dev/live_interview_demo.dart:74`.
- Off-scale `EdgeInsets` values (10, 14, 20 — not on the 4/8/12/16/24/32/48 spacing scale) appear repeatedly across `claim_audit_screen.dart`, `enrolment_screen.dart`, `interview_screen.dart`, `evidence_graph_screen.dart`, `live_interview_screen.dart`, `task_screen.dart`, `session_history_screen.dart` — at least 7 files routinely fall back to hand-picked pixel values instead of the `Spacing` enum.
- Test coverage of responsive/theme combinations is thin: `test/preview/` has exactly 3 screenshots (wide+light, wide+dark, compact+light) of **only the Dashboard/shell view** — no compact+dark pairing, no mid-breakpoint (700–1080px) coverage, no other screen photographed at any size. The preview test file's own doc comment states these are non-comparing (nothing fails on pixel changes) — visual-inspection only, not a regression gate.
- `candidates_screen.dart` (1,026 LOC) combines a list screen and a full detail/profile screen (`CandidateProfileScreen`, pushed via `Navigator.push` from inside the same file) — the clearest "should be split into two files" case found.

---

## 6. Data Flow

Exactly as implemented, with the disclosed-degradation and grounding points marked:

```
Resume file (PDF/.docx)
    │
    ▼
resume_text_extraction.dart — real parse (Syncfusion / archive+xml), on-device only.
Failure → reported failure, never a fabricated empty success.
    │
    ▼
OllamaClaimExtractor.extract() — POST {ollamaBaseUrl}/api/chat, model qwen2.5:7b,
format: json, temperature: 0, 90s timeout.
Failure (timeout / non-200 / malformed JSON) → HeuristicClaimExtractor fallback,
ClaimExtraction.degradedReason set and (per the code's contract) surfaced to the UI.
    │
    ▼
Grounding gate — exact substring match (case/whitespace-normalized) of each
returned claim against the resume text. Anything failing → rejectedUngrounded,
never becomes a Claim.
    │
    ▼
SessionDraft (ChangeNotifier) — candidate reviews/edits/confirms claims.
confirmedClaims only populated by an explicit confirmReviewed() call — extraction
alone never fills it.
    │
    ▼
effectiveClaims — reordered by orderClaimsForRole() if a Role was picked
(this session's addition) so the role's required skills open first. Nothing
dropped or hidden, only reordered.
    │
    ▼
InterviewController drives the session: QuestionBank (static rule-based ladder)
generates the scripted question per claim; FollowUpGenerator reacts to
ProcessTelemetry (typing patterns) with rule-based follow-ups; VerificationSession
re-checks identity on a jittered ~20s interval throughout.
[Separately, LiveTurnClient — Ollama-backed adaptive turns — exists and works,
 but is only reachable via the unused LiveInterviewScreen, not this path.]
    │
    ▼
SessionEventLog — every event (claim opened, answered, identity checked,
telemetry batch, etc.) appended and SHA-256 hash-chained as it happens.
    │
    ▼
ClaimAuditBuilder.build() — pure, deterministic, NO model call. Classifies each
claim from stored evidence + optional human reviewerAssessments into
substantiated / notDemonstrated / contradicted / notExamined. No numeric score.
    │
    ▼
JsonFileAuditStore.saveAudit() — one plaintext JSON file per session, atomic
write-then-rename, under platform app-support storage. NO integrity protection
on this file itself (the hash chain covers the event log, not this saved report).
    │
    ▼
Claim Audit screen / Evidence Graph screen / Model Decision (ML sufficiency)
screen / HTML export — all read-only views over the saved audit.
```

---

## 7. Database

**No SQL database exists — confirmed, no SQLite, no Supabase.** Persistence is entirely `JsonFileAuditStore` (`lib/core/persistence/audit_store_io.dart`): one JSON file per session under the platform's app-support directory, plus a single `enrolment.json` for the enrolled face reference. `RoleStore` follows the same pattern for role definitions (`lib/core/roles/role_store_io.dart`). Both use an atomic write-then-rename pattern for crash safety. Web builds get an in-memory-only stub (`store_factory_stub.dart`) since there's no filesystem — data does not survive a page reload on web.

---

## 8. State Management

**No Provider, Riverpod, flutter_bloc, GetX, or InheritedWidget-based state library anywhere** (confirmed via a whole-repo grep — zero hits for any of them, aside from the app's own hand-rolled `_Scope` `InheritedWidget` inside `app_shell.dart` for shell-local context, which is a one-off, not a general DI mechanism).

Two patterns are actually in use:
1. **`setState` + `StatefulWidget`** — the dominant pattern, used in essentially every one of the ~20 stateful screens for local loading/error/busy flags.
2. **`ChangeNotifier`**, in exactly two deliberate, narrow places: `SessionDraft` (shared between the resume-analysis and new-session-setup screens, which must observe the same in-progress draft) and `InterviewVoiceController` (drives `LiveInterviewScreen`'s state machine, independent of camera/audio capture for testability).

No app-wide DI mechanism exists to propagate a `ChangeNotifier` to a deeply nested screen — both current instances are hand-threaded via constructors. This is not a problem yet (only two shared-state objects exist), but a third would force a real decision (introduce `provider`/`riverpod`, or keep hand-threading) that the current code gives no template for.

---

## 9. Services

| Service | What it does | Where |
|---|---|---|
| `OllamaClaimExtractor` | Resume → structured claims via local LLM | `lib/core/claims/ollama_claim_extractor.dart` |
| `HeuristicClaimExtractor` | Non-LLM fallback claim extraction | `lib/core/claims/heuristic_claim_extractor.dart` |
| `LiveTurnClient` | Ollama-backed adaptive interview turn generation (streaming) | `lib/core/interview/live_turn_client.dart` |
| `QuestionBank` | Fully static, non-LLM question ladders by claim type | `lib/core/interview/question_bank.dart` |
| `FollowUpGenerator` | Rule-based follow-ups from typing telemetry | `lib/core/interview/followup.dart` |
| `HttpFaceEngine` | HTTP client to the Python face-embedding service | `lib/core/verification/face_engine.dart` |
| `IdentityMatcher` | Cosine-similarity face comparison | `lib/core/verification/identity_matcher.dart` |
| `VerificationSession` | Jittered continuous identity re-check loop | `lib/core/verification/verification_session.dart` |
| `JsonFileAuditStore` | Session/audit/enrolment persistence | `lib/core/persistence/audit_store_io.dart` |
| `RoleStore` (file-backed) | Role persistence | `lib/core/roles/role_store_io.dart` |
| `WorkspaceStats`/`WorkspaceLoader` | Cross-session dashboard aggregation | `lib/core/workspace/*.dart` |
| `AuditExport` | Standalone HTML export of a claim audit | `lib/core/export/audit_export.dart` |
| `EvidenceGraphBuilder` | Builds graph nodes/edges from claims/verification results | `lib/core/graph/evidence_graph.dart` |
| `SufficiencyModel` + friends | Synthetic-data-only ML decision-support layer | `lib/core/ml/*` (12 files) |
| `RouteResolver` / `AccessPolicy` | RBAC enforcement — **orphaned, not wired in** | `lib/core/rbac/*` |
| `InMemoryAuthStore` | Mocked auth — **orphaned, not wired in** | `lib/core/auth/*` |
| Python face service | InsightFace `buffalo_l`, detection+recognition only, FastAPI | `service/main.py` |
| Python ML trainer | Offline trainer producing `assets/ml/sufficiency_model.json` | `service/ml/*.py` |
| `tool/calibrate_threshold.dart` | Threshold calibration CLI (this session's addition) — blocked on real paired-capture data | `tool/calibrate_threshold.dart` |

---

## 10. AI Pipeline

**Every prompt found, with wiring status:**

| Prompt | File:line | Wired to running app? |
|---|---|---|
| Claim extraction system prompt | `lib/core/claims/ollama_claim_extractor.dart:68` (~600 chars) | Yes |
| Live interview turn prompt (Dart copy) | `lib/core/interview/live_turn_client.dart:176` (~2,900 chars) | Yes — but only reachable through the unused `LiveInterviewScreen` |
| Live interview turn prompt (`.txt` copy) | `prompts/interview_agent.v2.txt` | Reference copy for evals/tests only, not loaded at runtime — **a hand-synced duplicate of the Dart string above**, and the Dart file's own comment documents a real production bug (empty `say` field) caused by these two drifting apart in the past |
| `prompts/interview_agent.v1.txt` | on disk | No — superseded, unreferenced |
| `prompts/scoring_agent.txt` | on disk | **No — confirmed unwired.** `interview_voice_controller.dart:78-82` states outright it's "not wired to this controller yet"; `_lastAnswerScore` is a hardcoded `1`, never updated. This means the live-turn prompt's own stated rules ("never re-ask a claim scored below 2," difficulty adjustment based on last-answer quality) run against **permanently fake input**. |
| `prompts/report_agent.txt` | on disk | **No call site found anywhere in `lib/`.** The actual report path (`ClaimAuditBuilder`) is pure deterministic Dart with zero model calls. This prompt describes functionality that does not exist in the app. |

**Grounding discipline is uneven across the two live prompts:** claim extraction is grounded on every returned claim (exact substring match). The live interview turn only grounds the `quote` field against the candidate's transcript (`_enforceGrounding`, `live_turn_client.dart:495-514`) — `say`, `kind`, `difficulty_delta`, and `why` are not grounding-checked, and candidate speech (transcribed, user-controlled) reaches the model as unescaped JSON-string content with no other injection defense.

**Models used:** Ollama `qwen2.5:7b` (local, `http://localhost:11434`, configurable via `--dart-define`). InsightFace `buffalo_l` (detection + recognition modules only — the gender/age classifier is explicitly excluded from `allowed_modules`) for face embeddings, no liveness model. **Confirmed by whole-repo grep: zero cloud LLM API calls anywhere** (no OpenAI/Anthropic/Gemini/Cohere references in first-party code).

**The ML "sufficiency" layer** (`lib/core/ml/`, 1,801 LOC) is a separate system from the two Ollama-backed prompts above — logistic regression + isotonic calibration + conformal prediction (with abstain) + exact per-feature attribution, entirely trained and validated on **fabricated synthetic data** (`SyntheticSufficiencyDataset`). `isValidatedOnRealData=false` is a hardcoded field with no `fitReal()` constructor anywhere in the codebase. `decision_from_audit.dart` hardcodes `presentedAsAboutRealPerson: false` with **no parameter to override it** — a real, code-enforced guard against this ever being shown as if it evaluated an actual person, and `decision_guards.dart` runtime-checks for exactly that misuse.

---

## 11. Dependencies

| Package | Used? | Where / verdict |
|---|---|---|
| `cupertino_icons` | **No — zero usages found anywhere in `lib/`** | Dead weight from the default Flutter template; safe to remove |
| `camera` | Yes | Enrolment + interview screens |
| `http` | Yes | Ollama calls, live-turn client, face-service client |
| `meta` | Yes | `@immutable`/annotations |
| `camera_windows` | Not directly imported (expected) | Platform plugin for `camera` on Windows, registers via Flutter's plugin system |
| `path_provider` | Yes | Export writer, audit/role store factories |
| `file_picker` | Yes | Resume file picking |
| `crypto` | Yes | Candidate-id HMAC, session event hash chain |
| `syncfusion_flutter_pdf` | Yes | PDF text extraction — **note: commercial/licensed package**, verify licensing tier before any commercial deployment |
| `archive` | Yes | `.docx` zip unpacking |
| `xml` | Yes | `.docx` document.xml parsing |
| `flutter_tts` | Yes | `LiveInterviewScreen` (the unused one) |
| `speech_to_text` | Yes | `LiveInterviewScreen` (the unused one) |
| `flutter_lints` (dev) | Yes | Linting only, correct usage |

---

## 12. Current Security

*(Full detail in Section 31 — Security Review; summarized here per the original prompt's structure.)*

Authentication is mocked and unwired. RBAC is real but unwired — the running app enforces nothing. Storage is plaintext, no encryption at rest. The hash chain is tamper-evident, not tamper-proof (stated in its own source comment). Saved audit report files have **zero** integrity protection (no hash, no signature — the chain covers the event log, a separate artifact). Identity verification has no liveness detection — a photo, screen replay, or deepfake is not defended against by anything in this codebase. CORS on the face service is wide open (`allow_origins=["*"]`). No secrets/API keys are hardcoded anywhere (verified clean).

---

## 13. Technical Debt

- **The RBAC/auth system is fully built and unused** — the single largest structural finding in this audit (see top of report).
- **`LiveInterviewScreen` (1,013 LOC) is dead code from the shipping app's perspective**, only reachable via a dev harness.
- **Two of four AI prompts on disk (`scoring_agent.txt`, `report_agent.txt`) are unwired**, and one wired prompt (`interview_agent.v2.txt`) exists as a hand-synced duplicate that has already caused a real production bug from drift.
- **Answer scoring feeds the live interview loop a hardcoded constant**, silently defeating two of that prompt's own stated adaptivity rules.
- **`candidates_screen.dart`** combines a list screen and a full detail screen in one 1,026-LOC file.
- **`lib/ui/patterns.dart`** (1,487 LOC) is a flat, unsplit component catalogue.
- **Off-scale hardcoded padding/color values** in at least 7 feature files, bypassing the token system that exists specifically to prevent this.
- **`EnrolmentProfile`'s schema-version check has no migration path** — any schema bump silently orphans every previously-saved enrolment (hard throw, no backward-compat handling).
- **No hardcoded secrets or TODO/FIXME/HACK markers found anywhere** (positive finding — debt in this codebase tends to be documented in prose doc-comments rather than left as tags, which is unusually disciplined, but also means grep-for-TODO won't surface it — you have to read the comments).
- **Serialization logic placement is inconsistent**: `Role` serializes itself; `Claim`/`ClaimAudit`/`VerificationResult`/`EnrolmentProfile` delegate to an external codec file.
- **`cupertino_icons` is a dead dependency.**
- **Rail label "Telemetry" doesn't match the underlying `TaskScreen` class/file name** — a real find-by-name trap for future contributors.

---

## 14. Performance

Not deeply profiled in this pass (no `flutter run --profile` trace was captured), but structurally:
- `WorkspaceStats`/dashboard figures are recomputed from stored audits on load, not cached/streamed — fine at demo scale (a few dozen sessions per the codebase's own stated assumption in `audit_store_io.dart`), would need revisiting before hundreds/thousands of sessions.
- `lib/ui/patterns.dart`'s `CustomPainter`-based charts (`RingGauge`, `RadarChart`) correctly push geometry work out of `build()`, which is the right call for repaint cost.
- The Ollama HTTP calls (claim extraction: 90s timeout; live turn: streaming) are the two clearly blocking-network operations in the app; both are `async`/awaited, not fire-and-forget, and both have documented fallback/failure paths.
- No image/asset size audit was performed (out of scope for this pass — flag for a follow-up if binary size matters).

---

## 15. Missing Enterprise Features

| Feature | Status |
|---|---|
| Authentication | Mocked only, not production-usable, not wired in |
| RBAC | **Built and tested — just needs wiring + a real AuthStore behind it** (not a from-scratch design task) |
| Organizations / multi-tenancy | Missing entirely — every model (`Role`, `ClaimAudit`, `EnrolmentProfile`) lacks any org/tenant-scoping field |
| Supabase (or any cloud DB) | Missing entirely — no SQL, no cloud persistence of any kind |
| Notifications | Missing entirely |
| Audit Logs | Partially present in spirit — `SessionEventLog` is an audit trail for one session, but there's no cross-session/system-level admin audit log |
| Scheduling / Calendar | Missing entirely |
| Email | Missing entirely — no SMTP/email-sending code found |
| Realtime | Missing entirely — no websockets, no live sync between clients |
| API (external-facing) | Missing entirely — the only HTTP servers in this repo are the local Ollama instance and the local face-embedding FastAPI service; there is no app-facing API for a second client to consume |
| Storage (cloud) | Missing — local filesystem only, no cloud object storage |

---

## 16. Current APIs

- **Ollama** — local, `http://localhost:11434`, `/api/chat`, model `qwen2.5:7b`. Two call sites: `OllamaClaimExtractor`, `LiveTurnClient`.
- **Face embedding service** — local, `http://localhost:8000` (configurable), FastAPI, `POST /face/analyze`, `GET /health`. Called from `HttpFaceEngine`.
- **No external/cloud APIs of any kind** — confirmed by grep, no OpenAI/Anthropic/AWS/GCP/Azure SDK usage anywhere in `lib/` or first-party `service/` code.

---

## 17. Configuration

All configuration lives in one 31-line file, `lib/core/config.dart`, as `String.fromEnvironment` dart-defines with local-service defaults:

```dart
faceServiceUrl   → http://localhost:8000   (override: FACE_SERVICE_URL)
ollamaBaseUrl    → http://localhost:11434  (override: OLLAMA_BASE_URL)
ollamaModel      → qwen2.5:7b              (override: OLLAMA_MODEL)
minEnrolmentFaceSize → 15000 (constant, not overridable)
```

No `.env` files anywhere in the repo. No API keys, tokens, or secrets — hardcoded or otherwise — found in either `lib/` or first-party `service/` code (the only "secret"-adjacent code is `lib/core/privacy/candidate_id.dart`'s HMAC pseudonymization, which takes a caller-supplied key, not a hardcoded one).

---

## 18. Architecture Diagram (current implementation only)

```
┌─────────────────────────────────────────────────────────────────────┐
│  Flutter app process (Windows / Android / Web)                       │
│                                                                       │
│   lib/main.dart  ── composition root, owns SessionDraft,             │
│         │            EnrolmentProfile state, RoleIndex               │
│         ▼                                                             │
│   AppShell (lib/ui/app_shell.dart)                                    │
│     IndexedStack destination switch + Navigator.push for takeovers    │
│         │                                                              │
│         ├─ Dashboard ── WorkspaceStats ◄── JsonFileAuditStore         │
│         ├─ Resume analysis ── resume_text_extraction.dart              │
│         │        │  (PDF/.docx, on-device only)                       │
│         │        ▼                                                     │
│         │   OllamaClaimExtractor ──HTTP──► [Ollama :11434, local]      │
│         │        │  (fallback: HeuristicClaimExtractor)                │
│         │        ▼                                                     │
│         │   grounding gate (exact substring match)                     │
│         │                                                               │
│         ├─ New session setup ── SessionDraft(ChangeNotifier)           │
│         │        (role picker → orderClaimsForRole)                    │
│         │                                                               │
│         ├─ Enrolment ── camera ──HTTP──► [Face service :8000, local]   │
│         │                                  InsightFace buffalo_l        │
│         │                                  (detection+recognition only) │
│         │                                                               │
│         ├─ InterviewScreen (the live one)                               │
│         │        QuestionBank (static) + FollowUpGenerator (rule-based) │
│         │        VerificationSession ──HTTP──► [Face service, jittered  │
│         │                                        ~20s interval]         │
│         │        SessionEventLog (SHA-256 hash chain, append-only)      │
│         │                │                                               │
│         │                ▼                                               │
│         │         ClaimAuditBuilder (pure Dart, no model call)          │
│         │                │                                               │
│         │                ▼                                               │
│         │       JsonFileAuditStore.saveAudit() ── plaintext JSON,        │
│         │                                          app-support dir,      │
│         │                                          NO integrity check    │
│         │                                                               │
│         ├─ Claim Audit screen ─┬─ Evidence Graph screen                 │
│         │                      └─ Model Decision screen                 │
│         │                            (ML sufficiency, SYNTHETIC DATA     │
│         │                             ONLY, isValidatedOnRealData=false) │
│         │                                                               │
│         ├─ Candidates / Sessions / Reports / Roles / Settings          │
│         │                                                               │
│         └─ [UNUSED PATH] LiveInterviewScreen ──HTTP(stream)──► Ollama   │
│                (only reachable via lib/dev/live_interview_demo.dart)    │
│                             flutter_tts / speech_to_text                │
│                                                                          │
│   [ORPHANED, NOT WIRED IN] lib/app/routes.dart + lib/core/rbac/*        │
│   [ORPHANED, NOT WIRED IN] lib/core/auth/* (InMemoryAuthStore)          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 19. Improvement Roadmap (from existing code only — no redesign)

Ordered by technical importance, not product priority:

1. **Wire the existing RBAC system into `main.dart`.** This is the highest-leverage item in the whole audit — the engineering work is already done and tested; it's currently doing nothing. Requires a real `AuthStore` behind it (see #2) to be meaningful.
2. **Replace `InMemoryAuthStore` with a real backend.** The class itself names its intended successor ("the hosted `SupabaseAuthStore` is the one that ships") — that class does not exist yet anywhere in the repo.
3. **Decide the fate of `LiveInterviewScreen` vs. `InterviewScreen`.** Right now there are two interview implementations, one live, one dead. Either delete the 1,013-LOC dead one, or make it the real one and retire `InterviewScreen` — leaving both as-is is pure liability.
4. **Wire or delete `scoring_agent.txt` and `report_agent.txt`.** Two of four on-disk prompts do nothing; one of the other two (`interview_agent.v2.txt`) is a maintenance hazard by being a hand-synced duplicate that already caused a bug.
5. **Add integrity protection to saved `ClaimAudit` JSON files**, not just the session event log — currently a completed report can be silently edited with no detection at all.
6. **Split `candidates_screen.dart`** into list + profile files; **split `lib/ui/patterns.dart`** into per-family component files. Mechanical, low-risk, improves navigability.
7. **Remove `cupertino_icons`** from `pubspec.yaml` (zero usages).
8. **Standardize the off-scale `EdgeInsets`/hardcoded-`Color` values** back onto the `Spacing`/`ThemeExtension` tokens across the ~7 flagged files.
9. **Add a schema-migration path for `EnrolmentProfile`** (and audit similarly-versioned models) instead of hard-throwing on any version bump.
10. Real threshold calibration and liveness detection are **not** "next logical milestones" from the existing code alone — they require external resources (real paired biometric data, a liveness model/SDK decision) beyond what refactoring the current code can produce.

---

## 20. Final Project Health

| Area | Score /10 | Why |
|---|---|---|
| Architecture | 7 | Clean core/features/ui layering, strong domain-model discipline (sealed types, deny-by-default RBAC, no-fabrication codecs) — undercut by the fact that a whole finished subsystem (RBAC+auth) is disconnected from the app, and two parallel interview screens exist. |
| Code Quality | 8 | Consistently strict serialization, deliberate anti-patterns guarded against in source (no `strength()` method on the evidence graph, no override for `presentedAsAboutRealPerson`), unusually thorough doc comments explaining *why*, not just *what*. |
| Maintainability | 6 | Hurt by the orphaned RBAC system, the dead `LiveInterviewScreen`, the hand-synced prompt duplicate, and two very large files (`patterns.dart`, `candidates_screen.dart`) that should be split. |
| Scalability | 4 | Single-tenant by construction (no org/tenant field on any model), no cloud DB, no real router, no DI beyond two hand-threaded `ChangeNotifier`s — every one of these is a real wall before this becomes multi-org production software. |
| UI | 7 | Genuine token system, genuine two-tier responsive design, but inconsistently applied (off-scale spacing/color in ~7 files) and thin preview/screenshot coverage (3 shots, one screen, no regression gate). |
| UX | 6 | Evidence graph and model decision are buried two navigation levels deep off the rail; a rail label ("Telemetry") doesn't match its underlying screen name; otherwise coherent, deliberately restrained (no fake scores anywhere in the UI). |
| Performance | Not scored | Not profiled in this pass — insufficient evidence for a number either way. |
| Security | 3 | No real auth, no encryption at rest, no liveness detection, saved reports have zero integrity protection, CORS wide open on the face service. The one strong area (RBAC logic itself) is unused. |
| AI Pipeline | 6 | The parts that are wired (claim extraction + grounding) are honest and well-tested; the parts that aren't (answer scoring, report generation) are silently absent rather than fabricated, which is the right failure mode — but "half the pipeline described by the prompts on disk doesn't run" is a real gap, not a rounding error. |
| Documentation | 8 | Exceptionally thorough in-source doc comments explaining design rationale — better than most production codebases. No external docs found describing the RBAC/auth disconnect, though — this report is the first place that's written down. |
| Testing | 8 | 10,622 LOC of tests against 24,885 LOC of app code (~43% ratio), strong coverage of domain logic (permissions, route guard, persistence, identity calibration, session event log) — thinner on UI/widget regression (only 3 static preview screenshots, no golden-image comparison). |

---

## 21. File-by-File Implementation Map

Full table for all 104 files under `lib/`. Deep "problems / should split into" analysis (from the navigation/UI audit) is included for the largest and most complex files; the rest get path, LOC, and a one-line purpose — flagged explicitly as a scoping decision, not a silent omission, given the volume involved.

| File | LOC | Purpose |
|---|---|---|
| `lib/app/routes.dart` | 224 | Route table with per-route RBAC requirements. **Orphaned — not imported by `main.dart`.** |
| `lib/core/auth/auth_store.dart` | 137 | `AuthStore` abstract interface + `AuthFailure` types. Orphaned. |
| `lib/core/auth/in_memory_auth_store.dart` | 188 | Plaintext-password, in-memory `AuthStore` implementation. Self-documented as a test double. Orphaned from the running app. |
| `lib/core/auth/principal.dart` | 61 | Signed-in identity value object (`role`, immutable). Orphaned. |
| `lib/core/auth/user_role.dart` | 57 | 2-value `UserRole` enum (recruiter/candidate). Orphaned from the running app (though the *concept* re-exists informally elsewhere). |
| `lib/core/claims/claim.dart` | 92 | `Claim` model — id/text/source/skill. |
| `lib/core/claims/claim_audit.dart` | 175 | `ClaimFinding`/`ClaimAudit` — the non-scored per-claim verdict aggregate. |
| `lib/core/claims/claim_extractor.dart` | 66 | `ClaimExtractor`/`ClaimExtraction` abstract interface. |
| `lib/core/claims/heuristic_claim_extractor.dart` | 111 | Non-LLM fallback extractor (bullet-strip, keyword tagging). |
| `lib/core/claims/ollama_claim_extractor.dart` | 244 | Ollama-backed extractor + grounding gate. |
| `lib/core/config.dart` | 31 | Runtime config (service URLs, model name, face-size minimum). |
| `lib/core/design/app_theme.dart` | 631 | `AppTheme.light`/`dark`, `EvidenceColors`/`BrandAccents` `ThemeExtension`s, spacing/radii constants. |
| `lib/core/export/audit_export.dart` | 292 | Standalone HTML export of a claim audit. |
| `lib/core/export/export_writer.dart` | 5 | Export writer abstract interface. |
| `lib/core/export/export_writer_io.dart` | 34 | File-based export writer (desktop/mobile). |
| `lib/core/export/export_writer_stub.dart` | 10 | No-op export writer (web). |
| `lib/core/features/feature_assembler.dart` | 565 | Assembles the ML feature vector from a session/audit. Not a UI "feature" — ML terminology collision with `lib/features/`. |
| `lib/core/features/feature_registry.dart` | 729 | Registry of all ML feature definitions and their extraction logic. |
| `lib/core/features/feature_vector.dart` | 86 | The assembled feature-vector value type. |
| `lib/core/graph/evidence_graph.dart` | 467 | `GraphNode`/`GraphEdge`/`EvidenceGraph` model + `EvidenceGraphBuilder`. Deliberately no `strength()`/`score()` method. |
| `lib/core/graph/graph_codec.dart` | 272 | Serialization for the evidence graph. |
| `lib/core/graph/graph_from_audit.dart` | 156 | Builds a per-claim `EvidenceGraph` from a `ClaimAudit`. |
| `lib/core/integrity/integrity_tracker.dart` | 76 | Applies violation rules to running telemetry, tracks strikes. |
| `lib/core/integrity/violation_rules.dart` | 88 | Escalation rule table (20–100 point scale). |
| `lib/core/interview/followup.dart` | 128 | Rule-based follow-up generator from telemetry patterns. |
| `lib/core/interview/live_turn_client.dart` | 515 | Ollama-backed adaptive interview turn client (streaming). Powers only the unused `LiveInterviewScreen`. |
| `lib/core/interview/question_bank.dart` | 386 | Fully static question-ladder bank by claim type. |
| `lib/core/ml/binary_metrics.dart` | 200 | Classifier eval metrics (AUC, Brier, ECE, reliability bins). |
| `lib/core/ml/conformal_sufficiency.dart` | 126 | Split conformal prediction with abstain. |
| `lib/core/ml/decision_from_audit.dart` | 141 | Maps a real `ClaimAudit` into ML feature inputs; hardcodes `presentedAsAboutRealPerson: false`. |
| `lib/core/ml/decision_guards.dart` | 191 | Runtime guard rules preventing synthetic-model output from being presented as real. |
| `lib/core/ml/explanation_templater.dart` | 160 | Renders model output into templated human text, injects synthetic-data caveat. |
| `lib/core/ml/grouped_split.dart` | 57 | Group-aware (by candidate) train/test split. |
| `lib/core/ml/isotonic_calibrator.dart` | 155 | PAVA-based isotonic calibration. |
| `lib/core/ml/sufficiency_attribution.dart` | 56 | Exact per-feature logit attribution. |
| `lib/core/ml/sufficiency_counterfactual.dart` | 123 | "What would need to change" counterfactual search. |
| `lib/core/ml/sufficiency_model.dart` | 306 | Logistic regression, `fitSynthetic()` only, `isValidatedOnRealData=false`. |
| `lib/core/ml/synthetic_sufficiency_dataset.dart` | 204 | Fabricated training-data generator. |
| `lib/core/ml/trained_artifact.dart` | 82 | Loader for the checked-in `assets/ml/sufficiency_model.json`. |
| `lib/core/persistence/audit_store.dart` | 146 | `AuditStore` abstract interface + `InMemoryAuditStore` (for tests/web). |
| `lib/core/persistence/audit_store_io.dart` | 191 | File-backed `AuditStore` implementation. |
| `lib/core/persistence/json_codec.dart` | 407 | Strict `toJson`/`fromJson` codecs for `Claim`/`ClaimAudit`/`VerificationResult`/`EnrolmentProfile`. |
| `lib/core/persistence/store_factory.dart` | 8 | Platform-agnostic store-factory interface. |
| `lib/core/persistence/store_factory_io.dart` | 30 | Resolves the real app-support directory. |
| `lib/core/persistence/store_factory_stub.dart` | 13 | Web/no-filesystem stub. |
| `lib/core/privacy/candidate_id.dart` | 50 | HMAC-SHA256 candidate-id pseudonymization. |
| `lib/core/privacy/scrubber.dart` | 74 | Text scrubbing utility (likely PII-adjacent; not deep-read this pass). |
| `lib/core/rbac/permission.dart` | 88 | 19-value `Permission` enum. |
| `lib/core/rbac/permissions.dart` | 82 | `AccessPolicy` deny-by-default matrix. Real, tested, orphaned from `main.dart`. |
| `lib/core/rbac/route_guard.dart` | 110 | `RouteResolver` — the stated "single choke point." Orphaned from `main.dart`. |
| `lib/core/roles/role.dart` | 153 | `Role`/`SkillCoverageRow` models, self-serializing (`toJson`/`fromJson` on the model, unlike most other domain types). |
| `lib/core/roles/role_coverage.dart` | 132 | Matches a role's skills against a session's claims → coverage report. |
| `lib/core/roles/role_question_priority.dart` | 63 | **This session's addition** — reorders a session's claim queue toward a role's required skills. |
| `lib/core/roles/role_store.dart` | 53 | `RoleStore` abstract interface + `InMemoryRoleStore`. |
| `lib/core/roles/role_store_factory.dart` | 9 | Platform-agnostic factory interface. |
| `lib/core/roles/role_store_factory_io.dart` | 11 | Real file-backed factory. |
| `lib/core/roles/role_store_factory_stub.dart` | 6 | Web stub. |
| `lib/core/roles/role_store_io.dart` | 112 | File-backed `RoleStore` implementation. |
| `lib/core/session/session_draft.dart` | 203 | `SessionDraft` (`ChangeNotifier`) — shared in-progress session state across 2 screens. |
| `lib/core/session/session_event_log.dart` | 322 | `SessionEventLog` — SHA-256 hash-chained, append-only event log. Tamper-evident, not tamper-proof (stated in-file). |
| `lib/core/telemetry/edit_event.dart` | 35 | Structural edit-event enum. |
| `lib/core/telemetry/keystroke_capture.dart` | 119 | Live keystroke capture plumbing. |
| `lib/core/telemetry/keystroke_event.dart` | 202 | Keystroke event classification. |
| `lib/core/telemetry/process_telemetry.dart` | 212 | Aggregates keystroke/edit events into the 3 trigger patterns. |
| `lib/core/verification/biometric_metrics.dart` | 87 | FAR/FRR/EER statistics over labelled score pairs (pure math, no baked-in threshold). |
| `lib/core/verification/capture_quality_head.dart` | 85 | Capture-quality scoring (brightness/sharpness/size). |
| `lib/core/verification/capture_stability_labels.dart` | 61 | Labels for within-session capture stability. |
| `lib/core/verification/face_engine.dart` | 127 | `HttpFaceEngine` — HTTP client to the Python face service. |
| `lib/core/verification/identity_matcher.dart` | 120 | Cosine-similarity match/mismatch/unchecked decision logic, threshold=0.50 (documented as reasoned, not validated). |
| `lib/core/verification/platt_scaler.dart` | 148 | Logistic calibration of raw similarity → probability, real `fit()`, honest `uncalibrated()` passthrough. |
| `lib/core/verification/verification_result.dart` | 88 | Sealed `Verified`/`Mismatch`/`Unchecked` — no fabricated "0% pass" state. |
| `lib/core/verification/verification_session.dart` | 261 | Jittered continuous re-verification loop, strike escalation. |
| `lib/core/verification/within_session_baseline.dart` | 70 | Self-similarity baseline from repeated captures. |
| `lib/core/workspace/workspace_loader.dart` | 134 | Loads all stored sessions for dashboard/workspace views. |
| `lib/core/workspace/workspace_stats.dart` | 353 | Computes live dashboard figures, no fabricated numbers. |
| `lib/dev/live_interview_demo.dart` | 96 | Standalone dev harness — the only place `LiveInterviewScreen` is ever instantiated. |
| `lib/features/analysis/resume_analysis_screen.dart` | 643 | Resume upload + claim review/edit/confirm UI. |
| `lib/features/audit/claim_audit_screen.dart` | 351 | Claim audit (report) viewer, links to graph/model-decision screens. |
| `lib/features/candidates/candidates_screen.dart` | 1,026 | List + `_CandidateCard` + `CandidateProfileScreen` (detail) — **recommend splitting into 2 files**. |
| `lib/features/common/empty_state.dart` | 172 | Shared empty-state widget. |
| `lib/features/dashboard/dashboard_screen.dart` | 524 | Workspace dashboard — real arithmetic only, explicitly strips the mockup's fabricated score cards. |
| `lib/features/enrolment/enrolment_controller.dart` | 104 | Enrolment state machine (captured/rejected/failed). |
| `lib/features/enrolment/enrolment_screen.dart` | 261 | Face enrolment capture UI. |
| `lib/features/graph/evidence_graph_screen.dart` | 568 | Evidence graph viewer. Contains 3 hardcoded `Color(0x...)` values bypassing the theme extensions. |
| `lib/features/graph/graph_layout.dart` | 133 | Graph node layout algorithm. |
| `lib/features/interview/interview_controller.dart` | 319 | Pure-Dart interview state machine driving `InterviewScreen`. |
| `lib/features/interview/interview_screen.dart` | 521 | **The interview screen users actually reach.** |
| `lib/features/interview/interview_voice_controller.dart` | 201 | Voice-presence state machine for `LiveInterviewScreen`; `_lastAnswerScore` hardcoded to `1`. |
| `lib/features/interview/live_interview_screen.dart` | 1,013 | **Dead code from the shipping app's perspective** — full mic/TTS/presence UI, only reachable via the dev harness. |
| `lib/features/reports/reports_screen.dart` | 303 | Reports listing screen. |
| `lib/features/resume/resume_pick.dart` | 124 | File-picker wrapper for resume upload. |
| `lib/features/resume/resume_text_extraction.dart` | 170 | Real PDF/.docx text extraction, on-device. No explicit zip-bomb hardening found. |
| `lib/features/resume/resume_upload_card.dart` | 250 | Upload UI card. |
| `lib/features/reviewer/model_decision_screen.dart` | 394 | ML sufficiency model decision viewer. |
| `lib/features/roles/roles_screen.dart` | 618 | Role CRUD + coverage viewer. |
| `lib/features/session/verification_status_card.dart` | 151 | Identity-verification status widget. |
| `lib/features/sessions/session_history_screen.dart` | 278 | Session history list. |
| `lib/features/settings/settings_screen.dart` | 482 | Settings screen. |
| `lib/features/task/task_screen.dart` | 225 | Backs the rail's "Telemetry" label — **class/file name doesn't match the rail label**. |
| `lib/main.dart` | 904 | Composition root — the real navigation graph, `SessionDraft`/enrolment/role-loading owner. |
| `lib/ui/app_shell.dart` | 1,052 | Shell chrome — rail, top bar, `IndexedStack` destination switch, `AppShellController`. |
| `lib/ui/components.dart` | 429 | Additional shared components (cards, buttons — not deep-read this pass). |
| `lib/ui/patterns.dart` | 1,487 | Flat catalogue of ~18 presentational widgets (charts, tags, rows) — **recommend splitting by family**. |
| `lib/ui/tokens.dart` | 94 | Spacing/breakpoint/motion/typography constants. |

---

## 22. Widget Tree (largest screens)

Covered in depth for the 4 largest files in Section 5 / above table. Summary of nesting depth and structure:

- **`lib/ui/app_shell.dart`** — `AppShell` → `Scaffold` → `SafeArea` → `Row`(wide)/`Column`(compact) → `_Rail`/`NavigationBar` + `_TopBar` + body `IndexedStack`. ~6–7 levels at the deepest branch point, appropriate for a shell.
- **`lib/features/candidates/candidates_screen.dart`** — `CandidatesScreen` (list) → `_CandidateCard` (per row) is one subtree; `CandidateProfileScreen` (pushed separately) is a second, structurally unrelated subtree living in the same file.
- **`lib/features/interview/live_interview_screen.dart`** — `LiveInterviewScreen` → `_TopBar`/`_MicButton`/`_StatusPill`/`_PresenceIndicator`/`_CaptionLine`/`_InputRow`/`_EndedRow`, all properly delegating logic to `widget.controller` rather than embedding it in `build()` — clean structure, undermined only by being dead code.
- **`lib/ui/patterns.dart`** — no single tree; ~18 independent, shallow (3–5 level) component trees, several backed by `CustomPainter`s (`RingGauge`, `RadarChart`) for the actual geometry.

No other screens were widget-tree-mapped in this pass beyond what's in the tables above — flagged as a scoping decision (the 4 largest cover the highest-value ground; the remaining ~85 screens/widgets are smaller and lower-risk).

---

## 23. Service Dependency Graph

```
OllamaClaimExtractor ──uses──► HeuristicClaimExtractor (fallback only, not a pipeline stage)
        │
        ▼
SessionDraft ──holds confirmed claims──► orderClaimsForRole (if Role picked)
        │
        ▼
InterviewController ──uses──► QuestionBank, FollowUpGenerator, ProcessTelemetry
        │
        ├──uses──► VerificationSession ──uses──► IdentityMatcher ──uses──► HttpFaceEngine
        │
        ▼
SessionEventLog (independent, append-only, no dependency on the above beyond receiving events)
        │
        ▼
ClaimAuditBuilder ──consumes──► claims + evidence map + reviewerAssessments + identityAttempts
        │
        ▼
JsonFileAuditStore ──persists──► ClaimAudit
        │
        ├──feeds──► EvidenceGraphBuilder / graph_from_audit.dart
        ├──feeds──► AuditExport (HTML)
        └──feeds──► decision_from_audit.dart ──feeds──► SufficiencyModel (synthetic-only)

[Separate, parallel, not connected to the above]:
LiveTurnClient ──used only by──► LiveInterviewScreen (dead) ──uses──► InterviewVoiceController
        (InterviewVoiceController._lastAnswerScore hardcoded, never fed by a real scoring service)

[Separate, parallel, not connected to the above]:
RouteResolver ──consumes──► AppRoutes + Principal (from AuthStore)
        (nothing in the running app calls RouteResolver.resolve() — orphaned)
```

**Circular dependencies:** none found in this pass.
**Bad/tight coupling:** `SessionDraft` is coupled to `Role`/`orderClaimsForRole` directly (a `core/session` file importing `core/roles`) — reasonable given the stated design ("act, not just describe" — see the file's own doc comment), but worth naming as a cross-module coupling point if `roles` is ever split into a separate package. The bigger structural issue isn't circular dependency — it's the **disconnection** of two whole subgraphs (RBAC/auth, and the LiveTurnClient/LiveInterviewScreen pair) from the graph that's actually exercised at runtime.

---

## 24. Data Model

Covered in full detail in the Data Model Audit above (Part A). Summary table:

| Model | Fields | Self-serializing? | Missing for production |
|---|---|---|---|
| `Claim` | id, text, source, skill? | No (external codec) | No candidateId/session FK, no timestamp, no extraction-method provenance |
| `ClaimFinding`/`ClaimAudit` | claim, status, evidence[] / findings[], sessionStart/End, identityAttempts[], sessionEventsJsonl | No | No auditId, candidateId, reviewerId, or version field on the audit itself |
| `Role`/`SkillCoverageRow` | id, title, requiredSkills[], desirableSkills[], notes, createdAt | **Yes** (inconsistent with the rest) | No canonical skill taxonomy — stringly-typed skill matching |
| `VerificationResult` (sealed: Verified/Mismatch/Unchecked) | at + subtype fields | No | No deviceId/matcherVersion/threshold-at-time-of-check |
| `EnrolmentProfile` | embedding[512], capturedAt, faceSize | No (in `json_codec.dart`) | No candidateId, no expiry, no model-version tag (a model swap silently makes old embeddings incomparable), **no migration path on schema bump — hard throw** |
| `SessionEntry`/`SessionEventLog` | sequence, kind, at, payload, previousHash, hash | Partial (`SessionEntry.toJson` only) | No actor/identity field distinguishing human vs. system vs. candidate action |
| `GraphNode`/`GraphEdge`/`EvidenceGraph` | id, claimId, type, payload (untyped map), createdAt / id, from, to, type, rationale, basis, createdBy | No | `payload` is untyped (no compile-time guard against a mismatched node type), `createdBy` conflates human-name and model-version into one untyped string, one graph per claim (no session-level aggregate) |

---

## 25. Current Routing

```
App
 ↓
HomeScreen (no auth gate — reachable directly)
 ↓
AppShell destination switch (string-keyed goTo())
 ├─ Dashboard          [public — no permission check exists at runtime]
 ├─ Candidates         [public]
 ├─ Roles              [public]
 ├─ New session        [public]
 ├─ Resume analysis    [public]
 ├─ Sessions           [public]
 ├─ Reports            [public]
 ├─ "Telemetry"→TaskScreen [public]
 └─ Settings           [public]
      ↓ (stack pushes, also unguarded)
      Enrolment → InterviewScreen → ClaimAuditScreen → {EvidenceGraphScreen, ModelDecisionScreen}
      CandidatesScreen → CandidateProfileScreen
```

**Public/Private:** everything is effectively public — there is no principal, no sign-in gate, so "private" as a concept doesn't apply to the running app at all. The *would-be* private/public split exists only in the orphaned `AppRoutes` table (`/auth/*` signed-out-only, `/hr/*` recruiter-only, `/candidate/*` candidate-only per its own doc comment).

**Unused:** `AppRoutes`/`RouteResolver` themselves (the whole table, unused).
**Dead:** the navigation path into `LiveInterviewScreen` from the shipping app — it simply doesn't exist; only the dev harness reaches it.

---

## 26. Event Flow

```
User clicks "New session"
    ↓
AppShellController.goTo('New session')  (string-keyed IndexedStack switch)
    ↓
SessionDraft is read/mutated live by the setup form widgets

User picks a resume file
    ↓
ResumePicker (file_picker) → SessionDraft.beginPick()
    ↓
resume_text_extraction.dart (PDF/.docx → text)
    ↓
OllamaClaimExtractor.extract() [or heuristic fallback on failure]
    ↓
SessionDraft.completeExtraction() → review list populated (DraftClaim per item)

User edits/deselects claims, clicks confirm
    ↓
SessionDraft.confirmReviewed() → confirmedClaims populated (extraction alone never does this)

User picks a Role (optional)
    ↓
SessionDraft.targetRole = role → effectiveClaims reordered via orderClaimsForRole()

User clicks "Start verified interview"
    ↓
Navigator.push(InterviewScreen(claims: effectiveClaims, ...))
    ↓
InterviewController constructed → SessionEventLog.append(sessionStarted)
    ↓
Per claim: QuestionBank.ladderFor() builds the scripted ladder
    ↓ (candidate types)
ProcessTelemetry classifies keystroke pattern → FollowUpGenerator may inject a follow-up
    ↓ (every ~20s, jittered)
VerificationSession → HttpFaceEngine → IdentityMatcher.compare() → SessionEventLog.append(identityChecked)

User clicks "End session"
    ↓
InterviewController finalizes → ClaimAuditBuilder.build()
    ↓
JsonFileAuditStore.saveAudit() → plaintext JSON written (atomic write-then-rename)
    ↓
Navigator.push(ClaimAuditScreen) — reviewer reads the non-scored per-claim verdicts
```

---

## 27. Async Operations

| Operation | Type | Notes |
|---|---|---|
| `OllamaClaimExtractor.extract()` | `Future`, blocking-with-timeout (90s) | Real network call, awaited, has a fallback path |
| `LiveTurnClient.nextTurn()` | `Stream` (streaming HTTP response) | Incrementally parses the `say` field for TTS as it arrives |
| `HttpFaceEngine` calls | `Future` | Per-frame HTTP POST, awaited inside `VerificationSession`'s timer loop |
| `VerificationSession` | Timer-driven, jittered ~20s interval | Not a `Stream`/`Isolate` — a periodic `Future`-returning check |
| `JsonFileAuditStore` reads/writes | `Future`, `dart:io` file operations | Atomic write-then-rename; not backgrounded to an `Isolate` — large file I/O could block the UI thread on very large audits, not verified as an actual issue at current data sizes |
| Resume text extraction (PDF/.docx) | `Future` | Synchronous parsing library calls wrapped in async functions — CPU-bound work is not offloaded to an `Isolate`; a very large/adversarial file could block the UI thread (see Section 31 on resource-exhaustion risk) |
| `speech_to_text`/`flutter_tts` | Plugin-driven async/streams | Only exercised via the dead `LiveInterviewScreen` path |

No explicit `Isolate.spawn` usage found anywhere in `lib/` — all async work is `Future`/`Stream` on the main isolate. For current demo-scale data this is unlikely to matter; flagged as a thing to revisit if resume parsing or large-audit I/O ever becomes a measured bottleneck.

---

## 28. Storage Audit

| Data | Where | Durable? | Notes |
|---|---|---|---|
| Resume file | Memory only during extraction | No | Never persisted as a file by the app itself |
| Extracted/confirmed claims | `SessionDraft` (memory) until session ends, then embedded in the saved `ClaimAudit` JSON | Yes, once saved | |
| Enrolled face embedding | `enrolment.json`, app-support dir | Yes (desktop/mobile) / No (web — stub is in-memory only) | Plaintext, no encryption |
| Completed audits/reports | `session-<timestamp>.json`, app-support dir | Yes (desktop/mobile) / No (web) | Plaintext, atomic write, **no integrity protection on this file itself** |
| Session event log (hash chain) | Embedded inside the saved audit JSON (`sessionEventsJsonl` field) | Yes, same as above | Tamper-evident, not tamper-proof |
| Roles | File-backed via `RoleStoreIo`, same app-support dir pattern | Yes (desktop/mobile) / No (web) | |
| Settings/theme preference | Not traced in this pass — likely `SharedPreferences` or similar, not directly verified | Unknown | Flagged as unverified rather than assumed |
| ML model weights | `assets/ml/sufficiency_model.json`, bundled with the app binary | Yes (read-only, ships with app) | Checked into the repo intentionally, per its own doc comment |

---

## 29. AI Prompt Audit

Fully covered in Section 10 above (the "Every prompt found" table + grounding-discipline paragraph). Not duplicated here to avoid redundancy — see Section 10 for file:line citations, variables, output contracts, and per-prompt wiring status.

---

## 30. Error Handling

| Failure | What happens |
|---|---|
| PDF/.docx parse fails | Reported failure (try/catch around the Syncfusion/archive calls), never a fabricated empty success — confirmed by direct read of `resume_text_extraction.dart` |
| Ollama unreachable (claim extraction) | Falls back to `HeuristicClaimExtractor`, `ClaimExtraction.degradedReason` set and disclosed |
| Ollama unreachable (live turn) | `LiveTurnClient` throws `TurnDegraded`; the class's own doc states the caller should fall back to `QuestionBank`/`FollowUpGenerator` — **the actual fallback wiring was not fully verified in this pass** (only the throw side was directly confirmed) |
| Camera unavailable | Not directly traced in this pass — `enrolment_controller.dart` has a `Rejected`/`Failed` sealed outcome, consistent with the app's general no-silent-failure pattern, but the exact camera-unavailable code path wasn't read line-by-line |
| Microphone denied | Only relevant to the dead `LiveInterviewScreen` path — not traced |
| Face service offline | `HttpFaceEngine` failure → `IdentityMatcher.compare()` receives no embedding → `Unchecked(reason: serviceUnreachable)`, never a fabricated pass — confirmed via `verification_result.dart`'s sealed-type design |
| Hash chain verification fails | `verifyIntegrity()` returns `IntegrityBroken(firstBrokenSequence, detail)` — a real result type, not an exception swallowed silently. **Note:** decoding a log from JSONL does **not** automatically call `verifyIntegrity()` — a caller that forgets to call it explicitly gets a structurally-valid-looking but potentially-tampered log with no error raised |
| Storage full / write failure | Not directly traced in this pass — the atomic write-then-rename pattern implies *some* crash-safety intent, but explicit "disk full" handling wasn't verified |

---

## 31. Security Review

Full findings from the dedicated security audit — see the summary at Section 12; repeating the most load-bearing details here per the original prompt's structure:

- **Bypass interview?** No code path found that skips `InterviewController`/`ClaimAuditBuilder` to fabricate a result — the audit is always built from what was actually recorded.
- **Modify reports?** **Yes, trivially** — saved `ClaimAudit` JSON files have zero integrity protection (no hash, no signature); anyone with filesystem access can hand-edit any field and it loads back without complaint.
- **Modify claims?** Only before `confirmReviewed()` is called (that's the intended edit point). After a session is saved, same answer as "modify reports" — no protection.
- **Replay sessions?** No replay-prevention mechanism found (no nonces, no single-use tokens) — there's no server-side component to enforce this against besides the stateless face-embedding service.
- **Change evidence?** Same as "modify reports" — the saved JSON is the evidence, and it's unprotected once written.
- **Spoof identity?** Yes — no liveness detection exists anywhere in the codebase (confirmed by whole-repo grep for liveness/anti-spoof/blink/challenge-response terms — zero hits in `lib/` or `service/`). A photo, screen replay, or deepfake is not defended against by anything found here.
- **Vulnerabilities:** plaintext storage, no encryption at rest, `InMemoryAuthStore`'s plaintext password comparison (not production-relevant since it's unwired, but a real weakness if ever activated as-is), CORS wide open on the face service (`allow_origins=["*"]`), no explicit resource-exhaustion hardening on PDF/.docx parsing (relies entirely on third-party library behavior, not audited here).

---

## 32. Code Metrics

- **Largest files:** `lib/ui/patterns.dart` (1,487), `lib/ui/app_shell.dart` (1,052), `lib/features/candidates/candidates_screen.dart` (1,026), `lib/features/interview/live_interview_screen.dart` (1,013 — dead code), `lib/main.dart` (904), `lib/core/features/feature_registry.dart` (729).
- **Largest widgets:** see Section 22 (Widget Tree) — `candidates_screen.dart` effectively contains 2 full screens' worth of widget tree in one file.
- **Longest methods:** not individually profiled line-by-line in this pass beyond what's cited above (`_AppShellState.build()` branches ~6–7 levels deep; `ClaimAuditBuilder.build()` and `SessionEventLog._computeHash`/`_writeCanonical` are the most logically dense single methods encountered, both well under 50 lines each based on the file sizes).
- **Most imports / deepest widget tree:** `app_shell.dart` and `candidates_screen.dart` are the standout cases (see Section 22).
- **Most duplicated logic found:** the `interview_agent.v2.txt` / `live_turn_client.dart:176` hand-synced prompt duplicate (already caused one documented production bug from drift) is the single clearest duplication finding in this audit — more significant than any code-level copy-paste found.
- **Unused / dead code:** `LiveInterviewScreen` (1,013 LOC) + its exclusive dependents (`InterviewVoiceController`'s real usage, `flutter_tts`/`speech_to_text` packages); the entire `lib/app/routes.dart` + `lib/core/rbac/*` + `lib/core/auth/*` subsystem (334 + 443 LOC ≈ 777 LOC); `cupertino_icons` dependency; `prompts/interview_agent.v1.txt` and `prompts/scoring_agent.txt`/`report_agent.txt` (unwired prompt files, not Dart code but dead nonetheless).

---

## 33. Package Audit

Covered in full in Section 11 — not duplicated here. One package worth a second flag: **`syncfusion_flutter_pdf`** is used and load-bearing (real PDF extraction), but it's a commercially-licensed package family — verify the license tier this project is actually entitled to (free Community License has revenue/employee-count caps) before any commercial deployment plan is finalized.

---

## 34. UI Consistency Audit

Covered in Section 5 — off-scale `EdgeInsets` values and hardcoded `Color(0x...)` literals in ~7 feature files, bypassing an otherwise-real and otherwise-mostly-followed token system. No inconsistency was found in border-radius usage or button styling in the files actually inspected (not exhaustively checked across all 104 files — this is a sampled finding, not a full sweep).

---

## 35. Naming Audit

- **Rail label "Telemetry" ≠ underlying file/class name `task_screen.dart`/`TaskScreen`** — a real find-by-name trap.
- **`lib/core/features/`** (ML feature-vector assembly) vs. **`lib/features/`** (UI screens) — a genuine naming collision between two completely different meanings of "feature" in the same codebase. Not a bug, but a real source of confusion for anyone new to the repo (including, per this audit's own research agents, momentary confusion during investigation).
- **`Role.required_`** field (trailing underscore because `required` is a Dart reserved word) — a minor but real naming compromise, not wrong, just worth knowing about if `Role` is ever redesigned.
- No other systematically bad naming was found in the files read this pass — the codebase generally favors descriptive, unabbreviated names (`ClaimAuditBuilder`, `VerificationSession`, `orderClaimsForRole`) consistently.

---

## 36. Configuration Audit

Fully covered in Section 17 — `lib/core/config.dart` is the single source of runtime configuration, no scattered magic numbers/URLs found elsewhere for these same values (spot-checked; not exhaustively grepped across all 104 files for every possible hardcoded number). `AppConfig.minEnrolmentFaceSize` (15000) is the one non-URL constant in that file and is not overridable via dart-define, unlike the three URL/model values.

---

## 37. Build Pipeline

- **Desktop (Windows):** standard Flutter Windows runner under `windows/runner/`; `windows/flutter/generated_plugin_registrant.cc` and `generated_plugins.cmake` are present (auto-generated, currently showing as modified in git status — a normal artifact of `flutter pub get`, not hand-edited).
- **Android:** standard `android/app/` scaffold, `applicationId = "com.cognihire.cognihire"`, `minSdk`/`targetSdk` both deferred to the Flutter-provided defaults (no custom override found).
- **Web:** `web/index.html`, `manifest.json`, `favicon.png`, `icons/` — standard Flutter web scaffold, no custom service-worker or PWA customization found beyond the defaults.
- **Assets:** exactly one non-default asset declared in `pubspec.yaml` — `assets/ml/sufficiency_model.json` (the checked-in model weights). No custom fonts declared (uses Flutter's default Material typography plus the app's own `AppTheme` text-style definitions, not custom font files).
- **Icons:** default Flutter template icons appear present under `android`/`web`/`windows` platform folders — not verified whether these were ever customized to a CogniHire-specific icon (out of scope for this pass; worth a visual check).
- **Generated files:** `windows/flutter/generated_plugin_registrant.cc`/`generated_plugins.cmake` (Windows plugin registration, regenerated by tooling, currently modified per `git status` — likely just a pending `flutter pub get` sync, not a hand-edited file).

---

## 38. Future Migration Risks

If the following are added, here's what in the existing code will need to change or will actively fight the addition:

- **Supabase (or any cloud DB):** every domain model (`Claim`, `Role`, `ClaimAudit`, `EnrolmentProfile`) lacks any tenant/org-scoping field — a migration would need to add these fields *and* decide how existing local JSON files map onto new cloud rows. `JsonFileAuditStore`'s file-per-session model has no concept of "sync state," so a local-first-with-cloud-sync design isn't a small addition — it's closer to a second storage backend implementing the same `AuditStore`/`RoleStore` interfaces (which is at least a real, already-abstracted seam — those interfaces exist and are used consistently, which helps).
- **RBAC:** already built — the risk here is different from most items: whoever wires it in needs to audit **every** navigation call site to make sure `RouteResolver.resolve()` is actually consulted, since right now `AppShellController.goTo()` and every `Navigator.push()` bypass it completely. Wiring it in incompletely (e.g., only gating the rail, not the stack pushes) would create a false sense of security worse than the current honest "nothing is gated."
- **Organizations / multi-tenancy:** same root problem as Supabase above — no model has an org-scoping field, and `WorkspaceStats`/`WorkspaceLoader` currently assume a single global pool of sessions with no tenant filter anywhere in their aggregation logic.
- **Realtime:** nothing in the current architecture streams state between clients — `SessionDraft`/`InterviewController` are single-process, in-memory objects with no network sync layer; adding realtime means introducing a sync mechanism from scratch, not extending an existing one.
- **Cloud AI (replacing local Ollama):** `AppConfig.ollamaBaseUrl`/`ollamaModel` being externally configurable is a genuine seam here — swapping the base URL is trivial. What will NOT be trivial: the grounding-gate discipline (exact substring match) and the "resume never leaves the machine" privacy promise stated explicitly in the pubspec comments would need to be re-litigated as a product decision, not just a config change, if claim extraction ever calls a cloud model.
- **Multiple interviewers:** the RBAC model as designed only has 2 roles (recruiter, candidate) — there is no "multiple reviewers on one claim" concept anywhere in the domain model (`ClaimFinding` has one `status`, not a per-reviewer list). This was flagged and deliberately deferred this session as needing new identity/role infrastructure, not a bolt-on.
- **Multi-tenant:** see Organizations above — same underlying gap.

---

## 39. Rewrite Candidates

Files where refactoring in place is likely more expensive than a clean rewrite, and why:

- **`lib/features/interview/live_interview_screen.dart` (1,013 LOC):** not because the code is bad — the navigation/UI audit found it cleanly structured, logic properly delegated to a controller — but because its entire reason for existing (become "the" interview screen, or get deleted) is an unresolved product decision, not an engineering one. Refactoring it now, before that decision, risks polishing code that gets deleted. **Recommend: decide first, rewrite/delete second — don't refactor in the dark.**
- **`InMemoryAuthStore` → real `AuthStore`:** this isn't a refactor target at all, it's meant to be replaced wholesale by a real backend implementation (`SupabaseAuthStore` or equivalent) — the class's own doc comment says as much. Nothing about extending `InMemoryAuthStore` incrementally gets you to production auth; a new implementation of the existing `AuthStore` interface is the right shape, which is good news — the interface itself doesn't need to change.
- **`lib/features/candidates/candidates_screen.dart`:** a mechanical split (list screen / profile screen into two files), not a rewrite — flagging it here only to distinguish it from genuine rewrite candidates: this one is cheap and low-risk.

No other files in this audit rose to "rewrite, don't refactor" — the domain layer (`lib/core/*`) is consistently well-factored enough that incremental improvement (Section 19's roadmap) is the right approach for nearly everything else found.

---

## 40. Questions for the Architect

Based on everything above, here is what needs a human decision before this becomes production software — genuinely open questions, not rhetorical ones:

1. **Is `LiveInterviewScreen` the intended future interview experience, or should it be deleted?** This blocks any further investment in either `InterviewScreen` or `LiveInterviewScreen`/`LiveTurnClient`/the voice stack.
2. **Should the existing RBAC/route-guard system be wired in as-is, or redesigned first?** It's built, tested, and sitting idle — is the 2-role (recruiter/candidate) model still the right shape, or does a real backend change what roles should exist?
3. **What replaces `InMemoryAuthStore`?** Supabase Auth (implied by the class's own comment), a custom backend, or something else — and does that choice change the `Principal`/`UserRole` model at all?
4. **Should `scoring_agent.txt` be wired in for real, or deleted along with the answer-scoring concept?** Right now the live-turn prompt's own stated rules run on fake data — that's either a bug to fix or a feature to formally drop.
5. **Is `report_agent.txt` (LLM-generated report summaries) still wanted, given the product's explicit no-numeric-score, no-fabricated-summary design principle elsewhere?** It currently contradicts the deterministic, no-model-call design of `ClaimAuditBuilder` — reconcile or remove.
6. **Should saved `ClaimAudit` JSON files get the same hash-chain/integrity protection as the session event log, or is a different mechanism (e.g., a signature, a server-side copy) intended?**
7. **Is real liveness detection in scope at all, or is the product's honest stance meant to be "we don't defend against this, and we say so"?** This is a legitimate product answer, not necessarily a gap to close — but it needs to be a decision, not a silence.
8. **What does "organization" mean for this product?** Does a recruiter's org own candidates, roles, and sessions — or do candidates own their own data across multiple orgs' interviews? This decides the entire multi-tenancy shape and every model's foreign-key design.
9. **Can a candidate be interviewed more than once for the same role?** Nothing in the current `Role`/`ClaimAudit` model prevents or tracks this either way.
10. **Should completed reports/audits be immutable once saved, or editable by a recruiter (e.g., adding a note)?** Currently they're accidentally-mutable (no protection) rather than deliberately either — pick one.
11. **Can HR/recruiters edit claims after a session, or only annotate/review them?** `reviewerAssessments` exists as an input to `ClaimAuditBuilder`, but whether that's meant to be a permanent, append-only annotation layer or a live-editable one wasn't determined in this audit.
12. **Can the AI regenerate a report/audit after the fact** (e.g., after a re-review), and if so, does the old version need to be retained for auditability?
13. **Should interviews be resumable** if a candidate's session is interrupted (browser closed, app crashed) — nothing in `InterviewController`/`SessionEventLog` currently supports resuming a partial session; the state is in-memory until `saveAudit()` is called at the end.
14. **What's the actual retention/deletion policy for enrolled face embeddings and interview data?** No expiry, no deletion flow beyond the existing "clear enrolment" affordance was found — is that a legal question (candidate data-deletion requests) that needs answering before any production launch?
15. **Is single-tenant, local-storage-only ever meant to be a supported deployment mode** (e.g., for a privacy-focused customer who explicitly doesn't want cloud storage), or is cloud/multi-tenant the only future target? This changes whether `JsonFileAuditStore` should be kept as a permanent option or is purely a stepping stone to delete later.

---

*End of report. This reflects the codebase exactly as it exists on disk as of this audit — nothing here describes intended, planned, or aspirational functionality unless explicitly labeled as such.*
