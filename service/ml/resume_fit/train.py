"""Fits a 1-feature logistic regression — cosine similarity -> fit
probability — on real, human-labeled resume/job-description pairs.

Replaces the fixed `_MATCH_FLOOR = 0.5` threshold in
`ai/semantic_similarity.py` with a threshold and slope actually fit and
measured against held-out data, using the same discipline the sufficiency
model (`ml/train.py`) already established: grouped split (here, the
dataset's own predefined train/test partition, so no fitting decision ever
sees a test-fold row), scikit-learn's LBFGS solver, and the exact same
`ml/metrics.py` evaluation used everywhere else in this project so numbers
are comparable across models.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression

from ml import metrics as shared_metrics
from ml.resume_fit.data import build_features, load_examples

SCHEMA_VERSION = 1


@dataclass(frozen=True)
class TrainedResumeFitModel:
    weight: float
    bias: float

    def predict_probability(self, cosine_similarity: float) -> float:
        z = self.bias + self.weight * cosine_similarity
        clamped = max(-30.0, min(30.0, z))
        return 1.0 / (1.0 + float(np.exp(-clamped)))


def fit(similarities: list[float], labels: list[bool]) -> TrainedResumeFitModel:
    X = np.asarray(similarities, dtype=float).reshape(-1, 1)
    y = np.asarray(labels, dtype=int)
    if len(np.unique(y)) < 2:
        raise ValueError("training set contains only one class")

    clf = LogisticRegression(solver="lbfgs", max_iter=2000)
    clf.fit(X, y)
    return TrainedResumeFitModel(weight=float(clf.coef_[0][0]), bias=float(clf.intercept_[0]))


async def main() -> int:
    print("[resume_fit] loading dataset...")
    train_examples, test_examples = load_examples()
    print(f"[resume_fit] {len(train_examples)} train rows, {len(test_examples)} test rows")

    print("[resume_fit] embedding train set (cached after first run)...")
    train_sims, train_labels = await build_features(train_examples)
    print("[resume_fit] embedding test set (cached after first run)...")
    test_sims, test_labels = await build_features(test_examples)

    print(f"[resume_fit] fitting on {len(train_sims)} embedded rows...")
    model = fit(train_sims, train_labels)

    test_probs = [model.predict_probability(s) for s in test_sims]
    held_out = shared_metrics.evaluate(test_probs, test_labels)

    print(f"[resume_fit] held-out AUC={held_out.auc:.4f} accuracy={held_out.accuracy:.4f} "
          f"brier={held_out.brier:.4f} ece={held_out.expected_calibration_error:.4f}")

    # Compare against the un-fit 0.5-cosine-similarity threshold this
    # replaces, on the same held-out rows — the number that actually
    # justifies training this at all.
    naive_probs = [1.0 if s >= 0.5 else 0.0 for s in test_sims]
    naive_accuracy = float(np.mean([p == float(l) for p, l in zip(naive_probs, test_labels)]))
    print(f"[resume_fit] naive fixed-0.5-threshold accuracy on the same rows: {naive_accuracy:.4f}")

    report = {
        "trainedOnRealData": True,
        "datasetSource": "huggingface:cnamuangtoun/resume-job-description-fit",
        "trainRows": len(train_sims),
        "testRows": len(test_sims),
        "heldOut": held_out.to_json(),
        "naiveFixedThresholdAccuracy": naive_accuracy,
        "weight": model.weight,
        "bias": model.bias,
    }

    out_dir = Path(__file__).parent
    (out_dir / "resume_fit_model.report.json").write_text(json.dumps(report, indent=2))

    artifact = {
        "schemaVersion": SCHEMA_VERSION,
        "trainedOnRealData": True,
        "datasetSource": "huggingface:cnamuangtoun/resume-job-description-fit",
        "feature": "cosine_similarity",
        "weight": model.weight,
        "bias": model.bias,
    }
    (out_dir / "resume_fit_model.json").write_text(json.dumps(artifact, indent=2))

    print(f"[resume_fit] wrote {out_dir / 'resume_fit_model.json'} and .report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
