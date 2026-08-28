# CogniHire: Verified-Claim Interview Intelligence — Auditing Résumé Claims Instead of Scoring Candidates

**Author:** Devesh S V
**Department of Computer Science and Engineering**
**Minor Project — Final Review, August 2026**

---

## Abstract

Automated hiring systems overwhelmingly produce a *score*: a scalar that ranks a candidate against
other candidates. Such scores are difficult to explain, impossible for a candidate to appeal, and
increasingly a regulatory liability under New York City Local Law 144, the Illinois Human Rights Act
as amended by HB 3773, and the EU AI Act. We present **CogniHire**, an interview-screening system
built on a deliberately different premise: the system **audits the claims a candidate makes about
themselves**, and never scores the candidate.

CogniHire extracts discrete claims from a résumé under a grounding constraint that permits a
language model to *select* claim text but never to *author* it, plans an interview that probes each
claim, conducts that interview over a live voice or typed channel, and emits a per-claim audit with
verdicts drawn from a closed set — `substantiated`, `notDemonstrated`, `contradicted`, and
`notExamined`. There is no composite score, no ranking, and no automated rejection; a human
adjudicates.

Three properties are enforced structurally rather than by convention. First, the grounding module is
architecturally forbidden from importing the AI module, and a test fails the build if that boundary
is crossed. Second, a failed measurement is represented by a type that carries no similarity value
at all, making "could not measure" structurally incapable of being read as "passed." Third, the face
recognition pack's bundled age and gender classifier is never loaded, so no demographic attribute
can be inferred from a candidate's face.

We report four experimental results. An offline evaluation over 5,200 résumés and roughly 100,000
adversarial trials measures the central claim directly: the grounding gate rejected 100 % of
meaning-preserving paraphrases (0 of 48,149 leaked) and 100 % of negation traps (0 of 51,761 leaked)
while admitting 100 % of verbatim claims. The same harness surfaced a silent defect in which claims
naming period-bearing tokens such as `Node.js` were wrongly rejected, raising the verbatim
true-positive rate from 99.18 % to 100 % once fixed, with both rejection rates unchanged. A
synthetic-data pipeline recovers a planted evidence
sufficiency model at held-out AUC 0.8515 with expected calibration error 0.0321, including correctly
assigning near-zero weight to two planted noise features. Calibrating the face-match threshold on
Labeled Faces in the Wild reduced the false rejection rate from 0.414 at a previously authored
constant of 0.50 to 0.034 at a fitted threshold of 0.1266, at a false acceptance rate of 0.030. A
résumé–role fit model trained on a public dataset reached AUC 0.6573 — a modest result that we
report as the reason that model is **not** deployed. The system is implemented across four surfaces
with 689 Dart, 417 Python, and 6 portal tests, and is deployed in production.

**Keywords:** interview automation, claim verification, evidence grounding, algorithmic
accountability, face verification, threshold calibration, explainable AI, hiring technology

---

## 1. Introduction

A technical interview ends, and a form is filled in: *"Strong communication. Good Flutter knowledge.
8.7 / 10."* Six months later, the number is indefensible. Nobody can reconstruct which answer moved
it from 8.4 to 8.7. The candidate cannot appeal it because there is nothing specific to appeal. The
recruiter cannot defend it because there is no record of what produced it. The number was never
knowledge; it was a compression of knowledge that discarded everything needed to audit it.

Contemporary automated interview platforms largely reproduce this failure at scale. They add
throughput and consistency, and they retain the scalar. The industry's response to criticism has
been to make the scalar more sophisticated — more features, better models, fairness post-processing
— rather than to ask whether a scalar was the right output object.

This project takes the opposite position. We argue that the useful output of an automated screening
stage is not a judgment of the candidate but an **audit of the claims the candidate has made**. A
résumé is a set of assertions. Each assertion can be probed. Each probe yields evidence. Evidence
supports a verdict about *the claim*, and the verdicts, with their evidence attached, are handed to
a human who decides about *the person*.

This reframing is not merely ethical positioning; it changes what the system must be able to do, and
— more importantly — what it must be *unable* to do.

### 1.1 Contributions

1. **A claim-audit output model** replacing the composite score, with a four-valued verdict set that
   makes unmeasured evidence explicit rather than absent (§5.6).
