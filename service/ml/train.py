"""Fitting the sufficiency model, and exporting it for the Dart scorer.

Port of the training half of `lib/core/ml/sufficiency_model.dart`. The Dart file
hand-rolls batch gradient descent; this uses scikit-learn's LBFGS solver, which
converges to the same optimum far more reliably than a fixed 4000 iterations at
a fixed learning rate ever could.

## Matching the Dart objective exactly

This is the one place the port could silently diverge, so it is spelled out.
The Dart trainer descends the *mean* log-loss plus an L2 term whose gradient is
`l2 * w`, i.e. it minimises

    mean_loss(w) + (l2 / 2) * ||w||^2

scikit-learn's LogisticRegression minimises the *summed* loss plus `1/(2C)`:

    sum_loss(w) + (1 / (2C)) * ||w||^2

Multiplying the Dart objective by n makes the two comparable and gives
`1/(2C) = n * l2 / 2`, hence `C = 1 / (n * l2)` — computed in `_c_for`. Neither
implementation penalises the intercept, so no adjustment is needed there.

## What this refuses to do

There is deliberately no `fit_real`. There is no real Phase 2 data to give it,
and the honest move when that data lands is a separate, reviewed entry point
that sets `is_validated_on_real_data` only after held-out evaluation — never a
silent flip of a flag. Everything this module produces carries
`trained_on_synthetic_data=True` and `is_validated_on_real_data=False`, and the
exported JSON carries them too, so the app cannot lose track of what it loaded.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence

import numpy as np
from sklearn.linear_model import LogisticRegression

from .calibration import IsotonicCalibrator
from .synthetic import Range, SufficiencyExample, SyntheticSufficiencyDataset, standardize

# v2 added the optional "calibration" section. The Dart loader rejects any
# version it does not recognise rather than best-effort parsing it: a silently
# misread weight is a wrong decision that looks right.
SCHEMA_VERSION = 2


@dataclass(frozen=True)
class FeatureContribution:
    feature: str
    raw_value: float
    standardized_value: float
    weight: float
    contribution: float


@dataclass(frozen=True)
class SufficiencyAttribution:
    bias: float
    logit: float
    probability: float
    contributions: List[FeatureContribution]


@dataclass(frozen=True)
class TrainedSufficiencyModel:
    """A fitted logistic model plus everything the Dart scorer needs to
    reproduce its predictions bit-for-bit: the weights, the bias, and the raw
    ranges that define the standardization."""

    weights: Dict[str, float]
    bias: float
    ranges: Dict[str, Range]
    trained_on_synthetic_data: bool
    is_validated_on_real_data: bool

    @property
    def feature_names(self) -> List[str]:
        return list(self.weights.keys())

    def standardize_feature(self, name: str, raw: float) -> Optional[float]:
        if name not in self.ranges:
            return None
        return standardize(raw, self.ranges[name])

    def predict_probability(self, raw_features: Dict[str, float]) -> float:
        """Probability of "sufficient" for a raw feature map. A feature the model
        was not trained on is ignored; a trained feature missing from the map
        contributes its standardized midpoint (0) — "no information", never a
        fabricated extreme. Same rule as the Dart scorer."""
        z = self.bias
        for name, w in self.weights.items():
            raw = raw_features.get(name)
            if raw is None:
                continue
            z += w * standardize(raw, self.ranges[name])
        return _sigmoid(z)

    def explain(self, raw_features: Dict[str, float]) -> SufficiencyAttribution:
        """Exact per-feature decomposition of the logit. For a linear model the
        contributions plus the bias *are* the logit — the explanation is the
        arithmetic, not a post-hoc surrogate."""
        contributions: List[FeatureContribution] = []
        logit = self.bias
        for name, w in self.weights.items():
            r = self.ranges[name]
            raw = raw_features.get(name, (r.lo + r.hi) / 2.0)
            std = standardize(raw, r)
            c = w * std
            logit += c
            contributions.append(
                FeatureContribution(
                    feature=name,
                    raw_value=raw,
                    standardized_value=std,
                    weight=w,
                    contribution=c,
                )
            )
        contributions.sort(key=lambda c: abs(c.contribution), reverse=True)
        return SufficiencyAttribution(
            bias=self.bias,
            logit=logit,
            probability=_sigmoid(logit),
            contributions=contributions,
        )

    def to_json(self, *, calibrator: Optional[IsotonicCalibrator] = None) -> dict:
        """The export consumed by `SufficiencyModel.fromTrainedJson` in Dart.

        Feature order is sorted and stable so the artifact diffs cleanly in git
        — a reviewer should be able to see a weight change, not a reshuffle.

        `calibrator` is optional and, when present, must have been fitted on a
        dedicated calibration fold. The app applies it *after* scoring; the
        uncalibrated probability remains recoverable, because a calibrator is a
        correction to a model's confidence and not a replacement for it.
        """
        blob = {
            "schemaVersion": SCHEMA_VERSION,
            "trainedOnSyntheticData": self.trained_on_synthetic_data,
            "isValidatedOnRealData": self.is_validated_on_real_data,
            "bias": self.bias,
            "features": [
                {
                    "name": name,
                    "weight": self.weights[name],
                    "lo": self.ranges[name].lo,
                    "hi": self.ranges[name].hi,
                }
                for name in sorted(self.weights)
            ],
        }
        if calibrator is not None:
            blob["calibration"] = {
                "method": "isotonic",
                # Step function, NOT linear interpolation between knots — this
                # must match `IsotonicCalibrator.calibrate` in Dart exactly.
                # See calibration.py for why that distinction is load-bearing.
                "representation": "pavaBlocks",
                **calibrator.to_json(),
            }
        return blob


def fit_synthetic(
    dataset: SyntheticSufficiencyDataset,
    *,
    train_on: Optional[Sequence[SufficiencyExample]] = None,
    l2: float = 0.001,
    max_iter: int = 5000,
) -> TrainedSufficiencyModel:
    """Fit on a synthetic dataset, or on a subset of it (e.g. a grouped split's
    train side), standardizing with the dataset's ranges either way so the
    transform is identical to the one prediction will later apply.

    Trains over **every** feature present in the examples — including the
    deliberate noise features — so that "the trainer ignores noise" is something
    a test can verify, not something guaranteed by hiding the noise from it.
    """
    examples = list(train_on if train_on is not None else dataset.examples)
    if not examples:
        raise ValueError("cannot fit on an empty dataset")

    feature_names = sorted(examples[0].features.keys())

    X = np.array(
        [
            [dataset.standardize(name, ex.features.get(name, 0.0)) for name in feature_names]
            for ex in examples
        ],
        dtype=float,
    )
    y = np.array([1 if ex.sufficient else 0 for ex in examples], dtype=int)

    if len(np.unique(y)) < 2:
        raise ValueError(
            "training set contains only one class — a fit on it would encode the "
            "class prior, not a decision rule"
        )

    # penalty is left at its default: L2 is the default in every scikit-learn
    # version this supports, and passing penalty="l2" explicitly is deprecated
    # as of 1.8. The strength is what matters, and that is C.
    clf = LogisticRegression(
        C=_c_for(n=X.shape[0], l2=l2),
        solver="lbfgs",
        max_iter=max_iter,
        fit_intercept=True,
    )
    clf.fit(X, y)

    return TrainedSufficiencyModel(
        weights={name: float(w) for name, w in zip(feature_names, clf.coef_[0])},
        bias=float(clf.intercept_[0]),
        ranges={name: dataset.range_for(name) for name in feature_names},
        trained_on_synthetic_data=True,
        is_validated_on_real_data=False,
    )


def _c_for(*, n: int, l2: float) -> float:
    """scikit-learn's C for an L2 strength expressed the way the Dart trainer
    expresses it. See the module docstring for the derivation. l2 <= 0 means no
    regularization, which sklearn spells as a very large C."""
    if l2 <= 0:
        return 1e12
    return 1.0 / (n * l2)


def _sigmoid(z: float) -> float:
    clamped = max(-30.0, min(30.0, z))
    return 1.0 / (1.0 + float(np.exp(-clamped)))
