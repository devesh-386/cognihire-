"""AI stage — semantic similarity matching.

Two callers on top of `embeddings.embed`:

- `match_claims_to_requirements` — for each job requirement, which resume
  claim (if any) best supports it. This is the traditional-ML sibling to the
  LLM claim-extraction stage: embeddings + cosine similarity, not a prompt.
- `match_answer_to_concepts` — for a candidate's answer, which expected
  concepts it actually touches on, by meaning rather than shared keywords.

Both degrade to `None` scores (not zero) when embeddings are unavailable, so
a caller can tell "nothing matched" apart from "couldn't check" and fall back
to the substring-based grounding check instead of trusting a fabricated 0.0.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import embeddings

# Below this, a "best match" is noise — two unrelated sentences from the same
# embedding model rarely score below this floor, so anything under it is
# reported as no match rather than the closest of a bad lot.
_MATCH_FLOOR = 0.5


@dataclass
class RequirementMatch:
    requirement: str
    best_claim: str | None
    score: float | None
    degraded: bool = False


@dataclass
class ConceptMatch:
    concept: str
    score: float | None
    matched: bool


async def match_claims_to_requirements(
    requirements: list[str], claims: list[str], *, provider_override: str | None = None
) -> list[RequirementMatch]:
    """Best-supporting claim per requirement, or None if embeddings aren't
    available — never a fabricated ranking over un-embedded text."""
    if not requirements:
        return []
    if not claims:
        return [RequirementMatch(r, None, None) for r in requirements]

    claim_vectors = await embeddings.embed_many(claims, provider_override=provider_override)
    requirement_vectors = await embeddings.embed_many(requirements, provider_override=provider_override)

    results: list[RequirementMatch] = []
    for requirement, r_vec in zip(requirements, requirement_vectors):
        if r_vec is None:
            results.append(RequirementMatch(requirement, None, None, degraded=True))
            continue

        best_claim: str | None = None
        best_score: float | None = None
        for claim, c_vec in zip(claims, claim_vectors):
            if c_vec is None:
                continue
            score = embeddings.cosine_similarity(r_vec, c_vec)
            if score is None:
                continue
            if best_score is None or score > best_score:
                best_score, best_claim = score, claim

        if best_score is not None and best_score < _MATCH_FLOOR:
            best_claim, best_score = None, best_score
        results.append(RequirementMatch(requirement, best_claim, best_score))
    return results


async def match_answer_to_concepts(
    answer: str, concepts: list[str], *, provider_override: str | None = None
) -> list[ConceptMatch]:
    """Which expected concepts an answer actually touches on, by meaning.
    A concept the answer never mentions by name but clearly explains should
    still match — that is the entire reason this exists instead of a
    keyword check."""
    if not concepts:
        return []

    answer_vec = await embeddings.embed(answer, provider_override=provider_override)
    if answer_vec is None:
        return [ConceptMatch(c, None, False) for c in concepts]

    concept_vectors = await embeddings.embed_many(concepts, provider_override=provider_override)
    results: list[ConceptMatch] = []
    for concept, c_vec in zip(concepts, concept_vectors):
        if c_vec is None:
            results.append(ConceptMatch(concept, None, False))
            continue
        score = embeddings.cosine_similarity(answer_vec, c_vec)
        results.append(ConceptMatch(concept, score, score is not None and score >= _MATCH_FLOOR))
    return results
