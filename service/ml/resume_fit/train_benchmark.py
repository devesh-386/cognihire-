"""Multi-algorithm benchmark for the resume<->job-description fit task.

## Why this file exists (separate from train.py)

`train.py` compares three classifiers on the dataset's single predefined
train/test split and ships the winner. That is enough to pick a production
model; it is *not* enough to claim one algorithm family beats another,
because a single split gives one number per model and no variance.

This file is the research-grade version:

- **9 algorithms** spanning six model families (linear, probabilistic,
  instance-based, kernel, bagging ensembles, boosting ensembles, neural).
- **10-fold GroupKFold, grouped by job description.** Every fold's test
  job descriptions are unseen during that fold's training - the same
  honesty property the dataset's own by-JD split has, but repeated 10x so
  each model gets a *distribution* of scores.
- **Leakage discipline preserved per fold:** IDF statistics and the feature
  scaler are fit on the fold's training rows only, never the whole corpus.
- **Efficiency measured, not asserted:** fit time, inference latency, and
  serialized model size are recorded alongside accuracy.
- **Significance tested:** Friedman across all models on per-fold AUC, then
  Wilcoxon signed-rank of the best model vs each other with Holm-Bonferroni
  correction.

Nothing here is synthetic. Source: `cnamuangtoun/resume-job-description-fit`
on Hugging Face, binarized (No Fit -> False; Potential/Good Fit -> True),
class-balanced by downsampling so 50% is the true random baseline.

Run from `service/`:

    python -m ml.resume_fit.train_benchmark

Outputs, next to this file:
  resume_fit_benchmark.report.json   full results + significance tests
  resume_fit_benchmark_folds.csv     one row per (model, fold) for plotting
"""

from __future__ import annotations

import asyncio
import io
import json
import time
from pathlib import Path

import numpy as np
from scipy.stats import friedmanchisquare, wilcoxon
from sklearn.ensemble import (
    ExtraTreesClassifier,
    GradientBoostingClassifier,
    HistGradientBoostingClassifier,
    RandomForestClassifier,
)
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import f1_score
from sklearn.model_selection import GroupKFold
from sklearn.naive_bayes import GaussianNB
from sklearn.neighbors import KNeighborsClassifier
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from ml import metrics as shared_metrics
from ml.resume_fit import features as fx
from ml.resume_fit.data import build_features, load_examples

SEED = 100
N_SPLITS = 10

# Trees are scale-invariant; the rest are not. Giving each model the
# representation it wants keeps this a comparison of algorithms rather than
# of preprocessing (same call the original train.py makes).
_SCALE_SENSITIVE = {"logistic_regression", "gaussian_nb", "knn", "svm_rbf", "mlp"}


def _candidate_models() -> dict:
    """Nine algorithms, six families. Hyper-parameters are deliberately
    modest and fixed (no per-model tuning budget) so the comparison is of
    the algorithms at sane defaults, not of who got tuned hardest. Any
    tuning would have to be nested inside the CV to stay honest."""
    return {
        # linear
        "logistic_regression": LogisticRegression(solver="lbfgs", max_iter=5000, C=1.0),
        # probabilistic
        "gaussian_nb": GaussianNB(),
        # instance-based
        "knn": KNeighborsClassifier(n_neighbors=25, weights="distance"),
        # kernel
        "svm_rbf": SVC(kernel="rbf", C=2.0, gamma="scale", probability=True, random_state=SEED),
        # bagging ensembles
        "random_forest": RandomForestClassifier(
            n_estimators=400, max_depth=12, min_samples_leaf=3, random_state=SEED, n_jobs=-1
        ),
        "extra_trees": ExtraTreesClassifier(
            n_estimators=400, max_depth=16, min_samples_leaf=2, random_state=SEED, n_jobs=-1
        ),
        # boosting ensembles
        "gradient_boosting": GradientBoostingClassifier(
            n_estimators=300, learning_rate=0.05, max_depth=3, subsample=0.9, random_state=SEED
        ),
        "hist_gradient_boosting": HistGradientBoostingClassifier(
            max_depth=4, learning_rate=0.06, max_iter=400, l2_regularization=1.0, random_state=SEED
        ),
        # neural
        "mlp": MLPClassifier(
            hidden_layer_sizes=(64, 32), alpha=1e-3, max_iter=800,
            early_stopping=True, random_state=SEED
        ),
    }


def _feature_matrix(examples, sims, stats) -> np.ndarray:
    return fx.to_matrix([
        fx.extract(
            resume_text=ex.full_resume_text or ex.resume_text,
            job_description_text=ex.full_job_description_text or ex.job_description_text,
            embedding_cosine=sim,
            stats=stats,
        )
        for ex, sim in zip(examples, sims)
    ])


def _serialized_kb(model) -> float:
    buf = io.BytesIO()
    import joblib

    joblib.dump(model, buf)
    return len(buf.getvalue()) / 1024.0


