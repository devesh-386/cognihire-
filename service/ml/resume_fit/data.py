"""Loads the resume<->job-description fit dataset and turns it into the one
feature the model trains on: cosine similarity between a resume embedding and
a job-description embedding.

This is real, labeled, human-annotated data — unlike the sufficiency model,
nothing here is synthetic. Source: `cnamuangtoun/resume-job-description-fit`
on Hugging Face (6241 train / 1759 test rows, 3-class label). We collapse to
binary here (`Potential Fit` and `Good Fit` -> fit=True, `No Fit` -> False)
because the product's actual use (`ai/semantic_similarity.py`) is a binary
match/no-match decision, and "Potential Fit" is a genuinely fuzzy middle
class that would only blur a 3-way classifier's boundary.

Embeddings are computed locally via Ollama (`nomic-embed-text`), not OpenAI —
no API key needed, no per-call cost, fully reproducible offline. Every
embedding is cached to disk by a hash of its (truncated) text, so re-running
this script after the first time costs nothing.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import random
from dataclasses import dataclass
from pathlib import Path
from typing import List, Sequence

from ai.provider import embed

_CACHE_DIR = Path(__file__).parent / "cache"
_CACHE_FILE = _CACHE_DIR / "embeddings.json"

# Resumes in this dataset run to several thousand characters; truncating
# keeps embedding calls fast without losing the parts of a resume/JD that
# actually carry the skill/role signal (which tends to front-load).
_MAX_CHARS = 2000

# The full dataset is affordable because its texts repeat heavily across
# rows: 8000 rows contain only ~1470 unique resumes/job descriptions, and
# the embedding cache is keyed by text hash — so "use every row" costs
# ~1470 embed calls, not 16000.
_TRAIN_PER_CLASS = None
_TEST_PER_CLASS = None

_CONCURRENCY = 16
_EMBED_PROVIDER = "ollama"


@dataclass(frozen=True)
class FitExample:
    # Truncated to _MAX_CHARS — this is what gets embedded, and what the
    # cache is keyed on. Do not widen without invalidating the cache.
    resume_text: str
    job_description_text: str
    fit: bool
    # Untruncated. Token/keyword features read these: truncation exists to
    # bound embedding cost, and there is no matching reason to throw away
    # the skills section of a long resume when merely counting terms.
    full_resume_text: str = ""
    full_job_description_text: str = ""


def _binarize(label: str) -> bool:
    return label in ("Good Fit", "Potential Fit")


def _truncate(text: str) -> str:
    return text[:_MAX_CHARS]


def _stratified_sample(rows, per_class: int | None, seed: int) -> list:
    """Class-balances by downsampling the majority class. `per_class=None`
    balances to whatever the smaller class has, keeping every row it can —
    balancing matters because 'No Fit' is ~50% of the raw data and an
    unbalanced fit would be graded against a shifted base rate."""
    rng = random.Random(seed)
    by_label: dict[bool, list] = {True: [], False: []}
    for row in rows:
        by_label[_binarize(row["label"])].append(row)

    limit = per_class if per_class is not None else min(len(b) for b in by_label.values())
    sampled = []
    for bucket in by_label.values():
        rng.shuffle(bucket)
        sampled.extend(bucket[:limit])
    rng.shuffle(sampled)
    return sampled


def load_examples() -> tuple[list[FitExample], list[FitExample]]:
    """Pulls the dataset (cached by the `datasets` library after the first
    call) and returns (train, test) as stratified, class-balanced subsamples
    using the dataset's own predefined split — no leakage between them."""
    from datasets import load_dataset

    ds = load_dataset("cnamuangtoun/resume-job-description-fit")

    train_rows = _stratified_sample(ds["train"], _TRAIN_PER_CLASS, seed=100)
    test_rows = _stratified_sample(ds["test"], _TEST_PER_CLASS, seed=101)

    def to_examples(rows) -> list[FitExample]:
        return [
            FitExample(
                resume_text=_truncate(r["resume_text"]),
                job_description_text=_truncate(r["job_description_text"]),
                fit=_binarize(r["label"]),
                full_resume_text=r["resume_text"],
                full_job_description_text=r["job_description_text"],
            )
            for r in rows
        ]

    return to_examples(train_rows), to_examples(test_rows)


def _cache_key(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _load_cache() -> dict[str, list[float]]:
    if not _CACHE_FILE.exists():
        return {}
    return json.loads(_CACHE_FILE.read_text())


def _save_cache(cache: dict[str, list[float]]) -> None:
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _CACHE_FILE.write_text(json.dumps(cache))


async def _embed_all(texts: Sequence[str]) -> list[list[float] | None]:
    cache = _load_cache()
    keys = [_cache_key(t) for t in texts]
    to_fetch = [(i, t) for i, (t, k) in enumerate(zip(texts, keys)) if k not in cache]

    if to_fetch:
        semaphore = asyncio.Semaphore(_CONCURRENCY)

        async def fetch(i: int, text: str) -> None:
            async with semaphore:
                vector = await embed(text, provider=_EMBED_PROVIDER, timeout=60)
                if vector is not None:
                    cache[keys[i]] = vector

        await asyncio.gather(*(fetch(i, t) for i, t in to_fetch))
        _save_cache(cache)

    return [cache.get(k) for k in keys]


def cosine_similarity(a: List[float], b: List[float]) -> float:
    import numpy as np

    va, vb = np.asarray(a), np.asarray(b)
    denom = float(np.linalg.norm(va) * np.linalg.norm(vb))
    if denom == 0.0:
        return 0.0
    return float(np.dot(va, vb) / denom)


async def build_features(
    examples: Sequence[FitExample],
) -> tuple[list[float], list[bool], list[FitExample]]:
    """Embeds every resume and job description (cached), returns
    (cosine_similarities, labels, surviving_examples) with any row whose
    embedding failed dropped rather than silently zero-filled.

    The surviving examples come back alongside so the caller can compute
    text-based features over exactly the rows that made it through — the
    three lists are index-aligned by construction.
    """
    resume_vectors = await _embed_all([e.resume_text for e in examples])
    job_vectors = await _embed_all([e.job_description_text for e in examples])

    similarities: list[float] = []
    labels: list[bool] = []
    survivors: list[FitExample] = []
    dropped = 0
    for ex, rv, jv in zip(examples, resume_vectors, job_vectors):
        if rv is None or jv is None:
            dropped += 1
            continue
        similarities.append(cosine_similarity(rv, jv))
        labels.append(ex.fit)
        survivors.append(ex)

    if dropped:
        print(f"[resume_fit] dropped {dropped}/{len(examples)} rows (embedding failed)")

    return similarities, labels, survivors
