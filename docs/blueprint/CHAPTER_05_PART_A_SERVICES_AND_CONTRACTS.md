# Chapter 5 — API Architecture, Service Contracts & Integration Design

**Part A of B** — request sections §1–12 (executive summary, API philosophy, API gateway, service catalog, REST APIs, commands, queries, DTO specifications, event contracts, WebSocket contracts, voice contracts, AI contracts). Part B covers §13–24.

> **Status relative to the codebase.** Chapters 1–4 are immutable source documents. Today CogniHire is a **single-process Flutter application** with pure-Dart domain logic (`lib/core/**`) and one out-of-process dependency: the **Python FastAPI face-embedding service** (`service/`) `[IMPL]`, plus **local Ollama** reached over HTTP for claim extraction/turn planning `[IMPL]` (`lib/core/claims/ollama_claim_extractor.dart`, `lib/core/interview/live_turn_client.dart`). **There is no API gateway, no HTTP command/query surface, no event bus, no WebSocket server, no service mesh in the repository.** Therefore this chapter is overwhelmingly `[PROP]` — the contract surface the monolith must decompose into — with the two genuinely-networked contracts (face service, Ollama inference) tagged `[IMPL]`, and prior subsystem designs `[DES]`. A statement without `[IMPL]` is a specification, not working software.

**Series continuity.** Introduces **ED-41 … ED-52**, **OQ-59 … OQ-70**, **R-51 … R-62**. Prior ranges (Ch1–Ch4) are referenced, never renumbered.

**Non-negotiable inheritances this chapter must not violate:**
- **ED-14 🔴** (Ch3/Ch4) — Evidence (BC-07) and Disposition (BC-09) are Separate Ways. **No API endpoint may accept a `SessionRef`/`AuditRef` and write a disposition, and no query may return evidence joined to a disposition.** The contract surface must make the join *inexpressible*, exactly as the data model does (Ch4 §21.5). §7.6 and §12.7 enforce this at the contract layer.
- **ED-13** (Ch3/Ch4) — commands append events through the transactional outbox (Ch4 §11.3, ED-35). Every command endpoint in §6 maps to an event append, never a raw table mutation.
- **Ch1 "no hidden score"** — no response DTO carries a composite score/rank/probability (Ch4 §10.6 linter). §8.5 reuses the vocabulary ban on DTO schemas.
- **Grounding gate** (Ch1/Ch2) — AI contracts (§12) return *selections/decompositions*, never authored claim text; the gate is a contract post-condition, not a prompt nicety.

---

## 1 Executive Summary

### 1.1 Why contract-first is mandatory here

For most products contract-first is a good practice. For CogniHire it is a **safety mechanism**, because the product's guarantees are properties of *what crosses a boundary*:

- "No hidden score" is only true if **no response schema has a score field**. A score can't leak through an interface that has no shape to carry it. That is a *contract* invariant, checkable before a single handler is written.
- ED-14's Evidence/Disposition separation is only real if **no request schema can carry both an evidence reference and a disposition intent**. Again: a contract property, enforceable at the schema linter, not discoverable only at runtime.
- The grounding gate's "the AI selects, never authors" is only enforceable if the **AI service's response contract returns spans/indices into the resume, not free text**. The contract shape *is* the guardrail.

Contract-first means: the OpenAPI/AsyncAPI/protobuf schemas are the source of truth, generated into typed clients and servers, and **CI fails if an implementation drifts from the contract** (§20). Writing a handler that returns a field the contract forbids is a build error, which is the only place these guarantees survive a team that has forgotten why they exist (Ch3 §21 "enforcement that survives the team").

### 1.2 How APIs derive from bounded contexts

Every endpoint maps to exactly one Ch3 bounded context (BC-01…BC-14). The mapping is mechanical:

```
Bounded Context (Ch3)          →  Service (§4)              →  API surface (§5–7)
BC-01 Identity & Access        →  Identity Service          →  /auth, /users, /roles
BC-02 Organizations & Tenancy  →  Organization Service      →  /orgs, /workspaces
BC-03 Jobs & Requisitions      →  Job Service               →  /jobs, /role-versions
BC-04 Candidates & Invitations →  Candidate Service         →  /candidates, /invitations
BC-05 Resume Intelligence      →  Resume Intelligence Svc   →  /resumes  (+ grounding gate)
BC-06 Interview Plan & Exec    →  Interview Planning +       →  /interviews, WS /session
                                   Interview Session Svc
BC-07 Evidence & Audit 🔴      →  Evidence Service          →  /audits, /evidence  (read-only)
BC-08 Decision Support         →  Evaluation Service        →  /sufficiency (no score out)
BC-09 Disposition 🔴           →  Disposition Service       →  /dispositions (ISOLATED, §7.6)
BC-10 Conversation Memory      →  Conversation Memory Svc   →  internal only (no public API)
BC-11 Reporting & Read Models  →  Report Service            →  /reports, /dashboards (queries)
BC-12 Notifications            →  Notification Service      →  internal + /notifications (read)
BC-13 Billing                  →  Billing Service (future)  →  /billing (OQ-63)
BC-14 Admin & Compliance       →  Audit Service             →  /admin/audit-events
(cross-cutting)                →  Inference Gateway (ACL)   →  internal only (ED-16)
```

