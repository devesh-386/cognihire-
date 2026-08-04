# CogniHire — Architecture Validation Checklist

**This is the architecture gate. Every pull request must pass it before merge.** Each question maps to a load-bearing decision; a "yes" to any red-flag question blocks the merge until resolved (or a new ADR is written and reviewed). Where a check can be automated, the enforcing test is named — those run in CI (ED-45/ED-46/ED-52/ED-65/ED-71). The rest are reviewer judgement.

---

## The nine questions

### 1. Does this violate ED-14 (Evidence ⟂ Disposition)? 🔴
- Does any new schema, DTO, event payload, table column, or function signature let an **evidence/audit/session reference** and a **disposition reference** be held or joined together?
- Does any service gain a credential or network route to *both* the evidence plane and the disposition store?
- Does any consumer subscribe to *both* an evidence topic and a disposition topic?
> **Automated:** ED-45 CI schema/consumer test · ED-77 network-policy test. **If yes → block.** ED-14 is the product's defining boundary; this is not negotiable without a documented, reviewed reversal (which would also regress EU AI Act compliance, ED-63).

### 2. Does it introduce a score? 
- Any new field/column/DTO property named or typed as a composite `score`, `rating`, `rank`, `probability`, `fit`, `percentile`, or an aggregate/weight over the evidence graph?
- Any read model or API response that orders candidates into a total ranking?
> **Automated:** ED-32 read-model DDL linter · ED-46 DTO vocabulary-ban linter. **If yes → block** (allowlist a genuine UI sort only with reviewed justification). See ED-03.

### 3. Does it bridge Evidence ↔ Disposition through analytics or a back door?
- Does any analytics fact, CDC pipeline, log line, or export carry a **hire/reject outcome** alongside candidate-level evidence?
- Does the disposition store become a source for the warehouse?
> **Automated:** ED-40 analytics-schema check. **If yes → block.** The (evidence, outcome) join *is* the dataset ED-04 refuses to collect (R-14/R-49).

### 4. Does it violate a Chapter 1 product boundary?
- Does it make CogniHire produce an **autonomous hire/reject decision** (vs. evidence + human disposition)?
- Does it collect **hire/no-hire outcome labels** anywhere (ED-04)?
- Does it infer or reference candidate **affect/emotion** (FR-4.6)?
- Does it add **cross-session same-candidate memory** without an explicit reasoned decision (OQ-22)?
> Reviewer judgement against [Chapter 1 §15 boundaries](CHAPTER_01_PRODUCT_VISION_AND_SCOPE.md). **If yes → block or require an ADR.**

### 5. Does it introduce a new AI output without grounding / validation?
- Does an AI/LLM output become part of the **evidential record** without passing the grounding gate (verbatim-present) or a schema post-condition?
- Does the model **author** claim text (vs. select/decompose)?
- Is a model output **executed, or used as a URL to fetch** (SSRF)?
- Is a synthetic-only model's `isValidatedOnRealData=false` provenance **surfaced**?
> **Automated:** grounding-gate property test (ED-65). **If yes → block.** See ED-02/ED-17/ED-60, R-54/R-56/R-70.

### 6. Does it bypass the audit / event log?
- Does it mutate an aggregate **without emitting an event** through the outbox (ED-13/ED-22/ED-35)?
- Does it **edit or delete** an event or a compiled audit (vs. append a compensating event)?
- Does it build a tool that can rewrite the event log or audit (R-50)?
- Does it record a safety step (identity check) as anything other than an appended event — i.e. could a check run **without being recorded** (R-37)?
> Reviewer judgement + `verifyIntegrity()` in tests. **If yes → block.** Append-only is how tamper-evidence survives.

### 7. Does it require a new ADR?
- Does it make a decision with a lasting trade-off, choose between real alternatives, or resolve/contradict an earlier decision?
- Does it **contradict** any existing ED? (Contradictions are documented and resolved explicitly — never silently.)
- Does it add to the **Shared Kernel** (ED-28 — additions require an ADR + size check, R-29)?
> **If yes →** write the ADR as **ED-85+**, add it to [Appendix A](APPENDIX_A_DECISION_REGISTER.md) in the same PR, and note any superseded ED.

### 8. Does it affect tenant isolation?
- Is `tenant_id` present on every new table, derived from the **token** (never the body/path, ED-43)?
- Are new queries **RLS-scoped** and inexpressible without a tenant context (ED-15)?
- Could a connection pooler leak a tenant's RLS GUC between borrowers (R-83 — use `SET LOCAL`/session-pool)?
- Does any new admin/reporting/search path bypass tenant scoping (R-31/R-41)?
> **Automated:** cross-tenant-returns-0/404 integration test. **If yes → block.**

### 9. Does it create a new data-retention or privacy obligation?
- Does it store new **PII or biometric** data? Is it encrypted under a **shreddable** per-tenant/subject key (ED-33/ED-57) — i.e. can it be crypto-shredded on erasure?
- Does it write PII **outside the encryption envelope** — a log line, an analytics fact, an error message (R-44/R-67)?
- Does it have a **retention policy** row and a deletion path (Ch4 §16)?
- Does new data capture require **explicit consent**, and is the path structurally gated on it (ED-58)?
- Does it move data across a **residency** boundary (Ch6 §14)?
> Reviewer judgement + scrubber coverage. **If yes → require the retention policy + consent gate + encryption before merge.**

---

## Quick gate (paste into the PR template)

```
Architecture Validation (block on any 🔴):
- [ ] 1. Does NOT violate ED-14 (evidence⟂disposition) 🔴
- [ ] 2. Introduces NO composite score/rank/probability
- [ ] 3. Does NOT bridge evidence↔outcome via analytics/back door 🔴
- [ ] 4. Respects Chapter 1 boundaries (no autonomous verdict, no outcome labels, no affect)
- [ ] 5. Any AI output is grounded/validated; model does not author evidence
- [ ] 6. Does NOT bypass or edit the audit/event log (append-only)
- [ ] 7. New/《contradicting》decisions have an ADR (ED-85+) added to Appendix A
- [ ] 8. Tenant isolation intact (tenant_id from token, RLS-scoped)
- [ ] 9. New PII/biometric data is shreddable, consented, retention-policied, in-envelope
```

## Escalation

- A checklist item that is **arguable** (not a clear yes/no) → require an ADR (question 7) rather than a judgement call in review comments.
- A checklist item that a change **must** violate for a legitimate reason → that reason is a product/architecture decision above the PR's pay grade: **write the ADR, get it reviewed, update the register**, then merge. The checklist never "waives" a red flag informally — it converts it into a documented decision.

> The value of this gate is that the guarantees in Chapters 1–6 stop depending on anyone *remembering why they exist*. Questions 1, 2, 3, 5, 6, 8 are substantially automated as red builds; the checklist is what catches the rest before they become the incident that a later chapter has to explain.
