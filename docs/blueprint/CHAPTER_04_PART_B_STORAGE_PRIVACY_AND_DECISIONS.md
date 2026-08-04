# Chapter 4 — Data Architecture, Database Design, Event Store & Persistence Model

**Part B of B** — request sections §12–27 (object storage, vector storage, search, caching, data lifecycle, schema evolution, backup & DR, performance, data security, privacy, analytics data model, data quality, risks, open questions, engineering decisions, engineering notes). Part A covered §1–11.

> Evidence tags and the two load-bearing inheritances (**ED-13** event sourcing, **ED-14 🔴** Evidence↔Disposition Separate Ways) are defined in Part A §Preamble. This part physically enforces ED-14 in §21.5 and §22.

---

## 12 Object Storage

S3-compatible, content-addressed, write-once. Key scheme: `s3://cognihire-{region}/{tenant_id}/{data_class}/{sha256}`. Content-addressing gives free dedup and makes an object's key a proof of its bytes.

| Object class | Bucket prefix | Encryption | Retention | Referenced by | Tag |
|---|---|---|---|---|---|
| **Resumes** (PDF/DOCX original) | `/resume/` | per-tenant key (§20.3) | `retention_policy(resume)` | `candidate` / `resumeIngested` event | `[PROP]` |
| **Generated report PDFs** | `/report/` | per-tenant key | policy | read model | `[PROP]` |
| **Exported audit** (HTML/JSON) | `/export/` | per-tenant key | policy | on-demand | `[DES]` (writer to local FS `[IMPL]`) |
| **Screenshots** (integrity evidence) | `/screenshot/` | per-tenant key | policy(evidence) | `integrityObserved` event | `[PROP]` |
| **Attachments** | `/attachment/` | per-tenant key | policy | linking row | `[PROP]` |
| **Audio / video** | `/media/` | per-tenant key | policy | — | **`[OPEN]` OQ-44** — not confirmed in scope; Ch2 kept interviews text+telemetry first |
| **Temp uploads** | `/tmp-uploads/` | per-tenant key | 24 h TTL `[EST]` | staging only | `[PROP]` |

### 12.1 Ownership & lifecycle
Every object has exactly one owning `tenant_id` (in the key path) and one `data_class` governing retention. **Lifecycle:** staged (tmp, TTL) → scanned (AV + parse) → promoted (permanent, referenced) → retained (policy window) → expired (crypto-shred: destroy tenant key access for that object class, or hard-delete). An object is never referenced before promotion; a promotion writes the reference atomically with the domain event.

### 12.8 Temporary uploads
Resumes land in `/tmp-uploads/` first. Only after virus-scan + successful parse (producing a `resumeIngested` event) is the object copied to `/resume/` and the temp reaped. A failed parse leaves nothing referenced; the reaper (24 h) removes orphans. **R-40:** an un-reaped temp bucket is a PII leak surface — reaper is a monitored cron, alert on backlog.

---

## 13 Vector Storage

**pgvector, co-located in Postgres at V1** (avoids a second datastore; §2.5). One logical table, partitioned by embedding purpose.

```sql
CREATE TABLE embedding (
  id                uuid PRIMARY KEY,
  tenant_id         uuid NOT NULL,
  purpose           text NOT NULL,      -- 'claim'|'resume_chunk'|'question'|'working_set'
  source_type       text NOT NULL,      -- what it embeds
  source_id         uuid NOT NULL,      -- FK-by-convention to the source row/event
  model_version_id  uuid NOT NULL REFERENCES model_version(id),   -- §5.4
  vector            vector(768) NOT NULL,   -- dim per model; see §13.5
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_emb_ann ON embedding
  USING hnsw (vector vector_cosine_ops) WHERE purpose = 'claim';
CREATE INDEX ix_emb_source ON embedding (tenant_id, purpose, source_id);
```

| Purpose | Embeds | Used for |
|---|---|---|
| `claim` | a candidate claim | grounding-gate retrieval, semantic dedup of claims |
| `resume_chunk` | a resume passage | mapping a claim to its resume span (provenance) |
| `question` | a question-bank entry | retrieval of relevant follow-ups (Interview Turn Planner) |
| `working_set` | live-session context | Ch2's renamed "session working set" semantic recall |

