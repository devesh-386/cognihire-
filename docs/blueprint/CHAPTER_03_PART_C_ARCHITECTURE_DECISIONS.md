# CogniHire — Engineering Blueprint
# Chapter 3, Part C — Cross-Cutting Architecture & Decision Records
## Communication · Consistency · Transactions · Multi-Tenancy · Security · Scale · Failure · ADRs · OQ · Risks · Notes

| Field | Value |
|---|---|
| Document | Chapter 3, Part C of 3 |
| Prerequisites | **Part A** (contexts) · **Part B** (tactical design) |
| Immutable sources | Chapter 1, Chapter 2 |
| Covers | Request sections 17 – 27 |
| Scope exclusion | **Not infrastructure. Not deployment.** Runtime placement, hosting, and topology are Ch. 7 |

---

## 17. Service Communication

### 17.1 Selection rule

> **Synchronous when the caller cannot proceed without the answer and the answer is cheap. Asynchronous otherwise. Streaming only where partial output has standalone value. Never synchronous across a bounded-context boundary that a saga can span.**

### 17.2 Mechanism per interaction

| # | Interaction | Mechanism | Justification | Rejected alternative |
|---|---|---|---|---|
| 1 | Client → application services | **REST/JSON** | Commands are request/response with typed failures; caching, proxies, and debugging are commodity | gRPC — binary framing buys nothing for a UI-driven command surface and costs debuggability |
| 2 | Cross-context integration | **Events over a bus** | Contexts must not know each other's availability. `AuditSealed` has 5 consumers; a synchronous fan-out couples compilation latency to notification uptime | Synchronous orchestration — creates a distributed monolith (R-33) |
| 3 | Turn planning: gateway → model | **HTTP streaming (SSE-shaped)** | 🔴 **`say` serialises first specifically so TTS can start while `quote`/`difficulty_delta`/`why` are still being written** `[IMPL]`. Non-streaming forfeits the entire latency design | Request/response — turns NFR-P1 from 1.5 s into full generation time |
| 4 | Client ↔ live session | **WebSocket** | Bidirectional, low-latency, long-lived: streamed captions, presence transitions, identity-check prompts, suspend/resume signals. Polling at conversational cadence is wasteful and adds jitter to a UI where jitter reads as a fault | SSE — unidirectional; the client must send answers and heartbeats |
| 5 | Face measurement | **REST, synchronous** | Single frame in, embedding out, sub-second, ~135 calls per session. The caller genuinely cannot proceed without it | Async — adds correlation overhead to a fast pure function |
| 6 | Audit compilation | **Queue (durable work item)** | Triggered by `SessionEnded`, must survive a crash, retried 3× then escalated to `HumanReviewRequired`. Losing this loses the product's only durable artifact | In-request — a client disconnect at session end would lose the audit |
| 7 | Notification dispatch | **Queue with DLQ** | Retries span hours; provider failures are routine; dead-lettering is an alert, never a silent drop | Synchronous — provider latency would block domain transactions |
| 8 | Analytics ingestion | **Fire-and-forget on the bus** | Lossy-tolerant by design. Must **never** block a live session | Synchronous — the highest-severity failure in the product is stranding a candidate |
| 9 | Read models | **REST + query handlers** | Cacheable, idempotent | GraphQL — a flexible query surface over a model whose central rule is *these two things must never be joined* is an anti-goal (R-27) |
| 10 | Inference pool (future) | **gRPC** `[PROP]` | The one place gRPC earns its cost: high-volume internal RPC (~15 generations/s at target scale `[EST]`), bidirectional streaming, schema-enforced contracts | REST — per-request overhead at that volume is real |
| 11 | Outbound webhooks | **HTTP POST, at-least-once, signed** | Tenant-configured endpoints are T0 | — |

### 17.3 Protocol boundaries

```
   BROWSER / DESKTOP CLIENT
        │           │
   REST │           │ WebSocket  (live session only)
        ▼           ▼
   ┌──────────────────────────────┐
   │   APPLICATION SERVICES       │
   │   (stateless, §22)           │
   └───┬──────────┬──────────┬────┘
       │ REST     │ EVENTS   │ QUEUE
       │ (sync)   │ (async)  │ (durable work)
       ▼          ▼          ▼
  ┌─────────┐ ┌────────┐ ┌───────────────┐
  │ Face    │ │  BUS   │ │ Compilation   │
  │ measure │ │        │ │ Notification  │
  │ (REST)  │ │        │ │ Retention     │
  └─────────┘ └───┬────┘ └───────────────┘
                  │
        ┌─────────┼──────────┬─────────────┐
        ▼         ▼          ▼             ▼
     BC-07     BC-11      BC-12         BC-13
   Evidence   Notify      Admin       Analytics
        ║                                 ║
        ╚════ 🔴 no subscriber holds ═════╝
              both BC-07 and BC-09
                       │
                  ┌────┴─────┐
                  │  BC-09   │  separate credentials
                  │Disposition│  separate store
                  └──────────┘

   ┌──────────────────────────────┐
   │  INFERENCE GATEWAY (ACL)     │  HTTP streaming today [IMPL]
   │  topology-agnostic port      │  gRPC pool tomorrow [PROP]
   └──────────────────────────────┘
```

---

## 18. Consistency Model

### 18.1 Classification

| Boundary | Model | Rationale |
|---|---|---|
| Within one aggregate | **Strong** | The aggregate is the consistency boundary. Non-negotiable |
| Session event append | **Strong, single-writer** | Sequence monotonicity and hash-chain continuity require serialised appends per session (ED-21) |
| Audit compilation | **Strong w.r.t. its stream** | Deterministic replay; the same stream yields the same audit `[IMPL]` |
| Enrolment ↔ session start | **Strong** | The invariant is type-level; there is no window in which a session exists without an enrolment (ED-23) |
| Claim confirmation ↔ session | **Eventual** | Confirmation precedes creation causally; no shared transaction needed |
| Session ↔ notification | **Eventual** | Notification lag never blocks an interview |
| Audit ↔ read models | **Eventual, bounded** | Projection lag is monitored (`ProjectionLagged`); staleness surfaced, never hidden |
| Audit ↔ decision support | **Eventual** | Advisory |
| Org suspension ↔ live sessions | **Deliberately inconsistent** | Suspension applies to *new* sessions. A live session completing under a suspended org is **correct** (Ch. 2 §12.4) |
| 🔴 **Evidence ↔ Disposition** | **No consistency relationship of any kind** | ED-14. Not eventual, not weak — **absent**. There is nothing to reconcile because there is no shared identity |

### 18.2 Sagas

Six long-running processes. Each names its orchestrator, steps, compensation, and timeout.

#### SAGA-1 Candidate Onboarding
`InviteCandidate` → `MintToken` → `DispatchNotification` → *(wait)* → `RedeemToken` → `RecordConsent`
**Orchestrator:** BC-03. **Compensation:** delivery exhausted → revoke token, surface to recruiter with a copyable link; **never auto-resend to a system-corrected address**. **Timeout:** 14 d → `InvitationExpired`.

#### SAGA-2 Interview Completion
`SessionEnded` → `CompileAudit` → `PersistAtomic` → `SealIntegrity` → `EvaluateSufficiency` → `NotifyReviewers`
**Orchestrator:** BC-07. **Compensation:** 🔴 **forward-only.** Evidence is append-only; there is no rollback. Compile failure retries 3× then transitions to `HumanReviewRequired` — a **state**, not an exception (ED-21). **Timeout:** 60 s per compile attempt.

