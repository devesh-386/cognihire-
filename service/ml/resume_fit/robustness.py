"""Robustness checks against the two most likely objections to the main result.

## Objection 1 - "your split still lets resumes leak, so of course a
## resume-identity effect shows up"

Grouping by job description is the dataset's own intended protocol: it tests
generalisation to an unseen posting. It deliberately does NOT hold resumes
out, and the main result argues that this is precisely what inflates the
apparent score. This experiment quantifies that by holding the features and
the model fixed and varying ONLY the splitting scheme:

  S1  KFold, no grouping        - the naive protocol (both sides seen in train)
  S2  GroupKFold by posting     - the dataset's protocol, used in the main result
  S3  GroupKFold by resume      - resumes held out; the confound is removed

If S1 > S2 > S3 with S3 collapsing toward chance, then most of the reported
performance on this benchmark is attributable to having seen the resume
before, not to having learned matching.

## Objection 2 - "you binarised a 3-class label; the relational signal may
## live in the distinction you collapsed"

The main pipeline maps {Good Fit, Potential Fit} -> True and {No Fit} ->
False. `Potential Fit` is a genuinely fuzzy middle class, so this checks
whether a cleaner contrast recovers signal:

  L1  binary as-shipped         - Good+Potential vs No Fit
  L2  extreme contrast          - Good Fit vs No Fit only (Potential dropped)
  L3  three-class               - macro one-vs-rest AUC

If L2 does not materially exceed L1, the binarisation is not what is hiding
the signal.

Run from `service/`:

    python -m ml.resume_fit.robustness
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import GroupKFold, KFold
from sklearn.preprocessing import StandardScaler

from ml import metrics as shared_metrics
from ml.resume_fit import features as fx
from ml.resume_fit.data import _MAX_CHARS, _binarize, _embed_all, cosine_similarity

SEED = 100
N_SPLITS = 10


async def _load_raw():
    """Loads every row WITHOUT the class-balancing downsample and keeps the
    original 3-class label, because L2/L3 need the classes separated."""
    from datasets import load_dataset

    ds = load_dataset("cnamuangtoun/resume-job-description-fit")
    rows = list(ds["train"]) + list(ds["test"])

    r_texts = [r["resume_text"][:_MAX_CHARS] for r in rows]
    j_texts = [r["job_description_text"][:_MAX_CHARS] for r in rows]
    r_vecs = await _embed_all(r_texts)
    j_vecs = await _embed_all(j_texts)

    keep = [i for i, (a, b) in enumerate(zip(r_vecs, j_vecs)) if a is not None and b is not None]
    rows = [rows[i] for i in keep]
    cos = np.asarray([
        cosine_similarity(r_vecs[i], j_vecs[i]) for i in keep
    ])
    label3 = np.asarray([r["label"] for r in rows])
    y2 = np.asarray([_binarize(r["label"]) for r in rows], dtype=int)
    resume = np.asarray([r["resume_text"] for r in rows])
    jd = np.asarray([r["job_description_text"] for r in rows])
    return rows, cos, label3, y2, resume, jd


def _features_for(rows, cos, train_idx, all_idx) -> np.ndarray:
    """IDF fitted on `train_idx` only, features computed for `all_idx`."""
    stats = fx.DocumentStats.fit(
        [rows[i]["resume_text"] for i in train_idx]
        + [rows[i]["job_description_text"] for i in train_idx]
    )
    return fx.to_matrix([
        fx.extract(
            resume_text=rows[i]["resume_text"],
            job_description_text=rows[i]["job_description_text"],
            embedding_cosine=cos[i], stats=stats,
        )
        for i in all_idx
    ])


def _run_cv(rows, cos, y, idx, splits, label: str) -> dict:
    """One CV scheme. `splits` yields (train_positions, test_positions) into
    `idx`. Class weights balance the folds so accuracy stays interpretable
    when the subset is not 50/50."""
    aucs, accs = [], []
    for tr_pos, te_pos in splits:
        tr, te = idx[tr_pos], idx[te_pos]
        if len(set(y[tr])) < 2 or len(set(y[te])) < 2:
            continue
        X_all = _features_for(rows, cos, tr, np.concatenate([tr, te]))
        X_tr, X_te = X_all[:len(tr)], X_all[len(tr):]
        scaler = StandardScaler().fit(X_tr)
        model = RandomForestClassifier(
            n_estimators=300, max_depth=12, min_samples_leaf=3,
            random_state=SEED, n_jobs=-1, class_weight="balanced",
        )
        model.fit(scaler.transform(X_tr), y[tr])
        p = model.predict_proba(scaler.transform(X_te))[:, 1]
        m = shared_metrics.evaluate(p.tolist(), [bool(v) for v in y[te]])
        if m.auc is not None:
            aucs.append(m.auc)
        accs.append(m.accuracy)
    out = {
        "auc_mean": float(np.mean(aucs)), "auc_std": float(np.std(aucs)),
        "accuracy_mean": float(np.mean(accs)), "accuracy_std": float(np.std(accs)),
        "folds": len(aucs), "rows": int(len(idx)),
    }
    print(f"[robust] {label:38s} AUC {out['auc_mean']:.4f}+/-{out['auc_std']:.3f}   "
          f"acc {out['accuracy_mean']:.4f}   (n={len(idx)})")
    return out


def main() -> int:
    rows, cos, label3, y2, resume, jd = asyncio.run(_load_raw())
    n = len(rows)
    print(f"[robust] {n} rows, {len(set(resume))} resumes, {len(set(jd))} postings")
    print(f"[robust] 3-class counts: "
          + ", ".join(f"{k}={int((label3 == k).sum())}" for k in sorted(set(label3))))

    all_idx = np.arange(n)
    report = {"splitStrategy": {}, "labelGranularity": {}}

    # ---- Objection 1: split strategy ------------------------------------
    print("\n[robust] --- split strategy (relational-10 features, RandomForest) ---")
    report["splitStrategy"]["S1_kfold_no_grouping"] = _run_cv(
        rows, cos, y2, all_idx,
        list(KFold(n_splits=N_SPLITS, shuffle=True, random_state=SEED).split(all_idx)),
        "S1 KFold, no grouping (naive)")

    report["splitStrategy"]["S2_group_by_posting"] = _run_cv(
        rows, cos, y2, all_idx,
        list(GroupKFold(n_splits=N_SPLITS).split(all_idx, y2, jd)),
        "S2 GroupKFold by posting (dataset's own)")

    report["splitStrategy"]["S3_group_by_resume"] = _run_cv(
        rows, cos, y2, all_idx,
        list(GroupKFold(n_splits=N_SPLITS).split(all_idx, y2, resume)),
        "S3 GroupKFold by resume (confound removed)")

    # ---- Objection 2: label granularity ---------------------------------
    print("\n[robust] --- label granularity (GroupKFold by posting throughout) ---")
    report["labelGranularity"]["L1_binary_as_shipped"] = _run_cv(
        rows, cos, y2, all_idx,
        list(GroupKFold(n_splits=N_SPLITS).split(all_idx, y2, jd)),
        "L1 Good+Potential vs No Fit")

    extreme = all_idx[(label3 == "Good Fit") | (label3 == "No Fit")]
    y_extreme = (label3[extreme] == "Good Fit").astype(int)
    y_full = np.zeros(n, dtype=int)
    y_full[extreme] = y_extreme
    report["labelGranularity"]["L2_good_vs_nofit"] = _run_cv(
        rows, cos, y_full, extreme,
        list(GroupKFold(n_splits=N_SPLITS).split(extreme, y_extreme, jd[extreme])),
        "L2 Good Fit vs No Fit (Potential dropped)")

    # L3: one-vs-rest AUC per class, macro-averaged.
    print("[robust] L3 three-class one-vs-rest:")
    ovr = {}
    for cls in sorted(set(label3)):
        y_cls = (label3 == cls).astype(int)
        ovr[cls] = _run_cv(
            rows, cos, y_cls, all_idx,
            list(GroupKFold(n_splits=N_SPLITS).split(all_idx, y_cls, jd)),
            f"   vs-rest: {cls}")
    report["labelGranularity"]["L3_three_class_ovr"] = ovr
    report["labelGranularity"]["L3_macro_auc"] = float(
        np.mean([v["auc_mean"] for v in ovr.values()])
    )
    print(f"[robust] L3 macro AUC: {report['labelGranularity']['L3_macro_auc']:.4f}")

    report["interpretation"] = {
        "objection1": "If S1 > S2 > S3 with S3 near chance, most reported performance on this "
                      "benchmark comes from having seen the resume before, not from matching.",
        "objection2": "If L2 does not materially exceed L1, collapsing the fuzzy middle class "
                      "is not what hides the relational signal.",
    }

    out = Path(__file__).parent
    (out / "robustness.report.json").write_text(json.dumps(report, indent=2))
    print(f"\n[robust] wrote {out / 'robustness.report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