### 13.1–13.4 Not authoritative
Every vector is **re-derivable** from its source text via the Inference Gateway (ED-16). The vector DB is a *cache of a computation*, never a system of record. Losing it degrades retrieval quality until re-embedded; it loses no truth.

### 13.5 Versioning & re-embedding
Each vector records its `model_version_id`. When an embedding model is upgraded (`model_version.active` flips), old vectors are **not** silently mixed with new ones (cosine distances across model versions are meaningless). Strategy: **shadow re-embed** — compute new-model vectors alongside, cut retrieval over per-purpose once coverage is complete, then retire old vectors. **ED-36.** **Trade-off:** transient double storage + inference cost during re-embed; accepted because mixed-model retrieval silently corrupts provenance. **OQ-55:** re-embed proactively on model change, or lazily on next access?

---

## 14 Search Architecture

**V1: PostgreSQL full-text search** (`tsvector` columns + GIN indexes) over: resume text, `job_requisition.title`/description, `candidate` name/email (tenant-scoped, RLS-enforced). Fully rebuildable from source rows/objects. **At scale: OpenSearch** — deferred (**OQ-45**) until FTS latency on the capacity model (Ch1 §11.2) is shown insufficient. Search is a projection like any other: an index bug is fixed by reindexing, never by mutating source. Search results are **tenant-scoped by the same RLS GUC** — a search must never be the hole that bypasses isolation (**R-41**).

---

## 15 Caching (Redis)

| Cache | Key | TTL | Invalidation | Reconstructable from |
|---|---|---|---|---|
| Session working set | `ws:{stream_id}` | session lifetime + short grace | on `sessionEnded` | replay of stream |
| Single-writer lease (ED-21) | `lease:{stream_id}` | short (renewed) | on release/expiry | re-acquire |
| Read-through hot read model | `rm:{view}:{id}` | 30–120 s `[EST]` | on projection write (pub/sub bust) | Postgres read model |
| Rate-limit counters | `rl:{tenant}:{route}` | window | natural expiry | n/a (ephemeral) |
| Projection checkpoint cache | `ckpt:{proj}` | — | write-through | Postgres `projection_checkpoint` |

**Rule (ED-37):** Redis is **never** the sole copy of anything. A total flush degrades latency and forces lease re-acquisition but loses zero truth. **Invalidation** favours short TTL + event-driven busting over manual invalidation (manual invalidation is the classic correctness bug). **Trade-off:** short TTLs raise DB read load; tuned against the capacity model. **R-42:** a stale read model served from cache after a projection update could show an old interview state — bounded by TTL, acceptable for dashboards, **never** used on the write-path (commands re-read from source, not cache).

---

## 16 Data Lifecycle

Every persistent class flows: **Creation → Modification → Retention → Deletion**, governed by `retention_policy` (§5.4) and `legal_hold` (§5.4).

| Stage | Rule |
|---|---|
| **Creation** | via command → event (behavioural) or INSERT (master). Every row/object gets `tenant_id`, `created_at`, owner. |
| **Modification** | master data: `UPDATE` with `version` guard + `audit_event`. Event-sourced: **never modified** — new event only (§8.3). |
| **Retention** | per `retention_policy.ttl_days` by `data_class`. No class is "forever" by default (Ch1 minimisation). |
| **Deletion** | soft (master, §3.6) or hard/crypto-shred (PII/expiry, §3.7). |

### 16.5 Legal hold
A `legal_hold` row on a subject/scope **suspends all deletion** (retention expiry and GDPR erasure alike) until released. Deletion jobs check for an active hold and skip + log. **R-43:** a GDPR erasure that ignores a legal hold is a compliance violation *in the other direction* — the erasure pipeline must consult `legal_hold` first (§16.6 ordering).

### 16.6 GDPR requests
- **Access / portability:** a read-only export assembled per subject (their `candidate`/`app_user` rows + their event streams, redacted of other subjects). A projection, not a mutation.
- **Erasure (right to be forgotten):** **crypto-shred (ED-33)** — destroy the subject's slice of the per-tenant key (or a per-subject sub-key, **OQ-43**), rendering their encrypted PII (resume bytes, face template, PII fields) permanently unreadable, and append a **tombstone event** to their stream. The hash chain stays intact (the tombstone is a normal appended event); the *encrypted* payloads remain as ciphertext-nobody-can-read. This reconciles "immutable append-only" with "erasure" **without editing history** — the single most important lifecycle decision in this chapter. **Ordering:** check `legal_hold` → if clear, shred key slice → append tombstone → drop soft-deletable master rows.
- **Trade-off:** crypto-shred requires PII to have been encrypted under a shreddable key *from creation* — retrofitting is impossible, so §20.3's per-subject/per-tenant key design is a **prerequisite, not an add-on**. **R-44:** any PII written outside the encryption envelope (a log line, an analytics fact) is un-shreddable — §20.4 and §22 forbid exactly that.

