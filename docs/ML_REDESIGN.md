# CogniHire — ML-First Redesign

**Document type:** architecture + research design
**Status:** design proposal (nothing below is implemented yet)
**Date:** 2026-07-28
**Scope:** converts CogniHire from a deterministic evidence-collection app into a
machine-learning system whose learned component is *evidence sufficiency*, not
candidate quality and not deception.

---

## 0. Reading this document

**Citation discipline.** Section 11 names research areas and well-known method
families. It does **not** contain paper titles, author lists, venues, years, or
numeric results, because those cannot be verified from inside this repository.
Every citation must be fetched and read before it enters a report, a paper, or a
mentor brief. This rule exists because fabricated primary research has already
been caught in this project once.

**Honesty about the starting point.** The claims about the current system below
were read out of the source, not assumed:

| Fact | Evidence |
|---|---|
| Claims are hardcoded, not extracted | [main.dart:85](../lib/main.dart:85) seeds `Claim(skill: 'React')` etc. |
| Telemetry is buffer-length deltas, not keystrokes | [process_telemetry.dart:66](../lib/core/telemetry/process_telemetry.dart:66) `record(int newLength)` |
| Follow-ups are threshold rules | [followup.dart:59](../lib/core/interview/followup.dart:59) 5 s / 30 s constants |
| Claim status is set by the reviewer, not the system | [claim_audit.dart:150](../lib/core/claims/claim_audit.dart:150) `reviewerAssessments[claim.id] ?? notDemonstrated` |
| Identity threshold is admitted-uncalibrated | [identity_matcher.dart:36](../lib/core/verification/identity_matcher.dart:36) "reasoned starting point, NOT a validated one" |
| A scalar risk score already exists | [integrity_tracker.dart:39](../lib/core/integrity/integrity_tracker.dart:39) |

That last row matters: `IntegrityTracker` is the one component in the codebase
that already violates the project's stated philosophy. It produces an opaque
0–100 "risk score" from hand-set weights (`identityMismatch: 20`,
`additionalPerson: 15`, …) with a `+2` compounding penalty. That is a
cheating-probability proxy with the serial numbers filed off. The redesign
deletes it. See §2.9.

---

## 1. The one-sentence thesis

> CogniHire learns **how much evidence a session has accumulated for a specific
> technical claim, and which question would most increase it** — and it never
> learns anything about the candidate's worth or honesty.

The learned quantity is a property of *the interview*, not of *the person*. That
single reframing is what makes this an ML project that is also compliant with
the philosophy, and it is the source of the research contribution in §11.

**Formally.** For claim $c$ with session state $s_t$ at turn $t$, learn

- $f_\theta(c, s_t) \rightarrow$ evidence sufficiency $\in$ {Strong, Moderate, Weak, Insufficient} + calibrated uncertainty
- $g_\phi(c, s_t, q) \rightarrow$ expected sufficiency gain $\Delta \hat{E}$ if question $q$ is asked next
- $\pi(s_t) = \arg\max_q\ g_\phi(\cdot) - \lambda \cdot \text{cost}(q)$

Neither $f$ nor $g$ has "hire", "reject", "cheat", or "score" anywhere in its
label space. $f$ measures the *interview's* completeness. $g$ measures a
*question's* usefulness. Humans read $f$'s explanation and decide.

---

## 2. Module-by-module: current → target

Each entry: what exists now, the verdict (Rule / ML / DL / NLP / Hybrid), the
justification, the redesign, and its edge in the ML pipeline.

### 2.1 Face enrolment & embedding — `face_engine.dart`, `service/`

**Now.** Flutter calls a FastAPI service that runs InsightFace `buffalo_l` to
produce a 512-d embedding. `AppConfig.minEnrolmentFaceSize = 15000` px² gates
acceptance.

**Verdict: Deep Learning (keep, do not retrain).**

**Justification.** This is already a DL module — a pretrained ArcFace-family CNN.
Retraining face recognition on a B.Tech dataset would be strictly worse than the
pretrained model and would introduce demographic bias the project cannot audit.
The *research* contribution is not the encoder; it is what is done with the
embedding stream downstream (§2.3).

**Redesign.** Keep the encoder frozen. Add a small learned **capture-quality
head** (§4.11) that replaces the `15000` constant: a 6-feature logistic
regression predicting "will this capture yield a stable embedding?" from face
area, blur (Laplacian variance), yaw/pitch estimate, exposure, and detector
confidence. Trained on self-supervised labels — a capture is "good" if its
embedding's cosine to the enrolment centroid is stable across ±3 neighbouring
frames. Zero human annotation required.

**Pipeline edge.** Emits `E_face[t] ∈ ℝ^512` + `q_capture[t] ∈ [0,1]` into the
identity-continuity model and the multimodal fusion layer.

---

### 2.2 Identity matching — `identity_matcher.dart`

**Now.** Cosine similarity vs. a single enrolment embedding, hard threshold
`rawThreshold = 0.50`, `strikesAllowed = 3`. The file's own doc comment states
the threshold is unvalidated.

**Verdict: Hybrid — keep cosine, learn the decision boundary.**

**Justification.** Cosine on a normalised embedding space is the *correct*
metric and must not be replaced by a learned similarity — that would discard the
encoder's training objective. But a **global constant threshold is the wrong
decision rule**, and the code says so. Threshold selection is exactly the kind
of thing that should be learned, because the optimal boundary depends on capture
quality, session illumination, and within-session variance — all measurable.

**Redesign — Adaptive Verification Threshold (§4.2).** Replace the constant with
a calibrated per-session boundary:

