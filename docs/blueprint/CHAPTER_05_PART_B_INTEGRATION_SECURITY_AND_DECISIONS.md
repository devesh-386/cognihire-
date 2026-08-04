# Chapter 5 — API Architecture, Service Contracts & Integration Design

**Part B of B** — request sections §13–24 (external integrations, authentication & authorization flow, error model, API versioning, rate limiting, security, observability, testing strategy, open questions, risks, engineering decisions, engineering notes). Part A covered §1–12.

> Evidence tags and the non-negotiable inheritances (ED-14 🔴, ED-13, no-hidden-score, grounding gate) are defined in Part A. This part continues the same series.

---

## 13 External Integrations

Every external dependency sits behind an **Anti-Corruption Layer** (Ch3 ACLs) so a provider swap is an adapter change, not a domain change.

| Integration | Purpose | Pattern | ACL / port | Tag |
|---|---|---|---|---|
| **OAuth / OIDC IdP** | delegated authN (§14) | redirect + code exchange | IdP Adapter (Ch3) | `[PROP]` |
| **SSO (SAML/OIDC)** | enterprise login | per-tenant IdP config | IdP Adapter | `[PROP]` |
| **Email** | invitations, notifications (Ch2 §16) | provider API behind port | Notification Transport Adapter | `[PROP]` |
| **SMS** | optional notification channel | provider API behind port | Notification Transport Adapter | `[PROP]` |
| **Calendar** | interview scheduling (future) | ICS / provider API | — | `[OPEN]` OQ-59 |
| **Object storage** | blobs (Ch4 §12) | S3 API | Storage port | `[PROP]` (local FS `[IMPL]`) |
| **LLM provider** | inference | **Inference Gateway ACL** (ED-16) | Local Ollama `[IMPL]`, remote pool `[PROP]` | `[IMPL]`/`[PROP]` |
| **STT/TTS** | voice (§11) | streaming provider | Voice port | `[PROP]` OQ-64 |
| **Payment** | billing (future) | provider-hosted checkout | Billing ACL | `[OPEN]` OQ-63 |

**ED-48 (integration boundary rule):** no external call is made from domain code; all go through a port with a deterministic fallback where correctness allows (Inference Gateway has `DeterministicFallbackAdapter` `[IMPL]`; notifications queue-and-retry; **there is no fallback that fabricates an identity check or an answer** — those fail loud, Ch3 R-37). **Payment credentials are never entered or stored by CogniHire** — provider-hosted checkout only (aligns with the platform prohibition on handling financial credentials).

### 13.1 SSRF-safe outbound (see also §18)
All outbound integration URLs come from **server-side tenant configuration**, never from a request body or from untrusted content (a resume, an LLM output). An LLM output is data, never a URL to fetch. **R-56.**

---

## 14 Authentication & Authorization Flow

### 14.1 Model
- **Human authN:** delegated to an external OIDC IdP (Ch4 `app_user.idp_subject`; **no password stored** — the `InMemoryAuthStore` password field is a test double only). 
- **Tokens:** short-lived **access JWT** (~15 min `[EST]`) + rotating **refresh token** (httpOnly, secure cookie or secure store). JWT claims: `sub`, `tenant_id`, `roles[]`, `aud`, `exp`, `iat`, `jti`.
- **Service identity:** service-to-service calls use **mTLS + short-lived service JWTs** (SPIFFE-style IDs, OQ-60); the **Disposition Service's credential is held by no evidence-context service** (Ch4 §21.5, contract fence §7.6).
- **AuthZ:** coarse at the gateway (route class), fine-grained in-service via `PermissionResolver` over the RBAC matrix (`lib/core/rbac/**` `[IMPL]`, unwired — Ch4 R-38).

### 14.2 Login + first call (Mermaid)
```mermaid
sequenceDiagram
    participant C as Client
    participant G as API Gateway
    participant I as Identity Service
    participant IdP as External IdP
    participant S as Domain Service
    participant DB as Postgres (RLS)

    C->>G: GET /auth/login
    G->>IdP: redirect (OIDC authz code)
    IdP-->>C: login UI → consent
    C->>G: /auth/callback?code=...
    G->>I: exchange code
    I->>IdP: token endpoint (code→id_token)
    IdP-->>I: id_token (sub, email)
    I->>DB: upsert app_user by idp_subject (RLS via tenant)
    I-->>C: access JWT (15m) + refresh (rotating)
    Note over C,G: subsequent calls
    C->>G: POST /interviews/{id}/answers (Bearer JWT, Idempotency-Key)
    G->>G: verify JWT, extract tenant_id/sub/roles (ED-43)
    G->>S: forward + X-Tenant-Id(signed), traceparent, correlation_id
    S->>S: PermissionResolver: candidate-self? (fine RBAC)
    S->>DB: SET rls.tenant_id; append AnswerSubmitted (outbox)
    S-->>C: 202 {sequence}
```