### 16.7 Organization / tenant deletion
Follows Ch3 §20.3's ordered M-steps (a wrong order orphans data — Ch3 R-34). Sequence: place terminal status → stop projections/ingest → crypto-shred tenant key → tombstone streams → drop RLS-scoped rows → destroy the **separate disposition DB** slice (§21.5) independently (no shared transaction — they can't share one; ED-14). **R-45:** because evidence and disposition are separate DBs, tenant deletion is a **two-system saga** with no distributed transaction — forward-recovery + reconciliation report, never a silent partial delete.

---

## 17 Schema Evolution

| Concern | Strategy |
|---|---|
| **Master-data migrations** | expand/contract (add nullable → backfill → enforce → drop old), online, reversible. Standard tool (e.g. sqitch/Flyway — **OQ-56**). |
| **Event schema evolution** | **never rewrite stored events.** Add `schema_version`; upcast on read (Part A §9.4). Old events remain valid forever. |
| **Backward compatibility** | a new consumer must read all historical `schema_version`s (upcasters). |
| **Forward compatibility** | consumers ignore unknown *metadata* fields but **reject unknown payload fields** (strict decode discipline `[IMPL]`) — additive payload changes are a version bump, not a silent field. |
| **Rolling upgrades** | old + new app versions run concurrently; both must handle current event `schema_version`. New event kinds are gated behind a `feature_flag` until all nodes deploy. |
| **Read-model schema change** | blue/green projection (Part A §11.4): build new alongside, replay, cut over — zero downtime. |

**ED-38:** the event store is **append-only across schema versions** — schema evolution never touches historical bytes, so the hash chain is stable across every future migration. This is what makes the tamper-evidence claim durable over years, not just at launch.

---

## 18 Backup & Disaster Recovery

| Aspect | Design | Tag |
|---|---|---|
| **Backup schedule** | Postgres: continuous WAL archiving + nightly base backup. Object store: cross-region replication + versioning. Disposition DB: **its own independent backup** (ED-14 — never a joint backup that reunites the two) | `[PROP]` |
| **Restore** | PITR from base + WAL. Read models/vectors/search **not restored from backup** — rebuilt by replay/reindex (faster and guarantees consistency with the event store). | `[PROP]` |
| **Point-in-time recovery** | to any second within WAL retention. | `[PROP]` |
| **Integrity verification** | after any restore, run `verifyIntegrity()` (`[IMPL]`) across restored streams; a broken chain post-restore = corrupted backup, alert. `audit_event` chain verified likewise. | `[IMPL]` mechanism |

**RPO/RTO targets: OQ-57** (tie to Ch1 availability NFR). **ED-39:** derived stores are *rebuilt, not restored* — a restore only needs the event store + master data + object store + disposition store; everything else is a projection. This shrinks the backup surface and eliminates read-model/event-store restore skew. **Trade-off:** post-restore rebuild adds RTO minutes; accepted for consistency.

---

## 19 Performance

| Lever | Design |
|---|---|
| **Partitioning** | `event`/`event_stream` by `HASH(tenant_id)`; large read models by tenant or time. |
| **Sharding** | not at V1 (single primary within a region). Shard key when needed = `tenant_id` (natural, since no cross-tenant query exists). **OQ-58.** |
| **Indexes** | per §5 (state/time composites on read models; PK ordering on events; HNSW on claim vectors). Index the *read* patterns, not speculatively. |
| **Compression** | archived event JSONL gzip'd in object store; Postgres TOAST for large `jsonb`/`tsvector`. |
| **Archiving** | cold interview streams sealed to object storage (Part A §8.5). |
| **Large object handling** | binaries never in rows — object store + URI reference (§12). `jsonb` payloads bounded; a large blob in a payload is a design error (reduced values only — `[IMPL]` rule). |

