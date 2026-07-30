# Sufficiency model — Python training pipeline

Fits the evidence-sufficiency model and exports the coefficients the Flutter app
scores with. Training happens here; **scoring does not**.

## Run it

From `service/`:

```bash
python -m ml.export_model --out ../assets/ml/sufficiency_model.json
```

Tests:

```bash
python -m pytest ml/tests -q
```

The exporter is gated. If the held-out fit does not clear AUC > 0.7, ECE < 0.1,
and Brier < 0.25 — the same bars `test/sufficiency_pipeline_test.dart` enforces
— it exits non-zero and writes nothing.

## Where the line is drawn, and why

| Stage | Lives in | Reason |
|---|---|---|
| Generate synthetic data, split by candidate, fit, evaluate, calibrate | Python | scikit-learn's solver beats a hand-rolled descent, and real Phase 2 validation will need real tooling |
| Score a candidate, run guards, refuse to render, explain | Dart, on-device | a component that returns verdicts is a component that can invent them |

That second row is the same argument `service/main.py` makes about the face
service, and it is why this pipeline emits **coefficients, not decisions**. The
app never calls this code at runtime — the numbers are baked into an asset
before it ships, so scoring works with the service down and with no network.

## Files

- `synthetic.py` — the generative process (planted weights, 2 deliberate noise features)
- `split.py` — grouped split; a candidate is wholly in train or wholly in test
- `train.py` — the fit, plus the JSON export format
- `metrics.py` — AUC / Brier / log-loss / ECE, with `auc = None` when undefined
- `calibration.py` — isotonic via hand-rolled PAVA, in Dart's step-function form
- `export_model.py` — CLI: train, gate, write artifact + audit report

## The calibrator is not shipped, and that is the finding

Three folds, not two: the model learns on `train`, the calibrator learns on
`calibration`, and both are judged on `test`, which neither has seen. Measured
that way, isotonic recalibration currently makes things slightly **worse**:

| test fold | raw | calibrated |
|---|---|---|
| ECE | 0.0321 | 0.0403 |
| log loss | 0.4761 | 0.5241 |
| Brier | 0.1578 | 0.1606 |

That is not a bug. A logistic model fit on a logistic generative process is
already near-calibrated, so there is little to correct and isotonic mostly adds
variance on a finite fold. The exporter therefore embeds the calibrator **only
when it measurably improves held-out ECE without worsening log loss**, and
records the decision in `calibrationDecision` in the report. Today it declines.

The earlier two-fold version of this pipeline reported an isotonic ECE of
`0.0000` and looked like a triumph. It was fitting and scoring the calibrator on
the same predictions. **If a calibration number looks perfect, check which fold
it was fitted on.**

Note also why `calibration.py` hand-rolls PAVA rather than calling
`sklearn.isotonic`: scikit-learn interpolates linearly between knots, while
Dart's `IsotonicCalibrator` is a step function over pooled blocks. Exporting
scikit-learn's knots would ship a calibrator that disagrees with the one the app
evaluates — slightly, plausibly, invisibly. The test suite cross-checks our PAVA
against scikit-learn at the block bounds, where the two must agree.

## What the artifact claims about itself

`sufficiency_model.json` carries `trainedOnSyntheticData: true` and
`isValidatedOnRealData: false`. The Dart loader reads those flags rather than
assuming them, and **rejects** a file that omits them or that claims real-data
validation while also reporting it only ever saw synthetic data.

There is deliberately no `fit_real`. When Phase 2 data exists, the honest move is
a separate reviewed entry point that sets the flag only after held-out
evaluation — never a silent flip.

## Known gaps

- The Python generator cannot see Dart's `FeatureRegistry`. A phantom feature
  would be caught on the Dart side by
  `test/sufficiency_model_export_test.dart`, not here.
- Datasets are statistically equivalent to Dart's for a given seed, not
  byte-identical — different PRNGs. Nothing depends on row equality.
- The calibration decision is made on a single fold split, not repeated CV. With
  real Phase 2 data it should be re-made with cross-validation before anyone
  concludes calibration does or does not help in general.
- `TrainedArtifact.probabilityFor` is the intended scoring path for anything
  user-facing, but the reviewer screen still calls the model directly. That is
  harmless while no calibrator ships and becomes a real divergence the day one
  does.
