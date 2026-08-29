# CogniHire — Database Schema

**Supabase PostgreSQL** (project `cognihire`, region ap-south-1).
**13 tables, 20 migrations** (`infra/migrations/0000_baseline.sql` → `0019_invitation_rpcs_enforce_expiry.sql`).

Every tenant-bearing table carries `organization_id` and is protected by row-level security.

---

## Entity relationships

```
organizations ─┬─▶ roles ─────────┬──▶ intakes
               │                   │
               ├─▶ candidates ◀────┘
               │        │
               │        ├──▶ candidate_ai_profile   (1:1)
               │        ├──▶ interview_sessions ──▶ interview_events   (1:N, sequenced)
               │        ├──▶ interview_codes ─────▶ interview_code_emails
               │        └──▶ invitations
               │
               ├─▶ organization_invites
               └─▶ google_oauth_connections   (1:1)

app_config  — global key/value, not tenant-scoped
```

---

## Tables

### `organizations`
The tenant root. Every other tenant-bearing row cascades from here.

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | `gen_random_uuid()::text` |
| `name` | text NOT NULL | |
| `created_at` | timestamptz | |

### `roles`
A position being screened for.

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | |
| `organization_id` | text FK → organizations | ON DELETE CASCADE |
| `title` | text NOT NULL | |
| `required_skills` | text[] | default `{}` |
| `desirable_skills` | text[] | default `{}` |
| `notes` | text | |

### `intakes`
An open application channel binding a Google Form to an organisation and role. This binding is why
the intake webhook never has to guess a role from a form title.

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | |
| `organization_id`, `role_id` | text FK | CASCADE |
| `name` | text NOT NULL | |
| `status` | text | CHECK ∈ `draft`,`active`,`paused`,`closed` |
| `google_form_id` | text | resolution key for the webhook |
| `application_url` | text | |
| `last_polled_response_at` | timestamptz | poller watermark |
| `closed_at` | timestamptz | |

### `candidates`
Identity and contact record. **No biometric data.**

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | |
| `organization_id` | text FK | CASCADE |
| `name`, `email` | text NOT NULL | |
| `role_id` | text FK → roles | |
| `intake_id` | text FK → intakes | ON DELETE SET NULL |
| `resume_path` | text | Supabase Storage key |
| `resume_link`, `linkedin_url` | text | |
| `phone`, `years_experience` | text | added migration `0010` |
| `preferred_time` | timestamptz | migration `0007` |
| | | **UNIQUE (`organization_id`, `email`)** — idempotent intake |

### `candidate_ai_profile`
Résumé processing output. **1:1 with `candidates`.** The provenance columns are the notable feature:
any reader of a claim can tell how it was produced and whether the pipeline degraded.

| Column | Type | Notes |
|---|---|---|
| `candidate_id` | text UNIQUE FK | CASCADE |
| `processing_status` | text | CHECK ∈ `UPLOADED`,`TEXT_EXTRACTED`,`STRUCTURED`,`CLAIMS_READY`,`READY_FOR_INTERVIEW`,`FAILED` |
| `resume_text` | text | raw extracted text |
| `skills`, `projects` | text[] | |
| `experience`, `claims` | jsonb | |
| `understanding_kind` | text | CHECK ∈ `hosted_llm`,`local_llm`,`heuristic_rule` |
| `claim_extraction_kind` | text | same closed set |
| `degraded_reason` | text | why a fallback ran |
| `embedding_id`, `error` | text | |
| `claims_truncated` | bool | migration `0017` — truncation is disclosed, not silent |

### `interview_sessions`
One interview run.

| Column | Type | Notes |
|---|---|---|
| `id` | text PK | |
| `candidate_id` | text FK | |
| `status` | text | CHECK ∈ `not_started`,`in_progress`,`complete`,`abandoned` |
| `role_title` | text NOT NULL | |
| `question_plan` | jsonb | held for the session, not treated as a durable record |
| `coverage_state`, `outcomes` | jsonb | |
| `current_topic`, `last_question` | text | |
| `version` | int | migration `0015`, optimistic concurrency |
| `available_minutes` | int | migration `0016`, enforced time limit |

### `interview_events`
**Append-only turn log.** The authoritative interview record.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint identity PK | |
| `session_id` | text FK | CASCADE |
| `sequence` | int NOT NULL | assigned by trigger, migration `0011` |
| `event_type` | text NOT NULL | |
| `payload` | jsonb | |
| | | **UNIQUE (`session_id`, `sequence`)** — no gaps, no reordering |

A database trigger assigns `sequence`, so ordering cannot be corrupted by a racing client.

### `interview_codes`
Candidate redemption codes. **Distinct from `invitations`.**

| Column | Type | Notes |
|---|---|---|
| `code` | text UNIQUE NOT NULL | |
| `candidate_id` | text FK | |
| `role_title`, `required_skills`, `difficulty` | | snapshot at issue time |
| `available_minutes` | int | default 20 |
| `status` | text | CHECK ∈ `active`,`used`,`expired`,`revoked` |
| `max_attempts` / `attempts_used` | int | default 3 / 0 |
| `window_start`, `window_end`, `expires_at` | timestamptz | `expires_at` NOT NULL |
| `session_id` | text FK | set on redemption |