#### SAGA-3 Retention Purge
`RetentionDue` → fan-out `PurgeInContext` to BC-04, BC-05, BC-06, BC-07, BC-11 → collect acks → `RetentionExecuted`
**Orchestrator:** BC-12. **Compensation:** none possible — deletion is irreversible. **A partial purge alerts, retries, and never marks itself complete.** **Timeout:** per-context 15 min; batch escalates after 24 h.
> Chapter 2 §8.5: deletion must reach backups. That is Ch. 7's obligation; this saga is the domain half.

#### SAGA-4 Deprovisioning
`PrincipalRevoked` → terminate live sessions → revoke tokens → pseudonymise actor in retained artifacts → ack
**Orchestrator:** BC-01. **Compensation:** none; reinstatement is a new principal. **Timeout:** immediate; alert at 60 s.
> Authored artifacts (annotations, overrides, dispositions) are **retained with a stable, non-reassignable actor handle**. Deleting a reviewer must not orphan the evidence they produced (Ch. 2 §13.12, OQ-25).

#### SAGA-5 Organisation Termination
`TerminationRequested` → 30 d export window → `RevokeReadAccess` → `SchedulePurge` → SAGA-3
**Orchestrator:** BC-02. **Compensation:** reinstatement permitted until the window closes.

#### SAGA-6 Data-Subject Request
`DsrReceived` → enumerate identifiers per context → verify completeness → delete → attest
**Orchestrator:** BC-12. **Compensation:** none. **Verification is by identifier and count, never by reading content** (contradiction X-5).

### 18.3 Compensation philosophy

> **Append-only domains use forward recovery, not rollback.**

A distributed transaction that "undoes" an interview would have to delete evidence — which is exactly the mutation the hash chain exists to make visible. So every failure in an evidence-touching saga resolves to a **new recorded state** (`HumanReviewRequired`, `AuditUnreadable`, `RetentionPartiallyFailed`), never to an erasure. This is why classic Saga compensation applies only to SAGA-1 and SAGA-5, and why the other four have "none possible" in their compensation row — stated rather than left blank, because a blank invites someone to add one later.

---

## 19. Transaction Boundaries

### 19.1 Rules

| # | Rule |
|---|---|
| TB-1 | **One aggregate, one transaction.** No transaction spans two aggregate roots |
| TB-2 | Events publish via an **outbox written in the same transaction** as the aggregate (ED-22) |
| TB-3 | A transaction never contains a network call to another context |
| TB-4 | 🔴 A transaction never spans BC-07 and BC-09 — **structurally impossible**: separate stores, separate credentials |
| TB-5 | Read models are updated **outside** the write transaction |
| TB-6 | Optimistic concurrency on every write; `ConcurrencyException` is retried by the caller, never swallowed |

### 19.2 Boundary table

| Operation | Begins | Ends | Aggregates | Outbox |
|---|---|---|---|---|
| Create organisation | `CreateOrganization` accepted | `Organization` persisted | AG-01 | `OrganizationCreated` |
| Publish role version | Command accepted | `RoleVersion` frozen | AG-03 | `RoleVersionPublished` |
| Invite candidate | Command accepted | `Invitation` persisted | AG-06 *(AG-05 in a prior tx)* | `CandidateInvited` |
| Extract claims | Gateway returned **and gate applied** | `ClaimSet` persisted | AG-08 | `ClaimsExtracted` |
| Enrol face | Measurement returned **and gate applied** | `EnrolmentProfile` persisted **or rejected** | AG-09 | `EnrolmentCompleted` \| `EnrolmentRejected` |
| **Append session event** | Command accepted | Event appended at `expectedSequence` | AG-10 | the event itself |
| **Submit answer** | Command accepted | `AnswerReceived` appended | AG-10 | `AnswerReceived` |
| **Plan turn** | Gateway returned **and grounding applied** | `QuestionAsked` appended | AG-10 | `QuestionAsked` |
| Compile audit | Stream replay complete | Audit persisted atomically | AG-11 | `AuditCompiled` |
| Seal audit | Signature computed | Seal persisted | AG-11 | `AuditSealed` |
| Override status | Command accepted | Assessment appended | AG-13 | `ClaimStatusOverridden` |
| **Record disposition** 🔴 | Command accepted | `Disposition` persisted | AG-15 **alone** | `DispositionRecorded` |
| Dispatch notification | Work item claimed | Receipt persisted | AG-16 | `NotificationDispatched` |

### 19.3 The three boundaries that carry the most weight

**Turn planning.** The transaction opens *after* the gateway returns and *after* the grounding gate runs. A model call inside a transaction would hold a write lock for 2.2–2.6 s warm — and up to 40 s cold `[IMPL]`. The sequence is: call (no tx) → validate (no tx) → append (tx). Only validated output is ever durable.

**Enrolment.** Either a profile meeting the quality gate is persisted, or nothing is. There is no intermediate "provisional enrolment" state, because a provisional biometric reference is exactly the weak reference Chapter 1 refuses to enrol `[IMPL]`.

**Audit compilation.** Atomic write-then-rename means **no half-audit is ever observable** `[IMPL]`. The transaction ends only when the complete audit is durable. A crash mid-compile leaves the stream intact and the audit absent — recoverable by replay, which is the whole argument for ED-13.

---

## 20. Multi-Tenancy — resolving Chapter 1 R-05

### 20.1 The problem, restated precisely

Chapter 1 R-05: **no domain model carries an organisation or tenant field** `[IMPL]`. Chapter 1 §0.3 named this the *only* current decision that would require a rewrite rather than an extension to reach multi-tenant scale, and Chapter 1 P7 forbids exactly that. Chapter 2 §5.1 added the deadline: **do it before data worth preserving exists.**

### 20.2 Resolution — ED-15

**`TenantId` enters the Shared Kernel as a mandatory value object on every aggregate root, and repository interfaces make an unscoped query inexpressible.**

Three enforcement layers, weakest to strongest:

| Layer | Mechanism | Defeats |
|---|---|---|
| 1. Type | `findById(TenantContext, ID)` — **there is no single-argument overload** | Accidental omission at compile time |
| 2. Persistence | Row-level scoping; every predicate carries the tenant | A repository bug |
| 3. Credential | Per-tenant key for biometric material (BC-06) | A compromised query path reading another tenant's templates |

Layer 1 is the one that survives staff turnover. A developer cannot write an unscoped query, because the method does not exist.

### 20.3 Migration from the current single-tenant state

The current store is per-session JSON files with a `schemaVersion` check that **hard-throws on mismatch and has no migration path** `[IMPL]`. Chapter 1 noted that adding the tenant key and the migration path together costs far less than either alone. Sequenced:

| Step | Action | Notes |
|---|---|---|
| M1 | Introduce `TenantId` in the SK with a well-known bootstrap value | One tenant exists today |
| M2 | Add `tenantId` to every aggregate's codec as an **optional** field, defaulting to bootstrap on read | Forward-compatible read |
| M3 | Build the migration path that the schema check currently lacks | Fixes Ch. 1 NFR-R5 |
| M4 | Bump `schemaVersion`; migrate on read, rewrite on next save | No big-bang migration |
| M5 | Make `tenantId` **required**; remove the default | The point of no return |
| M6 | Change repository signatures to require `TenantContext` | Compiler finds every call site |

> M2 → M5 is the whole trick: a field that is optional during migration and required afterwards, with the compiler enforcing the transition at M6. Attempting M5 first against a hard-throwing version check orphans every saved enrolment (R-34).

### 20.4 Shared vs isolated