**Rule: an endpoint that would need to reach across two contexts' data does not exist** — the client composes, or a read model (Ch4 §10) pre-joins on the *allowed* side. The one join that is forbidden entirely (evidence⋈disposition) has no service, no endpoint, no schema that can express it.

---

## 2 API Philosophy

### 2.1 Protocol selection — **ED-41**

| Interaction | Protocol | Justification | Tag |
|---|---|---|---|
| Client → command (state change) | **REST/HTTP+JSON** | Ubiquitous, cacheable, tooling-rich; commands are coarse-grained and low-frequency | `[PROP]` |
| Client → query (read model) | **REST/HTTP+JSON** | Same; read models are already denormalized (Ch4 §10) | `[PROP]` |
| Cross-context (service→service, async) | **Event bus (AsyncAPI over the outbox)** | Ch3 §17 chose events for cross-context; decoupling + ordering per stream | `[PROP]` |
| Live interview (bidirectional, low-latency) | **WebSocket** | Turn-by-turn duplex, presence, streaming transcript (§10) | `[PROP]` |
| Turn planning (token streaming) | **HTTP streaming (SSE/chunked)** | Ch3 §17 "say serializes first" latency design — first token fast | `[IMPL]`-adjacent (`live_turn_client.dart` streams) |
| Face measurement (request/response) | **REST sync** to FastAPI service | Existing `service/` contract; bounded latency | `[IMPL]` |
| Inference (LLM) | **Inference Gateway ACL** over HTTP (local Ollama today) | ED-16 topology-agnostic port | `[IMPL]` (Ollama) |
| Future inference pool | **gRPC** (reserved) | Ch3 §17 reserved gRPC for the remote inference pool | `[PROP]` |

**Trade-off:** choosing REST over gRPC for the primary surface costs some efficiency and streaming ergonomics, but buys universal client support, human-debuggable payloads, and gateway/CDN compatibility. gRPC is deliberately reserved for the one internal, high-throughput, schema-stable path (inference pool) where its cost is justified — not spread across the whole surface. **GraphQL is rejected** for the reason Ch3 §17 already gave: *"a flexible query surface over a model whose central rule is these two things must never be joined is an anti-goal."* A client-composable query language is precisely the wrong tool when the product's job is to make one join impossible.

### 2.2 Sync vs async
- **Synchronous** (REST): anything the caller must know the result of *now* — auth, reads, command *acceptance* (202/200).
- **Asynchronous** (events): anything downstream of acceptance — projections, notifications, audit compilation, analytics. A command returns as soon as its event is durably appended (Ch4 outbox); the *effects* (read-model update, audit) are eventually consistent (Ch3 §18).

### 2.3 Idempotency — **ED-42**
Every state-changing endpoint requires an **`Idempotency-Key`** header (client-generated UUID). The gateway/service records `(tenant_id, idempotency_key) → first response` for a TTL window; a replay returns the stored response, never re-executes. This composes with Ch4 §8.4's event-store unique `(stream_id, sequence)` constraint: even if idempotency cache misses, the append collides and is safe. Two layers, because a duplicated `SubmitAnswer` fabricating a second answer is a correctness bug, not a nuisance. **Trade-off:** idempotency storage + lookup on the write path; bounded by TTL.

### 2.4 Versioning (summary; full in §16)
**URL-major + header-minor.** Breaking changes bump `/v2/…`; additive changes are negotiated by `Accept: application/vnd.cognihire.v1+json`. Event contracts version by `schema_version` (Ch4 §9.4) and upcast on read.

### 2.5 Pagination, filtering, consistency
- **Pagination:** cursor-based (opaque, tenant-scoped cursor encoding `(sort_key, id)`); no offset pagination (unstable under concurrent writes). Default page 25, max 100.
- **Filtering:** a fixed allowlist of filter fields per endpoint (never arbitrary query expressions — that reopens the GraphQL problem). Filters are RLS-scoped; a filter can never widen tenant visibility.
- **Consistency:** reads are **read-your-writes for the writing client on command-acceptance fields**, eventually consistent for projections. A `read_model_lag_ms`/`as_of_sequence` field (Ch4 §10) lets a client detect staleness.
- **Errors:** one envelope everywhere (§15).

---

## 3 API Gateway

`[PROP]` — no gateway exists today. Target responsibilities:

| Responsibility | Design |
|---|---|
| **Authentication** | validates the caller's JWT (§14); rejects unauthenticated at the edge; never a service's job to re-parse raw credentials |
| **Authorization (coarse)** | route-level scope check (has *a* valid role for this route class); **fine-grained RBAC stays in the service** (Ch3 PermissionResolver) because it needs domain context the gateway lacks |
| **Rate limiting** | per-tenant + per-user + per-route token buckets (§17) |
| **Tenant isolation** | extracts `tenant_id` from the validated JWT claim and injects it as a **signed internal header** + sets the DB RLS GUC downstream (Ch4 §4.2). The client never supplies `tenant_id` in a body — it is derived from the token, so a client cannot forge cross-tenant access (**R-51**) |
| **Request tracing** | assigns/propagates `traceparent` (W3C Trace Context) + a `correlation_id` (Ch4 §9 envelope) |
| **Correlation IDs** | `correlation_id` groups all events/logs of one logical flow (an interview); `causation_id` links cause→effect |

