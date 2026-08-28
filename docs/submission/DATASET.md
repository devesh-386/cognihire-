# CogniHire — Dataset Documentation

**Status as of 2026-08-28.** Every number below is copied from a report file committed in this
repository. Nothing here is estimated, projected, or rounded up.

---

## 0. The short answer

CogniHire is **not** a system that learns to predict hiring outcomes. There is no
`(candidate, hired/not-hired)` training set anywhere in this repository, and no code path that
could build one.

Data appears in this project in four distinct roles, and conflating them is the most common way to
misread the system:

| Role | What it is | Real people? |
|---|---|---|
| **A. Runtime input** | Résumés and interview answers processed at application time | Yes — but never used for training |
| **B. Synthetic training data** | Manufactured rows used to prove one measurement mechanism | No |
| **C. Public benchmark data** | Third-party datasets used to fit two parameters offline | Yes (public, consented benchmarks) |
| **D. Pretrained third-party weights** | Face detection and recognition models | Trained elsewhere, by others |

Sections 1–4 cover each in turn.

---

## 1. Runtime input data (Role A)

### 1.1 What enters the system

| Field | Source | Format |
|---|---|---|
| Full name, email, contact | Google Form / apply page | text |
| Target role | Form selection, resolved to a `roles` row | FK |
| Preferred interview time | Form | timestamp |
| Résumé | Upload | PDF / DOC / DOCX, ≤ 5 MB |
| Interview answers | Typed or spoken | text; audio streamed, never stored |
| Webcam frame(s) | Device check | JPEG, in-memory only |
| Microphone audio | Live voice interview | PCM 24 kHz, relayed, never stored |

### 1.2 What is persisted

Supabase PostgreSQL, 13 tables across 20 migrations (`infra/migrations/0000` → `0019`).
The candidate-bearing tables:

| Table | Candidate content |
|---|---|
| `candidates` | name, email, contact, `role_id`, `resume_path`, `years_experience`, `preferred_time` |
| `candidate_ai_profile` | `resume_text` (raw), `knowledge_profile` jsonb, `claims` jsonb, `skills[]`, `projects[]`, `experience` jsonb, `processing_status`, `understanding_kind`, `claim_extraction_kind`, `degraded_reason` |
| `interview_sessions` | `question_plan`, `coverage_state`, `outcomes`, `current_topic`, `available_minutes` |
| `interview_events` | append-only, sequenced turn log (trigger, migration `0011`) |
| `interview_codes`, `interview_code_emails` | redemption codes, attempts, expiry, delivery state |

Résumé binaries live in Supabase Storage, referenced by `candidates.resume_path`, scoped by
`organization_id` under row-level security.

### 1.3 What is deliberately NOT stored

This list is enforced by absence — there is no table to write these into, so no future change can
quietly start retaining them without a migration that a reviewer would see.

| Not stored | Enforcement |
|---|---|
| **Face images** | `POST /face/analyze` is stateless: decode → measure → embed → return. No write. |
| **Face embeddings** | No `face_embeddings` table exists in any of the 20 migrations. |
| **Raw interview audio** | The Realtime relay (`service/session/live_interview.py`) streams PCM through; only text turns reach `interview_events`. |
| **Keystroke / process telemetry** | Implemented in Dart (`lib/core/telemetry/`), drives a demo screen only. Zero references in `portal/`; no table. |
| **Question plans** | Explicitly by design — see the docstring in `service/ai/question_planning.py`. |
| **Demographic attributes** | Never collected, never inferred. See §4.2. |

### 1.4 Runtime data is never training data

No module in `service/`, `lib/`, or `portal/` writes candidate data to any training corpus. The two
models that were trained (§3) read from a HuggingFace dataset and an sklearn benchmark loader
respectively; neither has a code path that reads the Supabase tables above.

---

## 2. Synthetic data (Role B) — the sufficiency model

**Purpose.** Demonstrate that the evidence-sufficiency measurement pipeline (feature assembly →
training → grouped split → calibration → conformal abstention → attribution) is correct end to end,
without involving a single real candidate.

**Generator.** `service/ml/synthetic.py`, mirrored in Dart at
`lib/core/ml/synthetic_sufficiency_dataset.dart`.

A `GENERATIVE_MODEL` with planted, known-in-advance weights emits rows; the training pipeline must
then recover those weights. Two of the nine features are given **weight exactly 0**
(`typing.backspaceRate`, `session.followUpCount`) as planted noise — if training assigns them
importance, the pipeline is broken. `GENERATIVE_BIAS = -0.2`. RNG is numpy PCG64, seeded.

**Dataset** (`assets/ml/sufficiency_model.report.json`):

| Property | Value |
|---|---|
| Rows | 6 000 |
| Groups | 300 |
| Seed | 100 |
| Train / calibration / test | 3 600 / 1 200 / 1 200 (0.6 / 0.2 / 0.2) |
| Split | **Grouped** — no group spans two splits |
| Provenance string | `"synthetic data only — no real candidate was involved"` |

