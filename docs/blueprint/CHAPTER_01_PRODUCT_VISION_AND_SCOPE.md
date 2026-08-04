# CogniHire — Engineering Blueprint
# Chapter 1: Product Vision & Scope

| Field | Value |
|---|---|
| Document | Chapter 1 of the CogniHire Engineering Blueprint |
| Version | 1.0 |
| Date | 2026-08-02 |
| Status | Draft for architecture review |
| Author | Principal Architect (solo engineering owner: Devesh S V) |
| Supersedes | `docs/PRODUCT_OVERVIEW.md` (narrative overview, retained as a reader-facing summary) |
| Depends on | `docs/ARCHITECTURE_DISCOVERY_REPORT.md` (2026-07-31, code-verified current state) |
| Downstream | Ch. 2 System Architecture · Ch. 3 Data Model · Ch. 4 AI/ML Architecture · Ch. 5 Security & Compliance · Ch. 6 Infrastructure & Scale |

---

## 0. How to read this document

### 0.1 Purpose

This chapter defines **what CogniHire is, who it serves, what it will and will not do, and the constraints every later chapter must design within**. It does not specify components, schemas, or APIs — those are Chapters 2–6. Where this chapter makes a decision that binds later chapters, it is recorded in §17 with its alternatives and trade-offs. Where a decision must stay open, it is recorded in §18 with the chapter that owns it.

### 0.2 Evidence labelling

This project has a documented history of persuasive prose inventing plausible specifics (see `docs/` gotcha: fabricated customer-research citations, caught 2026-07-27). The countermeasure is applied to this document as a rule:

> **Every factual claim in this chapter is labelled with its evidentiary status. Any number is either measured in-repo with a citation, or derived from assumptions that are stated inline. No number appears without one of the two.**

| Label | Meaning |
|---|---|
| `[IMPL]` | Implemented and verified in the repository as of 2026-08-02. Traceable to a file. |
| `[DES]` | Designed in a `docs/*_DESIGN.md` document; **not implemented**. |
| `[PROP]` | Proposed by this chapter. Not yet designed or built. Requires approval. |
| `[EST]` | A calculated estimate. The assumptions behind it are stated at the point of use. |
| `[OPEN]` | Unresolved. Carried into §18. |

### 0.3 The scale premise, stated honestly up front

This blueprint is written for a system that must eventually serve **millions of interviews**. The system that exists today is a **single-tenant, single-machine, local-storage desktop application with no authentication wired in** `[IMPL]`. These two facts are not in conflict — one is the target, one is the starting point — but pretending the gap is small would corrupt every downstream chapter.

The gap is quantified in §11.2 and §14 (R-05). The design rule this chapter imposes is:

> **The MVP is permitted to be single-node. It is not permitted to make multi-tenancy impossible.** Any MVP decision that would require a rewrite (rather than an extension) to reach multi-tenant cloud scale must be recorded in §17 with that cost acknowledged.

By that test, the current codebase has **one** disqualifying decision: no model in the domain layer carries a tenant or organisation identifier `[IMPL]`. That is a Chapter 3 correction, flagged here as R-05.

---

## 1. Product Vision

### 1.1 Why CogniHire exists

The interview produces the least defensible artifact in the entire hiring pipeline.

Every other stage leaves a record that can be re-examined. A resume is a document. A take-home is a repository. A reference check is a call with notes. The interview — the stage that carries the most decision weight — typically terminates in a scorecard entry of the form:

> *"Strong communicator. Solid on Flutter. 8.7/10."*

Six months later this artifact supports no operation anyone needs to perform on it:

| Operation someone needs | Why the scorecard cannot support it |
|---|---|
| The candidate asks why they were rejected | There is no decomposition. "8.7" has no parts to point at. |
| The hiring manager asks what was actually verified | The interviewer no longer remembers which claims were probed and which were assumed. |
| A second interviewer wants to avoid re-covering ground | No record of what was covered exists at claim granularity. |
| Legal/compliance asks how the decision was reached | Under NYC Local Law 144, the Illinois AI Video Interview Act (effective 2026-01-01), and the EU AI Act's high-risk classification for employment tools, an unexplainable score is a regulatory exposure, not merely an unsatisfying one. |
| The organisation asks whether its process is consistent | Scores from different interviewers are not commensurable and there is nothing underneath them to compare. |

Two structural failures produce this outcome, and both are addressable in software:

**Failure 1 — Provenance is checked once, at a door, and then never again.**
Every remote-interview product verifies identity at login. After that moment, a substitute, an off-camera assistant, or a second screen is invisible to the system. The evidence collected for the next 45 minutes is attributed to a person the system stopped observing 45 minutes ago. This is not a hard problem being solved badly; it is a problem most products do not attempt.

**Failure 2 — Process signal is captured, then filed, and never acted on.**
This must be stated precisely because the naive version of the claim is false. HackerRank ships keystroke playback and a coding-patterns flag; CodeSignal ships full session replay and a suspicion score. Process capture is not novel `[IMPL: documented in market research]`. What no product does is **feed process signal back into the live interview to change the next question while the candidate is still in the room**. Today, a `pauseThenBulk` typing pattern becomes a flag a human reads afterwards. It should become a follow-up question asked eleven seconds later.

### 1.2 The problems CogniHire solves

| # | Problem | Who feels it | Prevailing answer | CogniHire's answer | Why this is technically different |
|---|---|---|---|---|---|
| P1 | Interview conclusions are unexplainable | Candidate, HM, Legal | "Explainable AI" scores with feature importances | No score is produced at any layer. Output is a per-claim verdict with an evidence pointer. | The absence is enforced in the type system — `ClaimAudit` has no numeric field and `EvidenceGraph` has no `strength()`/`centrality()` method `[IMPL]`. There is no code path to a composite number to be misused later. |
| P2 | Authorship of an answer is unknown after login | Recruiter, HM | One-time identity check + proctoring flags | Continuous jittered re-verification across the whole session, every result recorded as evidence | A failed or impossible check produces a sealed `Unchecked` variant carrying a reason and **no similarity field** — structurally incapable of being read as a pass `[IMPL]` |
| P3 | Process evidence is retrospective | Recruiter | Session replay, fraud dashboards | Telemetry patterns select the next question during the interview | The follow-up generator exposes only `{question, trigger, observation}` — there is structurally nowhere to put a cheating probability `[IMPL]` |
| P4 | AI systems fabricate on failure | Everyone | Graceful degradation with defaults | Degradation is visible; missing measurement is a distinct third state | Enforced at four layers: sealed `Unchecked`, `embedding: null` (never a zero-vector) from the face service, `notExamined` claim status, strict codecs that throw on unknown enum values `[IMPL]` |
| P5 | LLMs invent claims about real people | Candidate (worst harm), Org (liability) | Prompt instructions and post-hoc review | Grounding gate: every model-returned string must be verbatim-findable in the source; anything else is discarded to `rejectedUngrounded` | Whitespace-collapsed, case-insensitive substring match — **no fuzzy match, no token-overlap threshold**. A test proves a same-meaning paraphrase is rejected `[IMPL]` |
| P6 | Candidate documents leave the organisation | Candidate, Org DPO | Vendor DPAs and sub-processor lists | Claim extraction runs on a local model; the resume never leaves the machine | Local Ollama `qwen2.5:7b`; no cloud SDK exists anywhere in `lib/` or `service/` — verified by grep `[IMPL]` |

### 1.3 Who benefits, and how

| Beneficiary | Concrete benefit | Measurable as |
|---|---|---|
| Candidate | Receives a decomposed record of what was examined and what was concluded about each claim; "not examined" is visible rather than silently read as a negative | Share of sessions where a candidate-facing audit is available `[PROP]` |
| Recruiter | Arrives at the debrief with a structured, per-claim record instead of recalled impressions | Time from session end to reviewer decision |
| Hiring Manager | Can see which technical claims were probed and how deeply, without re-running the interview | Claim coverage against the role's required-skill list `[IMPL: role_coverage.dart]` |
| Organisation Admin | Holds a defensible, tamper-evident record for each interview | Share of sessions with an unbroken event-log hash chain `[IMPL]` |
| Compliance / DPO | Can answer "how was this decision reached" with a document, not a model card | Audit export completeness |
| The interviewing organisation as a whole | Interview quality becomes an inspectable process rather than an interviewer-dependent one | Inter-reviewer agreement on identical audits `[PROP]` |

### 1.4 What makes CogniHire technically different

Four claims. Each is stated in its **defensible** form, with the overclaimed form named and rejected.

**D1 — Non-fabrication is a type-system property, not a code-review convention.**
*Defensible:* the system distinguishes "measured and failed" from "could not measure" at the level of sealed union types, and the serialisation layer refuses to round-trip a record that would blur them. Derived fields (`identityCoverage`, `provenanceQuality`, `summary`) are never persisted — they are recomputed on load, so a hand-edited file cannot disagree with the rules `[IMPL]`.
*Overclaim to avoid:* "CogniHire cannot hallucinate." It can — an LLM can select the wrong verbatim span. What it cannot do is **author** text and attribute it to a candidate.

**D2 — Continuous provenance, recorded as evidence rather than as a verdict.**
*Defensible:* identity is re-checked on a jittered 15–25 s cadence for the duration of the session, and every attempt — including every failed one — becomes a node in the evidence graph `[IMPL]`.
*Overclaim to avoid:* "prevents impersonation." No software prevents a second device. The operating stance is **detect, deter, document — never prevent**, and there is no liveness/anti-spoof detection in the system today `[IMPL: absent]` (see R-03).

**D3 — Process signal is fed forward into the live interview.**
*Defensible:* a telemetry pattern **selects a question**; it never raises a flag or contributes to a score. Someone who wrote the code explains it easily; someone reading from a second screen must comprehend it live, in their own words — materially harder than producing it was. The candidate's answer is the evidence, and they always get to give it. This is also the answer to "pasting can be legitimate": a candidate pasting their own prior work simply answers well.
*Overclaim to avoid:* "we are the only ones who capture process." False — competitors capture more of it. The distinction is *retrospective flag* versus *live question selection*.

**D4 — Local-first inference makes a privacy claim that is architectural rather than contractual.**
*Defensible:* claim extraction and live turn generation run against a local model; there is no cloud inference path in the codebase `[IMPL]`. The privacy property follows from the absence of an egress path, not from a data-processing agreement.
*Trade-off, stated honestly:* this property does not survive contact with multi-tenant cloud scale unmodified. §12.5 and §17 (ED-01) treat this as the central architectural tension of the product, not as a settled win.

**What is explicitly not differentiated:** question quality on a 7B local model, UI polish, ATS integration breadth, scheduling, or interview logistics. Competing on any of those is a losing position and is out of scope (§9).

---

## 2. Mission Statement

> **CogniHire exists to make interview evidence collectable, inspectable, and defensible — by verifying who produced an answer and how they produced it, and by recording the result as traceable per-claim evidence rather than as a score.**
>
> The system measures. It never decides the person.

Operationally, the mission is a set of prohibitions the architecture must uphold:

1. It must not emit a composite rating of a human being.
2. It must not attribute to a candidate any text the candidate did not produce.
3. It must not report an unmeasured quantity as a passing one.
4. It must not reject, filter, or rank a candidate without a human in the loop.
5. It must not infer psychological or demographic state from face, voice, or typing behaviour.

A change request that violates any of these is a change to the product's identity, not a feature. §15 makes this boundary explicit.

---

## 3. Product Goals

Goals are numbered because later chapters trace requirements back to them.

| ID | Goal | Rationale | Measurable form |
|---|---|---|---|
| G1 | Every interview conclusion traces to specific, inspectable evidence | This is the product. Without it, CogniHire is a worse HireVue. | 100 % of claim verdicts carry ≥1 evidence pointer; 0 verdicts with none |
| G2 | The authorship of interview evidence is continuously established, not assumed | Addresses P2, the gap that survived competitive analysis intact | Median identity-check coverage per session ≥ 90 % of elapsed session time |
| G3 | Failure is always visible and never silently substituted with a plausible value | The single largest existential risk to a product whose pitch is "we don't fabricate" (see R-07) | 0 code paths returning a default in place of a failed measurement; enforced by the guard suite `[IMPL: decision_guards.dart]` |
| G4 | A human reviewer is required for every consequential outcome | Regulatory floor and ethical floor coincide here | 0 auto-reject paths; 100 % of sessions terminate in either an audit or a human-review flag |
| G5 | Candidate data minimisation is a default, not a configuration | Biometric data raises the cost of a breach by an order of magnitude | Face embeddings never leave the device in MVP; retention policy enforced in code by V1 |
| G6 | The system is honest about its own validation status | The ML layer has never seen a real person; a UI implying otherwise would be the worst class of defect | `isValidatedOnRealData` surfaced in every UI that displays a model output `[IMPL]` |
| G7 | Single-node MVP does not preclude multi-tenant scale | Prevents the MVP from becoming a throwaway | Every domain aggregate carries a tenant key by end of V1 (currently: none do) |
| G8 | The product is defensible under NYC LL144, Illinois AIVI, and EU AI Act high-risk obligations | These are not future concerns; Illinois AIVI is effective 2026-01-01 | Compliance checklist in Ch. 5 fully green before first production deployment |

