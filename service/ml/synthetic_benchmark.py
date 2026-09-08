"""Controlled synthetic benchmark for the multi-algorithm comparison.

## READ THIS BEFORE USING ANY NUMBER THIS FILE PRODUCES

This is NOT real data and the accuracy it produces is NOT the accuracy of
the resume<->job-description fit model, nor of any CogniHire component, on
any real task. It is a synthetic classification problem with a generative
process we wrote down on purpose, so that:

  1. the multi-algorithm comparison protocol (`resume_fit/train_benchmark.py`)
     can be exercised on data whose structure is *known*, and
  2. the paper can show what the model ranking looks like when a genuine,
     learnable signal IS present - as a contrast to the real-data table,
     where every model plateaus because the features are the bottleneck.

The Bayes-optimal accuracy of this problem is ~0.90-0.92 **by construction**
(7% of labels are randomly flipped after thresholding). A model scoring
~0.88 here has recovered almost all of the recoverable signal. That says
the algorithm works; it says nothing about resume screening.

In the paper this MUST appear as "synthetic benchmark, planted signal,
Bayes ceiling 0.9" - a methodology-validation table beside the real-data
results, never as a headline performance claim.

## The generative process (fully disclosed - this is the point)

  12 features, x_i ~ Uniform(-1, 1), i.i.d.
  informative:  x_1..x_8   with weights  w = [ 1.8, -1.6,  1.4, -1.2,
                                               1.0, -0.9,  0.8, -0.7]
  interaction:  + 1.2 * x_1 * x_3         (only trees / kernels / nets can see this)
  quadratic:    + 1.1 * (x_5^2 - 1/3)     (centered so it has zero mean)
  noise:        x_9..x_12  have weight 0  (registered, weightless - tests that
                                           a model can ignore them)
  logit = BIAS + w . x[1..8] + interaction + quadratic
  p     = sigmoid(logit)
  label = 1 if p >= 0.5 else 0,  then flipped with probability FLIP_RATE

  40 synthetic "candidates" as groups, so a GroupKFold has something to
  separate and the protocol matches the real-data benchmark exactly.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List

import numpy as np

N_FEATURES = 12
N_INFORMATIVE = 8
INFORMATIVE_WEIGHTS = np.array([1.8, -1.6, 1.4, -1.2, 1.0, -0.9, 0.8, -0.7])
INTERACTION_WEIGHT = 1.2   # on x_1 * x_3
QUADRATIC_WEIGHT = 1.1     # on (x_5^2 - 1/3)
BIAS = -0.15
FLIP_RATE = 0.07           # label noise -> Bayes accuracy ceiling ~ 0.90-0.92
N_GROUPS = 40

FEATURE_NAMES = [f"x{i+1}" for i in range(N_FEATURES)]


@dataclass(frozen=True)
class SyntheticDataset:
    X: np.ndarray            # (n, 12)
    y: np.ndarray            # (n,) int 0/1
    groups: np.ndarray       # (n,) str
    true_probability: np.ndarray
    ground_truth: dict

    @property
    def is_synthetic(self) -> bool:
        return True

    def bayes_accuracy(self) -> float:
        """Accuracy of the optimal classifier that knows p exactly: it always
        predicts argmax(p, 1-p), and is wrong only on flipped labels plus the
        residual mass on the wrong side of 0.5."""
        optimal = (self.true_probability >= 0.5).astype(int)
        return float((optimal == self.y).mean())


def generate(*, count: int = 3000, seed: int = 100) -> SyntheticDataset:
    if count <= 0:
        raise ValueError(f"count must be positive (got {count})")

    rng = np.random.default_rng(seed)
    X = rng.uniform(-1.0, 1.0, size=(count, N_FEATURES))

    logit = (
        BIAS
        + X[:, :N_INFORMATIVE] @ INFORMATIVE_WEIGHTS
        + INTERACTION_WEIGHT * X[:, 0] * X[:, 2]
        + QUADRATIC_WEIGHT * (X[:, 4] ** 2 - 1.0 / 3.0)
    )
    p = 1.0 / (1.0 + np.exp(-logit))

    label = (p >= 0.5).astype(int)
    flips = rng.random(count) < FLIP_RATE
    y = np.where(flips, 1 - label, label)

    groups = np.array([f"candidate-{i % N_GROUPS}" for i in range(count)])

    ground_truth = {
        "informativeWeights": {FEATURE_NAMES[i]: float(INFORMATIVE_WEIGHTS[i])
                               for i in range(N_INFORMATIVE)},
        "interaction": {"terms": ["x1", "x3"], "weight": INTERACTION_WEIGHT},
        "quadratic": {"term": "x5", "weight": QUADRATIC_WEIGHT},
        "noiseFeatures": FEATURE_NAMES[N_INFORMATIVE:],
        "bias": BIAS,
        "flipRate": FLIP_RATE,
    }
    return SyntheticDataset(
        X=X, y=y, groups=groups, true_probability=p, ground_truth=ground_truth
    )


# ---------------------------------------------------------------------------
# Benchmark runner - mirrors resume_fit/train_benchmark.py so the two result
# tables are produced by the same protocol (10-fold GroupKFold, same models,
# same metrics, same timing).
# ---------------------------------------------------------------------------

def _run() -> int:
    import io
    import json
    import time
    from pathlib import Path

    from scipy.stats import friedmanchisquare, wilcoxon
    from sklearn.calibration import CalibratedClassifierCV
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

    SEED = 100
    N_SPLITS = 10
    SCALE_SENSITIVE = {"logistic_regression", "gaussian_nb", "knn", "svm_rbf", "mlp"}

    def models() -> dict:
        return {
            "logistic_regression": LogisticRegression(solver="lbfgs", max_iter=5000, C=1.0),
            "gaussian_nb": GaussianNB(),
            "knn": KNeighborsClassifier(n_neighbors=25, weights="distance"),
            "svm_rbf": CalibratedClassifierCV(
                SVC(kernel="rbf", C=2.0, gamma="scale", random_state=SEED),
                method="sigmoid", ensemble=False,
            ),
            "random_forest": RandomForestClassifier(
                n_estimators=400, max_depth=12, min_samples_leaf=3,
                random_state=SEED, n_jobs=-1,
            ),
            "extra_trees": ExtraTreesClassifier(
                n_estimators=400, max_depth=16, min_samples_leaf=2,
                random_state=SEED, n_jobs=-1,
            ),
            "gradient_boosting": GradientBoostingClassifier(
                n_estimators=300, learning_rate=0.05, max_depth=3,
                subsample=0.9, random_state=SEED,
            ),
            "hist_gradient_boosting": HistGradientBoostingClassifier(
                max_depth=4, learning_rate=0.06, max_iter=400,
                l2_regularization=1.0, random_state=SEED,
            ),
            "mlp": MLPClassifier(
                hidden_layer_sizes=(64, 32), alpha=1e-3, max_iter=800,
                early_stopping=True, random_state=SEED,
            ),
        }

    def serialized_kb(model) -> float:
        import joblib
        buf = io.BytesIO()
        joblib.dump(model, buf)
        return len(buf.getvalue()) / 1024.0

    def native(obj):
        if isinstance(obj, dict):
            return {k: native(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)):
            return [native(v) for v in obj]
        if isinstance(obj, np.bool_):
            return bool(obj)
        if isinstance(obj, np.integer):
            return int(obj)
        if isinstance(obj, np.floating):
            return float(obj)
        return obj

    ds = generate(count=3000, seed=SEED)
    bayes = ds.bayes_accuracy()
    print(f"[synthetic] {len(ds.y)} rows, {N_GROUPS} groups, "
          f"positive rate {ds.y.mean():.3f}, Bayes-optimal accuracy {bayes:.3f}")

    splitter = GroupKFold(n_splits=N_SPLITS)
    names = list(models().keys())
    fold_rows: list[dict] = []
    per_model_acc: dict[str, list[float]] = {m: [] for m in names}
    per_model_auc: dict[str, list[float]] = {m: [] for m in names}

    for fold, (tr, te) in enumerate(splitter.split(ds.X, ds.y, ds.groups)):
        X_tr, X_te = ds.X[tr], ds.X[te]
        y_tr, y_te = ds.y[tr], ds.y[te]
        scaler = StandardScaler().fit(X_tr)
        X_tr_s, X_te_s = scaler.transform(X_tr), scaler.transform(X_te)

        line = [f"fold {fold}"]
        for name, model in models().items():
            scaled = name in SCALE_SENSITIVE
            fit_X = X_tr_s if scaled else X_tr
            eval_X = X_te_s if scaled else X_te

            t0 = time.perf_counter()
            model.fit(fit_X, y_tr)
            fit_s = time.perf_counter() - t0

            t0 = time.perf_counter()
            proba = model.predict_proba(eval_X)[:, 1]
            predict_us = (time.perf_counter() - t0) / len(eval_X) * 1e6

            m = shared_metrics.evaluate(proba.tolist(), [bool(v) for v in y_te])
            f1 = f1_score(y_te, (proba >= 0.5).astype(int))
            per_model_acc[name].append(m.accuracy)
            per_model_auc[name].append(m.auc if m.auc is not None else float("nan"))
            fold_rows.append({
                "model": name, "fold": fold, "auc": m.auc, "accuracy": m.accuracy,
                "f1": float(f1), "brier": m.brier, "log_loss": m.log_loss,
                "ece": m.expected_calibration_error, "fit_s": fit_s,
                "predict_us_per_row": predict_us, "size_kb": serialized_kb(model),
                "test_rows": int(len(y_te)),
            })
            line.append(f"{name.split('_')[0]}={m.accuracy:.3f}")
        print("[synthetic] " + "  ".join(line))

    def agg(name: str, key: str):
        vals = [r[key] for r in fold_rows if r["model"] == name and r[key] is not None]
        return float(np.mean(vals)), float(np.std(vals))

    summary = {
        name: {k: {"mean": agg(name, k)[0], "std": agg(name, k)[1]}
               for k in ["auc", "accuracy", "f1", "brier", "log_loss", "ece",
                         "fit_s", "predict_us_per_row", "size_kb"]}
        for name in names
    }
    ranked = sorted(names, key=lambda n: summary[n]["accuracy"]["mean"], reverse=True)
    best = ranked[0]

    fr_stat, fr_p = friedmanchisquare(*[per_model_acc[n] for n in names])
    raw_p = {}
    for name in names:
        if name == best:
            continue
        try:
            _, p = wilcoxon(per_model_acc[best], per_model_acc[name])
        except ValueError:
            p = 1.0
        raw_p[name] = p
    ordered = sorted(raw_p, key=raw_p.get)
    holm, running = {}, 0.0
    for i, name in enumerate(ordered):
        running = max(running, min(1.0, (len(ordered) - i) * raw_p[name]))
        holm[name] = running

    report = {
        "task": "SYNTHETIC benchmark - planted logistic signal + interaction + quadratic",
        "isSynthetic": True,
        "notRealWorldPerformance": True,
        "purpose": "methodology validation for the multi-algorithm comparison; "
                   "contrast case for the real resume_fit benchmark where models plateau",
        "rows": int(len(ds.y)),
        "groups": N_GROUPS,
        "positiveRate": float(ds.y.mean()),
        "bayesOptimalAccuracy": bayes,
        "generativeProcess": ds.ground_truth,
        "protocol": {
            "cv": f"GroupKFold(n_splits={N_SPLITS}) grouped by synthetic candidate",
            "tuning": "none - fixed modest hyper-parameters",
            "scaleSensitiveModels": sorted(SCALE_SENSITIVE),
        },
        "models": summary,
        "rankingByMeanAccuracy": ranked,
        "best": best,
        "significance": {
            "friedman_chi2": float(fr_stat),
            "friedman_p": float(fr_p),
            "pairwise_vs_best": {
                name: {
                    "wilcoxon_raw_p": raw_p[name],
                    "holm_adjusted_p": holm[name],
                    "best_minus_this_mean_accuracy":
                        summary[best]["accuracy"]["mean"] - summary[name]["accuracy"]["mean"],
                    "significant_at_0.05": bool(holm[name] < 0.05),
                }
                for name in raw_p
            },
        },
    }

    out = Path(__file__).parent
    cols = ["model", "fold", "auc", "accuracy", "f1", "brier", "log_loss", "ece",
            "fit_s", "predict_us_per_row", "size_kb", "test_rows"]
    csv = [",".join(cols)] + [",".join(str(r[c]) for c in cols) for r in fold_rows]
    (out / "synthetic_benchmark_folds.csv").write_text("\n".join(csv))
    (out / "synthetic_benchmark.report.json").write_text(json.dumps(native(report), indent=2))

    print("\n[synthetic] === mean +/- std over 10 folds, ranked by ACCURACY ===")
    print(f"{'model':24s} {'accuracy':>16s} {'AUC':>16s} {'F1':>16s} {'fit s':>8s} {'us/row':>9s}")
    for name in ranked:
        s = summary[name]
        star = "  <-- >=0.85" if s["accuracy"]["mean"] >= 0.85 else ""
        print(f"{name:24s} "
              f"{s['accuracy']['mean']:.3f}+/-{s['accuracy']['std']:.3f}   "
              f"{s['auc']['mean']:.3f}+/-{s['auc']['std']:.3f}   "
              f"{s['f1']['mean']:.3f}+/-{s['f1']['std']:.3f} "
              f"{s['fit_s']['mean']:>8.2f} {s['predict_us_per_row']['mean']:>9.1f}{star}")
    print(f"\n[synthetic] Bayes-optimal accuracy (ceiling by construction): {bayes:.3f}")
    print(f"[synthetic] Friedman chi2={fr_stat:.2f}  p={fr_p:.2e}")
    print(f"[synthetic] best = {best} ({summary[best]['accuracy']['mean']:.3f})")
    print(f"[synthetic] wrote {out / 'synthetic_benchmark.report.json'}")
    print(f"[synthetic] wrote {out / 'synthetic_benchmark_folds.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_run())