| Resource | Model | Rationale |
|---|---|---|
| Application services | **Shared, stateless** | Tenant arrives in the request context |
| Event bus | **Shared, tenant-partitioned topics** | Ordering is per-aggregate; partitioning by tenant also bounds blast radius |
| Relational/document store | **Shared schema, row-level scoping** | Thousands of tenants × per-tenant schemas is operationally unserviceable |
| **Biometric templates** | 🔴 **Per-tenant encryption key** | Special-category data. Key isolation makes cryptographic erasure possible and bounds a breach to one tenant |
| Evidence store | **Shared, row-scoped, per-tenant key optional** | Tenant-configurable for privacy-sensitive customers |
| 🔴 **Disposition store** | **Separate store entirely, per tenant** | ED-14 — separation is by store, not merely by row |
| Model artifacts | **Shared** | No tenant data; provenance-flagged |
| Read models | **Shared, row-scoped** | Rebuildable |
| Inference | **Shared pool** `[PROP]` | 🔴 **With one constraint: no cross-tenant state of any kind — no shared cache keyed on content, no cross-tenant few-shot selection.** That is Ch. 2 §9.6's prohibition at the infrastructure layer |

### 20.5 Deployment-shape hook (Ch. 1 §12.5)

Chapter 1 offered three shapes: (a) cloud control plane + local data plane, (b) per-tenant on-premises, (c) full cloud. **Chapter 3 does not choose** — that is Ch. 7. What Chapter 3 guarantees is that the choice is expressible without a domain change:

| Shape | What changes | What does not |
|---|---|---|
| (a) Control plane + local data plane | Repository adapters; Inference Gateway adapter | Aggregates, invariants, events, sagas |
| (b) Per-tenant on-premises | Deployment unit; tenant becomes implicit but is **still carried explicitly** | Everything else |
| (c) Full cloud | Nothing architectural; ED-01's privacy claim becomes contractual rather than architectural | Everything else |

> The tenant key is carried explicitly **even in shape (b)**, where it is redundant. A single-tenant deployment that omits the field cannot later join a multi-tenant fleet without the migration this section just described.

---

## 21. Security Boundaries

### 21.1 Trust boundaries as software boundaries

```
  ┌────────────────────────────────────────────────────────────┐
  │ T0  UNTRUSTED CONTENT — resume text, transcripts,          │
  │     model output, provider callbacks, webhook endpoints    │
  │     Escaped at EVERY sink. Never authoritative.            │
  └───────────────────────────┬────────────────────────────────┘
                              │ ACL / GroundingGate / escaping
  ┌───────────────────────────▼────────────────────────────────┐
  │ T1  AUTHENTICATED PRINCIPAL — candidate                    │
  │     Identity established; content still T0                 │
  └───────────────────────────┬────────────────────────────────┘
                              │ PermissionResolver (deny by default)
  ┌───────────────────────────▼────────────────────────────────┐
  │ T2  DOMAIN-TRUSTED — recruiter, hiring manager             │
  │     Every audit read is an auditable event                 │
  └───────────────────────────┬────────────────────────────────┘
                              │ role separation
  ┌───────────────────────────▼────────────────────────────────┐
  │ T3  ADMINISTRATIVE — org admin                             │
  │     🔴 Configuration authority, ZERO content authority     │
  └───────────────────────────┬────────────────────────────────┘
                              │ plane separation
  ┌───────────────────────────▼────────────────────────────────┐
  │ T4  CONTROL PLANE — platform admin                         │
  │     🔴 No UserRole exists. No application permission.      │
  │     Break-glass: two-person, time-boxed, disclosed.        │
  └────────────────────────────────────────────────────────────┘
```

### 21.2 Service-to-service authentication `[PROP]`

| Aspect | Design |
|---|---|
| Identity | Each context is a workload identity; tokens are **audience-scoped to the callee context** |
| Authorisation | Capability-based: a token grants *what may be done*, not *who is calling*. BC-11's token carries no evidence-read capability, so content minimisation is enforced by absent capability rather than template review |
| 🔴 Credential separation | **No workload identity holds both an evidence credential and a disposition credential.** Not a policy — a provisioning constraint |
| Propagation | `TenantContext` and `ActorRef` propagate as signed claims, never as caller-supplied parameters |
| Face service | Today `allow_origins=["*"]` and unauthenticated `[IMPL: Ch. 1 V1-17]`. Must become mTLS or a signed service token |
| Inference gateway | Callers authenticate to the gateway; the gateway authenticates to adapters. **The domain never holds a model credential** |

### 21.3 Secrets

| Class | Handling |
|---|---|
| Service credentials | Injected, short-lived, rotated. **Never in source — verified clean** `[IMPL]` |
| Per-tenant biometric keys | Envelope-encrypted; **cryptographic erasure is the deletion primitive** for §18.2 SAGA-3 |
| Signing keys (audit seals) | Separate custody from the evidence store — a store compromise must not yield seal-forgery capability |
| Provider credentials | Scoped to BC-11 only |
| Break-glass | Two-person, time-boxed, non-suppressible candidate disclosure `[OPEN: OQ-24]` |

### 21.4 Least privilege by context

| Context | Reads | Writes | Explicitly denied |
|---|---|---|---|
| BC-04 Resume | Own | Own | Evidence, Disposition |
| BC-05 Interview | Claims, RoleVersion, identity **timing** | Own stream | **Identity confidence values**, Disposition |
| BC-06 Verification | Own + frames | Own | Everything else. **Templates never leave** |
| BC-07 Evidence | Session streams | Own | 🔴 **Disposition** |
| BC-08 Decision Support | Evidence (read-only) | Own | Evidence writes, Disposition |
| BC-09 Disposition 🔴 | Candidate, Requisition | Own | 🔴 **Evidence, Decision Support, Analytics** |
| BC-11 Notification | Minimal directory | Own | 🔴 **Evidence, Disposition** |
| BC-12 Administration | **Identifiers and lifecycle states only** | Admin log | 🔴 **Aggregate content** |
| BC-13 Analytics | Sanitised events | Metrics | 🔴 **Cannot subscribe to BC-07 and BC-09** |

### 21.5 Enforcement that survives the team

Three mechanisms, in descending order of durability:

1. **Type-level** — `TenantContext` required; `RecordDisposition` has no evidence-ref field; `Unchecked` has no similarity field. Cannot be violated without a deliberate, reviewed type change.
2. **Provisioning-level** — no workload identity holds both credentials. Violating it requires an infrastructure change, which is reviewed.
3. **CI-level** — the check that fails any query joining evidence to disposition (Ch. 2 §17.5 control 5). **The only one that catches a violation invented after everyone who read this blueprint has left.**

> Documentation is not on this list. A rule that exists only in prose is a rule that will be broken by someone who never read the prose.

---

## 22. Scalability

### 22.1 Target (Ch. 1 §11.2, `[EST]`)

~900 peak concurrent sessions · ~45 embeddings/s · ~15 generations/s · ~135 M verifications/yr · ~40 M turns/yr.

### 22.2 Stateless services

Every application service is stateless: `TenantContext` and `ActorRef` arrive per request; aggregates are loaded and released; **no aggregate is cached across requests** (a cached aggregate is a stale invariant).

**The single stateful thing is `InterviewSession`, and it is stateful for a real reason:** hash-chain continuity and sequence monotonicity require a serialised writer.

### 22.3 Session affinity via lease — ED-21