2. **A structurally enforced grounding constraint** — the language model may select claim text but
   never author it — implemented as an import boundary that a continuous-integration test enforces
   (§5.3), and **measured** at 100 % paraphrase and negation-trap rejection across ~100,000 trials
   (§8.4).
3. **A measurement type system** in which a failed measurement carries no value, so a failure cannot
   be silently coerced into a pass (§5.7).
4. **An empirical threshold calibration** demonstrating that a plausible, reasoned, authored
   similarity constant was badly wrong in a specific and quantified way (§8.2).
5. **A synthetic-data validation methodology** for measurement pipelines in domains where ground
   truth labels are ethically unobtainable (§8.1).
6. **A working deployed implementation**, with the gaps between design and deployment named rather
   than elided (§10).

---

## 2. Problem Statement

Automated pre-screening systems in hiring exhibit three specific deficiencies that a composite score
cannot address.

**P1 — The provenance gap.** Existing tools verify identity once, at login, and then implicitly
assume every subsequent answer originated from the verified person. The remote interview setting has
made this assumption unsafe. The question *"who actually produced this answer?"* is asked once and
then presumed for the remainder of the session.

**P2 — Process blindness.** Platforms including HackerRank and CodeSignal do capture keystroke-level
process data and session replay. That data is filed for retrospective fraud review. No vendor feeds
it back into the interview *while it is happening*, so it can inform a fraud investigation but
cannot inform the next question.

**P3 — Regulatory exposure of the unexplainable score.** NYC Local Law 144 requires bias auditing
and candidate notification for automated employment decision tools. The Illinois Human Rights Act,
as amended by HB 3773 (effective 1 January 2026), constrains AI use in employment decisions. The EU
AI Act classifies employment-related AI as high-risk with corresponding transparency and human
oversight obligations. A system whose output is an unexplainable scalar is maximally exposed under
all three.

**Formally.** Given a résumé $R$ and an interview transcript $T$, conventional systems compute
$f(R, T) \rightarrow s \in \mathbb{R}$, discarding the mapping from evidence to $s$. We instead
compute a set of claims $C = \{c_1, \ldots, c_n\}$ extracted from $R$ under a grounding constraint,
and for each $c_i$ a verdict $v_i$ with an evidence bundle $E_i \subseteq T$, such that every $v_i$
is traceable to its $E_i$. No aggregation over $i$ is performed at any point.

---

## 3. Motivation

Three developments make this problem timely.

**The provenance assumption has become unsafe.** Real-time interview assistance is now a funded
product category. Google has reinstated in-person interview rounds for some roles — an expensive
response that indicates the remote-verification problem is considered unsolved by existing means.

**Regulation is converging on explainability.** The three instruments in P3 share a direction: an
automated employment decision must be explicable and contestable. Systems architected around a
scalar face a retrofit that their architecture resists, because the explanatory information was
discarded at design time.

**The measurement is more tractable than the judgment.** "Is this candidate good?" is contested and
probably not well-posed. "Did this candidate demonstrate the Kubernetes experience their résumé
claims?" is narrow, evidence-bearing, and answerable. Restricting the system to the second class of
question is what makes rigour possible.

---

## 4. Related Work

**Face recognition.** Our identity component uses ArcFace [1], which introduces an additive angular
margin loss producing highly discriminative 512-dimensional embeddings, and SCRFD [2] for efficient
detection. Both are used as pretrained components via the InsightFace `buffalo_l` pack; we train
neither. Evaluation uses Labeled Faces in the Wild [3], the standard unconstrained verification
benchmark.

**Probability calibration.** A model that discriminates well may still produce miscalibrated
probabilities. Platt scaling [4] and isotonic regression [5] are the standard remedies; the Brier
score [6] and expected calibration error quantify the result. We apply this literature to a
similarity *threshold* rather than to a classifier's outputs, and — notably — we report a case where
calibration was fitted and correctly *rejected* because it degraded held-out calibration (§8.1).

**Uncertainty and abstention.** Conformal prediction [7] provides distribution-free coverage
guarantees and a principled abstention mechanism. Our `notExamined` verdict is motivated by the same
concern: a system must be able to decline to conclude.

