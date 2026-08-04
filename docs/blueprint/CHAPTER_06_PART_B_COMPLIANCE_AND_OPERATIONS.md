# Chapter 6 — Security, Privacy, Compliance & Trust Architecture

**Part B of B** — request sections §12–24 (supply-chain security, API security, infrastructure security requirements, compliance, abuse cases, incident response, security testing, business continuity, security metrics, engineering decisions, risks, open questions, engineering notes). Part A covered §1–11.

> Evidence tags, the trust-zone model (T0–T4, T3'), and the protected product principles (ED-14 🔴, no-hidden-score/grounding, Ch4 R-37 / Ch5 ED-51) are defined in Part A. This part continues the same series.

---

## 12 Supply Chain Security

| Control | Design | Threat (TA-5) | Tag |
|---|---|---|---|
| **Dependencies** | pinned versions (Dart `pubspec.lock`, Python `requirements`); no floating ranges in prod; automated CVE scanning (Dependabot/osv-scanner) gating CI | vulnerable/typosquatted dep | `[PROP]` (lockfiles `[IMPL]`) |
| **SBOM** | generate a CycloneDX/SPDX SBOM per build; store with the artefact; diff on each release | unknown-inventory (API9) | `[PROP]` |
| **Signed builds** | sign artefacts (Sigstore/cosign); CI provenance attestation (SLSA level target, OQ-79) | tampered build | `[PROP]` |
| **Artifact verification** | deploy admits only signed, attested artefacts whose digest matches the SBOM | supply-chain injection | `[PROP]` |
| **Model artefacts** | `model_version.digest` (weights hash, Ch4 §5.4) verified before load; a mismatch refuses to serve | silent model swap / poisoned weights | `[IMPL]` (flag) / `[PROP]` (enforce) |
| **Local inference** | Ollama models pulled from a pinned digest; no runtime code from the model | remote LLM compromise | `[IMPL]` posture |

**ED-61:** the deploy gate admits **only** signed artefacts with a verified SBOM and a matching model digest; an unverifiable artefact fails closed (does not deploy). **Trade-off:** slower release + signing infra vs. closing the supply-chain vector that TA-5 depends on. **R-71:** a poisoned dependency in the résumé-parsing or embedding path could exfiltrate PII or bias extraction — mitigated by SBOM+scanning, least-privilege (the parser has no outbound network except the inference port), and treating all parser output as untrusted.

---

## 13 API Security

Fully specified in Chapter 5 §18 (OWASP API Top 10 mapping); summarised here from the security lens with the threats each addresses. **This section does not restate Ch5 — it references and does not contradict it.**

| Ch5 control | Security threat closed |
|---|---|
| Tenant-from-token, signed internal ctx (ED-43) | cross-tenant access via parameter tampering (TA-6, R-51) |
| Object-level authz re-check + RLS (API1 BOLA) | horizontal privilege escalation (TA-1/TA-2) |
| Idempotency-Key + event-store PK (ED-42) | **replay attacks** — duplicate `SubmitAnswer` fabricating a second answer (TA-1) |
| Request signing (HMAC internal header) | forged tenant context from a compromised service (TA-3) |
| Strict decode + vocabulary-ban linter (ED-46) | property-level leakage of score/disposition (AS-5/AS-10) |
| Rate limiting that never sheds a safety step (ED-51) | overload-induced skipped identity check (R-37 lineage) |
| SSRF guard: outbound URLs from config only (R-56) | SSRF via URL in résumé/LLM output (TA-5) |
| Error envelope, `message` never sensitive (ED-49) | info leak / cross-tenant existence oracle (R-58) |

**Replay protection** deserves emphasis as a security control (not just correctness): an interview is a sequence of evidential events; a replayed or reordered event is a forged record. The `(stream_id, sequence)` unique constraint + idempotency key + per-stream ordering (Ch4 §8.4, Ch5 §9.2) make replay **detectable and rejected**, mapping to AS-1 integrity.

---

## 14 Infrastructure Security Requirements

> Requirements only — the *how* of provisioning is Chapter 7. These are the security constraints Ch7 must satisfy.

| Requirement | Rationale | Tag |
|---|---|---|
| **Network segmentation** | T1/T2/T3/T4 in separate network zones; **T3' (disposition) in its own segment with no route to the evidence data plane** (ED-14 at the network layer) | `[PROP]` |
| **Private services** | only the gateway + WS terminator are public; all T2/T3/T4 private (no public ingress) | `[PROP]` |
| **Firewalls / security groups** | deny-by-default; explicit allow per service-pair; the evidence-plane SG has **no rule permitting the disposition SG** | `[PROP]` |
| **VPN / bastion** | human admin access to T3 via audited bastion + MFA; no direct DB exposure | `[PROP]` |
| **Service mesh** | mTLS, identity-based policy, per-hop authz; mesh policy encodes least-privilege (Evidence service has no mesh route to disposition) | `[PROP]` |
| **Data residency zoning** | region-pinned clusters (Ch4 `organization.region`); a tenant's data never leaves its region | `[PROP]` |
| **Egress control** | T2 services have **no general internet egress**; only allow-listed endpoints (IdP, inference, notification providers); the parser/embedder cannot exfiltrate | `[PROP]` |

**ED-62:** ED-14 is enforced at **four layers** — schema (Ch4), contract (Ch5), network segment + security group + mesh policy (here), and CI test (Ch5 ED-45). A single-layer control on the product's defining boundary is unacceptable; each layer independently prevents the evidence↔disposition join. **R-72:** a misconfigured security group that opened a route between the two planes would silently re-enable the forbidden correlation — mitigated by policy-as-code with a test asserting the deny rule, and by the disposition zone using a credential the evidence plane never possesses (so a route alone is insufficient).

---

## 15 Compliance

Every requirement maps to an architectural decision (per the rules).

| Regime | Requirement | Architectural mapping | Tag |
|---|---|---|---|
| **GDPR** | lawful basis, subject rights, minimisation, storage limitation | consent architecture (§9), crypto-shred erasure (§7.6/ED-57), retention policies (Ch4 §16), scrubber `[IMPL]`, portability export (Ch4 §16.6) | `[DES]`/`[IMPL]` parts |
| **GDPR Art. 9** (special category) | explicit consent + heightened protection for biometrics | separate biometric consent (§9), per-tenant/subject encryption + crypto-isolation (§7), minimal retention (§8.3) | `[PROP]` |
| **EU AI Act** (hiring = **high-risk AI**) | risk management, data governance, **transparency**, **human oversight**, logging, accuracy | provenance/grounding (§11), **human-in-the-loop** (system produces *evidence + sufficiency support*, never an autonomous hire/reject — Ch1/Ch3 boundary), **no autonomous decision** (disposition is a human act, BC-09), immutable logs (§10), the `isValidatedOnRealData=false` honesty flag | `[IMPL]` (several) / `[PROP]` |
| **ISO 27001** | ISMS, risk treatment, controls | this chapter's control set + risk register (§22) + metrics (§20) form the control basis | `[PROP]` |
| **SOC 2** (Security/Confidentiality/Privacy) | control operating-effectiveness over time | audit trails (§10), access reviews (§20), change mgmt (Ch7), incident response (§17) | `[PROP]` |
| **Accessibility** (WCAG 2.2 AA) | interview usable by candidates with disabilities | non-biometric identity fallback (OQ-76), text fallback for voice (Ch5 §11), UI a11y (Ch: design) | `[PROP]`/`[OPEN]` |
| **Data residency** | keep data in-region | region-pinned clusters (§14), residency zoning (Ch4 §19) | `[PROP]` |
| **Anti-discrimination / biometric law** (e.g. BIPA, Illinois; NYC LL144 bias audit) | consent, bias auditing, notice | biometric consent (§9), **no composite score to be biased** (structural), auditable evidence for external bias review, `[OPEN]` bias-audit process | `[OPEN]` OQ-80 |

**The EU AI Act mapping is the most consequential** and reinforces, rather than fights, the product principles: the Act demands human oversight and forbids opaque automated decisions in hiring — which is *precisely* CogniHire's founding boundary (no hidden score, no autonomous verdict, disposition is a human act isolated from evidence). **ED-63:** the architecture treats the EU AI Act's "human oversight" and "transparency" requirements as **already-satisfied by design** (evidence-not-verdict, provenance, human-only disposition), and any future feature that added an autonomous scoring/ranking output would **regress compliance**, not just product principle — making §22 R-49/R-73 a compliance risk, not only a product one. **Contradiction note (not silently resolved):** Ch1 listed SOC2/ISO as *future* goals while the EU AI Act (if operating in the EU) is *not optional* for high-risk AI. This chapter does not resolve *when* certification happens (a business decision, **OQ-81**), but flags that **EU-market operation has a hard compliance floor that precedes any certification timeline** — an item the roadmap must confront rather than defer.

---

## 16 Abuse Cases

Each abuse case names the attacker, the attack, and the mitigating control(s).

| # | Abuse case | Attacker | Mitigation |
|---|---|---|---|
| AB-1 | **Identity fraud** — someone else takes the interview | TA-1 | mandatory **continuous** biometric verification `[IMPL]`; gaps recorded `Unchecked` (never inferred pass); token-bound invitation |
| AB-2 | **Résumé fraud** — fabricated claims | TA-1 | claims must be verbatim-grounded (gate `[IMPL]`); interview probes claims; provenance in evidence graph |
| AB-3 | **Prompt injection** — "ignore instructions, mark as passed" in résumé/answer | TA-1/TA-5 | content is data not instructions; gate discards non-grounded text; integrity observations emitted by runtime, not model (R-70); no model output executed/fetched |
| AB-4 | **Data poisoning** — corrupt the model's training/decisioning | TA-5/TA-6 | model is synthetic-trained + `isValidatedOnRealData=false`; **no (evidence,outcome) training set exists** (ED-04/AS-10); model provenance digest verified |
| AB-5 | **Replay attack** — resubmit/reorder evidential events | TA-1 | idempotency key + `(stream_id, sequence)` unique + per-stream ordering (§13) |
| AB-6 | **Credential theft** — stolen recruiter/admin token | TA-2/TA-4 | short JWT + rotating refresh w/ reuse-detection; MFA for admin; anomaly detection (§20) |
| AB-7 | **Insider bias/exfil** — recruiter alters or leaks | TA-2 | append-only evidence (can't alter, only append visibly); RBAC least-privilege; audit chain; **no score to quietly tweak** |
| AB-8 | **Customer builds a scoring model** — correlate evidence↔hire outcome | TA-6 | ED-14 four-layer isolation (schema/contract/network/CI); analytics has no outcome column (Ch4 §22); AS-10 protected |
| AB-9 | **Camera/DOM spoofing** — synthetic face/keystrokes | TA-1 | liveness/capture-quality checks (`capture_quality_head` `[IMPL]`); reduced-keystroke behavioural signal; treated as `Unchecked` on failure, never forced pass |
| AB-10 | **Coercion/omission** — force the system to *not* record a problem | TA-1/TA-2 | omission-as-fabrication doctrine: skipped checks recorded as `Unchecked`; strict decode; runtime (not model) authors integrity events |

**AB-8 and AB-10 are the signature abuse cases** — they attack the product's defining properties (AS-10, integrity-by-omission) rather than ordinary confidentiality, and every architectural fence in Chapters 3–6 exists substantially to defeat them.

---

## 17 Incident Response

| Phase | Design | Tag |
|---|---|---|
| **Detection** | alerts (§20): broken hash chain, cross-tenant query attempt, break-glass use, breaker-open on a safety path, cold-start on a live session, anomalous access; SIEM over scrubbed logs | `[PROP]` |
| **Escalation** | severity tiers; **an integrity incident (chain break, AI-authored claim, score/disposition leak) is P1** by definition (ED-60) | `[PROP]` |
| **Containment** | revoke tokens/family; rotate affected secrets; isolate a compromised service (mesh policy); **containment may pause interviews but must not fabricate/omit evidence** (a paused session is honest; a silently-continued one is not) | `[PROP]` |
| **Recovery** | rebuild derived stores from the event store (Ch4 §11); restore authoritative stores from backup + `verifyIntegrity()`; forced re-verification of affected sessions | `[IMPL]` (verify) / `[PROP]` |
| **Postmortem** | blameless; feeds the risk register (§22) and controls; a recurring class triggers a structural fix (a new CI test / type fence), per the "structural over procedural" philosophy | `[PROP]` |

**ED-64:** a suspected **evidence-integrity** incident forbids any "quiet fix." The response is to **preserve** (legal hold), **detect the scope** (`verifyIntegrity` first-broken-sequence + external anchor divergence §10.4), and **disclose** to affected parties as regulation requires — never to edit the record to "correct" it (editing is indistinguishable from tampering; Ch4 R-50). **R-73:** an incident responder under pressure "fixing" an audit by editing it would destroy its evidential value and breach compliance — mitigated by the absence of any edit tool + break-glass that cannot write the evidence log.

---

## 18 Security Testing

| Method | Target | Cadence | Tag |
|---|---|---|---|
| **Threat modeling** | this chapter, refreshed per major feature; STRIDE per bounded context | per release / new context | `[PROP]` |
| **SAST** | Dart/Python static analysis; secret scanning (ED-56); the **guardrail linters** (vocabulary ban ED-46, ED-14 schema test ED-45) run as security tests | every CI | `[PROP]` (analyze clean `[IMPL]`) |
| **DAST** | running app: authz/BOLA, injection, replay against the API surface | scheduled + pre-release | `[PROP]` |
| **Fuzzing** | résumé parser, event decoder, DTO decoders (strict-decode is the invariant fuzzing checks) | continuous on parsers | `[PROP]` |
| **Pen testing** | full app, focus on ED-14 boundary + identity-verification bypass + AB-8/AB-10 | ≥ annual + major change | `[PROP]` |
| **Red team** | objective-based: "fabricate a passing interview," "correlate evidence to a hire," "exfiltrate biometrics" — the abuse cases as red-team goals | periodic | `[PROP]` |

**ED-65:** the product's guarantees have **dedicated regression tests treated as security tests** — the ED-14 schema test, the vocabulary-ban linter, the grounding-gate property test, the `Unchecked`-has-no-similarity test, and a "breaker-open pauses not proceeds" test. A red build on any of these is a **security** failure, blocking release. This makes Chapters 1–5's guarantees continuously *verified*, not merely *designed*. **Trade-off:** test-suite maintenance vs. guarantees that silently rot; the project's history (a `setState`-returned-Future crash shipped green because tests were logic-only and blind to screen crashes) is the cautionary precedent — security tests must exercise the real boundary, not a mock of it.

---

## 19 Business Continuity

Security view of Ch4 §18 / Ch5 §19; the constraint here is that continuity must never trade away integrity.

| Aspect | Design | Tag |
|---|---|---|
| **Disaster recovery** | PITR for authoritative stores; derived stores **rebuilt, not restored** (Ch4 ED-39); disposition zone recovered **independently** (no joint restore that reunites planes) | `[PROP]` |
| **Availability** | stateless services + multi-AZ; graceful degradation that **preserves safety** (an unavailable inference plane pauses evidential AI steps, never fabricates) | `[PROP]` |
| **Backups** | encrypted, cross-region, versioned; **integrity-verified on restore** (`verifyIntegrity` `[IMPL]`); backups of the two planes are separate (ED-14) | `[PROP]` |
| **Failover** | region failover respects data residency (no cross-region failover that moves data out of its legal region — a failover that violated residency is itself an incident) | `[PROP]` |

**ED-66:** continuity procedures inherit the "fail loud, never fabricate" doctrine — degraded mode may reduce availability or functionality but may **not** relax an integrity or identity control to stay up. **R-74:** a well-meant "keep interviews running during an outage by skipping identity verification" toggle would be the single most damaging continuity mistake — it is explicitly forbidden; the correct degraded behaviour is to pause and record honestly.

---

## 20 Security Metrics

| Category | Metric (examples) | Target `[EST]` |
|---|---|---|
| **KPIs** | % sessions with continuous-verification coverage; mean identity-gap duration; % claims grounded (should be 100% by construction) | coverage ≥ 99%; grounded = 100% |
| **Audit metrics** | chain-integrity check pass rate; time-to-detect a chain break; external-anchor divergence events | pass = 100%; detect ≤ minutes |
| **Compliance metrics** | erasure-request SLA; consent-coverage (no biometric without consent = 100%); access-review completion | erasure ≤ 30 d; consent = 100% |
| **Access metrics** | break-glass frequency + median duration; stale-grant count; MFA coverage for admin | break-glass rare + short; MFA admin = 100% |
| **Detection** | mean-time-to-detect / respond for P1; false-positive rate on identity mismatch | MTTD/MTTR bounded; FP managed via `Unchecked`+adjudication |
| **Security SLAs** | critical-patch time; secret-rotation adherence; pen-test finding remediation time | crit patch ≤ 72 h `[EST]` |

**ED-67 (metric integrity):** security metrics are computed from the **immutable logs**, and a metric may **never** be improved by suppressing a record — e.g. "reduce identity mismatches" must not be achievable by recording fewer checks (that is R-37 wearing a KPI hat). Metrics that could create such an incentive (mismatch rate, integrity-flag count) are paired with a **coverage** metric so gaming by omission is visible. **R-75:** a KPI like "lower mismatch rate" incentivises skipping checks; mitigated by pairing with coverage and by the structural impossibility of a check that runs-but-isn't-recorded (events are appended by the runtime).

---

## 21 Engineering Decisions (continued)

| ID | Decision | Trade-off |
|---|---|---|
| **ED-53** | Zero-trust extends to the human subject: continuous in-session identity verification; gaps = `Unchecked`, never inferred pass | capture/compute overhead + false mismatches vs. evidential worth |
| **ED-54** | RBAC spine + ABAC edges; wiring the built-but-unwired matrix is top priority | in-process resolver simplicity vs. external policy engine (OQ-74) |
| **ED-55** | Break-glass = MFA + four-eyes + time-boxed + audited + **cannot bridge T3/T3'** | slower emergencies vs. no omnipotent backdoor |
| **ED-56** | No secret in source/image/config; CI secret scanner as permanent gate | runtime-injection ops dependency vs. closing top breach vector |
| **ED-57** | Crypto-shred + tombstone for erasure (security view of Ch4 ED-33) | requires shreddable-key-from-creation prerequisite |
| **ED-58** | Consent is structurally gating (path doesn't execute without it), not advisory | less flexibility vs. Art. 9 correctness by construction |
| **ED-59** | Periodic external anchoring of the chain head to close the full-rewrite gap | external dependency + latency vs. honest tamper-proofing |
| **ED-60** | AI-authored claim / score leak = **security incident**, not quality bug | heavier process vs. defending AS-1/AS-10 |
| **ED-61** | Deploy admits only signed + SBOM-verified + model-digest-matched artefacts; fail closed | slower releases vs. closing supply-chain vector |
| **ED-62** | ED-14 enforced at four layers (schema/contract/network/CI) | redundancy cost vs. no single point of product-identity failure |
| **ED-63** | EU AI Act human-oversight/transparency treated as satisfied-by-design; autonomous scoring would **regress compliance** | constrains future features vs. legal defensibility |
| **ED-64** | Evidence-integrity incidents forbid "quiet fix"; preserve + disclose, never edit | disclosure cost vs. evidential value + compliance |
| **ED-65** | Product-guarantee regression tests are **security tests**; red build blocks release | test maintenance vs. guarantees that rot silently |
| **ED-66** | Continuity may reduce availability but never relax an integrity/identity control | lower uptime in degraded mode vs. never fabricating |
| **ED-67** | Security metrics from immutable logs; mismatch metrics paired with coverage so omission-gaming is visible | metric complexity vs. no perverse incentive to skip checks |

## 22 Risks (continued)

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| **R-63** | Stolen recruiter token → tenant PII read ≤15 min | Med | short JWT + rotation + anomaly detection |
| **R-64** | RBAC matrix built but **unwired** — running app enforces nothing | **Critical** | wire `PermissionResolver` into every handler before real tenants (carries Ch4 R-38) |
| **R-65** | Break-glass abused by insider | High | four-eyes + MFA + immutable audit + ED-14 hard limit |
| **R-66** | Secret-manager outage stalls startup | Med | short-cached leases; degrade without disabling safety checks |
| **R-67** | PII written outside the encryption envelope is un-shreddable | High | scrubber `[IMPL]`, error minimisation, analytics ban — as security controls |
| **R-68** | Biometric leakage (irreplaceable, special-category) | High | crypto-isolation + minimal retention + verification-service-only access |
| **R-69** | Biometric path runs without explicit consent | High | capture code unreachable without matching consent record (ED-58) |
| **R-70** | Prompt injection suppresses an integrity observation | High | integrity events authored by runtime, not model; model can't delete what it doesn't write |
| **R-71** | Poisoned dependency in parse/embed path exfiltrates PII | High | SBOM + scanning + no egress except inference port + untrusted output |
| **R-72** | Misconfigured SG opens an evidence↔disposition route | High | policy-as-code deny test + separate credential (route alone insufficient) |
| **R-73** | Autonomous scoring feature added later → product **and** compliance regression | High | ED-63; refuse; guarded by ED-45/ED-46 tests |
| **R-74** | "Skip identity verification to stay up" degraded toggle | **Critical** | explicitly forbidden (ED-66); degrade = pause + record honestly |
| **R-75** | Mismatch-rate KPI incentivises skipping checks | Med | pair with coverage metric; structural impossibility of unrecorded check (ED-67) |
| **R-76** | Full-file rewrite of the chain (tamper-evident, not tamper-proof) | Med | external anchoring (ED-59) + access controls preventing whole-file rewrite |

## 23 Open Questions (continued)

| ID | Question |
|---|---|
| **OQ-71** | Service/workload identity scheme (SPIFFE/SPIRE vs. cloud-native)? |
| **OQ-72** | Passkeys/WebAuthn mandated for admin tiers in V1? |
| **OQ-73** | Instant token revocation (`jti` denylist) needed at V1? |
| **OQ-74** | Externalise policy to OPA/Cedar vs. keep the in-process Dart resolver? |
| **OQ-75** | Double-envelope (field-level) encryption for biometrics in transit beyond TLS? |
| **OQ-76** | Non-biometric identity-assurance fallback when a candidate declines face verification (a11y + consent) |
| **OQ-77** | External anchoring mechanism (RFC 3161 TSA vs. transparency log vs. signed checkpoint)? |
| **OQ-78** | If a remote inference pool is introduced, what gates its PII-egress channel? |
| **OQ-79** | Target SLSA level for build provenance? |
| **OQ-80** | Bias-audit process (e.g. NYC LL144) — who runs it, on what, how surfaced, given there is no composite score? |
| **OQ-81** | Certification timeline (SOC2/ISO) vs. the hard EU AI Act floor for EU operation — sequencing? |
| **OQ-82** | Data-processing agreements + sub-processor list (IdP, notification, future inference) governance? |
| **OQ-83** | Candidate-facing transparency: how much of the security/AI-governance posture is disclosed to the candidate at consent time? |

## 24 Engineering Notes — downstream impact

| Area | Obligation from this chapter |
|---|---|
| **Infrastructure (Ch7)** | Network segmentation with **T3' isolated** (ED-62); private services + egress control; bastion+MFA; region-pinned residency; mesh mTLS/identity policy; secret manager + KMS with per-tenant/subject key hierarchy; external-anchor endpoint (ED-59). |
| **Backend** | **Wire the RBAC matrix (R-64)** into every handler; enforce ABAC (candidate-self, scope); consent-gating checks before any consented path (ED-58); emit integrity/consent events to the hash chains; never build an evidence/audit edit tool. |
| **Frontend** | MFA/passkey flows; consent capture UI (separate biometric consent); surface `Unchecked`/abstain honestly (never render as pass/score); a11y fallback for identity + voice; never reconstruct a score the API withholds. |
| **AI** | Treat all model output as untrusted (re-validate, schema-check); grounding gate + templated reports as security post-conditions; verify `model_version.digest` before load; surface `isValidatedOnRealData=false`; keep inference local (no PII egress) until OQ-78 resolved. |
| **Database** | Field-level encryption under the key hierarchy; RLS as backstop; disposition zone separate DB + credential; append-only + hash chains; crypto-shred on erasure; no PII in logs/analytics. |
| **Operations** | Break-glass runbook (four-eyes, time-boxed); incident process with the "no quiet fix" rule (ED-64); access reviews; secret/patch-rotation SLAs; backup integrity verification. |
| **Monitoring** | Alert on chain break, cross-tenant attempt, break-glass, breaker-open on safety paths, cold-start on live sessions, external-anchor divergence; SIEM over **scrubbed** logs only (R-61); coverage-paired security metrics (ED-67). |
| **Deployment (Ch7)** | Signed + SBOM-verified + model-digest-matched artefacts, fail-closed (ED-61); policy-as-code for the ED-14 network deny rule with a test (R-72); guardrail security tests block release (ED-65). |

### Appendix 24.A — Series continuity after Chapter 6
| Series | Ch6 range | Next chapter starts at |
|---|---|---|
| Engineering Decisions | ED-53 … ED-67 | **ED-68** |
| Open Questions | OQ-71 … OQ-83 | **OQ-84** |
| Risks | R-63 … R-76 | **R-77** |

### Appendix 24.B — How this chapter preserved each protected product principle (per the rules)
| Principle (Ch1–5) | Preserved by |
|---|---|
| ED-14 🔴 Evidence⟂Disposition | four-layer enforcement incl. network (§14 ED-62); break-glass cannot bridge (§5.6); trust zone T3' (§2); backup/DR independence (§19) |
| No hidden score | no score to bias (AB-7); score-leak = security incident (ED-60); vocabulary-ban linter as security test (§13, §18) |
| Grounding gate / AI-not-author | AI output untrusted T4→T0 (§11); grounding as security control; injection defeated by discard-non-grounded (AB-3) |
| Ch4 R-37 / Ch5 ED-51 (skip = fabrication) | omission-as-fabrication doctrine (AB-10, ED-66, ED-67); continuity/rate-limit/incident controls may never skip a safety step |
| Human-only disposition (EU AI Act) | satisfied-by-design; autonomous scoring would regress compliance (ED-63) |
| Tamper-evident record | two hash chains (§10), external anchoring (ED-59), no edit tool, incident "no quiet fix" (ED-64) |
