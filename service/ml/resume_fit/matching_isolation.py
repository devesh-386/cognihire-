"""Isolating the matching signal from the resume base rate.

## Why this experiment exists

`diagnose.py` shows a resume-identity lookup - memorise each resume's
majority label, never look at the job description - reaches 0.6064 accuracy
where the full 10-feature relational model reaches 0.6109. That is
suggestive but not conclusive, because 78% of resumes DO carry different
labels for different postings. So the label is not purely a resume
property; there is genuine within-resume variation.

The decisive question is therefore not "how accurate is the model" but:

    Of the label variation that is actually RELATIONAL - the same resume
    labelled fit for one posting and no-fit for another - how much can any
    model recover?

That is the matching task, isolated. A model that predicts only the
resume's base rate scores well on the overall task and exactly 0.5 here.

## The test

Decompose, then measure:

  1. **Variance decomposition.** Split total label variance into a
     between-resume component (some resumes are labelled fit more often
     than others) and a within-resume component (the same resume's label
     changes with the posting). Only the second is matching.

  2. **Within-resume pairwise ranking.** Train on the training folds. In
     each test fold, for every resume, form all (positive posting,
     negative posting) pairs. Score both with the model. The model is
     correct if it gives the positive posting the higher probability.
     Chance is exactly 0.5, and the resume's base rate cancels out
     completely because both items of a pair share the same resume.

  3. **Between-resume pairwise ranking**, for contrast: pairs drawn from
     DIFFERENT resumes. If between-resume ranking is well above chance
     while within-resume ranking is at chance, the model is ranking
     resumes, not matches - and the benchmark's name is misleading.

Two representations are tested so the conclusion is not an artifact of the
hand-engineered features: the 10 relational features, and the 1536-d
interaction encoding [|r-j| ; r*j] that is standard for sentence-pair tasks.

Run from `service/`:

    python -m ml.resume_fit.matching_isolation
"""

from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import GroupKFold
from sklearn.preprocessing import StandardScaler

from ml.resume_fit import features as fx
from ml.resume_fit.data import _embed_all, cosine_similarity, load_examples

SEED = 100
N_SPLITS = 10
MAX_PAIRS_PER_RESUME = 40   # caps the combinatorics on prolific resumes


async def _load():
    tr, te = load_examples()
    pool = list(tr) + list(te)
    r_vecs = await _embed_all([e.resume_text for e in pool])
    j_vecs = await _embed_all([e.job_description_text for e in pool])
    keep = [i for i, (r, j) in enumerate(zip(r_vecs, j_vecs)) if r is not None and j is not None]
    ex = [pool[i] for i in keep]
    R = np.asarray([r_vecs[i] for i in keep], dtype=float)
    J = np.asarray([j_vecs[i] for i in keep], dtype=float)
    y = np.asarray([e.fit for e in ex], dtype=int)
    cos = np.asarray([cosine_similarity(R[i].tolist(), J[i].tolist()) for i in range(len(ex))])
    groups = np.asarray([e.full_job_description_text or e.job_description_text for e in ex])
    rid = np.asarray([e.full_resume_text or e.resume_text for e in ex])
    return ex, R, J, y, cos, groups, rid


def _variance_decomposition(y: np.ndarray, rid: np.ndarray) -> dict:
    """Between- vs within-resume components of the label.

    total variance = E_r[Var(y | r)]  +  Var_r(E[y | r])
                      ^ within           ^ between
    """
    by_resume: dict[str, list[int]] = defaultdict(list)
    for label, r in zip(y, rid):
        by_resume[r].append(int(label))

    means, withins, weights = [], [], []
    for labels in by_resume.values():
        arr = np.asarray(labels, dtype=float)
        means.append(arr.mean())
        withins.append(arr.var())
        weights.append(len(arr))

    weights_arr = np.asarray(weights, dtype=float)
    w = weights_arr / weights_arr.sum()
    within = float(np.sum(w * np.asarray(withins)))
    grand = float(np.sum(w * np.asarray(means)))
    between = float(np.sum(w * (np.asarray(means) - grand) ** 2))
    total = within + between

    multi = [labels for labels in by_resume.values() if len(labels) >= 2]
    varying = [labels for labels in multi if len(set(labels)) > 1]

    return {
        "totalVariance": total,
        "betweenResumeVariance": between,
        "withinResumeVariance": within,
        "withinResumeShare": within / total if total else 0.0,
        "resumes": len(by_resume),
        "resumesWithMultiplePostings": len(multi),
        "resumesWithVaryingLabel": len(varying),
        "note": "withinResumeShare is the fraction of label variance that is genuinely "
                "relational - the maximum any matching model could explain.",
    }