| Aspect | Design |
|---|---|
| Mechanism | A single-writer **lease** per `SessionRef`; only the lease holder may append |
| Renewal | Heartbeat; expiry releases the lease |
| Failover | A new holder rehydrates from the stream and continues at `lastSequence + 1` |
| Conflict | Append at an unexpected sequence is **rejected**, never merged |
| Why not optimistic-only | Two concurrent appends could each read the same predecessor hash and produce a fork. A fork in a tamper-evident chain is indistinguishable from tampering |

> This is what makes Chapter 2 R-22 (in-memory session state) and Chapter 2 §12.6 (resumability) the **same** fix. Externalising state to the stream and leasing the writer solves both. One change, two problems.

### 22.4 Worker pools

| Pool | Scaling signal | Constraints |
|---|---|---|
| **AI turn workers** | Generations/s; queue depth | 🔴 **One in-flight turn per session** `[IMPL]` — parallelism is across sessions, never within one. Warm-up is per-worker; a cold worker must not receive a live turn |
| **Embedding workers** | Frames/s | Batched; GPU-backed above ~10/s (Ch. 1 NFR-S4). Stateless |
| **Voice workers** | Concurrent streams | 🔴 **Media never transits the application tier** (Ch. 1 NFR-S6). Voice is a data-plane concern; only the transcribed text enters the domain — which is already true of the domain contract: `InterviewVoiceController` only knows "text in, text out" `[IMPL]` |
| **Compilation workers** | Queue depth | Idempotent on `sessionRef`; safe to retry |
| **Notification workers** | Queue depth | Idempotent on key |
| **Projection workers** | Lag | Rebuildable; lag is surfaced, never hidden |

### 22.5 Backpressure

| Saturation | Response | Never |
|---|---|---|
| Turn workers saturated | Degrade to the static question bank, disclosed | Queue turns behind a growing latency wall |
| Embedding workers saturated | Widen the check interval within the 15–25 s band; beyond it, record `Unchecked{reason: capacity}` | Silently skip a check |
| Compilation backlog | Queue; candidate is already finished | Drop |
| Analytics backlog | **Shed load** | Block a live session |

> **The two `Never` rows in the identity path are the interesting ones.** A skipped check that is not recorded is an unmonitored gap presented as monitored — the omission-shaped version of a fabricated pass. Under capacity pressure the system must record that it could not measure, exactly as it does under service failure.

### 22.6 Data-volume scaling

| Concern | Threshold | Action |
|---|---|---|
| Per-session JSON files | ~10 k sessions/tenant `[EST]` | Indexed store behind `AuditStore` — interface unchanged (Ch. 1 ED-09) |
| Event stream length | ~500 events/session `[EST]` | Snapshotting `[OPEN: OQ-33]` |
| Dashboard recomputation | Dozens of sessions `[IMPL: acknowledged in source]` | Materialised projections |
| Graph rendering | ~200 nodes `[EST]` | Deterministic layered layout is O(V+E) `[IMPL]` |

---

## 23. Failure Scenarios

### 23.1 Partial failure

| Failure | Behaviour | Recovery | Principle |
|---|---|---|---|
| Inference unavailable mid-session | `TurnDegraded`; static bank; disclosed | Auto-recover next turn | P5 |
| Face service reachable but `engine_available:false` | All checks `Unchecked{engine_unavailable}`; session continues; coverage **null** | Auto-recover | 🔴 The case a naive uptime check reports green `[IMPL]` |
| Compilation fails | 3 retries → `HumanReviewRequired` | Human queue | Forward-only |
| Projection worker down | Read model stales; `ProjectionLagged` emitted; **staleness shown** | Auto-catch-up | Never hide staleness |
| Notification provider down | Retry with backoff → DLQ → alert | Recruiter gets a copyable link | Never silent |
| Disposition store down | Recording fails **loudly**; evidence unaffected | Retry | The separation means one outage cannot corrupt the other |

### 23.2 Message duplication

At-least-once delivery is assumed. Every consumer is idempotent on `idempotencyKey`.

| Consumer | Key | Duplicate effect |
|---|---|---|
| Event append | `sessionRef:{sequence}` | Rejected — sequence already exists |
| Compilation | `sessionRef` | Recompiles deterministically to the identical audit |
| Notification | `notificationId:{attempt}` | Suppressed at the provider boundary |
| Projection | event id | Idempotent upsert |
| Analytics | event id | Deduplicated |

> **Compilation is idempotent because it is deterministic** — the same stream yields the same audit `[IMPL]`. A non-deterministic compiler (one containing a model call) would make duplicate delivery produce two different audits for one interview. That is a second, independent argument for the no-model-call rule.

### 23.3 Network partition

| Partition | Behaviour | CAP posture |
|---|---|---|
| Client ↔ backend | Session → `Suspended` after 30 s; resumable within 24 h with mandatory identity re-verification; **gap recorded as `Unchecked{session_suspended}`** | Availability sacrificed; consistency of the record preserved |
| Backend ↔ inference | Degrade to static bank | Availability preserved, capability reduced |
| Backend ↔ face service | `Unchecked{reason}` | Availability preserved, evidence honestly reduced |
| Between write and read stores | Read models stale, staleness surfaced | AP with visible lag |
| **Within the event store** | 🔴 **Consistency chosen.** Appends refuse rather than fork | **CP** — a forked chain is indistinguishable from tampering |

> One boundary in this system is deliberately **CP** and every other is **AP**. That single exception is the hash chain, and it is the correct exception: everywhere else, degraded availability produces an honest record of degradation; in the chain, a partition-tolerant write produces a record that cannot be trusted at all.

### 23.4 Cascading-failure prevention

| Mechanism | Where |
|---|---|
| Circuit breakers | Gateway, face adapter, notification transports |
| Bulkheads | Turn, embedding, compilation, notification pools isolated — notification exhaustion cannot starve turn planning |
| Timeouts sized to measured reality | Turn 25 s warm; warm-up 90 s **because cold load is ~40 s** `[IMPL: a 20 s timeout against a 40 s cold load was a real shipped bug]` |
| Load shedding | Analytics first, notifications second, **never the interview path** |
| Graceful degradation | Every external dependency has a defined, visible degraded mode `[IMPL]` |

---

## 24. Architectural Decision Records

ADRs continue the ED series from Chapter 1 (ED-01 … ED-12).

---

### ED-13 — Event-source `InterviewSession`; the event log is authoritative and the audit is a projection

**Context.** Contradiction X-1: Ch. 2 §20.1 asserts the log is authoritative while OQ-26 lists the question as open. Aggregate design cannot proceed without an answer. Today the log is append-only and hash-chained `[IMPL]` but the aggregate is **not** rehydrated from it — state is in memory until `saveAudit()`, so a crash loses the interview (Ch. 2 R-22).

**Decision.** `InterviewSession` is event-sourced. The hash-chained `SessionEventLog` is the single source of truth. `ClaimAudit` and `EvidenceGraph` are **projections**, recompilable at any time. **OQ-26 is closed here, not deferred to Ch. 4.**

**Alternatives.**
- *Audit authoritative, log as an audit trail* — makes the log decorative and leaves corruption unrecoverable (Ch. 2 §13.13 recovery depends on replay).
- *Both authoritative* — two truths that can disagree; the disagreement would be invisible.
- *State-stored aggregate with a change log* — the status quo, which is Ch. 2 R-22.

**Consequences.**
- ✅ Crash recovery, resumability, and horizontal scale all become reachable from one change.
- ✅ Compilation is deterministic and idempotent (§23.2).
- ✅ Corruption of a projection is recoverable by rebuild.
- ✅ **Extension, not rewrite** — the substrate exists `[IMPL]`.
- ⚠️ Requires a snapshot policy `[OPEN: OQ-33]` and projection-rebuild testing (R-32).
- ⚠️ Event schema versioning becomes permanent overhead; the closed `SessionEventKind` enum already enforces the right discipline `[IMPL]`.

