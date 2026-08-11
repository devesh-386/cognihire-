# CogniHire

Evidence-based AI interview + candidate evaluation platform. AI provides
evidence and analysis; the recruiter makes the final hiring decision.

## Surfaces

- `lib/` — Flutter **recruiter-only** app (dashboard, roles, candidates,
  invitations, interview sessions, reports).
- `portal/` — Next.js **candidate** web app (application, interview code
  entry, device check, interview) plus recruiter web workspace routes.
- `service/` — FastAPI backend (resume processing, AI interview engine,
  grounding gate, email workflow, face verification), deployed on an Azure VM
  behind Coolify at `api.cognihire.online`.
- `infra/` — Supabase migrations/edge functions, Google Form intake
  (Apps Script → `intake-webhook` → auto-invite, "Ticket 21" pipeline),
  reminder scheduler.

Candidate intake is canonical and single-path: Google Form → Apps Script →
`intake-webhook` → Supabase `candidates` → resume processing →
`READY_FOR_INTERVIEW` → auto-invite trigger → `interview_codes.generate()` →
invitation email. Do not add a second intake pipeline — extend this one.

Grounding is enforced in `service/deterministic/grounding.py`: AI may select
claim text, never author it. This module is architecturally isolated from
`service/ai/` and checked by `service/test_architecture_boundary.py` — do not
weaken this boundary.

See `archive/flutter-candidate-code/` for the candidate-facing Flutter code
(enrolment, voice interview, resume pick/analysis) removed when the app went
recruiter-only — candidate experience now lives entirely in `portal/`.

## Local infrastructure (T-MVP)

`docker-compose.yml` stands up the T-MVP datastore/gateway stack locally,
matching the deployment topology in the Engineering Blueprint (Ch7 Part A §3,
ED-68):

```bash
docker compose up -d      # start the full stack
docker compose down -v    # stop and remove volumes
```

| Service | Purpose | Host port | Network |
|---|---|---|---|
| `postgres` | Primary store + pgvector (evidence plane) | 5432 | `evidence` |
| `postgres-disposition` | Disposition store — physically separate (ED-76/ED-14) | 5433 | `disposition` |
| `redis` | Cache / session working set | 6379 | `evidence` |
| `minio` | S3-compatible object storage (API / console) | 9000 / 9001 | `evidence` |
| `caddy` | Gateway + TLS terminator (scaffold config) | 8080 / 8443 | `evidence` |

The `evidence` and `disposition` networks are disjoint: **no service joins
both**, so there is no route between the evidence-plane and disposition stores
(the ED-14 boundary, enforced structurally). Passwords default to dev-only
values; override via a gitignored `.env` (`POSTGRES_PASSWORD`,
`POSTGRES_DISPOSITION_PASSWORD`, `MINIO_ROOT_PASSWORD`). CI smoke tests live in
`.github/workflows/` (`compose-smoke`, `disposition-isolation`, `stack-smoke`).
