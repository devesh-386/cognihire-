# CogniHire — Engineering Blueprint

> **Start with the [Architecture Handbook](HANDBOOK.md)** (canonical entry point) and [Chapter 0 — Architecture Overview](CHAPTER_00_ARCHITECTURE_OVERVIEW.md) (the first document every engineer reads). This README is the detailed chapter/series index behind them.
>
> Working instruments: [Decision Register](APPENDIX_A_DECISION_REGISTER.md) · [Risk Register](APPENDIX_B_RISK_REGISTER.md) · [Open Questions](APPENDIX_C_OPEN_QUESTIONS.md) · [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md) · [Validation Checklist](ARCHITECTURE_VALIDATION_CHECKLIST.md)

Chapters are cumulative and immutable once issued. A later chapter may **resolve** an earlier open question but may not silently contradict an earlier decision; contradictions are documented and resolved explicitly.

## Chapters

| Ch. | Title | File | Covers |
|---|---|---|---|
| 1 | Product Vision & Scope | [CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md](CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md) | Vision, goals, KPIs, principles, stakeholders, scope, FR/NFR, constraints, assumptions, risks, boundaries, roadmap, ED-01…ED-12, OQ-01…OQ-17, R-01…R-13 |
| 2 | User Personas & Complete User Journey | [CHAPTER_02_PERSONAS_AND_USER_JOURNEY.md](CHAPTER_02_PERSONAS_AND_USER_JOURNEY.md) | 17 actors, 5 personas, 5 human journeys, AI internal journey, state machines, edge cases, permissions, notifications, analytics, OQ-18…OQ-30, R-14…R-25 |
| 3 | DDD, Bounded Contexts & System Architecture | Part A · Part B · Part C (below) | Domains, contexts, aggregates, events, CQRS, AI architecture, consistency, tenancy, security, scale, ED-13…ED-28, OQ-31…OQ-42, R-26…R-37 |
| 4 | Data Architecture, Database Design, Event Store & Persistence Model | Part A · Part B (below) | Persistence strategy, DB philosophy, multi-tenant data model, complete ER model, event store, event schemas, read models, projections, object/vector/search storage, caching, lifecycle, schema evolution, backup/DR, performance, security, privacy (physical ED-14 enforcement), analytics, data quality, ED-29…ED-40, OQ-43…OQ-58, R-38…R-50 |
| 5 | API Architecture, Service Contracts & Integration Design | Part A · Part B (below) | API philosophy, gateway, service catalog (16 services), REST/commands/queries, DTOs, event contracts, WebSocket, voice, AI contracts, external integrations, auth/authz flows, error model, versioning, rate limiting, OWASP API security, observability, testing (contract-layer ED-14 enforcement), ED-41…ED-52, OQ-59…OQ-70, R-51…R-62 |
| 6 | Security, Privacy, Compliance & Trust Architecture | Part A · Part B (below) | Security philosophy, threat model (assets/actors/attackers/trust zones T0–T4+T3'), zero trust, authN/authZ, secrets, encryption + key hierarchy + crypto-shred, privacy, consent, audit + tamper detection, AI trust, supply chain, API security, infra security requirements, compliance (GDPR/ISO/SOC2/EU AI Act/residency), abuse cases, incident response, security testing, business continuity, security metrics, ED-53…ED-67, OQ-71…OQ-83, R-63…R-76 |
| 7 | Infrastructure, Cloud Architecture, Scalability, DevOps & Operations | Part A · Part B (below) | Three deployment tiers (MVP / Production SaaS / Enterprise+air-gap), deployment topology, cloud architecture, Kubernetes, containers, CI/CD, environments, IaC/GitOps, AI + voice + storage infrastructure, networking, observability + SLOs, performance, scalability (1→10M interviews with calculations), reliability + chaos, cost, operations, DR, infra-security carry-forward, ED-68…ED-84, OQ-84…OQ-96, R-77…R-89 |

### Chapter 3 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md](CHAPTER_03_PART_A_DOMAINS_AND_CONTEXTS.md) | 1–5: executive summary, 16 domains, classification, 14 bounded contexts, context map |
| B | [CHAPTER_03_PART_B_TACTICAL_DESIGN.md](CHAPTER_03_PART_B_TACTICAL_DESIGN.md) | 6–16: aggregates, entities, value objects, domain/application services, repositories, events, commands, queries, event storming, AI architecture |
| C | [CHAPTER_03_PART_C_ARCHITECTURE_DECISIONS.md](CHAPTER_03_PART_C_ARCHITECTURE_DECISIONS.md) | 17–27: communication, consistency, transactions, multi-tenancy, security, scalability, failure, ADRs, OQ, risks, engineering notes |

### Chapter 5 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_05_PART_A_SERVICES_AND_CONTRACTS.md](CHAPTER_05_PART_A_SERVICES_AND_CONTRACTS.md) | 1–12: executive summary, API philosophy, gateway, service catalog, REST APIs, commands, queries, DTOs, event contracts, WebSocket, voice, AI contracts |
| B | [CHAPTER_05_PART_B_INTEGRATION_SECURITY_AND_DECISIONS.md](CHAPTER_05_PART_B_INTEGRATION_SECURITY_AND_DECISIONS.md) | 13–24: external integrations, auth/authz flows, error model, versioning, rate limiting, security (OWASP API Top 10), observability, testing, OQ, risks, engineering decisions, engineering notes |

### Chapter 6 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_06_PART_A_THREAT_MODEL_AND_TRUST.md](CHAPTER_06_PART_A_THREAT_MODEL_AND_TRUST.md) | 1–11: executive summary, threat model, zero trust, authentication, authorization, secrets management, encryption, privacy, consent, audit, AI trust |
| B | [CHAPTER_06_PART_B_COMPLIANCE_AND_OPERATIONS.md](CHAPTER_06_PART_B_COMPLIANCE_AND_OPERATIONS.md) | 12–24: supply chain, API security, infra security requirements, compliance, abuse cases, incident response, security testing, business continuity, security metrics, OQ, risks, engineering decisions, engineering notes |

### Chapter 7 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_07_PART_A_TOPOLOGY_AND_PLATFORM.md](CHAPTER_07_PART_A_TOPOLOGY_AND_PLATFORM.md) | 1–12: executive summary, deployment topology (3 tiers), cloud architecture, Kubernetes, containers, CI/CD, environments, IaC, AI infrastructure, voice infrastructure, storage infrastructure, networking |
| B | [CHAPTER_07_PART_B_SCALE_RELIABILITY_AND_OPERATIONS.md](CHAPTER_07_PART_B_SCALE_RELIABILITY_AND_OPERATIONS.md) | 13–24: observability + SLOs, performance, scalability (with calculations), reliability + chaos, cost, operations, disaster recovery, infra-security carry-forward, OQ, risks, engineering decisions, engineering notes |

### Chapter 4 parts

| Part | File | Request sections |
|---|---|---|
| A | [CHAPTER_04_PART_A_DATA_MODEL_AND_EVENT_STORE.md](CHAPTER_04_PART_A_DATA_MODEL_AND_EVENT_STORE.md) | 1–11: executive summary, persistence strategy, DB philosophy, multi-tenant data model, complete ER model, Mermaid ER diagram, aggregate persistence, event store, event schemas, read models, projection architecture |
| B | [CHAPTER_04_PART_B_STORAGE_PRIVACY_AND_DECISIONS.md](CHAPTER_04_PART_B_STORAGE_PRIVACY_AND_DECISIONS.md) | 12–27: object/vector/search storage, caching, lifecycle, schema evolution, backup/DR, performance, security, privacy (physical ED-14 enforcement), analytics data model, data quality, risks, open questions, engineering decisions, engineering notes |

## Series continuity

| Series | Ch. 1 | Ch. 2 | Ch. 3 | Ch. 4 | Ch. 5 | Ch. 6 | Ch. 7 | Next chapter starts at |
|---|---|---|---|---|---|---|---|---|
| Engineering Decisions / ADRs | ED-01…ED-12 | — | ED-13…ED-28 | ED-29…ED-40 | ED-41…ED-52 | ED-53…ED-67 | ED-68…ED-84 | **ED-85** |
| Open Questions | OQ-01…OQ-17 | OQ-18…OQ-30 | OQ-31…OQ-42 | OQ-43…OQ-58 | OQ-59…OQ-70 | OQ-71…OQ-83 | OQ-84…OQ-96 | **OQ-97** |
| Risks | R-01…R-13 | R-14…R-25 | R-26…R-37 | R-38…R-50 | R-51…R-62 | R-63…R-76 | R-77…R-89 | **R-90** |

## Evidence tags

Used in every chapter. A statement without an `[IMPL]` tag is a specification, not a description of working software.

| Tag | Meaning |
|---|---|
| `[IMPL]` | Verified in the repository |
| `[DES]` | Designed in a `docs/*_DESIGN.md`; not implemented |
| `[PROP]` | Proposed by the chapter; not designed or built |
| `[EST]` | Calculated estimate; assumptions stated at point of use |
| `[OPEN]` | Requires a decision |

## Status

Chapters 1–7 are complete — the system is fully specified from product vision through production operations. The core blueprint is closed. Any further chapters (e.g. a dedicated AI/ML training-and-evaluation chapter, or a QA/test-strategy chapter) would be additive and continue the series from **ED-85 / OQ-97 / R-90**.

Open Questions accumulated across all chapters (OQ-01…OQ-96) are the live backlog of decisions to make before or during implementation; the highest-priority carried risk is **R-64 (Critical)** — the RBAC/permission matrix is built and tested but **unwired** in the running app.

## Related documents

| Path | Role |
|---|---|
| `docs/ARCHITECTURE_DISCOVERY_REPORT.md` | Code-verified current state, 2026-07-31. The factual basis for every `[IMPL]` tag |
| `docs/PRODUCT_OVERVIEW.md` | Reader-facing narrative overview; superseded as a specification by Ch. 1 |
| `docs/*_DESIGN.md` | Five subsystem designs; the basis for `[DES]` tags |