Capacity anchor: Ch1 §11.2 (~900 concurrent sessions, ~45 embeddings/s, ~15 generations/s `[EST]`). §8.2 argued Postgres-as-event-store has headroom here; **R-46** tracks event-table write contention under burst (mitigated by per-stream PK, partitioning, and the single-writer lease reducing retries).

---

## 20 Data Security

| Control | Design | Tag |
|---|---|---|
| **Encryption at rest** | Postgres TDE / encrypted volumes; object store SSE with **per-tenant KMS keys**; biometric data additionally app-encrypted per-tenant. | `[PROP]` |
| **Encryption in transit** | TLS 1.3 everywhere, incl. service-to-service and DB connections. | `[PROP]` |
| **Key management** | KMS; one key alias per tenant (`tenant.encryption_key_id`). Per-subject sub-keys for crypto-shred granularity — **OQ-43**. App never holds raw key material; it requests decrypt via KMS with the tenant context. | `[PROP]` |
| **PII** | classified (§21.2); encrypted under shreddable keys; never in logs, URLs, or analytics facts (§22). | `[PROP]`/`[IMPL]` scrubber (`lib/core/privacy/scrubber.dart`) |
| **Secrets** | never in DB rows (commit-history lesson); in KMS/secret manager. `invitation.token_hash` and IdP delegation mean no raw tokens/passwords are stored. | `[PROP]` |
| **Access control** | RLS (tenant) + RBAC (role) + per-context least privilege (Ch3 §21). The disposition DB has a **separate credential** no evidence-context service holds (§21.5). | `[PROP]` |

### 20.3 Per-tenant key & crypto-shred
The key hierarchy is the mechanism behind both G-T2 (crypto tenant isolation) and ED-33 (erasure): PII is encrypted under a tenant key (optionally a per-subject sub-key). Destroying the (sub-)key destroys readability irreversibly. **This design must exist from day one** — retrofitting shreddability onto plaintext PII is impossible (§16.6 trade-off).

### 20.5 Platform-admin cross-tenant path
The only sanctioned cross-tenant reads (support, billing ops) go through an explicit, **heavily audited** `platform_admin` path that sets a special GUC — every such query writes an `audit_event`. Never an ambient bypass. **R-47:** the platform-admin path is the highest-value attack target; MFA + audit + minimal scope.

---

## 21 Privacy

### 21.1 Principles
GDPR-aligned: lawful basis (consent/legitimate interest per data class), **data minimisation** (Ch1), purpose limitation, storage limitation (retention), and the erasure mechanism (§16.6). Data minimisation is enforced in code (`[IMPL]` scrubber, "reduced values only" event rule) not just policy.

### 21.2 PII classification
| Class | Examples | Handling |
|---|---|---|
| **Biometric** (special category) | face template/embedding | per-tenant encrypted; explicit consent; strictest retention |
| **Direct PII** | name, email, resume | encrypted, shreddable, RLS-scoped |
| **Behavioural** | reduced keystroke cadence, timing | pseudonymous; no raw characters ever stored (`[IMPL]`) |
| **Derived** | claims, audit, evidence graph | provenance-bound; lives only in event/evidence side |

### 21.3 Consent
`research_consent` (append-only) gates the **only** path by which any data may enter the analytics/research store (§22). No consent ⇒ no research fact, structurally.

### 21.5 🔴 Physical enforcement of Chapter 3 ED-14

This is the section the whole chapter is built to deliver. ED-14 says Evidence (BC-07) and Disposition (BC-09) are Separate Ways: "NO EDGE. NO KEY. NO SHARED CREDENTIAL." The physical enforcement, in five concrete mechanisms:

1. **Separate database instance.** Disposition lives in its own Postgres instance (`disposition_db`), not a schema or table in the evidence/master DB. There is no network route from an evidence-context service to `disposition_db` and vice versa beyond each context's own service.
2. **No foreign key, no shared identifier of the joinable kind.** The `disposition` table has `tenant_id` and its own `id`, but **no `session_id`, `interview_id`, `candidate_evidence_id`, or `audit_id`**. The command that records a disposition (Ch3 `RecordDisposition`) takes a `CandidateRef` (identity) — never a `SessionRef`/`AuditRef` (Ch3 CR-4). The **column does not exist**, so the join is not merely forbidden, it is inexpressible.
3. **Separate credential.** The disposition service authenticates to `disposition_db` with a credential held by **no** evidence/audit/analytics service (Ch3 §21 least-privilege). An evidence service that tried to read dispositions has no credential to do so.
4. **No shared event subscription.** `DispositionRecorded` is published on the disposition stream with **exactly two consumers, none in BC-07/08/10/13** (Ch3 §12; Part A §9.3). No subscriber consumes **both** an evidence topic and a disposition topic (Ch3 CR-5) — enforced by a CI check on subscription manifests.
5. **No shared backup/restore.** §18 — the two DBs are backed up and restored independently; there is no joint snapshot that reunites them.

