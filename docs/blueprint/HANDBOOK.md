# CogniHire — Architecture Handbook

**The canonical reference for the CogniHire project.** Every engineer, contributor, and future maintainer starts here. This handbook is a thin index; the documents it links are the authoritative source. Read [Chapter 0 — Architecture Overview](CHAPTER_00_ARCHITECTURE_OVERVIEW.md) first — it is the front door.

> **What this is.** A living software-architecture specification, maintained like a mature engineering organisation maintains architecture: continuous decision tracking (ED-01…ED-84), a continuous risk register (R-01…R-89), a continuous open-question register (OQ-01…OQ-96), evidence tags on every claim, and explicit contradiction tracking rather than silent edits. It runs from product vision through production operations.
>
> **Honesty contract.** A statement tagged `[IMPL]` describes working software in the repository. Everything else (`[DES]`/`[PROP]`/`[EST]`/`[OPEN]`) is a specification, a design, an estimate, or an open decision. Today the system is a working single-process Flutter prototype with its hardest domain logic built and tested; most of the cloud/production architecture is `[PROP]`. See [Ch0 §4](CHAPTER_00_ARCHITECTURE_OVERVIEW.md).

---

## Contents

### 1. Orientation
| Document | Purpose |
|---|---|
| [Chapter 0 — Architecture Overview](CHAPTER_00_ARCHITECTURE_OVERVIEW.md) | Executive overview, how to read the blueprint, current status, dependency graphs, risk heatmap, OQ priority, repo mapping, glossary, acronyms. **Start here.** |
| [Reading guide](CHAPTER_00_ARCHITECTURE_OVERVIEW.md#3-reading-guide--where-to-start-by-role) | Where to start by role (in Ch0 §3) |

### 2. The seven chapters (authoritative specification)
| Ch. | Title | Series added |
|---|---|---|
| 1 | [Product Vision & Scope](CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md) | ED-01…12 · OQ-01…17 · R-01…13 |
| 2 | [User Personas & Complete User Journey](CHAPTER_02_PERSONAS_AND_USER_JOURNEY.md) | OQ-18…30 · R-14…25 |
| 3 | DDD, Bounded Contexts & System Architecture — [A](CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md) · [B](CHAPTER_03_PART_B_TACTICAL_DESIGN.md) · [C](CHAPTER_03_PART_C_ARCHITECTURE_DECISIONS.md) | ED-13…28 · OQ-31…42 · R-26…37 |
| 4 | Data Architecture, Database & Event Store — [A](CHAPTER_04_PART_A_DATA_MODEL_AND_EVENT_STORE.md) · [B](CHAPTER_04_PART_B_STORAGE_PRIVACY_AND_DECISIONS.md) | ED-29…40 · OQ-43…58 · R-38…50 |
| 5 | API Architecture, Service Contracts & Integration — [A](CHAPTER_05_PART_A_SERVICES_AND_CONTRACTS.md) · [B](CHAPTER_05_PART_B_INTEGRATION_SECURITY_AND_DECISIONS.md) | ED-41…52 · OQ-59…70 · R-51…62 |
| 6 | Security, Privacy, Compliance & Trust — [A](CHAPTER_06_PART_A_THREAT_MODEL_AND_TRUST.md) · [B](CHAPTER_06_PART_B_COMPLIANCE_AND_OPERATIONS.md) | ED-53…67 · OQ-71…83 · R-63…76 |
| 7 | Infrastructure, Cloud, Scalability, DevOps & Ops — [A](CHAPTER_07_PART_A_TOPOLOGY_AND_PLATFORM.md) · [B](CHAPTER_07_PART_B_SCALE_RELIABILITY_AND_OPERATIONS.md) | ED-68…84 · OQ-84…96 · R-77…89 |

### 3. Registers (working instruments)
| Document | Purpose |
|---|---|
| [Appendix A — Decision Register](APPENDIX_A_DECISION_REGISTER.md) | Every ED-01…84: status, owner, chapter, depends-on |
| [Appendix B — Risk Register](APPENDIX_B_RISK_REGISTER.md) | Every R-01…89: likelihood, impact, owner, status, mitigation + heatmap |
| [Appendix C — Open Question Register](APPENDIX_C_OPEN_QUESTIONS.md) | Every OQ-01…96: priority, owner, blocked work, current recommendation |

### 4. Execution
| Document | Purpose |
|---|---|
| [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md) | Six sprints on the T-MVP tier, each naming the EDs it implements and risks it closes |
| [Architecture Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md) | The nine-question PR merge gate — the architecture gate |

### 5. Reference material
| Path | Role |
|---|---|
| `docs/ARCHITECTURE_DISCOVERY_REPORT.md` | Code-verified current state; the factual basis for every `[IMPL]` tag |
| `docs/PRODUCT_OVERVIEW.md` | Narrative overview; superseded as a spec by Ch1 |
| `docs/*_DESIGN.md` | Subsystem designs; the basis for `[DES]` tags |

---

## The five decisions that define the product

If you read nothing else, understand these — a change that weakens any one is a change to *what CogniHire is*, not a bug fix:

1. **ED-03 — No composite score.** Enforced by the absence of a field, not by policy.
2. **ED-04 — No hire/no-hire training labels.** The system has no path to the dataset that trains biased hiring models.
3. **ED-13 — Event-sourced, tamper-evident record.** The interview is an append-only hash-chained log; the audit is a rebuildable projection.
4. **ED-14 🔴 — Evidence ⟂ Disposition.** Separate contexts, no join key, no shared credential, no network path — enforced at schema, contract, network, and CI layers. The join *evidence ⋈ outcome* is the forbidden dataset (ED-04), made impossible to express.
5. **ED-02 / ED-17 — Grounded AI.** The model selects and decomposes; it never authors the evidential record.

Everything marked 🔴 in the blueprint exists to defend these.

---

## Series continuity

| Series | Range issued (Ch1–7) | Next |
|---|---|---|
| Engineering Decisions | ED-01 … ED-84 | **ED-85** |
| Open Questions | OQ-01 … OQ-96 | **OQ-97** |
| Risks | R-01 … R-89 | **R-90** |

New decisions/risks/questions continue these series and are added to the appendices in the same pull request that introduces them (Validation Checklist question 7).

---

## Working agreements

- **The [Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md) is the merge gate.** Every PR passes its nine questions; questions 1, 2, 3, 5, 6, 8 are substantially automated as red CI builds.
- **Contradictions are documented, never silent.** A later change that contradicts an earlier ED writes a new ED explaining the resolution and marks the old one superseded.
- **Evidence tags are mandatory** on any claim about system behaviour.
- **Never build:** a composite score (ED-03), an evidence↔disposition join (ED-14), an edit tool for the event log/audit (R-50), a fabricating fallback on the identity/answer path (ED-48), or a feature that collects hire/no-hire outcomes (ED-04).

---

*CogniHire Engineering Blueprint v1.0 — Chapters 1–7 complete · 84 Engineering Decisions · 89 Risks · 96 Open Questions · overview, registers, roadmap, and validation gate.*
