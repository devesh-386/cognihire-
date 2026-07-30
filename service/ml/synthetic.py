"""Synthetic, ground-truth-known data for the evidence-sufficiency target.

Port of `lib/core/ml/synthetic_sufficiency_dataset.dart`. Read that file's
header first — every warning in it applies here verbatim. In short: this is NOT
real candidate data and must never be treated as evidence about a real person.
Its only purpose is to let us prove the training mechanism recovers an answer we
planted on purpose, before a single real labelled session exists.

## One difference from the Dart generator, stated plainly

The generative process — the features, their sampling ranges, the planted
weights, the bias — is identical. The *random number stream* is not: this uses
numpy's PCG64, Dart uses its own `math.Random`. So for a given seed the two
produce statistically equivalent datasets, not byte-identical ones. Nothing
downstream depends on cross-language row equality; the tests assert recovered
weights and metrics, which are properties of the process, not of the stream.
Asserting row equality would have meant reimplementing Dart's PRNG, which buys
a guarantee no consumer needs.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, NamedTuple, Optional

import numpy as np


class Range(NamedTuple):
    lo: float
    hi: float


@dataclass(frozen=True)
class Signal:
    """One feature in the generative process: name, sampling range, and its
    weight in standardized space (0.0 marks a deliberate noise feature)."""

    name: str
    lo: float
    hi: float
    weight: float


# The generative model. Mirrors `_model` in the Dart generator exactly — same
# registry feature names, same ranges, same planted weights and signs:
#   + genuine support, verified identity, answered claims, productive editing
#   - contradictions, sustained identity mismatches, superhuman-fast typing
# The last two are weight-0 NOISE: registered features with no generative
# influence, present so the trainer can be tested for ignoring them.
GENERATIVE_MODEL: List[Signal] = [
    Signal("graph.supportsEdgeCount", 0.0, 10.0, 1.4),
    Signal("graph.contradictsEdgeCount", 0.0, 6.0, -1.6),
    Signal("identity.verifiedShareOfMeasured", 0.0, 1.0, 1.2),
    Signal("identity.maxConsecutiveMismatches", 0.0, 5.0, -1.0),
    Signal("session.answeredToOpenedRatio", 0.0, 1.5, 0.8),
    Signal("editing.netToGrossRatio", 0.0, 1.0, 0.9),
    Signal("typing.veryFastKeystrokeRate", 0.0, 0.5, -1.1),
    # --- noise: registered, weightless ---
    Signal("typing.backspaceRate", 0.0, 0.4, 0.0),
    Signal("session.followUpCount", 0.0, 5.0, 0.0),
]

GENERATIVE_BIAS: float = -0.2


def standardize(raw: float, r: Range) -> float:
    """Map a raw value in [lo, hi] onto [-1, 1], midpoint to 0.

    This is the one transform shared by the generator, the trainer, and the
    Dart scorer. Publishing it (not just the data) is what makes weight recovery
    a fair, reproducible check — and what lets the exported JSON be scored in
    Dart without re-deriving anything.
    """
    mid = (r.lo + r.hi) / 2.0
    half = (r.hi - r.lo) / 2.0
    return 0.0 if half == 0 else (raw - mid) / half


@dataclass(frozen=True)
class SufficiencyExample:
    """One synthetic example: raw feature values, the manufactured label, the
    generative probability it was drawn from, and the synthetic candidate it
    belongs to (so a grouped split can be checked for leakage)."""

    features: Dict[str, float]
    sufficient: bool
    true_probability: float
    group: str


@dataclass(frozen=True)
class SyntheticSufficiencyDataset:
    examples: List[SufficiencyExample]
    ground_truth_weights: Dict[str, float]
    ground_truth_bias: float
    sampling_ranges: Dict[str, Range]

    @property
    def is_synthetic(self) -> bool:
        """Always true. There is intentionally no way to construct one of these
        that reports false."""
        return True

    def range_for(self, name: str) -> Range:
        """The sampling range recorded for `name`. Raises for an unknown feature
        rather than guessing a range."""
        if name not in self.sampling_ranges:
            raise KeyError(f'no sampling range recorded for "{name}"')
        return self.sampling_ranges[name]

    def standardize(self, name: str, raw: float) -> float:
        return standardize(raw, self.range_for(name))


class SyntheticSufficiencyGenerator:
    """Produces datasets from the fixed, documented logistic generative model.
    Deterministic given a seed, so experiments are reproducible."""

    def __init__(self, model: Optional[List[Signal]] = None, bias: float = GENERATIVE_BIAS):
        self._model = list(model if model is not None else GENERATIVE_MODEL)
        self._bias = bias

    def generate(
        self,
        *,
        count: int,
        seed: int,
        group_count: Optional[int] = None,
    ) -> SyntheticSufficiencyDataset:
        if count <= 0:
            raise ValueError(f"count must be positive (got {count})")

        # Default: roughly 10 examples per synthetic candidate, at least 2 groups
        # so a grouped split has something to separate.
        groups = group_count if group_count is not None else max(2, count // 10)
        if groups < 1:
            raise ValueError(f"group_count must be positive (got {groups})")

        rng = np.random.default_rng(seed)
        examples: List[SufficiencyExample] = []

        for i in range(count):
            features: Dict[str, float] = {}
            logit = self._bias
            for s in self._model:
                raw = float(s.lo + rng.random() * (s.hi - s.lo))
                features[s.name] = raw
                if s.weight != 0.0:
                    logit += s.weight * standardize(raw, Range(s.lo, s.hi))
            p = 1.0 / (1.0 + float(np.exp(-logit)))
            label = bool(rng.random() < p)
            examples.append(
                SufficiencyExample(
                    features=features,
                    sufficient=label,
                    true_probability=p,
                    group=f"candidate-{i % groups}",
                )
            )

        return SyntheticSufficiencyDataset(
            examples=examples,
            ground_truth_weights={s.name: s.weight for s in self._model if s.weight != 0.0},
            ground_truth_bias=self._bias,
            sampling_ranges={s.name: Range(s.lo, s.hi) for s in self._model},
        )
