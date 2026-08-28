# CogniHire — API Reference

**Base URL (production):** `https://api.cognihire.online`
**Implementation:** `service/main.py` (FastAPI). **42 routes** — 41 HTTP + 1 WebSocket.
Interactive docs are served by FastAPI at `/docs` when the service is running.

---

## Authentication model

A **default-deny ASGI middleware** (`service/security/access_control.py`) sits in front of every
route. Requests are rejected unless the path appears in an explicit, reviewed `PUBLIC_PATHS` list.

The consequence worth understanding: **a newly added route is private by default.** A developer who
forgets to think about authentication gets a locked door, not an open one. Matching happens on the
ASGI scope rather than on a decorator, so it cannot be bypassed by how a route is declared.

| Class | Auth | Count |
|---|---|---|
| Public | none | apply/intake discovery, OAuth callback, health |
| Authenticated | Supabase JWT; `organization_id` from `app_metadata` | recruiter operations |
| Internal | `INTERNAL_AUTOINVITE_SECRET` header | service-to-service |
| Non-production | `_require_non_production()` | demo/seed only |

Rate limits are applied per route (`service/security/rate_limit.py`).

---

## Health

### `GET /health`
Public. Returns deployment and configuration state.

```json
{
  "status": "ok",
  "git_sha": "a3c1d96...",
  "llm_provider": "openai",
  "engine_available": true,
  "google_token_encryption_key_present": true
}
```

`git_sha` is the deployment freshness signal — the CD pipeline asserts against it twice, so a
container that failed to be replaced cannot report a successful deploy.

---

## Résumé and claims

### `POST /resumes/process`
Rate limit: 20. Runs extraction → structuring → knowledge profile → claims.
Advances `candidate_ai_profile.processing_status`; records `understanding_kind`,
`claim_extraction_kind`, and `degraded_reason` on fallback.

### `POST /extract-claims`
Claim extraction under the grounding gate. Claim text is always a verbatim résumé substring;
negated and hedged statements are rejected. See `MODULES.md` M13.

---

## Candidate intake

| Route | Auth | Purpose |
|---|---|---|
| `GET /roles/open` | public | Roles accepting applications |
| `GET /roles/{role_id}/apply-info` | public | Application form metadata |
| `GET /intakes/{intake_id}/apply-info` | public | Intake-scoped equivalent |
| `POST /candidates/apply` | public | Portal self-registration |
| `POST /intakes/{intake_id}/apply` | public | Intake-scoped application |
| `POST /intakes` | auth | Create an intake channel |
| `GET /intakes` · `GET /intakes/{id}` | auth | List / fetch |
| `PATCH /intakes/{intake_id}` | auth | Update status |
| `POST /intakes/{intake_id}/google-form` | auth | Provision a bound Google Form |

Three further entry points bypass this API and write through Supabase edge functions:
`intake-webhook` (Apps Script push), `intake-form-poller` (pg_cron), `apply-webhook`.

---

## Interview codes and email

| Route | Auth | Purpose |
|---|---|---|
| `POST /interview-codes/generate` | auth | Issue a code |
| `GET /interview-codes` | auth | List |
| `GET /interview-codes/{code_id}/emails` | auth | Delivery state |
| `POST /interview-codes/resend-invitation` | auth | Re-send |
| `POST /internal/candidates/{id}/auto-invite` | internal | Auto-invite on `READY_FOR_INTERVIEW` |
| `POST /email/send-due-reminders` | internal | Called by the pg_cron scheduler |

Codes are single-use with attempt limits, a validity window, and hard expiry. Expiry and revocation
are enforced in database RPCs (migrations `0018`/`0019`), not only in application code.

---

## Interview session

### `POST /interview/start`
Redeems a code and opens a session. **Response is normalised** so that an invalid, expired, and
revoked code are indistinguishable to the caller — closing a code-enumeration oracle identified as a
HIGH finding in the security audit and fixed.

### `POST /interview/answer`
Submits an answer, returns the next question. The next question is selected by
`interview_session.answer()`; no model decides the flow.