Expiry and revocation are enforced in RPCs (migrations `0018`, `0019`), so revoking a code halts an
interview already in progress rather than only preventing a new one.

### `interview_code_emails`
Delivery state per email type.

| Column | Type | Notes |
|---|---|---|
| `code_id` | text FK | CASCADE |
| `email_type` | text | CHECK ∈ `invitation`,`reminder_1h`,`reminder_30m` |
| `status` | text | CHECK ∈ `pending`,`sent`,`failed` |
| `attempts`, `last_error`, `last_attempt_at`, `sent_at` | | retry bookkeeping |
| | | **UNIQUE (`code_id`, `email_type`)** — one send per type, idempotent scheduler |

### `invitations`
Recruiter-side scheduled invitation with precomputed send times.

| Column | Type | Notes |
|---|---|---|
| `candidate_id`, `role_id` | text FK | CASCADE |
| `code` | text | UNIQUE per organisation |
| `status` | text | CHECK ∈ `scheduled`,`pending`,`accepted` |
| `scheduled_at`, `code_send_at`, `reminder_send_at` | timestamptz | computed at creation |
| `code_sent_at`, `reminder_sent_at` | timestamptz | |
| `expires_at`, `revoked_at` | timestamptz | migration `0018` |

### `organization_invites`
Invites a colleague into a recruiter organisation. Single-use, hashed, expiring.

### `google_oauth_connections`
Per-organisation Google authorisation. **1:1 with `organizations`.**

| Column | Type | Notes |
|---|---|---|
| `google_account_email` | text NOT NULL | |
| `access_token`, `refresh_token` | text NOT NULL | **encrypted at rest** — `service/security/token_crypto.py` |
| `token_expires_at`, `scope` | | |

### `app_config`
Global key/value (e.g. gateway URL). Not tenant-scoped.

---

## Security model

**Row-level security** is enabled on every tenant-bearing table. Policies scope reads and writes by
`organization_id`.

**Tenancy source.** `organization_id` is read from Supabase **`app_metadata`**, not `user_metadata`
— migrations `0012` and `0014`. This matters: `user_metadata` is client-writable, so a tenant key
stored there could be forged by the client. `app_metadata` is server-controlled.

**Service-role writes.** The intake webhooks write with the service role and bypass RLS by design —
an unauthenticated applicant has no session to scope against. Those functions are the only
service-role writers.

**RPC-enforced invariants.** `generate()`, `get_redeemable_invitation()`, `accept_invitation()`, and
`provision_organization()` carry expiry and revocation checks in the database, so application code
cannot bypass them.

**A hard-won detail** (`evidence/ticket-012`): `provision_organization` remained executable by the
anonymous role after an apparent revoke, because PostgreSQL grants `EXECUTE` to `PUBLIC` by default
on new functions and revoking from `anon` alone does not remove it. The fix revokes from `PUBLIC`.

---

## Migration history

| # | Migration | Change |
|---|---|---|
| 0000 | baseline | 11 initial tables + RLS |
| 0001 | candidate_ai_profile | résumé processing output |
| 0002 | candidate_resume_trigger | auto-process on résumé upload |
| 0003 | interview_sessions | session state |
| 0004 | interview_code_emails | delivery tracking |
| 0005 | app_config_gateway_url | runtime config |
| 0006 | canonical_auto_invite_pipeline | single intake path |
| 0007 | candidate_preferred_time | |
| 0008 | intakes | Form binding |
| 0009 | google_oauth_connections | per-org OAuth |
| 0010 | candidate_contact_fields | phone, LinkedIn, experience |
| 0011 | interview_events_sequence_trigger | ordering guarantee |
| 0012 | auth_org_from_app_metadata | **tenancy hardening** |
| 0013 | organization_invites | team invites |
| 0014 | provision_organization_app_metadata | signup chicken-and-egg |
| 0015 | interview_sessions_version | optimistic concurrency |
| 0016 | interview_sessions_available_minutes | enforced time limit |
| 0017 | candidate_ai_profile_claims_truncated | disclose truncation |
| 0018 | invitations_expiry_and_revocation | **security** |
| 0019 | invitation_rpcs_enforce_expiry | enforce in DB, not app |

---

## What is deliberately absent

| Absent table | Why |
|---|---|
| `face_embeddings` | Biometric templates are never stored. `/face/analyze` is stateless. |
| `interview_audio` | Voice is relayed, never persisted. |
| `keystroke_events` | Process telemetry is not captured in production. |
| `candidate_scores` | No composite score exists. A CI vocabulary ban fails the build on one. |
| `hiring_outcomes` | No outcome labels anywhere — nothing for a model to learn bias from. |

These absences are load-bearing. Adding any of them would require a migration that a reviewer would
see, which is the point.
