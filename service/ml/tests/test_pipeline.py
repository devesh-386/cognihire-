"""The correctness proof for the Python trainer.

These mirror `test/sufficiency_pipeline_test.dart` and
`test/sufficiency_model_test.dart`. The central argument is unchanged from the
Dart side: the data has a *known* answer, so a correct trainer must recover it.
A trainer that cannot recover a planted signal cannot be trusted on an unknown
one, and a trainer that latches onto a weight-0 noise feature is provably wrong.
"""

from __future__ import annotations

import json

import pytest

from ml.calibration import fit_isotonic
from ml.metrics import evaluate
from ml.split import grouped_split, grouped_split_three
from ml.synthetic import SyntheticSufficiencyGenerator
from ml.train import fit_synthetic

GEN = SyntheticSufficiencyGenerator()

# Weight-0 features in the generative process. The trainer sees them and must
# conclude they carry nothing.
NOISE_FEATURES = ["typing.backspaceRate", "session.followUpCount"]


@pytest.fixture(scope="module")
def dataset():
    return GEN.generate(count=6000, seed=100, group_count=300)


@pytest.fixture(scope="module")
def split(dataset):
    return grouped_split(
        dataset.examples, train_fraction=0.7, seed=100, group_of=lambda e: e.group
    )


@pytest.fixture(scope="module")
def model(dataset, split):
    return fit_synthetic(dataset, train_on=split.train)


def test_no_candidate_crosses_the_split(split):
    assert not split.leaks(lambda e: e.group)
    assert split.train and split.test


def test_recovers_the_planted_weights(dataset, model):
    """Sign and rough magnitude, not exact equality — the labels are sampled, so
    the recovered weights are estimates and demanding exactness would be a test
    that fails for being right."""
    for name, truth in dataset.ground_truth_weights.items():
        got = model.weights[name]
        assert got * truth > 0, f"{name}: sign flipped (planted {truth}, got {got})"
        assert abs(got - truth) < 0.35, f"{name}: planted {truth}, got {got}"


def test_ignores_the_noise_features(model):
    for name in NOISE_FEATURES:
        assert name in model.weights, f"{name} must be trained on, not hidden"
        assert abs(model.weights[name]) < 0.15, (
            f"{name} carries no signal but got weight {model.weights[name]}"
        )


def test_recovers_the_bias(dataset, model):
    assert abs(model.bias - dataset.ground_truth_bias) < 0.25


def test_discriminates_and_is_calibrated_on_held_out_groups(split, model):
    probs = [model.predict_probability(ex.features) for ex in split.test]
    labels = [ex.sufficient for ex in split.test]
    m = evaluate(probs, labels, calibration_bins=10)

    assert m.auc is not None
    assert m.auc > 0.7
    assert m.expected_calibration_error < 0.1
    assert m.brier < 0.25  # beats the all-0.5 baseline
    assert m.log_loss == pytest.approx(m.log_loss)  # finite, not NaN


def test_pipeline_is_deterministic_end_to_end():
    def run():
        ds = GEN.generate(count=2000, seed=7, group_count=100)
        s = grouped_split(
            ds.examples, train_fraction=0.7, seed=7, group_of=lambda e: e.group
        )
        mdl = fit_synthetic(ds, train_on=s.train)
        return evaluate(
            [mdl.predict_probability(ex.features) for ex in s.test],
            [ex.sufficient for ex in s.test],
        )

    a, b = run(), run()
    assert a.auc == b.auc
    assert a.brier == b.brier
    assert a.expected_calibration_error == b.expected_calibration_error


def test_explanation_arithmetic_is_exact(dataset, model):
    """The attribution must BE the logit, not approximate it. This is what lets
    the reviewer screen show contributions as fact rather than as a guess."""
    ex = dataset.examples[0]
    a = model.explain(ex.features)
    assert a.logit == pytest.approx(
        a.bias + sum(c.contribution for c in a.contributions), abs=1e-12
    )
    assert a.probability == pytest.approx(model.predict_probability(ex.features), abs=1e-12)


