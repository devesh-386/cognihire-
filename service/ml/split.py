"""Train/test splitting that partitions by candidate, never by row.

Port of `lib/core/ml/grouped_split.dart`; the reasoning there is the important
part and is not repeated in full here. Summary: the unit of independence is a
candidate, not a single answer. If some of a candidate's rows land in train and
others in test, the model can memorise that candidate's typing rhythm or camera
and then be scored on what is effectively training data — optimistic in exactly
the way that later fails on a genuinely new person.

scikit-learn ships `GroupShuffleSplit`, which would do this correctly. It is not
used, because its group assignment is driven by scikit-learn's own RNG and would
diverge from the Dart implementation's documented behaviour (sort the distinct
groups, seeded-shuffle, take a rounded fraction). Keeping the algorithm explicit
means the two implementations can be reasoned about as the same procedure.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Generic, List, Sequence, TypeVar

import numpy as np

T = TypeVar("T")


@dataclass(frozen=True)
class GroupedSplit(Generic[T]):
    train: List[T]
    test: List[T]

    def leaks(self, group_of: Callable[[T], str]) -> bool:
        """True if any group appears on both sides. Should always be False —
        exposed so a test can assert the structural guarantee rather than
        trusting it."""
        return bool(
            {group_of(e) for e in self.train} & {group_of(e) for e in self.test}
        )


def grouped_split(
    examples: Sequence[T],
    *,
    train_fraction: float,
    seed: int,
    group_of: Callable[[T], str],
) -> GroupedSplit[T]:
    """Partition so `train_fraction` of the *groups* go to train and the rest to
    test, with no group split across the two."""
    if not 0.0 < train_fraction < 1.0:
        raise ValueError(
            f"train_fraction must be in (0,1) exclusive (got {train_fraction})"
        )

    # Stable, sorted list of distinct groups, then a seeded shuffle so the
    # assignment is reproducible and independent of input row order.
    groups = sorted({group_of(e) for e in examples})
    rng = np.random.default_rng(seed)
    rng.shuffle(groups)

    # round() to match the Dart implementation's rounding, not int() truncation.
    train_group_count = int(round(len(groups) * train_fraction))
    train_groups = set(groups[:train_group_count])

    train: List[T] = []
    test: List[T] = []
    for e in examples:
        (train if group_of(e) in train_groups else test).append(e)
    return GroupedSplit(train=train, test=test)


@dataclass(frozen=True)
class ThreeWaySplit(Generic[T]):
    """Train / calibration / test, partitioned by group.

    The third fold is not a refinement — without it there is no honest way to
    report what calibration does. Fit the calibrator on the fold the model was
    scored on and its measured benefit is an artifact of that overlap; fit it on
    the test fold and the test fold stops being held out. So: the model learns
    on `train`, the calibrator learns on `calibration`, and both are judged on
    `test`, which neither has seen.
    """

    train: List[T]
    calibration: List[T]
    test: List[T]

    def leaks(self, group_of: Callable[[T], str]) -> bool:
        a = {group_of(e) for e in self.train}
        b = {group_of(e) for e in self.calibration}
        c = {group_of(e) for e in self.test}
        return bool((a & b) or (a & c) or (b & c))


def grouped_split_three(
    examples: Sequence[T],
    *,
    train_fraction: float,
    calibration_fraction: float,
    seed: int,
    group_of: Callable[[T], str],
) -> ThreeWaySplit[T]:
    """Partition groups into train / calibration / test. The test fraction is
    whatever remains, and must be positive."""
    if not 0.0 < train_fraction < 1.0:
        raise ValueError(
            f"train_fraction must be in (0,1) exclusive (got {train_fraction})"
        )
    if not 0.0 < calibration_fraction < 1.0:
        raise ValueError(
            "calibration_fraction must be in (0,1) exclusive "
            f"(got {calibration_fraction})"
        )
    if train_fraction + calibration_fraction >= 1.0:
        raise ValueError(
            "train_fraction + calibration_fraction must leave a test fold "
            f"(got {train_fraction} + {calibration_fraction})"
        )

    groups = sorted({group_of(e) for e in examples})
    rng = np.random.default_rng(seed)
    rng.shuffle(groups)

    n_train = int(round(len(groups) * train_fraction))
    n_calib = int(round(len(groups) * calibration_fraction))
    if n_train < 1 or n_calib < 1 or len(groups) - n_train - n_calib < 1:
        raise ValueError(
            f"{len(groups)} groups cannot be split {train_fraction}/"
            f"{calibration_fraction}/rest without leaving a fold empty"
        )

    train_groups = set(groups[:n_train])
    calib_groups = set(groups[n_train : n_train + n_calib])

    train: List[T] = []
    calibration: List[T] = []
    test: List[T] = []
    for e in examples:
        g = group_of(e)
        if g in train_groups:
            train.append(e)
        elif g in calib_groups:
            calibration.append(e)
        else:
            test.append(e)
    return ThreeWaySplit(train=train, calibration=calibration, test=test)