### 14.3 Refresh & revocation
Refresh rotates (one-time-use; reuse detection ⇒ revoke the family — **R-57** token replay). Logout revokes the refresh family; access JWTs are short enough to not need a blocklist at V1 (revisit with a `jti` denylist if step-up/instant-revoke is required — OQ-61).

### 14.4 WebSocket auth
The WS handshake carries the access JWT; the server validates before `session.ready` and **re-checks candidate-self binding** to the interview. A mid-session token expiry triggers a `token.refresh_required` control message, not a silent drop (§10.5 reconnect).

---

## 15 Error Model

### 15.1 Standard envelope — **ED-49**
```jsonc
{ "error": {
    "code": "interview.claim_not_open",   // stable, namespaced, machine-readable
    "message": "The referenced claim is not currently open.",  // human, non-sensitive
    "correlation_id": "uuid",             // ties to logs/traces (§19)
    "details": [ { "field": "claim_id", "issue": "not_open" } ],  // optional, structured
    "retryable": false
} }
```
`message` is **never** sensitive — no PII, no claim content, no similarity value, no disposition data (same minimisation as notifications). HTTP status + stable `code`; clients branch on `code`, not `message`.

### 15.2 Status usage
`400` validation · `401` unauthenticated · `403` unauthorized (incl. not-your-interview) · `404` (also returned instead of `403` where existence itself is tenant-sensitive — avoids a cross-tenant oracle, **R-58**) · `409` conflict (sequence/idempotency) · `410` gone (ended interview) · `422` domain precondition · `429` rate limited (+ `Retry-After`) · `503` dependency unavailable (cold inference gateway §12.6, lease unavailable).

### 15.3 Retry / timeout / circuit breaker
| Concern | Policy |
|---|---|
| **Retry** | only `retryable:true` (idempotent GET, 503, 429-with-Retry-After); exponential backoff + jitter; **never auto-retry a non-idempotent command without the same Idempotency-Key** |
| **Timeout** | per-dependency budgets: DB 2 s, inference 8 s (gen) / 1 s (embed) `[EST]`, face verify 1.5 s `[EST]`; a timeout is a typed failure, never a silent pass |
| **Circuit breaker** | per-dependency; open ⇒ fail fast with `503` + fallback where correctness allows. **Identity verification and answer submission have NO fabricating fallback** — breaker-open means the interview pauses (Ch2 timeout SM), never proceeds as if verified (Ch3 R-37 / Ch4 R-37 lineage). **R-59.** |

---

## 16 API Versioning

- **Transport:** URL-major (`/v1`, `/v2`) for breaking changes; `Accept: application/vnd.cognihire.v1+json` for minor negotiation.
- **Breaking change** = remove/rename a field, tighten a type, change semantics, remove an endpoint, or add a required request field. ⇒ new major, old major supported through a **deprecation window** (≥ 2 quarters `[EST]`, OQ-62).
- **Non-breaking** = add optional field, add endpoint, add enum value *the client is told to tolerate*.
- **Events:** versioned by `schema_version` + upcasters (Ch4 §9.4, ED-38) — historical events never rewritten, so the hash chain is stable across all API versions.
- **Deprecation:** `Deprecation` + `Sunset` response headers; usage tracked per version (§19) so a version is retired on evidence, not guess.
- **Migration:** dual-run majors; clients migrate endpoint-by-endpoint. **ED-50.**

---

## 17 Rate Limiting

Token-bucket, enforced at the gateway (counters in Redis, Ch4 §15), **layered**:

| Scope | Purpose | Example limit `[EST]` |
|---|---|---|
| **Per tenant** | fairness across customers; blast-radius cap | e.g. 10k req/min |
| **Per user** | abuse/runaway-client protection | e.g. 300 req/min |
| **Per service (internal)** | protect a slow dependency (inference, face) | concurrency cap + queue |
| **Per session (WS/answers)** | pace an interview naturally | burst small, sustained low |

