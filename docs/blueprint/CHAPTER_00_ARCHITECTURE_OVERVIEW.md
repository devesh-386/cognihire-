# Chapter 0 — Architecture Overview

**The first document every engineer reads.** It orients you to the CogniHire Engineering Blueprint — what the system is, why it is shaped the way it is, what is actually built versus specified, and how to navigate the seven chapters and their registers. It is deliberately short (a map, not the territory); the chapters remain the authoritative source.

---

## 1 Executive overview

**CogniHire is an AI interviewing platform whose product *is* a trustworthy, defensible record of what a candidate demonstrated — not a score, not a verdict, not a ranking.** It extracts checkable claims from a résumé (only claims verbatim-present in the source), conducts an adaptive interview that probes those claims, continuously verifies the candidate's identity, and compiles an append-only, tamper-evident **evidence audit** with full provenance. A human — never the system — makes the hire/reject decision, and that decision is kept **physically separate** from the evidence so the system can never learn (or be made to learn) to predict hiring outcomes.

Four differentiators define everything downstream:

1. **No hidden score.** There is no composite number. This is enforced by the *absence of a field*, not by policy (ED-03).
2. **No outcome-label dataset.** CogniHire never collects hire/no-hire labels and has no path to them — because that dataset is exactly how biased hiring models are trained (ED-04). Amazon's 2018 résumé-screener is the cautionary precedent named in Chapter 1.
3. **Grounded AI.** The model *selects and decomposes*; it never *authors* the evidential record. A claim not verbatim-present in the résumé is discarded (ED-02/ED-17).
4. **Tamper-evident by construction.** The interview is an append-only, hash-chained event log; the audit is a rebuildable projection of it (ED-13).

The single most consequential structural decision is **ED-14 🔴**: *Evidence* and *Disposition* are **Separate Ways** bounded contexts with **no join key, no shared credential, no network path** between them. The join `evidence ⋈ outcome` is the forbidden training set (ED-04), so the architecture makes that join *impossible to express* at four independent layers — schema, API contract, network, and CI. Nearly every 🔴 marker in the blueprint traces back to defending this boundary.

---

## 2 How to read the blueprint

The blueprint is a **living specification**, maintained the way mature engineering organisations maintain architecture:

- **Continuous decision tracking** — every Engineering Decision is numbered ED-01…ED-84 and never renumbered; a later chapter may *resolve* an earlier open question but may not *silently contradict* a decision. Contradictions are documented and resolved explicitly.
- **Continuous risk register** — R-01…R-89, with likelihood/impact/owner.
- **Continuous open-question register** — OQ-01…OQ-96, with priority and current default.
- **Evidence tags on every claim** — the discipline that keeps the document honest:

| Tag | Meaning |
|---|---|
| `[IMPL]` | Verified in the repository today — working software |
| `[DES]` | Designed in a `docs/*_DESIGN.md`; not implemented |
| `[PROP]` | Proposed by the chapter; not designed or built |
| `[EST]` | Calculated estimate; assumptions stated at the point of use |
| `[OPEN]` | Requires a decision (an OQ) |

> **Read the tags literally.** A sentence without `[IMPL]` is a *specification*, not a description of working software. Most of Chapters 4–7 is `[PROP]` — the system today is a single-process Flutter prototype (see §4).

Chapters are **cumulative and immutable once issued**. Each chapter continues the ED/OQ/R numbering from the previous one (see the dependency section for ranges).

---

## 3 Reading guide — where to start by role

| You are… | Read, in order |
|---|---|
| **New to the project** | This chapter → [Ch1 Vision](CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md) → the ED-14 explanation in [Ch3 Part A](CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md) → [Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md) |
| **Backend / API engineer** | Ch3 (DDD) → Ch4 (data) → Ch5 (contracts) → [Roadmap](IMPLEMENTATION_ROADMAP.md) |
| **Data / platform engineer** | Ch4 (data/event store) → Ch7 (infra) → [Appendix A](APPENDIX_A_DECISION_REGISTER.md) |
| **Security / privacy / compliance** | Ch6 (security) → Ch4 §20–22 → [Appendix B](APPENDIX_B_RISK_REGISTER.md) |
| **AI / ML engineer** | Ch1 §KPIs → Ch3 Part B §16 (AI arch) → Ch5 §12 (AI contracts) → Ch6 §11 (AI trust) |
| **SRE / DevOps** | Ch7 (both parts) → Ch6 §14/§19 → [Roadmap](IMPLEMENTATION_ROADMAP.md) Sprint 6 |
| **Product / founder** | Ch1 → Ch2 (journeys) → [Appendix C](APPENDIX_C_OPEN_QUESTIONS.md) P0 questions |
| **About to open a PR** | [Architecture Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md) — the merge gate |

