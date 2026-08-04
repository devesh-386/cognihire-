# Chapter 7 — Infrastructure, Cloud Architecture, Scalability, DevOps & Operations

**Part B of B** — request sections §13–24 (observability, performance engineering, scalability strategy, reliability, cost engineering, operations, disaster recovery, infrastructure security carry-forward, engineering decisions, risks, open questions, engineering notes). Part A covered §1–12.

> Evidence tags and the three deployment tiers (**T-MVP** single-customer low-cost · **T-SaaS** multi-tenant · **T-ENT** dedicated/on-prem/air-gap) are defined in Part A. The anti-over-engineering rule (ED-68: MVP is one boring box, K8s only when load demands it) governs this part too.

---

## 13 Observability

The four signals, mapped to CogniHire's specific integrity needs (Ch6 §19 alerting is the security view; this is the SRE view).

| Signal | Design | Tier |
|---|---|---|
| **Metrics** | RED per endpoint (rate/errors/duration); USE per resource; domain metrics: concurrent sessions, event-append rate, projection lag, inference queue depth/latency, lease contention, **continuous-verification coverage %** | all (light in T-MVP) |
| **Logs** | structured JSON, **PII-scrubbed** (`scrubber.dart` `[IMPL]`); `correlation_id`+`tenant_id`+`code`; never claim/similarity/disposition content (Ch6 R-61) | all |
| **Tracing** | W3C Trace Context; `correlation_id` spans an interview across sync+async hops (Ch4 §9) | T-SaaS/T-ENT |
| **Dashboards** | golden-signals per service; a **capacity dashboard** (§14); an **integrity dashboard** (chain-verify pass rate, dead-letters, coverage) | T-SaaS/T-ENT |
| **Alerting** | Ch6 §19 triggers: broken hash chain, projection dead-letter, cross-tenant attempt, break-glass, **breaker-open on a safety path**, cold-start on a live session, external-anchor divergence | all (critical subset in T-MVP) |
| **Health checks** | `/healthz` liveness; `/readyz` readiness incl. **inference warm-up state**, DB, event store, lease store (Ch5 §19) | all |

### 13.1 SLIs / SLOs / error budgets — **ED-78**
| SLI | SLO (target `[EST]`) | Notes |
|---|---|---|
| API availability | 99.9% (T-SaaS) / 99.5% (T-MVP single-AZ) | T-MVP is honestly lower — single node |
| Interview session success (start→complete without infra fault) | 99.5% | excludes candidate-abandon |
| Turn latency (answer→next question) | p95 ≤ 1.5s `[EST]` | Ch5 §11 |
| Event-append durability | 100% (no lost/duplicated event) | correctness, not a budget — never "spent" |
| Identity-verification coverage | ≥ 99% of session time | a **coverage** SLO, deliberately, so gaming-by-omission is visible (Ch6 ED-67) |
| Chain-integrity check | 100% pass | integrity is not error-budgeted |

**ED-78:** some SLOs are **not error-budgeted** — event durability, chain integrity, and identity-coverage are correctness/safety properties, not availability trade-offs. You may spend an availability budget to ship faster; you may **never** "spend" integrity. This distinguishes CogniHire's SRE posture from ordinary SaaS where everything is a budget. **Trade-off:** stricter change control around the safety paths vs. the product's entire value.

---

## 14 Performance Engineering

| Lever | Design |
|---|---|
| **Capacity planning** | model from Ch1 §11.2: ~900 concurrent sessions, ~15 gen/s, ~45 embed/s `[EST]`; dashboards track headroom; scale triggers defined per resource (§15) |
| **Load testing** | synthetic interview generator replaying event streams; ramp to 2× target; **run before each tier promotion**; test the *safety-under-load* path explicitly (does an identity check ever get skipped at 2×? must be no) |
| **Caching** | Redis read-through for hot read models (short TTL, event-busted, Ch4 §15); never cache on the write path; never cache across tenants |
| **Autoscaling** | HPA on custom metrics (queue depth, concurrent sessions), not just CPU; inference on GPU util+latency (§9) |
| **Cold starts** | inference warm pool (§9, ED-74); service min-replicas ≥ 2 in T-SaaS so a scale-from-zero never hits a live session; T-MVP accepts occasional cold start (documented lower SLO) |
| **Connection pooling** | PgBouncer/pooler in front of Postgres; per-service pool caps; **RLS GUC set per checked-out connection** (Ch4 §4.2) — pooling must not leak a tenant context between borrowers (**R-83**) |