def _pairwise_ranking(proba: np.ndarray, y: np.ndarray, rid: np.ndarray,
                      *, within: bool, rng) -> tuple[int, int]:
    """Returns (correct, total) over (positive, negative) pairs.

    within=True  -> both items share a resume (base rate cancels; pure matching)
    within=False -> items come from different resumes (base rate is usable)

    Ties count as half, the standard AUC convention.
    """
    idx_by_resume: dict[str, list[int]] = defaultdict(list)
    for i, r in enumerate(rid):
        idx_by_resume[r].append(i)

    correct = 0.0
    total = 0

    if within:
        for indices in idx_by_resume.values():
            pos = [i for i in indices if y[i] == 1]
            neg = [i for i in indices if y[i] == 0]
            if not pos or not neg:
                continue
            pairs = [(p, n) for p in pos for n in neg]
            if len(pairs) > MAX_PAIRS_PER_RESUME:
                sel = rng.choice(len(pairs), size=MAX_PAIRS_PER_RESUME, replace=False)
                pairs = [pairs[k] for k in sel]
            for p, nn in pairs:
                total += 1
                correct += 1.0 if proba[p] > proba[nn] else (0.5 if proba[p] == proba[nn] else 0.0)
    else:
        pos_all = [i for i in range(len(y)) if y[i] == 1]
        neg_all = [i for i in range(len(y)) if y[i] == 0]
        if not pos_all or not neg_all:
            return 0, 0
        # sample the same order of magnitude of pairs as the within test
        budget = min(20000, len(pos_all) * len(neg_all))
        ps = rng.choice(pos_all, size=budget, replace=True)
        ns = rng.choice(neg_all, size=budget, replace=True)
        for p, nn in zip(ps, ns):
            if rid[p] == rid[nn]:
                continue
            total += 1
            correct += 1.0 if proba[p] > proba[nn] else (0.5 if proba[p] == proba[nn] else 0.0)

    return correct, total


def main() -> int:
    ex, R, J, y, cos, groups, rid = asyncio.run(_load())
    n = len(y)
    print(f"[matching] {n} rows, {len(set(rid))} resumes, {len(set(groups))} postings")

    decomp = _variance_decomposition(y, rid)
    print(f"[matching] label variance: between-resume {decomp['betweenResumeVariance']:.4f}, "
          f"within-resume {decomp['withinResumeVariance']:.4f} "
          f"({decomp['withinResumeShare']:.1%} of total is relational)")
    print(f"[matching] {decomp['resumesWithVaryingLabel']}/{decomp['resumes']} resumes "
          f"have a label that varies across postings")

    interaction = np.hstack([np.abs(R - J), R * J])
    folds = list(GroupKFold(n_splits=N_SPLITS).split(np.zeros(n), y, groups))
    rng = np.random.default_rng(SEED)

    out_rows = {}
    for rep_name in ["relational_10", "interaction_1536"]:
        within_c, within_t = 0.0, 0
        between_c, between_t = 0.0, 0
        per_fold_within = []

        for fold, (tr, te) in enumerate(folds):
            if rep_name == "relational_10":
                tr_ex = [ex[i] for i in tr]
                stats = fx.DocumentStats.fit(
                    [e.full_resume_text or e.resume_text for e in tr_ex]
                    + [e.full_job_description_text or e.job_description_text for e in tr_ex]
                )
                X = fx.to_matrix([
                    fx.extract(
                        resume_text=e.full_resume_text or e.resume_text,
                        job_description_text=e.full_job_description_text or e.job_description_text,
                        embedding_cosine=c, stats=stats,
                    ) for e, c in zip(ex, cos)
                ])
            else:
                X = interaction

            scaler = StandardScaler().fit(X[tr])
            model = RandomForestClassifier(
                n_estimators=300, max_depth=12, min_samples_leaf=3,
                random_state=SEED, n_jobs=-1
            )
            model.fit(scaler.transform(X[tr]), y[tr])
            p = model.predict_proba(scaler.transform(X[te]))[:, 1]

            wc, wt = _pairwise_ranking(p, y[te], rid[te], within=True, rng=rng)
            bc, bt = _pairwise_ranking(p, y[te], rid[te], within=False, rng=rng)
            within_c += wc; within_t += wt
            between_c += bc; between_t += bt
            if wt:
                per_fold_within.append(wc / wt)

        w_acc = within_c / within_t if within_t else float("nan")
        b_acc = between_c / between_t if between_t else float("nan")

        # Binomial test against chance for the within-resume result.
        from scipy.stats import binomtest
        bt_res = binomtest(int(round(within_c)), within_t, 0.5, alternative="two-sided")

        out_rows[rep_name] = {
            "withinResumePairAccuracy": w_acc,
            "withinResumePairs": within_t,
            "withinResumePerFold": per_fold_within,
            "withinResumeStd": float(np.std(per_fold_within)) if per_fold_within else None,
            "withinResumeBinomialP": float(bt_res.pvalue),
            "betweenResumePairAccuracy": b_acc,
            "betweenResumePairs": between_t,
        }
        print(f"[matching] {rep_name:18s} within-resume {w_acc:.4f} (n={within_t}, "
              f"p={bt_res.pvalue:.3g})   between-resume {b_acc:.4f} (n={between_t})")

    report = {
        "question": "Of the label variation that is genuinely relational, how much can a model recover?",
        "protocol": {
            "cv": f"GroupKFold(n_splits={N_SPLITS}) grouped by job description",
            "model": "RandomForest(300 trees, depth 12) - the strongest tree model in the full benchmark",
            "pairwiseConvention": "ties count 0.5; chance = 0.5 exactly",
            "maxPairsPerResume": MAX_PAIRS_PER_RESUME,
        },
        "varianceDecomposition": decomp,
        "pairwiseRanking": out_rows,
        "interpretation": (
            "within-resume pair accuracy near 0.5 means the model cannot tell which posting a "
            "given resume fits - all of its apparent skill is ranking resumes against each other, "
            "which is a resume-quality task, not a matching task."
        ),
    }
    out = Path(__file__).parent
    (out / "matching_isolation.report.json").write_text(json.dumps(report, indent=2))
    print(f"\n[matching] wrote {out / 'matching_isolation.report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
