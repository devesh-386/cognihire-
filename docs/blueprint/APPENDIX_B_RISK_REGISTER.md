# Appendix B — Risk Register (R-01 … R-89)

The authoritative flat index of every risk across Chapters 1–7. The **chapter is the source of truth** for full mitigation detail; this table is for triage and ownership.

**Status legend:** `Present` — the risk is realised in the codebase *today* · `Open` — a real future risk, not yet realised, mitigation designed · `Mitigated-by-design` — an architectural control neutralises it if implemented as specified · `Watch` — low-likelihood, monitored.

**Likelihood / Impact:** as stated in the source chapter. **Owner:** discipline (ARCH/DATA/API/SEC/ML/INFRA/PROD/COMP).

| R | Risk (short) | Likelihood | Impact | Owner | Status | Mitigation (short) |
|---|---|---|---|---|---|---|
| R-01 | Core value proposition unvalidated with a buyer | High | Critical | PROD | Open | 10 customer-discovery convos gate V1 |
| R-02 | Identity threshold uncalibrated | High | High | ML | Present | Tool refuses FAR/FRR <50 pairs/class; no figure quoted |
| R-03 | No liveness / anti-spoof detection | Medium | High | SEC | Present | State plainly; layered adaptive follow-ups; V2 passive liveness |
| R-04 | Auth is a test double, RBAC unwired | Certain | Critical | SEC | Present | Wire auth + RBAC before real tenants (→ R-64) |
| R-05 | No tenant key on any aggregate | Certain | High | ARCH | Present | ED-15 TenantId in Shared Kernel; migration §20.3 |
| R-06 | Regulatory classification assumed, not reviewed | Medium | High | COMP | Open | Legal review of AEDT/Art. 22/EU AI Act gates V1 |
| R-07 | Fabrication regression (a default in place of a failure) | Low | Critical | ML | Mitigated-by-design | Guard suite; 0 default-returning paths `[IMPL]` |
| R-08 | Saved audits have no integrity protection | Certain | High | SEC | Present | Extend hash chain / signature / server copy (OQ-06) |
| R-09 | Local 7B model quality inadequate | Medium | Medium | ML | Open | Eval harness; template-first; abstain |
| R-10 | Dead-code divergence (2 screens, unwired RBAC/prompts) | Certain | Medium | ARCH | Present | ED-25 unify; delete unwired subsystems |
| R-11 | Single key-person dependency | Medium | High | PROD | Present | Documentation (this blueprint); onboarding |
| R-12 | Adversarial candidate defeats the mechanism | Medium | Medium | PROD | Open | Detect-deter-document; adaptive follow-ups |
| R-13 | Scope creep toward a score, customer-driven | Medium | Critical | PROD | Open | ED-03/ED-46 make a score inexpressible; refuse |
| R-14 | Outcome labels reconstructible (analytics ⋈ evidence) | High | Critical | DATA | Mitigated-by-design | ED-40; disposition not a CDC source |
| R-15 | Notification content leaks verdicts | High | High | API | Mitigated-by-design | ED-24 content minimisation |
| R-16 | Voice-first without equal text path discriminates | Medium | Critical | PROD | Open | ED-26 typed path is first-class command |
| R-17 | Enrolment mandatory-vs-declinable invalidates consent | High | High | COMP | Present | ED-23 aggregate non-existence; OQ-18 |
| R-18 | Live monitoring reintroduces unrecorded judgment | Medium | High | PROD | Open | Telemetry→question selection, never a flag/score |
| R-19 | Invitation token is an unbound bearer credential | Medium | High | SEC | Open | Single-use `token_hash`; expiry; bind to candidate |
| R-20 | Multi-role disjointness test deleted not replaced | High | High | SEC | Open | Replace-not-delete rule; CI test |
| R-21 | Break-glass normalises into routine access | Medium | High | SEC | Open | ED-55 four-eyes + time-box + audit |
| R-22 | In-memory session state; a crash loses the interview | Certain | High | ARCH | Present | ED-13 + ED-21 externalised durable state |
| R-23 | Role definitions mutate, invalidating history | High | Medium | DATA | Open | ED-19 copy-on-write RoleVersion |
| R-24 | Cross-tenant existence disclosure via dup detection | Medium | Medium | SEC | Open | 404-not-403; tenant-scoped uniqueness |
| R-25 | Analytics `modality` encodes a disability signal | Medium | High | COMP | Open | Non-persistence rule; never reaches evidence/analytics |
| R-26 | Event-sourced sessions w/o snapshot policy → unbounded replay | Medium | High | DATA | Open | Snapshot every N events; replay time as SLI (OQ-33/51) |
| R-27 🔴 | No-join-key unenforceable if one process holds both creds | Medium | Critical | SEC | Mitigated-by-design | §21.5 three layers; CI check is durable one |
| R-28 | A context bypasses the Inference Gateway "just once" | Medium | High | ARCH | Open | Dependency-direction test; no model cred outside gateway |
| R-29 | Shared-kernel creep reunifies separated contexts | High | High | ARCH | Open | ED-28; SK additions need an ADR + size check |
| R-30 | Lease-service failure → duplicate/blocked appends | Medium | High | INFRA | Mitigated-by-design | Sequence PK makes dup safe; outage→suspension |
| R-31 | Admin/reporting query bypasses tenant scoping | Medium | Critical | SEC | Mitigated-by-design | ED-15 makes it inexpressible; same repos |
| R-32 | Projection drift (read model disagrees with stream) | Medium | High | DATA | Open | Rebuild-and-compare in CI |
| R-33 | Saga orchestrator becomes a distributed monolith | Medium | Medium | ARCH | Open | Choreography default; orchestrate only 3/4/6 |
| R-34 | TenantId migration collides w/ hard schema check | High | High | DATA | Open | §20.3 M1–M6 in order; M5-before-M3 orphans enrolments |
| R-35 | Event schema versioning neglected until a consumer breaks | High | Medium | DATA | Open | Tolerance rules; per-consumer contract tests |
| R-36 | ED-25 screen migration read as "voice production-ready" | Medium | Medium | PROD | Open | Name voice as stand-in in the migration ticket |
| R-37 🔴 | Capacity-driven skipped identity checks not recorded `Unchecked` | Low | Critical | SEC | Mitigated-by-design | Runtime authors the event; ED-51/ED-66 |
| R-38 | RBAC persistence specified but enforcement unwired | High | High | SEC | Present | Wire before real tenant; CI import check (→ R-64) |
| R-39 | Projection silently skips a poison event | High | High | DATA | Mitigated-by-design | Halt-and-alert per stream; dead-letter; never skip |
| R-40 | Un-reaped temp-upload bucket leaks PII | Medium | Medium | INFRA | Open | Monitored reaper cron; backlog alert |
| R-41 | Search index bypasses tenant RLS | High | High | SEC | Mitigated-by-design | RLS GUC on all search; cross-tenant→0 test |
| R-42 | Stale cached read model shown after update | Low | Low | API | Mitigated-by-design | Short TTL + event bust; never write-path |
| R-43 | GDPR erasure ignores an active legal hold | High | High | COMP | Mitigated-by-design | Erasure consults legal_hold first |
| R-44 | PII outside the encryption envelope is un-shreddable | High | High | SEC | Open | Scrubber; error minimisation; analytics ban |
| R-45 | Tenant delete is a two-system saga (no distributed txn) | Medium | Medium | INFRA | Open | Forward-recovery saga + reconciliation report |
| R-46 | Event-table write contention under burst | Medium | Medium | DATA | Open | Partitioning; per-stream PK; single-writer lease |
| R-47 | Platform-admin cross-tenant path is top attack target | Medium | High | SEC | Open | MFA + full audit + minimal scope |
| R-48 🔴 | Future feature requiring evidence⋈disposition correlation | — | High | ARCH | Open | Refuse at design time; §21.5 is the citation |
| R-49 🔴 | "Scores vs hiring success" dashboard = prohibited dataset | — | High | PROD | Open | Forbidden by ED-40; refuse |
| R-50 | Building an "edit event/audit" repair tool = a tamper tool | — | High | SEC | Mitigated-by-design | Never built; repairs touch only derived data |
| R-51 | Client forging tenant_id for cross-tenant access | — | High | SEC | Mitigated-by-design | ED-43 tenant-from-token, signed header |
| R-52 | Reconnect silently restarts interview, losing answers | — | High | API | Mitigated-by-design | ED-47 resume-from-sequence mandatory |
| R-53 | Voice failure drops/omits an answer | — | High | API | Mitigated-by-design | Fall back to text; never skip |
| R-54 | Sufficiency model (unvalidated) mistaken for validated | — | High | ML | Mitigated-by-design | `isValidatedOnRealData=false` surfaced in output |
| R-55 | Cold inference gateway hangs a live session 40s | — | Medium | INFRA | Mitigated-by-design | warmUp() precondition; cold=503 |
| R-56 | SSRF via URL in résumé/LLM output | — | High | SEC | Mitigated-by-design | Outbound URLs from config only |
| R-57 | Refresh-token replay | — | High | SEC | Mitigated-by-design | One-time rotation + reuse-detection revokes family |
| R-58 | Cross-tenant existence oracle via 403-vs-404 | — | Medium | SEC | Mitigated-by-design | Return 404 where existence is tenant-sensitive |
| R-59 | Circuit breaker fails open past an identity check | — | High | SEC | Mitigated-by-design | No fabricating fallback; pause instead |
| R-60 | Rate-limit shedding skips a safety step | — | High | SEC | Mitigated-by-design | ED-51 |
| R-61 | Debug/verbose logging leaks answers/claims | — | High | SEC | Mitigated-by-design | Mandatory scrubber; debug can't bypass |
| R-62 | Contract drift reopens a closed guarantee | — | High | API | Mitigated-by-design | CI contract tests + linters (ED-45/46) |
| R-63 | Stolen recruiter token → tenant PII read ≤15 min | — | Medium | SEC | Open | Short JWT + rotation + anomaly detection |
| R-64 | RBAC matrix built but unwired — app enforces nothing | Certain | Critical | SEC | **Present** | Wire PermissionResolver into every handler |
| R-65 | Break-glass abused by insider | — | High | SEC | Mitigated-by-design | Four-eyes + MFA + immutable audit + ED-14 limit |
| R-66 | Secret-manager outage stalls startup | — | Medium | INFRA | Open | Short-cached leases; degrade w/o disabling safety |
| R-67 | PII outside encryption envelope un-shreddable (sec view) | — | High | SEC | Open | Scrubber, error minimisation, analytics ban |
| R-68 | Biometric leakage (irreplaceable, special-category) | — | High | SEC | Mitigated-by-design | Crypto-isolation + minimal retention + strict access |
| R-69 | Biometric path runs without explicit consent | — | High | COMP | Mitigated-by-design | Capture code unreachable w/o consent (ED-58) |
| R-70 | Prompt injection suppresses an integrity observation | — | High | SEC | Mitigated-by-design | Runtime authors integrity events, not the model |
| R-71 | Poisoned dep in parse/embed path exfiltrates PII | — | High | SEC | Open | SBOM + scan + no egress except inference port |
| R-72 | Misconfigured SG opens evidence↔disposition route | — | High | SEC | Mitigated-by-design | Policy-as-code deny test + separate credential |
| R-73 | Autonomous scoring feature → product + compliance regression | — | High | COMP | Open | ED-63; refuse; guarded by ED-45/46 |
| R-74 | "Skip identity verify to stay up" degraded toggle | — | Critical | INFRA | Mitigated-by-design | Forbidden (ED-66); degrade = pause + record |
| R-75 | Mismatch-rate KPI incentivises skipping checks | — | Medium | SEC | Mitigated-by-design | Pair w/ coverage; unrecorded check impossible (ED-67) |
| R-76 | Full-file rewrite of the chain (evident, not proof) | — | Medium | SEC | Open | External anchoring (ED-59) + access controls |
| R-77 | Air-gapped anchoring internal-only (weaker) | — | Medium | SEC | Open | Documented; internal anchor + media checkpoints |
| R-78 | Hotfix bypasses guardrail gate → leak | — | High | INFRA | Mitigated-by-design | Un-skippable guardrails; same gate for hotfix |
| R-79 | Real PII/biometrics copied to staging/preview | — | High | SEC | Mitigated-by-design | Synthetic/de-identified only (ED-72) |
| R-80 | GPU shortfall stalls interviews under burst | — | Medium | INFRA | Open | Queue+backpressure (slow not skip); autoscale |
| R-81 | Cloud voice creates a PII-egress channel | — | Medium | INFRA | Open | Voice deferred; local STT/TTS for air-gap |
| R-82 | MVP co-locates disposition DB w/ shared creds | — | High | INFRA | Mitigated-by-design | ED-76 separate DB + credential even co-located |
| R-83 | Connection pooler leaks a tenant RLS GUC | — | High | DATA | Open | SET LOCAL per-txn / session-pool; no-inherit test |
| R-84 | HA retry proceeds past a failed identity check | — | Critical | INFRA | Mitigated-by-design | ED-80; retries keep Idempotency-Key, no bypass |
| R-85 | GPU idle cost at low scale | — | Low | INFRA | Open | CPU inference at T-MVP; warm-pool sized to peak |
| R-86 | Out-of-order/destructive migration orphans data | — | High | DATA | Open | Ordered-migration gate + post-deploy verifyIntegrity |
| R-87 | Residency-violating regional failover | — | High | COMP | Open | DR standby within each residency region (ED-83) |
| R-88 | A security control silently dropped in tier migration | — | High | SEC | Open | Migration checklist + policy-as-code tests |
| R-89 | Two infra shapes (Compose + K8s) drift | — | Medium | INFRA | Open | One Helm chart + mirroring Compose; identical domain code |