**R-83 (subtle + important):** transaction-pooling a connection that carries a per-session `SET rls.tenant_id` could serve tenant A's GUC to tenant B's borrowed connection. Mitigation: set the tenant GUC as a `SET LOCAL` inside each transaction (reset at commit), or use session-pooling for RLS-scoped work; a test asserts a borrowed connection never inherits a prior tenant's GUC. This is a **tenant-isolation** bug that lives purely in infrastructure (pooling), invisible at the app layer — exactly why operational architecture is separate (Ch7 §1.2).

---

## 15 Scalability Strategy — the growth path with calculations

The point of this section (and of ED-68): **show that the architecture grows by adding infrastructure, not by rewriting**, and that early tiers are genuinely small.

| Scale | Interviews/yr `[EST]` | Peak concurrent `[EST]` | Infra shape | Key change from prior |
|---|---|---|---|---|
| **1 customer** | ~1–5k | ~5–20 | **T-MVP: one VM + managed Postgres + 1 GPU/CPU** | — |
| **10 customers** | ~50k | ~50–100 | T-MVP-plus (bigger VM) or entry T-SaaS | vertical scale; add Redis HA |
| **100 customers** | ~500k | ~200–400 | **T-SaaS: K8s, service fleet, GPU pool (3–5), Postgres replicas** | horizontal services; managed HA |
| **1,000 customers** | ~5M | ~600–900 | T-SaaS multi-AZ, read replicas, partitioned event store | replicas + partitioning (Ch4 §19) |
| **10,000 customers** | ~50M | ~few-k | T-SaaS multi-region; **shard by tenant_id** (Ch4 OQ-58); dedicated vector/search | sharding + regionalisation |
| **1M interviews/yr** | 1M | ~200–400 | fits comfortably in **100-customer T-SaaS** | — |
| **10M interviews/yr** | 10M | ~few-k | 10k-customer shape | sharding + multi-region |

### 15.1 Worked calculation `[EST]`
10M interviews/yr ÷ (365×8 working-hours ×3600s) ≈ **~950 interviews/hour average**; with a 4× business-hours/timezone peaking factor ≈ **~1.05 interviews/s starting**. At ~20 min each `[EST]`, Little's Law gives concurrent ≈ 1.05/s × 1200s ≈ **~1,260 concurrent** at peak `[EST]`. That is only ~1.4× Ch1's ~900 planning number — so **10M/yr is a low-thousands-concurrent problem, not a hyperscale one**: a few dozen stateless service replicas, a handful-to-low-dozens of GPU workers, a sharded Postgres. This calculation is the antidote to over-provisioning — the honest ceiling is modest.

### 15.2 Architectural evolution (what changes, what doesn't)
- **Never changes:** the domain/event model, ED-14 isolation, the hash chain, RLS, the safety controls. Tier is packaging.
- **Changes by adding, not rewriting:** single Postgres → +replicas → +partitions → +shards; in-process gateway → API GW; pgvector → dedicated vector DB (OQ-45); Postgres FTS → OpenSearch; single inference → pool → multi-region pool.
- **ED-79:** every scaling step in the table was made *additive* by earlier chapters' choices (tenant_id on every row, event sourcing, stateless services, ports/ACLs). Ch1's rule — "MVP decisions must not require a rewrite to scale" — is discharged here with the concrete evolution path. **Trade-off:** carrying tenant_id/event-sourcing/ports from day one is slightly more upfront cost at T-MVP than a naive CRUD app, repaid by never rewriting.

---

## 16 Reliability

| Aspect | T-MVP | T-SaaS / T-ENT |
|---|---|---|
| **High availability** | single-AZ (honest 99.5% SLO) | multi-AZ; min 2 replicas/service; managed-DB failover |
| **Failover** | manual (documented runbook) | automatic DB failover; LB health-based routing |
| **Replication** | nightly + WAL | sync/async replicas; cross-region for DR |
| **Recovery** | restore + rebuild derived (Ch4 ED-39) | same, automated; **derived stores rebuilt from event store, not restored** |
| **Chaos engineering** | n/a | game-days: kill a pod, an AZ, the inference pool, Redis — assert **no fabricated/omitted evidence** results, only degraded availability |