**Golden rule for contributors:** if you are about to touch evidence, disposition, scoring, AI output, the audit log, tenancy, or PII — read the relevant chapter *and* run the [Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md) first. The nine checklist questions exist so that ED-14 and its siblings survive people who weren't in the room when they were decided.

---

## 4 Current implementation status

As verified against the repository (basis: `docs/ARCHITECTURE_DISCOVERY_REPORT.md` and code reads):

**What is `[IMPL]` today — a working single-process Flutter prototype:**
- The **hash-chained, tamper-evident session event log** (`session_event_log.dart`) with `verifyIntegrity()` and strict decode.
- The **grounding gate** — verbatim claim extraction (`lib/core/claims/**`), with a deterministic fallback extractor.
- **Continuous identity verification** + the FastAPI face service (`service/`); sealed `VerificationResult` where `Unchecked` has no similarity field.
- The **ML decision engine** (`lib/core/ml/**`) — synthetic-trained, calibrated, conformal+abstain, exact attribution, `isValidatedOnRealData=false`.
- The **evidence graph** + deterministic audit compiler; **no composite score** anywhere.
- The **RBAC/permission matrix** (`lib/core/rbac/**`) — built and tested **but unwired** (the app enforces nothing — **R-64, Critical**).
- **Local Ollama inference** (`qwen2.5:7b`), no API key, no data egress.
- File-based persistence (per-session JSON, atomic write-then-rename).
- **537 tests**, `dart analyze` clean; widget tests added after a green-but-crashing regression.

**What is `[PROP]`/`[DES]` — specified, not built:** the entire cloud/production stack — Postgres/event-store/pgvector, Redis, object storage, the API gateway, the service decomposition, the event bus, WebSocket tier, multi-tenancy (RLS + per-tenant keys), the disposition database, CI/CD, IaC, Kubernetes, observability, and every deployment tier beyond "runs on a laptop."

**The one-line status:** *the software is fully specified and its hardest domain logic is built and tested; what remains is wiring, persistence, tenancy, the service/API surface, and production infrastructure* — which is what the [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md) sequences.

---

## 5 Chapter dependency graph

```
Ch1 Vision & Scope ─────────────┐  (product principles: no score, no labels, grounding, tamper-evidence)
      │                         │
      ▼                         │
Ch2 Personas & Journeys         │  (actors, state machines, the §17.5 evidence/disposition hazard)
      │                         │
      ▼                         ▼
Ch3 DDD & Architecture ◀────────┘  (bounded contexts; ED-13 event sourcing; ED-14 🔴 the boundary)
      │
      ├──────────────┬───────────────┐
      ▼              ▼               ▼
Ch4 Data        Ch5 API         Ch6 Security      (each enforces ED-13/ED-14 in its own plane:
 (persistence)  (contracts)     (trust)            data / contract / network+trust)
      │              │               │
      └──────────────┴───────┬───────┘
                             ▼
                       Ch7 Infrastructure        (runs it in production; 3 tiers; carries Ch6 §14)
```

**Reading direction:** Ch1 sets the principles; Ch2 makes the hazard concrete; Ch3 defines the software; Ch4/5/6 enforce Ch3's boundaries in the data, contract, and security planes respectively; Ch7 runs it. **You cannot understand why Ch4 forbids a `disposition.session_id` column, or why Ch5 has no endpoint returning both, without ED-14 from Ch3 — which is why this overview exists.**

---

## 6 Decision dependency graph (the load-bearing spine)

```
ED-04 (no outcome labels) ─┐
ED-03 (no score) ──────────┼──▶ ED-14 🔴 (Evidence⟂Disposition)
                           │        │
                           │        ├─▶ ED-28 (minimal shared kernel)
                           │        ├─▶ ED-40 (outcome-free analytics)
                           │        ├─▶ ED-45 (CI contract test)      ┐
                           │        ├─▶ ED-62 (four-layer enforcement)├─ the fences
                           │        ├─▶ ED-69 (K8s namespace/netpol)  │
                           │        └─▶ ED-76 (separate DB even at MVP)┘
ED-02 (verbatim grounding) ─▶ ED-17 (gate in consuming context) ─▶ ED-60 (leak = incident)
ED-13 (event sourcing) ──┬─▶ ED-21 (single-writer lease) ─▶ ED-47 (reconnect=replay)
                         ├─▶ ED-22/ED-35 (outbox) ─▶ ED-44 (202-on-append)
                         ├─▶ ED-30 (Postgres event store) ─▶ ED-38 (append-only across versions)
                         └─▶ ED-33/ED-57 (crypto-shred erasure, not edit)
ED-15 (TenantId in kernel) ─▶ ED-30 (RLS) ─▶ ED-43 (tenant-from-token) ─▶ (tenant isolation)
ED-16 (Inference ACL) ─▶ ED-48 (ports, no fabricating fallback) ─▶ ED-74 (AI infra evolves)
ED-51 (rate-limit never skips) ─▶ ED-66 (continuity never relaxes safety) ─▶ ED-80 (chaos asserts safety)
```