**Burst handling:** short bursts absorbed by bucket depth; sustained overage ⇒ `429 + Retry-After`. **Critical rule (ED-51):** rate limiting **shapes** load, it never causes the system to **skip** a safety step. Under pressure, the interview slows or queues; an identity check is **never** dropped to shed load (Ch4 R-37 — "capacity-driven skipped identity checks are the omission-shaped fabricated pass"). **R-60.** Backpressure on the inference gateway degrades to the deterministic fallback for *non-evidential* text, never for identity or answer capture.

---

## 18 Security — OWASP API Top 10 mapping

| OWASP API risk | Mitigation in this spec |
|---|---|
| **API1 BOLA** (object-level authz) | every read/write re-checks principal↔object binding in-service (candidate-self, workspace membership); `404` not `403` for cross-tenant (§15.2); RLS as backstop (Ch4 §4.2) |
| **API2 Broken authN** | delegated OIDC, short JWT, rotating refresh with reuse detection (§14.3) |
| **API3 BOPLA** (property-level) | strict request decode (reject unknown fields); response DTOs carry only allowlisted fields; **vocabulary ban** blocks score/disposition leakage (ED-46) |
| **API4 Resource consumption** | rate limits (§17), pagination caps, request size limits, inference concurrency caps |
| **API5 Broken function authz** | fine-grained RBAC (`PermissionResolver`); command endpoints check role, not just authN |
| **API6 Unrestricted sensitive business flows** | idempotency + domain preconditions (invitation single-use, immutable role versions, one disposition path) |
| **API7 SSRF** | outbound URLs only from server config, never from body/resume/LLM output (§13.1, R-56) |
| **API8 Security misconfig** | contract-first + CI schema linting; deny-by-default gateway; TLS 1.3 |
| **API9 Improper inventory** | single generated OpenAPI/AsyncAPI catalog; versions tracked; no undocumented endpoint (CI fails on drift) |
| **API10 Unsafe consumption of 3rd-party** | LLM/STT outputs treated as untrusted data (grounding gate; no eval, no fetch-from-output); provider responses schema-validated |

