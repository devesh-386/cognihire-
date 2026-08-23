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

## Building the Windows recruiter app

`lib/core/config.dart`'s `FACE_SERVICE_URL`/`AI_GATEWAY_URL`/`PORTAL_URL` all
default to `localhost` — correct for `flutter run`/`flutter test` against a
local `service/`+`portal/`, wrong for a build meant to actually be used,
which has neither running locally. A plain `flutter build windows --release`
silently bakes in every localhost default (backend AND the "Create account"
browser handoff) and produces an exe that can never reach anything real (the
same failure mode `portal/.env.production` exists to prevent on the Next.js
side — Flutter has no equivalent env-file split, so every override has to be
passed explicitly, every time, or it's silently wrong). Build with:

```bash
flutter build windows --release --dart-define=FACE_SERVICE_URL=https://api.cognihire.online --dart-define=PORTAL_URL=https://cognihire.online
```

## Local infrastructure (T-MVP) — not what actually runs

`docker-compose.dev-infra-unused.yml` stands up the T-MVP datastore/gateway
stack this repo was originally scaffolded against (Postgres+pgvector, Redis,
MinIO, Caddy — Engineering Blueprint Ch7 Part A §3, ED-68). **The real
backend does not use it**: it talks to a managed Supabase Postgres project
(`service/pipeline/supabase_store.py`) and deploys via
`docker-compose.api.yml` (see `.github/workflows/deploy.yml`). This file is
kept only in case the self-hosted-Postgres path is revisited later — it is
not required to run or develop against this repo today:

```bash
docker compose -f docker-compose.dev-infra-unused.yml up -d      # start the unused stack
docker compose -f docker-compose.dev-infra-unused.yml down -v    # stop and remove volumes
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
`POSTGRES_DISPOSITION_PASSWORD`, `MINIO_ROOT_PASSWORD`). This stack has no CI
coverage — the `compose-smoke`/`disposition-isolation`/`stack-smoke`
workflows that used to test it were removed along with it being unused;
see this section's opening note.