async def main() -> int:
    print("[benchmark] loading dataset (train+test pooled for GroupKFold)...")
    train_examples, test_examples = load_examples()
    pool = list(train_examples) + list(test_examples)
    print(f"[benchmark] {len(pool)} rows pooled")

    print("[benchmark] embedding (cached after first run)...")
    sims, labels, examples = await build_features(pool)
    y = np.asarray(labels, dtype=int)
    groups = np.asarray([e.full_job_description_text or e.job_description_text for e in examples])
    n_groups = len(set(groups))
    print(f"[benchmark] {len(examples)} rows survived, {n_groups} unique job descriptions, "
          f"{y.mean():.3f} positive rate")

    splitter = GroupKFold(n_splits=N_SPLITS)
    model_names = list(_candidate_models().keys())

    # per-model lists of per-fold metric dicts
    fold_rows: list[dict] = []
    per_model_auc: dict[str, list[float]] = {m: [] for m in model_names}

    for fold, (tr_idx, te_idx) in enumerate(splitter.split(np.zeros(len(examples)), y, groups)):
        tr_ex = [examples[i] for i in tr_idx]
        te_ex = [examples[i] for i in te_idx]
        tr_sims = [sims[i] for i in tr_idx]
        te_sims = [sims[i] for i in te_idx]
        y_tr, y_te = y[tr_idx], y[te_idx]

        # fit corpus stats + scaler on TRAIN ROWS ONLY
        stats = fx.DocumentStats.fit(
            [e.full_resume_text or e.resume_text for e in tr_ex]
            + [e.full_job_description_text or e.job_description_text for e in tr_ex]
        )
        X_tr = _feature_matrix(tr_ex, tr_sims, stats)
        X_te = _feature_matrix(te_ex, te_sims, stats)
        scaler = StandardScaler().fit(X_tr)
        X_tr_s, X_te_s = scaler.transform(X_tr), scaler.transform(X_te)

        # naive baseline this whole model is supposed to beat: fixed 0.5
        # cosine threshold, no learning.
        naive_acc = float(np.mean([(s >= 0.5) == bool(t) for s, t in zip(te_sims, y_te)]))

        line = [f"fold {fold}: naive={naive_acc:.3f}"]
        for name, model in _candidate_models().items():
            scaled = name in _SCALE_SENSITIVE
            fit_X = X_tr_s if scaled else X_tr
            eval_X = X_te_s if scaled else X_te

            t0 = time.perf_counter()
            model.fit(fit_X, y_tr)
            fit_s = time.perf_counter() - t0

            t0 = time.perf_counter()
            proba = model.predict_proba(eval_X)[:, 1]
            predict_ms_per_1k = (time.perf_counter() - t0) / len(eval_X) * 1e6

            m = shared_metrics.evaluate(proba.tolist(), [bool(v) for v in y_te])
            f1 = f1_score(y_te, (proba >= 0.5).astype(int))
            size_kb = _serialized_kb(model)

            per_model_auc[name].append(m.auc if m.auc is not None else float("nan"))
            fold_rows.append({
                "model": name, "fold": fold,
                "auc": m.auc, "accuracy": m.accuracy, "f1": float(f1),
                "brier": m.brier, "log_loss": m.log_loss,
                "ece": m.expected_calibration_error,
                "fit_s": fit_s, "predict_us_per_row": predict_ms_per_1k,
                "size_kb": size_kb,
                "test_rows": int(len(y_te)), "naive_accuracy": naive_acc,
            })
            line.append(f"{name}={m.auc:.3f}")
        print("[benchmark] " + "  ".join(line))

    # ---- aggregate ----
    def agg(name: str, key: str) -> tuple[float, float]:
        vals = [r[key] for r in fold_rows if r["model"] == name and r[key] is not None]
        return float(np.mean(vals)), float(np.std(vals))

    summary = {}
    for name in model_names:
        summary[name] = {
            k: {"mean": agg(name, k)[0], "std": agg(name, k)[1]}
            for k in ["auc", "accuracy", "f1", "brier", "log_loss", "ece",
                      "fit_s", "predict_us_per_row", "size_kb"]
        }

    ranked = sorted(model_names, key=lambda n: summary[n]["auc"]["mean"], reverse=True)
    best = ranked[0]

    # ---- significance ----
    auc_matrix = [per_model_auc[n] for n in model_names]  # models x folds
    friedman_stat, friedman_p = friedmanchisquare(*auc_matrix)

    pairwise = {}
    raw_p = {}
    for name in model_names:
        if name == best:
            continue
        a = np.asarray(per_model_auc[best])
        b = np.asarray(per_model_auc[name])
        try:
            stat, p = wilcoxon(a, b)
        except ValueError:  # all-zero differences
            stat, p = float("nan"), 1.0
        raw_p[name] = p
    # Holm-Bonferroni
    ordered = sorted(raw_p, key=raw_p.get)
    m = len(ordered)
    holm = {}
    running_max = 0.0
    for i, name in enumerate(ordered):
        adj = min(1.0, (m - i) * raw_p[name])
        running_max = max(running_max, adj)
        holm[name] = running_max
    for name in raw_p:
        pairwise[name] = {
            "wilcoxon_raw_p": raw_p[name],
            "holm_adjusted_p": holm[name],
            "best_minus_this_mean_auc": summary[best]["auc"]["mean"] - summary[name]["auc"]["mean"],
            "significant_at_0.05": bool(holm[name] < 0.05),
        }

    report = {
        "task": "resume<->job-description binary fit",
        "trainedOnRealData": True,
        "datasetSource": "huggingface:cnamuangtoun/resume-job-description-fit",
        "rows": len(examples),
        "uniqueJobDescriptions": n_groups,
        "positiveRate": float(y.mean()),
        "protocol": {
            "cv": f"GroupKFold(n_splits={N_SPLITS}) grouped by job_description_text",
            "leakageControls": [
                "IDF statistics fit on each fold's training rows only",
                "StandardScaler fit on each fold's training rows only",
                "every feature is relational (resume-vs-JD), never resume-only",
            ],
            "tuning": "none - fixed modest hyper-parameters, defaults where reasonable",
            "scaleSensitiveModels": sorted(_SCALE_SENSITIVE),
        },
        "models": summary,
        "rankingByMeanAuc": ranked,
        "best": best,
        "significance": {
            "friedman_chi2": float(friedman_stat),
            "friedman_p": float(friedman_p),
            "note": "Friedman tests whether the models differ at all across folds. "
                    "Pairwise entries compare the top model to each other, "
                    "Wilcoxon signed-rank over the 10 folds, Holm-Bonferroni corrected.",
            "pairwise_vs_best": pairwise,
        },
        "naiveFixedThresholdAccuracy": {
            "mean": float(np.mean([r["naive_accuracy"] for r in fold_rows if r["model"] == best])),
        },
    }

    def _native(obj):
        if isinstance(obj, dict):
            return {k: _native(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)):
            return [_native(v) for v in obj]
        if isinstance(obj, (np.bool_,)):
            return bool(obj)
        if isinstance(obj, np.integer):
            return int(obj)
        if isinstance(obj, np.floating):
            return float(obj)
        return obj

    out_dir = Path(__file__).parent

    # tidy CSV for plotting (written first so it survives any report issue)
    cols = ["model", "fold", "auc", "accuracy", "f1", "brier", "log_loss", "ece",
            "fit_s", "predict_us_per_row", "size_kb", "test_rows", "naive_accuracy"]
    lines = [",".join(cols)]
    for r in fold_rows:
        lines.append(",".join(str(r[c]) for c in cols))
    (out_dir / "resume_fit_benchmark_folds.csv").write_text("\n".join(lines))

    (out_dir / "resume_fit_benchmark.report.json").write_text(
        json.dumps(_native(report), indent=2)
    )

    # ---- console summary ----
    print("\n[benchmark] === mean +/- std over 10 folds, ranked by AUC ===")
    print(f"{'model':24s} {'AUC':>14s} {'acc':>14s} {'F1':>14s} {'ECE':>8s} "
          f"{'fit s':>8s} {'us/row':>9s} {'size kb':>9s}")
    for name in ranked:
        s = summary[name]
        print(f"{name:24s} "
              f"{s['auc']['mean']:.3f}+/-{s['auc']['std']:.3f} "
              f"{s['accuracy']['mean']:.3f}+/-{s['accuracy']['std']:.3f} "
              f"{s['f1']['mean']:.3f}+/-{s['f1']['std']:.3f} "
              f"{s['ece']['mean']:>8.3f} "
              f"{s['fit_s']['mean']:>8.2f} "
              f"{s['predict_us_per_row']['mean']:>9.1f} "
              f"{s['size_kb']['mean']:>9.1f}")
    print(f"\n[benchmark] naive fixed-0.5-cosine accuracy: "
          f"{report['naiveFixedThresholdAccuracy']['mean']:.3f}")
    print(f"[benchmark] Friedman chi2={friedman_stat:.2f}  p={friedman_p:.2e}")
    print(f"[benchmark] best = {best}")
    for name in ranked[1:]:
        pw = pairwise[name]
        flag = "differs" if pw["significant_at_0.05"] else "n.s."
        print(f"           vs {name:24s} dAUC={pw['best_minus_this_mean_auc']:+.3f}  "
              f"Holm p={pw['holm_adjusted_p']:.3f}  [{flag}]")
    print(f"\n[benchmark] wrote {out_dir / 'resume_fit_benchmark.report.json'}")
    print(f"[benchmark] wrote {out_dir / 'resume_fit_benchmark_folds.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