**The load-bearing five:** ED-03, ED-04, ED-13, ED-14, ED-02/17. A change that weakens any of these is a product-identity change, not a bug fix. Full table in [Appendix A](APPENDIX_A_DECISION_REGISTER.md).

**Series ranges:** ED-01–12 (Ch1) · ED-13–28 (Ch3) · ED-29–40 (Ch4) · ED-41–52 (Ch5) · ED-53–67 (Ch6) · ED-68–84 (Ch7). Next: **ED-85**. OQ: 01–17/18–30/31–42/43–58/59–70/71–83/84–96, next **OQ-97**. R: 01–13/14–25/26–37/38–50/51–62/63–76/77–89, next **R-90**.

---

## 7 Risk heatmap (summary)

The full heatmap is in [Appendix B](APPENDIX_B_RISK_REGISTER.md). The essentials:

- **Critical & present today:** **R-04 / R-64** — auth is a test double and the RBAC matrix is unwired; the running app enforces nothing. *This is the first thing to fix (Roadmap Sprint 1).*
- **Critical & product-defining:** R-13 (score creep), R-14/R-48/R-49 🔴 (reconstructing the outcome dataset), R-73 (autonomous scoring = compliance regression), R-74/R-84 (skipping identity checks to stay up). All are **mitigated-by-design** if the specified fences (ED-14, ED-40, ED-51, ED-66) are built as written.
- **Present & high:** R-02 (uncalibrated identity threshold), R-05 (no tenant key), R-08 (audits not tamper-proof), R-17 (enrolment consent), R-22 (in-memory session state).
- **The recurring theme** — an *omission* presented as a pass (a skipped check not recorded, a projection silently dropping an event): R-07, R-37 🔴, R-39, R-70, R-75. The architecture's answer is uniform: the runtime records the gap as `Unchecked`; the model never authors integrity events; there is no edit tool.

---

## 8 Open-question priority (the decision gate)

Full register with recommendations in [Appendix C](APPENDIX_C_OPEN_QUESTIONS.md). The **genuinely-open P0s** (decide before V1) are:

| OQ | Decide | Why now |
|---|---|---|
| **OQ-08** | What "organisation" means (org- vs candidate-owned data) | Determines every foreign key and the tenant-key migration — **decide first** |
| **OQ-14** | Biometric retention & deletion policy | Highest legal exposure; precedes storing biometrics at scale |
| **OQ-18** | Enrolment mandatory-vs-declinable (consent validity) | Consent conditioned on service access is presumptively invalid |
| **OQ-04** | Delete answer-scoring (or formally keep) | Two live rules run on a hardcoded constant today |
| **OQ-06** | Tamper-proofing for saved audits | Saved audits are silently editable today (R-08) |
| **OQ-17** | Identity-fail mid-session escalation | Highest-stakes in-session event; currently ad-hoc |
| **OQ-81** | EU AI Act floor vs certification timeline | EU operation has a hard compliance floor that precedes certification |

Several other P0s (OQ-01, OQ-13, OQ-26) are already **resolved on architectural grounds** (ED-25, ED-13/21, ED-13) and need only a delivery decision.

---

## 9 MVP implementation order (summary)

The [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md) sequences six sprints on the **T-MVP** tier (one box, real safety controls, no Kubernetes):

```
0  Decision gate + CI guardrails + Compose stores (incl. separate disposition DB)
1  Identity · Tenancy · RBAC        ← closes R-64 (Critical); wire the built matrix
2  Organizations · Candidates · Jobs · Invitations
3  Resume Intelligence · Inference Gateway · Interview Planning
4  Interview Session (event-sourced) · Memory · Voice
5  Evidence · Evaluation · Reports  ← erect the ED-14 boundary; all fences
6  Production deployment (T-MVP → path to T-SaaS)
```

Sprint 1 is first because unwired authorization (R-64) is the top present risk; the disposition database is provisioned *separate from Sprint 0* (ED-76) so ED-14 is never retrofitted.

---

## 10 Repository mapping

How the specification maps onto the codebase as it exists (`[IMPL]`) and will grow (`[PROP]`):