**ED-80:** chaos experiments include a **safety-invariant assertion**, not just availability: when a dependency is killed, the system must **pause honestly** (record `Unchecked`, 503, dead-letter) and **never** produce a fabricated pass or a silent gap (Ch6 ED-66, Ch4 R-37). A chaos run that shows an interview *proceeding* through an inference/verification outage is a **failed** experiment even if availability looked fine. **R-84:** an HA mechanism that "helpfully" retried past a failed identity check to preserve uptime would convert an availability event into an integrity breach — forbidden; retries carry the same Idempotency-Key and never bypass a safety gate.

---

## 17 Cost Engineering

| Cost | Driver | Optimisation | Tier note |
|---|---|---|---|
| **Compute** | service replicas | right-size; scale-to-min off-peak; T-MVP is one box | T-MVP ~tens USD/mo `[EST]` |
| **GPU** | inference workers | **biggest T-SaaS lever**; batch embeddings; warm-pool sized to peak not max; CPU fallback for non-latency-critical; **local Ollama = no per-token API cost** `[IMPL]` | GPU is the dominant variable cost |
| **Storage** | events, blobs, backups | event archival to cold object storage (Ch4 §8.5); lifecycle-tier old blobs; crypto-shred frees nothing but stops growth honestly | grows with interviews |
| **Bandwidth** | media (if voice), exports | CDN for static; signed URLs; voice egress is a real cost (another reason voice is deferred) | voice-dependent |
| **Monitoring** | log/metric volume | sample traces; scrub-then-ship reduces volume; retention tiers | can surprise at scale |

**ED-81:** the **local-inference posture is a structural cost advantage** — no per-token LLM API bill, ever (`[IMPL]`). A GPU worker is a fixed cost amortised across many interviews, not a per-call charge; at 10M interviews/yr this is the difference between a capex-like GPU line and a large opex LLM-API line. **Trade-off:** you operate GPUs (or rent them) vs. paying a provider per token; at CogniHire's volume and privacy needs, self-hosted inference wins on both cost and the air-gap/PII-egress properties. **R-85:** GPU under-utilisation (paying for idle warm workers) at low scale — mitigated by CPU inference at T-MVP and warm-pool sizing to *peak*, not max. **OQ-86:** owned vs. rented GPU for T-SaaS.

---

## 18 Operations

| Practice | Design |
|---|---|
| **Runbooks** | per alert: chain-break, projection-lag, inference-pool-down, DB-failover, break-glass (Ch6 §5.6), tenant-deletion saga (Ch4 §16.7), **migration-order** (Ch4 R-34) |
| **Incident response** | Ch6 §17 — integrity incident = P1; **"no quiet fix"** on the evidence log (Ch6 ED-64) |
| **Maintenance** | rolling, zero-downtime; announced windows for T-ENT; DB maintenance via replicas |
| **Upgrade strategy** | rolling upgrades gated by event `schema_version` compatibility (Ch4 §17); new event kinds behind feature flags until all nodes deploy |
| **Version rollout** | **Blue/Green** for the API tier; **Canary** for inference/model changes (non-evidential traffic first, §9); **Blue/Green projections** for read-model schema changes (Ch4 §11.4) |
| **Blue/Green** | two identical prod stacks; cut traffic at the LB; instant rollback by cutting back |
| **Canary** | 1–5% traffic, watch SLOs + guardrail metrics, auto-rollback on breach |

**ED-82:** **schema/read-model/event changes use the append-only, rebuild-not-rollback discipline from Ch4** — deployments never destructively migrate the event store, read models are rebuilt behind blue/green projections, and a migration's **order** is a release-gate check (Ch4 R-34). **R-86:** an out-of-order or destructive migration could orphan enrolments or break the hash chain — mitigated by the ordered-migration gate + `verifyIntegrity()` post-deploy.

---

## 19 Disaster Recovery