**Held-out results** (1 200 rows, 557 positive):

| Metric | Value |
|---|---|
| AUC | **0.8515** |
| Brier | 0.1578 |
| Log loss | 0.4761 |
| Accuracy | 0.7592 |
| Expected calibration error | **0.0321** |

**The calibrator was fitted and deliberately not shipped.** Isotonic regression made held-out ECE
*worse* (0.0321 → 0.0403), below the `MIN_CALIBRATION_GAIN = 0.005` bar, so `export_model.py` wrote
no calibrator. Shipping it would have looked more sophisticated and been less accurate.

**Export gate.** `export_model.py` refuses to write an artifact unless AUC > 0.7, ECE < 0.1, and
Brier < 0.25. A bad training run produces no file rather than a quietly bad file.

**Self-declaration.** `assets/ml/sufficiency_model.json` carries:

```json
"trainedOnSyntheticData": true,
"isValidatedOnRealData": false
```

The Dart loader (`lib/core/ml/trained_artifact.dart`) **rejects** an artifact that omits either flag
or claims both. The model cannot be loaded while pretending to be something it is not.

**There is no `fit_real` entry point**, in Python or Dart, by design — stated in `train.py` and
`service/ml/README.md`.

---

## 3. Public benchmark data (Role C)

Two parameters in this system needed real-world grounding. Neither could ethically use candidate
data, so both use public benchmarks — and both carry their limitation in the report file itself.

### 3.1 Face-verification threshold — LFW

**Source:** `sklearn.datasets.fetch_lfw_pairs` (LFW funneled, color).
**Code:** `service/ml/face_verification/calibrate.py`. **Report:** `calibration_report.json`.

No weights are trained. A **single scalar threshold** is fitted by equal-error-rate sweep on train
pairs and evaluated on unseen test pairs.

| | Genuine | Impostor | Dropped |
|---|---|---|---|
| Train pairs | 1 100 | 1 100 | 0 |
| Test pairs | 500 | 500 | 0 |

**Calibrated threshold: 0.1266** (train EER 0.0309).

| Threshold | FAR | FRR | Accuracy | AUC |
|---|---|---|---|---|
| **0.1266** (calibrated) | 0.030 | **0.034** | **0.968** | 0.9785 |
| 0.50 (previous authored constant) | 0.000 | **0.414** | 0.793 | — |

This is the headline experimental result of the project. The previously authored threshold of 0.50
rejected **41.4 %** of genuine matches — it had never been measured. Calibration cut that to 3.4 %
at comparable false-accept cost.

**Stated caveat, verbatim from the report file:**

> "LFW is a public benchmark of celebrity/public-figure photos, not CogniHire's candidate
> population. This calibrates a reasonable general threshold, not one validated on real candidates."

Embedding cache committed at `service/ml/face_verification/cache/lfw_embeddings.json` (53 MB) so the
result is reproducible without re-running InsightFace over 3 200 pairs.

### 3.2 Résumé–role fit — HuggingFace

**Source:** `huggingface:cnamuangtoun/resume-job-description-fit`, 3-class, collapsed to binary.
**Code:** `service/ml/resume_fit/`. **Report:** `resume_fit_model.report.json`.

| Property | Value |
|---|---|
| Train rows | 6 196 |
| Test rows | 1 714 (857 positive) |
| Features | 10, all **relational** (résumé-vs-JD), none identity-bearing |

**Model comparison on held-out data:**

| Model | AUC | Accuracy | Brier | ECE |
|---|---|---|---|---|
| Logistic regression | 0.6195 | 0.5846 | 0.2426 | 0.0570 |
| Gradient boosting | 0.6479 | 0.6091 | 0.2360 | 0.0590 |
| **Random forest (selected)** | **0.6573** | **0.6109** | 0.2311 | **0.0257** |
| *Naive fixed threshold (baseline)* | — | *0.5163* | — | — |

Top feature importances: `embedding_cosine` 0.281, `idf_weighted_coverage` 0.127,
`token_jaccard` 0.128, `jd_term_coverage` 0.111.

**Honest reading:** AUC 0.657 is weak. The model beats a naive fixed threshold by roughly 9
accuracy points, which is a real but modest signal. **This is presented as a negative-to-modest
result, not a success.** It is the reason the model is *not* wired into the runtime.

**Stated caveat, verbatim from the report file:**

> "The dataset splits by job description: test job descriptions are unseen in train, but 476/477
> test resumes appear in train. All features are relational (resume-vs-JD) so the model cannot
> score well by memorizing resume identity."

**Not on the live path.** No module in `service/ai/`, `service/main.py`, or `lib/` imports
`resume_fit`. Production similarity uses `service/ai/semantic_similarity.py` with an unfitted
`_MATCH_FLOOR = 0.5`. This is an offline research artifact, and closing that gap is named as future
work rather than glossed.

