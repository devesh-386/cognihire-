# CogniHire — Product Overview

*Verified-claim interview intelligence. The AI measures the evidence. It never decides the person.*

---

## The Problem, Concretely

A recruiter receives a resume, conducts a 45-minute interview, and finally records:

> "Strong communication. Good Flutter knowledge. 8.7/10."

Six months later, nobody can explain why that score was given. The candidate can't appeal it — there's nothing to appeal, just a number. The recruiter can't defend it — they don't remember the specifics either. And under NYC Local Law 144, the Illinois AI Video Interview Transparency Act (effective 2026-01-01), and the EU AI Act's high-risk classification for hiring tools, an unexplainable score is now a *legal* liability, not just an unsatisfying one.

CogniHire was built to close that gap: not by scoring better, but by never producing an unexplainable score in the first place.

---

## Design Principles

These aren't aspirations — each one is enforced in code, not just prose.

**Evidence over scores.** No candidate ever receives a numerical rating. The claim audit is a set of per-claim verdicts (`substantiated` / `notDemonstrated` / `contradicted` / `notExamined`), not a composite number. There is no code path that produces one.

**Human review required.** A claim never becomes "evidence" without a reviewer looking at it. The system never auto-rejects; a session is either resolved with an audit or flagged for human review.

**Privacy by default.** No resume or interview data leaves the device. The face-matching service runs locally over HTTP to `localhost`; there is no cloud API call in the verification path.

**Everything explainable.** Every claim status links back to the specific evidence that produced it — a transcript excerpt, a verification timestamp, a telemetry pattern. Nothing is asserted without a pointer to why.

**Failure is explicit.** A measurement that couldn't be taken is reported as `Unchecked` or `notExamined`, never silently defaulted to pass or fail. "Could not measure" and "measured and it failed" are different states and the UI never conflates them.

---

## System Architecture

```
Resume
  │
  ▼
┌────────────────────────┐
│ Claim Extraction         │  Turns resume text into a list of discrete,
│ (local Ollama, grounded) │  checkable claims — grounded against the
└────────────────────────┘  resume so the model can't invent a claim
  │                          the candidate never made.
  ▼
┌────────────────────────┐
│ Grounding Gate            │  Discards any claim text that isn't verbatim
└────────────────────────┘  in the resume. Prevents the LLM from
  │                          hallucinating skills onto a candidate.
  ▼
┌────────────────────────┐
│ Candidate Confirmation    │  Candidate sees the extracted claims before
└────────────────────────┘  the interview starts — no surprise claims.
  │
  ▼
┌────────────────────────┐
│ Interview Engine           │  Adaptive follow-ups triggered by process
│ (identity + process)      │  telemetry (see below). Continuous face
└────────────────────────┘  verification every 15–25s, jittered.
  │
  ▼
┌────────────────────────┐
│ Evidence Store             │  Hash-chained, append-only. Every
│ (hash-chained)            │  verification attempt, transcript turn,
└────────────────────────┘  and telemetry event is a linked record —
  │                          tamper-evident, not just tamper-resistant.
  ▼
┌────────────────────────┐
│ Claim Audit                │  One verdict per claim, each backed by an
└────────────────────────┘  evidence pointer. No recommendation.
  │
  ▼
HTML Report (exportable, leaves the app by design — see Trust Boundaries)
```

### Why each subsystem exists

| Subsystem | Prevents / Ensures |
|---|---|
| **Grounding Gate** | Prevents the language model from inventing resume claims the candidate never made. |
| **Continuous identity verification** | Ensures the evidence being collected belongs to the enrolled candidate, not a substitute mid-interview. |
| **Process telemetry** (`bulkInsert`, `pauseThenBulk`, `immediateAnswer`) | Distinguishes "candidate is thinking and typing" from "candidate is pasting a prepared or fed answer." |
| **Adaptive follow-ups** | Forces live comprehension. Pasting an answer is easy; explaining it under a follow-up, live, is materially harder. |
| **Evidence Store (hash chain)** | Makes the audit trail tamper-evident — a reviewer or regulator can verify nothing was edited after the fact. |
| **Claim Audit (no score)** | Regulatory ceiling: NYC LL144, Illinois AIVI, and the EU AI Act all penalize opaque composite scores. A verdict with a citation is defensible; a number is not. |