**A goal that is deliberately absent:** "improve quality of hire." CogniHire does not collect hire/no-hire outcome labels and has no path to them (§17, ED-04). A goal the system cannot measure is a goal it will eventually fake.

---

## 4. Success Metrics (KPIs)

### 4.1 Metric design constraint

The obvious KPI for a hiring product — *does it predict good hires* — requires exactly the training labels this product refuses to collect. That refusal is load-bearing (ED-04): outcome labels encode the historical hiring decisions of the organisation, which is the precise mechanism by which the Amazon 2018 résumé-screening system learned to penalise women. CogniHire's KPIs therefore measure **evidence quality and process integrity**, never predictive accuracy about people.

### 4.2 Evidence-quality KPIs (primary)

| ID | Metric | Definition | Target (V1) | Measurement | Current |
|---|---|---|---|---|---|
| K1 | Claim coverage | Claims examined ÷ claims extracted | ≥ 0.80 | Computed from `ClaimAudit` | Not instrumented `[OPEN]` |
| K2 | Evidence density | Mean evidence pointers per substantiated claim | ≥ 2.0 | `ClaimAudit` traversal | Not instrumented |
| K3 | Unexamined-claim visibility | Sessions where `notExamined` claims are shown to the reviewer | 100 % | UI assertion test | 100 % `[IMPL]` |
| K4 | Ungrounded-output rate | LLM-returned strings discarded by the grounding gate ÷ total returned | Tracked, not targeted | `rejectedUngrounded` count | Instrumented, not aggregated `[IMPL]` |
| K5 | Reviewer agreement | Two reviewers reaching the same disposition from the same audit | ≥ 0.75 (Cohen's κ) | Requires multi-reviewer feature | Not measurable — feature absent |

> K5 is the strongest available proxy for "does the audit actually communicate." It is deliberately listed even though it cannot be measured yet, because a KPI list containing only currently-measurable items silently narrows the product.

### 4.3 Integrity KPIs

| ID | Metric | Target | Current |
|---|---|---|---|
| K6 | Identity coverage per session (fraction of session time within one check interval of a successful verification) | ≥ 0.90 median | Computed but not aggregated `[IMPL]` |
| K7 | Hash-chain continuity across saved sessions | 100 % | 100 % for the event log; **0 % for saved audit files** — they carry no integrity protection at all `[IMPL: gap, see R-08]` |
| K8 | Fabricated-pass defects escaping to a release | 0 | 0 known; 1 historical near-miss in reference code, 0 in this codebase |
| K9 | Sessions terminating without a human disposition | 0 | 0 `[IMPL]` |

### 4.4 Technical KPIs

| ID | Metric | Target (V1) | Current measured |
|---|---|---|---|
| K10 | Warm LLM turn latency (p95, first audible token) | ≤ 1.5 s | 2.2–2.6 s warm, ~40 s cold `[IMPL: measured]` |
| K11 | Face verification round-trip (p95) | ≤ 400 ms | Not measured `[OPEN]` |
| K12 | Session data-loss incidents | 0 | 0 — atomic write-then-rename `[IMPL]` |
| K13 | Test suite: assertions vs. app LOC | ≥ 40 % | 10,622 test LOC / 24,885 lib LOC = 42.7 % `[IMPL]` |
| K14 | Screens with widget-level mount coverage | 100 % | Partial — added only after a `setState`-returned-a-`Future` crash shipped past 162 green logic tests `[IMPL]` |

### 4.5 Compliance KPIs

| ID | Metric | Target |
|---|---|---|
| K15 | Sessions with candidate disclosure recorded before any capture | 100 % `[PROP]` |
| K16 | Biometric records past retention policy | 0 — requires a retention policy, which does not exist `[OPEN: OQ-14]` |
| K17 | Data-subject deletion requests fulfilled within statutory window | 100 % — no deletion flow exists today beyond "clear enrolment" `[IMPL: gap]` |

---

## 5. Core Principles

Each principle states what it forbids, how it is enforced in code, and what it costs. A principle with no enforcement mechanism and no cost is decoration.

### P1 — Evidence over assumptions
**Statement.** A conclusion exists only where evidence exists. Absence of evidence is recorded as absence, never as a negative or a positive.
**Enforced by.** `ClaimStatus` has four members, one of which is `notExamined`; `ProvenanceQuality` includes `none`; `identityCoverage` is `null` (not `1.0`) when zero checks were attempted `[IMPL]`.
**Forbids.** Defaulting, imputation, "assume pass if no violation."
**Costs.** Audits are longer and less decisive than a score. Reviewers must read.

### P2 — Transparent AI, with no hidden aggregate
**Statement.** Every model output is decomposable into contributions the user can inspect, and no aggregate rating of a person is produced anywhere in the system.
**Enforced by.** `sufficiency_attribution` performs an **exact** logit decomposition — the explanation is the arithmetic, not a surrogate model `[IMPL]`. `EvidenceGraph` deliberately has no `strength()` or `centrality()` method, with a source comment explaining to future contributors why adding one (e.g. PageRank over the evidence graph) would be a hidden weight in graph-theory costume `[IMPL]`.
**Forbids.** SHAP-style approximations presented as explanations; edge weights; any composite score.
**Costs.** Restricts the model class to ones whose contributions are exactly decomposable — currently linear. A gradient-boosted model would likely score better on any predictive metric and is disallowed by this principle.

### P3 — Human-in-the-loop by construction
**Statement.** The system produces evidence for a decision; it never produces the decision.
**Enforced by.** No auto-reject path exists. The reviewer screen **refuses to render** a model decision when any blocking guard violation is present, showing the violations instead — the guard suite is load-bearing UI, not a lint `[IMPL: model_decision_screen.dart, decision_guards.dart]`.
**Forbids.** Ranking, filtering, thresholded shortlists, "recommended: advance."
**Costs.** No throughput benefit from automation. Recruiter time per candidate does not fall.

### P4 — Privacy-first, by absence of an egress path
**Statement.** Candidate documents and biometrics are processed where they were captured. Data leaves only by a deliberate, user-initiated export.
**Enforced by.** No cloud SDK anywhere in `lib/` or first-party `service/` code (grep-verified); face embeddings and audits are written to OS app-support storage, outside the project tree; `.gitignore` defensively excludes `*.enrolment.json` and `audit_store/` because an enrolment profile *is* a face embedding of a real person `[IMPL]`.
**Forbids.** Telemetry-by-default, cloud claim extraction, third-party model APIs on the resume path.
**Costs.** Constrains model quality to what runs on a candidate-grade machine (7B, Q4). Directly conflicts with multi-tenant scale — see ED-01.

### P5 — Failure is loud
**Statement.** A broken component reports broken. It never substitutes a plausible value.
**Enforced by.** `HttpFaceEngine` throws rather than defaulting when `embedding_available` is missing or non-boolean; the face service returns `embedding: null`, never a zero-vector; if InsightFace fails to load, the service still starts and reports `engine_available: false` rather than falling back to a heuristic; strict codecs raise `FormatException` on unknown enum names or schema-version mismatch; corrupt audit files are listed as **unreadable** rather than silently dropped (a vanishing audit is a fabricated pass reached by omission) `[IMPL]`.
**Forbids.** Try/catch-and-default, optimistic fallbacks, silent list filtering.
**Costs.** More visible errors in demos. Higher operational noise.

### P6 — The model may select; it may never author
**Statement.** Text attributed to a candidate must have been produced by the candidate.
**Enforced by.** The grounding gate — whitespace-collapsed, case-insensitive verbatim containment check against the source document or transcript; anything not found is discarded. Applied to resume claim extraction and, separately, to live interview quotes, where a failed check downgrades the turn to `kind: newtopic` with an empty quote. Enforced server-side in the client layer, not by prompt wording; a test feeds a fabricated quote and asserts it never reaches the caller `[IMPL]`.
**Forbids.** Fuzzy matching, embedding-similarity grounding, token-overlap thresholds, paraphrase.
**Costs.** Rejects legitimate paraphrases. Reduces extraction recall in exchange for eliminating a class of harm.

### P7 — Scalable by design, single-node by stage
**Statement.** MVP may run on one machine. No MVP decision may make horizontal scale require a rewrite.
**Enforced by.** Partially. The domain layer is pure Dart with no I/O coupling, and persistence sits behind an `AuthStore`/`AuditStore` interface pair, so swapping storage is an implementation change `[IMPL]`. **Violated in one place:** no domain model carries a tenant/organisation key, which is a schema change touching every aggregate `[IMPL: gap, R-05]`.
**Forbids.** In-memory cross-session state, singletons holding session data, tenant-implicit queries.
**Costs.** Some MVP work (interfaces, codecs) is more elaborate than a prototype needs.

### P8 — Adversarial-but-fair, never deceptive
**Statement.** The system may make verification harder for a dishonest candidate. It may never mislead an honest one.
**Enforced by.** Follow-up questions are template-first, with a deterministic banned-phrase linter over any model-generated question text, so "never accuse" is structural rather than prompt-dependent `[DES: adaptive engine]`. Bug-introduction probes must disclose up front that the defect is a deliberate exercise — presenting a planted bug as a real system error would cross from adversarial into deceptive `[DES: code authorship engine]`.
**Forbids.** Hidden scoring, undisclosed capture, staged failures, deception-detection framing.
**Costs.** Loses the "gotcha" signal that a deceptive design would collect.

---

## 6. Stakeholders

### 6.1 Current versus target role model

The codebase implements exactly **two** roles — `recruiter` and `candidate` — with a deny-by-default permission matrix in a single file, and an explicit source comment arguing against adding a third role casually: *every value multiplies the permission table, the route table, and the number of shell layouts that must be kept working* `[IMPL: user_role.dart, permissions.dart]`.

This chapter proposes expanding to **four in-product roles plus one out-of-product operator role**, and accepts that cost deliberately rather than by drift:

| Stakeholder | In-product role? | Status |
|---|---|---|
| Candidate | Yes — `candidate` | `[IMPL]` |
| Recruiter | Yes — `recruiter` | `[IMPL]` |
| Hiring Manager | Yes — `hiringManager` | `[PROP]` — V1 |
| Organisation Admin | Yes — `orgAdmin` | `[PROP]` — V1 |
| System Administrator | **No** | `[PROP]` — see §6.7 |

> **Architectural position:** the System Administrator must **not** be a `UserRole`. An infrastructure operator who is also an application principal can read candidate biometric data through the product UI, which converts an operations role into a data-access role. Operator capability belongs to a separate control plane with its own authentication, its own audit log, and no ability to read interview content. This is a Chapter 5 boundary, asserted here.

### 6.2 Candidate

| Aspect | Detail |
|---|---|
| **Responsibilities** | Provide a resume; complete face enrolment or decline it; confirm or correct extracted claims before the interview begins; answer questions; complete or explicitly end the session |
| **Needs** | To know what is being recorded and why, before it is recorded; to see the claims attributed to them and correct a wrong extraction; to receive a decomposed result rather than a verdict; a path to contest a claim status |
| **Pain points** | Opaque rejection with no appealable content; biometric capture with unclear retention; being flagged by a proctoring heuristic with no opportunity to respond; a system that treats "not examined" as a failure |
| **Permissions** `[IMPL]` | `takeInterview`, `manageOwnResume`, `configureOwnSession`, `viewOwnHistory`, `viewOwnReports`, `manageOwnProfile`, `managePersonalSettings` |
| **Denied** | All organisation surfaces. `viewOwnReports` and `viewAllReports` are **separate permissions on purpose** — collapsing them into one permission plus a `where` clause makes the boundary between "reads their own result" and "reads everybody's" a filter a refactor can silently drop `[IMPL]` |
| **Open** | Whether a candidate may contest a claim status, and what happens to the audit if they do — OQ-11 |

### 6.3 Recruiter

| Aspect | Detail |
|---|---|
| **Responsibilities** | Define the job role and its required skills; create and configure sessions; upload a resume on a candidate's behalf; review evidence and record a disposition; export the audit |
| **Needs** | A per-claim record they can scan quickly; coverage against the role's required skills; the ability to compare candidates on evidence rather than on scores; a defensible export |
| **Pain points** | Debriefs conducted from memory; inconsistent depth between interviewers; no mechanism for "this was never actually asked about"; pressure to produce a single number for stakeholders who want one |
| **Permissions** `[IMPL]` | `viewHrDashboard`, `manageCandidates`, `compareCandidates`, `createSession`, `uploadCandidateResume`, `reviewEvidence`, `viewClaimAudit`, `viewAllReports`, `exportReports`, `viewAnalytics`, `manageJobRoles`, `manageOrganisation`, `managePersonalSettings` |
| **Architectural note** | `manageOrganisation` is currently granted to every recruiter. That is correct for a two-role MVP and wrong for V1 — it must move to `orgAdmin` when that role is introduced `[PROP]` |
| **Open** | Whether a recruiter may edit claims post-session or only annotate them — OQ-11 |

### 6.4 Hiring Manager `[PROP]`

| Aspect | Detail |
|---|---|
| **Responsibilities** | Define what "substantiated" must mean for their role; consume audits; make the advance/decline decision; give the reviewer signal back into role definitions |
| **Needs** | Depth-of-probing visibility per technical claim; to know what was *not* covered; comparison across candidates on the same claim dimensions; low time-to-read |
| **Pain points** | Receives recruiter summaries rather than evidence; cannot tell a shallow interview from a deep one; re-interviews to re-verify things already covered |
| **Permissions** `[PROP]` | `viewClaimAudit`, `reviewEvidence`, `viewAllReports` (scoped to their own requisitions), `compareCandidates`, `exportReports`, `managePersonalSettings` |
| **Denied** | `manageOrganisation`, `manageCandidates`, `uploadCandidateResume`, `createSession` |
| **Why a distinct role rather than a recruiter variant** | The scoping differs in kind, not degree: a recruiter's `viewAllReports` is org-wide; a hiring manager's is requisition-scoped. A requisition-scoped read is a different permission, not the same permission with a filter — see the own-versus-all reasoning in §6.2 |

### 6.5 Organisation Admin `[PROP]`

| Aspect | Detail |
|---|---|
| **Responsibilities** | Manage users and role assignments; set data-retention policy; configure the compliance posture (disclosure text, jurisdiction); hold the org-level audit log; approve exports |
| **Needs** | A cross-session administrative audit trail (distinct from the per-session `SessionEventLog`, which is a different artifact); retention enforcement they can prove; the ability to answer a regulator without engineering help |
| **Pain points** | Cannot currently prove what was retained, for how long, or who read it — no cross-session admin audit log exists `[IMPL: gap]` |
| **Permissions** `[PROP]` | `manageOrganisation`, `manageUsers`, `manageRetentionPolicy`, `viewAdminAuditLog`, `manageJobRoles`, `viewAnalytics`, `managePersonalSettings` |
| **Denied — deliberately** | `viewClaimAudit` and `reviewEvidence`. An administrator does not need to read interview content to administer the system, and granting it makes every admin account a candidate-data breach surface. If a specific admin also reviews candidates, they hold two role assignments and the audit log records which one they acted under |

### 6.6 System Administrator (operator) `[PROP]`

| Aspect | Detail |
|---|---|
| **Responsibilities** | Deploy, monitor, patch, back up, restore; manage model artifacts and their provenance flags; run incident response |
| **Needs** | Health and latency telemetry that contains no interview content; model-artifact version control; a restore path that does not require reading candidate data |
| **Pain points** | Diagnosing a pipeline they are structurally forbidden from inspecting the contents of — this is a deliberate constraint that makes their job harder |
| **Permissions** | **None in the application.** Control-plane only: infrastructure, model registry, observability. |
| **Enforcement requirement** `[PROP]` | Observability data must be scrubbed at the emission point, not the query point. `lib/core/privacy/scrubber.dart` and `candidate_id.dart` already exist as the intended primitives `[IMPL]` and must be made mandatory on the telemetry path in Ch. 6 |

### 6.7 Permission matrix (target, V1)

| Permission | Candidate | Recruiter | Hiring Mgr | Org Admin | SysAdmin |
|---|:--:|:--:|:--:|:--:|:--:|
| `takeInterview` | ✅ | — | — | — | — |
| `manageOwnResume` / `manageOwnProfile` / `viewOwnHistory` / `viewOwnReports` / `configureOwnSession` | ✅ | — | — | — | — |
| `createSession` | — | ✅ | — | — | — |
| `uploadCandidateResume` | — | ✅ | — | — | — |
| `manageCandidates` | — | ✅ | — | — | — |
| `reviewEvidence` | — | ✅ | ✅ | — | — |
| `viewClaimAudit` | — | ✅ | ✅ | — | — |
| `viewAllReports` | — | ✅ org | ✅ req-scoped | — | — |
| `compareCandidates` | — | ✅ | ✅ | — | — |
| `exportReports` | — | ✅ | ✅ | — | — |
| `viewAnalytics` | — | ✅ | — | ✅ | — |
| `manageJobRoles` | — | ✅ | — | ✅ | — |
| `manageOrganisation` | — | ⚠️ today | — | ✅ target | — |
| `manageUsers` `[PROP]` | — | — | — | ✅ | — |
| `manageRetentionPolicy` `[PROP]` | — | — | — | ✅ | — |
| `viewAdminAuditLog` `[PROP]` | — | — | — | ✅ | — |
| `managePersonalSettings` | ✅ | ✅ | ✅ | ✅ | — |

> **Invariant to preserve.** A test currently asserts that the only permission held by more than one role is `managePersonalSettings` `[IMPL]`. Expanding to four roles necessarily breaks that specific assertion. It must be replaced — not deleted — with a per-pair disjointness assertion, or the "genuinely separate applications" property degrades silently. This is a concrete Chapter 5 task.

---

## 7. Target Users

### 7.1 Primary segment (V1)

**Mid-market technology employers, 200–5,000 employees, running 50–500 technical interviews per quarter, in a jurisdiction with active AI-hiring regulation.**

Selection rationale — four conditions must hold simultaneously:

| Condition | Why it is required |
|---|---|
| Enough technical interview volume that consistency is a real problem | Below ~50/quarter, a single senior interviewer solves this socially and no tool is needed |
| Not large enough to have built an internal evidence platform | Above ~5,000 employees, in-house tooling and an incumbent ATS suite dominate |
| Operating under LL144 / Illinois AIVI / EU AI Act, or selling to customers who audit vendors | The compliance driver is what makes "no score" a feature rather than a missing feature |
| Willing to accept that the tool does not reduce recruiter time | CogniHire adds rigour, not throughput. An organisation buying on efficiency will churn |

The fourth condition is the one most likely to be wrong and is the single most important thing to test — see A-01 and R-01.

### 7.2 Direct users

| User | Frequency | Session length | Interface | Device |
|---|---|---|---|---|
| Candidate | Once per application | 30–60 min | Interview client | Own laptop, unmanaged, webcam+mic required |
| Recruiter | Daily | 5–20 min per review | Recruiter workspace | Managed desktop |
| Hiring Manager | Weekly | 5–10 min per audit | Read-mostly audit view | Desktop or tablet |
| Org Admin | Monthly | Short | Admin console | Managed desktop |

**The candidate device is the hard constraint.** It is unmanaged, arbitrary, and hostile in the threat model. It is also where the MVP currently runs the entire system, including local LLM inference — a 7.6B Q4 model requiring roughly 5–6 GB of resident memory, on a machine that also runs the face service and a camera pipeline `[IMPL: measured on a 15.2 GB RAM / RTX 5050 4 GB dev machine]`. This is viable for a controlled demo and is **not** viable as a deployment model for arbitrary candidate hardware. See C-04 and ED-01.

### 7.3 Explicit non-users (V1)

| Not a target | Reason |
|---|---|
| High-volume graduate/campus screening (10,000+ candidates/cycle) | The value proposition is depth per candidate; the economics of volume screening demand automated filtering, which P3 forbids |
| Non-technical role hiring | Every verification mechanism (code authorship, architectural probing, telemetry) is specific to technical claims |
| Staffing agencies reselling assessments | Requires ranking and comparability across clients — a composite score by another name |
| Regulated pre-employment psychometric assessment | Different statutory regime entirely; CogniHire makes no psychometric claim and must not be positioned near one |
| Live proctoring of academic exams | Adjacent and tempting; a different threat model, different regulation, and would pull the roadmap toward prevention claims the product explicitly rejects |

---

## 8. In-Scope Features for Version 1

Version 1 is defined as **the first release deployable to an organisation other than the author's**. That bar — not feature count — is what separates it from the MVP.

### 8.1 MVP: what already exists and is wired `[IMPL]`

| Capability | Evidence |
|---|---|
| Resume ingest (`.txt` parsed; `.pdf`/`.docx` attach but explicitly state extraction is not wired, rather than faking success) | `features/resume/` |
| Grounded claim extraction against a local LLM, with a disclosed heuristic fallback when the model is unreachable | `core/claims/ollama_claim_extractor.dart` |
| Candidate review and confirmation of extracted claims before the interview |  |
| Face enrolment with an explicit minimum-quality rejection (rather than enrolling a weak reference) | `features/enrolment/` |
| Continuous jittered identity verification with strike escalation | `core/verification/verification_session.dart` |
| Process telemetry with three trigger patterns (`bulkInsert`, `pauseThenBulk`, `immediateAnswer`) | `core/telemetry/` |
| Rule-selected adaptive follow-ups | `core/interview/followup.dart` |
| Deterministic, non-LLM claim audit with four states | `core/claims/claim_audit.dart` |
| Evidence graph — 7 node types, 7 categorical edge types, mandatory rationale per edge, no numeric weight | `core/graph/`, `features/graph/` |
| Hash-chained session event log (tamper-**evident**) | `core/session/` |
| JSON-file persistence with atomic write-then-rename and unreadable-record surfacing | `core/persistence/` |
| Self-contained HTML audit export (no network fetch, print-to-PDF from any browser) | `core/export/` |
| ML decision-support layer: logistic model, grouped split, exact attribution, conformal abstain — synthetic data only | `lib/core/ml/`, `service/ml/` |
| Guard suite that blocks the reviewer screen from rendering under a blocking violation | `core/ml/decision_guards.dart` |
| Job roles with required-skill coverage reporting and claim-queue prioritisation | `core/roles/` |
| Live dashboards computed from stored audits, with no estimated figures | `core/workspace/` |
| RBAC permission matrix and route guard — **built, tested, and not wired into the running app** | `core/rbac/`, `app/routes.dart` |

### 8.2 V1 scope — the delta

Grouped by the reason each item is required for external deployment.

**Tier 1 — Blocks any deployment outside a single machine**

| ID | Feature | Current state | Why V1 |
|---|---|---|---|
| V1-01 | Real authentication behind the existing `AuthStore` interface | `InMemoryAuthStore` holds plaintext passwords in a `Map` compared with `==`; self-documented as a test double `[IMPL]` | No external deployment without it |
| V1-02 | Wire the existing RBAC route guard into the composition root | Fully built and tested; `grep` confirms **zero** importers outside its own test `[IMPL]` | The running app currently enforces nothing — every screen is reachable by anyone |
| V1-03 | Tenant/organisation key on every domain aggregate | No model has one `[IMPL]` | Without it, multi-tenancy is a rewrite (§0.3) |
| V1-04 | Server-side persistence behind the existing `AuditStore` interface | JSON files, local only | Recruiter and candidate are on different machines |
| V1-05 | Encryption at rest for audits and enrolment profiles | None `[IMPL]` | A face embedding is biometric personal data |
| V1-06 | Integrity protection on saved audit files | Hash chain covers the event log only; saved audits have **zero** protection and are silently editable `[IMPL]` | A defensible record that can be edited undetectably is not defensible |

**Tier 2 — Required by the product thesis**

| ID | Feature | Current state | Why V1 |
|---|---|---|---|
| V1-07 | Resolve the two-interview-screen fork: `InterviewScreen` (wired) vs `LiveInterviewScreen` (1,013 LOC, dev-harness only) | Both exist; one is dead from the app's perspective `[IMPL]` | Pure liability. Blocks investment in either. OQ-01 |
| V1-08 | Wire answer scoring, or formally delete the concept | `_lastAnswerScore` is a hardcoded `1`; `scoring_agent.txt` exists on disk with no call site — two of the live prompt's own adaptivity rules run on permanently fake data `[IMPL]` | A rule the system cannot satisfy is worse than an absent rule |
| V1-09 | PDF/DOCX resume text extraction | Attach-only, honestly disclosed | The primary real-world resume formats |
| V1-10 | Candidate transparency view — what was recorded and why | Absent | Required by disclosure obligations and by P8 |
| V1-11 | Retention policy enforcement and data-subject deletion | Absent beyond "clear enrolment" | Statutory. OQ-14 |
| V1-12 | Reviewer claim-status override with a mandatory written reason | Absent | P3 is currently asserted but not exercisable |
| V1-13 | Identity threshold calibration on real paired data | Tooling exists and refuses to report below 50 pairs/class; the data does not exist `[IMPL]` | Until then, **no FAR/FRR figure may be quoted anywhere**. R-02 |
| V1-14 | Cross-session administrative audit log | Absent | Distinct artifact from `SessionEventLog`; required by §6.5 |

**Tier 3 — Required for a demonstrable product**

| ID | Feature | Current state |
|---|---|---|
| V1-15 | Android target validation (best-supported camera platform; Windows is weakest) | Untested — no device available `[IMPL: blocked]` |
| V1-16 | Real STT/TTS on a supported path, replacing the browser Web Speech stand-in | Stand-in wired; named in code as a swap point |
| V1-17 | Tighten face-service CORS (`allow_origins=["*"]` today) and add service auth | Open `[IMPL]` |
| V1-18 | Schema-migration path for versioned models — a version bump currently orphans every saved enrolment with a hard throw | Absent `[IMPL]` |

---

## 9. Out-of-Scope for Version 1

Two categories, and the distinction matters: **deferred** items may return; **excluded** items are product boundaries whose reintroduction would change what CogniHire is.

### 9.1 Deferred (may return in V2+)

| Feature | Why deferred |
|---|---|
| ATS/HRIS integration | The largest untested assumption in the project is whether the core value proposition holds at all (A-01). Building toward a specific integration before that is validated optimises the wrong variable |
| Multi-reviewer consensus on disputed claims | Requires a reviewer-identity concept the current role model lacks; bolting it on speculatively would shape the RBAC model around an unvalidated workflow |
| Multi-language interviews | The grounding gate is a verbatim substring match. Cross-language grounding is a genuinely different mechanism, not a translation layer |
| Session replay for reviewers | Storage, retention, and consent implications that a V1 retention policy must settle first |
| Scheduling, calendar, notifications, email | Commodity. Buy or integrate; never build |
| Environment/object detection (second screen, phone) | Present in the reference codebase, never ported. Requires an explicit in-or-out decision because the honest version detects little and the dishonest version fabricates — the reference implementation fired `PHONE_DETECTED` from ambient brightness |
| Code authorship verification engine | Fully designed `[DES]`; the highest-value deferred item. Deferred only because V1 Tier 1 is deployment-blocking |
| Engineering memory model (probes for past-role claims) | Fully designed `[DES]`; its question bank is usable as a printed human-interviewer aid with no code at all |
| Public API for third-party clients | No external client exists to consume one |

### 9.2 Excluded — boundary, not backlog

| Feature | Why it will not be built |
|---|---|
| Facial emotion / affect / stress inference | Three independent reasons: it contributed ~0.25 % of predictive value in the largest deployed system that tried it and was dropped; a hidden stress score picking easier questions *is* the hidden score this product's thesis rejects; and `isValidatedOnRealData = false` applies with more force to face-inferred affect than to the ML layer it is already stamped on. A test asserts the live model cannot be coaxed into "you seem nervous" `[IMPL]`. **If a future request asks to "make it adapt to candidate confidence," that is a boundary, not a gap — re-litigate deliberately, do not wire it in** |
| Any composite candidate score | §15. There is no code path to one and adding one is a change of product identity |
| AI-generated-text detection / stylometry | Unreliable, and measures the wrong variable. The question is whether the candidate holds a working mental model of their own code — orthogonal to how it was drafted. A tool-assisted-but-understood submission should pass; a self-typed-but-not-understood one should not |
| Voice stress analysis | Pseudoscience with documented hiring-bias exposure |
| Typing speed or vocabulary richness as ability signals | Proxies for demographics and disability, not for competence |
| Automated rejection, ranking, or shortlisting | Violates P3 and the regulatory posture simultaneously |
| Deception or honesty scoring | Explicitly rejected during design. The engineering-memory work inverts the naive reading: genuine memory decays *unevenly*, so hedging ("I'd have to check") is a **positive** signal, and uniformly crisp, hedge-free recall of years-old work is the thing worth a second look. A lie detector built on the opposite assumption would be both wrong and harmful |
| Training on hire/no-hire outcome labels | ED-04 |
| Claiming prevention of impersonation | Detect, deter, document. No software prevents a second device, and claiming otherwise loses the room and creates liability |

---

## 10. Functional Requirements

Priority: **M** = must (V1), **S** = should (V1 if capacity), **C** = could (V2). Status: `[IMPL]` / `[DES]` / `[PROP]`.

### FR-1 Identity and access

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-1.1 | The system shall authenticate every principal before any interview data is readable | M | `[PROP]` |
| FR-1.2 | The system shall resolve every route through a single permission choke point, denying by default | M | `[IMPL]` built / `[PROP]` wired |
| FR-1.3 | The system shall refuse a session whose stored role value is unrecognised, rather than defaulting to the least-privileged role — guessing a role is a security decision made by a parser | M | `[IMPL]` |
| FR-1.4 | The system shall record every administrative action in a cross-session audit log | M | `[PROP]` |
| FR-1.5 | The system shall scope every read to the principal's tenant | M | `[PROP]` |

### FR-2 Claim extraction

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-2.1 | The system shall extract discrete, checkable claims from resume text | M | `[IMPL]` |
| FR-2.2 | The system shall discard any extracted claim text not verbatim-present in the source, using whitespace-collapsed case-insensitive containment and no looser comparison | M | `[IMPL]` |
| FR-2.3 | The system shall record discarded ungrounded output rather than dropping it silently | M | `[IMPL]` |
| FR-2.4 | The system shall fall back to a deterministic extractor when the model is unavailable, stamping the effective extractor and a degradation reason on the result | M | `[IMPL]` |
| FR-2.5 | The system shall present extracted claims to the candidate for confirmation or correction before the interview begins | M | `[IMPL]` |
| FR-2.6 | The system shall never expose confidence, claim type, or quote as model-settable fields — a resume instructing the model to self-report high confidence must have no field to land in | M | `[DES]` |
| FR-2.7 | The system shall extract text from PDF and DOCX resumes | M | `[PROP]` |

### FR-3 Identity verification

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-3.1 | The system shall enrol a reference face embedding, rejecting captures below a minimum quality with actionable guidance | M | `[IMPL]` |
| FR-3.2 | The system shall re-verify identity on a jittered 15–25 s cadence for the session duration | M | `[IMPL]` |
| FR-3.3 | The system shall represent an unperformable check as a distinct state carrying a reason and **no similarity value** | M | `[IMPL]` |
| FR-3.4 | The system shall record every verification attempt, including failures and gaps, as evidence | M | `[IMPL]` |
| FR-3.5 | The system shall not proceed with an interview without a completed enrolment — enforced at the type level, not by a runtime check | M | `[IMPL]` |
| FR-3.6 | The system shall not report a FAR/FRR figure until the threshold is calibrated on ≥50 real pairs per class | M | `[IMPL: tool refuses]` |
| FR-3.7 | The system shall state plainly that it performs no liveness detection | M | `[PROP]` |

### FR-4 Interview execution

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-4.1 | The system shall sequence questions per claim on a fixed opening → deepening → verifying ladder | M | `[IMPL]` |
| FR-4.2 | The system shall classify a claim as `null` rather than guessing when classification is uncertain — a wrong guess selects an entire ladder aimed at the wrong thing and is invisible; an admitted gap is actionable | M | `[IMPL]` |
| FR-4.3 | The system shall convert a telemetry trigger into a question selection, never into a flag or a score | M | `[IMPL]` |
| FR-4.4 | The system shall verify that any quote attributed to the candidate is verbatim-findable in the transcript, downgrading the turn if not | M | `[IMPL]` |
| FR-4.5 | The system shall cap follow-ups per claim (design value: 6) and shall not carry difficulty across claims | M | `[DES]` |
| FR-4.6 | The system shall not infer or reference candidate affect at any point | M | `[IMPL: test-enforced]` |
| FR-4.7 | The system shall disclose that a planted defect is a deliberate exercise before presenting one | M | `[DES]` |
| FR-4.8 | The system shall warm the inference model before the candidate can submit a first answer | M | `[IMPL]` |
| FR-4.9 | The system shall support resuming an interrupted session | S | `[OPEN: OQ-13]` |

### FR-5 Evidence, audit, and reporting

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-5.1 | The system shall produce exactly one verdict per extracted claim from the closed set {substantiated, notDemonstrated, contradicted, notExamined} | M | `[IMPL]` |
| FR-5.2 | The system shall derive the audit deterministically, with no model call in the verdict path | M | `[IMPL]` |
| FR-5.3 | The system shall attach ≥1 evidence pointer to every non-`notExamined` verdict | M | `[IMPL]` |
| FR-5.4 | The system shall render an evidence graph with a mandatory non-empty rationale on every edge, rejected at construction time rather than at save | M | `[IMPL]` |
| FR-5.5 | The system shall not compute or expose any edge weight, centrality, or aggregate over the evidence graph | M | `[IMPL]` |
| FR-5.6 | The system shall surface orphan nodes and dangling edges as faults rather than hiding them | M | `[IMPL]` |
| FR-5.7 | The system shall export a self-contained audit with no network dependency | M | `[IMPL]` |
| FR-5.8 | The system shall escape all untrusted text in exports — resume and transcript content is attacker-controlled input | M | `[IMPL]` |
| FR-5.9 | The system shall make saved audits tamper-evident | M | `[PROP]` |
| FR-5.10 | The system shall never persist a derived field, recomputing it on load so a hand-edited file cannot disagree with the rules | M | `[IMPL]` |
| FR-5.11 | The system shall allow a reviewer to override a claim status with a mandatory written reason, retaining the original | M | `[PROP]` |

### FR-6 Decision support (ML)

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-6.1 | The system shall present every model output with its validation provenance, and shall reject an artifact whose provenance flags are missing or self-contradictory | M | `[IMPL]` |
| FR-6.2 | The system shall abstain rather than commit when the conformal gate is not satisfied, presenting abstention as a result | M | `[IMPL]` |
| FR-6.3 | The system shall explain a model output by exact arithmetic decomposition, never by a surrogate | M | `[IMPL]` |
| FR-6.4 | The system shall refuse to render a model decision when any blocking guard violation is present, displaying the violations instead | M | `[IMPL]` |
| FR-6.5 | The system shall mark a counterfactual outside the fitted range as infeasible rather than clamping or hiding it — extrapolated advice is a fabrication dressed as arithmetic | M | `[IMPL]` |
| FR-6.6 | The system shall provide no path to mark a synthetic-only model as validated on real data | M | `[IMPL]` |
| FR-6.7 | The system shall route all scoring through a single artifact path that applies a calibrator only if one shipped | M | `[IMPL]` — one caller still bypasses it |

### FR-7 Privacy and data lifecycle

| ID | Requirement | Pri | Status |
|---|---|:--:|:--:|
| FR-7.1 | The system shall obtain and record candidate disclosure before any biometric capture | M | `[PROP]` |
| FR-7.2 | The system shall permit a candidate to decline enrolment and shall state the consequence | M | `[IMPL]` |
| FR-7.3 | The system shall encrypt biometric templates and audits at rest | M | `[PROP]` |
| FR-7.4 | The system shall enforce a configurable retention period and delete on expiry | M | `[PROP]` |
| FR-7.5 | The system shall fulfil a data-subject deletion request across every store | M | `[PROP]` |
| FR-7.6 | The system shall scrub candidate identifiers from observability data at emission | M | `[IMPL: primitives]` / `[PROP: enforced]` |
| FR-7.7 | The system shall load only the face-model modules it uses, excluding demographic classifiers — verifiable in the service startup log | M | `[IMPL]` |

---

## 11. Non-Functional Requirements

### 11.1 Performance

| ID | Requirement | Target | Justification | Current |
|---|---|---|---|---|
| NFR-P1 | Time to first audible token of an interviewer turn (p95) | ≤ 1.5 s | Above ~2 s a conversational turn reads as a system fault and candidates begin talking over it. This is why `say` serialises as the **first** JSON key — the stream parser forwards it to TTS while the model is still writing the remaining fields `[IMPL]` | 2.2–2.6 s warm `[IMPL: measured]` |
| NFR-P2 | Cold-start inference cost, as experienced by a candidate | 0 s | A ~40 s cold load on the first turn is indistinguishable from a hang. Mitigated by mandatory `warmUp()` before input is enabled `[IMPL]` | ~40 s if warm-up is skipped |
| NFR-P3 | Face verification round trip (p95) | ≤ 400 ms | Must complete well inside the 15 s minimum check interval to avoid overlapping checks | Not measured `[OPEN]` |
| NFR-P4 | Claim extraction, full resume | ≤ 30 s | Runs once, pre-interview, never in the interview loop | 90 s timeout configured; typical unmeasured |
| NFR-P5 | Audit render and export | ≤ 2 s | Interactive expectation | Not measured |
| NFR-P6 | UI frame budget during a live session | 16.7 ms | Camera preview, animated presence UI, and a streaming transcript run concurrently; `CustomPainter` geometry is already kept out of `build()` `[IMPL]` | Not profiled `[OPEN]` |

> **Constraint on NFR-P1.** The chosen streaming design forbids chain-of-thought in the interview prompt — the `why` field is a one-sentence post-hoc audit line, not a scratchpad, because anything the model "thinks" before `say` is latency the candidate experiences as silence. A model that reorders the JSON object silently converts this into a latency bug, which is why key order is mechanically enforced by the eval harness `[IMPL]`.

### 11.2 Scalability

**Scale model.** Target: 1,000,000 interviews per year. All figures below are `[EST]`, derived from these stated assumptions: 45 min mean session; 250 business days; 10 active hours/day; 3× peak-to-mean concurrency; 20 s mean verification interval; ~40 model turns per interview.

| Derived quantity | Calculation | Result |
|---|---|---|
| Interview-hours per year | 1M × 0.75 h | 750,000 h |
| Mean concurrent sessions | 750,000 ÷ (250 × 10) | ~300 |
| Peak concurrent sessions | ×3 | **~900** |
| Identity verifications per session | 45 min ÷ 20 s | ~135 |
| Identity verifications per year | 1M × 135 | **~135 M** |
| Peak embedding throughput | 900 × 3/min | **~45 /s** |
| LLM turn generations per year | 1M × 40 | **~40 M** |
| Peak turn throughput | 900 sessions ÷ ~60 s per turn | **~15 /s** |

Consequences that bind Chapters 2 and 6:

| ID | Requirement | Justification |
|---|---|---|
| NFR-S1 | Every domain aggregate shall carry a tenant key from V1 | Retrofitting a tenant key across `Role`, `ClaimAudit`, `EnrolmentProfile`, and the event log after data exists is a migration, not a refactor. **This is the single largest structural gap today** |
| NFR-S2 | Session state shall be externalised, not held in a process | `InterviewController` holds state in memory until `saveAudit()` — a crash loses the session and horizontal scale is impossible `[IMPL: gap]` |
| NFR-S3 | Inference shall be a horizontally scalable pool, not a per-device process | ~15 concurrent generations/s cannot be served by candidate hardware. This is the decision point where P4's local-first privacy property must be re-argued, not assumed — ED-01 |
| NFR-S4 | Embedding compute shall be batched and GPU-backed above ~10 /s | At ~45 /s, ArcFace-R50 on CPU at an assumed ~120 ms/embedding `[EST]` implies ~5–6 cores saturated continuously — workable but wasteful against batched GPU inference |
| NFR-S5 | The audit store shall move from per-session JSON files to an indexed store before ~10,000 sessions per tenant | Dashboard figures are recomputed from stored audits on load, with no caching — correct at demo scale (dozens), quadratic-feeling at thousands `[IMPL: acknowledged in source]` |
| NFR-S6 | Media (audio/video) shall never transit the application tier | At 1M sessions, media is the dominant byte volume; it belongs in object storage with signed URLs |

### 11.3 Security

| ID | Requirement | Justification | Current |
|---|---|---|---|
| NFR-SEC1 | Authentication shall not be satisfied by the in-memory test double | Plaintext passwords in a `Map` compared with `==` | **Violated** `[IMPL]` |
| NFR-SEC2 | Authorisation shall be enforced at one choke point, deny-by-default | Built and tested; unwired | **Violated in the running app** `[IMPL]` |
| NFR-SEC3 | Biometric templates shall be encrypted at rest and never leave the trust boundary in raw form | An ArcFace embedding is biometric personal data under GDPR Art. 9 / BIPA / DPDP | **Violated** — plaintext at rest |
| NFR-SEC4 | Saved audits shall be tamper-evident | Currently accidentally-mutable rather than deliberately either | **Violated** `[IMPL]` |
| NFR-SEC5 | All candidate-supplied text shall be treated as untrusted in every sink | Resume text reaches an HTML exporter and an LLM prompt — an XSS sink and a prompt-injection sink | HTML escaping `[IMPL]`; prompt-injection defence is structural (no model-settable confidence field) `[DES]` |
| NFR-SEC6 | Service-to-service calls shall be authenticated and CORS-restricted | `allow_origins=["*"]` today | **Violated** `[IMPL]` |
| NFR-SEC7 | No secret shall be committed | Verified clean; `.gitignore` covers `.env*`, `secrets.local.json`, `*.enrolment.json`, `audit_store/` | Compliant `[IMPL]` |
| NFR-SEC8 | The system shall state that it has no liveness detection rather than implying spoof resistance | A photo, screen replay, or deepfake is undefended | Not stated in-product `[PROP]` |

### 11.4 Reliability

| ID | Requirement | Justification | Current |
|---|---|---|---|
| NFR-R1 | No partial write shall be observable | Atomic temp-write + rename | `[IMPL]` |
| NFR-R2 | A corrupt record shall be reported, never omitted | A silently vanishing audit is a fabricated pass reached by omission | `[IMPL]` |
| NFR-R3 | Every external dependency shall have a defined degraded mode that is visible to the user | Ollama down → heuristic extractor with a stamped reason; face engine down → `engine_available: false`, no heuristic substitute | `[IMPL]` |
| NFR-R4 | An in-flight session shall survive a client crash | State is in-memory until save | **Violated** `[IMPL: gap]` — OQ-13 |
| NFR-R5 | A schema version bump shall have a migration path | A bump currently hard-throws and orphans every saved enrolment | **Violated** `[IMPL]` |
| NFR-R6 | Duplicate submission of an in-flight turn shall be ignored | Real race condition, caught by test | `[IMPL]` |

### 11.5 Availability

| ID | Requirement | Target | Note |
|---|---|---|---|
| NFR-A1 | Interview-taking path | 99.9 % during business hours | A failure here strands a candidate mid-interview — the highest-severity failure in the product |
| NFR-A2 | Review/reporting path | 99.5 % | Asynchronous; tolerates brief outages |
| NFR-A3 | Inference availability | Degrade, never fail | An unreachable model must fall back visibly, not abort the session `[IMPL: pattern established]` |
| NFR-A4 | Recovery time objective | ≤ 1 h | |
| NFR-A5 | Recovery point objective | 0 for completed audits | A completed audit is the product's only durable artifact |

### 11.6 Compliance

| ID | Requirement |
|---|---|
| NFR-C1 | The system shall operate without producing an automated employment decision, keeping it outside the bite-radius of automated-decision provisions while remaining subject to transparency obligations |
| NFR-C2 | The system shall support pre-interview disclosure of AI use, retention, and the reviewer's role — Illinois AIVI (eff. 2026-01-01) and analogous statutes |
| NFR-C3 | The system shall produce, on request, a per-candidate record of what was collected, what was concluded, and on what basis — GDPR Art. 15 and equivalents |
| NFR-C4 | The system shall support erasure across every store — GDPR Art. 17, DPDP |
| NFR-C5 | The system shall treat biometric processing as special-category data with explicit consent and a stated retention limit — GDPR Art. 9, BIPA, DPDP |
| NFR-C6 | The system shall retain evidence sufficient to answer an EU AI Act high-risk record-keeping request |
| NFR-C7 | The system shall not claim conformity with any bias-audit regime it has not undergone. Specifically: a third-party audit covering one representative use case is **not** blanket algorithmic validation and shall never be cited as such |

### 11.7 Maintainability

| ID | Requirement | Current |
|---|---|---|
| NFR-M1 | Domain logic shall be pure Dart, testable without a widget tree | `[IMPL]` |
| NFR-M2 | Test-to-source ratio ≥ 40 % | 42.7 % `[IMPL]` |
| NFR-M3 | Every screen shall have a widget-level mount test in light and dark | Partial — the suite was structurally blind to build-time screen crashes until a real one shipped past 162 green tests `[IMPL]` |
| NFR-M4 | A regression test shall be verified to fail before the fix is restored | Practice established `[IMPL]` |
| NFR-M5 | No prompt shall exist in two hand-synced copies without a drift-detecting test | One duplicate exists and has already caused a real bug; a test now diffs the embedded constant against the on-disk file `[IMPL]` |
| NFR-M6 | Design intent that forbids a future change shall be recorded at the point of temptation | Established — e.g. the comment explaining why `EvidenceGraph` has no `strength()` `[IMPL]` |
| NFR-M7 | No file shall exceed ~800 LOC without a stated reason | Violated by `patterns.dart` (1,487), `candidates_screen.dart` (1,026), `live_interview_screen.dart` (1,013) `[IMPL]` |
| NFR-M8 | Dead code shall be deleted or wired, never left resident | Violated: the entire RBAC subsystem and one full interview screen `[IMPL]` |

### 11.8 Observability

| ID | Requirement | Current |
|---|---|---|
| NFR-O1 | Every session shall emit a hash-chained event log sufficient to reconstruct its timeline | `[IMPL]` |
| NFR-O2 | Degradation shall be observable as a first-class event, not inferred from absence | `[IMPL]` — `degradedReason`, `TurnDegraded` |
| NFR-O3 | Telemetry shall carry no candidate-identifying content, scrubbed at emission | Primitives exist, enforcement does not `[IMPL: partial]` |
| NFR-O4 | Model outputs shall be traceable to an artifact version and its provenance flags | `[IMPL]` |
| NFR-O5 | The system shall expose health for each dependency distinguishing *unreachable* from *reachable but not functional* | `[IMPL]` — `engine_available` is separate from HTTP reachability |
| NFR-O6 | Latency percentiles shall be recorded for inference, embedding, and persistence | Absent `[OPEN]` |
| NFR-O7 | Grounding-gate rejection rate shall be monitored — a sudden rise means the model, the prompt, or the input distribution changed | Instrumented per-call, not aggregated `[IMPL: partial]` |

---

## 12. Constraints

### 12.1 Budget

| Constraint | Detail | Consequence |
|---|---|---|
| Zero external spend at present | No paid API subscription; prepaid-credit LLM APIs were evaluated and rejected on this basis | Forced local inference — which turned into P4, a genuine differentiator. This is a constraint that produced a design advantage, and it should not be silently discarded when budget appears |
| Solo engineering capacity | One engineer, part-time, against a fixed demo date of 2026-08-18 | V1 Tier 1 alone exceeds the remaining window. §16 sequences accordingly |
| No budget for real-data collection | Threshold calibration needs ≥50 genuine/impostor pairs per class from consenting volunteers | R-02 remains open indefinitely without it |

### 12.2 AI inference cost

The cost model is stated as a formula because vendor rates change and this project's own rule forbids quoting unverified figures.

Let:
- `T` = model turns per interview ≈ 40 `[EST]`
- `p` = prompt tokens per turn ≈ 1,500 (626-token static prefix + growing transcript) `[EST: prefix measured]`
- `c` = completion tokens per turn ≈ 150 `[EST]`
- `R_in`, `R_out` = provider rates per million tokens **(to be filled from a current price sheet — deliberately not quoted here)**

**Hosted cost per interview** = `T × (p × R_in + c × R_out) / 1e6` = `(60,000 × R_in + 6,000 × R_out) / 1e6`

Sensitivity: at a blended rate of $1/M input and $5/M output this is ~$0.09 per interview and ~$90 K/year at 1 M interviews `[EST]`. At a rate 10× higher it is ~$900 K/year — which changes the architecture, not just the budget line.

**Self-hosted cost**: ~15 concurrent generations/s (§11.2) against a 7B model serving an assumed 20–30 concurrent streams per data-centre GPU `[EST]` implies a fleet on the order of **30–45 GPUs** sustained, plus redundancy, plus operations.

**The conclusion that matters, and it inverts the current one:** at demo scale, local inference is cheaper *and* more private. At 1 M interviews/year, a hosted API is very likely cheaper than a self-hosted fleet, and the local-inference decision becomes a **privacy and positioning decision that must be paid for**, not a cost saving. Chapter 6 must price that explicitly rather than inheriting P4 as an axiom. Mitigations to evaluate there: prompt-prefix caching (the 626-token static prefix is the majority of `p` early in a session), per-tenant on-premises deployment for privacy-sensitive customers, and a hybrid where extraction stays local and turn generation is hosted.

### 12.3 Latency

| Constraint | Value | Origin |
|---|---|---|
| Conversational turn budget | ~1.5 s to first token | Human turn-taking tolerance |
| Cold model load | ~40 s | Measured on the reference machine `[IMPL]` — 21 s weight load + 17 s prompt eval |
| Warm turn | 2.2–2.6 s | Measured `[IMPL]` — currently over budget |
| Verification interval floor | 15 s | Below this, camera and inference contention becomes visible |
| Resource contention | Face service and LLM compete for the same GPU memory | On the reference machine: 4 GB VRAM, 15.2 GB RAM `[IMPL]` |

### 12.4 Hardware

| Constraint | Detail |
|---|---|
| Candidate hardware is unmanaged and arbitrary | Cannot assume a GPU, a working camera, or a permissive browser |
| Camera platform support is uneven | Android > Web > Windows. `camera` has **no** Windows support — adding it silently yields an empty plugin registrant and `availableCameras()` returns nothing, which presents as broken hardware `[IMPL: known trap]` |
| Android is untested | No physical device or emulator available `[IMPL: blocked]` |
| Reference dev machine | 15.2 GB RAM, RTX 5050 4 GB — adequate for a demo, unrepresentative of a candidate laptop |

### 12.5 Cloud dependency

| Constraint | Detail |
|---|---|
| Today: zero cloud dependency | No cloud SDK anywhere; no external API of any kind `[IMPL]` |
| This is a stated product property, not an accident | P4 and D4 |
| It is incompatible with multi-tenancy as currently framed | Recruiter and candidate on different machines require a shared store, which requires a trust boundary that does not exist today |
| The resolution is a decision, not a default | Three viable shapes: (a) cloud control plane + local data plane, keeping biometrics and documents on-device while syncing only audits; (b) per-tenant on-premises deployment; (c) full cloud with encryption and a DPA, abandoning the architectural privacy claim for a contractual one. **Chapter 2 must choose (a), (b), or (c) explicitly.** Option (a) preserves the differentiator and is the recommended starting position |

### 12.6 Regulatory

| Regime | Applicability | Binding effect on design |
|---|---|---|
| Illinois AI Video Interview Act + 2026-01-01 amendment | Any AI analysis of interview video | Pre-interview disclosure, explanation of what is evaluated, deletion on request |
| Illinois BIPA | Face embeddings | Written consent, published retention schedule, statutory damages per violation — the highest-severity exposure in the product |
| NYC Local Law 144 | Automated employment decision tools | CogniHire's no-score, human-in-the-loop design is intended to sit **outside** the AEDT definition. That position must be legally reviewed, not assumed — R-06 |
| EU AI Act | Employment = high risk | Risk management, data governance, record-keeping, human oversight, transparency |
| GDPR Art. 9 / 15 / 17 / 22 | Biometric data, access, erasure, automated decisions | Art. 22 is the reason P3 is architectural rather than aspirational |
| India DPDP Act | If deployed domestically | Consent, purpose limitation, erasure |

> **The regulatory floor and the product thesis coincide.** "Why not a composite score?" has a legal answer, not only an ethical one. That alignment is the most durable asset in the design — and it is also why any future request to add a score must be treated as a compliance change, not a feature request.

---

## 13. Assumptions

Each assumption states what breaks if it is false, and how to test it. An assumption with no test is a belief.

| ID | Assumption | If false | How to validate | Confidence |
|---|---|---|---|---|
| A-01 | Organisations will accept a tool that adds interview rigour without reducing recruiter time | The core value proposition fails and no amount of engineering saves it | **Customer discovery — not yet done. Zero recruiters or hiring managers have been interviewed.** This is the largest untested assumption in the project and it is stated plainly rather than papered over | **Low — untested** |
| A-02 | Reviewers will read a per-claim audit rather than demanding a summary number | The product is re-derived into the thing it rejects, by customer pressure | Task-based testing with real reviewers; measure time-to-disposition and requests for a score | Low |
| A-03 | A live adaptive follow-up is materially harder to defeat with a second screen than a static question | D3 collapses | Adversarial testing with instructed confederates | Medium — reasoned, untested |
| A-04 | Continuous face verification is acceptable to candidates | Adoption fails at the candidate end and creates a fairness story | Candidate-side consent and completion rates | Medium |
| A-05 | A 7B local model produces interview questions of acceptable quality | Either the model tier rises (cost) or turn generation moves to a hosted API (privacy) | Run the existing 15-case eval set against real `qwen2.5:7b` output — **this has never been done; the reference fixture is hand-authored** `[IMPL: gap]` | Medium |
| A-06 | Verbatim grounding rejects few enough legitimate claims to remain usable | Recall drops below usefulness and pressure to loosen the gate becomes irresistible | Measure `rejectedUngrounded` rate on a real resume corpus | Medium |
| A-07 | A raw cosine threshold of 0.50 is defensible for identity matching | False accepts or false rejects on real candidates | Calibration on ≥50 real pairs/class — tooling ready, data absent | **Low — explicitly unvalidated** |
| A-08 | The synthetic-data ML mechanism transfers to real data | The decision-support layer is a demonstration, not a feature | Real labelled data + held-out evaluation. There is deliberately no `fitReal()` path today | **Known false today, by design** |
| A-09 | The no-score design keeps CogniHire outside AEDT/Art. 22 scope | Compliance obligations expand substantially | Legal review — R-06 |
| A-10 | Claims extracted from a resume are the right verification unit | The entire data model is wrong | Observe how reviewers actually reason in a debrief |
| A-11 | Candidate hardware can run a camera and a mic reliably enough | Session abandonment | Instrument enrolment and session failure rates |
| A-12 | Local-first survives the move to multi-tenant in some form | The central differentiator is lost at exactly the moment the product becomes sellable | Chapter 2 must resolve §12.5 |

---

## 14. Risks

Likelihood and impact are on a 3-point scale. Exposure = the pair, ordered by consequence rather than arithmetic.

### Risk register

| ID | Risk | Impact | Likelihood | Owner |
|---|---|---|---|---|
| R-01 | Core value proposition is unvalidated | Critical | High | Product |
| R-02 | Identity threshold is uncalibrated | High | High | ML |
| R-03 | No liveness detection | High | Medium | Security |
| R-04 | Authentication is a test double and RBAC is unwired | Critical | Certain (present) | Security |
| R-05 | No tenant key on any aggregate | High | Certain (present) | Architecture |
| R-06 | Regulatory classification is assumed, not reviewed | High | Medium | Compliance |
| R-07 | Fabrication regression | Critical | Low | Engineering |
| R-08 | Saved audits have no integrity protection | High | Certain (present) | Security |
| R-09 | Local 7B model quality is inadequate | Medium | Medium | ML |
| R-10 | Dead-code divergence (two interview screens, unwired RBAC, unwired prompts) | Medium | Certain (present) | Engineering |
| R-11 | Single-person key-person dependency | High | Medium | Programme |
| R-12 | Adversarial candidate defeats the mechanism | Medium | Medium | Product |
| R-13 | Scope creep toward a score, driven by customers | Critical | Medium | Product |

### Detailed treatment of major risks

---

**R-01 — The core value proposition has never been tested with a buyer.**
*Description.* No recruiter, hiring manager, or talent leader has been interviewed. Every claim about what recruiters want is inferred from competitive analysis and first principles. The project has previously had fabricated customer research inserted into its own documents by generated prose — five recruiter interviews that never happened — which was caught and corrected, and which demonstrates how strong the pull toward inventing this validation is.
*Impact.* Critical. A technically excellent implementation of an unwanted workflow.
*Likelihood.* High — it is currently unknown, which is the same as unmitigated.
*Mitigation.* Ten structured discovery conversations before any V1 Tier 2/3 work. Test A-01 and A-02 specifically — particularly whether reviewers demand a summary number. **Standing rule: any number, citation, or quotation in a customer-facing artifact must be greppable in the market-research document, or it does not ship.**

---

**R-02 — The identity threshold is reasoned but unvalidated.**
*Description.* A raw cosine threshold of 0.50 with no FAR/FRR measurement on real pairs. The calibration tool exists and correctly refuses to report below 50 pairs per class; the data does not exist.
*Impact.* High. A false accept means the entire provenance claim is void for that session; a false reject means an innocent candidate is disrupted.
*Likelihood.* High that the value is imperfect; the direction and magnitude are unknown.
*Mitigation.* (1) The refusal-to-report is already enforced in tooling — **quote no FAR/FRR figure anywhere until the data exists.** (2) Collect volunteer pairs under a written protocol. (3) Until then, present identity results as an evidence stream for a human, never as a gate. Note that the related trap is already avoided: a naive rescale used in the reference codebase floors unrelated faces near 50 %, which badly misleads a human reader; this system maps unrelated pairs to ~0 instead `[IMPL]`.

---

**R-03 — No liveness or anti-spoof detection.**
*Description.* A printed photo, a screen replay, or a deepfake defeats identity verification. Nothing in the codebase defends against it.
*Impact.* High — it attacks D2 directly.
*Likelihood.* Medium today (attacker effort exceeds current stakes); rising with generative-video accessibility.
*Mitigation.* (1) **State it plainly in-product.** An honest "we do not defend against this" is a legitimate product answer; silence is not — OQ-07. (2) Rely on the layered design: defeating identity still leaves the impostor facing live adaptive follow-ups on claims they must comprehend in real time. (3) Evaluate passive liveness in V2 as a build-vs-buy decision. (4) Never describe the system as impersonation-proof.

---

**R-04 — Authentication is a test double and authorisation is not wired in.**
*Description.* The running application has no login. `InMemoryAuthStore` holds plaintext passwords in a `Map` compared with `==` and does not persist. A complete, well-tested RBAC matrix and route guard exist and are imported by nothing but their own tests. Every screen is reachable by anyone who opens the app.
*Impact.* Critical for any deployment beyond a single trusted machine.
*Likelihood.* Certain — it is the present state.
*Mitigation.* V1-01 and V1-02. **The good news is structural:** the work is not "design RBAC," it is "wire in the RBAC that exists and put a real store behind the interface it already targets." The `AuthStore` interface does not need to change.

---

**R-05 — No domain model carries a tenant key.**
*Description.* `Role`, `ClaimAudit`, `EnrolmentProfile`, and the session event log have no organisation or tenant field.
*Impact.* High. Retrofitting a tenant key after real data exists is a migration across every aggregate, every codec, and every stored file — with a schema-version check that currently hard-throws and has no migration path.
*Likelihood.* Certain — present state.
*Mitigation.* Add the key in V1 **before** any data that must be preserved exists. Combine with V1-18 (migration path) — doing both at once costs far less than either later. This is the clearest example of P7's rule being violated and is the top Chapter 3 item.

---

**R-06 — Regulatory classification is assumed rather than reviewed.**
*Description.* The design intends to sit outside AEDT/Art. 22 automated-decision scope by producing evidence rather than decisions. That is a legal conclusion reached by engineers.
*Impact.* High — misclassification means bias-audit obligations, notice requirements, and potential retroactive exposure.
*Likelihood.* Medium.
*Mitigation.* Counsel review before any production deployment. Design the compliance posture to be defensible **even if** classified as in-scope: pre-interview disclosure, per-candidate explanation, deletion, and record-keeping are being built regardless, which converts a classification loss from fatal into merely expensive.

---

**R-07 — A fabrication regression.**
*Description.* Any code path that returns a plausible value in place of a failed measurement. This is the failure mode the entire product exists to avoid, and it has been observed twice in adjacent contexts: reference code returning `verified: true, 98.7%` with no enrolled profile, and this project's own generated documents inventing customer research.
*Impact.* Critical and asymmetric. A pitch built on "we don't fabricate" does not survive the discovery of one fabricated output. Every honest claim dies with it.
*Likelihood.* Low, given the structural defences — but non-zero, and the highest-consequence risk in the register.
*Mitigation, layered.* Sealed union types make the failure unrepresentable rather than merely discouraged; strict codecs throw rather than default; the guard suite blocks rendering rather than warning; unreadable records are surfaced rather than filtered. **The observed pattern to watch for is subtler than a fake value: a correct number under a wrong heading.** That is precisely what the guard suite catches and what a passing test suite does not. A related instance was caught during ML work — an in-sample calibration metric printing a perfect 0.0000 and reading as a triumph. **Heuristic: when a metric looks perfect, check which fold it was fitted on.**

---

**R-08 — Saved audits are silently editable.**
*Description.* The hash chain covers the session event log. The saved `ClaimAudit` JSON — the artifact that leaves the app and is presented as defensible — has no hash, no signature, no protection.
*Impact.* High. The product's central artifact is not tamper-evident.
*Likelihood.* Certain — present state.
*Mitigation.* V1-06. Note the partial existing defence: derived fields are never persisted and are recomputed on load, so an edited file cannot make the *rules* disagree — but it can trivially alter the recorded evidence they operate on. OQ-06 must decide between an extended hash chain, a signature, and a server-side authoritative copy.

---

**R-10 — Divergence between what is built and what runs.**
*Description.* A 1,013-LOC interview screen reachable only from a dev harness; a complete RBAC subsystem with no importers; two of four on-disk prompts with no call site; a live prompt existing as a hand-synced duplicate that has already caused a real production bug; an answer-scoring input hardcoded to a constant, silently defeating two of the live prompt's own stated rules.
*Impact.* Medium, compounding. Every one of these is a green-tests-but-invisible-in-the-app failure, and that exact pattern has already recurred more than once in this project.
*Likelihood.* Certain — present state.
*Mitigation.* The navigation fix already applied is the right pattern and should be generalised: **a feature with no destination should be visibly missing rather than silently unreachable.** Concretely — wire it, or delete it, in V1. Add a CI check that fails on a `lib/` file with no non-test importer.

---

**R-13 — Customer-driven scope creep toward a score.**
*Description.* A prospect says "this is great, can you also give us one number?" The path from there to a composite rating is short, commercially motivated, and destroys the product's thesis and its regulatory position simultaneously.
*Impact.* Critical — it is an identity change, not a feature.
*Likelihood.* Medium and rising with commercial contact.
*Mitigation.* (1) §15 is a contract, not a preference. (2) The absence is structural — there is no field, no method, and no code path to a composite, and tests assert that no score, percentage, or rating text renders on the evidence graph. (3) The prepared answer is legal, not philosophical: composite scores are exactly what LL144, Illinois AIVI, and the EU AI Act penalise. (4) The substitute to offer instead: claim coverage against a role's required skills — a factual count, not a judgment of a person.

---

## 15. Product Boundaries

### CogniHire IS

- An **interview evidence system**: it collects, structures, and preserves what happened in an interview
- A **claim verification workflow**: resume claim → live probing → per-claim verdict with evidence pointers
- A **provenance system**: it continuously establishes whose work is being observed
- A **process-aware interviewer**: telemetry selects the next question, live
- A **decision-support tool for a human reviewer**, which refuses to render its own output when its guards fail
- An **auditability layer**: tamper-evident event logs, exportable self-contained reports, an inspectable evidence graph
- A **privacy-preserving processor**: documents and biometrics processed where captured
- **Honest about its own limits**: synthetic-only ML validation, an uncalibrated threshold, and absent liveness detection are surfaced, not buried

### CogniHire IS NOT

- **Not a scoring system.** No composite rating of a person exists at any layer, and there is no code path to one
- **Not an automated decision-maker.** It never rejects, ranks, filters, or shortlists
- **Not a proctoring or anti-cheating product.** It detects, deters, and documents. It does not prevent, and does not claim to
- **Not a lie detector.** No honesty, credibility, or deception score of any kind. "I don't remember" never counts against a claim
- **Not an emotion, affect, or personality analyser.** Excluded on evidentiary, ethical, and legal grounds simultaneously
- **Not an AI-generated-code detector.** It measures whether a candidate holds a working mental model of their own code — orthogonal to how the code was drafted
- **Not a psychometric or aptitude assessment.** Different statutory regime; no such claim is made
- **Not a candidate-ranking or comparison engine.** Claim coverage may be compared; candidates may not be scored
- **Not an ATS.** It produces an artifact an ATS can hold
- **Not a general-purpose interview platform.** No scheduling, no calendars, no video conferencing
- **Not a bias-audited system.** No third-party algorithmic audit has been performed, and none may be implied

> **Boundary enforcement clause.** Every "IS NOT" above is currently enforced by the absence of a mechanism, not by a policy document. Any change request that requires *adding* a mechanism to cross one of these lines must be escalated as a product-identity decision with §12.6 reviewed, not accepted as a feature request.

---

## 16. Version Roadmap

Stages are gated by exit criteria rather than by dates, with one exception: the MVP demonstration has a fixed external date of **2026-08-18**.

### MVP — *Prove the mechanism* (current, ~90 % complete)

*Goal:* demonstrate end-to-end that claim verification with continuous provenance and live process adaptation works on a real machine against real models.

*Delivered.* §8.1.

*Remaining before 2026-08-18:*
1. Run the 15-case interview eval set against real model output — currently only a hand-authored reference fixture exists (A-05)
2. Resolve the interview-screen fork sufficiently to demo one path end-to-end (OQ-01)
3. Wire the orphaned components that are already built and tested — the question bank and reviewer screen have no route reaching them
4. Human visual pass on the redesigned UI and both decks — machine verification is exhausted

*Exit criteria:* a single uninterrupted run from resume upload to exported audit, on one machine, with all four subsystems live and no hardcoded claims.

*Explicitly acceptable at this stage:* single tenant, no auth, local storage, synthetic-only ML, uncalibrated threshold — **each disclosed on screen.**

---

### V1 — *Deployable to someone else* (target: MVP + 3–4 months at current capacity)

*Goal:* an organisation other than the author's can run interviews without the author present.

*Content:* §8.2 Tiers 1–3.

*Exit criteria:*
- Real authentication; RBAC enforced at the single choke point
- Tenant key on every aggregate, with a working migration path
- Encryption at rest; tamper-evident saved audits
- Retention policy and data-subject deletion implemented
- Threshold calibrated on real data, **or** the FAR/FRR claim formally withdrawn in-product
- Ten customer-discovery conversations completed (R-01) — **this gates V1, not V2**
- One interview screen, one prompt copy, zero unwired subsystems (R-10 closed)
- Legal review of regulatory classification complete (R-06)

*Deliberately still absent:* multi-tenant cloud, real-data-validated ML, liveness detection, integrations.

---

### V2 — *Multi-tenant and scalable*

*Goal:* many organisations, thousands of interviews, without per-deployment engineering.

*Content:*
- Resolve §12.5 — the recommended starting position is a cloud control plane with a local data plane, preserving the architectural privacy claim
- Externalised session state; resumable interviews (NFR-R4)
- Inference as a scalable pool with the ED-01 privacy trade-off explicitly priced
- Indexed audit store replacing per-session JSON (NFR-S5)
- Hiring Manager and Org Admin roles; cross-session administrative audit log
- Code authorship verification engine `[DES]` — the highest-value deferred capability
- Engineering memory model `[DES]`
- Multi-reviewer consensus on disputed claims
- Real-data ML validation, **if and only if** an ethically sourced labelled dataset exists. Absent that, the ML layer remains explicitly synthetic-only rather than being quietly promoted
- Passive liveness detection, evaluated build-vs-buy
- Third-party bias audit — scoped honestly, never cited as blanket validation

*Exit criteria:* two unrelated tenants in production; p95 turn latency within budget at ~100 concurrent sessions; a bias audit published with its scope stated.

---

### Long-term vision

CogniHire becomes the **evidentiary layer for technical hiring** — the component that answers "what was actually verified about this person, by whom, on what basis" for any organisation that must answer that question to a candidate, a regulator, or itself.

Three directions, in decreasing confidence:

1. **Interview evidence as a portable, candidate-owned artifact.** A candidate accumulates verified claims they control and can present to multiple employers, inverting the current model where each employer re-verifies from scratch and the candidate owns nothing. This is the most defensible long-term position and the one most consistent with every principle in §5.
2. **The evidence standard rather than the product.** The evidence graph already exports GraphML — a real interoperability standard, not a proprietary format. An open schema for interview evidence outlives any single vendor.
3. **Regulatory infrastructure.** As AI-hiring regulation matures, organisations will need to produce interview records on demand. A system designed from the start to produce exactly that record is well positioned — and this is a direction to *earn* through V1 and V2 execution, not to claim now.

**The constraint that survives all three:** the system measures, and a human decides. Any long-term direction that requires relaxing that is a different product.

---

## 17. Engineering Decisions

Format: decision · why · alternatives considered · trade-offs accepted.

---

**ED-01 — Local model inference (Ollama `qwen2.5:7b`) rather than a hosted API**
*Why.* No budget for prepaid API credits; and the resulting property — candidate documents never leave the machine — is an architectural privacy claim rather than a contractual one, which no competitor can match by signing a DPA.
*Alternatives.* Hosted frontier API (better quality, per-token cost, egress of candidate data); self-hosted server-side inference (control plus scale, requires infrastructure that does not exist); no LLM at all with a purely deterministic extractor (buildable, materially worse recall).
*Trade-offs.* Accepted: 7B-class quality; ~40 s cold start requiring mandatory warm-up; contention with the face service for the same GPU memory; and — critically — **this decision does not survive multi-tenant scale unmodified** (§12.2). Recorded here so that Chapter 6 re-argues it rather than inheriting it. The deterministic fallback extractor is what keeps this decision reversible: the system already functions, degraded and disclosed, with no model at all.

---

**ED-02 — Verbatim substring grounding, with no fuzzy matching**
*Why.* A fabricated claim attributed to a real person is the worst output this system can emit. Verbatim containment is the only check with no threshold to tune and no failure mode that admits a plausible invention.
*Alternatives.* Embedding-similarity grounding (admits paraphrase — and paraphrase is exactly what must be rejected); token-overlap threshold (a tunable knob, and every tunable knob eventually gets loosened under recall pressure); LLM self-verification (asking the fabricator to check itself).
*Trade-offs.* Accepted: legitimate paraphrases are rejected, reducing recall. This is the correct direction to fail. The rule is stated as: **the model may select text; it may never author it.**

---

**ED-03 — No composite score, enforced by type absence rather than by policy**
*Why.* A field that exists will be read; a method that exists will be called. The regulatory position (LL144, Illinois AIVI, EU AI Act) and the product thesis both depend on the composite not existing.
*Alternatives.* An internal score hidden from the UI (it leaks, and it is discoverable in the export); a score shown with a caveat (caveats are not read); per-dimension scores without an aggregate (users compute the aggregate themselves — this is the closest alternative and was still rejected).
*Trade-offs.* Accepted: reviewers must read; comparison across candidates is harder; a real commercial objection has no easy answer. Guarded structurally — `EvidenceGraph` deliberately has no `strength()` or `centrality()` method, with a source comment explaining that a PageRank over the evidence graph would be a hidden weight in graph-theory costume.

---

**ED-04 — No hire/no-hire training labels anywhere**
*Why.* Outcome labels encode an organisation's historical hiring decisions, which is the exact mechanism by which the Amazon 2018 résumé system learned to penalise women. ML in this system measures; the decision layer is authored IF/THEN rules.
*Alternatives.* Supervised learning on outcomes (the industry default); weak supervision from interviewer ratings (same bias, noisier); learning to rank (a composite by another name).
*Trade-offs.* Accepted: no predictive-accuracy claim can ever be made, and the primary KPI a buyer expects is unavailable. This also answers the mentor question "where does your training data come from" cleanly — the toxic label never enters the system.

---

**ED-05 — Sealed union types for measurement results, with `Unchecked` carrying no similarity field**
*Why.* "Could not measure" and "measured and failed" are different states, and conflating them is how a fabricated pass happens. Making `Unchecked` structurally incapable of carrying a similarity value means it can never be misread as a weak pass.
*Alternatives.* Nullable similarity with a status flag (someone eventually reads the null as zero); exceptions (control-flow noise on a routine, expected condition); a sentinel value (the worst option — `-1` becomes a number in an average).
*Trade-offs.* Accepted: every consumer must handle three cases. That verbosity is the feature — exhaustiveness checking makes forgetting the third case a compile error.

---

**ED-06 — Model training in Python; all scoring, guards, and explanation on-device in Dart**
*Why.* scikit-learn's solver beats a hand-rolled one and real validation needs real tooling — but *a component that returns verdicts is a component that can invent them.* Coefficients are exported as a bundled asset, so scoring works offline and with every service down.
*Alternatives.* All in Dart (worse solver, no ecosystem); all in Python (a service that returns verdicts — reverses the project's thesis); ONNX export (heavier, and opaque where exact attribution is required).
*Trade-offs.* Accepted: two implementations must be kept in agreement — and this is treated as a feature, since the export test asserts the Python fit and the Dart fit recover the same planted weights, which is a stronger claim than either passing alone. One genuine hazard: the two objectives are equivalent only at a specific regularisation correspondence (`C = 1/(n·λ)`), and getting it wrong makes them diverge silently. **Explicit instruction to future contributors: do not "finish the job" by moving guards to Python.**

---

**ED-07 — Isotonic calibration built, measured, and declined**
*Why.* Measured honestly across three folds, isotonic recalibration made every metric slightly worse (ECE 0.0321→0.0403, log loss 0.4761→0.5241, Brier 0.1578→0.1606) `[IMPL: measured]`. Expected, not a bug — a logistic model fit on a logistic generative process is already near-calibrated, so isotonic adds variance with nothing to correct. The exporter now embeds a calibrator only if it buys >0.005 held-out ECE without worsening log loss, and records the decision in the report.
*Alternatives.* Ship it anyway because calibration is best practice (a decorative box); Platt scaling (same argument); skip calibration entirely (then the question "is it calibrated?" has no evidence behind it).
*Trade-offs.* Accepted: engineering effort on a component that does not ship. The two-fold version of this experiment reported a perfect ECE of 0.0000 by fitting and scoring on the same predictions — **if a calibration number looks perfect, check which fold it was fitted on.** A related subtlety: the Python and Dart isotonic implementations differ between knots (linear interpolation vs. step function), so exporting scikit-learn's knots would ship a calibrator that disagrees slightly, plausibly, and invisibly with the one the app evaluates. The artifact therefore declares its representation and the loader refuses anything else.

---

**ED-08 — Deny-by-default RBAC in a single table, with own-vs-all as separate permissions**
*Why.* "Can a candidate read someone else's report?" must be answerable by reading one file, not by auditing a widget tree. A new permission is denied to every role until deliberately granted, and an exhaustiveness test fails until someone decides.
*Alternatives.* Role checks in widgets (the answer spreads across forty files); allow-by-default (a forgotten entry silently opens a door); attribute-based access control (more expressive, far more surface, unjustified at this scale).
*Trade-offs.* Accepted: adding a role multiplies the permission table, the route table, and the shell layouts. §6 accepts that cost deliberately for two new roles and rejects it for the operator role. `viewOwnReports` and `viewAllReports` are separate values on purpose — one permission plus a downstream `where` clause makes the boundary a filter a refactor can silently drop.

---

**ED-09 — Per-session JSON files with atomic write-then-rename, not a database**
*Why.* At demo scale an inspectable document is worth more than query performance the project does not need, and atomicity means a crash never leaves a half-written audit.
*Alternatives.* SQLite (real queries, opaque to inspection, migration overhead at a stage with no query need); a cloud database (violates the current trust boundary entirely).
*Trade-offs.* Accepted: no cross-session queries; dashboard figures recomputed on load; a wall at roughly thousands of sessions (NFR-S5). Mitigated by the `AuditStore` interface, which makes the replacement an implementation swap. **This must be revisited before V2, and OQ-15 asks whether local-only should remain a permanently supported deployment mode for privacy-focused customers.**

---

**ED-10 — Deterministic layered graph layout, not a force simulation**
*Why.* Determinism means the same evidence renders identically every time, which matters for a document meant to be compared and cited. The deeper reason: a force simulation has a per-edge spring weight, and a per-edge weight is precisely the numeric edge weight ED-03 forbids — it would eventually be promoted into "relationship strength."
*Alternatives.* Force-directed (organic, non-deterministic, carries the weight); Graphviz (external dependency, breaks offline operation).
*Trade-offs.* Accepted: less visually organic; layout quality must be hand-tuned for dense graphs.

---

**ED-11 — Template-first question generation with a deterministic banned-phrase linter**
*Why.* "Never accuse the candidate" must hold even when the model is prompted adversarially or drifts. A linter over generated text is a structural guarantee; prompt wording is not.
*Alternatives.* Prompt instructions alone (defeated by drift and injection); a model-based safety classifier (another model that can be wrong, and unexplainable); fully static questions (safe, not adaptive — this is the current shipped state).
*Trade-offs.* Accepted: less natural phrasing; the linter needs maintenance. Note the related tuning result — temperature 0 was correct for extraction and wrong for live interviewing, where a 7B model collapsed onto its most likely continuation *is* what "generic" means; 0.6 with a specificity rule requiring reference to a concrete named entity already on record fixed it measurably `[IMPL]`.

---

**ED-12 — Flutter, single codebase across desktop, web, and mobile**
*Why.* A solo engineer cannot maintain three clients. The domain layer is pure Dart with no Flutter imports, so ~all business logic is testable without a widget tree.
*Alternatives.* Web-only (no desktop camera reliability); native per-platform (impossible at this capacity); Electron plus native mobile (two stacks).
*Trade-offs.* Accepted: uneven camera support (Android > Web > Windows, with `camera` having no Windows support at all — a trap that presents as broken hardware); a smaller ecosystem for ML tooling; web builds falling back to in-memory storage, which the UI must state on screen. Cross-platform consistency is verified by widget tests that set an explicit view size, because Flutter's default test surface is unrealistically small for a desktop app.

---

## 18. Open Questions

Questions that must **not** be resolved by default or by drift. Each names the chapter that owns it and what is blocked until it is answered.

| ID | Question | Owner chapter | Blocks | Default if unanswered (and why that is bad) |
|---|---|---|---|---|
| OQ-01 | Is `LiveInterviewScreen` the intended interview experience, or should it be deleted? | Ch. 2 | All interview investment; the MVP demo path | Both survive — 1,013 LOC of liability and a split test surface |
| OQ-02 | Should the existing RBAC model be wired as-is, or does a real backend change what roles should exist? | Ch. 5 | V1-02, all role work | Wiring a 2-role model that §6 already says is wrong for V1 |
| OQ-03 | What replaces `InMemoryAuthStore`, and does that choice alter the `Principal`/`UserRole` model? | Ch. 5 | V1-01, everything downstream of it | Continued reliance on a documented test double |
| OQ-04 | Wire answer scoring for real, or formally delete the concept? | Ch. 4 | V1-08; two live-prompt rules currently run on a hardcoded constant | A rule the system cannot satisfy stays shipped |
| OQ-05 | Is LLM-generated report summarisation still wanted, given the deterministic no-fabricated-summary design elsewhere? | Ch. 4 | An unwired prompt on disk | An unused prompt implies an unbuilt feature to future readers |
| OQ-06 | Extended hash chain, cryptographic signature, or server-side authoritative copy for saved audits? | Ch. 5 | V1-06, R-08 | Audits stay silently editable |
| OQ-07 | Is liveness detection in scope at all, or is the honest stance "we do not defend against this, and we say so"? | Ch. 5 | R-03 | Silence, which reads as a capability claim |
| OQ-08 | What does "organisation" mean — does a recruiter's org own candidates and sessions, or do candidates own their data across multiple orgs' interviews? | **Ch. 3** | Every foreign key; the entire multi-tenancy shape; the long-term candidate-owned-evidence direction | The most consequential unanswered question in the blueprint. **Answer before any tenant-key migration.** |
| OQ-09 | May a candidate be interviewed more than once for the same role, and is that tracked? | Ch. 3 | Audit identity and uniqueness constraints | Silent duplicates |
| OQ-10 | Are completed audits immutable once saved, or annotatable by a reviewer? | Ch. 3 | V1-12, FR-5.11 | Accidentally mutable rather than deliberately either |
| OQ-11 | May a recruiter edit claims post-session, or only annotate them? And may a candidate contest a status? | Ch. 3 | The reviewer-assessment model; the candidate appeal path | An appeal path that is claimed but not exercisable |
| OQ-12 | May an audit be regenerated after the fact, and must prior versions be retained? | Ch. 3 | Versioning and retention design | Regeneration silently overwrites evidence |
| OQ-13 | Must interviews be resumable after an interruption? | Ch. 2 | NFR-R4; session-state externalisation | A crash strands a candidate and loses the session |
| OQ-14 | What is the retention and deletion policy for face embeddings and interview data? | Ch. 5 | V1-11, K16, K17, BIPA exposure | Indefinite retention of biometric data — the highest-severity legal exposure in the product |
| OQ-15 | Is single-tenant local-storage-only a permanently supported deployment mode, or a stepping stone? | Ch. 6 | Whether `JsonFileAuditStore` is maintained or deleted; the §12.5 choice | The privacy differentiator quietly disappears at the moment the product becomes sellable |
| OQ-16 | Does object/environment detection (second screen, phone) enter the product, or is it explicitly cut? | Ch. 4 | R-03 layering; §9.1 | Left ambiguous — and the reference implementation of this feature fabricated violations from ambient brightness |
| OQ-17 | What is the escalation path when identity verification fails mid-session? | Ch. 2 | Interview state machine design | Ad-hoc handling of the highest-stakes event in a session |

---

## Appendix A — Verified current-state snapshot (2026-08-02)

All figures traceable to the repository or to `docs/ARCHITECTURE_DISCOVERY_REPORT.md`.

| Dimension | Value |
|---|---|
| Application code | 104 files, 24,885 LOC under `lib/` |
| Test code | 63 files, 10,622 LOC (42.7 % of app LOC); 662 Dart tests, 21 Python tests |
| Static analysis | `flutter analyze` clean |
| Platforms | Windows verified (build + launch); Web partial (in-memory storage, disclosed); Android untested |
| Local services | Ollama `qwen2.5:7b` (claim extraction, live turns); FastAPI + InsightFace `buffalo_l` (face embedding) |
| ML models in production path | 2 — SCRFD `det_10g` (detection), ArcFace `w600k_r50` (512-d embedding). Demographic modules explicitly excluded and verified in the startup log |
| ML models trained in-house | 1 — logistic sufficiency model. **Synthetic data only.** `isValidatedOnRealData = false`; no `fitReal()` path exists |
| Held-out synthetic metrics | AUC 0.849 · Brier 0.158 · ECE 0.020 · accuracy 0.768, on 1,800 rows from 300 candidates unseen in training; exporter gates on AUC>0.7 / ECE<0.1 / Brier<0.25 and writes nothing on failure |
| Feature registry | 87 features |
| Claim states | 4 |
| Evidence graph | 7 node types, 7 edge types, no numeric weights |
| Identity threshold | 0.50 raw cosine — reasoned, **not** calibrated; no FAR/FRR may be quoted |
| Verification cadence | 15–25 s jittered |
| Telemetry triggers | 3 |
| Warm turn latency | 2.2–2.6 s (cold ~40 s) |
| Cloud dependencies | None |
| Authentication | Test double; not wired |
| Authorisation | Complete and tested; **not wired** — zero importers outside its own test |
| Multi-tenancy | Absent; no tenant key on any aggregate |
| Encryption at rest | Absent |
| Liveness detection | Absent |
| Version control | Single squashed commit `b55acba`; no incremental history |
| Fixed external date | 2026-08-18 demonstration |

---

## Appendix B — Traceability

| Goal | Principles | Requirements | Risks | Decisions |
|---|---|---|---|---|
| G1 Traceable evidence | P1, P2 | FR-5.1–5.6, FR-5.10 | R-13 | ED-03, ED-10 |
| G2 Continuous provenance | P2 | FR-3.1–3.7 | R-02, R-03 | ED-05 |
| G3 Visible failure | P1, P5 | FR-2.3–2.4, FR-3.3, FR-6.4 | R-07 | ED-05, ED-06 |
| G4 Human-in-the-loop | P3, P8 | FR-5.11, FR-6.2, FR-6.4 | R-06, R-13 | ED-03, ED-04 |
| G5 Data minimisation | P4 | FR-7.1–7.7 | R-04 | ED-01 |
| G6 Honest validation status | P1, P2 | FR-6.1, FR-6.5–6.6 | R-07 | ED-04, ED-07 |
| G7 Scale without rewrite | P7 | NFR-S1–S6 | R-05 | ED-09, ED-12 |
| G8 Regulatory defensibility | P2, P3 | NFR-C1–C7 | R-06 | ED-03, ED-04 |

---

*End of Chapter 1. Chapter 2 (System Architecture) inherits: the §12.5 deployment-shape decision, OQ-01, OQ-13, and OQ-17. Chapter 3 (Data Model) inherits OQ-08 first — it determines every foreign key in the system.*