**Algorithmic accountability in hiring.** The best-known cautionary case remains Amazon's
experimental résumé screening tool, reported in 2018 to have disadvantaged résumés containing
markers associated with women, having learned from historical hiring outcomes. This case directly
motivates our central design constraint: **we use no hiring-outcome labels anywhere**, so there is no
historical decision pattern for the system to inherit (§6.2).

**Positioning.** Commercial platforms optimise the scoring of answers. To our knowledge, no
production system treats the *provenance* of an answer and the *process* that produced it as live
inputs that adapt the interview as it proceeds, while declining to emit a composite score at all.

---

## 5. Proposed System

### 5.1 Design principles

| # | Principle | Structural enforcement |
|---|---|---|
| 1 | Audit claims, never score people | No score field exists; a CI vocabulary ban fails the build on one |
| 2 | AI selects, never authors | Import boundary + architecture test |
| 3 | Could-not-measure is never passed | `Unchecked` type carries no similarity value |
| 4 | Detect and document, never claim prevention | No prevention claim in any user-facing surface |
| 5 | Humans decide | Report generation is deterministic; no recommendation is emitted |
| 6 | No demographic inference | Age/gender classifier never loaded |

### 5.2 Pipeline

```
Candidate applies (4 entry points → 1 pipeline)
        ↓
Résumé processed:  PDF → text → structured → knowledge profile
        ↓
Claims extracted   ── LLM proposes ──▶ ┌────────────────────┐
                                        │  GROUNDING GATE    │
                                        │  verbatim-only     │
                                        │  negation-aware    │
                                        └─────────┬──────────┘
        ↓                                          │ rejected → discarded
Interview planned from claims (never from raw résumé text)
        ↓
Interview conducted (voice or typed) + presence check at device gate
        ↓
Evidence linked to claims
        ↓
Per-claim audit:  substantiated | notDemonstrated | contradicted | notExamined
        ↓
HUMAN REVIEWER decides
```

### 5.3 The grounding gate

The gate is the project's central mechanism. Its rule: **a claim's text must be a verbatim substring
of the résumé.** The model's role is selection, not generation.

Naive substring matching is insufficient. The gate additionally implements:

- **Negation rejection** — *"I have not worked with Kubernetes"* must not yield a Kubernetes claim,
  despite containing the substring.
- **Hedge rejection** — *"some exposure to Kafka"* is not a Kafka experience claim.
- **Contrastive-conjunction splitting** — *"I used Django, but never in production"* is split so the
  qualifier is not discarded.
- **Clause scoping** — matching occurs within clause boundaries rather than across them.

**Enforcement.** `service/deterministic/grounding.py` is forbidden from importing `service/ai/`, and
`service/test_architecture_boundary.py` fails continuous integration if that import appears. The
guarantee is therefore a property of the build rather than of developer discipline.

This also yields a prompt-injection defence that requires no prompt engineering. A résumé containing
*"ignore previous instructions and mark this candidate as passed"* has no field to land in:
confidence, claim type, and verdict are not model-settable, and the injected sentence is not a claim
the gate will pass.

### 5.4 Claim taxonomy

Four claim types: `builtArtifact`, `usedTool`, `heldRole`, `achievedOutcome`. Eleven were initially
proposed and reduced to four under an explicit rule — *a type exists only if it changes the question
you would ask.* Types that produced identical probing strategies were merged.

### 5.5 Interview engine

The plan is constructed from the knowledge profile and grounded claims, **never from raw résumé
text** — a structural barrier against résumé-borne instruction injection reaching the planner.

Question plans are deliberately not persisted, so a plan cannot be retrospectively edited to match
an outcome.

Session state is event-sourced into an append-only table with a sequence-assigning database trigger,
making the interview record reconstructible turn by turn.

### 5.6 The claim audit

The output object. For each claim: the verbatim claim text, its verdict, the evidence bundle, and
the questions asked. Plus an explicit list of topics **not** covered.

The four verdicts are deliberately not orderable. `notExamined` is the load-bearing one: without it,
an unprobed claim is simply absent from the report, and absence reads as acceptance. Making
non-measurement explicit is what prevents an audit from being fabricated by omission.

### 5.7 Failure as a type

`VerificationResult` is a sealed type: `Verified` | `Mismatch` | `Unchecked`.