| Aspect | Design | Target `[EST]` |
|---|---|---|
| **RTO** | time to restore service | T-SaaS ≤ 1h; T-MVP ≤ 4h (single-node, honest) |
| **RPO** | max data loss | ≤ 5 min (WAL shipping) for authoritative stores; **0 for committed events** within the CP boundary (Ch4 §23) |
| **Regional failures** | cross-region standby; failover **respects data residency** — never fails a tenant's data into a non-permitted region (Ch6 §19; a residency-violating failover is itself an incident) | region-scoped |
| **Backup validation** | scheduled restore drills; **`verifyIntegrity()` on restored streams** (`[IMPL]`) — a restore with a broken chain = corrupt backup, alert | monthly drill `[EST]` |
| **Recovery drills** | game-day restores; disposition zone restored **independently** (ED-14, never a joint restore) | quarterly `[EST]` |

**ED-83:** DR **rebuilds derived stores, restores only authoritative ones** (Ch4 ED-39): a recovery needs the event store + master data + object store + disposition store; read models/vectors/search are regenerated — shrinking the restore surface and guaranteeing derived data is consistent with the events post-recovery. **Trade-off:** +rebuild time in RTO vs. no read-model/event skew. **R-87:** a residency-violating failover (moving EU tenant data to another region to stay up) trades an availability event for a compliance breach — explicitly forbidden; DR standby is provisioned *within* each residency region.

**Contradiction watch (not silently resolved):** RPO "0 for committed events" (CP event store) can conflict with "fail over instantly to another region" (which for a synchronous-durability store means either cross-region sync latency or a small RPO window). This chapter does **not** claim both zero-RPO *and* instant cross-region failover simultaneously — it flags the tension as **OQ-87** (sync cross-region replication cost/latency vs. accepting a small RPO on regional loss) rather than asserting a free lunch.

---

## 20 Infrastructure Security (carry-forward from Chapter 6)

This chapter **implements** Ch6 §14's requirements; it does not restate or weaken them.

| Ch6 requirement | Infrastructure realisation (this chapter) |
|---|---|
| Network segmentation, **T3' disposition isolation** | K8s namespaces + NetworkPolicy + node separation (ED-69); separate DB even at T-MVP (ED-76); mesh deny (§12) |
| Private services, edge-only public | private subnets; only gateway/WS public (§12) |
| Egress control | T2 egress allow-list, policy-as-code (ED-77) |
| Secrets in a manager, per-tenant KMS keys | external-secrets + KMS via Terraform (§8); never in Git (ED-56) |
| Signed + SBOM + digest-verified artefacts | CI gate fail-closed (ED-70/ED-71) |
| Residency zoning | region-pinned clusters + residency-respecting DR (§19) |
| External anchoring of the chain head | anchoring endpoint (T-SaaS); **internal-only in air-gap** — the documented weaker case (R-77/OQ-84) |
| Mesh mTLS, identity-based policy | service mesh (§12), workload identities (Ch6 OQ-71) |

**ED-84:** infrastructure security controls are **tier-invariant in intent** — T-MVP achieves them more coarsely (host firewall vs. mesh) but **never omits** the isolation-critical ones (ED-14 separation, no-secrets-in-image, encrypted PII). The tier promotion checklist (§7 migration paths) verifies each control carried forward. **R-88:** the highest infra risk is a control silently dropped during a tier migration (e.g. the ED-14 deny rule not recreated when moving MVP→SaaS) — mitigated by the migration checklist + policy-as-code tests that fail if the deny rule is absent.

---

## 21 Engineering Decisions (continued)