---

### ED-14 — Evidence and Disposition are separate bounded contexts with no join key; correlation is temporal and human-only 🔴

**Context.** Ch. 2 §17.5: recording hiring outcomes beside evidence reconstructs the labelled dataset Ch. 1 ED-04 refuses to collect, and it assembles itself from two individually reasonable decisions. But defensibility appears to want the link: which evidence informed which decision?

**Decision.** BC-09 holds **no** reference to any evidence artifact. `Disposition` carries `CandidateRef` and `RequisitionRef` only; the command object has no field for `SessionRef` or `AuditRef`. Separate store, separate credentials, no shared subscriber. **The causal link is preserved as temporal correlation** — `AuditViewed{actor, at}` in the admin log and `DispositionRecorded{actor, at+n}` — which a human or regulator can follow and no automated pipeline can join on.

**Alternatives.**
- *Foreign key with a policy prohibiting its use in ML* — a policy is not a control; R-14.
- *Same store, separate tables* — one credential reads both; the join is a `SELECT`.
- *No disposition record at all* — loses operational necessity and the audit trail of who decided what.
- *Encrypt the link, hold the key elsewhere* — reversible by anyone with both, and creates the illusion of protection.

**Consequences.**
- ✅ The prohibited dataset cannot be assembled without a deliberate, visible cross-store exfiltration.
- ✅ Ch. 1 ED-04's answer to "where does your training data come from" stays true as the product scales.
- ⚠️ **Forensic reconstruction is weaker.** Answering "exactly which audit informed this decision" requires temporal reasoning over two logs, not a join. **This is the point, and the cost is accepted deliberately.**
- ⚠️ A reviewer UI showing both must compose per-request without persisting the composition — permitted, and constrained by CR-4/CR-5 plus the CI check.
- ⚠️ Requires provisioning discipline forever. §21.5 layer 2.

---

### ED-15 — `TenantId` in the Shared Kernel; unscoped queries are inexpressible

**Context.** Ch. 1 R-05: no aggregate carries a tenant key — the only current decision Ch. 1 §0.3 identified as requiring a rewrite rather than an extension.

**Decision.** `TenantId` is a mandatory SK value object on every aggregate root. Repository interfaces accept `TenantContext` as a **required first parameter with no single-argument overload**. Biometric material additionally gets a per-tenant key. Migration per §20.3.

**Alternatives.**
- *Ambient tenant in a request context* — invisible at the call site; a background job forgets it.
- *Row-level security only* — correct, but a bug bypasses it silently; defence in depth wants the type layer first.
- *Schema per tenant* — unserviceable at thousands of tenants.
- *Defer to V2* — the failure Ch. 1 P7 exists to prevent.

**Consequences.**
- ✅ Cross-tenant leakage becomes a compile error, not a code-review responsibility.
- ✅ Per-tenant cryptographic erasure becomes possible (SAGA-3).
- ⚠️ Every repository signature changes — the compiler finds every call site, which is why M6 is last.
- ⚠️ Migration must be paired with the missing migration path (R-34).

---

### ED-16 — Inference behind a topology-agnostic Anti-Corruption Layer

**Context.** Contradiction X-4. Ch. 1 ED-01 makes local inference an architectural privacy property; Ch. 1 §12.2 shows that at 1 M interviews/yr a hosted API is likely cheaper than a self-hosted fleet, so the decision must be re-argued in Ch. 7. A bounded-context design must place inference now.

**Decision.** All model calls cross the **Inference Gateway**, whose port is topology-agnostic. Three adapters: `LocalOllamaAdapter` `[IMPL]`, `RemotePoolAdapter` `[PROP]`, `DeterministicFallbackAdapter` `[IMPL]`. No domain type mentions locality.

**Alternatives.**
- *Direct calls from each context* — every context learns the topology; the Ch. 7 decision becomes a refactor across BC-04 and BC-05.
- *Commit to local now* — makes ED-01 irreversible against Ch. 1's own instruction.
- *Commit to remote now* — abandons a differentiator before the trade-off is priced.

**Consequences.**
- ✅ Ch. 7 chooses without touching a domain type.
- ✅ Warm-up, timeout, degradation, and provenance stamping are implemented once.
- ✅ The deterministic fallback keeps the whole decision reversible — the product functions, degraded and disclosed, with no model at all `[IMPL]`.
- ⚠️ An indirection layer over what is currently a single local call — justified only because the topology decision is genuinely open (R-28: the risk is that someone bypasses the gateway "just this once").

---

### ED-17 — The grounding gate lives in the consuming context, never in the AI context

**Context.** The gate is the mechanism behind Ch. 1 P6. It is tempting to package it with the model client as a single "safe extraction" service.

**Decision.** `GroundingGate` is a domain service in BC-04 and BC-05. The AI service returns proposals; the consuming context validates.

**Alternatives.**
- *Inside the AI service* — an untrusted component judging its own trustworthiness. A prompt change and a gate change become one deployment.
- *Shared library in both* — acceptable mechanically, but ownership blurs and the gate drifts toward the model team's release cadence.

**Consequences.**
- ✅ The validator is owned by the party harmed by a validation failure.
- ✅ A model swap cannot weaken the gate.
- ⚠️ Two call sites implement grounding (resume text, live transcript) — already true `[IMPL]` and already covered by tests, including one proving a same-meaning paraphrase is rejected.

---

### ED-18 — Measurement and adjudication are separate bounded contexts

**Context.** Contradiction X-2. Ch. 1 ED-06 says "the service extracts, the client decides" — but "the client" presumes a two-tier desktop app and is undefined in a multi-context architecture.

**Decision.** Generalise: **the measuring component never adjudicates.** The face service returns embeddings and quality (`embedding: null` when it cannot measure; `engine_available: false` rather than a heuristic fallback `[IMPL]`); BC-06 adjudicates into `Verified`/`Mismatch`/`Unchecked`. The same rule governs the Inference Gateway: it returns text, it never decides groundedness.

**Alternatives.**
- *Service returns a verdict* — the exact failure found in the reference codebase: `verified: true, 98.7%` with no enrolled profile.
- *Adjudication in the UI* — unreachable from a server-side pipeline and untestable without a widget tree.

**Consequences.**
- ✅ Threshold, escalation, and coverage rules live in one documented, tested, calibratable place.
- ✅ Ch. 1 ED-06's intent survives the move to a distributed architecture.
- ⚠️ The face service can never be "improved" into returning a decision — worth a source comment where the response type is defined, matching the pattern used for `EvidenceGraph.strength()` `[IMPL]`.

---

### ED-19 — Copy-on-write `RoleVersion`; sessions bind a version

**Context.** Ch. 2 OQ-27 / R-23: editing required skills after interviews have run silently changes historical coverage reports, so an audit would state coverage against a role definition that did not exist when the interview happened.

**Decision.** A published `RoleVersion` is immutable. Edits create a new version. `InterviewSession` binds `roleVersionId` at creation. **Resolves OQ-27.**

**Alternatives.** *Mutable roles* — silently invalidates history. *Full temporal versioning of everything* — over-general for one aggregate.

**Consequences.** ✅ Historical coverage stays valid. ✅ A/B comparison of role definitions becomes possible later. ⚠️ Version proliferation needs an archival policy. ⚠️ The UI must make "editing creates a new version" obvious, or recruiters will be surprised.

---

### ED-20 — Candidate transparency is a distinct projection, not the recruiter artifact

