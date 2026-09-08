"""Does hyper-parameter tuning change the conclusion? A nested-CV falsification test.

`train_benchmark.py` runs every model at fixed modest settings and finds the
nine statistically indistinguishable from one another at the top. The paper
argues (Threats to Validity) that tuning would not change this, because the
ceiling is representational rather than algorithmic. That is an argument, not
evidence, and it is the objection a reviewer is most likely to raise.

This script tests it, and is deliberately constructed so it *could* refute the
paper's central claim: if tuning pulls one model clear of the others, the
"statistically indistinguishable" finding weakens and we would have to say so.

## Design

**Nested cross-validation.** The outer loop is the same 10-fold GroupKFold by
job description used everywhere else, so results are directly comparable to
Table 1. Inside each outer training fold, a 3-fold GroupKFold (again by posting)
selects hyper-parameters by mean AUROC. The selected configuration is then refit
on the full outer-training fold and scored once on the untouched outer-test
fold. No test row influences any selection decision.

**Equal budget, which is the fairness condition.** Every model gets exactly
`N_CONFIGS` sampled configurations. Giving one model a larger search than
another converts a comparison of algorithms into a comparison of search effort,
which is the failure this whole paper is about. Models whose grid is smaller
than the budget are sampled with replacement suppressed and simply get their
whole grid.

**Reported quantities.** Per model: tuned AUROC (mean +/- sd over the ten outer
folds), the untuned AUROC from the main benchmark for reference, the delta, and
how often each configuration was selected. Then Friedman across the tuned
results and Holm-corrected Wilcoxon of the tuned leader against the rest --- the
same protocol as the untuned comparison, so the two tables answer the same
question.

Run from `service/` (expect roughly an hour; the RBF SVM dominates):

    python -m ml.resume_fit.tuned_benchmark
"""

from __future__ import annotations

import asyncio
import json
import time
from collections import Counter
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
INNER_SPLITS = 3
N_CONFIGS = 8          # identical for every model - see docstring
SCALE_SENSITIVE = {"logistic_regression", "gaussian_nb", "knn", "svm_rbf", "mlp"}

# Untuned reference values from train_benchmark.py, for the delta column.
UNTUNED_AUC = {
    "logistic_regression": 0.6647, "gaussian_nb": 0.6671, "knn": 0.6797,
    "svm_rbf": 0.6863, "random_forest": 0.6881, "extra_trees": 0.6855,
    "gradient_boosting": 0.6891, "hist_gradient_boosting": 0.6795, "mlp": 0.6958,
}


def _grids() -> dict:
    """Hyper-parameter grids. Kept deliberately sane rather than exhaustive:
    the question is whether reasonable tuning moves the ranking, not what the
    global optimum is."""
    return {
        "logistic_regression": [
            {"C": c, "penalty": "l2", "solver": "lbfgs", "max_iter": 4000}
            for c in [0.01, 0.05, 0.1, 0.5, 1.0, 3.0, 10.0, 50.0]
        ],
        "gaussian_nb": [
            {"var_smoothing": v}
            for v in [1e-11, 1e-10, 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4]
        ],
        "knn": [
            {"n_neighbors": k, "weights": w}
            for k in [5, 15, 25, 50] for w in ["uniform", "distance"]
        ],
        "svm_rbf": [
            {"C": c, "gamma": g, "kernel": "rbf", "probability": True, "random_state": SEED}
            for c in [0.5, 2.0, 8.0, 32.0] for g in ["scale", "auto"]
        ],
        "random_forest": [
            {"n_estimators": n, "max_depth": d, "min_samples_leaf": m,
             "random_state": SEED, "n_jobs": -1}
            for n, d, m in [(200, 8, 5), (200, 16, 3), (400, 12, 3), (400, 24, 1),
                            (600, 12, 5), (600, None, 3), (800, 16, 2), (800, None, 1)]
        ],
        "extra_trees": [
            {"n_estimators": n, "max_depth": d, "min_samples_leaf": m,
             "random_state": SEED, "n_jobs": -1}
            for n, d, m in [(200, 8, 5), (200, 16, 3), (400, 16, 2), (400, None, 1),
                            (600, 12, 5), (600, 24, 2), (800, None, 2), (800, 32, 1)]
        ],
        "gradient_boosting": [
            {"n_estimators": n, "learning_rate": lr, "max_depth": d,
             "subsample": 0.9, "random_state": SEED}
            for n, lr, d in [(100, 0.1, 2), (100, 0.05, 3), (200, 0.1, 3),
                             (300, 0.05, 2), (300, 0.05, 3), (300, 0.02, 4),
                             (500, 0.02, 3), (500, 0.05, 2)]
        ],
        "hist_gradient_boosting": [
            {"max_iter": n, "learning_rate": lr, "max_depth": d,
             "l2_regularization": l2, "random_state": SEED}
            for n, lr, d, l2 in [(200, 0.1, 3, 0.0), (200, 0.06, 4, 1.0),
                                 (400, 0.06, 4, 1.0), (400, 0.03, 6, 1.0),
                                 (600, 0.03, 4, 5.0), (600, 0.02, 8, 1.0),
                                 (800, 0.02, 6, 5.0), (800, 0.01, 8, 10.0)]
        ],
        "mlp": [
            {"hidden_layer_sizes": h, "alpha": a, "max_iter": 600,
             "early_stopping": True, "random_state": SEED}
            for h, a in [((32,), 1e-4), ((64,), 1e-3), ((64, 32), 1e-4),
                         ((64, 32), 1e-3), ((128, 64), 1e-3), ((128, 64), 1e-2),
                         ((256, 64), 1e-2), ((32, 16), 1e-2)]
        ],
    }


