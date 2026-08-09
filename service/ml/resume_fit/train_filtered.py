"""v3: trains only on resumes whose label varies across postings.

`diagnose.py` found the real bottleneck in this dataset: a résumé-only
baseline (predicting the label from the résumé alone, ignoring the job
description entirely) scored 60.6% — almost identical to the full
10-feature model's 61.1%. 141 of 643 résumés (22%) never change label
across postings at all, which means for those résumés the label is a
property of the résumé, not of the match, and every one of them is pure
noise for a matching task — the model gets no signal from them about how
to compare a résumé against a posting, only how to recognize which résumés
tend to be labeled well.

This script removes exactly those résumés and re-runs the same pipeline as
`train.py` v2. If accuracy on the *matching-relevant* subset comes out
meaningfully higher than 61%, that confirms the ceiling was the confound,
not the feature set or model choice. If it does not, the ceiling is
something else and more data/better features from this dataset specifically
are unlikely to help.
"""

from __future__ import annotations

import asyncio
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

from ml import metrics as shared_metrics
from ml.resume_fit import features as feature_extraction
from ml.resume_fit.data import FitExample, _binarize, _truncate, build_features
from ml.resume_fit.train import _build_matrix, _candidate_models


def _varying_resumes(all_rows) -> set[str]:
    labels_by_resume: dict[str, set] = defaultdict(set)
    for row in all_rows:
        labels_by_resume[row["resume_text"]].add(_binarize(row["label"]))
    return {resume for resume, labels in labels_by_resume.items() if len(labels) > 1}


def _to_examples(rows) -> list[FitExample]:
    return [
        FitExample(
            resume_text=_truncate(r["resume_text"]),
            job_description_text=_truncate(r["job_description_text"]),
            fit=_binarize(r["label"]),
            full_resume_text=r["resume_text"],
            full_job_description_text=r["job_description_text"],
        )
        for r in rows
    ]


def _balance(rows: list, seed: int) -> list:
    import random

    rng = random.Random(seed)
    by_label: dict[bool, list] = {True: [], False: []}
    for r in rows:
        by_label[_binarize(r["label"])].append(r)
    limit = min(len(b) for b in by_label.values())
    sampled = []
    for bucket in by_label.values():
        rng.shuffle(bucket)
        sampled.extend(bucket[:limit])
    rng.shuffle(sampled)
    return sampled


async def main() -> int:
    from datasets import load_dataset

    ds = load_dataset("cnamuangtoun/resume-job-description-fit")
    all_rows = list(ds["train"]) + list(ds["test"])

    varying = _varying_resumes(all_rows)
    print(f"[resume_fit_v3] {len(varying)} resumes have a label that varies across postings "
          f"(of {len(set(r['resume_text'] for r in all_rows))} total)")

    train_rows = [r for r in ds["train"] if r["resume_text"] in varying]
    test_rows = [r for r in ds["test"] if r["resume_text"] in varying]
    print(f"[resume_fit_v3] after filtering: {len(train_rows)} train rows, {len(test_rows)} test rows "
          f"(was 6241/1759 unfiltered)")

    train_rows = _balance(train_rows, seed=100)
    test_rows = _balance(test_rows, seed=101)
    print(f"[resume_fit_v3] after class balancing: {len(train_rows)} train, {len(test_rows)} test")

    train_examples = _to_examples(train_rows)
    test_examples = _to_examples(test_rows)

    # Sanity check: re-run the resume-only baseline on THIS filtered set —
    # if filtering worked, it should now sit near 50%, not 60%.
    resume_votes: dict[str, Counter] = defaultdict(Counter)
    for r in train_rows:
        resume_votes[r["resume_text"]][_binarize(r["label"])] += 1
    hits = total = 0
    for r in test_rows:
        votes = resume_votes.get(r["resume_text"])
        if not votes:
            continue
        predicted = votes.most_common(1)[0][0]
        hits += predicted == _binarize(r["label"])
        total += 1
    baseline = hits / total if total else float("nan")
    print(f"[resume_fit_v3] resume-only baseline on the FILTERED set: {baseline:.4f} "
          f"(on {total} rows; was 0.6064 unfiltered — should be near 0.5 now)")

    print("[resume_fit_v3] embedding (cached from v1/v2 runs where texts overlap)...")
    train_sims, train_labels, train_examples = await build_features(train_examples)
    test_sims, test_labels, test_examples = await build_features(test_examples)

    stats = feature_extraction.DocumentStats.fit(
        [ex.full_resume_text for ex in train_examples]
        + [ex.full_job_description_text for ex in train_examples]
    )

    X_train = _build_matrix(train_examples, train_sims, stats)
    X_test = _build_matrix(test_examples, test_sims, stats)
    y_train = np.asarray(train_labels, dtype=int)

    scaler = StandardScaler().fit(X_train)
    X_train_scaled, X_test_scaled = scaler.transform(X_train), scaler.transform(X_test)

    results = {}
    best_name, best_auc = None, -1.0
    for name, model in _candidate_models().items():
        uses_scaling = name == "logistic_regression"
        model.fit(X_train_scaled if uses_scaling else X_train, y_train)
        probs = model.predict_proba(X_test_scaled if uses_scaling else X_test)[:, 1].tolist()
        evaluated = shared_metrics.evaluate(probs, test_labels)
        results[name] = evaluated.to_json()
        print(f"[resume_fit_v3]   {name:22s} AUC={evaluated.auc:.4f} accuracy={evaluated.accuracy:.4f}")
        if evaluated.auc is not None and evaluated.auc > best_auc:
            best_name, best_auc = name, evaluated.auc

    best = results[best_name]
    print(f"[resume_fit_v3] best: {best_name} (AUC={best['auc']:.4f}, accuracy={best['accuracy']:.4f})")

    naive_accuracy = float(np.mean([(s >= 0.5) == l for s, l in zip(test_sims, test_labels)]))
    print(f"[resume_fit_v3] naive fixed-0.5-threshold accuracy on filtered set: {naive_accuracy:.4f}")

    report = {
        "note": (
            "Trained only on resumes whose label varies across postings, "
            "removing the resume-identity confound diagnose.py found in the "
            "full dataset (resume-only baseline there: 0.6064, nearly equal "
            "to the full model's 0.6109)."
        ),
        "resumeOnlyBaselineOnFilteredSet": baseline,
        "trainRows": len(train_sims),
        "testRows": len(test_sims),
        "allModels": results,
        "selectedModel": best_name,
        "heldOut": best,
        "naiveFixedThresholdAccuracy": naive_accuracy,
    }
    out = Path(__file__).parent / "resume_fit_model.filtered_report.json"
    out.write_text(json.dumps(report, indent=2))
    print(f"[resume_fit_v3] wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