**Context.** Ch. 2 OQ-30, assigned to this chapter. Ch. 1 V1-10 requires a candidate-facing view of what was recorded and why.

**Decision.** `CandidateTransparencyView` is a separate projection from the same event stream. **Excludes reviewer annotations and decision-support output by default.** Includes: claims examined, verdicts, evidence pointers, what was **not** examined, identity-check coverage, consent record, retention date. **Resolves OQ-30.**

**Alternatives.**
- *Same artifact* — exposes internal deliberation and would chill honest reviewer annotation, degrading the evidence quality the product exists to produce.
- *Nothing candidate-facing* — fails Ch. 1 G5 and transparency obligations.
- *Everything including annotations* — arguable under access-request law; deferred to Ch. 6 as a per-jurisdiction question rather than a default.

**Consequences.** ✅ One stream, two audiences, no duplicated truth. ✅ The contest flow (OQ-11) has a defined surface. ⚠️ Two projections to keep consistent — mitigated by both being rebuildable and compared in CI.

---

### ED-21 — Single-writer lease per session; forward-only recovery

**Context.** Hash-chain continuity and sequence monotonicity require serialised appends; horizontal scale requires no single node owning all sessions.

**Decision.** A lease per `SessionRef`; only the holder appends; failover rehydrates from the stream. Recovery in append-only domains is **forward-only** — failures resolve to new recorded states, never erasure.

**Alternatives.**
- *Optimistic concurrency alone* — two appends can read the same predecessor hash and fork the chain; a fork is indistinguishable from tampering.
- *Global session-service singleton* — a scaling ceiling and a single point of failure.
- *Rollback compensation* — would require deleting evidence.

**Consequences.** ✅ Ch. 2 R-22 and §12.6 resumability are one fix. ✅ Chain integrity survives concurrency. ⚠️ Lease expiry tuning: too short causes spurious failover, too long delays recovery. ⚠️ Lease-service availability becomes an interview-path dependency (R-30).

---

### ED-22 — Transactional outbox for all domain events

**Context.** Events must not be lost when an aggregate write succeeds, and must not be published when it fails.

**Decision.** Events are written to an outbox in the same transaction as the aggregate; a relay publishes at-least-once; consumers are idempotent on `idempotencyKey`.

**Alternatives.** *Publish after commit* — a crash between the two loses the event. *Two-phase commit* — operationally poor and unavailable across heterogeneous stores. *Event store as the only store* — only AG-10 is event-sourced.

**Consequences.** ✅ No lost or phantom events. ✅ TB-2 holds. ⚠️ At-least-once forces idempotency everywhere — already assumed in §12.1 DE-4. ⚠️ Relay lag is a monitored metric.

---

### ED-23 — Enrolment optionality resolved by aggregate non-existence

**Context.** Contradiction X-3 / Ch. 2 OQ-18. Ch. 1 FR-3.5 makes enrolment mandatory at the type level `[IMPL]`; FR-7.2 makes it declinable `[IMPL]`. Together, declining terminates the process — which under GDPR is presumptively invalid consent, since consent conditioned on access to the service is not freely given.

**Decision.** Declining produces **no `InterviewSession` aggregate**, not a nullable field. The candidate is routed to a conventional interview outside CogniHire, with no CogniHire record. The type-level invariant is preserved; consent stays genuinely optional. Implements Ch. 2's recommendation (c). **Resolves OQ-18 architecturally**; the product/legal confirmation remains Ch. 6's.

**Alternatives.**
- *(a) Unverified session mode* — reintroduces the path deliberately removed on 2026-07-27, and every claim's provenance would be `none`, producing an audit that looks like evidence and is not.
- *(b) Human-proctored alternative inside the product* — expands scope into interview logistics, explicitly out of scope (Ch. 1 §9).
- *Nullable `enrolledEmbedding`* — the cheapest change and the worst: it makes an unverified session representable, and representable states get reached.

**Consequences.** ✅ The strongest invariant in the codebase survives. ✅ Consent is genuinely optional. ⚠️ The organisation must have a non-CogniHire path — a real operational requirement to state in onboarding. ⚠️ Declining is recorded as a fact and **never with a reason**; the reason is the candidate's (Ch. 2 §16.4).

---

### ED-24 — Notification content minimisation enforced by absent capability

**Context.** Ch. 2 §16.2 forbids claims, verdicts, transcripts, similarity values, and coverage figures in notifications, including webhooks — because a webhook endpoint is configured by an admin explicitly denied `viewClaimAudit`, so a content-carrying webhook routes content *around* the permission model.

**Decision.** BC-11 is **not granted a read credential** for BC-07 or BC-09. Payloads are validated against a field allow-list at construction. A payload containing forbidden content is rejected by the aggregate.

**Alternatives.** *Template review* — depends on reviewer diligence forever. *Redaction at send* — the content was already fetched, so a bug leaks it. *Trust webhook consumers* — they are T0.

**Consequences.** ✅ Content minimisation cannot be violated by a template edit. ✅ Webhooks inherit it automatically. ⚠️ Notifications are terse and always require a click-through — deliberate. ⚠️ BC-11 needs a minimal directory for display names; that directory holds names and addresses only.

---

### ED-25 — Unify on the controller-delegating interview presentation adapter

**Context.** Ch. 1 OQ-01 / Ch. 2 §20.2: two interview implementations exist. `InterviewScreen` is wired and embeds its own session state machine; `LiveInterviewScreen` (1,013 LOC) delegates logic to a controller and is reachable only from a dev harness `[IMPL]`. Leaving both is pure liability (Ch. 2 R-10).

**Decision.** The architectural criterion is: **the presentation layer must be a thin adapter over `InterviewSession` commands**, because ED-13 moves session state out of the UI entirely. `LiveInterviewScreen` already delegates to a controller and is therefore closer to the target shape; it survives. `InterviewScreen` is retired once parity is reached. **Resolves OQ-01 on architectural grounds**; the sequencing remains a delivery decision.

**Alternatives.**
- *Keep `InterviewScreen`* — its embedded state machine is exactly what ED-13 dissolves; it would need the larger rewrite.
- *Keep both* — Ch. 2 R-10.
- *Rewrite both* — Ch. 1's own discovery report advises deciding first and rewriting second rather than refactoring in the dark.

**Consequences.** ✅ One presentation path; one test surface. ✅ Aligns with ED-13. ⚠️ `LiveInterviewScreen`'s voice stack is a stand-in (Web Speech / `flutter_tts`), named in code as swap points `[IMPL]` — retiring the other screen must not be read as declaring voice production-ready. ⚠️ **The typed path must be first-class in the survivor** (Ch. 2 R-16), which is a functional requirement of this migration, not a follow-up.

---

### ED-26 — WCAG 2.2 AA; the typed interview path is a command, not a fallback

**Context.** Ch. 2 OQ-19 / R-16: a voice-first interview without an equal text path is disability discrimination in a hiring context. No accessibility audit has ever been performed.

**Decision.** Conformance target **WCAG 2.2 AA**. Architecturally: `SubmitAnswer` is modality-agnostic — the domain contract is already "text in, text out" `[IMPL]`. Voice is an **input adapter**, not a privileged path. `Modality` is recorded for operational routing and **never enters evidence, and never a per-session analytics event** (Ch. 2 R-25). **Resolves OQ-19**; audit scheduling is Ch. 6's.

**Alternatives.** *Voice-first with a text fallback* — "fallback" is the discrimination, expressed in the type system. *No target* — the status quo.