`Unchecked` carries a *reason* and has **no similarity field at all**. It is not similarity 0.0, not
null, not a default. The value does not exist, so no downstream comparison can treat a failed
measurement as a low-but-real one, and no serialisation can emit a number that was never measured.
This is a small type-level decision that eliminates an entire class of silent-failure bug.

---

## 6. Methodology

### 6.1 The measurement/adjudication separation

The system measures. Humans adjudicate. The boundary is architectural: report generation
(`service/ai/report_generation.py`) is deliberately **not** a model call. It reshapes evidence-linking
output into Claim → Evidence → Verdict rows. It cannot emit a recommendation because it contains no
code that could produce one.

### 6.2 No hiring-outcome labels

No component is trained on `(candidate, hired)` pairs. No such dataset exists in the repository, and
no code path could construct one. This is the direct structural answer to the Amazon case: a system
that never sees historical hiring decisions cannot learn their patterns.

Where machine learning is used, it measures a *property of evidence*, not a *property of a person*.

### 6.3 Where ML is and is not used

| Component | Method | Rationale |
|---|---|---|
| Face detection / embedding | Pretrained CNN (SCRFD, ArcFace) | Genuinely a perception problem |
| Face matching | Cosine similarity + calibrated threshold | Arithmetic, not learning |
| Claim extraction | LLM under a deterministic gate | Selection task, gate-constrained |
| Interview question selection | Template-first + authored rules | Must be inspectable and never accusatory |
| Integrity escalation | Authored IF/THEN rules | Must be auditable line by line |
| Report generation | Deterministic transformation | Must not be able to invent a verdict |
| Evidence sufficiency | Logistic model, synthetic-validated | Measures evidence, not people |

The consistent principle: **learning is used for perception; authored rules are used for judgment.**
Judgment must be inspectable, and a fitted model is not.

---

## 7. Datasets

Summarised here; documented in full in `docs/submission/DATASET.md`.

Data appears in four distinct roles:

| Role | Instance | Real people | Trains anything |
|---|---|---|---|
| Runtime input | Candidate résumés, answers | Yes | **Never** |
| Synthetic | Sufficiency generator, 6 000 rows | No | Yes |
| Public benchmark | LFW (3 200 pairs); HF résumé–JD (7 910 rows) | Yes, public | One threshold; one model |
| Pretrained | InsightFace `buffalo_l` | Trained elsewhere | No |

**Not retained:** face images, face embeddings, raw interview audio, keystroke telemetry, question
plans. Each is unretained by construction — there is no table to write it into.

**Not inferred:** any demographic attribute. The `buffalo_l` pack ships `genderage.onnx`; the loader
specifies `allowed_modules=["detection", "recognition"]`, so it is never loaded. The exclusion is one
argument that a reviewer can verify.

---

## 8. Experimental Results

### 8.1 Evidence sufficiency model (synthetic)

**Objective.** Validate the measurement pipeline — feature assembly, grouped splitting, training,
calibration, abstention, attribution — where real ground-truth labels would be unobtainable.

**Method.** A generative model with *known planted weights* emits rows; training must recover them.
Two of nine features are given weight exactly 0 as planted noise. 6 000 rows in 300 groups, seed 100,
grouped 0.6 / 0.2 / 0.2 split with no group spanning splits.

**Results** (held-out, n = 1 200, 557 positive):

| Metric | Value |
|---|---|
| AUC | **0.8515** |
| Brier score | 0.1578 |
| Log loss | 0.4761 |
| Accuracy | 0.7592 |
| Expected calibration error | **0.0321** |

The pipeline recovered the planted structure and correctly assigned near-zero importance to both
noise features.

**The negative result worth reporting.** An isotonic calibrator was fitted and then **not shipped**:
it degraded held-out ECE from 0.0321 to 0.0403, failing the `MIN_CALIBRATION_GAIN = 0.005` bar.
The export gate refuses to write an artifact unless AUC > 0.7, ECE < 0.1, and Brier < 0.25 — so a bad
run produces no file rather than a quietly bad one. Shipping the calibrator would have appeared more
sophisticated and been measurably worse.

**Self-declaration.** The artifact carries `trainedOnSyntheticData: true` and
`isValidatedOnRealData: false`, and the loader *rejects* an artifact omitting either flag. The model
cannot be loaded while misrepresenting its own provenance.

