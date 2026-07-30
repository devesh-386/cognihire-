"""CogniHire sufficiency-model training pipeline.

## Why training lives in Python and scoring does not

The Dart implementation under `lib/core/ml/` proved the mechanism: it fits a
real logistic regression, splits by candidate, calibrates, and evaluates. This
package takes over the *training* half of that work — fit, grouped split,
metrics, isotonic calibration — because that is where Python's ecosystem
genuinely wins, and because validating on a real Phase 2 dataset will need
tooling (scikit-learn, proper cross-validation, plots) that Dart does not have.

What this package deliberately does NOT do is decide anything. It emits a JSON
artifact of learned coefficients; the app loads it and scores locally. That
boundary is the same one `main.py` draws for the face service, and for the same
reason: a service that returns verdicts is a service that can invent them. Here
the service does not even run at scoring time — the numbers are baked into an
asset before the app ships.

Entry point:

    python -m ml.export_model --out ../assets/ml/sufficiency_model.json
"""

from .synthetic import SyntheticSufficiencyGenerator, SufficiencyExample
from .split import grouped_split
from .metrics import BinaryMetrics, evaluate
from .train import fit_synthetic, TrainedSufficiencyModel

__all__ = [
    "SyntheticSufficiencyGenerator",
    "SufficiencyExample",
    "grouped_split",
    "BinaryMetrics",
    "evaluate",
    "fit_synthetic",
    "TrainedSufficiencyModel",
]
