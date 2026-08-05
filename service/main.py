"""CogniHire face service.

Deliberately narrow: it extracts a face embedding from one frame and reports
image quality. It does NOT decide whether two faces match.

That separation is the point. The reference implementation this project learns
from did the comparison server-side, applied a threshold of 85 on a scale where
two *different* people score ~50, and returned a fabricated pass when no
enrolled profile existed. Keeping the decision in the client — where the
threshold is documented, tested, and calibratable — means this service has no
opportunity to invent a verdict.

Run:
    uvicorn main:app --port 8000
"""

from __future__ import annotations

import logging
import os
from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

logger = logging.getLogger("cognihire.face")

app = FastAPI(title="CogniHire Face Service", version="0.1.0")

# "*" only for local dev. Once this runs on a public VM (Ticket 9), set
# ALLOWED_ORIGINS to the HR app's and candidate web app's actual origins.
_allowed_origins = os.environ.get("ALLOWED_ORIGINS", "*")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _allowed_origins == "*" else _allowed_origins.split(","),
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Engine loading
#
# If InsightFace is unavailable the service still starts, but every analysis
# reports embedding_available=false. It never falls back to a cheaper heuristic
# and never reports a result it did not compute — a proctoring system that
# guesses is worse than one that admits it cannot see.
# ---------------------------------------------------------------------------
_face_app = None
ENGINE_ERROR: Optional[str] = None

try:
    from insightface.app import FaceAnalysis

    # Load ONLY detection + recognition.
    #
    # The buffalo_l pack also ships genderage.onnx (a gender and age
    # classifier) and two landmark models. Loading the full pack would run a
    # demographic classifier over every candidate's face for no functional
    # reason — output we never read, on an attribute we have deliberately
    # chosen not to infer. Keeping it out of the process is the difference
    # between a claim we can defend and one that is contradicted by our own
    # dependency list. It also avoids ~143MB of pointless model loading.
    _face_app = FaceAnalysis(
        name="buffalo_l",
        allowed_modules=["detection", "recognition"],
    )
    _face_app.prepare(ctx_id=-1, det_size=(640, 640))
except Exception as exc:  # noqa: BLE001 - report any load failure verbatim
    ENGINE_ERROR = str(exc)
    logger.error("InsightFace unavailable: %s", exc)


class FrameAnalysis(BaseModel):
    engine_available: bool
    engine_error: Optional[str] = None

    face_detected: bool
    embedding_available: bool
    # 512-d ArcFace embedding. Present only when embedding_available is true.
    embedding: Optional[list[float]] = None

    face_size: int = 0
    brightness: float = 0.0
    sharpness: float = 0.0
    recommendations: list[str] = []


def _quality(gray: np.ndarray) -> tuple[float, float]:
    brightness = float(np.mean(gray)) / 255.0 * 100.0
    sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    return brightness, sharpness


def _recommendations(brightness: float, sharpness: float, face_size: int) -> list[str]:
    recs: list[str] = []
    if brightness < 25:
        recs.append("Increase lighting")
    elif brightness > 90:
        recs.append("Reduce glare or backlight")
    if sharpness < 60:
        recs.append("Hold still or clean the lens")
    if face_size == 0:
        recs.append("Ensure your face is visible to the camera")
    elif face_size < 15000:
        recs.append("Move closer to the camera")
    return recs


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "engine_available": _face_app is not None,
        "engine_error": ENGINE_ERROR,
    }


@app.post("/face/analyze", response_model=FrameAnalysis)
async def analyze_frame(file: UploadFile = File(...)) -> FrameAnalysis:
    raw = await file.read()

    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return FrameAnalysis(
            engine_available=_face_app is not None,
            engine_error=ENGINE_ERROR,
            face_detected=False,
            embedding_available=False,
            recommendations=["Frame could not be decoded"],
        )

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    brightness, sharpness = _quality(gray)

    if _face_app is None:
        # Honest dead-end: quality metrics only, no invented identity signal.
        return FrameAnalysis(
            engine_available=False,
            engine_error=ENGINE_ERROR,
            face_detected=False,
            embedding_available=False,
            brightness=brightness,
            sharpness=sharpness,
            recommendations=["Face recognition engine unavailable"],
        )

    faces = _face_app.get(img)
    if not faces:
        return FrameAnalysis(
            engine_available=True,
            face_detected=False,
            embedding_available=False,
            brightness=brightness,
            sharpness=sharpness,
            recommendations=_recommendations(brightness, sharpness, 0),
        )

    # Largest face wins: the candidate is the subject nearest the camera.
    face = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    x1, y1, x2, y2 = face.bbox
    face_size = int((x2 - x1) * (y2 - y1))

    return FrameAnalysis(
        engine_available=True,
        face_detected=True,
        embedding_available=True,
        embedding=[float(v) for v in face.embedding],
        face_size=face_size,
        brightness=brightness,
        sharpness=sharpness,
        recommendations=_recommendations(brightness, sharpness, face_size),
    )