**Consequences.** ✅ Equal treatment is structural: there is one command. ✅ The audit cannot encode a disability signal. ⚠️ An accessibility audit must actually be commissioned — architecture cannot substitute for it. ⚠️ Golden-image previews render text as boxes with no font loaded `[IMPL]`, so they cannot verify typography or screen-reader behaviour.

---

### ED-27 — Hiring-manager approval as a requisition-scoped policy value object

**Context.** Ch. 2 OQ-20: is HM approval a workflow gate or advisory?

**Decision.** `ApprovalPolicy` is a VO on `Requisition`, fixed at opening. `advisory` (default) or `gated` (two `ActorRef`s required on `Disposition`). **Resolves OQ-20.**

**Alternatives.** *Always advisory* — likely wrong for regulated tenants. *Always gated* — imposes ceremony on small teams. *Tenant-wide setting* — changing it mid-requisition would treat two candidates under the same requisition differently.

**Consequences.** ✅ Per-requisition configurability with a consistency guarantee. ⚠️ `Disposition` carries a small state machine. ⚠️ A gated requisition with an unavailable approver needs a documented escalation `[OPEN: OQ-37]`.

---

### ED-28 — Minimal shared kernel; `Claim`, verdicts, and `Disposition` are never shared

**Context.** Shared-kernel creep silently reunifies contexts that were separated for safety (R-29).

**Decision.** The SK carries identity and time primitives only: `TenantId`, `ActorRef`, the opaque refs, `OccurredAt`, `SequenceNumber`, `HashLink`, `EventEnvelope`. Excluded permanently: `Claim`, `ClaimStatus`, `ProvenanceQuality`, `VerificationResult`, `Permission`, and 🔴 anything from BC-09. Every SK addition requires an ADR.

**Alternatives.** *Rich shared model* — `Claim` means a proposed span in BC-04 and a thing with a verdict in BC-07; sharing it is how a verdict leaks into extraction. *No kernel* — every context reinvents identity and time, and refs stop being type-distinct.

**Consequences.** ✅ Contexts evolve independently. ✅ The `Claim` distinction is enforced by the compiler. ⚠️ Deliberate duplication of small types across contexts — the correct trade and worth a comment where it looks like an accident.

---

## 25. Open Questions

Continuing from Ch. 2 OQ-30.

| ID | Question | Owner | Blocks | Default if unanswered |
|---|---|---|---|---|
| **OQ-31** | Is `ClaimSet` versioned when a candidate edits claims, and is the edit history evidence? | Ch. 4 | AG-08 invariant 5; candidate transparency | Edits overwrite — loses what the model proposed vs. what the candidate corrected, which is genuine provenance |
| **OQ-32** | Does telemetry classification belong to BC-05 or a separate Integrity context? | Ch. 4 | BC-05 scope | Stays in BC-05 — acceptable, but integrity rules and interview rules then share a release cadence |
| **OQ-33** | Snapshot cadence and retention for event-sourced sessions | Ch. 7 | ED-13 replay cost (R-26) | No snapshots — replay cost grows unbounded |
| **OQ-34** | Do reviewer annotations belong to BC-07 or a separate Annotation context? | Ch. 4 | AG-13 placement | Stays in BC-07 — puts mutable-ish data beside an immutable artifact |
| **OQ-35** | Who orchestrates the retention purge saga, and what is the per-context ack contract? | Ch. 6 | SAGA-3 completeness | BC-12 by default; the ack contract is undefined, so "complete" is unverifiable |
| **OQ-36** | Does BC-13 consume domain events directly or a separately produced sanitised stream? | Ch. 7 | CR-5 enforceability | Direct consumption — makes the both-topics prohibition a subscription-config concern rather than a structural one |
| **OQ-37** | Escalation when a `gated` requisition's approver is unavailable | Ch. 6 | ED-27 | Blocked indefinitely; teams will work around it outside the system |
| **OQ-38** | Is `CandidateRef` stable across requisitions within one tenant? | Ch. 4 | Repeat-candidate handling; Ch. 1 OQ-09 | Assumed stable — enables within-tenant history, which is desirable but must be a decision |
| **OQ-39** | Does BC-08 persist `SufficiencyEvaluation`, or compute on demand? | Ch. 5 | AG-14 lifecycle | Persisted — creates a durable model output beside evidence, which is precisely the shape §17.5 warns about |
| **OQ-40** | Locale/language: property of `RoleVersion` or `InterviewSession`? | Ch. 4 | Multilingual (Ch. 1 §9.1) | Undecided; retrofitting either is a schema change |
| **OQ-41** | Is the event bus tenant-partitioned, and does partitioning affect per-aggregate ordering? | Ch. 7 | §20.4, DE-5 | Assumed compatible — must be verified, not assumed |
| **OQ-42** | Which context owns the `Modality` value, given it must never reach evidence? | Ch. 4 | ED-26, R-25 | BC-05 holds it transiently — needs an explicit non-persistence rule |

---

## 26. Risks

Continuing from Ch. 2 R-25.

| ID | Risk | Category | Impact | Likelihood | Mitigation |
|---|---|---|---|---|---|
| **R-26** | Event-sourced sessions without a snapshot policy make replay cost grow unbounded | Operational | Medium | High absent OQ-33 | Snapshot every N events; measure replay time as an SLI |
| **R-27** | 🔴 The no-join-key rule is unenforceable if one process holds both credentials | Privacy | **Critical** | Medium | §21.5 three layers; the CI check is the durable one |
| **R-28** | A context bypasses the Inference Gateway "just this once" | Architecture | High | Medium | Dependency-direction test; no model credential outside the gateway |
| **R-29** | Shared-kernel creep reunifies deliberately separated contexts | Architecture | High | High — it is the path of least resistance | ED-28; SK additions require an ADR; automated SK-size check |
| **R-30** | Lease-service failure causes duplicate or blocked appends | Operational | High | Medium | Sequence rejection makes duplicates safe; lease outage degrades to session suspension, not data loss |
| **R-31** | An admin or reporting query path bypasses tenant scoping | Security | **Critical** | Medium | ED-15 layer 1 makes it inexpressible; reporting uses the same repositories |
| **R-32** | Projection drift — a read model that disagrees with the stream | Data integrity | High | Medium | Rebuild-and-compare in CI; a disagreeing projection is a defect of the same class as a fabricated pass |
| **R-33** | The saga orchestrator becomes a distributed monolith | Architecture | Medium | Medium | Choreography by default; orchestration only for SAGA-3/4/6 where completeness must be verified |
| **R-34** | The `TenantId` migration collides with the hard-throwing schema check | Operational | High | **High if attempted naively** | §20.3 M1–M6 in order; **M5 before M3 orphans every saved enrolment** |
| **R-35** | Event schema versioning is neglected until a consumer breaks in production | Operational | Medium | High | DE-6 tolerance rules; contract tests per consumer |
| **R-36** | ED-25's screen migration is read as "voice is production-ready" | Product | Medium | Medium | The voice stack is a stand-in, named in code as swap points `[IMPL]`; state it in the migration ticket |
| **R-37** | Capacity-driven skipped identity checks are not recorded as `Unchecked` | **Evidence integrity** | **Critical** | Low | §22.5: an unrecorded skip is an unmonitored gap presented as monitored — the omission-shaped fabricated pass |

> **R-37 is the one to watch.** Every other capacity-shedding decision in §22.5 is benign. This one converts a performance optimisation into a false evidentiary claim, and it is the kind of change that gets made under production pressure by someone optimising a p99 without reading Chapter 1.

---

## 27. Engineering Notes

### 27.1 Database schema (Ch. 4)