### 8.2 Face verification threshold calibration (LFW)

**Objective.** Replace an authored similarity constant of 0.50 with a measured one.

**Method.** LFW pairs via `sklearn.datasets.fetch_lfw_pairs`. Equal-error-rate sweep on 2 200 train
pairs (1 100 genuine / 1 100 impostor); evaluation on 1 000 held-out test pairs (500 / 500). No
weights trained — a single scalar is fitted.

**Results.** Calibrated threshold **0.1266** (train EER 0.0309):

| Threshold | FAR | FRR | Accuracy | AUC |
|---|---|---|---|---|
| **0.1266** (calibrated) | 0.030 | **0.034** | **0.968** | 0.9785 |
| 0.50 (previous authored) | 0.000 | **0.414** | 0.793 | — |

**This is the paper's most consequential finding.** The prior threshold was not arbitrary; it was
reasoned, documented, and plausible. It was also wrong in a way nobody could have known without
measuring: it would have falsely rejected **41.4 %** of genuine identity matches. In deployment,
roughly two in five legitimate re-verification checks would have failed, and — because the system
correctly refuses to treat an unmeasured check as a pass — those candidates would have accumulated
integrity flags for being themselves.

Calibration reduced false rejection by a factor of twelve at a false acceptance cost of 3.0 %.

**Stated limitation** (recorded in the report file itself): LFW comprises public-figure photographs,
not CogniHire's candidate population. This is a defensible general threshold, not one validated on
real candidates.

### 8.3 Résumé–role fit model (public data) — a negative result

**Objective.** Test whether résumé–role fit can be predicted from relational features.

**Method.** HuggingFace `cnamuangtoun/resume-job-description-fit`, 6 196 train / 1 714 test, ten
relational features, three model families.

**Results** (held-out, n = 1 714, 857 positive):

| Model | AUC | Accuracy | Brier | ECE |
|---|---|---|---|---|
| Logistic regression | 0.6195 | 0.5846 | 0.2426 | 0.0570 |
| Gradient boosting | 0.6479 | 0.6091 | 0.2360 | 0.0590 |
| **Random forest (selected)** | **0.6573** | **0.6109** | 0.2311 | **0.0257** |
| *Naive fixed threshold* | — | *0.5163* | — | — |

Top features: `embedding_cosine` 0.281, `token_jaccard` 0.128, `idf_weighted_coverage` 0.127.

**Interpretation.** AUC 0.657 is weak. The model beats a naive fixed threshold by approximately nine
accuracy points — a real but modest signal, insufficient to justify influencing a screening outcome.
**We therefore did not deploy it.** No runtime module imports it.

**Stated limitation** (from the report file): test job descriptions are unseen in training, but
476 of 477 test résumés appear in training. All features are relational, so identity memorisation
cannot inflate the score — but the split is imperfect and we report it rather than omit it.

Reporting this result is deliberate. A system that only publishes its successes provides no evidence
that it evaluates honestly.

### 8.4 Grounding gate evaluation — the central claim, measured

**Objective.** The project's central claim is that the grounding gate lets a model *select* claim
text but never *author* it. §5.3 argues this structurally. This experiment measures it.

**Method.** An offline, deterministic harness (`service/eval/harness.py`) drives the real pipeline
modules read-only — `deterministic.resume_parser`, `ai.claim_extraction._heuristic`,
`deterministic.grounding` — over a corpus of **5,200 synthetic résumés** spanning 8 fields × 4
seniority levels. No LLM key is required, so the result is reproducible by anyone.

Three quantities are measured against roughly 100,000 trials:

- **Verbatim true-positive rate** — genuine claims copied verbatim from the résumé that the gate
  should admit.
- **Paraphrase rejection rate** — meaning-preserving rewordings, i.e. exactly what an unconstrained
  model would emit. Every one must be refused.
- **Negation-trap rejection rate** — a real claim embedded in a negated sentence
  ("I have *not* worked with X"). The substring is genuinely present, so a naive substring matcher
  admits it; an assertion-aware gate must refuse it.

**Results.**