| ID | Decision | Trade-off |
|---|---|---|
| **ED-68** | MVP = one boring single-node box (Compose); K8s/mesh/fleet are T-SaaS-only, added on measured need | two ops shapes vs. days-not-weeks, $10s-not-$1000s pilot |
| **ED-69** | Disposition gets its own K8s namespace + NetworkPolicy + node separation | more manifests vs. orchestration-layer ED-14 enforcement |
| **ED-70** | Distroless, non-root, read-only-root, signed, SBOM'd images; deploy fail-closed | build complexity vs. minimal attack surface + supply-chain closure |
| **ED-71** | Product-guarantee regression tests are release-blocking in CI | slower merges vs. guarantees that survive every release |
| **ED-72** | No real candidate PII/biometrics in any non-prod environment | harder repro vs. no special-category data sprawl |
| **ED-73** | One Helm chart, three tier value files | conditional chart complexity vs. three drifting infra codebases |
| **ED-74** | Inference Gateway ACL lets AI infra evolve (local→pool→canary) with no domain change; warm pool | pool ops vs. no cold-start on live sessions, no domain coupling |
| **ED-75** | Voice infra deferred + provider-abstracted; local STT/TTS required for air-gap | feature delay vs. no premature PII-egress channel |
| **ED-76** | Disposition DB is physically separate **even at T-MVP** | a second tiny DB early vs. a later migration that risks the ED-14 join |
| **ED-77** | ED-14 network-deny + T2 egress allow-list are policy-as-code with tests | policy maintenance vs. human can't quietly open the route |
| **ED-78** | Integrity/durability/coverage SLOs are **not** error-budgeted | stricter change control vs. never trading away the product's value |
| **ED-79** | Every scaling step is additive (no rewrite) — discharges Ch1's scale rule | slightly higher T-MVP cost vs. no rewrite ever |
| **ED-80** | Chaos experiments assert a **safety invariant**, not just availability | more elaborate game-days vs. proving outages don't become integrity breaches |
| **ED-81** | Local self-hosted inference as a structural cost + privacy advantage | operate GPUs vs. no per-token bill + air-gap + no PII egress |
| **ED-82** | Append-only, rebuild-not-rollback deploy discipline for schema/events/read-models | more deploy machinery vs. never destructively migrating truth |
| **ED-83** | DR restores only authoritative stores, rebuilds derived | +RTO rebuild vs. no read-model/event skew |
| **ED-84** | Infra security controls tier-invariant in intent; migration checklist verifies carry-forward | coarser MVP controls vs. never dropping an isolation-critical control |

## 22 Risks (continued)

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-77** | Air-gapped anchoring is internal-only (weaker than external notary) | Med | documented, not hidden; internal append-only anchor + removable-media checkpoints (OQ-84) |
| **R-78** | Hotfix bypasses the guardrail gate, reintroducing a score/disposition leak | High | un-skippable guardrails; same gate for hotfix branches (ED-71) |
| **R-79** | Real PII/biometrics copied to staging/preview | High | synthetic/de-identified only in non-prod (ED-72) |
| **R-80** | GPU shortfall stalls interviews under burst | Med | queue+backpressure that slows not skips; GPU autoscale; deterministic fallback (non-evidential) |
| **R-81** | Cloud voice creates a PII-egress channel | Med | voice deferred; local STT/TTS for air-gap (ED-75); gated by OQ-64/78 |
| **R-82** | MVP co-locates disposition DB with shared creds | High | ED-76: separate DB + separate credential even co-located |
| **R-83** | Connection pooler leaks a tenant RLS GUC between borrowers | High | SET LOCAL per-txn / session-pool for RLS; test asserts no GUC inheritance |
| **R-84** | HA retry proceeds past a failed identity check to preserve uptime | **Critical** | ED-80; retries keep Idempotency-Key, never bypass a safety gate |
| **R-85** | GPU idle cost at low scale | Low | CPU inference at T-MVP; warm-pool sized to peak |
| **R-86** | Out-of-order/destructive migration orphans data or breaks the chain | High | ordered-migration release gate + post-deploy verifyIntegrity (ED-82) |
| **R-87** | Residency-violating regional failover | High | DR standby within each residency region (ED-83); forbidden cross-region failover |
| **R-88** | A security control silently dropped during tier migration | High | migration checklist + policy-as-code tests fail if a deny rule is absent (ED-84) |
| **R-89** | Operating two infra shapes (Compose + K8s) causes drift | Med | one Helm chart + a Compose that mirrors it; the domain code is identical, limiting drift to packaging |

## 23 Open Questions (continued)