CTORS = {
    "logistic_regression": LogisticRegression, "gaussian_nb": GaussianNB,
    "knn": KNeighborsClassifier, "svm_rbf": SVC,
    "random_forest": RandomForestClassifier, "extra_trees": ExtraTreesClassifier,
    "gradient_boosting": GradientBoostingClassifier,
    "hist_gradient_boosting": HistGradientBoostingClassifier, "mlp": MLPClassifier,
}


def _matrix(examples, sims, stats) -> np.ndarray:
    return fx.to_matrix([
        fx.extract(
            resume_text=e.full_resume_text or e.resume_text,
            job_description_text=e.full_job_description_text or e.job_description_text,
            embedding_cosine=s, stats=stats,
        ) for e, s in zip(examples, sims)
    ])


async def main() -> int:
    print("[tuned] loading + embedding (cached) ...")
    tr, te = load_examples()
    pool = list(tr) + list(te)
    sims, labels, examples = await build_features(pool)
    y = np.asarray(labels, dtype=int)
    groups = np.asarray([e.full_job_description_text or e.job_description_text for e in examples])
    print(f"[tuned] {len(y)} rows, {len(set(groups))} postings")

    grids = _grids()
    names = list(grids.keys())
    outer = list(GroupKFold(n_splits=N_SPLITS).split(np.zeros(len(y)), y, groups))

    per_model_auc: dict[str, list[float]] = {n: [] for n in names}
    chosen: dict[str, Counter] = {n: Counter() for n in names}
    fold_rows = []

    for fold, (tr_idx, te_idx) in enumerate(outer):
        t_fold = time.perf_counter()
        tr_ex = [examples[i] for i in tr_idx]
        stats = fx.DocumentStats.fit(
            [e.full_resume_text or e.resume_text for e in tr_ex]
            + [e.full_job_description_text or e.job_description_text for e in tr_ex]
        )
        X = _matrix(examples, sims, stats)
        X_tr, X_te = X[tr_idx], X[te_idx]
        y_tr, y_te = y[tr_idx], y[te_idx]
        g_tr = groups[tr_idx]

        scaler = StandardScaler().fit(X_tr)
        X_tr_s, X_te_s = scaler.transform(X_tr), scaler.transform(X_te)

        inner = list(GroupKFold(n_splits=INNER_SPLITS).split(X_tr, y_tr, g_tr))

        line = [f"fold {fold}"]
        for name in names:
            scaled = name in SCALE_SENSITIVE
            A_tr = X_tr_s if scaled else X_tr
            A_te = X_te_s if scaled else X_te

            configs = grids[name][:N_CONFIGS]
            best_cfg, best_score = None, -1.0
            for cfg in configs:
                scores = []
                for i_tr, i_te in inner:
                    m = CTORS[name](**cfg)
                    m.fit(A_tr[i_tr], y_tr[i_tr])
                    p = m.predict_proba(A_tr[i_te])[:, 1]
                    ev = shared_metrics.evaluate(p.tolist(), [bool(v) for v in y_tr[i_te]])
                    if ev.auc is not None:
                        scores.append(ev.auc)
                s = float(np.mean(scores)) if scores else -1.0
                if s > best_score:
                    best_cfg, best_score = cfg, s

            model = CTORS[name](**best_cfg)
            model.fit(A_tr, y_tr)
            proba = model.predict_proba(A_te)[:, 1]
            ev = shared_metrics.evaluate(proba.tolist(), [bool(v) for v in y_te])
            per_model_auc[name].append(ev.auc)
            chosen[name][json.dumps(best_cfg, default=str, sort_keys=True)] += 1
            fold_rows.append({"model": name, "fold": fold, "auc": ev.auc,
                              "accuracy": ev.accuracy, "innerBestAuc": best_score,
                              "config": best_cfg})
            line.append(f"{name.split('_')[0]}={ev.auc:.3f}")
        print("[tuned] " + "  ".join(line) + f"   ({time.perf_counter()-t_fold:.0f}s)")

    summary = {}
    for n in names:
        a = np.asarray(per_model_auc[n], dtype=float)
        summary[n] = {
            "tunedAuc": {"mean": float(a.mean()), "std": float(a.std())},
            "untunedAuc": UNTUNED_AUC[n],
            "delta": float(a.mean() - UNTUNED_AUC[n]),
            "mostSelectedConfig": chosen[n].most_common(1)[0][0],
            "configSelectionCounts": dict(chosen[n]),
        }

    ranked = sorted(names, key=lambda n: summary[n]["tunedAuc"]["mean"], reverse=True)
    best = ranked[0]
    fr_stat, fr_p = friedmanchisquare(*[per_model_auc[n] for n in names])

    raw_p = {}
    for n in names:
        if n == best:
            continue
        try:
            _, p = wilcoxon(per_model_auc[best], per_model_auc[n])
        except ValueError:
            p = 1.0
        raw_p[n] = p
    order = sorted(raw_p, key=raw_p.get)
    holm, run = {}, 0.0
    for i, n in enumerate(order):
        run = max(run, min(1.0, (len(order) - i) * raw_p[n]))
        holm[n] = run

    spread_tuned = summary[ranked[0]]["tunedAuc"]["mean"] - summary[ranked[-1]]["tunedAuc"]["mean"]
    spread_untuned = max(UNTUNED_AUC.values()) - min(UNTUNED_AUC.values())

    report = {
        "question": "Does an equal-budget nested hyper-parameter search change the conclusion?",
        "protocol": {
            "outer": f"GroupKFold(n_splits={N_SPLITS}) by job description (same folds as Table 1)",
            "inner": f"GroupKFold(n_splits={INNER_SPLITS}) by job description on the training fold",
            "configsPerModel": N_CONFIGS,
            "selectionMetric": "mean inner-fold AUROC",
            "note": "Every model receives an identical search budget; unequal budgets would "
                    "compare tuning effort rather than algorithms.",
        },
        "models": summary,
        "rankingByTunedAuc": ranked,
        "best": best,
        "spreadTuned": spread_tuned,
        "spreadUntuned": spread_untuned,
        "significance": {
            "friedman_chi2": float(fr_stat), "friedman_p": float(fr_p),
            "pairwise_vs_best": {
                n: {"wilcoxon_raw_p": raw_p[n], "holm_adjusted_p": holm[n],
                    "deltaAuc": summary[best]["tunedAuc"]["mean"] - summary[n]["tunedAuc"]["mean"],
                    "significant_at_0.05": bool(holm[n] < 0.05)}
                for n in raw_p
            },
        },
    }

    out = Path(__file__).parent
    (out / "tuned_benchmark.report.json").write_text(json.dumps(report, indent=2, default=str))
    cols = ["model", "fold", "auc", "accuracy", "innerBestAuc"]
    csv = [",".join(cols)] + [",".join(str(r[c]) for c in cols) for r in fold_rows]
    (out / "tuned_benchmark_folds.csv").write_text("\n".join(csv))

    print("\n[tuned] === tuned vs untuned, mean AUROC over 10 outer folds ===")
    print(f"{'model':24s} {'tuned':>16s} {'untuned':>9s} {'delta':>8s}")
    for n in ranked:
        s = summary[n]
        print(f"{n:24s} {s['tunedAuc']['mean']:.4f}+/-{s['tunedAuc']['std']:.3f}  "
              f"{s['untunedAuc']:>9.4f} {s['delta']:>+8.4f}")
    print(f"\n[tuned] spread untuned {spread_untuned:.4f} -> tuned {spread_tuned:.4f}")
    print(f"[tuned] Friedman chi2={fr_stat:.2f} p={fr_p:.3e}   best={best}")
    for n in ranked[1:]:
        pw = report["significance"]["pairwise_vs_best"][n]
        flag = "differs" if pw["significant_at_0.05"] else "n.s."
        print(f"        vs {n:24s} dAUC={pw['deltaAuc']:+.4f}  Holm p={pw['holm_adjusted_p']:.3f}  [{flag}]")
    print(f"\n[tuned] wrote {out / 'tuned_benchmark.report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
