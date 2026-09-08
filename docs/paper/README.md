# Artifact — *Nine Algorithms, One Ceiling*

Everything needed to reproduce every number, table, and figure in the paper.

- **Submission guide:** [`SUBMISSION.md`](SUBMISSION.md) — venue decision, arXiv metadata,
  build steps, and the one field that still needs a human
- **Paper (Markdown):** [`PAPER.md`](PAPER.md)
- **Paper (LaTeX):** [`paper.tex`](paper.tex) + [`references.bib`](references.bib)
- **Figures:** [`figures/`](figures/) — PDF (vector, for LaTeX) and PNG (300 dpi)

> **LaTeX has not been compile-tested.** No TeX toolchain was available on the
> machine where `paper.tex` was written. The content matches `PAPER.md` exactly,
> but expect to fix minor build issues (a missing package, float placement) on
> first compile.

---

## Reproducing the results

All commands run from `service/` and are deterministic at seed 100.

```bash
cd service
python -m ml.resume_fit.diagnose             # dataset diagnostics (§3.1)
python -m ml.resume_fit.probe_datasets       # replication-corpus screen (§3.4)
python -m ml.resume_fit.verify_med2425       # contamination verification (§3.4)
python -m ml.resume_fit.train_benchmark      # 9 algorithms + significance (§6.1)
python -m ml.synthetic_benchmark             # positive control (§6.2)
python -m ml.resume_fit.ablation             # representations + learning curve (§6.3, §6.7)
python -m ml.resume_fit.matching_isolation   # within-résumé diagnostic (§6.4)
python -m ml.resume_fit.robustness           # split + label robustness (§6.5)
python -m ml.resume_fit.tuned_benchmark      # nested tuning check (§6.5, Obj. 3)
python -m ml.make_figures                    # all five figures
```

The two `§3.4` scripts and `tuned_benchmark` reach the network to download
candidate corpora from the Hugging Face Hub; the rest run offline once the
embedding cache exists.

**Embeddings are cached, but the cache is not in the repository.**
`service/ml/resume_fit/cache/embeddings.json` (~16 MB) holds all ~1,470 document
vectors keyed by content hash. It is excluded by `.gitignore` on size grounds, so a
fresh clone must regenerate it on first run — that requires a local Ollama instance
serving `nomic-embed-text`. It is a one-off cost; every later run reads the cache.
Exact replication of embedding-derived features depends on that encoder version
being unchanged; everything downstream (splits, fits, statistics) is seeded and exact.

**Runtime.** The benchmark and ablation are the expensive ones (roughly 10–20
minutes each on 8 cores, dominated by the RBF SVM and the 1536-dimensional
representations). `robustness` takes a similar time, dominated by refitting IDF
statistics per fold. The others complete in under two minutes.

---

## What each script produces

| Script | Outputs | Paper |
|---|---|---|
| `ml/resume_fit/train_benchmark.py` | `resume_fit_benchmark.report.json`, `resume_fit_benchmark_folds.csv` | Tables 1–2, Fig. 1a |
| `ml/synthetic_benchmark.py` | `synthetic_benchmark.report.json`, `synthetic_benchmark_folds.csv` | Table 3, Fig. 1b |
| `ml/resume_fit/ablation.py` | `ablation.report.json` | Table 4, Fig. 2, Table (learning curve) |
| `ml/resume_fit/matching_isolation.py` | `matching_isolation.report.json` | Tables (variance, pairwise), Fig. 3 |
| `ml/resume_fit/robustness.py` | `robustness.report.json` | Tables 6–7 |
| `ml/resume_fit/tuned_benchmark.py` | `tuned_benchmark.report.json`, `tuned_benchmark_folds.csv` | Table 8 (§6.5, Obj. 3) |
| `ml/resume_fit/probe_datasets.py` | `probe_datasets.report.json` | §3.4 candidate table |
| `ml/resume_fit/verify_med2425.py` | console output | §3.4 contamination figures |
| `ml/make_figures.py` | `docs/paper/figures/*.{pdf,png}` | all figures |

The `*_folds.csv` files carry one row per (model, fold) with every metric and
timing, and are the right starting point for re-plotting or re-testing.

---

## Dependencies

The experiments need only what `service/requirements.txt` already pins
(`scikit-learn`, `numpy`, `scipy`, `datasets`, `joblib`).

`matplotlib` is required **for figures only** and is deliberately *not* added to
`requirements.txt`, because that file's version floors flow into
`requirements.lock` and from there into the deployed service image. Figure
generation is not a service dependency. Install it into the virtualenv alone:

```bash
service/.venv/Scripts/python.exe -m pip install matplotlib
```

---

## A note on the synthetic benchmark

`ml/synthetic_benchmark.py` produces data with a planted signal and a known
Bayes-optimal accuracy of 0.925. It exists to establish that the evaluation
protocol has the statistical power to separate models when a difference exists —
it is the positive control that makes the paper's null result on real data
informative rather than merely inconclusive.

**Its accuracy figures are not résumé-screening performance and must never be
quoted as such.** Every artifact it writes carries `isSynthetic: true` and
`notRealWorldPerformance: true`, and the module docstring states the same. In the
paper it appears only as §6.2, beside the real-data table, never in place of it.

---

## Dataset

`cnamuangtoun/resume-job-description-fit` on Hugging Face, retrieved via the
`datasets` library. As documented in §3.2 of the paper, the dataset card carries
no description, licence, citation, or statement of how the labels were produced.
We report results on it without asserting anything about its provenance.