| Obligation | Source |
|---|---|
| `tenant_id` on **every** table, non-null, in every index prefix | ED-15 |
| Session event store: append-only, `(tenant_id, session_ref, sequence)` unique, `prev_hash` non-null | ED-13 |
| 🔴 **Disposition in a separate database with separate credentials; no FK, logical or physical, to any evidence table** | ED-14 |
| `role_version` insert-only after publish | ED-19 |
| Derived audit fields **not persisted** — recomputed on load `[IMPL]` | AG-11 |
| Actor identifiers stable and never reused | AG-02 |
| Optimistic-concurrency version column on every aggregate table | §11.1 |
| Outbox table co-located with each aggregate's store | ED-22 |
| Migration framework **before** the `TenantId` migration | R-34 |
| Ordering by sequence, never timestamp | Ch. 2 §13.20 |

### 27.2 API design (Ch. 3 → implementation)

| Obligation | Source |
|---|---|
| Commands map 1:1 to §13; typed failures, never silent no-ops | §13 |
| Every endpoint declares its `Permission`; deny-by-default | Ch. 2 §14 |
| `SubmitAnswer` is non-idempotent and must not auto-retry | Ch. 2 §13.2 |
| Turn streaming preserves `say`-first key order | Ch. 2 §9.4 |
| 🔴 `RecordDisposition` has **no** `sessionRef`/`auditRef` parameter | ED-14 |
| Export endpoints: rate-limited, step-up above threshold, always audited | Ch. 2 §5.7 |
| Health endpoints distinguish reachable from functional `[IMPL]` | Ch. 2 §8.1 |
| No general-purpose query language over the write model | §17.2 row 9 |

### 27.3 Deployment & infrastructure (Ch. 7 — hooks only)

| Hook | Detail |
|---|---|
| Choose the §12.5 deployment shape; ED-16 makes it an adapter choice | Ch. 1 §12.5 |
| Session lease service is an interview-path dependency | ED-21, R-30 |
| Worker pools bulkheaded; analytics sheds first, interview path never | §22.5 |
| 🔴 No workload identity holds both evidence and disposition credentials | §21.2 |
| Per-tenant biometric keys; cryptographic erasure is the deletion primitive | §21.3 |
| Snapshot policy | OQ-33 |

### 27.4 Testing

| Obligation | Rationale |
|---|---|
| **Invariant tests per aggregate** — every 🔴 invariant in Part B §6 gets a test that fails when the invariant is removed | Ch. 1's own lesson: verify the guard actually works by reverting the fix, or you have only proven the test passes |
| **Projection rebuild-and-compare in CI** | R-32 |
| 🔴 **A CI check failing any query joining evidence to disposition** | Ch. 2 §17.5 control 5; §21.5 layer 3 |
| Dependency-direction test (no cross-context aggregate imports) | CR-1, R-28 |
| Shared-kernel size check | ED-28, R-29 |
| Contract tests per event consumer | DE-6, R-35 |
| **Replace, do not delete, the role-disjointness test** | Ch. 2 R-20 |
| Widget-level mount tests for every screen | Ch. 1 NFR-M3 — the suite was structurally blind to build-time screen crashes until a real one shipped past 162 green logic tests |
| Prompt-drift test diffing the on-disk file against the embedded constant `[IMPL]` | Ch. 2 §13.6 |
| Deterministic compilation test: same stream → identical audit | ED-13, §23.2 |

### 27.5 Monitoring

| Signal | Why |
|---|---|
| Grounding-rejection rate | A spike means the model, prompt, or input distribution changed (Ch. 1 NFR-O7) |
| Projection lag | Staleness surfaced, never hidden |
| Outbox relay lag | ED-22 |
| Lease churn | R-30 |
| Replay duration | R-26 |
| `engine_available` separate from HTTP reachability `[IMPL]` | Ch. 1 NFR-O5 |
| 🔴 **Count of `Unchecked{reason: capacity}`** | R-37 — a rising count means the system is shedding evidence under load |
| Guard-block rate | Correctness signal |
| Turn degradation rate + cold-start flag `[IMPL]` | Keeps operators out of break-glass (Ch. 2 P-5) |

### 27.6 CI/CD

| Gate | Blocking |
|---|---|
| Aggregate invariant tests | Yes |
| Evidence↔disposition join check | **Yes — never overridable** |
| Dependency-direction check | Yes |
| Shared-kernel size check | Yes |
| Projection rebuild-and-compare | Yes |
| Schema migration present for any `schemaVersion` bump | Yes |
| Model artifact provenance validation | Yes `[IMPL: loader already rejects]` |
| Prompt-drift check | Yes `[IMPL]` |
| Contract tests | Yes |

### 27.7 Future scaling (Ch. 7)

| Obligation | Source |
|---|---|
| Externalised session state — one fix for resumability **and** horizontal scale | ED-13, ED-21 |
| Capacity model: ~900 concurrent, ~45 embeddings/s, ~15 generations/s | Ch. 1 §11.2 |
| Media never transits the application tier | Ch. 1 NFR-S6 |
| Indexed audit store behind the unchanged `AuditStore` interface | Ch. 1 ED-09 |
| 🔴 Inference pool holds **no cross-tenant state** — no content-keyed cache, no cross-tenant few-shot selection | Ch. 2 §9.6, §20.4 |
| Re-argue local-first inference explicitly; ED-16 makes it an adapter swap | Ch. 1 ED-01 |

---

## Appendix A — Traceability

| Chapter 1 / 2 item | Resolved by |
|---|---|
| Ch. 1 R-05 no tenant key | **ED-15**, §20 |
| Ch. 1 OQ-01 two interview screens | **ED-25** |
| Ch. 1 §12.5 deployment shape | Deferred by construction — **ED-16** |
| Ch. 2 OQ-18 enrolment mandatory vs declinable | **ED-23** |
| Ch. 2 OQ-19 accessibility target | **ED-26** |
| Ch. 2 OQ-20 HM approval gate | **ED-27** |
| Ch. 2 OQ-26 authoritative record | **ED-13** |
| Ch. 2 OQ-27 role mutability | **ED-19** |
| Ch. 2 OQ-30 transparency view | **ED-20** |
| Ch. 2 §17.5 evidence/disposition separation | **ED-14**, §21.5, §27.6 |
| Ch. 2 R-22 in-memory session state | **ED-13 + ED-21** |
| Ch. 1 ED-06 "service extracts, client decides" | Generalised by **ED-18** |

## Appendix B — Decisions in this chapter

ED-13 event sourcing · ED-14 evidence/disposition separation 🔴 · ED-15 tenant key · ED-16 inference ACL · ED-17 gate placement · ED-18 measurement vs adjudication · ED-19 role versioning · ED-20 transparency projection · ED-21 session lease · ED-22 outbox · ED-23 enrolment optionality 🔴 · ED-24 notification capability · ED-25 screen unification · ED-26 accessibility · ED-27 approval policy · ED-28 minimal shared kernel.

---

*End of Chapter 3. Chapter 4 (Data Model) inherits: Ch. 1 OQ-08 — which determines every foreign key — plus OQ-31, OQ-32, OQ-34, OQ-38, OQ-40, OQ-42, and the schema obligations in §27.1. Chapter 5 (AI/ML) inherits OQ-39 and the AI-service contracts in Part B §16. Chapter 6 (Security & Compliance) inherits OQ-35, OQ-37, and Ch. 2's OQ-21 … OQ-25. Chapter 7 (Infrastructure & Scale) inherits the §12.5 deployment shape, OQ-33, OQ-36, OQ-41, and §27.3.*
