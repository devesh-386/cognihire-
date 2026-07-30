"""Isotonic recalibration, in the exact representation the Dart scorer evaluates.

Port of `lib/core/ml/isotonic_calibrator.dart`.

## Why this hand-rolls PAVA instead of just calling scikit-learn

It looks like `sklearn.isotonic.IsotonicRegression` should do this, and for
*fitting* it would. But the two produce different functions from the same fit:

  * scikit-learn exposes knots and interpolates **linearly** between them.
  * The Dart calibrator is a **step function** — pooled blocks, each with an
    upper score bound and a constant value, and a query takes the first block
    whose bound is >= the score.

Exporting scikit-learn's knots would therefore ship a calibrator that disagrees
with the one the app actually evaluates, at every point between two knots. The
disagreement would be small, plausible, and completely invisible — the worst
kind. So PAVA is implemented here to match the Dart block semantics exactly, and
`test_pipeline.py` cross-checks it against scikit-learn at the knots to prove
the pooling itself is right. Same argument as keeping the Dart trainer: two
independent implementations agreeing is the evidence.

This maps scores to probabilities and asserts nothing about whether the
underlying model is valid — a well-calibrated wrong model is still wrong.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Sequence


@dataclass(frozen=True)
class IsotonicCalibrator:
    """A fitted monotonic non-decreasing step function from raw score to
    empirical probability.

    `block_max_score[i]` is the ascending upper score bound of block i, aligned
    with `block_value[i]`.
    """

    block_max_score: List[float]
    block_value: List[float]

    def calibrate(self, score: float) -> float:
        """Scores below the first block clamp to the first block's value; above
        the last, to the last. Extrapolation beyond the calibration data's
        support is held flat rather than invented."""
        for bound, value in zip(self.block_max_score, self.block_value):
            if score <= bound:
                return value
        return self.block_value[-1]

    def calibrate_all(self, scores: Sequence[float]) -> List[float]:
        return [self.calibrate(s) for s in scores]

    def to_json(self) -> dict:
        return {
            "blockMaxScore": list(self.block_max_score),
            "blockValue": list(self.block_value),
        }


def fit_isotonic(scores: Sequence[float], labels: Sequence[bool]) -> IsotonicCalibrator:
    """Fit on held-out (score, label) pairs via Pool Adjacent Violators.

    Must be a **calibration fold** — never the training or test fold, or the
    correction is fit and judged on the same data and its measured benefit is
    an artifact of that overlap.
    """
    if not scores or len(scores) != len(labels):
        raise ValueError(
            "scores and labels must be the same nonzero length "
            f"(got {len(scores)} and {len(labels)})"
        )
    if len(set(bool(l) for l in labels)) < 2:
        raise ValueError(
            "calibration sample contains only one class — the fit would collapse "
            "to a constant and hide, rather than correct, miscalibration"
        )

    order = sorted(range(len(scores)), key=lambda i: scores[i])

    # Each block carries a pooled target sum, a weight (count), and the max
    # score it spans. Start with singletons and pool any adjacent pair that
    # violates non-decreasing means. Mirrors the Dart loop line for line.
    sums: List[float] = []
    weights: List[float] = []
    max_score: List[float] = []

    for i in order:
        s = 1.0 if labels[i] else 0.0
        w = 1.0
        ms = float(scores[i])
        while sums and sums[-1] / weights[-1] > s / w:
            s += sums.pop()
            w += weights.pop()
            popped_max = max_score.pop()
            if popped_max > ms:
                ms = popped_max
        sums.append(s)
        weights.append(w)
        max_score.append(ms)

    return IsotonicCalibrator(
        block_max_score=max_score,
        block_value=[s / w for s, w in zip(sums, weights)],
    )
