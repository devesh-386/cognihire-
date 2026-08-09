"""Calibrates the face-verification threshold on real labeled pairs.

`lib/core/verification/identity_matcher.dart` uses `rawThreshold = 0.50` —
explicitly documented in that file as "a reasoned starting point, NOT a
validated one," because until now this project had no genuine/impostor pairs
to calibrate against. `lib/core/verification/biometric_metrics.dart` already
implements the EER sweep needed to do that calibration; it just never had
data to run on. This script is that data.

## Data

`sklearn.datasets.fetch_lfw_pairs` — the standard LFW (Labeled Faces in the
Wild) verification benchmark: 2200 train pairs / 1000 test pairs, each
labeled same-person (genuine) or different-person (impostor), perfectly
balanced. This is the honest caveat to carry forward: LFW calibrates a
reasonable *general* threshold, not one validated on CogniHire's actual
candidate population (which we don't have consent to collect for this).

## Method

1. Detect + embed both faces in every pair with the exact model production
   uses (`buffalo_l`, detection+recognition only — see `main.py`).
2. Compute raw cosine similarity exactly as `IdentityMatcher.cosineSimilarity`
   does (plain dot / norm product, no rescaling).
3. Port `BiometricMetrics.equalErrorRate` verbatim from Dart to Python, fit
   the threshold on TRAIN pairs only.
4. Evaluate FAR/FRR/accuracy/AUC at that threshold on TEST pairs the
   threshold search never saw.
"""

from __future__ import annotations

import hashlib
import json
import warnings
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from sklearn.metrics import roc_auc_score

warnings.filterwarnings("ignore")

_CACHE_DIR = Path(__file__).parent / "cache"
_CACHE_FILE = _CACHE_DIR / "lfw_embeddings.json"

_face_app = None


def _get_app():
    global _face_app
    if _face_app is None:
        from insightface.app import FaceAnalysis

        # Same model, same allowed_modules as service/main.py — a threshold
        # calibrated against a different embedding model would not transfer.
        _face_app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection", "recognition"])
        # Smaller det_size + a low det_thresh + border padding: LFW's
        # "funneled" crops leave almost no margin around the face, which
        # RetinaFace-style detectors need context for. Verified by hand
        # against a sample image before committing to this — plain
        # det_size=640 with no padding finds zero faces on this dataset.
        _face_app.prepare(ctx_id=-1, det_size=(320, 320), det_thresh=0.2)
    return _face_app


def _embed(image_float_rgb: np.ndarray) -> list[float] | None:
    """image_float_rgb: (H, W, 3) float32 in [0, 1], as sklearn returns it."""
    bgr = cv2.cvtColor((image_float_rgb * 255).astype("uint8"), cv2.COLOR_RGB2BGR)
    padded = cv2.copyMakeBorder(bgr, 40, 40, 50, 50, cv2.BORDER_REFLECT101)

    faces = _get_app().get(padded)
    if not faces:
        return None
    # Largest detected face by bounding-box area — LFW images occasionally
    # contain a smaller secondary face; production's own /analyze-frame
    # route has the same "one face expected" assumption, so this mirrors it
    # rather than introducing a new selection rule.
    largest = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    return [float(v) for v in largest.embedding]


def cosine_similarity(a: list[float], b: list[float]) -> float | None:
    """Exact port of IdentityMatcher.cosineSimilarity — plain cosine, no
    rescaling. Keeping the two implementations bit-for-bit equivalent
    matters: this number is what gets compared to the calibrated threshold
    in Dart."""
    va, vb = np.asarray(a), np.asarray(b)
    norm_a, norm_b = float(np.linalg.norm(va)), float(np.linalg.norm(vb))
    if norm_a == 0.0 or norm_b == 0.0:
        return None
    return float(np.dot(va, vb) / (norm_a * norm_b))


def _cache_key(image: np.ndarray) -> str:
    return hashlib.sha256(image.tobytes()).hexdigest()


def _load_cache() -> dict[str, list[float]]:
    if not _CACHE_FILE.exists():
        return {}
    return json.loads(_CACHE_FILE.read_text())


def _save_cache(cache: dict[str, list[float]]) -> None:
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _CACHE_FILE.write_text(json.dumps(cache))


def _embed_cached(image: np.ndarray, cache: dict[str, list[float]]) -> list[float] | None:
    key = _cache_key(image)
    if key in cache:
        return cache[key]
    vector = _embed(image)
    if vector is not None:
        cache[key] = vector
    return vector


@dataclass(frozen=True)
class PairScores:
    genuine: list[float]
    impostor: list[float]
    dropped: int