> **Why this severity.** The join `evidence ⋈ disposition` is *definitionally* the dataset Ch1 ED-04 refuses to collect (features → hire/reject label = a trainable outcome model, the exact "hidden score" the product exists to not build). ED-14 doesn't *discourage* the join — it makes the join **have no physical path to exist**. Every fence above is redundant on purpose; a single-layer control here is a single point of product-identity failure. **R-48** tracks any future feature request that would require correlating the two — it must be refused at design time, not engineered around.

---

## 22 Analytics Data Model

Columnar warehouse fed by **de-identified, outcome-free** CDC from master data + operational events. Star-ish schema of facts + conformed dimensions.

| Fact / dim | Grain | Contains | Explicitly excludes |
|---|---|---|---|
| `fact_interview` | one interview | tenant, workspace, role_version, state, durations, counts | candidate identity, claims, verdicts, **any hire/reject outcome** |
| `fact_integrity_signal` | one observation | rule_id, counts, timing | observation content, candidate identity |
| `fact_inference_usage` | one AI call | model_version, latency, adapter, purpose | prompt/response content |
| `dim_role_version` | role version | competencies (non-PII) | — |
| `dim_time`, `dim_tenant` | conformed | — | — |

### 22.1 Structural prevention of the prohibited dataset (Ch2 §17.5 hazard + ED-04)
Three enforced rules — **ED-40**:

1. **No outcome column exists in the warehouse.** There is no `hired`, `rejected`, `offer`, `disposition` field on any fact or dimension. The disposition DB (§21.5) is **not a CDC source for the warehouse** — the pipeline has no connection to it. The label half of the (features, label) pair simply never arrives.
2. **No candidate-level evidence in the warehouse.** Facts are aggregate/operational. There is no `fact_claim` or `fact_evidence` carrying per-candidate demonstrated content. The feature half is aggregated below the individual, so even a leaked outcome couldn't be joined to a person's evidence.
3. **Consent gate + de-identification.** Any path that would carry finer-grained data requires `research_consent = granted` (§21.3) **and** de-identification, and even then never crosses with disposition. Recording "candidate hired" as an analytics event — the precise Ch2 §17.5 hazard — is a **forbidden event kind**; the vocabulary ban (Part A §10.6 linter) is reused on warehouse DDL and on the analytics event schema.

> **This is ED-14 and ED-04 meeting in the warehouse.** §21.5 stops the join in the operational plane; §22 stops it being reassembled in the analytics plane. Both are needed — analytics is the classic back door through which a "we'd never join those" system quietly rebuilds the forbidden table. **R-49:** a well-meaning future dashboard request ("show interview scores vs. hiring success") *is* the prohibited dataset in a chart; it must be refused, and this section is the citation for refusing it.

---

## 23 Data Quality

| Dimension | Mechanism |
|---|---|
| **Validation** | strict decode at every boundary (`[IMPL]` codec discipline) — unknown/missing field rejected, never defaulted. DB constraints + CHECKs. |
| **Consistency** | read models reconcilable to the event store by replay; a scheduled **reconciliation job** re-derives a read model into a shadow and diffs (drift ⇒ alert + rebuild). |
| **Duplicate detection** | content-addressed objects (natural dedup); `UNIQUE` constraints on natural keys; claim semantic dedup via embeddings (§13). |
| **Integrity** | `verifyIntegrity()` (`[IMPL]`) run on a schedule across event + `audit_event` chains; first-broken-sequence pinpoints tampering. |
| **Repair tools** | read-model rebuild (Part A §11.4), snapshot discard-and-replay (Part A §7.2), reindex (§14), re-embed (§13.5). **All repairs regenerate derived data from the authoritative event store — no repair ever edits an event.** |

**Repair philosophy (ED-41... no — kept as principle):** every repair tool operates on *derived* data. There is deliberately **no tool that edits the event store or the audit** — because such a tool is indistinguishable from a tamper tool. The absence of an "edit event" utility is a security control, not a missing feature (**R-50** would be *building* one).