### Interview engine detail

```
Claim Queue → Question Generator → Candidate Response → Evidence Evaluator
                    ▲                                          │
                    └──────────── Next Question ◄───────────────┘
```

The evaluator inspects both the answer content and the process telemetry from the moment the question was posed. A telemetry anomaly (e.g. `pauseThenBulk`) routes back into the question generator as a forced follow-up on the same claim before the queue advances — the interview adapts to what it just observed, rather than logging it for later review.

---

## Trust Boundaries

```
┌──────────────────────────────────────┐
│ Device                                 │
│                                        │
│  Resume · Ollama (local LLM) ·         │
│  Face verification (local service) ·  │
│  Evidence store · Reports              │
│                                        │
└──────────────────────────────────────┘
No cloud communication in the verification or claim-extraction path.
```

The only thing that leaves the device by design is the exported HTML audit — because the audit's entire purpose is to be defensible *outside* the app, in front of a recruiter, a candidate, or a regulator.

---

## A Complete Walkthrough

**Resume excerpt:**
```
Built a Flutter desktop application with offline caching.
Implemented SQLite-backed local storage.
```

**Claim extraction (grounded against the resume above):**
```
✓ "Built a Flutter desktop application with offline caching."
✓ "Implemented SQLite-backed local storage."
```

**Interview:**
```
Question: "Can you explain how your cache invalidation worked?"
Candidate answers live.

Evidence collected:
✓ Response transcript
✓ Typing/edit pattern for this answer (no bulkInsert flag)
✓ Identity verification: passed (3 checks during this segment)
```

**Audit entry:**
```
Claim:      "Built a Flutter desktop application with offline caching."
Status:     Substantiated
Evidence:   Question 3 transcript · typing pattern · verification log
```

One claim, one traceable chain from resume text to verdict. Every claim in the audit follows this same shape — that consistency is what makes the report scannable.

---

## The Application — What's on Screen

Grouped by what the user is doing, not listed flat.

### Core Workflow
| Screen / Button | Purpose |
|---|---|
| Identity enrolment → **Discard enrolment** | Candidate can back out of face enrolment cleanly; nothing is captured until they explicitly proceed. |
| Live interview → **Submit** | Commits the candidate's current answer; triggers the evidence evaluator. |
| Live interview → **End session** | Closes the interview and finalizes whatever evidence has been collected so far — never silently discards it. |
| Task screen → **Preview the questions** | Lets a candidate see what's coming before committing to start, reducing surprise mid-flow. |

### Evidence Review
| Screen / Button | Purpose |
|---|---|
| Claim audit → **Full claim audit** / **Export full audit as HTML** / **Export as HTML** | The audit is meant to leave the app and be defensible on its own — exportable, not locked behind the tool. |
| Evidence graph → **View evidence graph** / **Model view** | Lets a reviewer inspect *why* a verdict was reached, not just the verdict itself. |
| Reviewer → **Model decision** | Shows the rules-engine verdict path directly — no hidden scoring step between evidence and conclusion. |
| Sessions → **Past sessions** / **Open the sample audit** | A reviewer can compare a live case against a known-good sample before trusting a verdict. |

### Administration
| Screen / Button | Purpose |
|---|---|
| Roles → **New role** / **Save role** / **Edit this role** (tooltip) / **Delete this role** (tooltip) | Role definitions are editable and disposable — nothing about a role is baked in permanently. |
| Sessions → **Delete this session** (tooltip) / **Delete** / **Clear filter** (tooltip) | Deletion is available but distinct from export — you can't accidentally lose an audit while trying to view one. |
| Settings → **Light** / **Dark** / **System** | Standard theme control, no evidentiary weight. |

**UX rule behind all of it:** buttons disable rather than lie. If an action isn't valid yet (no session selected, no evidence collected), the control is inert — it never fires and produces a fabricated or empty result. And where an action is destructive, **Keep it** is offered before **Delete** — the safe path is never the one requiring an extra click to find.

