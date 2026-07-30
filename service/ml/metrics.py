"""Honest binary-classification metrics.

Port of `lib/core/ml/binary_metrics.dart`. The discipline carried over from that
file: `auc` is None when only one class is present rather than a fabricated 0.5,
because with no negatives (or no positives) there is genuinely no ranking to
score. A metric that returns a plausible number for an unanswerable question is
worse than one that returns nothing.

AUC, Brier, and log-loss come from scikit-learn — battle-tested implementations
of textbook formulas, which is precisely the reason this pipeline moved to
Python. Expected calibration error and the reliability bins are computed here
because scikit-learn's `calibration_curve` drops empty bins, and a dropped bin
silently changes the ECE denominator.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Sequence

import numpy as np
from sklearn.metrics import brier_score_loss, log_loss, roc_auc_score

_EPS = 1e-12


@dataclass(frozen=True)
class ReliabilityBin:
    lower_edge: float
    upper_edge: float
    count: int
    mean_confidence: float
    observed_accuracy: float


@dataclass(frozen=True)
class BinaryMetrics:
    count: int
    positive_count: int
    auc: Optional[float]
    brier: float
    log_loss: float
    accuracy: float
    expected_calibration_error: float
    reliability_bins: List[ReliabilityBin] = field(default_factory=list)

    def to_json(self) -> dict:
        return {
            "count": self.count,
            "positiveCount": self.positive_count,
            "auc": self.auc,
            "brier": self.brier,
            "logLoss": self.log_loss,
            "accuracy": self.accuracy,
            "expectedCalibrationError": self.expected_calibration_error,
            "reliabilityBins": [
                {
                    "lowerEdge": b.lower_edge,
                    "upperEdge": b.upper_edge,
                    "count": b.count,
                    "meanConfidence": b.mean_confidence,
                    "observedAccuracy": b.observed_accuracy,
                }
                for b in self.reliability_bins
            ],
        }


def evaluate(
    probabilities: Sequence[float],
    labels: Sequence[bool],
    *,
    calibration_bins: int = 10,
) -> BinaryMetrics:
    if len(probabilities) != len(labels):
        raise ValueError(
            f"probabilities ({len(probabilities)}) and labels ({len(labels)}) "
            "must be the same length"
        )
    if not probabilities:
        raise ValueError("cannot evaluate an empty prediction set")

    p = np.asarray(probabilities, dtype=float)
    if np.any(p < 0.0) or np.any(p > 1.0):
        raise ValueError("probabilities must lie in [0, 1]")
    y = np.asarray(labels, dtype=bool)

    n = int(p.size)
    positives = int(y.sum())

    pc = np.clip(p, _EPS, 1.0 - _EPS)
    brier = float(brier_score_loss(y.astype(int), p))
    # labels=[0,1] so log_loss does not fail on a single-class test split.
    ll = float(log_loss(y.astype(int), pc, labels=[0, 1]))
    accuracy = float(((p >= 0.5) == y).mean())

    # Undefined with only one class present — say so rather than invent 0.5.
    auc = float(roc_auc_score(y.astype(int), p)) if 0 < positives < n else None

    bins = _reliability(p, y, calibration_bins)
    ece = sum(b.count / n * abs(b.mean_confidence - b.observed_accuracy) for b in bins)

    return BinaryMetrics(
        count=n,
        positive_count=positives,
        auc=auc,
        brier=brier,
        log_loss=ll,
        accuracy=accuracy,
        expected_calibration_error=float(ece),
        reliability_bins=bins,
    )


def _reliability(p: np.ndarray, y: np.ndarray, bin_count: int) -> List[ReliabilityBin]:
    if bin_count <= 0:
        raise ValueError(f"calibration_bins must be positive (got {bin_count})")

    # Right-closed final bin so a probability of exactly 1.0 lands in the last
    # bin instead of falling off the end.
    idx = np.minimum((p * bin_count).astype(int), bin_count - 1)

    out: List[ReliabilityBin] = []
    for b in range(bin_count):
        mask = idx == b
        count = int(mask.sum())
        out.append(
            ReliabilityBin(
                lower_edge=b / bin_count,
                upper_edge=(b + 1) / bin_count,
                count=count,
                mean_confidence=float(p[mask].mean()) if count else 0.0,
                observed_accuracy=float(y[mask].mean()) if count else 0.0,
            )
        )
    return out
