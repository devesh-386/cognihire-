"""AI stage — text embeddings.

Turns a piece of text (a resume claim, a job requirement, a candidate answer)
into a vector, so `semantic_similarity` can compare meaning instead of exact
wording. Nothing here is trained — these are pretrained embedding models used
as a fixed feature extractor, the same way `provider.chat_json` uses a
pretrained chat model.

Vendor calls live in `provider.py` (see `test_architecture_boundary.py`'s
`test_only_provider_module_reads_vendor_credentials`) — this module only
adds the cosine-similarity math and batch helper on top of `provider.embed`.
"""

from __future__ import annotations

import math

from . import provider


async def embed(text: str, *, timeout: int = 30, provider_override: str | None = None) -> list[float] | None:
    """Embed one string. Returns None on any failure — empty text, an
    unreachable model, a missing key — never raises."""
    return await provider.embed(text, timeout=timeout, provider=provider_override)


async def embed_many(
    texts: list[str], *, timeout: int = 30, provider_override: str | None = None
) -> list[list[float] | None]:
    """Embed each string independently — a failure on one text does not
    fail the batch, since a partial match list is still useful and a
    silent all-or-nothing failure would hide which items degraded."""
    return [await embed(t, timeout=timeout, provider_override=provider_override) for t in texts]


def cosine_similarity(a: list[float], b: list[float]) -> float | None:
    """Cosine similarity in [-1, 1], or None if either vector has zero
    magnitude (undefined, not zero — a zero vector isn't "orthogonal")."""
    if len(a) != len(b) or not a:
        return None
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return None
    return dot / (norm_a * norm_b)
