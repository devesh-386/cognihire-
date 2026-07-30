"""Train the sufficiency model and write the artifact the Flutter app loads.

    python -m ml.export_model --out ../assets/ml/sufficiency_model.json

Run from `service/`. Writes two files: the model artifact, and a sibling
`<name>.report.json` holding the held-out metrics the model was accepted on.
The report is not read by the app — it exists so that "this model scored an AUC
of X on groups it never saw" is a checked-in claim a reviewer can audit, rather
than a number that scrolled past in a terminal once.

The gate below is the point of the script. If the fit does not clear the same
bars the Dart pipeline test enforces, this exits non-zero and writes nothing. A
training script that emits a bad model quietly is how a bad model reaches a
demo.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .calibration import fit_isotonic
from .metrics import evaluate
from .split import grouped_split_three
from .synthetic import SyntheticSufficiencyGenerator
from .train import fit_synthetic

# The acceptance bars, mirroring `test/sufficiency_pipeline_test.dart`. The AUC
# bar is well below 1.0 on purpose: the generative process is noisy, so the
# Bayes-optimal AUC is itself modest, and a model claiming to beat it would be
# evidence of leakage, not of skill.
MIN_AUC = 0.7
MAX_ECE = 0.1
MAX_BRIER = 0.25  # the all-0.5 baseline

# How much held-out ECE the calibrator must actually buy to be worth embedding.
# Not zero: a hair's-breadth improvement on one fold is noise, and shipping an
# extra moving part on the strength of noise is how complexity accumulates
# without justification.
MIN_CALIBRATION_GAIN = 0.005


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True, help="model artifact path")
    ap.add_argument("--count", type=int, default=6000)
    ap.add_argument("--groups", type=int, default=300)
    ap.add_argument("--seed", type=int, default=100)
    ap.add_argument("--train-fraction", type=float, default=0.6)
    ap.add_argument("--calibration-fraction", type=float, default=0.2)
    ap.add_argument("--l2", type=float, default=0.001)
    args = ap.parse_args(argv)

    gen = SyntheticSufficiencyGenerator()
    ds = gen.generate(count=args.count, seed=args.seed, group_count=args.groups)

    # Three folds, not two. The model learns on train, the calibrator learns on
    # calibration, and both are judged on test — which neither has seen. Without
    # the third fold there is no honest way to say what calibration bought.
    split = grouped_split_three(
        ds.examples,
        train_fraction=args.train_fraction,
        calibration_fraction=args.calibration_fraction,
        seed=args.seed,
        group_of=lambda e: e.group,
    )
    if split.leaks(lambda e: e.group):
        print("FAIL: split leaked a candidate across folds", file=sys.stderr)
        return 2

    model = fit_synthetic(ds, train_on=split.train, l2=args.l2)

    probs = [model.predict_probability(ex.features) for ex in split.test]
    labels = [ex.sufficient for ex in split.test]
    metrics = evaluate(probs, labels, calibration_bins=10)

    # Fitted on the calibration fold, applied to the test fold. Both genuinely
    # held out from each other, so the comparison below means something.
    iso = fit_isotonic(
        [model.predict_probability(ex.features) for ex in split.calibration],
        [ex.sufficient for ex in split.calibration],
    )
    calibrated = evaluate(iso.calibrate_all(probs), labels, calibration_bins=10)

    # ------------------------------------------------------------------
    # Ship the calibrator only if it earns its place.
    #
    # It is tempting to treat "we calibrate our probabilities" as automatically
    # good — it sounds rigorous and it is a nice line in a pitch. But this model
    # is a logistic fit on a logistic generative process, so it is already close
    # to calibrated, and isotonic recalibration on a finite fold mostly adds
    # variance. Measured across folds it is currently a small net loss.
    #
    # So the decision is made by the numbers, not by the aesthetics: embed the
    # calibrator only if it actually improves held-out ECE without making the
    # log loss worse. Shipping a correction that measurably degrades the output
    # would be exactly the sort of unexamined "best practice" this project is
    # supposed to refuse.
    # ------------------------------------------------------------------
    ece_gain = metrics.expected_calibration_error - calibrated.expected_calibration_error
    worsens_log_loss = calibrated.log_loss > metrics.log_loss
    ship_calibrator = ece_gain > MIN_CALIBRATION_GAIN and not worsens_log_loss

    if ship_calibrator:
        shipped, shipped_label = calibrated, "calibrated"
    else:
        shipped, shipped_label = metrics, "uncalibrated"

    # The gate judges what actually ships. AUC is checked on the raw scores
    # because isotonic calibration is monotone and cannot change the ranking;
    # checking it post-calibration would just be measuring the same thing with
    # ties added.
    failures: list[str] = []
    if metrics.auc is None:
        failures.append("AUC undefined (test fold has a single class)")
    elif metrics.auc < MIN_AUC:
        failures.append(f"AUC {metrics.auc:.4f} < {MIN_AUC}")
    if shipped.expected_calibration_error > MAX_ECE:
        failures.append(
            f"{shipped_label} ECE {shipped.expected_calibration_error:.4f} > {MAX_ECE}"
        )
    if shipped.brier > MAX_BRIER:
        failures.append(f"{shipped_label} Brier {shipped.brier:.4f} > {MAX_BRIER}")

    _print_summary(model, metrics, calibrated, ship_calibrator, ece_gain)

    if failures:
        print("\nFAIL — model not written:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(model.to_json(calibrator=iso if ship_calibrator else None), indent=2)
        + "\n",
        encoding="utf-8",
    )

    report_path = args.out.with_suffix(".report.json")
    report_path.write_text(
        json.dumps(
            {
                "generatedFrom": "synthetic data only — no real candidate was involved",
                "dataset": {
                    "count": args.count,
                    "groups": args.groups,
                    "seed": args.seed,
                    "trainFraction": args.train_fraction,
                    "calibrationFraction": args.calibration_fraction,
                    "trainRows": len(split.train),
                    "calibrationRows": len(split.calibration),
                    "testRows": len(split.test),
                },
                # Both measured on the test fold. The calibrator was fitted on
                # the calibration fold, so the delta between these two is a real
                # held-out result, not an artifact of scoring a fit on itself.
                "heldOutUncalibrated": metrics.to_json(),
                "heldOutCalibrated": calibrated.to_json(),
                "calibrationDecision": {
                    "shipped": ship_calibrator,
                    "eceGain": ece_gain,
                    "minGainRequired": MIN_CALIBRATION_GAIN,
                    "worsensLogLoss": worsens_log_loss,
                    "note": (
                        "The calibrator is embedded only when it measurably "
                        "improves held-out ECE without worsening log loss. A "
                        "logistic model fit on a logistic process is already "
                        "near-calibrated, so 'we calibrate' is not automatically "
                        "an improvement — here it is measured, not assumed."
                    ),
                },
                "groundTruthWeights": ds.ground_truth_weights,
                "recoveredWeights": model.weights,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"\nwrote {args.out}")
    print(f"wrote {report_path}")
    return 0


def _print_summary(model, metrics, calibrated, ship_calibrator, ece_gain) -> None:
    auc = "n/a" if metrics.auc is None else f"{metrics.auc:.4f}"
    # ASCII only: this runs in a Windows console that mangles non-cp1252 output.
    print("test fold - candidates seen by neither the model nor the calibrator")
    print(f"  rows       {metrics.count}  ({metrics.positive_count} positive)")
    print(f"  AUC        {auc}")
    print(f"{'':13}{'raw':>10}{'calibrated':>14}")
    print(f"  Brier      {metrics.brier:>10.4f}{calibrated.brier:>14.4f}")
    print(f"  log loss   {metrics.log_loss:>10.4f}{calibrated.log_loss:>14.4f}")
    print(f"  accuracy   {metrics.accuracy:>10.4f}{calibrated.accuracy:>14.4f}")
    print(
        f"  ECE        {metrics.expected_calibration_error:>10.4f}"
        f"{calibrated.expected_calibration_error:>14.4f}"
    )
    if ship_calibrator:
        print(f"\ncalibrator EMBEDDED - buys {ece_gain:+.4f} held-out ECE")
    else:
        print(
            f"\ncalibrator OMITTED - would change held-out ECE by {ece_gain:+.4f}, "
            f"below the {MIN_CALIBRATION_GAIN} bar or worsens log loss."
        )
        print("  The app scores with the uncalibrated probability. This is a")
        print("  measured decision, recorded in the report - not an oversight.")
    print("\nrecovered weights (standardized space)")
    for name in sorted(model.weights, key=lambda n: -abs(model.weights[n])):
        print(f"  {model.weights[name]:+.4f}  {name}")
    print(f"  {model.bias:+.4f}  (bias)")


if __name__ == "__main__":
    raise SystemExit(main())
