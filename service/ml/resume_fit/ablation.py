"""Representation ablation: is the ceiling the algorithm, the features, or the labels?

## The question this answers

`train_benchmark.py` shows nine algorithms from six families converging to
0.665-0.696 AUC on the resume<->job-description fit task. Three explanations
are consistent with that:

  H1  the ALGORITHMS are the bottleneck  -> a better model breaks the ceiling
  H2  the FEATURES are the bottleneck    -> a richer representation breaks it
  H3  the LABELS are the bottleneck      -> nothing breaks it, because the
                                            target is not actually a function
                                            of the (resume, JD) relation

`train_benchmark.py` already makes H1 unlikely. This file separates H2 from
H3 by holding the protocol fixed (10-fold GroupKFold grouped by job
description, identical folds) and varying only the REPRESENTATION:

  R0  naive          fixed cosine >= 0.5 threshold, no learning at all
  R1  cosine-1       the single embedding-cosine feature (the v1 model)
  R2  relational-10  the 10 hand-engineered relational features (current model)
  R3  resume-only    768-d resume embedding; the job description is NEVER SEEN
  R4  jd-only        768-d JD embedding; the resume is NEVER SEEN
  R5  concat         [resume ; jd] 1536-d - can memorise either side
  R6  interaction    [|r-j| ; r*j] 1536-d - the standard sentence-pair
                     relational encoding, far richer than a single cosine

R3 is the load-bearing probe. A model that never sees the job description
cannot possibly be judging a MATCH. Whatever accuracy R3 reaches is accuracy
attributable to the resume's identity alone. If R3 ~= R2, the label is
predominantly a property of the resume, and the benchmark does not measure
what its name says it measures.

R6 is the fair test of H2. If a rich learned relational encoding also fails
to beat R2, the features are exonerated and H3 is what remains.

Also computed: a non-parametric **resume-identity lookup** baseline (memorise
each resume's majority label on the training folds, apply to test) which
needs no features at all, and a **learning curve** on the best
representation to separate "not enough data" from "not enough signal".

Run from `service/`:

    python -m ml.resume_fit.ablation
"""

from __future__ import annotations

import asyncio
import json
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import GroupKFold
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler

from ml import metrics as shared_metrics
from ml.resume_fit import features as fx
from ml.resume_fit.data import _embed_all, cosine_similarity, load_examples

SEED = 100
N_SPLITS = 10


def _models() -> dict:
    """Three representatives, one per family that mattered in the full
    benchmark: linear, bagging ensemble, neural. Running all nine across
    seven representations would add cost without changing the conclusion,
    since the full benchmark already established the models are within
    noise of each other."""
    return {
        "logistic_regression": LogisticRegression(solver="lbfgs", max_iter=3000, C=1.0),
        "random_forest": RandomForestClassifier(
            n_estimators=300, max_depth=12, min_samples_leaf=3, random_state=SEED, n_jobs=-1
        ),
        "mlp": MLPClassifier(
            hidden_layer_sizes=(64, 32), alpha=1e-3, max_iter=500,
            early_stopping=True, random_state=SEED
        ),
    }


async def _load() -> dict:
    train_examples, test_examples = load_examples()
    pool = list(train_examples) + list(test_examples)

    resume_texts = [e.resume_text for e in pool]
    jd_texts = [e.job_description_text for e in pool]
    r_vecs = await _embed_all(resume_texts)
    j_vecs = await _embed_all(jd_texts)

    keep = [i for i, (r, j) in enumerate(zip(r_vecs, j_vecs)) if r is not None and j is not None]
    examples = [pool[i] for i in keep]
    R = np.asarray([r_vecs[i] for i in keep], dtype=float)
    J = np.asarray([j_vecs[i] for i in keep], dtype=float)
    y = np.asarray([e.fit for e in examples], dtype=int)
    groups = np.asarray([e.full_job_description_text or e.job_description_text for e in examples])
    resume_id = np.asarray([e.full_resume_text or e.resume_text for e in examples])
    cos = np.asarray([cosine_similarity(R[i].tolist(), J[i].tolist()) for i in range(len(examples))])

    return {"examples": examples, "R": R, "J": J, "y": y,
            "groups": groups, "resume_id": resume_id, "cos": cos}