Embedding cache committed at `service/ml/resume_fit/cache/embeddings.json` (15.9 MB), keyed by text
hash, produced with Ollama `nomic-embed-text`.

---

## 4. Pretrained third-party models (Role D)

### 4.1 InsightFace `buffalo_l`

Loaded in `service/main.py` (~lines 150–177) via
`FaceAnalysis(name="buffalo_l", allowed_modules=["detection", "recognition"])`.

| Model | Role | Architecture / training corpus |
|---|---|---|
| `det_10g.onnx` | Face detection | SCRFD |
| `w600k_r50.onnx` | Face recognition → 512-d embedding | ArcFace, ResNet-50, WebFace600K |

**Not fine-tuned here.** No training code for either model exists in the repository. The ONNX files
are not committed — the `insightface` package downloads them (~300 MB) at first run and they are
cached in the Docker volume `insightface-models:/root/.insightface`
(`docker-compose.api.yml`).

### 4.2 The deliberate exclusion

The `buffalo_l` pack also ships **`genderage.onnx`**, an age and gender classifier. The
`allowed_modules=["detection", "recognition"]` argument means it is **never loaded**.

This is not an oversight or a performance optimisation. It is a design decision: no demographic
attribute is ever inferred from a candidate's face, so no downstream component can accidentally
condition on one. The narrowest possible module set is loaded, and the exclusion is visible in a
single argument that a reviewer can check.

### 4.3 Language models

| Use | Model | Provider |
|---|---|---|
| Résumé understanding, claim extraction, answer analysis | `gpt-4o-mini` (default) | OpenAI |
| Alternate / offline | `qwen2.5:7b` | Ollama, local |
| Embeddings | `nomic-embed-text` | Ollama, local |
| Voice (VAD / STT / TTS only) | `gpt-realtime-2` | OpenAI Realtime |

**No language model is fine-tuned.** All are used as-is through one module,
`service/ai/provider.py` — the only file in the codebase permitted to contact a vendor.

For voice, `turn_detection.create_response = false`: the Realtime API performs voice activity
detection, speech-to-text and text-to-speech, but **never decides what to say**. Every spoken
question originates from `interview_session.answer()`.

---

## 5. Authored content that functions as data

Not learned, but load-bearing, and worth declaring:

| Asset | Location | Size |
|---|---|---|
| Interview question bank | `lib/core/interview/question_bank.dart` | 25 templates over a 4-value claim taxonomy × 3 probe depths |
| Role → topic priority tables | `lib/core/roles/role_question_priority.dart`, `role_coverage.dart` | authored |
| Integrity violation rules | `lib/core/integrity/violation_rules.dart` | authored IF/THEN |
| Explanation templates | `lib/core/ml/explanation_templater.dart` | authored |
| Demo seed data | `service/demo/seed_data.py` | 1 org, 3 roles, **5 fictional candidates** at `@demo.cognihire.test` |
| Evaluation sets | `prompts/evals/`, `tool/corpus/` | prompt eval + corpus scoring runs |

The demo seed data is fictional, hand-written, and gated behind `_require_non_production()`. No real
person appears in it.

---

## 6. Ethics, consent, and regulatory position

| Concern | Position |
|---|---|
| Biometric consent | Face analysis is a live presence/quality check; no biometric template is stored. |
| Demographic inference | Structurally impossible — the classifier is never loaded (§4.2). |
| Training on candidates | Never occurs. No corpus, no code path, no table. |
| Automated rejection | Does not exist. `service/ai/report_generation.py` is deliberately **not** a model call: it emits Claim → Evidence → Verdict rows with no score, no ranking, and no recommendation. |
| NYC Local Law 144 | No composite score to audit for disparate impact. |
| Illinois AIVI Act (2026-01-01) | No demographic inference from video. |
| EU AI Act | Disposition is human-only by design; the system measures and never decides. |

---

## 7. Reproducibility

| Result | Command |
|---|---|
| Sufficiency model | `python -m service.ml.export_model` (seed 100, deterministic) |
| Face threshold | `python service/ml/face_verification/calibrate.py` (cache committed) |
| Résumé-fit model | `python service/ml/resume_fit/train.py` (cache committed) |

Both embedding caches are committed, so §3 reproduces without re-running the embedding models.

---

## 8. Summary table

| Dataset | Real people? | Rows | Used to train | Wired into runtime | Headline metric |
|---|---|---|---|---|---|
| Synthetic sufficiency | No | 6 000 | Logistic weights | Yes | AUC 0.8515, ECE 0.0321 |
| LFW pairs | Yes (public) | 3 200 pairs | One scalar threshold | Consumer not on live path | FAR 0.030 / FRR 0.034 |
| HF résumé–JD fit | Yes (public) | 7 910 | Random forest | **No** | AUC 0.6573 |
| WebFace600K | Yes (public) | — | Nothing — pretrained | Yes (embeddings) | third-party |
| **CogniHire candidates** | **Yes** | — | **Nothing, ever** | Yes (processed) | — |