### `POST /interview/event`
Appends a client-side event to `interview_events`.

### `POST /interview/finish`
Closes the session and triggers evidence linking.

### `WS /interview/live/{session_id}`
Voice relay to the OpenAI Realtime API. **Origin-checked. 8 MB frame cap.**

`turn_detection.create_response = false` — the Realtime model performs voice activity detection,
speech-to-text and text-to-speech only. It never decides what to say. Every spoken question comes
from the session state machine.

### `GET /interview/report/{session_id}`
The claim audit: per-claim **Claim → Evidence → Verdict** plus explicitly uncovered topics.
Verdicts ∈ `substantiated`, `notDemonstrated`, `contradicted`, `notExamined`.
**No score, no ranking, no recommendation** — `report_generation.py` is deterministic and contains no
code that could produce one.

---

## Face analysis

### `POST /face/analyze`
Rate-limited, 8 MB body cap. **Stateless** — nothing is written.

```json
{
  "engine_available": true,
  "face_detected": true,
  "embedding_available": true,
  "embedding": [512 floats],
  "face_size": 42317,
  "brightness": 128.4,
  "sharpness": 214.7,
  "recommendations": []
}
```

Runs InsightFace `buffalo_l` with `allowed_modules=["detection", "recognition"]`. The pack's bundled
`genderage.onnx` classifier is **never loaded**, so no demographic attribute is inferred.

Returns `embedding: null` — never a zero vector — when it cannot measure. If InsightFace fails to
load, the service still starts and reports `engine_available: false` rather than silently
substituting a heuristic.

⚠️ **Current production use:** the portal consumes only `face_detected`, `engine_available`,
`brightness`, and `sharpness`, and discards the embedding. This is a presence and capture-quality
gate, not continuous identity verification. See `MODULES.md` M8.

---

## Authentication and organisations

| Route | Auth | Purpose |
|---|---|---|
| `POST /auth/signup` | public | Rate-limited. Provisions an org via RPC. |
| `POST /auth/login` | public | **Rate-limited** — closed a brute-force finding |
| `POST /organizations/invites` | auth | Invite a colleague |
| `GET /organizations/{id}/google/connect` | auth | Begin OAuth |
| `GET /organizations/{id}/google/status` | auth | Connection state |
| `GET /google/oauth/callback` | public | OAuth return |
| `POST /internal/google/access-token` | internal | Token for edge functions |

OAuth `state` is signed, expiring, and single-use with a nonce sweep. Tokens are encrypted at rest.

---

## Recruiter data

| Route | Purpose |
|---|---|
| `GET /roles` | Roles in the caller's organisation |
| `GET /candidates` | Candidates, org-scoped |
| `GET /candidates/{id}/resume` | Résumé download — path-traversal-safe filename |
| `GET /interviews` | Sessions |
| `GET /reports` | Completed reports |

All are org-scoped by the tenant key from `app_metadata` and additionally by row-level security.

---

## Demo and development

`POST /demo/seed` · `POST /demo/reset` · `POST /dev/seed-multi-tenant-demo` ·
`POST /dev/seed-tester-account`

All gated behind `_require_non_production()`. Seed data is five fictional candidates at
`@demo.cognihire.test`.

---

## Cross-cutting controls

| Control | Behaviour |
|---|---|
| Default-deny | Unlisted route ⇒ authentication required |
| Rate limiting | Per-route; never skipped under load |
| Upload bounds | 5 MB résumé, 8 MB frame |
| Path traversal | `_safe_download_filename` on résumé downloads |
| CORS | Wildcard origin in production is surfaced as a warning |
| Boot refusal | Service refuses to start in production without `PORTAL_URL` |
| WebSocket origin | Checked on `/interview/live/` |
| Token encryption | Google OAuth tokens encrypted at rest |

---

## Error envelope

Errors return a consistent shape. Authentication failures are normalised so response content does
not distinguish "no such record" from "not yours" — preventing existence disclosure through error
differences.