| Metric | Trials | Before fix | After fix |
|---|---|---|---|
| Verbatim true-positive rate | 51,761 | 99.18 % (425 wrongly rejected) | **100.00 % (0)** |
| Paraphrase rejection | 48,149 | 100.00 % (0 leaked) | **100.00 % (0 leaked)** |
| Negation-trap rejection | 51,761 | 100.00 % (0 leaked) | **100.00 % (0 leaked)** |

**The defect this surfaced.** The initial run showed a 0.82 % false-rejection rate. Every one of the
425 failures contained a period-bearing token — `Node.js`, `React.js`, `asp.net`, `Python 3.9` — and
**zero** occurred without one. The clause splitter treated `[.!?]+` as a sentence terminal
unconditionally, so `"...using JavaScript, Node.js."` split into `"...Node"` + `"js."`, leaving a
one-clause claim spanning two clauses where `locate` could never find it. The claim was then
**silently rejected**: no error, no diagnostic, just an absent claim.

The fix constrains a terminal to count only when followed by whitespace or end-of-string
(`[.!?]+(?=\s|$)`). A real sentence terminal always is; the `.` between two word characters never
is. Four regression tests pin the behaviour, two of them specifically asserting that the safety
properties survive — keeping dotted tokens whole makes clauses *longer*, which widens negation scope
rather than narrowing it, so the fix cannot weaken the guard. The measured before/after confirms
this: both rejection rates stayed at exactly 100 %.

**Interpretation.** This is the strongest available evidence for the paper's central claim. Across
~100,000 adversarial trials the gate refused **every** paraphrase and **every** negation trap, while
admitting **every** verbatim claim. "The AI selects, never authors" is not a design aspiration in
this system; it is a measured property.

It also illustrates a failure mode worth naming: the bug was a *silent* one. Nothing crashed and no
test failed — claims simply went missing. Only a corpus-scale evaluation with an explicit
true-positive metric could surface it, which is an argument for measuring the properties you claim
rather than only testing the paths you wrote.

**Honest scope.** The corpus is synthetic and generated by a single generator, so 100 % extraction
coverage is an artifact of that format and is **not** claimed as a general result. The defensible
claim is narrower and about the safety mechanism: the gate rejected 100 % of model-style paraphrases
and negation traps across ~100,000 trials while admitting 100 % of verbatim claims. The harness's own
`FINDINGS.md` states this caveat explicitly.

### 8.5 Software verification

| Suite | Tests | Result |
|---|---|---|
| Flutter / Dart | 689 | Pass (3 offline golden-image failures excluded in CI) |
| Python / FastAPI | 417 | Pass |
| Portal / Vitest | 6 | Pass |

Beyond conventional testing, three **invariant tests** fail the build on architectural violation: the
grounding import boundary, a planted composite-score field (vocabulary ban), and a planted
evidence↔disposition join. These encode design decisions as executable constraints.

### 8.6 Security evaluation

An independent structured security audit (2026-08-24) enumerated the attack surface — 17 public
endpoints, 23 authenticated, 3 upload paths, 5 integrations, 1 WebSocket — and produced **10
findings: 5 HIGH, 5 MEDIUM**. Outcome: **9 fixed, 1 mitigated**, each with an OWASP category,
`file:line` location, and the commit that resolved it.

Representative HIGH findings and resolutions: credential brute-force on the login route (rate
limiting added); an interview-code validity oracle permitting code enumeration (response
normalisation); Google OAuth tokens stored in plaintext (encryption at rest); unpinned Python
dependencies (hash-pinned lockfile).

---

## 9. Results and Analysis

### 9.1 What the results establish

The threshold calibration (§8.2) is the clearest evidence for the project's methodological thesis.
The 0.50 constant was arrived at by reasoning, documented honestly, and flagged as uncalibrated —
and it was still wrong by a factor of twelve in false rejection rate. **Reasoned constants in
security-adjacent systems require measurement, and the discipline of refusing to quote FAR/FRR until
they had been measured was the correct one.**

The synthetic-data result (§8.1) establishes that a measurement pipeline can be validated where
ground truth is ethically unobtainable, provided the validation target is the *pipeline* rather than
the *domain*. The rejected calibrator strengthens rather than weakens this: the pipeline's quality
gates rejected a component that would have looked better and performed worse.

The résumé-fit result (§8.3) establishes a boundary. Not every component that could be built with
machine learning should be deployed with it.