def test_missing_feature_contributes_nothing(model):
    """A trained feature absent from the input means "no information" — the
    standardized midpoint — never a fabricated extreme."""
    midpoints = {
        name: (r.lo + r.hi) / 2.0 for name, r in model.ranges.items()
    }
    assert model.predict_probability({}) == pytest.approx(
        model.predict_probability(midpoints), abs=1e-12
    )


def test_untrained_feature_is_ignored(dataset, model):
    ex = dataset.examples[3]
    with_junk = {**ex.features, "not.a.real.feature": 999.0}
    assert model.predict_probability(with_junk) == pytest.approx(
        model.predict_probability(ex.features), abs=1e-12
    )


def test_refuses_to_fit_on_empty_data(dataset):
    with pytest.raises(ValueError, match="empty"):
        fit_synthetic(dataset, train_on=[])


def test_refuses_to_fit_on_a_single_class(dataset):
    positives = [e for e in dataset.examples if e.sufficient][:200]
    with pytest.raises(ValueError, match="one class"):
        fit_synthetic(dataset, train_on=positives)


def test_export_carries_the_honesty_flags(model):
    blob = json.loads(json.dumps(model.to_json()))
    assert blob["trainedOnSyntheticData"] is True
    assert blob["isValidatedOnRealData"] is False
    assert blob["schemaVersion"] == 2
    names = [f["name"] for f in blob["features"]]
    assert names == sorted(names), "feature order must be stable for clean diffs"
    for f in blob["features"]:
        assert f["hi"] > f["lo"]


def test_export_round_trips_through_the_documented_scoring_rule(dataset, model):
    """Score an example using only what the JSON contains, the way Dart will.
    If this drifts from `predict_probability`, the app and the trainer disagree
    — which is exactly the bug this artifact format exists to prevent."""
    import math

    blob = model.to_json()
    ex = dataset.examples[11]

    z = blob["bias"]
    for f in blob["features"]:
        raw = ex.features.get(f["name"])
        if raw is None:
            continue
        mid = (f["lo"] + f["hi"]) / 2.0
        half = (f["hi"] - f["lo"]) / 2.0
        z += f["weight"] * (0.0 if half == 0 else (raw - mid) / half)
    expected = 1.0 / (1.0 + math.exp(-max(-30.0, min(30.0, z))))

    assert model.predict_probability(ex.features) == pytest.approx(expected, abs=1e-12)


def test_isotonic_refuses_a_single_class_sample():
    with pytest.raises(ValueError, match="one class"):
        fit_isotonic([0.1, 0.2, 0.3], [True, True, True])


# --------------------------------------------------------------------------
# Three-fold split and the calibrator that depends on it
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def three(dataset):
    return grouped_split_three(
        dataset.examples,
        train_fraction=0.6,
        calibration_fraction=0.2,
        seed=100,
        group_of=lambda e: e.group,
    )


def test_three_way_split_keeps_every_candidate_in_exactly_one_fold(three, dataset):
    assert not three.leaks(lambda e: e.group)
    assert three.train and three.calibration and three.test
    total = len(three.train) + len(three.calibration) + len(three.test)
    assert total == len(dataset.examples), "the split dropped or duplicated rows"


def test_three_way_split_rejects_fractions_that_starve_a_fold(dataset):
    with pytest.raises(ValueError, match="leave a test fold"):
        grouped_split_three(
            dataset.examples,
            train_fraction=0.8,
            calibration_fraction=0.3,
            seed=1,
            group_of=lambda e: e.group,
        )