def _relational_10(examples, cos, stats) -> np.ndarray:
    return fx.to_matrix([
        fx.extract(
            resume_text=e.full_resume_text or e.resume_text,
            job_description_text=e.full_job_description_text or e.job_description_text,
            embedding_cosine=c, stats=stats,
        )
        for e, c in zip(examples, cos)
    ])


def main() -> int:
    d = asyncio.run(_load())
    examples, R, J, y = d["examples"], d["R"], d["J"], d["y"]
    groups, resume_id, cos = d["groups"], d["resume_id"], d["cos"]
    n = len(y)
    print(f"[ablation] {n} rows, {len(set(groups))} job descriptions, "
          f"{len(set(resume_id))} resumes, positive rate {y.mean():.3f}")

    splitter = GroupKFold(n_splits=N_SPLITS)
    folds = list(splitter.split(np.zeros(n), y, groups))

    # Representations that do not depend on a per-fold fit are built once.
    static_reps = {
        "R1_cosine_1": cos.reshape(-1, 1),
        "R3_resume_only_768": R,
        "R4_jd_only_768": J,
        "R5_concat_1536": np.hstack([R, J]),
        "R6_interaction_1536": np.hstack([np.abs(R - J), R * J]),
    }

    results: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    naive_acc, lookup_acc, lookup_cov = [], [], []

    for fold, (tr, te) in enumerate(folds):
        y_tr, y_te = y[tr], y[te]

        # --- R0: naive fixed threshold, no learning -----------------------
        naive_acc.append(float(np.mean((cos[te] >= 0.5) == y_te.astype(bool))))

        # --- resume-identity lookup: no features whatsoever ---------------
        votes: dict[str, Counter] = defaultdict(Counter)
        for i in tr:
            votes[resume_id[i]][int(y[i])] += 1
        hit = tot = 0
        for i in te:
            v = votes.get(resume_id[i])
            if not v:
                continue
            hit += int(v.most_common(1)[0][0] == y[i])
            tot += 1
        lookup_acc.append(hit / tot if tot else float("nan"))
        lookup_cov.append(tot / len(te))

        # --- R2 needs IDF fitted on the training rows of THIS fold --------
        tr_ex = [examples[i] for i in tr]
        stats = fx.DocumentStats.fit(
            [e.full_resume_text or e.resume_text for e in tr_ex]
            + [e.full_job_description_text or e.job_description_text for e in tr_ex]
        )
        rel10 = _relational_10(examples, cos, stats)

        reps = dict(static_reps)
        reps["R2_relational_10"] = rel10

        for rep_name, X in reps.items():
            X_tr, X_te = X[tr], X[te]
            scaler = StandardScaler().fit(X_tr)
            X_tr_s, X_te_s = scaler.transform(X_tr), scaler.transform(X_te)

            for model_name, model in _models().items():
                # Everything is scaled here: the high-dimensional embedding
                # representations make scaling the sane default, and the
                # full benchmark already showed trees are indifferent to it.
                t0 = time.perf_counter()
                model.fit(X_tr_s, y_tr)
                fit_s = time.perf_counter() - t0
                proba = model.predict_proba(X_te_s)[:, 1]
                m = shared_metrics.evaluate(proba.tolist(), [bool(v) for v in y_te])
                results[rep_name][model_name].append(
                    {"auc": m.auc, "accuracy": m.accuracy, "fit_s": fit_s}
                )
        print(f"[ablation] fold {fold} done")

    # ---- summarise -------------------------------------------------------
    def ms(vals):
        vals = [v for v in vals if v is not None and not (isinstance(v, float) and np.isnan(v))]
        return float(np.mean(vals)), float(np.std(vals))

    summary = {}
    for rep_name, per_model in results.items():
        summary[rep_name] = {}
        for model_name, runs in per_model.items():
            a_m, a_s = ms([r["auc"] for r in runs])
            c_m, c_s = ms([r["accuracy"] for r in runs])
            summary[rep_name][model_name] = {
                "auc": {"mean": a_m, "std": a_s},
                "accuracy": {"mean": c_m, "std": c_s},
                "fit_s": {"mean": ms([r["fit_s"] for r in runs])[0]},
            }

    # best model per representation, by AUC
    best_per_rep = {
        rep: max(models_, key=lambda m: models_[m]["auc"]["mean"])
        for rep, models_ in summary.items()
    }

    # ---- learning curve on R2, to separate data-limit from signal-limit --
    print("[ablation] learning curve on R2_relational_10 (random_forest)...")
    curve = []
    rng = np.random.default_rng(SEED)
    for frac in [0.1, 0.25, 0.5, 0.75, 1.0]:
        aucs = []
        for tr, te in folds:
            k = max(50, int(len(tr) * frac))
            sub = rng.choice(tr, size=k, replace=False)
            tr_ex = [examples[i] for i in sub]
            stats = fx.DocumentStats.fit(
                [e.full_resume_text or e.resume_text for e in tr_ex]
                + [e.full_job_description_text or e.job_description_text for e in tr_ex]
            )
            X = _relational_10(examples, cos, stats)
            scaler = StandardScaler().fit(X[sub])
            model = RandomForestClassifier(
                n_estimators=300, max_depth=12, min_samples_leaf=3, random_state=SEED, n_jobs=-1
            )
            model.fit(scaler.transform(X[sub]), y[sub])
            p = model.predict_proba(scaler.transform(X[te]))[:, 1]
            m = shared_metrics.evaluate(p.tolist(), [bool(v) for v in y[te]])
            if m.auc is not None:
                aucs.append(m.auc)
        curve.append({"trainFraction": frac,
                      "trainRows": int(np.mean([int(len(tr) * frac) for tr, _ in folds])),
                      "auc_mean": float(np.mean(aucs)), "auc_std": float(np.std(aucs))})
        print(f"[ablation]   {frac:.0%} -> AUC {np.mean(aucs):.4f}")

    naive_m, naive_s = ms(naive_acc)
    lookup_m, lookup_s = ms(lookup_acc)

    report = {
        "question": "Is the performance ceiling the algorithm, the features, or the labels?",
        "protocol": {
            "cv": f"GroupKFold(n_splits={N_SPLITS}) grouped by job_description_text - identical folds across every representation",
            "rows": n,
            "jobDescriptions": len(set(groups)),
            "resumes": len(set(resume_id)),
            "positiveRate": float(y.mean()),
        },
        "baselines": {
            "R0_naive_fixed_cosine_threshold": {"accuracy_mean": naive_m, "accuracy_std": naive_s},
            "resume_identity_lookup": {
                "accuracy_mean": lookup_m, "accuracy_std": lookup_s,
                "coverage_mean": float(np.mean(lookup_cov)),
                "note": "memorise each resume's majority label on the training folds; uses NO features and NEVER sees the job description",
            },
        },
        "representations": summary,
        "bestModelPerRepresentation": best_per_rep,
        "learningCurve_R2_randomForest": curve,
    }

    out = Path(__file__).parent
    (out / "ablation.report.json").write_text(json.dumps(report, indent=2))

    print("\n[ablation] === best AUC per representation (10-fold GroupKFold by JD) ===")
    order = ["R1_cosine_1", "R2_relational_10", "R3_resume_only_768",
             "R4_jd_only_768", "R5_concat_1536", "R6_interaction_1536"]
    print(f"{'representation':24s} {'best model':22s} {'AUC':>16s} {'accuracy':>16s}")
    for rep in order:
        if rep not in summary:
            continue
        bm = best_per_rep[rep]
        s = summary[rep][bm]
        print(f"{rep:24s} {bm:22s} "
              f"{s['auc']['mean']:.3f}+/-{s['auc']['std']:.3f}   "
              f"{s['accuracy']['mean']:.3f}+/-{s['accuracy']['std']:.3f}")
    print(f"\n{'R0_naive (no learning)':24s} {'-':22s} {'-':>16s} "
          f"{naive_m:.3f}+/-{naive_s:.3f}")
    print(f"{'resume-identity lookup':24s} {'(no features at all)':22s} {'-':>16s} "
          f"{lookup_m:.3f}+/-{lookup_s:.3f}   coverage {np.mean(lookup_cov):.1%}")
    print(f"\n[ablation] wrote {out / 'ablation.report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