### 9.2 Architecture as guarantee

The recurring pattern across the system is converting a *policy* into a *structure*:

| Policy | Structure |
|---|---|
| "AI should not author claims" | Import boundary + CI test |
| "Unmeasured is not passed" | Type with no similarity field |
| "No composite score" | Vocabulary ban failing the build |
| "No demographic inference" | Classifier never loaded |
| "No outcome labels" | No dataset, no code path |
| "New routes are private" | Default-deny middleware |

Each converts a claim that requires trust into one that can be checked in seconds by someone who
does not trust us.

### 9.3 Honest position on maturity

Deployed and working: intake through report, across four surfaces, with real security auditing.

**Not yet achieved:** identity matching is not wired into the live candidate session (§10.1); the
threshold is calibrated on a benchmark rather than on candidates; no recruiter validation interviews
have been conducted.

---

## 10. Limitations

**10.1 Identity verification is a presence gate in production.** The backend returns a 512-dimensional
embedding, but the portal retains only presence and capture-quality fields and discards the
embedding. The full matching stack — cosine matcher, jittered re-check loop, strike counter — is
implemented and unit-tested but has no construction site on the candidate path. **The system does not
today perform continuous identity verification**, and describing it otherwise would be a
misrepresentation. Now that the threshold is calibrated, wiring is the immediate next task.

**10.2 The threshold is calibrated on LFW, not on candidates.** Public-figure photographs under
benchmark conditions differ from webcam frames under interview conditions. Population-specific
recalibration requires consented candidate data we have not collected.

**10.3 No recruiter validation.** No structured interviews with recruiters have been conducted. The
premise that recruiters prefer a claim audit to a score is the project's largest untested assumption.

**10.4 The synthetic model has never seen a person.** Its own artifact says so.

**10.5 Process telemetry is not on the production path.** Keystroke classification is implemented in
Dart and drives a demonstration screen only; the portal does not capture it. Adaptive
process-triggered follow-ups are therefore not live.

**10.6 Portal test coverage is one file.** The candidate-facing surface carries the least automated
verification.

**10.7 Cloud LLM dependency.** Default operation uses OpenAI. A local Ollama path exists but is not
the deployed default; earlier documentation claiming zero cloud LLM calls is stale.

**10.8 Scale is unvalidated.** Correctness has been tested; concurrent-session load has not.

---

## 11. Future Scope

**Immediate.** Wire the calibrated matcher into the portal session (10.1). Bring keystroke telemetry
onto the production path (10.5). Expand portal test coverage (10.6).

**Near term.** Recruiter validation interviews (10.3). Population-specific threshold recalibration
under explicit consent (10.2). Load testing (10.8).

**Research direction.** Three questions follow from this work:

1. *Does a claim audit change human decisions?* A controlled comparison of reviewers given an audit
   versus a score would test the project's core premise directly.
2. *Can process signals be used without becoming accusations?* Our design treats a bulk insert as
   selecting a *question*, never raising a *flag* — the candidate's answer is the evidence. Whether
   this survives contact with real candidates is untested.
3. *What is the right abstention rate?* Conformal methods offer coverage guarantees; the operating
   point that maximises usefulness while preserving honesty is an empirical question.

---

## 12. Conclusion

CogniHire replaces the composite hiring score with a per-claim audit. The system extracts claims
under a grounding constraint enforced by an architectural boundary rather than by prompt discipline,
probes them in a live interview, and reports verdicts traceable to evidence — including explicit
statements about what was not measured. A human decides.

The project's methodological contribution is the repeated conversion of policies into structures.
"The AI must not author claims" becomes an import boundary with a failing test. "Unmeasured is not
passed" becomes a type with no field to hold a fabricated value. "No demographic inference" becomes
a module that is never loaded. These are verifiable by inspection in seconds, and they do not decay
as the team's attention moves elsewhere.

The most instructive empirical finding is the threshold calibration. A carefully reasoned constant
of 0.50 would have falsely rejected 41.4 % of genuine identity matches. Measurement reduced that to
3.4 %. The lesson generalises beyond this system: in security-adjacent components, *reasoned* and
*correct* are different properties, and only one of them can be demonstrated.