---

## 24 Risks (continued)

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-38** | RBAC persistence (`role_assignment`) specified but enforcement is unwired in the running app (inherited gap) | High | wire before any real tenant; CI check that guarded routes import the policy |
| **R-39** | Projection silently skipping a poison event = omission-shaped fabrication | High | halt-and-alert per stream, dead-letter, never skip |
| **R-40** | Un-reaped temp-upload bucket leaks PII | Med | monitored reaper cron, alert on backlog |
| **R-41** | Search index bypassing tenant RLS | High | RLS GUC on all search paths; test that cross-tenant search returns 0 |
| **R-42** | Stale cached read model shown after update | Low | short TTL + event busting; never on write-path |
| **R-43** | GDPR erasure ignoring an active legal hold | High | erasure pipeline consults `legal_hold` first |
| **R-44** | PII written outside the encryption envelope is un-shreddable | High | forbid PII in logs/analytics/URLs; scrubber `[IMPL]`; §22 |
| **R-45** | Tenant delete is a two-system saga (evidence + disposition), no distributed txn | Med | forward-recovery saga + reconciliation report |
| **R-46** | Event-table write contention under burst | Med | partitioning, per-stream PK, single-writer lease |
| **R-47** | Platform-admin cross-tenant path is the top attack target | High | MFA, full audit, minimal scope |
| **R-48** | Future feature requiring evidence⋈disposition correlation | High | refuse at design time; §21.5 is the citation |
| **R-49** | "Scores vs. hiring success" dashboard = the prohibited dataset in a chart | High | forbidden by §22 ED-40; refuse |
| **R-50** | Building an "edit event/audit" repair tool would create a tamper tool | High | such a tool is never built; repairs touch only derived data |

## 25 Open Questions (continued)

| ID | Question |
|---|---|
| **OQ-43** | Crypto-shred granularity: per-tenant key only, or per-subject sub-keys for candidate-level erasure? |
| **OQ-44** | Are audio/video captured at all? (Ch2 kept interviews text+telemetry-first) — gates §12 media class |
| **OQ-45** | When does search move from Postgres FTS to OpenSearch? (latency trigger) |
| **OQ-46** | When does Organization:Tenant become >1:1 (multi-org tenants)? |
| **OQ-47** | Enterprise tier: promote isolation from RLS to schema/DB-per-tenant? |
| **OQ-48** | Cross-tenant users (a recruiter serving multiple client orgs)? |
| **OQ-49** | Credential storage: fully IdP-delegated, or local fallback for SMB tenants? |
| **OQ-50** | Are inference records evidence (disputes) or purely ops telemetry? (drives retention) |
| **OQ-51** | Snapshot cadence (every N events / T seconds)? |
| **OQ-52** | Event-store migration trigger from Postgres to a dedicated log product? |
| **OQ-53** | Hot-window duration before archival, per data-residency region? |
| **OQ-54** | Should correlation/causation IDs be inside the hash boundary? |
| **OQ-55** | Re-embed proactively on model change, or lazily on access? |
| **OQ-56** | Migration tool for master data (Flyway/sqitch/…)? |
| **OQ-57** | RPO/RTO targets tied to Ch1 availability NFR? |
| **OQ-58** | Shard key & trigger when a single regional primary is exceeded? |

## 26 Engineering Decisions (continued)