1. During enrolment + warm-up, collect $k \geq 12$ embeddings of the candidate.
2. Compute the **within-session self-similarity distribution** $S_{\text{self}}$
   (all pairwise cosines among the candidate's own captures).
3. The decision boundary becomes $\mu_{\text{self}} - z \cdot \sigma_{\text{self}}$,
   with $z$ learned once offline on a labelled same/different-person set, and
   modulated by $q_{\text{capture}}$.
4. If $\sigma_{\text{self}}$ is too wide (bad lighting, moving candidate), the
   model returns **`Unchecked`**, not a mismatch. Unknown beats incorrect.

This directly fixes the flagged calibration problem *and* it is a legitimate ML
contribution: per-session adaptive biometric thresholding conditioned on capture
quality, evaluated with FAR/FRR curves.

**Pipeline edge.** Emits `identity_confidence[t]` and `identity_coverage` into
the sufficiency model as a **provenance gate**: if provenance is `none` or
`sparse` ([claim_audit.dart:74](../lib/core/claims/claim_audit.dart:74)), the
sufficiency model is *hard-capped* at "Insufficient" regardless of every other
feature. That is a rule, deliberately, and §2.10 explains why.

---

### 2.3 Continuous verification loop — `verification_session.dart`

**Now.** Polls the face service on an interval; counts consecutive mismatches.

**Verdict: ML (new) — identity continuity as a sequence model.**

**Justification.** Independent per-frame comparisons throw away the strongest
available signal: *the shape of the similarity time series*. A person who leans
out of frame produces a different trajectory from a person who is replaced. A
frame-independent threshold cannot distinguish them; a sequence model can, and
this is measurable without ever labelling anyone as a cheater.

**Redesign.** A 1-layer **GRU** (or a 4-head temporal Transformer if sequence
length permits) over the per-poll vector
`[cos_to_centroid, q_capture, Δt, face_count, embedding_drift]`, trained to
predict **the next similarity value** (self-supervised forecasting). The
residual $|s_{t+1} - \hat{s}_{t+1}|$ is the continuity signal. Large residual =
"the identity stream did something unmodellable" = **request a re-verification
capture**, never "flag the candidate".

**Pipeline edge.** `continuity_residual[t]` → adaptive interview planner as a
trigger to insert an identity checkpoint before the next high-value question.

---

### 2.4 Resume → claims — currently absent

**Now.** Non-existent. `resume_upload_card.dart` accepts a file;
[main.dart:85](../lib/main.dart:85) hardcodes three demo claims.

**Verdict: NLP (new) — the largest single addition.**

**Justification.** This is the module that makes CogniHire an NLP project rather
than a Flutter app with an ML sidecar. It is also the module where the "no
regex" instruction is technically correct for a real reason: resume claims are
*compositional* ("reduced p99 latency 40% by rewriting the batch scheduler in
Go") — the technology, the artefact, the metric, and the attributed agency are
four separate spans with typed relations between them. Regex extracts keywords;
it cannot extract *who did what to what, with what effect*.

**Redesign — the Claim Extraction Stack (§4.1):**

```
resume text
   └─ segmentation (rule: line/bullet structure — deterministic, keep)
        └─ claim-bearing sentence classifier   [MiniLM + linear head]
             └─ span extraction (BIO tagging)  [DeBERTa-v3-base token classifier]
                  entities: TECH · ARTEFACT · ROLE · METRIC · SCALE · DURATION
             └─ relation extraction             [same encoder, entity-pair head]
                  relations: BUILT · USED · IMPROVED · LED · CONTRIBUTED_TO
             └─ agency classifier               [3-class: sole / team / ambiguous]
             └─ verifiability head              [regression: how testable is this claim?]
        └─ normalisation (rule: tech-alias table — deterministic, keep)
        └─ deduplication/clustering [Sentence-Transformer embeddings + HDBSCAN]
   → structured Claim{text, tech[], artefact, metric, agency, verifiability, span_offsets}
```

**Why DeBERTa-v3-base and not an LLM as the primary extractor.** An LLM is used
as a *teacher* (§5.2) and as a *fallback*, never as the deployed extractor,
because: (a) the deployed model must be reproducible for a paper — an API model
that silently changes version invalidates every reported number; (b) the
extractor must return **character offsets into the original resume** so every
claim is clickable back to the candidate's own words (the evidence-first rule),
and LLMs hallucinate offsets; (c) 184 M params runs on the FastAPI service in
<80 ms/resume on CPU.

**Model comparison (this module):**

| Model | Verdict | Reason |
|---|---|---|
| Regex / rules | ✗ | Cannot do relations or agency. Retained *only* for tech-alias normalisation, where it is exact and auditable. |
| BERT-base | ○ | Works; superseded. |
| RoBERTa-base | ○ | ~= DeBERTa on NER, worse on relation extraction in our pilot budget. |
| **DeBERTa-v3-base** | **✓ selected** | Disentangled attention is measurably better on span+relation tasks at this size; offsets are exact. |
| MiniLM (6-layer) | ✓ (aux) | Used for the cheap sentence-level claim-bearing gate; 10× faster, and the gate's errors are recoverable downstream. |
| Sentence-Transformers | ✓ (aux) | Claim clustering + dedup only. |
| LLM (Claude/GPT) | ✓ (teacher) | Weak-label generation and human-in-the-loop annotation assist. Never in the inference path. |

**Pipeline edge.** Claims are the **root nodes of the evidence graph** and the
conditioning variable for every downstream model. `verifiability` directly seeds
the interview planner's priority queue.

---

### 2.5 Process telemetry — `process_telemetry.dart`

**Now.** Records `(timestamp, lengthBefore, lengthAfter)`; classifies
`bulkInsert` at Δ ≥ 40 chars, `bulkDelete` at Δ ≤ −40, pause at ≥ 20 s. Derives
11 signals. The file's doc comment correctly refuses to emit a cheating score.

**Verdict: Rule for capture (keep and *extend*), ML for interpretation.**

**Justification, split in two:**

- *Capture* stays deterministic. A measurement must be a measurement. Learning
  "what counts as an edit" would make the raw record unauditable, which breaks
  the entire evidence chain. **Keep.**
- *Interpretation* becomes ML. The constants 40 / 40 / 20 s are the clearest
  hardcoded rules in the codebase and they are indefensible as universals: 40
  chars is one line of Python and a third of a Java signature; 20 s is a long
  pause for a syntax question and a short one for a design question. These
  should be **learned, per-language and per-task-type**. **Replace.**

**Prerequisite — telemetry must be upgraded first.** Buffer-length deltas cannot
support keystroke dynamics. 100+ of the 150 features in §7 require:
`(t, keycode_class, event_type, cursor_pos, selection_len, len_before, len_after)`
where `keycode_class ∈ {alpha, digit, symbol, whitespace, nav, delete, modifier}`
— **never the character itself** (see §6.5, privacy). This is a ~1-day change to
`record()` plus the `TextField` listener, and it is **P0**: no downstream ML is
possible without it.

**Redesign.**
- Bulk-insert detection → learned **change-point detection** on the inter-key
  interval series (a paste is a Δ with a *zero-duration* interior, which
  length-delta alone cannot see).
- Pause thresholds → per-task percentile from the learned distribution, not 20 s.
- New output: **`authorship_consistency`** (§4.6, and the core novelty).

**Pipeline edge.** Feature groups A–D of §7 feed the sufficiency model and the
planner.

---

### 2.6 Follow-up generation — `followup.dart`

**Now.** Three triggers (bulk insert / immediate answer / pause-then-bulk) map to
three hardcoded question strings, sorted by span size.

**Verdict: ML — Learning-to-Rank over a question bank. This is the flagship
replacement.**

**Justification.** The current module answers *"was a trigger fired?"*. The right
question is *"which of the 200 questions I could ask right now would most
increase evidence for this claim, given everything I already have?"* Those are
different problems, and only the second one is learnable, useful, and
interesting. The current version cannot ask a *good* question — only a
*triggered* one — and it has no notion of a question being redundant with one
already asked.

**Redesign — two-stage, and the staging matters:**

```
Stage 1  CANDIDATE GENERATION  (recall-oriented, cheap)
  claim.tech + task_type → question bank retrieval
  bi-encoder (Sentence-Transformer) top-50 by semantic relevance
  hard filters (rule, kept): already-asked · out-of-scope · time-budget

Stage 2  RANKING  (precision-oriented)
  LambdaMART (LightGBM, objective=lambdarank)
  features: 40 question features × session-state interaction terms
  target: observed Δ evidence-sufficiency after the question was asked
  → top-5 questions + expected gain + the reason each was chosen
```

**Model comparison (this module):**

| Model | Verdict | Reason |
|---|---|---|
| Rule triggers (current) | ✗ | No ranking, no redundancy handling, 3 fixed outputs. |
| **LambdaMART / LightGBM** | **✓ selected** | LTR is the right formalism; trains on ~2 k ranked sessions, which is the realistic data ceiling. Native feature importance. Runs in <5 ms. |
| XGBoost `rank:pairwise` | ○ | Equivalent quality; LightGBM's categorical handling for `tech`/`task_type` is cleaner. |
| Transformer cross-encoder | ○ | Best ceiling, needs ~50 k labelled pairs we will not have. Kept as the §14 future-work upgrade path. |
| GNN over the question–claim graph | ○ | Only justified once the question bank exceeds ~1 k items with real co-occurrence structure. Not now (§2.8). |
| RL policy (contextual bandit) | ✓ (phase 2) | See §4.4 — offline-trained, shadow-mode only. |

**Philosophy guard, enforced in code.** A recommended question's explanation must
name the *evidence gap it targets* ("claim asserts a Postgres query-optimisation
result; no answer yet references an execution plan"), never the behavioural
trigger alone ("you pasted"). The observation stays visible to the candidate as
today, but it is now the *input*, not the *reason*.

---

### 2.7 Claim audit / status assignment — `claim_audit.dart`

**Now.** Deterministic: no evidence → `notExamined`; otherwise the *reviewer's*
assessment, defaulting to `notDemonstrated`.

**Verdict: Rule — KEEP, unchanged. Add ML strictly alongside.**

**Justification, and this is the most important "do not replace" call in the
document.** `ClaimStatus` is the *human's verdict*. Learning it would mean
training a model to predict whether a candidate demonstrated competence — which
is precisely the hire/reject predictor the philosophy forbids, wearing a
different label. Any model fit to `reviewerAssessments` becomes a reviewer-
imitation model, and deploying it would let the system pre-empt the human.
**Never train on `ClaimStatus` as a target.**

**Redesign.** Add a parallel, clearly-separated field:

```dart
class ClaimFinding {
  final ClaimStatus status;              // human. unchanged. authoritative.
  final EvidenceSufficiency sufficiency; // model. advisory. about the INTERVIEW.
}
```

The UI must render these in visually distinct regions with distinct language:
status = "The reviewer found…", sufficiency = "This session gathered…". A shared
row would invite reading the model output as a verdict.

**Pipeline edge.** `sufficiency` is $f_\theta$'s output (§4.3). `status` is never
a model input either — that would close a feedback loop from human judgement
back into the measurement layer.

---

### 2.8 Evidence graph — `evidence_graph.dart`

**Now.** Typed nodes/edges, closed enums, mandatory `rationale`, mandatory
`EdgeBasis`. The doc comment explicitly bans weights and node-ranking
("do not add PageRank … that is a hidden weight with extra steps").

**Verdict: Hybrid — keep the structure as-is; add ML for *edge proposal only*.**

**Justification.** The existing constraints are excellent and are the project's
strongest explainability asset — they should be preserved verbatim, including
the ban. But there is a genuine gap: **edges are currently created by rules or
by a human.** Deciding whether an answer *supports* or *contradicts* a claim is
a natural-language inference problem, and NLI is a solved-enough task to do well.

**Redesign.**
- **Edge proposal:** a fine-tuned NLI model (DeBERTa-v3 trained on MNLI, then
  domain-adapted) over (claim text, answer span) → {supports, partiallySupports,
  contradicts, unrelated} + confidence.
- **Every proposed edge enters as `EdgeBasis.modelProposed` and is
  *provisional*** until a reviewer accepts it. The rationale field is populated
  with the NLI model's attributed span, not with prose the model invented.
- **The ban holds.** No PageRank, no centrality, no `strength()`. If graph
  learning is added later it must be for *link prediction to suggest an
  unexamined claim–evidence pair to a human*, never for scoring a node.

**On graph neural networks — the honest answer is "not yet".** The instruction
said not to use graph ML unless justified. At the current scale (one session ≈
20–60 nodes, no cross-session graph, no node features richer than the text
already embedded) GraphSAGE/GAT would be a strictly worse text classifier with
more moving parts. **Defer to §14**, where the justified use appears: once a
cross-session graph exists over a *shared* technology ontology, GraphSAGE link
prediction over (claim-type → question) co-occurrence genuinely beats the
LambdaMART ranker's cold-start on unseen technologies. Say this explicitly in
the paper — "we evaluated GNNs and found them unjustified at this scale" is a
stronger result than shoehorning one in.

---

### 2.9 Integrity tracker — `integrity_tracker.dart` + `violation_rules.dart`

**Now.** Hand-weighted violations (5–20 points), `+2` compounding per repeat,
capped at 100. Produces `IntegritySummary.riskScore`.

**Verdict: DELETE. Not replaced by ML — replaced by nothing.**

**Justification.** This is the single component that contradicts the project's
stated philosophy. Its own doc comment says the reference build "fabricated
phone/book detections from ambient lighting" and that only measured events
should reach it — but the deeper problem is the *output type*. A 0–100 "risk
score" built from hand-set weights is a cheating-probability estimate. It has no
ground truth, cannot be calibrated, cannot be explained beyond restating its own
weights, and is exactly the artefact that draws NYC Local Law 144 and EU AI Act
scrutiny. Replacing the weights with a learned model would make it *worse* — a
learned cheating score is the thing the philosophy most forbids.

**Redesign.** Keep the **event log** (`IntegrityEvent` without `impact`) as
timestamped, cited observations that appear in the evidence graph as
`NodeType.telemetry` and in the audit as neutral facts. Delete `score`,
`baseWeight`, the escalation term, `IntegritySummary.riskScore`, and every UI
surface that renders them. Where a reviewer previously saw "risk 34", they now
see "3 focus-loss events at 04:12, 09:50, 11:02" and decide for themselves.

This deletion is a *result* worth reporting in the paper: an ablation showing
that removing the composite risk score does not reduce reviewer decision quality
(measured by inter-reviewer agreement on the same sessions) is a genuine
empirical finding about hiring-tool design.

---

### 2.10 Rules that stay rules — the full audit

The instruction was: never replace a rule unnecessarily. These are the ones where
determinism wins, with the reason:

| # | Rule (location) | Verdict | Why it stays |
|---|---|---|---|
| R1 | `evidence.isEmpty → notExamined` ([claim_audit.dart:148](../lib/core/claims/claim_audit.dart:148)) | **KEEP** | Absence of evidence is a *fact*, not a prediction. A model here could only invent evidence. |
| R2 | `identityCoverage == null` when no attempts | **KEEP** | Null-vs-1.0 distinction is a definitional correctness fix. Not learnable, and correct. |
| R3 | `ProvenanceQuality` bands (<0.5 → sparse) | **KEEP boundary, LEARN the input** | The band is a policy choice a human should own and be able to change. Its input (`didMeasure`) becomes model-driven via §2.2. |
| R4 | Provenance gate hard-caps sufficiency at Insufficient | **KEEP — add as a new rule** | A safety constraint must be a constraint, not a learned tendency. A model that *usually* respects it is a model that sometimes doesn't. |
| R5 | Cosine similarity as the identity metric | **KEEP** | Matches the encoder's training objective. Replacing it discards ArcFace's geometry. |
| R6 | Tech-alias normalisation (`postgres` → `PostgreSQL`) | **KEEP** | Exact, auditable, editable by a non-ML human. ML here would be worse *and* opaque. |
| R7 | "Already asked" / time-budget filters in question retrieval | **KEEP** | Hard constraints. Ranking should never have the option to violate them. |
| R8 | Closed enums for `NodeType` / `EdgeType` | **KEEP** | Structural guarantee that a legend is complete. §2.8. |
| R9 | Every edge carries a non-empty rationale | **KEEP** | Enforced at decode time; this is what makes the graph auditable. |
| R10 | No numeric weight on edges | **KEEP** | The project's best structural anti-black-box guard. |
| R11 | `minEnrolmentFaceSize = 15000` | **REPLACE (§2.1)** | Arbitrary constant standing in for a measurable quality question. |
| R12 | `rawThreshold = 0.50` | **REPLACE (§2.2)** | Admitted-uncalibrated by its own author. Session-adaptive beats global. |
| R13 | `strikesAllowed = 3` | **REPLACE (§2.3)** | Arbitrary; sequence residual is the principled version. |
| R14 | `bulkInsertThreshold = 40` chars | **REPLACE (§2.5)** | Language- and task-dependent; learnable from timing structure. |
| R15 | `idleGapThreshold = 20 s` | **REPLACE (§2.5)** | Should be a per-task-type percentile. |
| R16 | `immediateAnswerWindow = 5 s` | **REPLACE (§2.6)** | Subsumed by the ranker's features. |
| R17 | `pauseBeforeBulk = 30 s` | **REPLACE (§2.6)** | Same. |
| R18 | Follow-ups ordered by span size | **REPLACE (§2.6)** | Span size is a poor proxy for evidence value — that is what LTR is for. |
| R19 | Violation `baseWeight` table | **DELETE (§2.9)** | Hidden scoring. Not replaced. |
| R20 | `+2` repeat escalation | **DELETE (§2.9)** | Same. |
| R21 | `maxScore = 100` cap | **DELETE (§2.9)** | Same. |
| R22 | Abstain when uncertainty exceeds threshold | **ADD as rule** | Selective prediction must be a hard gate, not a soft preference. §9.4. |

**Score: 10 rules kept, 8 replaced by ML, 3 deleted outright, 1 added.** That
ratio is the point — an ML-first system is not a system with no rules; it is one
where every rule survived an argument.

---

## 3. Target architecture

### 3.1 System view

```
┌─────────────────────────── FLUTTER CLIENT (candidate) ────────────────────────────┐
│  Enrolment      Task / Editor          Interview            Audit · Graph          │
│  camera ──┐     keystroke stream ──┐   Q/A turns ──┐        read-only views        │
└───────────┼─────────────────────────┼──────────────┼───────────────────────────────┘
            │                         │              │
            │  frames (jpeg)          │  events      │  text
            ▼                         ▼              ▼
┌─────────────────────────── FASTAPI INFERENCE SERVICE ─────────────────────────────┐
│                                                                                    │
│  ① PERCEPTION                                                                      │
│     face encoder (InsightFace buffalo_l, frozen) ──► E_face 512-d                  │
│     capture-quality head (LR, 6 feat)            ──► q_capture                     │
│     claim extractor (DeBERTa-v3 NER+RE)          ──► Claim[]                       │
│     answer encoder (Sentence-Transformer)        ──► E_ans 384-d                   │
│                                                                                    │
│  ② FEATURE STORE  (§7 — 158 features, versioned, point-in-time correct)            │
│     A typing · B editing · C temporal · D identity · E interview                    │
│     F claim · G semantic · H session · I graph · J cross-modal                      │
│                                                                                    │
│  ③ LEARNED CORE                                                                    │
│     ┌──────────────────────────────────────────────────────────────────┐           │
│     │  IDENTITY CONTINUITY (GRU)      ──► continuity_residual           │           │
│     │  ADAPTIVE THRESHOLD (calibr.)   ──► identity_confidence           │           │
│     │  AUTHORSHIP CONSISTENCY (§4.6)  ──► self-deviation z-score        │◄── NOVEL  │
│     │  ANSWER↔CLAIM NLI (DeBERTa)     ──► edge proposals                │           │
│     │  ── ATTENTION FUSION (§4.8) ──────────────────────────────────┐   │           │
│     │  EVIDENCE SUFFICIENCY  f_θ  (LightGBM + calib.)  ──► 4-class   │◄── PRIMARY   │
│     │  QUESTION RANKER       g_φ  (LambdaMART)         ──► top-5     │           │
│     │  INTERVIEW STATE       (HMM/GRU)                 ──► phase     │           │
│     └──────────────────────────────────────────────────────────────────┘           │
│                                                                                    │
│  ④ EXPLANATION  (§8 — mandatory, no output leaves without one)                     │
│     SHAP(TreeExplainer) · counterfactual · conformal interval · NL template         │
│                                                                                    │
│  ⑤ GUARDS  (rules, un-bypassable)                                                  │
│     provenance gate · abstain gate · no-verdict gate · citation gate                │
└────────────────────────────────────────────────────────────────────────────────────┘
            │                                             │
            ▼                                             ▼
   evidence graph (typed, cited)              reviewer console (human decides)
```

### 3.2 Data flow — one interview turn

```
t=0   candidate submits answer A_t for claim c
      │
      ├─► keystroke buffer ──► feature extractor (groups A–D)  ── 71 features
      ├─► A_t text ──► Sentence-Transformer ──► E_ans           ── group G
      ├─► A_t vs c ──► NLI head ──► {supports|contradicts|…}    ── group F
      ├─► face poll ──► E_face, q_capture ──► GRU ──► residual  ── group D
      └─► graph state ──► structural features                   ── group I
                 │
                 ▼
      FEATURE VECTOR x_t ∈ ℝ^158  (+ 3 embedding blocks, fused §4.8)
                 │
                 ├─► f_θ ──► P(Strong|Moderate|Weak|Insufficient), calibrated
                 │      └─► SHAP ──► top-6 contributing features
                 │      └─► conformal ──► prediction set; if |set| > 1 → ABSTAIN
                 │
                 └─► g_φ ──► top-5 next questions, each with Δ Ê and target gap
                 │
                 ▼
      PROVENANCE GATE: identity_coverage < 0.5 → force "Insufficient — provenance"
      ABSTAIN GATE:    conformal set ambiguous  → force "Unknown"
                 │
                 ▼
      graph: new nodes (answer, telemetry snapshot, followUpQuestion)
             new edges (modelProposed, provisional, rationale = NLI span)
                 │
                 ▼
      reviewer console  ──►  human sets ClaimStatus  ──►  (never fed back to f_θ)
```

---

## 4. ML component specifications

Each spec follows the required 13-field template. Twelve components.

---

### 4.1 Resume Claim Extraction (NLP)

| Field | Specification |
|---|---|
| **Objective** | Convert free-text resume into typed, span-cited, verifiability-scored `Claim` objects. |
| **Inputs** | Resume text (PDF→text), section segmentation, char offsets. |
| **Outputs** | `Claim{text, tech[], artefact, metric, agency∈{sole,team,ambiguous}, verifiability∈[0,1], span:(start,end), extractor_confidence}` |
| **Labels** | BIO tags over 6 entity types; 5 relation types over entity pairs; 3-class agency; verifiability = ordinal 1–5 (human). |
| **Features** | Subword tokens; POS + dependency path as auxiliary input for relation head; sentence position; section type. |
| **Candidates** | BERT-base · RoBERTa-base · **DeBERTa-v3-base** · MiniLM · LLM-as-extractor |
| **Selected** | **DeBERTa-v3-base**, multi-task (NER + RE + agency + verifiability heads on a shared encoder). MiniLM as a pre-filter gate. Rationale in §2.4. |
| **Training** | Multi-task, weighted loss (NER 1.0, RE 1.0, agency 0.5, verifiability 0.3). AdamW 2e-5, 8 epochs, linear warmup 10 %. Weak-label pretraining on 5 k LLM-annotated resumes → fine-tune on 1 200 human-annotated. |
| **Validation** | 5-fold, **grouped by resume** (never split a resume across folds — same-document leakage is the classic failure here). |
| **Metrics** | Span-F1 (exact + partial), relation micro-F1, agency macro-F1, verifiability QWK, **offset-fidelity rate** (extracted span must be a literal substring — target 100 %). |
| **Explainability** | Every claim links to its character span; attention rollout over the claim sentence; extractor confidence surfaced; below-threshold claims routed to human confirmation instead of auto-accepted. |
| **Deployment** | ONNX INT8 on the FastAPI service. ~90 ms/resume CPU. One-shot at session start, so latency is uncritical. |

---

### 4.2 Adaptive Identity Threshold

| Field | Specification |
|---|---|
| **Objective** | Replace the global `0.50` cosine constant with a per-session calibrated boundary. |
| **Inputs** | Enrolment embedding set (k≥12), live embedding, `q_capture`, session illumination summary. |
| **Outputs** | `{Verified, Mismatch, Unchecked}` + calibrated $P(\text{same person})$ + the boundary used. |
| **Labels** | Same/different person pairs. Source: within-session pairs = positive (self-supervised, free); cross-candidate pairs = negative (free); plus a small human-verified cross-session set. |
| **Features** | cos-to-centroid, cos-to-nearest-enrolment, $\mu_{self}$, $\sigma_{self}$, q_capture, Δt since enrolment, face area, brightness delta. |
| **Candidates** | Fixed threshold · Logistic regression · **Platt-calibrated LR on the 8 features** · Isolation Forest · one-class SVM |
| **Selected** | **Platt-calibrated logistic regression.** 8 features, ~500 params, fully inspectable, gives a *probability* (needed for the abstain gate), trains on hundreds not thousands of pairs. Isolation Forest rejected: one-class novelty detection here silently learns "unusual lighting = impostor". |
| **Training** | Offline on the pair set; per-session the model *recalibrates its intercept* from that session's $\mu_{self},\sigma_{self}$. |
| **Validation** | Stratified by candidate identity (no identity in both train and test). Report FAR/FRR curves and EER. |
| **Metrics** | EER, FAR@FRR=1 %, **abstain rate** (target: high when quality is poor — abstaining is correct behaviour), ECE. |
| **Explainability** | "Similarity 0.62 vs. this session's own baseline 0.81 ± 0.06 → 3.2σ below. Capture quality 0.4 (low light) → boundary widened. Result: Unchecked, not Mismatch." |
| **Deployment** | Pure-Dart inference in Flutter (8-feature LR is trivial to port) — no round trip, works offline. |

---

### 4.3 Evidence Sufficiency Model $f_\theta$ — **PRIMARY MODEL**

| Field | Specification |
|---|---|
| **Objective** | Predict how much evidence the session has accumulated for claim $c$ at turn $t$. **Never** predict competence, honesty, or hire. |
| **Inputs** | 158-d feature vector (§7) + fused embeddings (§4.8) + claim metadata. |
| **Outputs** | Ordinal 4-class {Insufficient, Weak, Moderate, Strong} + calibrated posterior + conformal prediction set + `missing_evidence[]` + top-6 SHAP factors. |
| **Labels** | **Human annotation of the evidence, not the candidate.** Annotator prompt: *"Ignoring whether the candidate is good, does this session contain enough material for a reviewer to judge this claim?"* 4-point ordinal, 3 annotators, adjudicated. §5.1. |
| **Features** | All ten groups of §7. Critically **excludes**: `ClaimStatus`, reviewer notes, any outcome variable, and any demographic proxy. |
| **Candidates** | Random Forest · **XGBoost** · **LightGBM** · CatBoost · SVM · MLP · Transformer fusion |
| **Selected** | **LightGBM with `objective=multiclassova` + ordinal-aware class weights, wrapped in isotonic calibration.** |
| **Why LightGBM over the alternatives** | *vs. RF:* better calibration after isotonic, native monotonic constraints (see below), faster. *vs. XGBoost:* essentially tied on accuracy; LightGBM's native categorical handling for `tech`/`task_type`/`language` avoids one-hot blowup on high-cardinality tech names, and its leaf-wise growth needs fewer trees at n≈2 000, which matters for SHAP latency. *vs. CatBoost:* CatBoost's ordered target statistics are attractive for the categoricals, and it is the strongest runner-up — but it is 3–4× slower for TreeSHAP at inference and the categorical advantage shrinks once tech names are normalised (R6). Report it as the ablation baseline. *vs. SVM:* no native feature importance, poor calibration, no missing-value handling — and missingness is *semantically meaningful* here (`revisionRatio == null` means "not measurable", which LightGBM routes natively and an SVM cannot represent). *vs. MLP/Transformer:* n≈2 000 sessions is 1–2 orders of magnitude below where they win; and TreeSHAP is exact whereas DeepSHAP is approximate — for a system whose thesis is explainability, an exact attribution is worth real accuracy. |
| **Monotonic constraints (important)** | LightGBM `monotone_constraints` enforce domain truths the model must never violate: more probe responses → sufficiency cannot decrease; higher identity coverage → cannot decrease; more unanswered follow-ups → cannot increase. This encodes philosophy *into the hypothesis space*, so no training-data quirk can produce "answering more questions lowered your evidence". |
| **Training** | 5-fold grouped by candidate. Class weights inverse-frequency. Isotonic calibration on a held-out calibration fold. Ordinal handled as 4 one-vs-all + monotone post-processing of the CDF. |
| **Validation** | Grouped 5-fold + a temporal holdout (last 15 % of sessions by date) to catch drift. Human-annotator agreement (Krippendorff's α) is the *performance ceiling* and must be reported next to model accuracy. |
| **Metrics** | QWK (primary — ordinal), macro-F1, **ECE and reliability diagram** (co-primary; calibration matters more than accuracy for an advisory system), abstain-rate vs. selective-accuracy curve, per-technology fairness slices. |
| **Explainability** | TreeSHAP (exact), counterfactual ("if one follow-up on the indexing strategy were answered → Moderate"), conformal set, NL template. §8. |
| **Deployment** | Two paths: (a) LightGBM in the FastAPI service, full SHAP — the default; (b) TFLite-converted GBDT via `tflite_flutter` for offline sessions, with a **degraded-mode banner** because SHAP is unavailable on-device. Never silently degrade. |

---

### 4.4 Adaptive Interview Planner (RL)

| Field | Specification |
|---|---|
| **Objective** | Sequence questions to maximise evidence gained per minute across *all* claims — not per question greedily. |
| **State** | $s_t$ = [per-claim sufficiency posteriors, coverage vector over claims, identity confidence, elapsed/budget, last-3 question types, candidate engagement proxies]. ~40-d continuous. |
| **Actions** | 6 macro-actions: {architecture probe, debugging probe, optimisation probe, implementation probe, design-tradeoff probe, identity checkpoint} × claim selection. The *concrete* question comes from §4.5 — the RL policy chooses **type + target claim**, keeping the action space small enough to learn offline. |
| **Reward** | $r_t = \Delta\!\sum_c \text{suff}(c) \;-\; \lambda_1 \cdot \text{minutes} \;-\; \lambda_2 \cdot \mathbb{1}[\text{redundant}] \;-\; \lambda_3\cdot \mathbb{1}[\text{candidate disengaged}]$. **Explicitly absent:** any term for detecting deception, any term correlated with hire outcome. |
| **Labels** | Reward computed from $f_\theta$'s output deltas on logged sessions — no separate annotation. |
| **Candidates** | Greedy $g_\phi$ (myopic) · **Contextual bandit (LinUCB)** · Conservative Q-Learning (offline RL) · PPO (online) |
| **Selected** | **Phased.** Phase 1 = greedy $g_\phi$ + hard coverage rules (ship this). Phase 2 = **LinUCB contextual bandit**, offline-evaluated. Phase 3 = CQL once ≥5 k logged sessions exist. **PPO/online RL is rejected outright** — exploring on live candidates means deliberately asking a real person a question you believe is bad, for the algorithm's benefit. That is not defensible in a hiring context and should be stated as an ethics decision in the paper. |
| **Training** | Offline, from logged interaction data. Off-policy evaluation via **doubly-robust estimation** + a session simulator built from the empirical answer-quality distribution. |
| **Validation** | OPE with confidence intervals; simulator sanity checks; **shadow mode** — the policy runs and logs its choice, the deployed greedy ranker acts, and the two are compared retrospectively before any switch. |
| **Metrics** | Evidence gained per minute, claim coverage at fixed budget, redundancy rate, reviewer-rated question usefulness (5-point). |
| **Explainability** | Every action logs its Q-value decomposition and the coverage gap it targeted. A reviewer can see why the interview went where it went. |
| **Deployment** | Server-side; policy is a small linear model, so shipping it into Flutter later is trivial. |

---

### 4.5 Question Recommendation / Ranker $g_\phi$

| Field | Specification |
|---|---|
| **Objective** | Rank the question bank by expected evidence gain for the current state. |
| **Inputs** | Claim, session state, question-bank candidates (top-50 from bi-encoder retrieval), already-asked set. |
| **Outputs** | Top-5 with expected Δ sufficiency, targeted evidence gap, and diversity guarantee (≤2 of the same probe type). |
| **Labels** | $\Delta$ sufficiency observed after each historically-asked question = graded relevance (0–3). Free from logs once $f_\theta$ exists. |
| **Features** | 40: question-side (type, difficulty, tech match, specificity, expected answer length), state-side (current sufficiency, gap vector), interaction (semantic sim between question and unaddressed claim components, redundancy with asked set). |
| **Candidates** | See §2.6 table. |
| **Selected** | **LambdaMART (LightGBM `lambdarank`, NDCG@5 objective).** |
| **Training** | Grouped by (session, claim) as the query group. Position-bias correction via inverse-propensity weighting, since historical questions were not randomly ordered. |
| **Validation** | NDCG@5, MRR, grouped by candidate. Offline A/B against the current rule triggers on replayed sessions. |
| **Metrics** | NDCG@5, MAP, reviewer usefulness rating, redundancy rate. |
| **Explainability** | Per-question SHAP over the 40 features + the plain-English gap statement (§2.6 guard). |
| **Deployment** | FastAPI, <5 ms. Bank + bi-encoder index cached in memory. |

---

### 4.6 Within-Session Authorship Consistency — **NOVEL COMPONENT**

| Field | Specification |
|---|---|
| **Objective** | Measure how far a given answer's *production process* deviates from **this same candidate's own baseline, established minutes earlier in the same session**. Output is an evidence-need signal, never an authorship verdict. |
| **Why it is different** | Classical keystroke-dynamics authorship verification asks *"is this the enrolled user?"* against a stored profile — an accusatory, cross-session, privacy-heavy, notoriously brittle formulation. This asks *"is this span produced the way this person produced their warm-up span 6 minutes ago?"*, using the candidate as their own control. No stored biometric profile, no population comparison, no accusation — and a deviation triggers **a question**, not a flag. |
| **Inputs** | Warm-up span keystroke stream (baseline, 2–3 min, low-stakes task) + target span keystroke stream. |
| **Outputs** | Deviation z-score per dimension (rhythm, burstiness, revision style, pause structure) + an aggregate + which dimension drove it. |
| **Labels** | **None required for the core signal** — it is self-supervised (baseline vs. target from the same session). A small labelled set (same-author / different-author spans, collected consensually in a lab study) is used only to validate that the deviation measure *has* discriminative power. |
| **Features** | Groups A–C of §7 computed twice (baseline window, target window) → 34 paired deltas + distributional distances (Wasserstein on inter-key intervals, KL on n-graph duration histograms). |
| **Candidates** | Threshold on raw deltas · Mahalanobis distance · **Siamese 1-D CNN encoder + cosine** · LSTM · Autoencoder reconstruction error · Isolation Forest |
| **Selected** | **Siamese 1-D temporal CNN** producing a 64-d *style* embedding from an inter-key-interval sequence; deviation = cosine distance between baseline and target embeddings, z-normalised by the baseline's own internal variance. |
| **Why Siamese CNN** | *vs. Mahalanobis on hand features:* the CNN learns the timing motifs (digraph rhythms) that hand-crafted features flatten; still ship Mahalanobis as the interpretable baseline and report both. *vs. LSTM:* comparable accuracy, 4× slower, harder to attribute. *vs. Autoencoder/IsolationForest:* these are one-class novelty detectors — they learn "unusual" and would fire on a candidate who is simply nervous or tired. The Siamese formulation is *contrastive and self-referential*, which is precisely the property that makes the output non-accusatory. |
| **Training** | Contrastive (positive = two windows from one person's session; negative = windows from different sessions). Public keystroke corpora for pretraining, project data for fine-tuning. |
| **Validation** | AUC on held-out same/different-span pairs, **stratified by candidate** and by typing speed decile (to check it is not just learning "fast typist"). |
| **Metrics** | AUC, EER, and **the fairness metric that matters here**: deviation-score distribution across typing-speed deciles, motor-ability self-report, and keyboard type must be statistically indistinguishable. If a slow typist scores systematically higher deviation, the feature is discriminatory and must be dropped. |
| **Explainability** | "Your first task's rhythm: median 180 ms between keys, 12 % pauses > 2 s. This span: median 42 ms, 0 pauses. → asked about this span." The candidate sees the same numbers the reviewer does. |
| **Deployment** | 64-d CNN, ~200 k params, TFLite in Flutter — runs on-device, so **raw keystroke timings never leave the phone**. Only the 4 deviation scores are transmitted. This is a privacy property, not an optimisation. |

---

### 4.7 Answer↔Claim Semantic Verification (NLI)

| Field | Specification |
|---|---|
| **Objective** | Decide whether an answer span supports, partially supports, contradicts, or is unrelated to a claim — and cite the span. |
| **Inputs** | (claim text, answer text) pairs, chunked. |
| **Outputs** | 4-class + confidence + the attributed answer span (evidence for the edge). |
| **Labels** | 4-class human annotation on ~3 000 pairs; MNLI-pretrained initialisation. |
| **Features** | Cross-encoder token pairs; plus explicit tech-overlap and metric-agreement features concatenated to the [CLS] head. |
| **Candidates** | Bi-encoder cosine · **DeBERTa-v3 cross-encoder** · MiniLM cross-encoder · LLM-as-judge |
| **Selected** | **DeBERTa-v3-base cross-encoder**, MNLI-init. Bi-encoders cannot detect contradiction (both sentences are topically similar); LLM-as-judge is non-reproducible for a paper and cannot cite exact offsets. |
| **Training** | MNLI → domain fine-tune, 3 epochs, 1e-5. |
| **Validation** | Grouped by claim. Report the `contradicts` class separately — it is rare, high-stakes, and where errors hurt most. |
| **Metrics** | Macro-F1, per-class F1, **precision on `contradicts` is the gating metric** (target ≥0.9; a false contradiction is the most damaging error the system can make). |
| **Explainability** | Attention-attributed answer span becomes the edge `rationale`. Below-confidence pairs produce **no edge**, not a guessed one. |
| **Deployment** | FastAPI, ONNX, ~40 ms/pair. |

---

### 4.8 Multimodal Evidence Fusion

| Field | Specification |
|---|---|
| **Objective** | Combine behavioural (158 tabular), semantic (384-d answer), identity (512-d face → 16-d summary), and structural (graph) modalities for $f_\theta$. |
| **Inputs** | The four modality blocks. |
| **Outputs** | Fused representation + **per-modality attention weights** (these are an XAI output, not an internal detail). |
| **Candidates** | Early (concat) · Late (per-modality models + stacking) · **Gated attention fusion** · Transformer cross-modal · Tensor fusion |
| **Selected** | **Late fusion with a learned gating layer.** Per-modality LightGBM/linear models produce sufficiency logits; a 4-weight softmax gate (conditioned on modality availability + quality) combines them. |
| **Why late+gating over transformer cross-modal** | Three decisive reasons. (1) **Missing modalities are the norm** — camera denied, resume absent, answer empty. Late fusion degrades gracefully by renormalising the gate; early/transformer fusion needs imputation, and imputing a face embedding is exactly the kind of fabrication the philosophy bans. (2) **Attributability** — with late fusion, SHAP runs *inside* each modality and the gate weight is directly readable as "identity contributed 31 %". Cross-modal attention weights are notoriously unfaithful as explanations. (3) **Data scale** — cross-modal transformers need ≫10 k samples; n≈2 000 makes them a guaranteed overfit. Report early-fusion and transformer-fusion as ablations; the expectation that late fusion wins at this n is itself a reportable result. |
| **Training** | Modality models trained independently, gate trained on a held-out fold (proper stacking, no leakage). |
| **Validation** | Modality-dropout evaluation: measure performance with each modality ablated *and* with each unavailable at test time. |
| **Metrics** | QWK with all modalities and with each dropped; graceful-degradation curve. |
| **Explainability** | Gate weights shown in the reviewer UI: "This assessment: 46 % answer content, 31 % process, 18 % identity, 5 % structure." |
| **Deployment** | Server-side; gate is 4 parameters. |

---

### 4.9 Interview State / Phase Model

| Field | Specification |
|---|---|
| **Objective** | Infer the latent phase of the session (orienting / producing / revising / stalled / concluding) to time interventions well. |
| **Inputs** | Windowed telemetry + turn history. |
| **Outputs** | Phase posterior + expected time-to-next-phase. |
| **Labels** | Weak labels from heuristics + ~200 human-segmented sessions. |
| **Candidates** | HMM · **GRU sequence classifier** · CRF · Transformer |
| **Selected** | **GRU** (2 layers, 64 hidden). HMM is the interpretable baseline and is reported; the GRU wins because phase transitions here are not Markovian (a stall after heavy revision differs from a stall at the start). |
| **Training** | Semi-supervised: pretrain on next-window prediction, fine-tune on segmented sessions. |
| **Validation** | Frame-level F1, segment-boundary tolerance ±10 s. |
| **Metrics** | Macro-F1, boundary F1. |
| **Explainability** | Saliency over the input window + the HMM baseline's transition matrix as a human-readable sanity check. |
| **Deployment** | TFLite on-device (it drives UI timing, needs low latency). |

---

### 4.10 Candidate Knowledge Modelling

| Field | Specification |
|---|---|
| **Objective** | Track, per technology, how much has been *demonstrated* — to avoid re-probing covered ground and to find gaps. Explicitly a **coverage** model, not a mastery model. |
| **Inputs** | Answer–concept mappings, question difficulty, claim tech tags. |
| **Outputs** | Per-concept coverage ∈ [0,1] + which concepts remain unprobed. |
| **Labels** | Concept-touched annotations from the NLI module (§4.7) — free. |
| **Candidates** | Bayesian Knowledge Tracing · **Item-response-theory-style 2PL** · Deep Knowledge Tracing (LSTM) · matrix factorisation |
| **Selected** | **Coverage counting with IRT-style difficulty weighting.** DKT is rejected deliberately: DKT models *ability*, and a per-candidate ability estimate is a competence score by another name. The IRT difficulty parameter is used only to weight *coverage* ("a hard question about indexing covers more of the indexing concept"), never to estimate $\theta_{\text{candidate}}$. **Do not fit a candidate ability parameter.** |
| **Training** | Difficulty parameters fit once, offline, on the question bank from historical answer-length/follow-up-need — not from correctness. |
| **Validation** | Coverage predictions vs. human "was this concept examined?" judgements. |
| **Metrics** | Coverage-agreement κ, gap-detection recall. |
| **Explainability** | A concept grid: probed / partially probed / unprobed. Trivially readable. |
| **Deployment** | Pure Dart; it is arithmetic. |

---

### 4.11 Capture Quality Head

Compact spec — the details are in §2.1. LR over 6 features → $q_{capture}$;
self-supervised labels from embedding stability; validated by correlation with
downstream match reliability; deployed in Dart; explained by its 6 coefficients,
which are individually meaningful.

---

### 4.12 Evidence Ranking (reviewer-facing)

| Field | Specification |
|---|---|
| **Objective** | Order the evidence items shown to a reviewer per claim, so the most decision-relevant appears first. |
| **Inputs** | Evidence items + claim + reviewer interaction logs. |
| **Outputs** | Ranked evidence list. |
| **Labels** | Implicit: which items reviewers expanded, dwelt on, and cited in their notes. |
| **Candidates** | Recency sort · **LambdaMART** · pointwise GBDT |
| **Selected** | **LambdaMART**, sharing infrastructure with §4.5. |
| **Guard** | Ranking **must not filter**. Every item stays reachable, and the UI states the ordering criterion. A hidden filter is a hidden decision. |
| **Metrics** | NDCG@5 against reviewer-cited items, time-to-first-citation. |

---

## 5. Dataset design

### 5.1 `CogniHire-Evidence` — the primary dataset (publishable)

**This is the intended research artefact.** No public dataset exists that pairs
resume claims with interview process telemetry and human evidence-sufficiency
judgements. Releasing it is a contribution independent of any model.

**Schema (one row = one claim × one session state snapshot):**

```
session_id            str    hashed, stable
candidate_pseudo_id   str    HMAC(candidate, session_salt) — non-linkable across sessions
claim_id              str
turn_index            int    0..N; rows are point-in-time snapshots
claim_text            str    verbatim
claim_tech            list   normalised
claim_agency          enum   sole | team | ambiguous
claim_verifiability   int    1..5 (annotated)
task_type             enum   implement | debug | design | optimise | explain
language              str
features              json   158 floats/nulls (§7) — nulls preserved, never imputed
answer_embedding      bin    384-d fp16
face_summary          bin    16-d (NOT the 512-d embedding — see §5.4 privacy)
graph_snapshot        json   nodes/edges at this turn
questions_asked       list   question_ids in order
--- LABELS ---
evidence_sufficiency  ord    0=Insufficient 1=Weak 2=Moderate 3=Strong
missing_evidence      list   free-tag set from a controlled vocabulary
annotator_ids         list
annotator_raw         list   pre-adjudication labels (released — enables α computation)
adjudication_note     str
--- METADATA ---
collected_at          date
schema_version        str
consent_version       str
```

**Example row (abridged):**

```json
{"session_id":"s_0912","claim_id":"c_3","turn_index":4,
 "claim_text":"Cut p99 latency 40% by rewriting the batch scheduler in Go",
 "claim_tech":["Go"],"claim_agency":"sole","claim_verifiability":4,
 "task_type":"optimise","language":"go",
 "features":{"A01_ikm_median_ms":181.4,"A07_ikm_cv":0.62,"B03_revision_ratio":null,
             "D02_identity_coverage":0.83,"E05_followups_answered":2,"...":"..."},
 "questions_asked":["q_112","q_204","q_331","q_089"],
 "evidence_sufficiency":2,"missing_evidence":["no_profiling_method","no_baseline_number"],
 "annotator_raw":[2,3,2],"adjudication_note":"A2 credited the throughput anecdote; majority held it did not establish p99 method."}
```

**Annotation process.**
1. Annotators (3 per row; senior students + 1 industry engineer per batch) see
   the **session replay and the evidence, with the candidate's identity, face,
   name, and university removed**, and with `ClaimStatus` hidden.
2. The prompt is fixed and adversarially worded to block competence leakage:
   *"Do NOT judge whether the candidate is competent. Judge only whether a
   reviewer reading this session would have enough material to form their own
   view of this claim. If you find yourself thinking 'they seem good', you are
   answering the wrong question."*
3. Disagreement > 1 ordinal level → adjudication round with a written rationale.
4. **Quality control:** 10 % gold-standard items with known answers seeded per
   batch; annotators below 80 % gold agreement are retrained; their prior batch
   is re-annotated.
5. **Inter-annotator agreement:** Krippendorff's α (ordinal). Target α ≥ 0.67;
   **report it whatever it is.** α is the model's performance ceiling and hiding
   a low α is the single most common way this kind of paper becomes dishonest.

**Balancing.** Natural distribution will skew Weak/Moderate. Do **not** SMOTE —
synthesising interpolated behavioural feature vectors produces sessions that
never happened, and this project's entire thesis is that evidence must be real.
Use class weights + stratified sampling at collection time (deliberately run
some very short sessions and some very thorough ones to populate the tails).

**Splits.** **Grouped by candidate**, 70/15/15. A candidate must never appear in
two splits — their typing style would leak straight through. Plus a **temporal
holdout** of the final 15 % by date for drift measurement.

**Target size.** 200 candidates × ~4 claims × ~3 snapshots ≈ 2 400 rows.
Achievable in a college setting via consented volunteer sessions.

### 5.2 `CogniHire-Claims` — resume claim extraction

1 200 human-annotated resumes (span + relation + agency + verifiability), plus
5 000 LLM-weak-labelled for pretraining, **clearly flagged as weak in the
schema** — mixing weak and gold labels without a `label_source` column is a
reproducibility failure. Sourced from consented student resumes + public
anonymised corpora. Names/emails/phones/institutions scrubbed pre-annotation.

### 5.3 `CogniHire-Keystroke` — authorship consistency

Consented lab collection: 120 participants × (warm-up span + 3 task spans) +
a *transcription* condition (participant copies text they did not write) as the
labelled "different production process" positive class. **No candidate is ever
told a transcription condition means cheating** — it is a controlled stimulus.
Store only timing + keycode *class*, never characters (§5.4).

### 5.4 Privacy, and the non-negotiables

| Rule | Reason |
|---|---|
| Never store raw characters typed | A keystroke log with characters is a password logger. Store `keycode_class` only. |
| Never release 512-d face embeddings | Face embeddings are invertible to recognisable faces. Release only a 16-d non-invertible summary; keep raw embeddings on the enrolment device, encrypted, deleted at session end + 30 days. |
| Candidate IDs are per-session HMACs | Prevents cross-session linkage in the released data. |
| Explicit separate consent for research release | Consent to be interviewed ≠ consent to be a dataset. Two checkboxes, and declining must not affect the session. |
| Right to withdraw post-hoc | Row deletion by session_id, with a re-release process. |
| Demographic attributes: collected separately, never as model features | Needed for fairness audit; poison as features. Access-controlled, joined only for audit. |
| Every release is versioned + DOI'd | Reproducibility. |
| Store nulls, never impute in the released data | Missingness is signal (§4.3). |

### 5.5 Synthetic data — where it is legitimate

**Legitimate:** (a) the RL session simulator (§4.4), because off-policy
evaluation *requires* counterfactual rollouts and the simulator is clearly
labelled as such; (b) augmentation of the keystroke corpus by time-warping
(±10 % uniform scaling) and Gaussian jitter on intervals, which preserves the
motif structure the Siamese CNN learns; (c) resume templating for claim-extractor
pretraining.

**Illegitimate, and must be refused:** synthesising rows of
`CogniHire-Evidence` with fabricated sufficiency labels. There is no generative
process for "a human's judgement of evidence adequacy". Any paper reporting
results on synthetic sufficiency labels is reporting nothing.

---

## 6. Ground truth: the hardest problem, stated honestly

The single greatest threat to this project's validity is that
**evidence sufficiency has no objective ground truth.** It is a human judgement.
Three mitigations, all of which must appear in the paper's Threats to Validity:

1. **Report α as the ceiling.** If humans agree at α = 0.71, a model at QWK 0.68
   is at the ceiling and further "improvement" is fitting noise.
2. **Convergent validity check.** Independently measure: do sessions the model
   calls "Strong" produce *faster and more consistent* reviewer decisions than
   ones it calls "Weak"? That is an outcome the model was not trained on, and
   agreement there is real evidence the construct is meaningful.
3. **Explicitly bound the claim.** The system predicts *annotator-consensus
   evidence sufficiency*, not truth. Say so in the abstract.

---

## 7. Feature engineering — 158 features

Notation: `ikm` = inter-key interval. All windowed features computed over the
current span, the session, and a rolling 60 s window unless stated. **`null` is
a valid value and is never imputed** — LightGBM routes it natively and the
missingness itself is informative.

### Group A — Typing dynamics (24) · *requires the keystroke upgrade (§2.5)*

| ID | Feature | Why it is useful |
|---|---|---|
| A01 | ikm median (ms) | Central rhythm; robust to outlier pauses. |
| A02 | ikm mean | Pairs with median; mean≫median indicates a heavy pause tail. |
| A03 | ikm std | Rhythm stability. |
| A04 | ikm coefficient of variation | Scale-free burstiness — comparable across fast and slow typists, which raw std is not. |
| A05 | ikm p10 | Floor speed; distinguishes bursts from steady typing. |
| A06 | ikm p90 | Thinking-pause boundary. |
| A07 | ikm IQR | Robust dispersion. |
| A08 | ikm skewness | Right skew = occasional long thinks; symmetric = mechanical production. |
| A09 | ikm kurtosis | Heavy tails = alternating think/burst. |
| A10 | ikm entropy (histogram) | Rhythm predictability; near-uniform intervals are unusual for human composition. |
| A11 | Burst count (≥5 keys with ikm < p25) | Fluent stretches. |
| A12 | Mean burst length | How long fluency is sustained. |
| A13 | Max burst length | Peak fluency span. |
| A14 | Burst rate (bursts/min) | Production tempo. |
| A15 | Typing speed (chars/min, active time only) | Excludes idle — the naive version is dominated by pauses. |
| A16 | Peak 10 s speed | Ceiling capability. |
| A17 | Speed variance across 30 s windows | Consistency over the task. |
| A18 | Alpha-key ratio | Prose vs. symbol-heavy code. |
| A19 | Symbol-key ratio | Code density proxy. |
| A20 | Whitespace-key ratio | Indentation/formatting behaviour. |
| A21 | Modifier-key rate | IDE-fluent behaviour (shortcuts). |
| A22 | Navigation-key rate | Moving through code vs. appending. |
| A23 | ikm autocorrelation lag-1 | Rhythmic dependence; near-zero suggests non-continuous production. |
| A24 | ikm change-point count (PELT) | Structural shifts in production mode — the principled replacement for the `40`-char rule. |

### Group B — Editing behaviour (22)

| ID | Feature | Why |
|---|---|---|
| B01 | Total inserted chars | Volume. (Exists today.) |
| B02 | Total deleted chars | Volume. (Exists.) |
| B03 | Revision ratio (del/ins) | Thinking-through indicator; null when ins=0. (Exists — keep the null semantics.) |
| B04 | Net length | Output size. |
| B05 | Edit count | Interaction volume. |
| B06 | Insert-event count | — |
| B07 | Delete-event count | — |
| B08 | Bulk-insert count (learned threshold) | Spans worth probing. |
| B09 | Largest bulk insert (chars) | Biggest unexplained span. |
| B10 | Bulk-insert total share of final text | **What fraction of the answer arrived at once** — far more informative than raw count. |
| B11 | Bulk-insert interior ikm = 0 rate | **Paste signature** — a true paste has zero interior keystrokes; fast typing does not. This is the feature the current length-delta rule fundamentally cannot compute. |
| B12 | Bulk-delete count | Major rewrites. |
| B13 | Largest bulk delete | Scope of the largest rewrite. |
| B14 | Backspace rate (per 100 chars) | Micro-correction habit. |
| B15 | Undo count | Structural reconsideration. |
| B16 | Redo count | Indecision. |
| B17 | Cursor-jump count (non-adjacent moves) | Non-linear composition — a strong authorship-style marker. |
| B18 | Mean cursor-jump distance | Scope of restructuring. |
| B19 | Edit-position entropy | Append-only (low) vs. distributed revision (high). |
| B20 | Late-edit ratio (edits in final 25 % of time, to earlier text) | Polishing vs. one-pass production. |
| B21 | Selection-replace count | Deliberate substitution. |
| B22 | Mean time between consecutive edits to the same region | Local iteration depth. |

### Group C — Temporal behaviour (18)

| ID | Feature | Why |
|---|---|---|
| C01 | Time-to-first-keystroke (s) | Orientation time. (Exists.) |
| C02 | TTFK percentile within task-type | **Normalised** version — 5 s is fast for design, slow for syntax. Replaces `immediateAnswerWindow`. |
| C03 | Total active time | Effort. |
| C04 | Total idle time | Thinking or absent. |
| C05 | Active ratio | Engagement density. |
| C06 | Pause count (learned threshold) | (Exists, rule-based.) |
| C07 | Longest pause | (Exists.) |
| C08 | Mean pause duration | — |
| C09 | Pause duration entropy | Varied thinking vs. uniform gaps. |
| C10 | Pause-before-bulk max duration | Replaces `pauseBeforeBulk = 30 s`. |
| C11 | Pause position entropy | Early-loaded vs. distributed thinking. |
| C12 | First-quartile output share | Fast starter. |
| C13 | Final-quartile output share | Deadline-loaded. |
| C14 | Output-curve AUC (normalised cumulative chars vs. time) | Whole production shape in one number. |
| C15 | Output-curve max slope | Fastest accumulation. |
| C16 | Time from last edit to submit | Review time before submitting. |
| C17 | Total task duration | — |
| C18 | Duration vs. task-type median (ratio) | Relative pace. |

### Group D — Identity behaviour (16)

| ID | Feature | Why |
|---|---|---|
| D01 | Identity checks attempted | Denominator. (Exists.) |
| D02 | Identity coverage (measured/attempted) | (Exists; null-safe.) |
| D03 | Verified fraction of measured | (Exists.) |
| D04 | Mean cosine to enrolment centroid | Central match strength. |
| D05 | Min cosine | Worst moment. |
| D06 | Cosine std | Stability. |
| D07 | Within-session self-similarity μ | The adaptive-threshold baseline (§4.2). |
| D08 | Within-session self-similarity σ | Boundary width. |
| D09 | Longest unverified gap (s) | **How long was the session unwitnessed** — the provenance signal that matters most. |
| D10 | Unverified-gap share of session | Normalised D09. |
| D11 | Mean capture quality | Whether the camera could actually see. |
| D12 | Capture-quality std | Lighting/pose instability. |
| D13 | Continuity residual mean (§2.3) | Sequence-model surprise. |
| D14 | Continuity residual max | Peak surprise. |
| D15 | Face-count>1 event count | Measured fact only, no weight. |
| D16 | Unchecked-reason distribution (3 one-hots) | *Why* verification failed — no-face vs. engine-down are completely different for provenance. |

### Group E — Interview behaviour (20)

| ID | Feature | Why |
|---|---|---|
| E01 | Questions asked (this claim) | Probing volume. |
| E02 | Follow-ups triggered | — |
| E03 | Follow-ups answered | The actual evidence count. |
| E04 | Follow-up answer rate | Engagement with probing. |
| E05 | Mean answer length (chars) | Substance proxy (weak alone). |
| E06 | Answer-length variance | Consistency of engagement. |
| E07 | Mean time-to-answer | Response latency. |
| E08 | Answer latency vs. question difficulty (residual) | Latency *controlled for difficulty* — far better than raw latency. |
| E09 | Probe-type coverage (5-d one-hot count) | Breadth of examination. |
| E10 | Deepest follow-up chain length | How far a line of questioning went. |
| E11 | Clarification requests by candidate | Engagement (positive signal). |
| E12 | Unanswered / skipped questions | Evidence gaps. |
| E13 | Mean question difficulty asked | Level of probing. |
| E14 | Max question difficulty answered | Ceiling reached — coverage, not ability. |
| E15 | Question redundancy rate (semantic sim to prior) | Interview quality metric. |
| E16 | Time budget consumed on this claim | Attention allocation. |
| E17 | Turns since last identity check | Provenance freshness of this evidence. |
| E18 | Answer produced after a bulk insert (bool) | Links process to content. |
| E19 | Follow-up answer references the probed span (bool, from NLI) | **Did they actually address it** — the crux. |
| E20 | Reviewer interventions during session | Human-in-the-loop activity. |

### Group F — Claim behaviour (16)

| ID | Feature | Why |
|---|---|---|
| F01 | Claim verifiability score (§4.1) | Some claims are inherently harder to evidence — the model must know. |
| F02 | Claim agency (3-d) | "Led a team that built X" needs different evidence than "built X". |
| F03 | Claim specificity (entity count / token count) | Vague claims are hard to substantiate. |
| F04 | Claim has a quantitative metric (bool) | Metrics are checkable. |
| F05 | Metric magnitude (normalised) | — |
| F06 | Claim tech count | Breadth. |
| F07 | Claim recency (years since) | Memory decay is a legitimate explanation for weak recall. |
| F08 | Claim duration stated (months) | Depth of exposure claimed. |
| F09 | Claim tech ↔ task tech match score | Was the task even relevant? |
| F10 | Sibling claims sharing tech (count) | Cross-claim evidence transfer. |
| F11 | Cluster size of the claim (§4.1 clustering) | Repeated claims. |
| F12 | Extractor confidence | Low confidence = the claim itself may be misread. |
| F13 | Claim probed at all (bool) | Feeds R1. |
| F14 | Turns since first probe of this claim | Staleness. |
| F15 | Evidence item count for this claim | — |
| F16 | Evidence kind distribution (3-d: probe/process/identity) | Balance — three process signals and no answer is not evidence. |

### Group G — Semantic behaviour (20)

| ID | Feature | Why |
|---|---|---|
| G01 | Answer↔claim NLI: P(supports) | Core semantic evidence. |
| G02 | NLI: P(partially supports) | Partial credit is real. |
| G03 | NLI: P(contradicts) | High-stakes, reported separately. |
| G04 | NLI: P(unrelated) | Off-target answering. |
| G05 | Max supports-probability across answers | Best single piece of evidence. |
| G06 | Sum of supports across answers | Accumulated evidence. |
| G07 | Answer↔question cosine | Did they answer *the question asked*? |
| G08 | Technical-term density in answer | Domain specificity. |
| G09 | Technical terms matching claim tech (count) | On-topic specificity. |
| G10 | Technical terms *not* in the claim (count) | Volunteered depth — a strong positive signal. |
| G11 | Concrete-detail count (numbers, names, versions, tools) | Specificity is the hallmark of lived experience. |
| G12 | Hedging-marker rate | Uncertainty expression (descriptive only, never penalised). |
| G13 | Causal-connective rate ("because", "so that") | Explanatory depth. |
| G14 | First-person-singular rate | Agency language (**descriptive; must be fairness-audited for L2-English bias before use**). |
| G15 | Answer perplexity under a domain LM | Fluency (interpret with care). |
| G16 | Answer↔prior-answer cosine (consistency) | Self-contradiction detection across turns. |
| G17 | Novel-content ratio vs. prior answers | Is new evidence arriving? |
| G18 | Answer↔claim-text lexical overlap | Restating vs. explaining — high overlap with low G10 is restatement. |
| G19 | Code-block presence and share | Evidence type. |
| G20 | Named-artefact mentions (repos, tickets, tools) | Externally checkable references — the strongest evidence class. |

### Group H — Session behaviour (14)

H01 session duration · H02 claims examined / total · H03 task count · H04 task
switches · H05 focus-loss event count (fact, unweighted) · H06 fullscreen-exit
count (fact) · H07 mean inter-task gap · H08 session start hour (fatigue
covariate) · H09 device/platform one-hot · H10 keyboard-type indicator (fairness
covariate for group A) · H11 network-interruption count (explains missing data)
· H12 resume present (bool) · H13 camera permitted (bool) · H14 modality
availability mask (4-d) — *drives the fusion gate; a mask is not a missing value.*

### Group I — Graph / structural (14)

I01 node count · I02 edge count · I03 edges per claim · I04 supports-edge count
· I05 contradicts-edge count · I06 provisional-edge share (unreviewed) · I07
claim node degree · I08 mean path length claim→identity check (**provenance
distance**: is this evidence connected to a verified identity?) · I09 orphan-
evidence count (evidence connected to no claim) · I10 evidence-kind diversity
(entropy) · I11 reviewer-comment node count · I12 edge-basis distribution (3-d:
rule / model / human) · I13 graph density · I14 largest connected-component
share. **Note:** all structural *descriptions*. No centrality, no ranking — R10
holds.

### Group J — Cross-modal & authorship (10)

| ID | Feature | Why |
|---|---|---|
| J01 | Authorship deviation: rhythm (z) | §4.6 core output. |
| J02 | Authorship deviation: burstiness (z) | — |
| J03 | Authorship deviation: revision style (z) | — |
| J04 | Authorship deviation: pause structure (z) | — |
| J05 | Authorship deviation aggregate (z) | — |
| J06 | Baseline window quality (bool/score) | If the baseline was bad, J01–J05 are meaningless → they must go null, not zero. |
| J07 | Process↔content coherence: bulk-span share × answer specificity | Fast production *with* rich volunteered detail reads very differently from fast production with none. |
| J08 | Identity confidence × evidence recency interaction | Was the evidence gathered while identity was solid? |
| J09 | Answer specificity × claim verifiability interaction | Calibrates expectation to claim type. |
| J10 | Modality-agreement score | Do the modalities point the same way? Disagreement → abstain. |

**Total: 24+22+18+16+20+16+20+14+14+10 = 158 features.**

**Feature governance rules:**
- Every feature has a unit and a null semantics documented in the feature store.
- **Banned as features, permanently:** name, gender, age, institution, photo-derived
  demographics, nationality, English-as-L2 indicators, and anything correlated
  with them beyond the fairness threshold. G14 and G15 are on probation and must
  pass a slice audit before deployment.
- Point-in-time correctness enforced: a turn-`t` row may only contain features
  computable at turn `t`. Leakage from later turns is the easiest way to get a
  fraudulent QWK.

---

## 8. Explainability pipeline

Non-negotiable contract: **no prediction leaves the service without a complete
explanation object.** Enforced at the type level — the response DTO has no
constructor that omits it.

```
prediction
  ├─ ① SHAP           TreeSHAP (exact for LightGBM). Top-6 contributors,
  │                    signed, in original feature units.
  ├─ ② Global importance   gain-based, precomputed, shown in the model card.
  ├─ ③ Counterfactual  DiCE-style, constrained to ACTIONABLE features only:
  │                    "one answered follow-up on indexing → Moderate".
  │                    Never counterfactuals on immutable/behavioural traits.
  ├─ ④ Calibration     isotonic; reliability diagram published in the model card;
  │                    ECE reported per deployment.
  ├─ ⑤ Uncertainty     conformal prediction (Mondrian, per class) →
  │                    a prediction SET at 90 % coverage. |set|>1 ⇒ ABSTAIN.
  ├─ ⑥ Modality attribution  fusion gate weights (§4.8).
  └─ ⑦ NL explanation  templated from ①③⑤ — never free-generated, because a
                       generated explanation can describe reasoning that did
                       not occur. Templates are the guarantee of faithfulness.
```

**Reviewer-facing example:**

> **Evidence: Moderate** (90 % prediction set = {Moderate}) — *this is an
> assessment of the interview, not of the candidate.*
>
> **Strongest contributors**
> - 3 follow-ups answered, each referencing the probed span (+)
> - Answer volunteered 4 technical details not present in the claim (+)
> - Identity verified across 14 of 16 checks, longest unwitnessed gap 42 s (+)
> - No answer addressed *how* the 40 % figure was measured (−)
> - 61 % of the final answer arrived in one span, and the follow-up about it was
>   not answered (−)
>
> **To reach Strong, this session would need:** one answered question about the
> measurement method. *(counterfactual, actionable)*
>
> **Modality contributions:** answer content 46 %, process 31 %, identity 18 %,
> structure 5 %.
>
> **What this does not say:** whether to hire. Whether the candidate is honest.
> Whether the claim is true. Those remain yours.

**Candidate-facing example (same session, same numbers):**

> This session gathered **moderate** evidence for your claim about the batch
> scheduler. We asked about the section that appeared at once at 09:14 — that
> question is still open. Nothing here is a judgement of your work or your
> honesty; it is a record of what was and was not covered. You may add to it.

Same facts, no hidden second channel. That symmetry is a design requirement, not
a courtesy.

---

## 9. Pipelines

### 9.1 Training

```
raw sessions (JSONL, immutable, content-hashed)
  → validation (Great Expectations: schema, ranges, null semantics)
  → feature extraction (versioned code; feature_store_version pinned per row)
  → grouped split by candidate + temporal holdout
  → per-modality model training (LightGBM / DeBERTa / Siamese CNN / GRU)
  → fusion gate on held-out fold
  → isotonic calibration on the calibration fold
  → conformal quantiles from the calibration fold
  → evaluation: QWK · ECE · fairness slices · ablations · α ceiling comparison
  → MODEL CARD (mandatory artefact; a model without one does not deploy)
  → registry (MLflow): weights + feature_store_version + data_hash + git SHA
```

Reproducibility gate: fixed seeds, pinned deps, and a CI job that retrains on a
100-row fixture and asserts bit-identical metrics.

### 9.2 Inference

```
client event
  → feature extraction (SAME code path as training — one module, imported by both;
     a second implementation is the classic training/serving skew bug)
  → point-in-time assembly
  → modality models → fusion gate
  → calibration → conformal set
  → GUARDS: provenance gate → abstain gate → no-verdict gate → citation gate
  → SHAP + counterfactual + NL template
  → response DTO (prediction ∧ explanation, indivisible)
  → append to evidence graph as provisional
```

Latency budget: 120 ms p95 server-side (SHAP dominates). Authorship CNN and
phase GRU run on-device in Flutter.

### 9.3 Deployment topology

| Component | Where | Why |
|---|---|---|
| Face encoder, claim extractor, NLI | FastAPI (existing service) | Large models; already the established boundary. |
| $f_\theta$, $g_\phi$, fusion, SHAP | FastAPI | Needs the feature store + exact SHAP. |
| Adaptive threshold LR | Flutter (Dart) | 8 features; works offline; keeps embeddings local. |
| Authorship Siamese CNN | Flutter (TFLite) | **Raw keystroke timings must never leave the device.** |
| Phase GRU | Flutter (TFLite) | Drives UI timing. |
| Feature extraction | Shared Dart + Python spec, contract-tested | Skew prevention: one golden-fixture test asserts identical vectors from both. |

**Offline / degraded mode:** if the service is unreachable, the app collects and
queues, shows *"Evidence assessment unavailable — collection continuing"*, and
never renders a stale or on-device-approximated sufficiency without a visible
degraded-mode banner.

### 9.4 The guards (rules, un-bypassable, unit-tested)

```dart
// Each guard is a pure function with a dedicated test file.
// A model output that fails a guard is REPLACED, not adjusted.
G1 provenanceGate : coverage < 0.5 || quality == none  → Insufficient("provenance")
G2 abstainGate    : conformalSet.length > 1            → Unknown(setContents)
G3 noVerdictGate  : output ∉ {Insufficient,Weak,Moderate,Strong,Unknown} → throw
G4 citationGate   : any evidence item without a source span → drop the item
G5 monotoneGate   : assert model respects declared monotone constraints (CI)
G6 vocabularyGate : NL template contains no word from the banned lexicon
                    {hire, reject, cheat, suspicious, dishonest, risk, score,
                     likely, probably guilty, integrity violation}
```

G6 is not decoration. Language leaks judgement faster than numbers do.

---

## 10. Old vs. new

| Dimension | Current | Redesigned |
|---|---|---|
| Learned components | 1 (pretrained face encoder, used off the shelf) | 12 trained/fine-tuned components |
| Decision logic | Hardcoded thresholds (40, 20 s, 5 s, 30 s, 0.50, 3) | 8 replaced by learned models; 10 rules retained deliberately |
| Follow-up selection | 3 fixed strings from 3 triggers | LTR over a ranked question bank with expected evidence gain |
| Resume | Hardcoded demo claims in `main.dart` | DeBERTa NER+RE+agency+verifiability extraction with char-offset citations |
| Claim–answer link | Human infers from prose | NLI-proposed typed edges with cited spans, human-confirmed |
| Identity | Global 0.50 threshold, admitted uncalibrated | Session-adaptive calibrated boundary + sequence continuity model |
| Uncertainty | None | Conformal sets + isotonic calibration + explicit abstain |
| Explainability | Prose comments and a graph legend | SHAP + counterfactual + calibration + modality attribution + templated NL |
| Composite score | `IntegrityTracker.riskScore` 0–100 (philosophy violation) | **Deleted.** Replaced by unweighted timestamped facts. |
| Dataset | None | 3 datasets, one publishable, with α reported |
| Evaluation | 187 unit tests + widget tests | Unit tests **plus** QWK/ECE/NDCG/fairness/ablation on held-out data |
| Research claim | "AI interview platform" | "Evidence sufficiency modelling for human-decided technical assessment" |

**What is preserved unchanged:** the philosophy, `ClaimStatus` as a human field,
the graph's no-weight/no-ranking constraints, `Unchecked` as a first-class
outcome, null-not-zero semantics, candidate-visible observations, the audit as
source of truth, and HTML export.

---

## 11. Research contribution

**Do not cite anything in this section without fetching and reading it first.**
Named below are *areas* and *method families*, deliberately without titles,
authors, venues, years, or numbers.

### 11.1 The landscape (areas to search, and what to look for)

| Area | What exists | Typical weakness to check for |
|---|---|---|
| Automated hiring / asynchronous video interview scoring | Models predicting interviewer ratings or hire outcomes from audio/video/text | Predicts the *outcome*, inherits the bias in historical hiring decisions, and is precisely what regulation now targets. |
| Online proctoring / exam-cheating detection | CV-based gaze/object/multi-face detection, often with composite suspicion scores | Accusatory framing, no candidate recourse, high false-positive cost, thin ground truth for "cheating". |
| Keystroke-dynamics authorship & continuous authentication | Fixed-text and free-text verification, Siamese and statistical approaches | Cross-session enrolment profiles (privacy-heavy), population-relative comparison, binary accept/reject framing, weak fairness analysis across motor ability and keyboard type. |
| Automated short-answer & code assessment | Grading models over answers and code | Grades correctness; says nothing about provenance or about whether *enough was asked*. |
| Interview question generation | LLM generation from a JD or resume | Optimises plausibility/fluency; no notion of evidence gain, no measurement of whether the question worked. |
| Selective prediction & conformal methods | Abstention with coverage guarantees | Well developed in ML broadly; **rarely applied to hiring-adjacent systems**, which is an opening. |
| Multimodal fusion for behaviour | Early/late/attention/tensor fusion | Assumes modality availability; graceful degradation under real-world missingness is under-studied. |
| Knowledge/evidence graphs for assessment | Concept graphs, learner models | Typically culminate in a mastery score — the thing this project refuses to produce. |

### 11.2 The gap

Every line above optimises one of two targets: **the candidate's quality**, or
**the candidate's honesty**. No line optimises **the interview's evidential
completeness**. That target has three properties that make it a genuine research
object rather than a rebranding:

1. It is a property of an *artefact* (the session), so it can be annotated
   without judging a person, sidestepping the ground-truth-is-a-biased-human-
   decision problem that undermines hiring-outcome models.
2. It is *actionable* — a low value implies a specific next question, which
   makes it directly usable in a sequential decision problem.
3. It is *falsifiable by convergent validity* — sessions with high predicted
   sufficiency should yield faster, more consistent human decisions, an outcome
   the model never sees in training.

### 11.3 Contributions claimed

**C1 — Evidence Sufficiency Modelling (primary).** Formulate technical interview
assessment as predicting the *sufficiency of gathered evidence for a claim*
rather than candidate quality or deception. Includes the task definition, the
annotation protocol designed to block competence leakage (§5.1), and the
convergent-validity evaluation (§6).

**C2 — Within-session self-referential authorship consistency.** Use the
candidate as their own control within a single session, so no stored biometric
profile and no population comparison is needed, and route the signal to
*question selection* rather than to a flag. Novel in framing (self-referential,
non-accusatory, on-device) and in application (evidence routing, not
authentication). Fairness protocol across typing speed and keyboard type is part
of the contribution.

**C3 — Abstention-first architecture for high-stakes advisory ML.** Conformal
prediction sets plus hard guards, where "Unknown" is a first-class deployed
output and the abstain rate is a *reported headline metric*, not a footnote.
Combined with monotonic constraints that encode policy into the hypothesis
space, this is a transferable pattern for regulated advisory systems.

**C4 — The `CogniHire-Evidence` dataset.** First public dataset pairing resume
claims, interview process telemetry, provenance signals, and human evidence-
sufficiency judgements with raw per-annotator labels released.

**C5 — A negative result worth publishing.** Removing the composite integrity
score does not degrade — and is hypothesised to improve — inter-reviewer
agreement, and graph neural networks are not justified at session scale. Papers
in this space rarely report what they *removed*.

### 11.4 Research questions and hypotheses

- **RQ1** Can evidence sufficiency be annotated reliably? **H1** α ≥ 0.67 with the §5.1 protocol.
- **RQ2** Can it be predicted? **H2** QWK within 0.05 of the annotator ceiling.
- **RQ3** Does process telemetry add signal beyond answer content? **H3** ablating groups A–C drops QWK by ≥0.06.
- **RQ4** Does learned question ranking beat rule triggers? **H4** NDCG@5 improvement and higher reviewer-rated usefulness on replayed sessions.
- **RQ5** Is the within-session authorship signal discriminative *and* fair? **H5** AUC ≥ 0.75 on same/different-production spans, with no significant deviation-score difference across typing-speed deciles.
- **RQ6** Does abstention help? **H6** selective accuracy rises monotonically as coverage falls, and reviewer trust (survey) is higher with abstention than with forced prediction.
- **RQ7** Convergent validity. **H7** high-sufficiency sessions yield lower reviewer decision time and higher inter-reviewer agreement.

### 11.5 Ablations to run

modality drop-one (×4) · feature-group drop-one (×10) · fusion strategy (early /
late / late+gate / transformer) · model family (RF / XGB / **LGBM** / CatBoost /
MLP / TabTransformer) · calibration on/off · conformal on/off · monotonic
constraints on/off · rule-baseline vs. LTR · Siamese CNN vs. Mahalanobis
baseline · with/without the deleted integrity score (reviewer study).

### 11.6 Threats to validity

*Construct:* sufficiency is annotator consensus, not truth (§6). *Internal:*
candidate-grouped splits are mandatory; point-in-time correctness prevents turn
leakage. *External:* a single-institution student population; generalisation to
industry hiring is unproven and must be stated. *Ethical:* even a non-accusatory
process signal can be misused by a downstream employer — mitigated by the guards,
the candidate-facing symmetry, and by not exporting any raw behavioural score.
*Statistical:* n≈2 000 with candidate grouping gives an effective n closer to
200; report confidence intervals, not point estimates.

---

## 12. Migration roadmap

Sequenced by dependency, not by appeal. Effort assumes one student
full-time-equivalent; ×0.6 if two people split ML and app work.

### Phase 0 — Foundations (2 weeks) · **BLOCKING**

| # | Task | Effort |
|---|---|---|
| 0.1 | Upgrade telemetry to keystroke-level events (§2.5). **Nothing else can start without this.** | 3 d |
| 0.2 | Delete `IntegrityTracker`, `violation_rules` weights, and every UI surface for `riskScore` (§2.9) | 1 d |
| 0.3 | Event logging + session serialisation for offline ML consumption | 2 d |
| 0.4 | Feature-store scaffold with null semantics + point-in-time assembly | 3 d |
| 0.5 | Consent flow, two-checkbox research consent, privacy scrubbing (§5.4) | 2 d |
| 0.6 | Fix the home-screen layout overflow whose root cause is still unknown (existing gotcha) — a data-collection build cannot ship with an unexplained render bug | 1 d |

### Phase 1 — First real ML (3 weeks)

| # | Task | Effort |
|---|---|---|
| 1.1 | Resume claim extraction, LLM weak-label pipeline + DeBERTa fine-tune (§4.1) | 6 d |
| 1.2 | Replace hardcoded claims in `main.dart` with extractor output | 2 d |
| 1.3 | Feature groups A–C implemented + contract-tested Dart↔Python (§9.3) | 4 d |
| 1.4 | Adaptive identity threshold (§4.2), ported to Dart | 3 d |
| 1.5 | Capture-quality head (§4.11), replacing `minEnrolmentFaceSize` | 1 d |

### Phase 2 — Data collection (4 weeks, parallel with 3)

| # | Task | Effort |
|---|---|---|
| 2.1 | Annotation tool + gold items + the §5.1 protocol | 5 d |
| 2.2 | Recruit and run ~200 consented sessions | 15 d (elapsed) |
| 2.3 | Three-annotator pass + adjudication + α computation | 8 d |
| 2.4 | Dataset packaging, versioning, datasheet | 3 d |

### Phase 3 — The primary model (3 weeks)

| # | Task | Effort |
|---|---|---|
| 3.1 | Remaining feature groups D–J | 5 d |
| 3.2 | $f_\theta$ training + model comparison + monotonic constraints (§4.3) | 5 d |
| 3.3 | Isotonic calibration + conformal prediction + abstain gate | 3 d |
| 3.4 | SHAP + counterfactual + templated NL + guard suite (§8, §9.4) | 5 d |
| 3.5 | Reviewer UI: sufficiency alongside — never merged with — `ClaimStatus` | 3 d |

### Phase 4 — Adaptive interviewing (3 weeks)

| # | Task | Effort |
|---|---|---|
| 4.1 | Question bank (≥200 items, typed, difficulty-tagged) | 4 d |
| 4.2 | Bi-encoder retrieval + LambdaMART ranker (§4.5) | 5 d |
| 4.3 | Replace `FollowUpGenerator` triggers with the ranker | 2 d |
| 4.4 | Answer↔claim NLI + provisional graph edges (§4.7) | 4 d |
| 4.5 | Multimodal late-fusion gate (§4.8) | 3 d |

### Phase 5 — Novelty + paper (4 weeks)

| # | Task | Effort |
|---|---|---|
| 5.1 | Keystroke lab collection (120 participants) | 8 d |
| 5.2 | Siamese authorship CNN + TFLite on-device (§4.6) | 6 d |
| 5.3 | Fairness audit across typing speed / keyboard / L2-English | 4 d |
| 5.4 | Full ablation suite (§11.5) | 5 d |
| 5.5 | Reviewer study for C5 (integrity-score removal) | 4 d |
| 5.6 | Paper draft, IEEE format | 8 d |

### Phase 6 — Optional / stretch

Contextual-bandit planner in shadow mode (§4.4) · interview phase GRU (§4.9) ·
knowledge-coverage grid (§4.10) · cross-session graph + GNN link prediction (§14).

**Total to a defensible ML project: ~15 weeks (Phases 0–4).**
**To a submittable paper: ~19 weeks.**

### Priority, if time is short

1. **P0** Phase 0 entirely. Non-negotiable and cheap.
2. **P0** 1.1–1.2 (resume NLP) — the highest visibility-per-effort ML in the project.
3. **P0** Phase 2 (data) — the long pole; start recruiting during Phase 1.
4. **P1** Phase 3 ($f_\theta$ + XAI) — this is the project's spine.
5. **P1** 4.2–4.3 (ranker) — replaces the most obviously rule-based module.
6. **P2** Phase 5.2 (authorship) — the novelty; drop it before dropping P0/P1.
7. **P3** Everything else.

---

## 13. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Not enough annotated sessions; model undertrained | **High** | Start recruiting in week 1. Fall back to a leave-one-candidate-out study on n=80 with confidence intervals — a small, honestly-reported study beats a large fabricated one. |
| R2 | Annotator agreement α < 0.5 → the construct may not be real | **High** | This is a *finding*, not a failure. Report it, refine the rubric once, and if it stays low, pivot the paper to "why evidence sufficiency is hard to annotate", which is publishable. |
| R3 | Sufficiency model silently becomes a competence predictor | **Critical** | Never train on `ClaimStatus`; adversarial-probe the model (can a linear probe recover reviewer status from $f_\theta$'s hidden features? if yes, remove the leaking features); annotation prompt explicitly blocks it; monotonic constraints. |
| R4 | Authorship feature is unfair to slow typists / non-standard keyboards | **Critical** | Fairness gate in §4.6 metrics — the feature ships only if slice distributions are indistinguishable. Prepared to drop C2 entirely. |
| R5 | Training/serving skew between Dart and Python feature extraction | Med | Single spec + golden-fixture contract test in CI (§9.3). |
| R6 | Latency: SHAP at 120 ms p95 breaks the live loop | Med | Precompute SHAP asynchronously; the live loop needs only the ranker (<5 ms). |
| R7 | Scope: 12 ML components in 19 weeks is ambitious | **High** | The priority list in §12 is the contract. Ship P0–P1 fully rather than all of it partially. |
| R8 | Face service is a single point of failure | Med | Degraded mode already specified (§9.3); `Unchecked` is a first-class outcome, so the system is *designed* for the camera being unavailable. |
| R9 | Reviewers over-trust the model despite the framing | Med | This is the deepest risk and is itself worth studying — measure it in the 5.5 reviewer study. Guards + language rules + abstention are the mitigations. |
| R10 | The 187-test suite was blind to screen crashes until widget tests arrived | Med | Widget tests now exist; extend them to every new ML-backed screen before that screen ships. |
| R11 | Ethics/IRB approval delays the lab collection | Med | Submit the protocol during Phase 0, not Phase 5. |
| R12 | A reviewer of the paper reads "interview AI" and assumes hiring prediction | Low | Title and abstract must lead with what the system refuses to predict. |

---

## 14. Future research

1. **Cross-session graph learning — the justified GNN.** Once sessions share a
   technology ontology, GraphSAGE link prediction over (claim-type → question)
   solves the ranker's cold-start on unseen technologies. This is the point at
   which graph ML earns its place; not before.
2. **Causal evidence gain.** Move from "questions correlated with sufficiency
   gain" to a causal estimate via randomised question assignment within a
   ethically-bounded arm.
3. **Active learning for annotation.** Route only high-uncertainty sessions to
   the three-annotator protocol; cut annotation cost by an estimated half.
4. **Multilingual and L2-English fairness.** The semantic features (G12–G15) are
   the most likely source of bias against non-native speakers; a dedicated study
   is warranted.
5. **Federated authorship modelling.** The Siamese CNN already runs on-device;
   federated fine-tuning would let it improve without any keystroke data leaving
   any phone.
6. **Reviewer-behaviour modelling.** What *do* reviewers actually read first, and
   does high sufficiency change how they decide? Feeds C1's convergent validity.
7. **Adversarial robustness.** If a candidate knows the system measures process,
   they can mimic. Characterising the mimicry cost is a real security question —
   and note that the answer may be "mimicking authorship is as hard as writing
   the code", which would be a strong positive result.
8. **Sufficiency for non-technical claims.** Does the formulation transfer to
   leadership or communication claims, where evidence is even more contested?

---

## 15. Summary

CogniHire becomes an ML project by learning the right thing. It does not learn
who to hire — that stays human, by design and by regulation. It does not learn
who is cheating — that has no ground truth and the attempt is what makes these
systems harmful. It learns **how complete the evidence is, and what to ask
next**, which is a legitimate, annotatable, actionable, and — as far as the
literature search in §11.1 should be expected to confirm — unclaimed research
target.

Twelve learned components, 158 features, three datasets, five contributions, ten
rules kept because they were right, eight replaced because they were arbitrary,
and one score deleted because it should never have been there.

**AI measures. Humans decide.** The redesign makes the measuring learned, and
leaves the deciding exactly where it was.