We report a weak result (§8.3) and a rejected component (§8.1) alongside a strong one (§8.2),
because a project that publishes only its successes offers no evidence that it evaluates itself
honestly — and honest evaluation is precisely what this system claims to provide to its users.

---

## References

[1] J. Deng, J. Guo, N. Xue, and S. Zafeiriou, "ArcFace: Additive Angular Margin Loss for Deep Face
Recognition," *Proc. IEEE/CVF Conf. Computer Vision and Pattern Recognition (CVPR)*, 2019,
pp. 4690–4699.

[2] J. Guo, J. Deng, A. Lattas, and S. Zafeiriou, "Sample and Computation Redistribution for
Efficient Face Detection," *Proc. International Conference on Learning Representations (ICLR)*, 2022.
arXiv:2105.04714.

[3] G. B. Huang, M. Ramesh, T. Berg, and E. Learned-Miller, "Labeled Faces in the Wild: A Database
for Studying Face Recognition in Unconstrained Environments," University of Massachusetts Amherst,
Technical Report 07-49, 2007.

[4] J. Platt, "Probabilistic Outputs for Support Vector Machines and Comparisons to Regularized
Likelihood Methods," *Advances in Large Margin Classifiers*, MIT Press, 1999, pp. 61–74.

[5] B. Zadrozny and C. Elkan, "Transforming Classifier Scores into Accurate Multiclass Probability
Estimates," *Proc. 8th ACM SIGKDD Int. Conf. Knowledge Discovery and Data Mining*, 2002, pp. 694–699.

[6] G. W. Brier, "Verification of Forecasts Expressed in Terms of Probability," *Monthly Weather
Review*, vol. 78, no. 1, pp. 1–3, 1950.

[7] V. Vovk, A. Gammerman, and G. Shafer, *Algorithmic Learning in a Random World*. Springer, 2005.

[8] New York City Council, "Local Law 144 of 2021: Automated Employment Decision Tools," effective
5 July 2023.

[9] Illinois General Assembly, "House Bill 3773," amending the Illinois Human Rights Act
(775 ILCS 5) regarding artificial intelligence in employment decisions, effective 1 January 2026.

[10] Illinois General Assembly, "Artificial Intelligence Video Interview Act," 820 ILCS 42,
effective 1 January 2020.

[11] European Parliament and Council, "Regulation (EU) 2024/1689 laying down harmonised rules on
artificial intelligence (Artificial Intelligence Act)," *Official Journal of the European Union*,
2024. Employment-related systems are classified as high-risk under Annex III.

[12] InsightFace, "`buffalo_l` model pack," open-source 2D and 3D face analysis library.
https://github.com/deepinsight/insightface

[13] cnamuangtoun, "resume-job-description-fit," Hugging Face Datasets.
https://huggingface.co/datasets/cnamuangtoun/resume-job-description-fit

[14] F. Pedregosa et al., "Scikit-learn: Machine Learning in Python," *Journal of Machine Learning
Research*, vol. 12, pp. 2825–2830, 2011.

---

## Appendix A — Implementation summary

| Property | Value |
|---|---|
| Surfaces | 4 (FastAPI service, Next.js portal, Flutter recruiter app, Supabase infra) |
| API routes | 42 |
| Database tables | 13, across 20 migrations |
| Modules | 15 (see `docs/submission/MODULES.md`) |
| Tests | 689 Dart + 417 Python + 6 portal |
| Grounding gate trials | ~100,000 over 5,200 résumés |
| Invariant tests | 3 (grounding boundary, score vocabulary ban, evidence↔disposition join) |
| Security findings | 10 (5 HIGH, 5 MEDIUM) — 9 fixed, 1 mitigated |
| Deployment | Azure VM (backend), Vercel (portal), Supabase ap-south-1 |

## Appendix B — Reproducing the experiments

| Experiment | Command |
|---|---|
| §8.1 Sufficiency model | `python -m service.ml.export_model` (seed 100, deterministic) |
| §8.2 Face threshold | `python service/ml/face_verification/calibrate.py` |
| §8.3 Résumé fit | `python service/ml/resume_fit/train.py` |
| §8.4 Grounding gate | `cd service && ./.venv/Scripts/python.exe -m eval.harness --limit 5200 --out eval/metrics.json` |

Both embedding caches are committed, so §8.2 and §8.3 reproduce without re-running embedding models.