def score_pairs(subset: str) -> PairScores:
    from sklearn.datasets import fetch_lfw_pairs

    data = fetch_lfw_pairs(subset=subset, color=True, resize=1.0, funneled=True)
    cache = _load_cache()

    genuine: list[float] = []
    impostor: list[float] = []
    dropped = 0

    for i, (pair, label) in enumerate(zip(data.pairs, data.target)):
        v1 = _embed_cached(pair[0], cache)
        v2 = _embed_cached(pair[1], cache)
        if i % 200 == 0:
            _save_cache(cache)
            print(f"[face_verification] {subset}: {i}/{len(data.pairs)}")
        if v1 is None or v2 is None:
            dropped += 1
            continue
        score = cosine_similarity(v1, v2)
        if score is None:
            dropped += 1
            continue
        (genuine if label == 1 else impostor).append(score)

    _save_cache(cache)
    return PairScores(genuine=genuine, impostor=impostor, dropped=dropped)


def false_accept_rate(impostor_scores: list[float], threshold: float) -> float:
    accepted = sum(1 for s in impostor_scores if s >= threshold)
    return accepted / len(impostor_scores)


def false_reject_rate(genuine_scores: list[float], threshold: float) -> float:
    rejected = sum(1 for s in genuine_scores if s < threshold)
    return rejected / len(genuine_scores)


def equal_error_rate(genuine_scores: list[float], impostor_scores: list[float]) -> tuple[float, float]:
    """Verbatim port of BiometricMetrics.equalErrorRate. Returns (threshold, eer)."""
    candidates = sorted(set(genuine_scores) | set(impostor_scores))
    best_threshold, best_gap, best_eer = candidates[0], float("inf"), 1.0
    for t in candidates:
        far = false_accept_rate(impostor_scores, t)
        frr = false_reject_rate(genuine_scores, t)
        gap = abs(far - frr)
        if gap < best_gap:
            best_gap, best_threshold, best_eer = gap, t, (far + frr) / 2
    return best_threshold, best_eer


def main() -> int:
    print("[face_verification] scoring train pairs (embeds cached after first run)...")
    train = score_pairs("train")
    print(f"[face_verification] train: {len(train.genuine)} genuine, "
          f"{len(train.impostor)} impostor, {train.dropped} dropped (no face detected)")

    threshold, train_eer = equal_error_rate(train.genuine, train.impostor)
    print(f"[face_verification] calibrated threshold={threshold:.4f} (train EER={train_eer:.4f})")

    print("[face_verification] scoring test pairs (embeds cached after first run)...")
    test = score_pairs("test")
    print(f"[face_verification] test: {len(test.genuine)} genuine, "
          f"{len(test.impostor)} impostor, {test.dropped} dropped (no face detected)")

    test_far = false_accept_rate(test.impostor, threshold)
    test_frr = false_reject_rate(test.genuine, threshold)
    test_eer = (test_far + test_frr) / 2
    test_accuracy = 1.0 - (
        sum(1 for s in test.genuine if s < threshold)
        + sum(1 for s in test.impostor if s >= threshold)
    ) / (len(test.genuine) + len(test.impostor))

    all_scores = test.genuine + test.impostor
    all_labels = [1] * len(test.genuine) + [0] * len(test.impostor)
    test_auc = float(roc_auc_score(all_labels, all_scores))

    # The baseline this replaces.
    old_far = false_accept_rate(test.impostor, 0.50)
    old_frr = false_reject_rate(test.genuine, 0.50)
    old_accuracy = 1.0 - (
        sum(1 for s in test.genuine if s < 0.50)
        + sum(1 for s in test.impostor if s >= 0.50)
    ) / (len(test.genuine) + len(test.impostor))

    print(f"[face_verification] TEST at calibrated threshold {threshold:.4f}: "
          f"FAR={test_far:.4f} FRR={test_frr:.4f} EER={test_eer:.4f} "
          f"accuracy={test_accuracy:.4f} AUC={test_auc:.4f}")
    print(f"[face_verification] TEST at old hardcoded 0.50: "
          f"FAR={old_far:.4f} FRR={old_frr:.4f} accuracy={old_accuracy:.4f}")

    report = {
        "datasetSource": "sklearn.datasets.fetch_lfw_pairs (LFW funneled, color)",
        "caveat": (
            "LFW is a public benchmark of celebrity/public-figure photos, not "
            "CogniHire's candidate population. This calibrates a reasonable "
            "general threshold, not one validated on real candidates."
        ),
        "trainPairs": {
            "genuine": len(train.genuine), "impostor": len(train.impostor), "dropped": train.dropped,
        },
        "testPairs": {
            "genuine": len(test.genuine), "impostor": len(test.impostor), "dropped": test.dropped,
        },
        "calibratedThreshold": threshold,
        "trainEer": train_eer,
        "testAtCalibratedThreshold": {
            "far": test_far, "frr": test_frr, "eer": test_eer,
            "accuracy": test_accuracy, "auc": test_auc,
        },
        "testAtOldHardcodedThreshold": {
            "threshold": 0.50, "far": old_far, "frr": old_frr, "accuracy": old_accuracy,
        },
    }
    out = Path(__file__).parent / "calibration_report.json"
    out.write_text(json.dumps(report, indent=2))
    print(f"[face_verification] wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