**ED-43:** `tenant_id` is **always** derived from the authenticated principal, **never** accepted from the request body or path. This is the single most important gateway rule — it makes cross-tenant access a token-forgery problem (hard) rather than a parameter-tampering problem (trivial). Ch4 R-05/G-T1 depend on it.

```
Client ──JWT──▶ [ Gateway ]
                  │ 1. verify JWT (sig, exp, aud)
                  │ 2. extract tenant_id, sub, roles from claims
                  │ 3. rate-limit (tenant, user, route)
                  │ 4. inject X-Tenant-Id (signed), traceparent, correlation_id
                  ▼
              [ Service ]  ── sets RLS GUC = tenant_id ──▶ [ Postgres ]
                  │ fine-grained RBAC (PermissionResolver)
                  ▼ append event (outbox) / read model
```

---

## 4 Service Catalog

Each service = one bounded context (§1.2). Format: Purpose · Responsibilities · Public APIs · Dependencies · Events published · Events consumed. **Auth model:** all public APIs require a valid JWT (§14) unless marked *(pre-auth)*; fine-grained permission noted per endpoint in §5–7.

### 4.1 Identity Service (BC-01)
- **Purpose:** authN delegation + RBAC subject/role/permission management (`lib/core/auth/**`, `lib/core/rbac/**` `[IMPL]` logic; unwired — Ch4 R-38).
- **Responsibilities:** token issuance/refresh (via IdP), role assignment, permission resolution.
- **Public APIs:** `POST /auth/token` *(pre-auth)*, `POST /auth/refresh`, `GET /me`, `GET/POST /users`, `GET/POST /roles`, `POST /role-assignments`.
- **Dependencies:** external IdP (§13 OAuth/SSO); `app_user`, `role`, `role_assignment` (Ch4 §5.1).
- **Publishes:** `UserInvited`, `UserActivated`, `RoleAssigned`, `RoleRevoked`.
- **Consumes:** `OrganizationCreated` (to seed the first admin).

### 4.2 Organization Service (BC-02)
- **Purpose:** tenant/org/workspace lifecycle (Ch4 §4).
- **Public APIs:** `POST /orgs`, `GET/PATCH /orgs/{id}`, `POST /workspaces`, `GET /workspaces`.
- **Dependencies:** `tenant`, `organization`, `workspace`, KMS (per-tenant key provisioning, Ch4 §20.3).
- **Publishes:** `OrganizationCreated`, `WorkspaceCreated`, `OrganizationTerminating` (triggers Ch4 §16.7 saga).
- **Consumes:** billing signals (future).

### 4.3 Candidate Service (BC-04)
- **Purpose:** candidate identity + invitations (Ch4 §5.2). **Holds who, never how-they-performed.**
- **Public APIs:** `POST /candidates`, `GET /candidates`, `POST /invitations`, `POST /invitations/{id}/revoke`, `POST /invitations/{token}/accept` *(pre-auth, token-bound)*.
- **Dependencies:** `candidate`, `invitation`; Notification Service (invite delivery).
- **Publishes:** `CandidateCreated`, `CandidateInvited`, `InvitationAccepted`, `InvitationExpired`, `ConsentRecorded` (research consent, Ch4 §5.2).
- **Consumes:** `InterviewCompleted` (to advance candidate state per Ch2 SM).

### 4.4 Job Service (BC-03)
- **Purpose:** requisitions + immutable role versions (Ch4 §5.2).
- **Public APIs:** `POST /jobs`, `GET/PATCH /jobs/{id}`, `POST /jobs/{id}/role-versions` (publish = immutable), `GET /role-versions/{id}`.
- **Publishes:** `JobCreated`, `RoleVersionPublished`.
- **Consumes:** —.

### 4.5 Resume Intelligence Service (BC-05)
- **Purpose:** resume ingest, parsing, chunking, **claim extraction with the grounding gate** (`lib/core/claims/**` `[IMPL]`).
- **Responsibilities:** accept upload → virus-scan/parse (Ch4 §12.8) → chunk → embed (via Inference Gateway) → extract candidate claims **that are verbatim-grounded in the resume** (grounding gate `[IMPL]`).
- **Public APIs:** `POST /resumes` (multipart), `GET /resumes/{id}`, `GET /resumes/{id}/claims`.
- **Dependencies:** Object storage (Ch4 §12), Vector DB (Ch4 §13), Inference Gateway (embeddings + extraction).
- **Publishes:** `ResumeIngested`, `ClaimsExtracted`.
- **Consumes:** —.
- **Contract guarantee:** `GET /resumes/{id}/claims` returns claims each carrying a **span reference into the resume** (provenance), never AI-authored prose (§12.2).

