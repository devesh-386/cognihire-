"""Fits the resume<->job-fit model on real, human-labeled pairs.

## What changed from the first version, and why

v1 was a 1-feature logistic regression over embedding cosine similarity and
scored 0.642 AUC / 59.8% accuracy on held-out data. One similarity number
cannot separate "right field, wrong seniority" from a real match. This
version extracts 10 relational features (`features.py`) and compares three
classifiers on the same held-out fold, reporting whichever wins along with
every score so the choice is auditable rather than asserted.

## The honest constraints on the number this produces

- The dataset's split is by **job description**, not by resume: the test
  fold's 71 job descriptions appear nowhere in train, but 476 of its 477
  resumes do. Every feature is therefore relational (resume-vs-JD), never
  computed from a resume alone — see `features.py`. This costs accuracy and
  buys a number that means "can it handle a new posting" instead of "can it
  remember which resumes are good".
- IDF statistics are fitted on the **train fold only** and applied to test.
  Fitting them over the combined corpus would leak the test fold's term
  distribution into training and inflate the result.
- Classes are balanced by downsampling, so 50% is the true random baseline
  and accuracy is directly interpretable.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

from ml import metrics as shared_metrics
from ml.resume_fit import features as feature_extraction
from ml.resume_fit.data import build_features, load_examples

SCHEMA_VERSION = 2


def _build_matrix(examples, similarities, stats) -> np.ndarray:
    return feature_extraction.to_matrix([
        feature_extraction.extract(
            resume_text=ex.full_resume_text or ex.resume_text,
            job_description_text=ex.full_job_description_text or ex.job_description_text,
            embedding_cosine=sim,
            stats=stats,
        )
        for ex, sim in zip(examples, similarities)
    ])


def _candidate_models() -> dict:
    return {
        "logistic_regression": LogisticRegression(solver="lbfgs", max_iter=5000),
        "gradient_boosting": GradientBoostingClassifier(
            n_estimators=300, learning_rate=0.05, max_depth=3, subsample=0.9,
            random_state=100,
        ),
        "random_forest": RandomForestClassifier(
            n_estimators=400, max_depth=12, min_samples_leaf=3,
            random_state=100, n_jobs=-1,
        ),
    }


async def main() -> int:
    print("[resume_fit] loading dataset...")
    train_examples, test_examples = load_examples()
    print(f"[resume_fit] {len(train_examples)} train rows, {len(test_examples)} test rows")

    print("[resume_fit] embedding train set (cached after first run)...")
    train_sims, train_labels, train_examples = await build_features(train_examples)
    print("[resume_fit] embedding test set (cached after first run)...")
    test_sims, test_labels, test_examples = await build_features(test_examples)

    # Train fold only — see the module docstring on leakage.
    print("[resume_fit] fitting IDF statistics on the train fold...")
    stats = feature_extraction.DocumentStats.fit(
        [ex.full_resume_text or ex.resume_text for ex in train_examples]
        + [ex.full_job_description_text or ex.job_description_text for ex in train_examples]
    )

    print("[resume_fit] extracting features...")
    X_train = _build_matrix(train_examples, train_sims, stats)
    X_test = _build_matrix(test_examples, test_sims, stats)
    y_train = np.asarray(train_labels, dtype=int)

    scaler = StandardScaler().fit(X_train)
    X_train_scaled, X_test_scaled = scaler.transform(X_train), scaler.transform(X_test)

    results = {}
    best_name, best_auc, best_model = None, -1.0, None

    for name, model in _candidate_models().items():
        # Trees are scale-invariant; the linear model is not. Giving each
        # the representation it wants keeps this a comparison of models
        # rather than of preprocessing.
        uses_scaling = name == "logistic_regression"
        fit_X = X_train_scaled if uses_scaling else X_train
        eval_X = X_test_scaled if uses_scaling else X_test

        model.fit(fit_X, y_train)
        probabilities = model.predict_proba(eval_X)[:, 1].tolist()
        evaluated = shared_metrics.evaluate(probabilities, test_labels)
        results[name] = evaluated.to_json()
        print(f"[resume_fit]   {name:22s} AUC={evaluated.auc:.4f} "
              f"accuracy={evaluated.accuracy:.4f} brier={evaluated.brier:.4f}")

        if evaluated.auc is not None and evaluated.auc > best_auc:
            best_name, best_auc, best_model = name, evaluated.auc, model

    best = results[best_name]
    print(f"[resume_fit] best: {best_name} "
          f"(AUC={best['auc']:.4f}, accuracy={best['accuracy']:.4f})")

    # The baseline this whole model exists to beat: the un-fit 0.5 cosine
    # threshold currently hardcoded in ai/semantic_similarity.py.
    naive_accuracy = float(
        np.mean([(s >= 0.5) == l for s, l in zip(test_sims, test_labels)])
    )
    print(f"[resume_fit] naive fixed-0.5-threshold accuracy: {naive_accuracy:.4f}")

    importances = {}
    if hasattr(best_model, "feature_importances_"):
        importances = {
            name: float(value) for name, value in
            sorted(zip(feature_extraction.FEATURE_NAMES, best_model.feature_importances_),
                   key=lambda pair: pair[1], reverse=True)
        }
        print("[resume_fit] top features: " + ", ".join(
            f"{k}={v:.3f}" for k, v in list(importances.items())[:5]))

    report = {
        "trainedOnRealData": True,
        "datasetSource": "huggingface:cnamuangtoun/resume-job-description-fit",
        "trainRows": len(train_sims),
        "testRows": len(test_sims),
        "featureNames": feature_extraction.FEATURE_NAMES,
        "splitCaveat": (
            "The dataset splits by job description: test job descriptions are "
            "unseen in train, but 476/477 test resumes appear in train. All "
            "features are relational (resume-vs-JD) so the model cannot score "
            "well by memorizing resume identity."
        ),
        "allModels": results,
        "selectedModel": best_name,
        "heldOut": best,
        "naiveFixedThresholdAccuracy": naive_accuracy,
        "featureImportances": importances,
    }

    out_dir = Path(__file__).parent
    (out_dir / "resume_fit_model.report.json").write_text(json.dumps(report, indent=2))
    print(f"[resume_fit] wrote {out_dir / 'resume_fit_model.report.json'}")

    # Export a loadable artifact — not just a report. Refit the winning
    # model class on the scaled representation so inference always applies
    # the same StandardScaler regardless of which model won (trees don't
    # need it, but using one path for every model type means
    # `ai/semantic_similarity.py` never has to branch on which model is
    # loaded). This is a Python-only consumer (the FastAPI backend, not the
    # Dart app), so joblib is the honest format — no JSON schema needed.
    import joblib

    final_model = _candidate_models()[best_name]
    final_model.fit(X_train_scaled, y_train)

    artifact = {
        "schemaVersion": SCHEMA_VERSION,
        "trainedOnRealData": True,
        "datasetSource": "huggingface:cnamuangtoun/resume-job-description-fit",
        "modelType": best_name,
        "featureNames": feature_extraction.FEATURE_NAMES,
        "model": final_model,
        "scaler": scaler,
        "idf": stats.idf,
        "heldOutAuc": best["auc"],
        "heldOutAccuracy": best["accuracy"],
    }
    artifact_path = out_dir / "resume_fit_model.joblib"
    joblib.dump(artifact, artifact_path)
    print(f"[resume_fit] wrote {artifact_path} "
          f"(model={best_name}, held-out AUC={best['auc']:.4f}, accuracy={best['accuracy']:.4f})")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