Additional: **Input validation** (schema + domain), **output encoding** (JSON-safe; HTML export sanitised), **replay protection** (Idempotency-Key + JWT `jti`/`exp` + refresh rotation), **CSRF** (SameSite cookies for refresh; bearer tokens for API — not cookie-auth, so CSRF surface is minimal), **request signing** (internal `X-Tenant-Id` header is HMAC-signed by the gateway so a compromised service can't forge tenant context, **ED-43**).

---

## 19 Observability

| Signal | Design |
|---|---|
| **Tracing** | W3C Trace Context (`traceparent`) propagated gateway→service→event; a `correlation_id` spans an entire interview across sync + async hops (Ch4 §9 envelope) |
| **Metrics** | RED per endpoint (Rate/Errors/Duration); per-dependency latency; inference queue depth; projection lag; event-append rate; lease contention |
| **Logs** | structured JSON, **PII-scrubbed** (`lib/core/privacy/scrubber.dart` `[IMPL]`); log carries `correlation_id`, `tenant_id`, `code` — **never** claim content, similarity, or disposition data |
| **Correlation IDs** | the join key across logs/traces/events; the *only* sanctioned way to reconstruct a flow (never by correlating evidence↔disposition — that key is deliberately absent) |
| **Health** | `GET /healthz` (liveness), `GET /readyz` (readiness incl. **inference warm-up** state §12.6, DB, event store, lease store); gateway routes only to ready instances |

**Alert triggers (tie to Ch4 §27):** broken hash chain, projection dead-letter, cross-tenant query attempt, platform-admin path use, breaker-open on identity/answer path, inference cold-start on a live session. **R-61:** an observability pipeline that logged raw answers/claims for debugging would leak the very content the product protects — scrubber is mandatory, and a "verbose/debug" mode may never bypass it.

---

## 20 Testing Strategy

| Layer | What |
|---|---|
| **Contract tests** | generated from OpenAPI/AsyncAPI; provider verifies it satisfies the schema; **CI fails on drift** (the enforcement that makes §1.1's guarantees real) |
| **Consumer-driven contracts** | each event consumer publishes the payload subset it depends on (Pact-style); a publisher change that breaks a consumer fails before deploy |
| **Mock servers** | generated stub servers from the contract for frontend/AI dev without the backend |
| **Integration tests** | end-to-end flows: invite→accept→interview→audit; auth+RLS (cross-tenant returns 0/404); reconnect-resumes-from-sequence; idempotent replay returns stored response |
| **Guardrail regression tests** | **(a)** no schema in the surface carries both an evidence-ref and disposition-ref type (**ED-45**); **(b)** DTO vocabulary-ban linter (**ED-46**) — no score/rank/probability field; **(c)** grounding-gate property test — extraction never returns a claim absent from the resume; **(d)** `VerificationResult.Unchecked` has no similarity field; **(e)** breaker-open on identity path pauses, never proceeds |

These guardrail tests are the point of contract-first here: Ch1's product guarantees become **red builds** when violated, not incidents discovered in production. Existing `[IMPL]` tests already cover the domain-logic side (permissions, route guard, grounding, ML); the `[PROP]` step is lifting them to the contract surface.

---

## 21 Open Questions (continued)

| ID | Question |
|---|---|
| **OQ-59** | Calendar/scheduling integration — in scope for V1, or manual invite links only? |
| **OQ-60** | Service identity scheme — SPIFFE/SPIRE vs. a lighter internal mTLS + JWT? |
| **OQ-61** | Instant access-token revocation (`jti` denylist) — needed at V1, or is 15-min expiry sufficient? |
| **OQ-62** | Deprecation window length for a retired API major? |
| **OQ-63** | Billing/payment provider + whether any billing API is exposed in V1 (BC-13) |
| **OQ-64** | STT/TTS provider — local (privacy) vs cloud (latency/quality); interacts with Ch4 OQ-44 (retain audio?) |
| **OQ-65** | Gateway product — managed (e.g. cloud API GW) vs. self-hosted (Envoy/Kong)? Ties to Ch7 |
| **OQ-66** | Public/partner API — is there an external integration API in V1, or internal-only surface? |
| **OQ-67** | Webhook delivery to customers (interview completed, etc.) — signed webhooks, retry policy? |
| **OQ-68** | Bulk endpoints (import candidates, bulk invite) — batch semantics + partial-failure contract |
| **OQ-69** | Long-running export/report — sync 202+poll vs. async callback/webhook? |
| **OQ-70** | Field-level encryption in transit for biometric payloads beyond TLS (double-envelope)? |

## 22 Risks (continued)

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-51** | Client forging `tenant_id` for cross-tenant access | High | ED-43: tenant derived from token only, signed internal header |
| **R-52** | Reconnect silently restarts interview, losing answers | High | §10.5 resume-from-sequence mandatory; event stream is truth |
| **R-53** | Voice failure drops/omits an answer | High | fall back to text; never skip (§11) |
| **R-54** | Sufficiency model (`isValidatedOnRealData=false`) mistaken for validated | High | provenance flag surfaced in every response until real-data validation |
| **R-55** | Cold inference gateway hangs a live session 40 s | Med | `warmUp()` precondition; cold = 503 not hang (§12.6) |
| **R-56** | SSRF via URL in resume/LLM output | High | outbound URLs from server config only (§13.1) |
| **R-57** | Refresh-token replay | High | one-time-use rotation + reuse detection revokes family |
| **R-58** | Cross-tenant existence oracle via 403-vs-404 | Med | return 404 where existence is tenant-sensitive |
| **R-59** | Circuit breaker "fails open" past an identity check | High | no fabricating fallback on identity/answer path; pause instead |
| **R-60** | Rate-limit shedding skips a safety step | High | ED-51: limiting shapes load, never skips identity checks |
| **R-61** | Debug/verbose logging leaks answers/claims | High | mandatory PII scrubber; debug mode cannot bypass it |
| **R-62** | Contract drift reopens a closed guarantee (score/disposition leak) | High | CI contract tests + linters (ED-45/46) as red builds |

## 23 Engineering Decisions (continued)

| ID | Decision | Trade-off |
|---|---|---|
| **ED-41** | REST (commands/queries) + events (cross-context) + WS (live) + SSE (turn stream); gRPC reserved for inference pool; **GraphQL rejected** | REST/WS efficiency vs. universal tooling + the join stays inexpressible |
| **ED-42** | Idempotency-Key required on all non-GET; two-layer with event-store PK | write-path storage/lookup vs. duplicate-command safety |
| **ED-43** | `tenant_id` derived from token only; signed internal header | no client-supplied tenant; cross-tenant becomes token-forgery |
| **ED-44** | Commands return on durable append (202), not on projection | eventual read consistency vs. write latency + throughput |
| **ED-45** | CI asserts no schema/consumer bridges evidence↔disposition | build-time enforcement of ED-14 at the contract layer |
| **ED-46** | DTO vocabulary-ban linter (score/rank/probability/cross-ref) | heuristic false-positives (allowlist) vs. structural no-hidden-score |
| **ED-47** | WS reconnect = replay-from-sequence; state never socket-only | reconnect cost vs. zero evidence loss |
| **ED-48** | All external calls via ports; deterministic fallback only where correctness allows; **never** for identity/answer | resilience vs. refusing to fabricate |
| **ED-49** | One error envelope; `message` never sensitive; branch on `code` | verbosity vs. leak-proof, stable client contracts |
| **ED-50** | URL-major + header-minor versioning; dual-run majors; events upcast | maintenance of N majors vs. clean migration + stable hash chain |
| **ED-51** | Rate limiting shapes load, never skips a safety step | latency under load vs. no omission-shaped fabrication |
| **ED-52** | Contract-first: OpenAPI/AsyncAPI are source of truth; CI fails on drift | upfront schema rigor vs. guarantees that survive the team |

## 24 Engineering Notes — downstream impact

| Area | Obligation from this chapter |
|---|---|
| **Frontend** | Consumes generated typed clients from the contract; renders states/evidence, **never** synthesises a score the API won't give; handles 202+poll for read-your-writes; WS reconnect with `Last-Event-Seq`; treats `code` (not `message`) as the branch key. |
| **Backend** | Each service implements exactly one BC's contract; commands→outbox events; queries→read models; fine-grained RBAC in-service; **Disposition Service isolated with its own credential**; strict decode everywhere. |
| **AI** | All inference via the Gateway ACL; grounding gate + templated reports as **response post-conditions**; `warmUp()` before live sessions; sufficiency abstains, never scores; outputs are untrusted data (no eval/fetch). |
| **Database** | Contracts map 1:1 to Ch4 stores: commands↔event store, queries↔read models, RLS from the token-derived tenant; the two forbidden joins have no contract path (Ch4 §21.5 ⇄ §7.6/§8.4/§9). |
| **Deployment (Ch7)** | Gateway + N services + event bus + WS tier + Redis; readiness gates on inference warm-up; dual-run API majors; blue/green projections behind stable read endpoints. |
| **Scaling** | Stateless services behind the gateway; per-tenant rate limits cap blast radius; WS tier scales on concurrent sessions (Ch1 §11.2 ~900 `[EST]`); inference concurrency capped with backpressure that **never** sheds a safety step. |
| **Monitoring** | RED + correlation-id tracing; alert on chain break, projection lag, breaker-open on safety paths, cross-tenant attempts, cold-start on live sessions; scrubbed logs only. |

### Appendix 24.A — Series continuity after Chapter 5
| Series | Ch5 range | Next chapter starts at |
|---|---|---|
| Engineering Decisions | ED-41 … ED-52 | **ED-53** |
| Open Questions | OQ-59 … OQ-70 | **OQ-71** |
| Risks | R-51 … R-62 | **R-63** |

### Appendix 24.B — Inherited items this chapter carries or resolves at the contract layer
| Inherited | Handled by |
|---|---|
| Ch3/Ch4 ED-14 🔴 (Evidence↔Disposition) | §7.6, §8.4, §9.1, §12.7, ED-45 (contract-layer fences + CI test) |
| Ch3/Ch4 ED-13 (event sourcing) | §6 commands→outbox events, ED-44 |
| Ch4 ED-43-lineage (tenant on every row) | ED-43 tenant-from-token + RLS |
| Ch3 ED-16 (Inference Gateway ACL) | §12.6, §13, ED-48 |
| Ch3 ED-21 (single-writer lease) | §10.5 reconnect, §5.1 503-on-lease |
| Ch1 "no hidden score" | §7 (never-returns column), §8.5 ED-46 |
| Ch3/Ch4 R-37 (skipped identity check = fabricated pass) | ED-51, R-59, R-60, §11, §15.3, §17 |
| Ch4 R-38 (RBAC unwired) | §14.1 fine-grained RBAC is the wiring target |
| Grounding gate `[IMPL]` | §12.2 as an API post-condition |