### 4.6 Interview Planning Service (BC-06a)
- **Purpose:** the **Interview Turn Planner** (Ch2's renamed "AI Interview Agent") — decides the next question/follow-up (`lib/core/interview/**`, `question_bank.dart`, `live_turn_client.dart` `[IMPL]`).
- **Responsibilities:** given session working set + role version + open claims, plan the next turn. **Its input type carries no identity-confidence field** (Ch3 AG-10 invariant — identity may influence *timing*, never *difficulty*).
- **Public APIs:** internal only (driven by Interview Session Service over the WS/stream); `POST /planning/next-turn` (internal).
- **Dependencies:** Inference Gateway (generation), Conversation Memory, Question Bank.
- **Publishes:** `FollowUpAsked`, `TurnPlanned`.
- **Consumes:** `AnswerSubmitted`.

### 4.7 Interview Session Service (BC-06b)
- **Purpose:** the **event-sourced session runtime** (Ch3 AG-10, Ch4 §7.1). Owns the live interview lifecycle + the session event stream.
- **Responsibilities:** hold the single-writer lease (Ch3 ED-21), append session events, drive the WebSocket, enforce mandatory continuous identity verification (Ch2).
- **Public APIs:** `POST /interviews` (create), `POST /interviews/{id}/start`, `POST /interviews/{id}/answers` (command), `POST /interviews/{id}/end`; **WebSocket `/ws/session/{id}`** (§10).
- **Dependencies:** Event store (Ch4 §8), Redis lease/working-set, Interview Planning, Identity Verification (face service), Voice Service.
- **Publishes:** `InterviewStarted`, `AnswerSubmitted`, `IdentityChecked`, `IntegrityObserved`, `KeystrokeBatch`, `InterviewCompleted`.
- **Consumes:** `TurnPlanned`, `FollowUpAsked`.

### 4.8 Identity Verification (face) Service — `[IMPL]`
- **Purpose:** face enrolment + continuous verification (the FastAPI `service/` + `lib/core/verification/**`).
- **Public APIs:** `POST /face/enrol`, `POST /face/verify` (sync REST).
- **Contract:** returns `VerificationResult` = `Verified` | `Mismatch` | `Unchecked`; **`Unchecked` carries no similarity number** (Ch3/Ch4 VO rule — the field does not exist). Per-tenant encrypted templates (Ch4 §20.3).
- **Publishes:** (via Session Service) `IdentityChecked`.

### 4.9 Voice Service (BC-06c)
- **Purpose:** STT/TTS for spoken interviews (§11). `[PROP]` — `interview_voice_controller.dart` `[IMPL]` exists client-side; server STT/TTS is proposed.
- **Public APIs:** streaming STT ingest + TTS synthesis over the session WebSocket (§11).
- **Dependencies:** STT/TTS provider (OQ-64).

### 4.10 Conversation Memory Service (BC-10)
- **Purpose:** the **session working set** (Ch2's renamed "AI memory"). **No public API** — internal to the interview runtime; ephemeral in Redis (Ch4 §15), semantically recallable via vectors (Ch4 §13).
- **Publishes/Consumes:** internal only.

### 4.11 Evidence Service (BC-07) 🔴 — read-only
- **Purpose:** the **ClaimAudit + EvidenceGraph** projections (Ch3 AG-11/12/13, Ch4 §10.4). Derived, rebuildable.
- **Public APIs:** `GET /audits/{interview_id}`, `GET /evidence/{interview_id}` — **read-only. There is no write endpoint** (evidence is compiled from events by a projection, never POSTed). **No endpoint accepts or returns a disposition reference** (ED-14).
- **Publishes:** `AuditCompiled`.
- **Consumes:** the session event stream (projection).

### 4.12 Evaluation Service (BC-08)
- **Purpose:** **SufficiencyEvaluation** (Ch3 rename) — the decision-*support* model (`lib/core/ml/**` `[IMPL]`, synthetic-only, `isValidatedOnRealData=false`).
- **Public APIs:** `GET /sufficiency/{interview_id}` — returns a **sufficiency assessment with per-feature attribution copied from the exact decomposition** (Ch4 §10.4 AttributionExplanation), **abstains** where conformal coverage is insufficient (Ch3 conformal+abstain). **Returns no composite score, no hire probability, no rank** (§8.5).
- **Publishes:** `SufficiencyAssessed`.
- **Consumes:** `AuditCompiled`.

### 4.13 Report Service (BC-11)
- **Purpose:** CQRS read models + generated report artifacts (Ch4 §10, §12).
- **Public APIs:** `GET /dashboards/recruiter`, `GET /dashboards/candidate` (transparency view), `GET /reports/{interview_id}`, `POST /reports/{interview_id}/export` (→ object storage HTML/PDF; export writer `[IMPL]` to local FS today).
- **Consumes:** all projection-feeding events.

### 4.14 Notification Service (BC-12)
- **Purpose:** outbound notifications (Ch2 §16 catalogue N-01…N-20).
- **Public APIs:** `GET /notifications` (recipient's own, read); dispatch is event-driven (internal).
- **Contract guarantee:** notification payloads are **content-minimised — no claims, verdicts, transcripts, or similarity values** (Ch2 rule; Ch4 `notification.payload_ref` CHECK). Enforced as a schema post-condition (§8.5).
- **Dependencies:** Email/SMS providers (§13).
- **Consumes:** most domain events (as triggers).

### 4.15 Audit Service (BC-14)
- **Purpose:** **administrative/compliance** audit — the hash-chained `audit_event` stream (Ch4 §5.4), distinct from the interview evidence log.
- **Public APIs:** `GET /admin/audit-events` (platform/org admin only, §20 least-privilege).
- **Publishes:** —. **Consumes:** admin/master-data mutation events.

### 4.16 Disposition Service (BC-09) 🔴 — ISOLATED
- **Purpose:** record hire/reject decisions (Ch3 AG-15).
- **Public APIs:** `POST /dispositions` (takes **`CandidateRef` only** — no `SessionRef`/`AuditRef`; the field does not exist in the DTO), `GET /dispositions/{candidate_id}`.
- **Isolation:** its own database + credential (Ch4 §21.5); **subscribes to no evidence topic; publishes `DispositionRecorded` consumed by exactly two non-evidence consumers** (Ch4 §9.3). See §7.6.
- **Publishes:** `DispositionRecorded`.
- **Consumes:** nothing from BC-07/08/10/13.

### 4.17 Inference Gateway (ACL, ED-16) — internal
- **Purpose:** topology-agnostic port over inference (`LocalOllamaAdapter` `[IMPL]`, `RemotePoolAdapter` `[PROP]`, `DeterministicFallbackAdapter` `[IMPL]`).
- **Public APIs:** internal only — `infer(purpose, input) → output` + `embed(text) → vector`. Callers never talk to Ollama/remote pools directly (§12.6).
- **Contract:** every call audited via `inference_request`/`inference_result` (Ch4 §5.4).

---

## 5 REST APIs — endpoint specifications

Common to every endpoint: **Auth** = valid JWT (§14) unless *(pre-auth)*; **Tenant** = derived from token (ED-43), never in body; **Idempotency** = required on all non-GET (ED-42); **Errors** = standard envelope (§15); **Rate limits** = §17 tiers. Below, each endpoint lists what differs.

### 5.1 Representative endpoint specification (full template)

**`POST /interviews/{id}/answers`** — submit a candidate answer (command).
| Field | Value |
|---|---|
| Method / URL | `POST /v1/interviews/{id}/answers` |
| Bounded context | BC-06b Interview Session |
| Purpose | Append an `AnswerSubmitted` event to the session stream |
| Authorization | principal must be the candidate bound to this interview's invitation (self-only); recruiters **cannot** submit answers |
| Request schema | `SubmitAnswerRequest` (§8.2) `{ claim_id, answer_ref | answer_text, client_ts, response_ms }` |
| Response | `202 Accepted` + `{ interview_id, sequence, accepted_at }` (the appended event's sequence) |
| Error codes | 400 validation, 401, 403 not-your-interview, 404, 409 sequence conflict/duplicate idempotency mismatch, 410 interview ended, 422 claim not open, 429, 503 lease unavailable |
| Idempotency | required; `(tenant, key)` dedup + event-store `(stream_id, sequence)` unique (Ch4 §8.4) |
| Rate limit | per-session burst (§17); backpressure never *skips* an identity check (Ch3 R-37) |

The remaining endpoints are specified compactly in §6 (commands) and §7 (queries); each inherits the common rules above.

---

## 6 Commands (state-changing endpoints)

Every command **maps to an event append via the outbox** (ED-13/ED-35). None mutates a table directly except master-data services (which still emit an event for audit).

| Command endpoint | BC | Emits event | Key preconditions | Notable auth |
|---|---|---|---|---|
| `POST /orgs` | 02 | `OrganizationCreated` | unique name | platform signup |
| `POST /workspaces` | 02 | `WorkspaceCreated` | org active | org admin |
| `POST /users` (invite) | 01 | `UserInvited` | unique email/tenant | admin |
| `POST /role-assignments` | 01 | `RoleAssigned` | role+scope exist | admin (RBAC) |
| `POST /jobs` | 03 | `JobCreated` | workspace active | recruiter |
| `POST /jobs/{id}/role-versions` | 03 | `RoleVersionPublished` | **immutable once published** | recruiter |
| `POST /candidates` | 04 | `CandidateCreated` | unique email/tenant | recruiter |
| `POST /invitations` | 04 | `CandidateInvited` | job open, role version published | recruiter |
| `POST /invitations/{token}/accept` *(pre-auth)* | 04 | `InvitationAccepted` | token valid, not expired | token-bound candidate |
| `POST /candidates/{id}/consent` | 04 | `ConsentRecorded` | candidate self | candidate |
| `POST /resumes` | 05 | `ResumeIngested` (after scan/parse) | file type/size, AV pass | candidate/recruiter |
| `POST /interviews` | 06b | `InterviewCreated` | accepted invitation | recruiter/system |
| `POST /interviews/{id}/start` | 06b | `InterviewStarted` | enrolment done, lease acquired | candidate self |
| `POST /interviews/{id}/answers` | 06b | `AnswerSubmitted` | claim open, interview live | candidate self |
| `POST /interviews/{id}/end` | 06b | `InterviewCompleted` | live | candidate/system/timeout |
| `POST /reports/{id}/export` | 11 | `ReportExported` | audit compiled | recruiter |
| `POST /dispositions` 🔴 | 09 | `DispositionRecorded` | **`CandidateRef` only; no evidence ref accepted** | hiring manager |
| `POST /orgs/{id}/terminate` | 02 | `OrganizationTerminating` | admin + confirmation | org/platform admin |

**Command discipline (ED-44):** a command endpoint **returns on durable event append (202/200), not on projection completion**. Effects (read models, audit, notifications) are eventually consistent. The response carries the appended `sequence` so a client can poll a read model's `as_of_sequence` for read-your-writes.

### 6.1 The disposition command in detail 🔴
```
POST /v1/dispositions
Authorization: Bearer <jwt: hiring_manager>
Idempotency-Key: <uuid>
{
  "candidate_ref": "uuid",         // identity only
  "decision": "advance" | "reject" | "hold",
  "rationale_text": "free text"    // human's words; NOT derived from evidence
  // NO session_ref, NO audit_id, NO evidence_ref — the schema has no such field
}
```
The DTO **structurally cannot** carry an evidence reference (§8.4). A hiring manager reads evidence in the UI (a separate read call to BC-07) and forms a judgement; the *system* never transports the evidence identifier into the disposition write. That gap is ED-14 at the contract layer.

---

## 7 Queries (read endpoints)

All queries hit **read models** (Ch4 §10), are RLS-scoped, cursor-paginated, and carry `as_of_sequence` for staleness.

| Query endpoint | BC | Read model | Returns | Never returns |
|---|---|---|---|---|
| `GET /me` | 01 | — | principal + effective permissions | — |
| `GET /dashboards/recruiter` | 11 | `recruiter_dashboard_view` | interviews + **states** | score, rank, verdict |
| `GET /dashboards/candidate` | 11 | `candidate_transparency_view` | own claims + identity status | comparison to others |
| `GET /interviews/{id}/timeline` | 11 | `interview_timeline_view` | ordered events (role-redacted) | raw keystrokes |
| `GET /audits/{id}` 🔴 | 07 | `evidence_viewer_view` | claim audit + evidence graph | **any disposition** |
| `GET /evidence/{id}` 🔴 | 07 | evidence nodes/edges | provenance graph | disposition, composite score |
| `GET /sufficiency/{id}` | 08 | — | sufficiency + attribution + **abstain** flag | composite score, hire probability |
| `GET /resumes/{id}/claims` | 05 | — | claims + resume span refs | AI-authored prose |
| `GET /dispositions/{cand}` 🔴 | 09 | disposition DB | decision + rationale | **any evidence/audit ref** |
| `GET /reports/{id}` | 11 | report read model | report artifact ref | — |
| `GET /notifications` | 12 | notification | own notifications (minimised) | claims/verdicts/similarity |
| `GET /admin/audit-events` | 14 | `audit_event` | admin action log | — |

### 7.6 🔴 The contract-level enforcement of ED-14
Two services, two datastores, two credentials (Ch4 §21.5). At the **contract** layer:
1. **No query returns both.** `GET /audits/{id}` (BC-07) has no field for a disposition; `GET /dispositions/{cand}` (BC-09) has no field for an audit/session. A client wanting "both" must make two calls with two different authorizations, and **nothing in either response lets it correlate them back to a hidden key** — the audit is keyed by `interview_id`, the disposition by `candidate_ref`, and the mapping between them is not exposed by any endpoint.
2. **No command carries both.** §6.1.
3. **No event carries both.** §9 / Ch4 §9.3 — `DispositionRecorded` payload has no evidence field; no consumer subscribes to both topic classes.
4. **CI contract test** asserts: no schema in the entire OpenAPI/AsyncAPI surface contains a property that is simultaneously an evidence-ref type and a disposition-ref type; and no consumer manifest lists both an evidence and a disposition topic (**ED-45**). This is the "survives the team" fence — a future engineer who adds `disposition.session_id` fails CI.

---

## 8 DTO Specifications

Contract-first: DTOs are defined in OpenAPI/JSON-Schema, generated into typed Dart/TS/Python clients. Conventions: all timestamps ISO-8601 UTC; all IDs UUID; unknown request fields **rejected** (strict decode, inherited from the `[IMPL]` codec discipline); `schema_version` on evolvable DTOs.

### 8.1–8.3 Representative DTOs
```jsonc
// SubmitAnswerRequest (v1)
{ "claim_id": "uuid", "answer_ref": "uuid|null", "answer_text": "string|null",
  "client_ts": "iso8601", "response_ms": 1234 }   // one of answer_ref/answer_text required

// VerificationResult (sealed — mirrors Ch3/Ch4 VO)
// Verified:  { "kind": "verified", "at": "iso8601" }
// Mismatch:  { "kind": "mismatch", "at": "iso8601" }
// Unchecked: { "kind": "unchecked", "reason": "string" }   // NO similarity field

// ClaimDTO
{ "claim_id": "uuid", "text": "string",           // selected verbatim from resume
  "resume_span": { "object_key": "string", "start": 120, "end": 168 },  // provenance
  "verification": VerificationResult }

// SufficiencyDTO
{ "interview_id": "uuid", "assessment": "sufficient|insufficient|abstain",
  "attribution": [ { "feature": "string", "contribution": 0.0 } ],  // copied, never recomputed
  "coverage_ok": true }                             // NO overall_score, NO hire_probability
```

### 8.4 The disposition DTO's deliberate shape 🔴
`RecordDispositionRequest` has exactly `{ candidate_ref, decision, rationale_text, idempotency via header }`. **There is no optional evidence field, no nullable session_ref.** Optionality would be a foot-gun; absence is the guarantee (Ch4 §5.5 / AG-15 "the command object has no such parameter").

### 8.5 Validation & the vocabulary ban — **ED-46**
The DTO schema linter (reusing Ch4 §10.6 / ED-32) **rejects any response DTO property whose name/type implies** `score`, `rating`, `rank`, `probability`, `fit`, `percentile`, or a disposition-ref on an evidence DTO (and vice-versa). Runs in CI against the generated OpenAPI. **Trade-off:** heuristic false positives handled by a reviewed allowlist (e.g. a UI `sort_rank` that is not a candidate score). This makes "no hidden score" and ED-14 **build-time contract properties**, not runtime hopes.

### 8.6 Versioning
Additive fields → minor (negotiated by `Accept` header). Field removal/semantic change → new major (`/v2`). Never repurpose a field's meaning within a version. Full policy §16.

---

## 9 Event Contracts

Events are the async cross-context contract (AsyncAPI), sharing Ch4 §9's envelope (`schema_version, kind, stream_id, sequence, tenant_id, at, actor, correlation_id, causation_id, prev_hash, hash`).

### 9.1 Published events → consumers (every event names its consumers)
| Event | Publisher | Consumers | Ordering | Idempotency |
|---|---|---|---|---|
| `OrganizationCreated` | Org | Identity (seed admin), Billing | per-tenant | key `(event.id)` |
| `RoleVersionPublished` | Job | Interview Planning | per-job | — |
| `CandidateInvited` | Candidate | Notification | per-candidate | — |
| `InvitationAccepted` | Candidate | Interview Session | per-invitation | — |
| `ResumeIngested` | Resume Intel | Interview Planning, Report | per-candidate | — |
| `ClaimsExtracted` | Resume Intel | Interview Planning, Evidence | per-resume | — |
| `InterviewStarted` | Session | Report, Notification | per-stream | — |
| `AnswerSubmitted` | Session | Interview Planning, Evidence(proj) | **per-stream, gap-free** | seq-keyed |
| `IdentityChecked` | Session | Evidence(proj), Report | per-stream | seq-keyed |
| `IntegrityObserved` | Session | Evidence(proj), Report | per-stream | seq-keyed |
| `InterviewCompleted` | Session | Evidence(compile), Candidate, Report, Notification | per-stream | — |
| `AuditCompiled` | Evidence | Evaluation, Report | per-interview | — |
| `SufficiencyAssessed` | Evaluation | Report | per-interview | — |
| `DispositionRecorded` 🔴 | Disposition | **exactly 2 consumers, none in BC-07/08/10/13** | per-candidate | key-dedup |
| `ReportExported` | Report | Notification | per-interview | — |
| `NotificationDispatched` | Notification | Audit | per-notification | — |

### 9.2 Compatibility, ordering, versioning
- **Compatibility:** additive-only within a `schema_version`; consumers ignore unknown *metadata*, reject unknown *payload* fields. Breaking payload change ⇒ `schema_version++` + upcaster (Ch4 §9.4).
- **Ordering:** guaranteed **per stream** (session events) via `sequence`; **not** globally ordered across streams (Ch4 §8.5) — consumers needing cross-stream causality use `correlation_id`/`causation_id`, never wall-clock.
- **Delivery:** at-least-once (outbox); consumers idempotent by `(consumer, event.id)` (Ch4 §11.2). A poison event is dead-lettered, **never silently skipped** (Ch4 R-39).

---

## 10 WebSocket Contracts — live interview

`[PROP]` (client controller `interview_voice_controller.dart` / `live_interview_screen.dart` `[IMPL]`; server WS proposed). Endpoint: **`wss://…/ws/session/{interview_id}`**, JWT in the connection handshake (§14), candidate-self only.

### 10.1 Message envelope (both directions)
```jsonc
{ "type": "…", "seq": 42, "correlation_id": "uuid", "ts": "iso8601", "payload": { … } }
```

### 10.2 Message types
| Direction | type | payload | notes |
|---|---|---|---|
| S→C | `session.ready` | `{ lease_id, resume_from_seq }` | after lease acquired (Ch3 ED-21) |
| S→C | `turn.question` | `{ question_id, text, claim_id }` | from Turn Planner |
| S→C | `transcript.partial` | `{ text }` | streaming STT (§11) |
| S→C | `transcript.final` | `{ text, answer_ref }` | committed to event as `AnswerSubmitted` |
| S→C | `identity.status` | `VerificationResult` | continuous; **no similarity on Unchecked** |
| S→C | `progress` | `{ claims_done, claims_total }` | **no score** |
| C→S | `answer.commit` | `{ claim_id, response_ms }` | commits current turn |
| C→S | `heartbeat` | `{}` | presence/liveness |
| S→C | `session.end` | `{ reason }` | terminal |

### 10.3 Presence & 10.4 progress
Presence = heartbeat every 10 s `[EST]`; missed 3 → `presence.lost`, session may pause (Ch2 timeout SM). Progress messages count claims, **never** a running score.

### 10.5 Reconnect behaviour — **ED-47**
On disconnect, the client reconnects with `Last-Event-Seq: N`; the server (a) validates the single-writer lease is re-acquirable (Ch3 ED-21 / Ch4 §22 "one change, two problems": in-memory state + resumability), (b) replays events after `N` from the durable stream, (c) resumes. **State is never held only in the socket** — it is the event stream (Ch4 §7.1), so a reconnect is a replay, not a loss. **R-52:** a reconnect that silently restarts the interview (losing prior answers) would be an evidence gap — forbidden; resume-from-sequence is mandatory.

---

## 11 Voice Contracts

`[PROP]` server-side. Latency-first (Ch3 §17 "say serializes first").

| Aspect | Contract |
|---|---|
| **STT** | streaming ingest of audio frames over the session WS → `transcript.partial`/`final`. Provider abstracted behind a port (OQ-64). |
| **TTS** | text → streamed audio out; **first-audio-byte target ≤ 400 ms** `[EST]` (perceived responsiveness) |
| **Streaming** | both directions chunked; question audio may begin before full text is planned (Ch3 §17) |
| **Latency targets** | STT partial ≤ 300 ms `[EST]`; end-to-end turn ≤ 1.5 s `[EST]` — reconcile with Ch1 §11 NFR |
| **Failure handling** | STT failure → **fall back to text input** (never drop the answer); TTS failure → display text (never skip the question). A voice failure degrades modality, **never** fabricates or omits an answer (Ch3 R-37 lineage). **R-53.** |

**OQ-64:** STT/TTS provider — local vs cloud (privacy vs latency vs cost; interacts with Ch4 §12 media OQ-44 on whether audio is even retained).

---

## 12 AI Contracts

All AI flows go through the **Inference Gateway (ED-16)** — callers never hold a provider client. Each contract's response shape *is* a guardrail.

### 12.1 Resume analysis / chunking
`embed(chunk) → vector` (Ch4 §13). Deterministic re-derivation (Ch4 §13.5). No free-text output.

### 12.2 Claim extraction — grounding-gate contract `[IMPL]`
`extractClaims(resume_text) → ClaimDTO[]` where **every claim's `text` is a verbatim, whitespace-collapsed, case-insensitive substring of the resume** and carries a `resume_span`. The gate **discards any candidate claim not verbatim-present** (`[IMPL]` behaviour). The contract post-condition: *the service may return fewer claims than the model proposed, never a claim absent from the source.* This is the grounding gate as an API invariant, not a prompt.

### 12.3 Question generation (Turn Planner)
`planNextTurn(working_set, role_version, open_claims) → TurnPlan`. **Input type has no identity-confidence field** (Ch3 AG-10). Output selects/parameterises a question; may stream (SSE). Difficulty derives from role version + open claims, **never** from identity signal.

### 12.4 Evaluation (SufficiencyEvaluation)
`assessSufficiency(audit) → SufficiencyDTO` (§8.3). Uses the synthetic-trained model (`lib/core/ml/**` `[IMPL]`, `isValidatedOnRealData=false` — **R-54:** must be surfaced in any response provenance until validated on real data). **Abstains** under low conformal coverage rather than guess. **Returns no composite score.**

### 12.5 Report generation
`generateReport(audit, sufficiency) → ReportArtifact`. Narrative is **templated over verified evidence** (Ch1 counterfactual/templated-explanation work `[IMPL]`), not free LLM prose about the candidate — the same authorship boundary as the grounding gate.

### 12.6 Inference Gateway interface (ACL)
```
infer(purpose: enum, input: typed) → typed        // purpose ∈ {claim_extract, turn_plan, report}
embed(text) → vector(768)
// adapters: LocalOllamaAdapter [IMPL] | RemotePoolAdapter [PROP] | DeterministicFallbackAdapter [IMPL]
// every call → inference_request/result audit rows (Ch4 §5.4)
```
Warm-up is a **hard precondition** (Ch3 §10 `warmUp()`; memory: warm 2.2 s vs cold 40 s) — the session service calls `warmUp()` before `InterviewStarted`, and a cold gateway is a 503, not a 40 s hang (**R-55**).

### 12.7 🔴 AI contracts and ED-14
No AI contract takes a disposition as input or emits one. The Evaluation Service produces *sufficiency support*, explicitly **not** a hire recommendation — because a hire recommendation keyed to evidence, persisted, is the ED-04 dataset. The AI never sees the outcome label, so it cannot learn to predict it (Ch4 §22).

---

*Part A ends here. Part B covers §13–24: external integrations, auth/authz flows (sequence diagrams), the error model, versioning, rate limiting, API security (OWASP API Top 10), observability, testing strategy, and the chapter's Open Questions / Risks / Engineering Decisions / Engineering Notes.*