| ID | Question |
|---|---|
| **OQ-84** | Air-gapped external-anchoring substitute (internal notary vs. periodic signed removable-media checkpoint)? |
| **OQ-85** | Self-host vs. managed GPU inference for T-SaaS (cost/latency/ops)? |
| **OQ-86** | Owned vs. rented GPU capacity model? |
| **OQ-87** | Zero-RPO CP event store vs. instant cross-region failover — accept a small regional RPO, or pay sync cross-region latency? |
| **OQ-88** | Managed Kubernetes provider / cloud selection (or cloud-agnostic)? |
| **OQ-89** | When exactly does T-MVP graduate to T-SaaS (tenant count / load threshold)? |
| **OQ-90** | Multi-region topology: active-active vs. active-passive per residency zone? |
| **OQ-91** | Managed vs. self-hosted for Postgres/Redis/object store at each tier? |
| **OQ-92** | Observability stack choice (OpenTelemetry + which backends)? |
| **OQ-93** | GitOps tool (Argo vs. Flux) and config-repo structure? |
| **OQ-94** | BYOK/customer-managed keys for T-ENT — which KMS integrations? |
| **OQ-95** | Cost ceiling / unit-economics target per interview to guide right-sizing? |
| **OQ-96** | On-prem hardware reference spec for T-ENT/air-gap (GPU, storage, HA)? |

## 24 Engineering Notes — downstream impact

| Area | Obligation from this chapter |
|---|---|
| **Backend** | package as distroless non-root images; expose `/healthz` + `/readyz` (incl. warm-up state); tolerate rolling upgrades + event `schema_version` skew; set RLS GUC as `SET LOCAL` for pooler safety (R-83). |
| **Frontend** | served via CDN; tolerate blue/green cutover + brief read-model lag; WS reconnect across pod restarts (Ch5 §10.5); degrade honestly when a tier is single-AZ. |
| **AI** | run behind the Gateway ACL (local Ollama at T-MVP, pool at T-SaaS); keep warm workers; verify model digest before serve; **local STT/TTS for air-gap**; never a fallback that fabricates identity/answer. |
| **Security** | this chapter *implements* Ch6 §14 — namespaces/NetworkPolicy/mesh for ED-14, egress allow-list, signed+SBOM artefacts, KMS/secrets, residency-respecting DR; migration checklist preserves controls across tiers. |
| **Database** | HA + replicas + partitioning + (later) sharding by tenant_id; **disposition DB separate at every tier** (ED-76); PITR + integrity-verified restores; ordered migrations gated. |
| **Deployment** | GitOps from one Helm chart, three value files; CI gate with release-blocking guardrails; blue/green (API) + canary (model) + blue/green projections (read models). |
| **Operations** | runbooks incl. migration-order + tenant-deletion saga + break-glass; integrity incidents P1 with no-quiet-fix; chaos game-days asserting safety invariants; DR drills with verifyIntegrity. |
| **Future scaling** | the additive path (§15): replicas → partitions → shards → multi-region; pgvector → dedicated; FTS → OpenSearch; single inference → pool → multi-region pool — **all without domain rewrite** (ED-79). |

### Appendix 24.A — Series continuity after Chapter 7
| Series | Ch7 range | Next chapter starts at |
|---|---|---|
| Engineering Decisions | ED-68 … ED-84 | **ED-85** |
| Open Questions | OQ-84 … OQ-96 | **OQ-97** |
| Risks | R-77 … R-89 | **R-90** |

### Appendix 24.B — The three tiers at a glance
| | T-MVP | T-SaaS | T-ENT / air-gap |
|---|---|---|---|
| Orchestration | Docker Compose, 1 VM | managed Kubernetes | dedicated K8s / on-prem |
| Tenancy | single | multi (RLS + crypto) | single, isolated |
| Inference | local Ollama, 1 GPU/CPU | GPU worker pool | on-prem GPU / CPU |
| Datastores | 1 managed Postgres (+ separate disposition DB), single Redis, bucket | HA Postgres + replicas, HA Redis, object store, warehouse | same, customer-controlled / self-hosted |
| Availability SLO | ~99.5% (single-AZ) | 99.9% (multi-AZ) | per contract |
| Cost | ~$10s/mo `[EST]` | amortised multi-tenant | highest per-customer |
| ED-14 isolation | **separate DB + cred (yes, even here)** | namespace+netpol+mesh+DB | fully isolated stack |
| Air-gap | n/a | n/a | **possible (local inference)** |
| Introduced when | first pilot | multiple tenants / load | regulated customer |
