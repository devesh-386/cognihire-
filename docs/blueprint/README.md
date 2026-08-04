# CogniHire — Engineering Blueprint

Chapters are cumulative and immutable once issued. A later chapter may **resolve** an earlier open question but may not silently contradict an earlier decision; contradictions are documented and resolved explicitly.

## Chapters

| Ch. | Title | File | Covers |
|---|---|---|---|
| 1 | Product Vision & Scope | [CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md](CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md) | Vision, goals, KPIs, principles, stakeholders, scope, FR/NFR, constraints, assumptions, risks, boundaries, roadmap, ED-01…ED-12, OQ-01…OQ-17, R-01…R-13 |
| 2 | User Personas & Complete User Journey | [CHAPTER_02_PERSONAS_AND_USER_JOURNEY.md](CHAPTER_02_PERSONAS_AND_USER_JOURNEY.md) | 17 actors, 5 personas, 5 human journeys, AI internal journey, state machines, edge cases, permissions, notifications, analytics, OQ-18…OQ-30, R-14…R-25 |
| 3 | DDD, Bounded Contexts & System Architecture | Part A · Part B · Part C (below) | Domains, contexts, aggregates, events, CQRS, AI architecture, consistency, tenancy, security, scale, ED-13…ED-28, OQ-31…OQ-42, R-26…R-37 |

### Chapter 3 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md](CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md) | 1–5: executive summary, 16 domains, classification, 14 bounded contexts, context map |
| B | [CHAPTER_03_PART_B_TACTICAL_DESIGN.md](CHAPTER_03_PART_B_TACTICAL_DESIGN.md) | 6–16: aggregates, entities, value objects, domain/application services, repositories, events, commands, queries, event storming, AI architecture |
| C | [CHAPTER_03_PART_C_ARCHITECTURE_DECISIONS.md](CHAPTER_03_PART_C_ARCHITECTURE_DECISIONS.md) | 17–27: communication, consistency, transactions, multi-tenancy, security, scalability, failure, ADRs, OQ, risks, engineering notes |

## Series continuity

| Series | Ch. 1 | Ch. 2 | Ch. 3 | Next chapter starts at |
|---|---|---|---|---|
| Engineering Decisions / ADRs | ED-01…ED-12 | — | ED-13…ED-28 | **ED-29** |
| Open Questions | OQ-01…OQ-17 | OQ-18…OQ-30 | OQ-31…OQ-42 | **OQ-43** |
| Risks | R-01…R-13 | R-14…R-25 | R-26…R-37 | **R-38** |

## Evidence tags

Used in every chapter. A statement without an `[IMPL]` tag is a specification, not a description of working software.

| Tag | Meaning |
|---|---|
| `[IMPL]` | Verified in the repository |
| `[DES]` | Designed in a `docs/*_DESIGN.md`; not implemented |
| `[PROP]` | Proposed by the chapter; not designed or built |
| `[EST]` | Calculated estimate; assumptions stated at point of use |
| `[OPEN]` | Requires a decision |

## Remaining chapters

| Ch. | Title | Inherits |
|---|---|---|
| 4 | Data Model | Ch. 1 OQ-08 (determines every foreign key), OQ-31/32/34/38/40/42, §27.1 schema obligations |
| 5 | AI/ML Architecture | OQ-04, OQ-05, OQ-22, OQ-23, OQ-39, Part B §16 contracts |
| 6 | Security & Compliance | OQ-02/03/06/07/14/18(confirmation)/21/24/25/35/37 |
| 7 | Infrastructure & Scale | Ch. 1 §12.5 deployment shape, OQ-33/36/41, §27.3 |

## Related documents

| Path | Role |
|---|---|
| `docs/ARCHITECTURE_DISCOVERY_REPORT.md` | Code-verified current state, 2026-07-31. The factual basis for every `[IMPL]` tag |
| `docs/PRODUCT_OVERVIEW.md` | Reader-facing narrative overview; superseded as a specification by Ch. 1 |
| `docs/*_DESIGN.md` | Five subsystem designs; the basis for `[DES]` tags |
