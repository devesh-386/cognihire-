# Appendix A — Decision Register (ED-01 … ED-84)

The authoritative flat index of every Engineering Decision / ADR across Chapters 1–7. The **chapter is the source of truth** for rationale, alternatives, and trade-offs; this table is for lookup, ownership, and dependency tracing.

**Status legend:** `Accepted` — decided and binding · `Accepted (built)` — decided *and* reflected in `[IMPL]` code today · `Open` — direction stated but the decision is still contested / pending validation · `Superseded` — replaced by a later ED.

**Owner legend (discipline, not a person — assign a name before implementation):** ARCH (architecture) · DATA · API (API/backend) · SEC (security) · ML (AI/ML) · INFRA (SRE/platform) · PROD (product) · COMP (compliance).

| ED | Decision (short) | Status | Owner | Ch. | Depends on | Related |
|---|---|---|---|---|---|---|
| ED-01 | Local model inference (Ollama `qwen2.5:7b`) not a hosted API | Accepted (built) | ML | 1 | — | ED-16, ED-81; tension w/ NFR-S3 |
| ED-02 | Verbatim substring grounding, no fuzzy matching | Accepted (built) | ML | 1 | — | ED-17, FR-2.2 |
| ED-03 | No composite score — enforced by type *absence*, not policy | Accepted (built) | ARCH | 1 | — | ED-32, ED-46 |
| ED-04 | No hire/no-hire training labels anywhere | Accepted (built) | ARCH | 1 | — | ED-14, ED-40 |
| ED-05 | Sealed union measurement results; `Unchecked` has no similarity field | Accepted (built) | ARCH | 1 | — | ED-53 |
| ED-06 | Training in Python; scoring/guards/explanation on-device in Dart | Accepted (built) | ML | 1 | — | Generalised by ED-18 |
| ED-07 | Isotonic calibration built, measured, and declined | Accepted (built) | ML | 1 | — | — |
| ED-08 | Deny-by-default RBAC in one table; own-vs-all as separate permissions | Accepted (built) | SEC | 1 | — | ED-54; R-04/R-64 |
| ED-09 | Per-session JSON files, atomic write-then-rename, not a DB (current) | Accepted (built) | DATA | 1 | — | Superseded at scale by ED-30 |
| ED-10 | Deterministic layered graph layout, not a force simulation | Accepted (built) | ARCH | 1 | — | — |
| ED-11 | Template-first question generation + banned-phrase linter | Accepted (built) | ML | 1 | — | ED-46 |
| ED-12 | Flutter — single codebase across desktop/web/mobile | Accepted (built) | ARCH | 1 | — | — |
| ED-13 | Event-source `InterviewSession`; log is authoritative, audit is a projection | Accepted | ARCH | 3 | ED-09→evolves | ED-21, ED-30, ED-35 |
| ED-14 🔴 | Evidence ⟂ Disposition — separate contexts, no join key; correlation human-only | Accepted | ARCH | 3 | ED-04 | ED-45, ED-62, ED-69, ED-76 |
| ED-15 | `TenantId` in Shared Kernel; unscoped queries inexpressible | Accepted | ARCH | 3 | — | ED-30, R-05/R-31 |
| ED-16 | Inference behind a topology-agnostic Anti-Corruption Layer | Accepted (built) | ML | 3 | ED-01 | ED-74, ED-48 |
| ED-17 | Grounding gate lives in the consuming context, never the AI context | Accepted (built) | ARCH | 3 | ED-02 | — |
| ED-18 | Measurement and adjudication are separate bounded contexts | Accepted | ARCH | 3 | ED-06 | — |
| ED-19 | Copy-on-write `RoleVersion`; sessions bind a version | Accepted | DATA | 3 | — | OQ-27, R-23 |
| ED-20 | Candidate transparency is a distinct projection, not the recruiter artifact | Accepted | API | 3 | — | OQ-30 |
| ED-21 | Single-writer lease per session; forward-only recovery | Accepted | ARCH | 3 | ED-13 | ED-47, R-22/R-30 |
| ED-22 | Transactional outbox for all domain events | Accepted | DATA | 3 | ED-13 | ED-35 |
| ED-23 | Enrolment optionality resolved by aggregate non-existence | Accepted | ARCH | 3 | — | OQ-18, R-17 |
| ED-24 | Notification content minimisation enforced by absent capability | Accepted | API | 3 | — | R-15 |
| ED-25 | Unify on the controller-delegating interview screen (`LiveInterviewScreen`) | Accepted | PROD | 3 | ED-13 | OQ-01, R-36 |
| ED-26 | WCAG 2.2 AA; typed interview path is a command, not a fallback | Accepted | PROD | 3 | — | OQ-19, R-16 |
| ED-27 | Hiring-manager approval as a requisition-scoped policy value object | Accepted | PROD | 3 | — | OQ-20/37 |
| ED-28 | Minimal shared kernel; `Claim`/verdicts/`Disposition` never shared | Accepted | ARCH | 3 | ED-14 | R-29 |
| ED-29 | Event-source only behavioural aggregates; master data state-stored | Accepted | DATA | 4 | ED-13 | — |
| ED-30 | Event store = Postgres tables; shared-schema + RLS + `tenant_id` tenancy | Accepted | DATA | 4 | ED-13, ED-15 | R-31/R-46 |
| ED-31 | Snapshots always fall back to full replay; never trusted w/o `state_hash` | Accepted | DATA | 4 | ED-13 | OQ-51 |
| ED-32 | Read-model DDL linter rejects score/rank/probability columns | Accepted | DATA | 4 | ED-03 | ED-46 |
| ED-33 | GDPR erasure = crypto-shred + tombstone, never event edit | Accepted | DATA | 4 | ED-13 | ED-57 |
| ED-34 | Separate optimistic-concurrency `version` from semantic `schema_version` | Accepted | DATA | 4 | — | — |
| ED-35 | Transactional outbox for reliable event→projection delivery | Accepted | DATA | 4 | ED-22 | — |
| ED-36 | Embedding upgrades via shadow re-embed, never mixed-model retrieval | Accepted | ML | 4 | — | OQ-55 |
| ED-37 | Redis is never the sole copy of anything | Accepted | INFRA | 4 | — | — |
| ED-38 | Event store append-only across all schema versions; upcast on read | Accepted | DATA | 4 | ED-13 | ED-50 |
| ED-39 | Derived stores rebuilt, not restored; backup covers only authoritative | Accepted | INFRA | 4 | ED-13 | ED-83 |
| ED-40 | Analytics: no outcome column, no candidate-level evidence, consent-gated | Accepted | DATA | 4 | ED-04, ED-14 | R-14/R-49 |
| ED-41 | REST + events + WS + SSE; gRPC reserved for inference; GraphQL rejected | Accepted | API | 5 | — | — |
| ED-42 | Idempotency-Key on all non-GET; two-layer with event-store PK | Accepted | API | 5 | ED-30 | — |
| ED-43 | `tenant_id` derived from token only; signed internal header | Accepted | SEC | 5 | ED-15 | R-51 |
| ED-44 | Commands return on durable append (202), not on projection | Accepted | API | 5 | ED-13 | — |
| ED-45 | CI asserts no schema/consumer bridges evidence↔disposition | Accepted | SEC | 5 | ED-14 | ED-62 |
| ED-46 | DTO vocabulary-ban linter (score/rank/probability/cross-ref) | Accepted | API | 5 | ED-03, ED-32 | — |
| ED-47 | WS reconnect = replay-from-sequence; state never socket-only | Accepted | API | 5 | ED-13, ED-21 | R-52 |
| ED-48 | External calls via ports; deterministic fallback only where correctness allows | Accepted | API | 5 | ED-16 | R-59 |
| ED-49 | One error envelope; `message` never sensitive; branch on `code` | Accepted | API | 5 | — | R-58/R-61 |
| ED-50 | URL-major + header-minor versioning; dual-run majors; events upcast | Accepted | API | 5 | ED-38 | OQ-62 |
| ED-51 | Rate limiting shapes load, never skips a safety step | Accepted | SEC | 5 | — | R-37/R-60 |
| ED-52 | Contract-first: OpenAPI/AsyncAPI source of truth; CI fails on drift | Accepted | API | 5 | — | ED-45/ED-46 |
| ED-53 | Zero-trust extends to the human subject (continuous identity verify) | Accepted (built) | SEC | 6 | ED-05 | R-37 |
| ED-54 | RBAC spine + ABAC edges; wire the built-but-unwired matrix (top priority) | Accepted | SEC | 6 | ED-08 | R-64, OQ-74 |
| ED-55 | Break-glass = MFA + four-eyes + time-boxed + audited + cannot bridge T3/T3' | Accepted | SEC | 6 | ED-14 | R-65, OQ-24 |
| ED-56 | No secret in source/image/config; CI secret scanner as permanent gate | Accepted | SEC | 6 | — | R-66 |
| ED-57 | Crypto-shred + tombstone for erasure (security view of ED-33) | Accepted | SEC | 6 | ED-33 | R-67, OQ-43 |
| ED-58 | Consent is structurally gating (path doesn't execute w/o it) | Accepted | COMP | 6 | — | R-69 |
| ED-59 | Periodic external anchoring of the chain head | Accepted | SEC | 6 | ED-13 | R-76, OQ-77/84 |
| ED-60 | AI-authored claim / score leak = security incident, not quality bug | Accepted | SEC | 6 | ED-02/ED-03 | R-70 |
| ED-61 | Deploy admits only signed + SBOM + model-digest-matched artefacts | Accepted | INFRA | 6 | — | ED-70, OQ-79 |
| ED-62 | ED-14 enforced at four layers (schema/contract/network/CI) | Accepted | SEC | 6 | ED-14, ED-45 | ED-69, ED-77 |
| ED-63 | EU AI Act oversight/transparency satisfied-by-design; autonomous scoring regresses compliance | Accepted | COMP | 6 | ED-03/ED-04 | R-73, OQ-81 |
| ED-64 | Evidence-integrity incidents forbid "quiet fix"; preserve + disclose | Accepted | SEC | 6 | ED-13 | R-73 |
| ED-65 | Product-guarantee regression tests are security tests; red build blocks release | Accepted | SEC | 6 | ED-45/ED-46 | ED-71 |
| ED-66 | Continuity may reduce availability, never relax an integrity/identity control | Accepted | INFRA | 6 | ED-51 | R-74, ED-80 |
| ED-67 | Security metrics from immutable logs; mismatch paired with coverage | Accepted | SEC | 6 | — | R-75 |
| ED-68 | MVP = one boring single-node box; K8s/mesh/fleet are T-SaaS-only | Accepted | INFRA | 7 | — | R-89, OQ-89 |
| ED-69 | Disposition gets its own K8s namespace + NetworkPolicy + node separation | Accepted | INFRA | 7 | ED-14, ED-62 | R-72 |
| ED-70 | Distroless, non-root, read-only-root, signed, SBOM'd images; fail-closed | Accepted | INFRA | 7 | ED-61 | — |
| ED-71 | Product-guarantee regression tests release-blocking in CI | Accepted | INFRA | 7 | ED-65 | R-78 |
| ED-72 | No real candidate PII/biometrics in any non-prod environment | Accepted | SEC | 7 | — | R-79 |
| ED-73 | One Helm chart, three tier value files | Accepted | INFRA | 7 | ED-68 | R-88 |
| ED-74 | Inference Gateway ACL lets AI infra evolve with no domain change; warm pool | Accepted | INFRA | 7 | ED-16 | R-55/R-80 |
| ED-75 | Voice infra deferred + provider-abstracted; local STT/TTS for air-gap | Accepted | INFRA | 7 | — | R-81, OQ-64 |
| ED-76 | Disposition DB physically separate even at T-MVP | Accepted | INFRA | 7 | ED-14 | R-82 |
| ED-77 | ED-14 network-deny + T2 egress allow-list are policy-as-code w/ tests | Accepted | SEC | 7 | ED-62 | R-72/R-71 |
| ED-78 | Integrity/durability/coverage SLOs are not error-budgeted | Accepted | INFRA | 7 | — | ED-66 |
| ED-79 | Every scaling step is additive (no rewrite) — discharges Ch1 scale rule | Accepted | ARCH | 7 | ED-13/ED-15/ED-16 | — |
| ED-80 | Chaos experiments assert a safety invariant, not just availability | Accepted | INFRA | 7 | ED-66 | R-84 |
| ED-81 | Local self-hosted inference as a structural cost + privacy advantage | Accepted (built) | INFRA | 7 | ED-01 | R-85, OQ-85/86 |
| ED-82 | Append-only, rebuild-not-rollback deploy discipline | Accepted | INFRA | 7 | ED-38/ED-39 | R-86 |
| ED-83 | DR restores only authoritative stores, rebuilds derived | Accepted | INFRA | 7 | ED-39 | R-87 |
| ED-84 | Infra security controls tier-invariant in intent; migration checklist verifies | Accepted | SEC | 7 | ED-62 | R-88 |

**The load-bearing five** (a violation of any is a product-identity failure, not a bug): **ED-03** (no score), **ED-04** (no outcome labels), **ED-13** (event-sourced authoritative record), **ED-14 🔴** (Evidence⟂Disposition), **ED-02/ED-17** (grounding). Every downstream ED that carries a 🔴 or references these exists to defend them.

**Next ID: ED-85.**