---

## Engineering Metrics

| Metric | Value |
|---|---|
| Test suite | 662 tests, `flutter analyze` clean |
| Screens | 14 (enrolment, interview, live interview, audit, evidence graph, dashboard, candidates, roles, sessions, reports, settings, model decision, resume analysis, task) |
| Claim states | 4 (`substantiated`, `notDemonstrated`, `contradicted`, `notExamined`) |
| Identity threshold | 0.50 raw cosine similarity (reasoned, not yet FAR/FRR-validated) |
| Verification cadence | 15–25s, jittered |
| Telemetry trigger patterns | 3 (`bulkInsert`, `pauseThenBulk`, `immediateAnswer`) |
| Face embedding | ArcFace, 512-d, WebFace600K |
| LLM for claim extraction | Local Ollama `qwen2.5:7b` — no API key, ever |
| Warm inference latency | 2.2s (cold: ~40s — call `warmUp()` first) |
| Cloud dependency | None |
| Evidence store integrity | Hash-chained (tamper-evident) |

---

## Implemented vs. Roadmap

### Implemented
- Resume extraction and grounded claim extraction (local LLM, discards ungrounded text)
- Continuous identity verification with strike escalation
- Adaptive interview engine (3 telemetry-triggered follow-up patterns)
- Evidence graph with no hidden score
- Claim audit, exportable to standalone HTML
- Full ML decision-support layer (`lib/core/ml/`): logistic model, grouped train/test split, isotonic calibration, conformal prediction with abstain, exact per-feature attribution — trained and validated only on synthetic data (`isValidatedOnRealData = false`, no `fitReal` call exists)
- 537-test suite including widget-level screen tests (added after a `setState`-returned-a-Future bug shipped past a purely logic-level suite)
- **Persistence layer** (`lib/core/persistence/`): every enrolment and completed audit survives a restart, one JSON file per session under platform app-support storage, atomic write-then-rename so a crash mid-save can't leave a half-written audit, corrupt files surfaced as "unreadable" rather than silently dropped from the list. Deliberately plain files instead of SQLite — the dataset is small enough that an inspectable JSON document was judged worth more than query performance the project doesn't need.
- **Threshold-calibration tooling** (`tool/calibrate_threshold.dart`): turns a corpus of labelled genuine/impostor embedding pairs into an FAR/FRR/EER report and a fitted Platt scaler, refusing to report anything below 50 pairs per class. Still blocked on collecting the actual real-candidate pairs (see below).
- **Organization-level dashboards** (`lib/features/dashboard/`): every figure is computed live from stored audits by `WorkspaceStats` — no sampled, estimated, or projected numbers.
- **Per-role question priority** (`lib/core/roles/role_question_priority.dart`): picking a role in session setup reorders the claim queue so that role's required skills open first, so a session cut short by time still examined what the role author said mattered. Every claim is still asked, none dropped or hidden — it only changes the order, the same restraint `role_coverage.dart`'s reporting already follows.

### Planned
- **Run threshold calibration on real data** — the tool exists; what's missing is 50+ real genuine/impostor embedding pairs, which requires recruiting volunteers per the collection protocol in `docs/ML_REDESIGN.md` §5
- **Android camera testing** — blocked in this environment: no physical Android device or emulator available to test against
- Multi-reviewer consensus on disputed claims — needs a reviewer identity concept the current two-role (recruiter/candidate) RBAC model doesn't have; deferred rather than bolted on speculatively
- ATS integration — no validated need yet; customer validation (see Evidence & Market Research) is still the largest untested assumption in the project and should come before building toward a specific integration
- Multi-language interviews

---

## Closing

CogniHire is not designed to decide whether someone should be hired. It is designed to make interview evidence easier to collect, review, and explain. Rather than replacing human judgment with a score, it organizes interview observations into transparent, claim-based evidence that reviewers can inspect, challenge, or disregard.

"Not examined" exists so absence of evidence never reads as a quiet pass or a quiet fail. Buttons disable rather than lie. The audit is meant to leave the app and be defensible. That's the whole design.
