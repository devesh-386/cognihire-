# cognihire

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

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