## Risk heatmap (Impact × realised-today)

```
                 IMPACT →   Medium            High                       Critical
 Present today   ┌────────┬─────────────────┬──────────────────────────┬─────────────────────────┐
 (realised)      │  ---   │ R-02 R-08 R-10  │ R-05 R-17 R-22           │ R-04  R-64              │
                 │        │                 │                          │ (auth/RBAC unwired)     │
                 ├────────┼─────────────────┼──────────────────────────┼─────────────────────────┤
 Open / future   │ many   │ R-19 R-20 R-21  │ R-06 R-13(crit) R-44     │ R-48🔴 R-49🔴 R-73      │
 (not realised)  │ (ops)  │ R-23 R-32 R-34… │ R-47 R-71 R-76 R-83 R-86 │ R-74 R-84 (safety)      │
                 └────────┴─────────────────┴──────────────────────────┴─────────────────────────┘
 Mitigated-by-design (neutralised if built as specified): R-07 R-14 R-15 R-27🔴 R-30 R-31 R-37🔴
   R-39 R-41 R-42 R-43 R-50 R-51 R-52 R-53 R-54 R-55 R-56 R-57 R-58 R-59 R-60 R-61 R-62 R-65 R-68
   R-69 R-70 R-72 R-75 R-78 R-79 R-82 R-84
```

**Top of the register right now:** **R-64 / R-04** (Critical, *present today*) — the RBAC/permission matrix is built and tested but **unwired**, so the running app enforces nothing. This is the single most important thing to fix before any real tenant, and it anchors Sprint 1 of the [Implementation Roadmap](IMPLEMENTATION_ROADMAP.md).

**Next ID: R-90.**
