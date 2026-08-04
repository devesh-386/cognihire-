# Appendix C — Open Question Register (OQ-01 … OQ-96)

Every unresolved decision across Chapters 1–7. The **chapter is the source of truth** for full context; this table adds a **priority**, the **chapters/work it blocks**, and the **current default** (the "if nobody decides, this is what happens" position each chapter stated — usually the *undesirable* default, which is the point).

**Priority:** **P0** — blocks V1 / a first real customer; decide now. **P1** — blocks a specific chapter's implementation; decide before that workstream. **P2** — scale/enterprise concern; decide before the relevant tier. **P3** — refinement.

**Owner:** discipline (ARCH/DATA/API/SEC/ML/INFRA/PROD/COMP).

| OQ | Question (short) | Priority | Owner | Blocks | Current default / recommendation |
|---|---|---|---|---|---|
| OQ-08 | What does "organisation" mean — org-owned vs candidate-owned data? | **P0** | ARCH | every FK, the whole tenancy shape, tenant-key migration | **Decide before any tenant-key migration** — the most consequential OQ in the blueprint |
| OQ-01 | Delete `LiveInterviewScreen` or make it the interview? | **P0** | PROD | all interview investment; MVP demo path | **Resolved on architecture grounds by ED-25** (keep the controller-delegating screen); sequencing is a delivery call |
| OQ-04 | Wire answer scoring for real, or formally delete it? | **P0** | ML | two live-prompt rules run on a hardcoded constant | **Delete the concept** (aligns w/ no-score); a rule the system can't satisfy shouldn't ship |
| OQ-14 | Retention & deletion policy for biometrics + interview data | **P0** | COMP | V1-11, K16/K17, BIPA exposure | Highest-severity legal gap; **define a retention policy before storing biometrics at scale** |
| OQ-06 | Tamper-proofing for saved audits (chain / signature / server copy) | **P0** | SEC | R-08 | Extend the hash chain to saved audits + external anchor (ED-59) |
| OQ-02 | Wire existing RBAC as-is, or does a real backend change roles? | **P1** | SEC | V1-02, all role work | Wire it (→ R-64), but reconcile the 2-role model §6 calls wrong for V1 |
| OQ-03 | What replaces `InMemoryAuthStore`? | **P1** | SEC | V1-01 and everything downstream | IdP-delegated (Ch5 §14); no local password store |
| OQ-05 | Keep LLM report summarisation, given deterministic design? | P2 | ML | an unwired prompt on disk | Delete the unwired prompt or wire it deliberately |
| OQ-07 | Is liveness in scope, or is "we don't defend against this" the stance? | **P1** | SEC | R-03 | State the honest stance in-product; evaluate passive liveness in V2 |
| OQ-09 | May a candidate be interviewed >once for a role, tracked? | P1 | DATA | audit identity / uniqueness | Track within-tenant (see OQ-38) |
| OQ-10 | Are completed audits immutable or annotatable? | P1 | ARCH | V1-12, FR-5.11 | Immutable + separate annotation layer |
| OQ-11 | May a recruiter edit vs annotate claims; may a candidate contest? | P1 | PROD | reviewer model; appeal path | Annotate-only; append-only contest record |
| OQ-12 | May an audit be regenerated; retain prior versions? | P1 | DATA | versioning/retention | Regenerate as a new version; retain prior (ED-13 replay) |
| OQ-13 | Must interviews be resumable after interruption? | **P0** | ARCH | NFR-R4; session externalisation | **Yes** — resolved by ED-13 + ED-21 (durable state) |
| OQ-15 | Is single-tenant local-only a permanent mode or a stepping stone? | P1 | INFRA | JsonFileAuditStore lifecycle; §12.5 | Stepping stone; preserve as T-ENT/air-gap (Ch7) |
| OQ-16 | Does environment/second-screen detection enter the product? | P2 | PROD | R-03 layering | Explicitly cut for V1 (the ref impl fabricated violations) |
| OQ-17 | Escalation path when identity verification fails mid-session | **P0** | PROD | interview state machine | Answered behaviorally in Ch2 §12.2; formalise the SM |
| OQ-18 | Enrolment mandatory vs declinable (consent validity) | **P0** | COMP | whole candidate journey; GDPR | ED-23 aggregate non-existence; declining ⇒ no evidential path |
| OQ-19 | Accessibility conformance target + first audit date | P1 | PROD | P-1, R-16 | ED-26 WCAG 2.2 AA; schedule first audit |
| OQ-20 | Is HM approval a required gate or advisory? | P1 | PROD | disposition SM | ED-27 requisition-scoped policy value |
| OQ-21 | Custom roles vs fixed set? | P2 | SEC | RBAC scale | Fixed for V1; custom at enterprise |
| OQ-22 | Cross-session same-candidate memory permitted? | P1 | ML | repeat-candidate; §9.6 prohibition | Needs an explicit reasoned line; default off |
| OQ-23 | Does a face embedding expire? | P1 | ML | re-enrolment/retention | Add expiry + re-enrolment to avoid stale mismatches |
| OQ-24 | Exact break-glass protocol | P1 | SEC | Platform Admin journey, PE-08 | ED-55 defines shape; fill approvers/time-box/wording |
| OQ-25 | Workforce erasure vs audit integrity (pseudonymise vs delete) | P1 | COMP | admin audit design | Pseudonymise the actor, keep the chain (crypto-shred PII) |
| OQ-26 | Is the event log or the compiled audit authoritative? | **P0** | ARCH | recovery, regeneration | **Event log** — resolved by ED-13 |
| OQ-27 | Role definitions immutable or copy-on-write? | P1 | DATA | historical coverage validity | ED-19 copy-on-write |
| OQ-28 | Can a recruiter delete a completed audit; what survives? | P1 | DATA | tamper-evidence | No hard delete; crypto-shred + tombstone only |
| OQ-29 | Follow-up session: new audit or extend existing? | P1 | DATA | Superseded state, OQ-12 | New version referencing prior |
| OQ-30 | Transparency view = recruiter artifact or projection? | P1 | API | contest flow | ED-20 distinct projection |
| OQ-31 | Is `ClaimSet` versioned on candidate edit; is history evidence? | P1 | DATA | candidate transparency | Version + keep edit history as provenance |
| OQ-32 | Telemetry classification in BC-05 or a separate Integrity context? | P2 | ARCH | BC-05 scope | Stays in BC-05 for V1 |
| OQ-33 | Snapshot cadence + retention for event-sourced sessions | P1 | DATA | ED-13 replay cost (R-26) | Snapshot every N events; measure replay as SLI (=OQ-51) |
| OQ-34 | Reviewer annotations in BC-07 or a separate context? | P2 | ARCH | AG-13 placement | Separate annotation context (keeps evidence immutable) |
| OQ-35 | Retention-purge saga orchestrator + per-context ack contract | P1 | COMP | SAGA-3 completeness | BC-12; define the ack contract |
| OQ-36 | Does BC-13 consume domain events directly or a sanitised stream? | P2 | DATA | CR-5 enforceability | Sanitised stream (makes the both-topics ban structural) |
| OQ-37 | Escalation when a gated requisition's approver is unavailable | P1 | PROD | ED-27 | Define a delegate/timeout, else teams work around it |
| OQ-38 | Is `CandidateRef` stable across requisitions in a tenant? | P1 | DATA | repeat-candidate, OQ-09 | Stable within tenant (a decision, not an accident) |
| OQ-39 | Does BC-08 persist `SufficiencyEvaluation` or compute on demand? | **P1** | ML | AG-14 lifecycle | Compute-on-demand preferred; persisting is the §17.5 shape — decide carefully |
| OQ-40 | Locale/language: property of RoleVersion or InterviewSession? | P2 | DATA | multilingual | Decide before either becomes a schema change |
| OQ-41 | Is the event bus tenant-partitioned; effect on per-aggregate ordering? | P2 | INFRA | §20.4, DE-5 | Verify partitioning preserves per-stream order |
| OQ-42 | Which context owns `Modality`, given it must never reach evidence? | P1 | ARCH | ED-26, R-25 | BC-05 transiently + explicit non-persistence rule |
| OQ-43 | Crypto-shred granularity: per-tenant vs per-subject sub-keys | P1 | SEC | candidate-level erasure | Per-subject sub-keys for granular erasure |
| OQ-44 | Is audio/video captured at all? | **P1** | PROD | §12 media class, voice | Default text+telemetry-first (Ch2); confirm before building media |
| OQ-45 | When does search move Postgres FTS → OpenSearch? | P2 | DATA | search latency | On measured FTS latency breach |
| OQ-46 | When does Organization:Tenant become >1:1? | P2 | ARCH | multi-org tenants | 1:1 for V1 |
| OQ-47 | Enterprise: promote RLS → schema/DB-per-tenant? | P2 | INFRA | isolation tier | RLS for T-SaaS; DB-per-tenant at T-ENT |
| OQ-48 | Cross-tenant users (recruiter serving multiple orgs)? | P2 | SEC | user model | One tenant per user for V1 |
| OQ-49 | Credential storage: fully IdP-delegated vs local fallback? | P1 | SEC | auth model | Fully IdP-delegated |
| OQ-50 | Are inference records evidence or ops telemetry? | P1 | ML | retention of inference logs | Ops telemetry; short retention |
| OQ-51 | Snapshot cadence (every N events / T seconds)? | P1 | DATA | rehydration latency | Same decision as OQ-33 |
| OQ-52 | Event-store migration trigger Postgres → dedicated log | P2 | DATA | throughput | On measured contention (R-46) |
| OQ-53 | Hot-window duration before archival per residency region | P2 | DATA | archival | Per-region policy |
| OQ-54 | Should correlation/causation IDs be inside the hash boundary? | P1 | SEC | provenance strength | Decide before finalising the envelope |
| OQ-55 | Re-embed proactively on model change or lazily? | P2 | ML | embedding upgrades | Shadow re-embed proactively (ED-36) |
| OQ-56 | Migration tool for master data (Flyway/sqitch)? | P2 | DATA | migrations | Pick one before first migration |
| OQ-57 | RPO/RTO targets tied to Ch1 availability NFR | P1 | INFRA | DR design | See §19 targets; ratify |
| OQ-58 | Shard key + trigger beyond a single regional primary | P2 | DATA | scale | Shard by tenant_id when a primary is exceeded |
| OQ-59 | Calendar/scheduling integration in V1? | P2 | API | scheduling | Manual invite links for V1 |
| OQ-60 | Service/workload identity scheme (SPIFFE vs lighter) | P1 | SEC | service auth | Decide with the T-SaaS mesh |
| OQ-61 | Instant token revocation (jti denylist) at V1? | P1 | SEC | admin step-down | 15-min expiry sufficient unless step-up needed |
| OQ-62 | Deprecation window length for a retired API major | P2 | API | versioning | ≥2 quarters |
| OQ-63 | Billing/payment provider + any V1 billing API | P2 | PROD | BC-13 | Deferred; provider-hosted checkout only |
| OQ-64 | STT/TTS provider — local vs cloud | P1 | INFRA | voice, air-gap | Local for air-gap; cloud only w/ egress governance |
| OQ-65 | Gateway product — managed vs self-hosted | P2 | INFRA | edge | Managed for T-SaaS; nginx/Caddy for T-MVP |
| OQ-66 | Public/partner API in V1 or internal-only? | P2 | API | integration surface | Internal-only for V1 |
| OQ-67 | Signed webhooks to customers + retry policy | P2 | API | integrations | Signed + retry when webhooks added |
| OQ-68 | Bulk endpoints partial-failure contract | P2 | API | bulk import | Define per-item result semantics |
| OQ-69 | Long-running export: sync-poll vs async callback | P2 | API | reports | 202 + poll for V1 |
| OQ-70 | Field-level encryption for biometrics beyond TLS | P1 | SEC | biometric transit | Double-envelope for biometrics |
| OQ-71 | Service/workload identity scheme (SPIFFE/SPIRE?) | P1 | INFRA | mesh | With T-SaaS |
| OQ-72 | Passkeys mandated for admin tiers in V1? | P1 | SEC | admin auth | Prefer; mandate for T3/T4 |
| OQ-73 | Instant token revocation needed at V1? | P1 | SEC | revocation | 15-min expiry unless required |
| OQ-74 | Externalise policy to OPA/Cedar vs in-process Dart resolver | P1 | SEC | authZ engine | In-process resolver for V1 (already tested) |
| OQ-75 | Double-envelope encryption for biometrics in transit | P1 | SEC | biometric transit | Yes (=OQ-70) |
| OQ-76 | Non-biometric identity fallback when candidate declines face | **P1** | COMP | a11y + consent | Define an alternative assurance path |
| OQ-77 | External anchoring mechanism (TSA vs transparency log) | P1 | SEC | tamper-proofing | RFC 3161 TSA or transparency log |
| OQ-78 | If a remote inference pool is added, what gates PII-egress? | P1 | SEC | remote inference | No-PII-egress + untrusted-output gate |
| OQ-79 | Target SLSA level for build provenance | P2 | INFRA | supply chain | Aim SLSA 3 |
| OQ-80 | Bias-audit process (LL144) given no composite score | P1 | COMP | compliance | Define who/what/how it's surfaced |
| OQ-81 | Certification timeline vs the hard EU AI Act floor | **P0** | COMP | EU market operation | **EU AI Act floor precedes certification** — confront on the roadmap |
| OQ-82 | DPAs + sub-processor governance | P1 | COMP | vendor governance | Establish before onboarding a tenant |
| OQ-83 | Candidate-facing transparency at consent time | P1 | COMP | consent UX | Disclose posture at consent |
| OQ-84 | Air-gapped external-anchoring substitute | P2 | SEC | air-gap integrity | Internal notary / signed media checkpoints (R-77) |
| OQ-85 | Self-host vs managed GPU inference (T-SaaS) | P2 | INFRA | AI infra cost | Evaluate at T-SaaS |
| OQ-86 | Owned vs rented GPU capacity | P2 | INFRA | cost model | Rent first, own at sustained scale |
| OQ-87 | Zero-RPO CP event store vs instant cross-region failover | P1 | INFRA | DR topology | Accept small regional RPO or pay sync latency — pick |
| OQ-88 | Managed Kubernetes provider / cloud selection | P2 | INFRA | platform | With T-SaaS |
| OQ-89 | When does T-MVP graduate to T-SaaS (thresholds)? | P1 | INFRA | scaling plan | Define tenant/load trigger |
| OQ-90 | Multi-region active-active vs active-passive | P2 | INFRA | topology | Active-passive per residency zone first |
| OQ-91 | Managed vs self-hosted datastores per tier | P2 | INFRA | ops | Managed T-SaaS; self-host T-ENT/air-gap |
| OQ-92 | Observability stack choice | P2 | INFRA | monitoring | OpenTelemetry + chosen backends |
| OQ-93 | GitOps tool + config-repo structure | P2 | INFRA | deploy | Argo or Flux |
| OQ-94 | BYOK/customer-managed keys for T-ENT | P2 | SEC | enterprise keys | Support BYOK at T-ENT |
| OQ-95 | Cost ceiling / unit economics per interview | P1 | PROD | right-sizing | Set a per-interview target |
| OQ-96 | On-prem hardware reference spec for T-ENT/air-gap | P2 | INFRA | enterprise | Publish a reference spec |

## Priority summary

**P0 — decide before V1 / first customer (9):** OQ-08 (org meaning — decide first), OQ-01 (interview screen — resolved by ED-25), OQ-04 (delete answer scoring), OQ-06 (audit tamper-proofing), OQ-13 (resumability — resolved by ED-13/21), OQ-14 (biometric retention), OQ-17 (identity-fail escalation), OQ-18 (enrolment consent), OQ-26 (authoritative record — resolved by ED-13), OQ-81 (EU AI Act floor).

Several P0s are already **resolved on architectural grounds** (OQ-01, OQ-13, OQ-26) and just need a delivery decision; the genuinely-open P0s are **OQ-08, OQ-04, OQ-06, OQ-14, OQ-17, OQ-18, OQ-81** — the pre-implementation decision gate.

**Next ID: OQ-97.**