| Blueprint concept | Repo location (today `[IMPL]` unless noted) |
|---|---|
| Product principles, guards | `lib/core/ml/decision_guards.dart`, guard suite |
| Grounding gate / claim extraction | `lib/core/claims/**` (`ollama_claim_extractor.dart`, `heuristic_claim_extractor.dart`) |
| Session event log (event sourcing) | `lib/core/session/session_event_log.dart` |
| Identity verification | `lib/core/verification/**`, `service/` (FastAPI face) |
| Evidence graph / audit | `lib/core/graph/**`, `lib/core/claims/claim_audit.dart` |
| ML decision engine | `lib/core/ml/**` (model, calibration, conformal, attribution) |
| RBAC / auth (built, **unwired**) | `lib/core/rbac/**`, `lib/core/auth/**` |
| Persistence (file-based today) | `lib/core/persistence/**`, `lib/core/roles/role_store*.dart` |
| Privacy (scrubber, pseudonymisation) | `lib/core/privacy/**` |
| Inference Gateway (ACL) | `lib/core/interview/live_turn_client.dart`, `lib/core/config.dart` `[IMPL]` / pool `[PROP]` |
| Prompts + eval harness | `prompts/**` |
| UI screens | `lib/features/**`, `lib/ui/**` (interview screen unification → ED-25) |
| Event store / read models / projections | `[PROP]` — Postgres per Ch4 |
| API gateway / services / contracts | `[PROP]` — per Ch5 |
| Cloud / K8s / CI/CD / IaC | `[PROP]` — per Ch7; `.claude/launch.json` for local run |
| Prior design docs | `docs/*_DESIGN.md` (`[DES]` basis), `docs/PRODUCT_OVERVIEW.md`, `docs/ARCHITECTURE_DISCOVERY_REPORT.md` |

---

## 11 Glossary

| Term | Meaning |
|---|---|
| **Bounded Context** | A DDD boundary within which a model and its ubiquitous language are consistent (Ch3). |
| **Claim** | A discrete, checkable assertion extracted **verbatim** from a résumé. |
| **Grounding gate** | The check that discards any claim text not verbatim-present in the source (ED-02). |
| **Evidence** | The append-only record of what a candidate demonstrated — audit + evidence graph (BC-07). |
| **Disposition** | The human hire/reject decision (BC-09) — kept physically separate from evidence (ED-14). |
| **Event sourcing** | Storing state as an append-only sequence of events; the aggregate is the fold of its stream (ED-13). |
| **Projection / read model** | A derived, rebuildable view built from the event stream (CQRS read side). |
| **Sufficiency evaluation** | Decision *support* (is there enough evidence?) — never a score or recommendation (BC-08). |
| **`Unchecked`** | A verification result meaning "could not verify" — carries **no** similarity value (ED-05). |
| **Crypto-shred** | Erasure by destroying the decryption key, leaving unreadable ciphertext + a tombstone (ED-33/57). |
| **Tamper-evident** | Alteration is *detectable* (hash chain) — distinct from tamper-*proof* (see ED-59). |
| **Separate Ways** | A DDD context-map relationship: two contexts deliberately share nothing (ED-14). |
| **Tenant** | The isolation + billing boundary; every row carries `tenant_id`, RLS-enforced (ED-15/30). |
| **T-MVP / T-SaaS / T-ENT** | The three deployment tiers: single-box MVP / multi-tenant SaaS / dedicated enterprise (Ch7). |
| **Inference Gateway** | The anti-corruption layer over all AI inference (local Ollama → future pool) (ED-16). |
| **Outbox** | A table written in the same transaction as an event, relayed to the bus for reliable delivery (ED-35). |

---

## 12 Acronyms

| Acronym | Expansion |
|---|---|
| ADR | Architecture Decision Record (here, an **ED**) |
| ABAC / RBAC | Attribute- / Role-Based Access Control |
| ACL | Anti-Corruption Layer (DDD) — *not* access-control list here |
| BC | Bounded Context |
| CDC | Change Data Capture |
| CQRS | Command Query Responsibility Segregation |
| DDD | Domain-Driven Design |
| DEK / KEK | Data / Key Encryption Key |
| ED / OQ / R | Engineering Decision / Open Question / Risk |
| FAR / FRR | False Accept / False Reject Rate (biometrics) |
| GUC | Grand Unified Configuration (a Postgres session variable — used for RLS) |
| KMS / HSM | Key Management Service / Hardware Security Module |
| PITR | Point-In-Time Recovery |
| RLS | Row-Level Security (Postgres) |
| RPO / RTO | Recovery Point / Time Objective |
| SBOM | Software Bill of Materials |
| SLI / SLO | Service Level Indicator / Objective |
| SSE | Server-Sent Events |
| STT / TTS | Speech-To-Text / Text-To-Speech |
| WCAG | Web Content Accessibility Guidelines |

---

*This overview is the front door. The [Handbook](HANDBOOK.md) is the full table of contents; the seven chapters are the authoritative specification; the appendices and roadmap are the working instruments. Start here, then go where §3 points you.*
