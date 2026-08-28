# CogniHire — Final Review Submission Package

Created 2026-08-28. **These documents are the current, verified description of the system.**

Older documents elsewhere in this repository (`ABSTRACT.md`, `MENTOR_BRIEF.md`,
`docs/PRODUCT_OVERVIEW.md`, `docs/ARCHITECTURE_DISCOVERY_REPORT.md`) describe an earlier
Flutter-only architecture with no portal and no FastAPI backend. They are historical snapshots.
**When they disagree with anything here, this directory is correct.**

---

## Contents

| Document | Deliverable | What it is |
|---|---|---|
| [`RESEARCH_PAPER.md`](RESEARCH_PAPER.md) | 📄 Research Paper | Full paper — abstract through references, 14 real citations |
| [`MODULES.md`](MODULES.md) | 🧩 Modules | 15 modules, verified against code, with implementation status |
| [`DATASET.md`](DATASET.md) | 📊 Dataset | All four data roles; three trained models with exact metrics |
| [`SCHEMA.md`](SCHEMA.md) | 🗄️ Database | 13 tables, 20 migrations, security model |
| [`API.md`](API.md) | 🔌 API | 42 routes with auth classes |
| [`TESTING.md`](TESTING.md) | ✅ Testing | 1 112 tests, invariant tests, security audit |
| [`DEMO_AND_PRESENTATION.md`](DEMO_AND_PRESENTATION.md) | 🎥 Demo + 📊 Slides | Slide content, demo running order, recording checklist, hostile-question prep |

---

## Verified figures — use these, not older ones

| Fact | Value |
|---|---|
| Flutter / Dart tests | **689** passing (+3 preview goldens excluded in CI) |
| Python tests | **417** passing |
| Portal tests | **6** passing |
| API routes | **42** |
| Database tables | **13**, across 20 migrations |
| Modules | **15** |
| Security findings | **10** (5 HIGH, 5 MEDIUM) — 9 fixed, 1 mitigated |

**Do not quote 69, 662, 674, 681, 683, 688, 734, or a 1 100 total (412 Python / 2 portal).**
All are historical or, in the case of 412, simply wrong.

---

## The three experimental results

| Experiment | Data | Headline | Deployed |
|---|---|---|---|
| Evidence sufficiency | Synthetic, 6 000 rows | AUC 0.8515, ECE 0.0321 | Yes |
| **Face threshold calibration** | **LFW, 3 200 pairs** | **FRR 0.414 → 0.034** | Calibrated; matcher not yet wired |
| Résumé–role fit | HuggingFace, 7 910 rows | AUC 0.6573 | **No — too weak** |

The middle row is the project's strongest finding: a reasoned, documented threshold of 0.50 would
have falsely rejected 41.4 % of genuine identity matches. Only measurement revealed it.

---

## Three things to state plainly, not hide

1. **Identity verification is a presence gate in production.** The matcher is built, tested, and now
   calibrated, but the portal discards the embedding. Do not claim continuous verification.
2. **The résumé-fit model is not deployed** because AUC 0.657 is too weak to justify it. Reporting a
   negative result is deliberate.
3. **No recruiter validation interviews have been conducted.** This is the largest untested
   assumption and was carried over from the Review 2 way-forward plan.

Naming these first is worth more than any feature demo. A panel that finds a gap you concealed
discounts everything else you said.

---

## Two corrections to your Review 2 deck

1. **Test counts** — the deck says "674 Dart and 268 Python." Current: **689 and 417**.
2. **Illinois legislation** — the deck attributes the 2026-01-01 date to the *AI Video Interview
   Act*. That Act (820 ILCS 42) took effect **2020-01-01**. It is **HB 3773**, amending the Illinois
   Human Rights Act, that takes effect **2026-01-01**.

The deck also states the threshold is "not yet calibrated, so no FAR/FRR is quoted." **That is now
superseded** — it is the single biggest piece of progress since Review 2 and should be updated
rather than left standing.