def test_calibration_is_measured_across_folds_not_against_itself(dataset, three):
    """The point of the third fold. Fit on calibration, judge on test — so the
    reported improvement is something a reviewer can believe."""
    model = fit_synthetic(dataset, train_on=three.train)

    calib_probs = [model.predict_probability(e.features) for e in three.calibration]
    calib_labels = [e.sufficient for e in three.calibration]
    iso = fit_isotonic(calib_probs, calib_labels)

    test_probs = [model.predict_probability(e.features) for e in three.test]
    test_labels = [e.sufficient for e in three.test]

    raw = evaluate(test_probs, test_labels)
    cal = evaluate(iso.calibrate_all(test_probs), test_labels)

    # The model is already near-calibrated (its family matches the generative
    # process), so the honest expectation is "does not meaningfully harm",
    # not "dramatically improves". Asserting improvement would be asserting a
    # result the data does not owe us.
    assert cal.expected_calibration_error < raw.expected_calibration_error + 0.02
    assert cal.brier < raw.brier + 0.02


def test_pava_matches_sklearn_at_the_block_bounds():
    """Our hand-rolled PAVA must pool the same way scikit-learn's does.

    We cannot compare the two functions everywhere — ours is a step function and
    scikit-learn's interpolates between knots — but at the block upper bounds
    both are evaluating the same pooled means, so they must agree there. This is
    what buys the right to ship our representation instead of theirs.
    """
    from sklearn.isotonic import IsotonicRegression

    gen = SyntheticSufficiencyGenerator()
    ds = gen.generate(count=800, seed=42, group_count=80)
    model = fit_synthetic(ds)
    scores = [model.predict_probability(e.features) for e in ds.examples]
    labels = [e.sufficient for e in ds.examples]

    ours = fit_isotonic(scores, labels)

    sk = IsotonicRegression(y_min=0.0, y_max=1.0, increasing=True, out_of_bounds="clip")
    sk.fit(scores, [1.0 if l else 0.0 for l in labels])

    for bound, value in zip(ours.block_max_score, ours.block_value):
        assert float(sk.predict([bound])[0]) == pytest.approx(value, abs=1e-9)


def test_calibrator_output_is_monotone_and_clamped_outside_its_support():
    gen = SyntheticSufficiencyGenerator()
    ds = gen.generate(count=600, seed=5, group_count=60)
    model = fit_synthetic(ds)
    scores = [model.predict_probability(e.features) for e in ds.examples]
    labels = [e.sufficient for e in ds.examples]
    iso = fit_isotonic(scores, labels)

    assert iso.block_value == sorted(iso.block_value)
    assert iso.block_max_score == sorted(iso.block_max_score)
    assert all(0.0 <= v <= 1.0 for v in iso.block_value)

    # Held flat beyond the calibration data's support — never extrapolated.
    assert iso.calibrate(-99.0) == iso.block_value[0]
    assert iso.calibrate(99.0) == iso.block_value[-1]


def test_calibration_section_round_trips_through_the_dart_scoring_rule(dataset, three):
    """Score the exported calibrator the way Dart's `IsotonicCalibrator` does —
    first block whose bound is >= the score — and require agreement. A linear
    interpolation here instead would disagree subtly and invisibly."""
    model = fit_synthetic(dataset, train_on=three.train)
    iso = fit_isotonic(
        [model.predict_probability(e.features) for e in three.calibration],
        [e.sufficient for e in three.calibration],
    )
    blob = model.to_json(calibrator=iso)["calibration"]
    assert blob["method"] == "isotonic"
    assert blob["representation"] == "pavaBlocks"

    bounds, values = blob["blockMaxScore"], blob["blockValue"]
    assert len(bounds) == len(values)

    for e in three.test[:200]:
        score = model.predict_probability(e.features)
        expected = values[-1]
        for b, v in zip(bounds, values):
            if score <= b:
                expected = v
                break
        assert iso.calibrate(score) == pytest.approx(expected, abs=1e-12)


def test_export_without_a_calibrator_simply_omits_the_section(model):
    assert "calibration" not in model.to_json()
    assert model.to_json()["schemaVersion"] == 2