| ID | Decision | Trade-off |
|---|---|---|
| **ED-29** | Event-source **only** behavioural aggregates; master data is state-stored | Simplicity vs. losing master-data history (accepted; `audit_event` covers admin history) |
| **ED-30** | Event store = **PostgreSQL tables**, not a dedicated product; **shared-schema + RLS + `tenant_id`** tenancy | Lower ops surface & transactional outbox vs. lower raw log throughput; RLS planning overhead |
| **ED-31** | Snapshots are always fall-back-to-full-replay; never trusted without `state_hash` | Storage/worker cost vs. read latency |
| **ED-32** | Read-model DDL linter **rejects score/rank/probability columns** | Name-heuristic false positives (allowlist) vs. structural "no hidden score" |
| **ED-33** | GDPR erasure = **crypto-shred + tombstone**, never event edit | Requires shreddable-key-from-creation prerequisite |
| **ED-34** | Separate `version` (optimistic concurrency) from `schema_version` (semantic) | Two columns, one concept-space; prevents conflation bugs |
| **ED-35** | Transactional **outbox** for reliable event→projection delivery | Extra table + relay vs. dual-write inconsistency |
| **ED-36** | Embedding upgrades via **shadow re-embed**, never mixed-model retrieval | Transient double storage/inference vs. corrupted provenance |
| **ED-37** | Redis is **never** the sole copy of anything | Cache-miss DB load vs. durability simplicity |
| **ED-38** | Event store append-only **across all schema versions**; upcast on read | Upcaster maintenance vs. stable multi-year hash chain |
| **ED-39** | Derived stores are **rebuilt, not restored**; backup covers only authoritative stores | +RTO rebuild minutes vs. no restore skew, smaller backup surface |
| **ED-40** | Analytics warehouse has **no outcome column, no candidate-level evidence, consent-gated de-id**; disposition DB is not a CDC source | Weaker product analytics vs. structural impossibility of the ED-04 dataset |

## 27 Engineering Notes — downstream impact

| Downstream area | What this chapter obligates |
|---|---|
| **API design (Ch: API)** | Commands map to event appends (outbox in same txn); queries hit read models only; every endpoint carries tenant context (sets RLS GUC); **no endpoint can return a score or a disposition-joined-to-evidence** — the data model can't express it, and the API must not synthesise it. |
| **Microservices** | Service boundaries = bounded contexts; the **disposition service owns a separate DB with a separate credential** (§21.5); no service holds both evidence and disposition access. |
| **Infrastructure (Ch7)** | Provision: Postgres (master+events+read+pgvector), separate disposition Postgres, Redis, S3-compatible object store, analytics warehouse, KMS with per-tenant keys, region-pinned clusters (data residency). Backup topology per §18. |
| **AI architecture (Ch5)** | Embeddings persist via §13 (model-versioned, re-embeddable); Inference Gateway calls audited via `inference_request/result`; grounding-gate provenance maps to `resume_chunk` embeddings + claim events. |
| **Deployment** | Rolling upgrades gated by event `schema_version` compatibility + `feature_flag`; blue/green projections for read-model changes (§17). |
| **Monitoring** | Alert on: broken hash chain (`verifyIntegrity`), projection lag/dead-letters, reaper backlog, RLS-bypass test failures, reconciliation drift, cross-tenant query attempts, platform-admin path usage. |
| **Testing** | Property test: replay(events) is deterministic; snapshot state == full-replay state; cross-tenant query returns 0 rows; **a test asserting no schema path links evidence to disposition** (ED-14 regression guard); score-column linter in CI. |
| **Future scaling** | Shard by `tenant_id` (OQ-58); event store → dedicated log (OQ-52); search → OpenSearch (OQ-45); isolation → schema/DB-per-tenant for enterprise (OQ-47). All are **additive** — the tenant-keyed, event-sourced, separated-context model was chosen so none of these requires a rewrite (Ch1's "MVP decisions must not require a rewrite to scale"). |

### Appendix 27.A — Series continuity after Chapter 4
| Series | Ch4 range | Next chapter starts at |
|---|---|---|
| Engineering Decisions | ED-29 … ED-40 | **ED-41** |
| Open Questions | OQ-43 … OQ-58 | **OQ-59** |
| Risks | R-38 … R-49 (+R-50 as a never-build note) | **R-51** |

### Appendix 27.B — Inherited items this chapter resolves
| Inherited | Resolved by |
|---|---|
| Ch1 R-05 (no tenant key on aggregates) | §4 + ED-30 (`tenant_id` everywhere + RLS) |
| Ch3 ED-15 (TenantId physical shape) | §4.2, §20.3 |
| Ch3 ED-14 🔴 (Evidence↔Disposition separation) | §21.5 (five physical fences) + §22 (analytics back-door closed) |
| Ch3 ED-13 (event sourcing) | §7, §8 (durable event store) |
| Ch3 ED-21 (single-writer lease) | §8.4 (PK-guarded concurrency as belt-and-suspenders) |
| Ch2 §17.5 hazard (outcome-as-analytics-event) | §22 ED-40 |
| Ch1 GDPR-vs-immutability tension | §16.6 ED-33 (crypto-shred + tombstone) |
| Ch1 "no hidden score" | §5.5, §10.6 ED-32 (linter), §22 |
