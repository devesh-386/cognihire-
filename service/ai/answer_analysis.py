"""AI stage — answer analysis.

Judges whether one candidate answer substantiates the claim it was asked
about. This is the stage the interview engine calls after every answer to
decide: accept and move on, or follow up.

## What is graded, and what is grounded

`supported`, `confidence`, and `followup_required` are judgements — there is
no verbatim text in the resume that says "this answer is convincing", so they
cannot be gated the way a quotation can.

`evidence_quote` is different: it is meant to be the part of the candidate's
OWN ANSWER that supports the verdict, and that IS a quotation — of the answer,
not the resume. It is gated the same way: verbatim in the answer text, or
discarded. A model is allowed to judge that an answer is convincing; it is not
allowed to invent the sentence that convinced it.
"""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass

from deterministic import grounding

from . import embeddings, provider

logger = logging.getLogger("cognihire.ai.answer_analysis")

_INSTRUCTION = """\
You judge whether a candidate's spoken answer substantiates a specific claim
they made on their resume.

Rules:
1. "supported": true only if the answer provides real, specific substance —
   not confidence of delivery. A vague or generic answer is not supported
   even if fluently stated.
2. "confidence": your certainty in that judgement, 0.0 to 1.0.
3. "followup_required": true if a deeper or clarifying question would still
   be useful — this can be true even when supported is true, if the answer
   was thin.
4. "evidence_quote": the exact sentence or phrase FROM THE ANSWER that most
   supports your verdict, copied verbatim. Null if nothing in the answer
   supports it.
5. "reason": one sentence explaining the verdict.

Reply with JSON only, in this exact shape:
{"supported": true, "confidence": 0.8, "followup_required": false, "evidence_quote": "<verbatim from the answer, or null>", "reason": "<one sentence>"}
"""


@dataclass
class AnswerAnalysis:
    supported: bool
    confidence: float
    followup_required: bool
    reason: str
    evidence_quote: str | None = None

    kind: str = "heuristic_rule"
    degraded_reason: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)


async def _fallback(answer_text: str, claim_text: str, reason: str) -> AnswerAnalysis:
    """Semantic-similarity heuristic: weaker than the model's judgement, but
    reads meaning instead of counting shared words.

    Never claims support with confidence — a degraded verdict always asks for
    a follow-up, because the alternative (silently accepting a claim on a
    heuristic this shallow) is worse than one extra question. If embeddings
    are also unavailable, this falls back further to plain keyword overlap
    rather than reporting zero relevance for an answer nobody actually
    compared to anything.
    """
    claim_vec = await embeddings.embed(claim_text)
    answer_vec = await embeddings.embed(answer_text)
    similarity = (
        embeddings.cosine_similarity(claim_vec, answer_vec)
        if claim_vec is not None and answer_vec is not None
        else None
    )

    if similarity is not None:
        # Clamp to [0, 1]: a confidence score, not a signed similarity —
        # a negative cosine (opposite meaning) is exactly as unconvincing
        # as no relation at all.
        confidence = max(0.0, min(1.0, similarity))
        check = "an unverified semantic-similarity check, not a judgement"
    else:
        claim_words = {w.lower() for w in claim_text.split() if len(w) > 3}
        answer_words = {w.lower() for w in answer_text.split() if len(w) > 3}
        confidence = 0.2 if claim_words & answer_words else 0.0
        check = "an unverified keyword check, not a judgement"

    return AnswerAnalysis(
        supported=False,
        confidence=confidence,
        followup_required=True,
        reason=f"the model was unavailable; this is {check}",
        kind="heuristic_rule",
        degraded_reason=reason,
    )


async def analyze(
    question: str,
    answer_text: str,
    claim_text: str,
    provider_override: str | None = None,
) -> AnswerAnalysis:
    """Never raises. An unavailable provider degrades to a heuristic that
    always asks for a follow-up rather than guessing at support."""
    if not answer_text.strip():
        return AnswerAnalysis(
            supported=False,
            confidence=0.0,
            followup_required=True,
            reason="no answer was given",
            kind=provider.kind_for(provider.LLM_PROVIDER),
        )

    user_message = (
        f"CLAIM BEING PROBED: {claim_text}\n\nQUESTION ASKED: {question}\n\nANSWER: {answer_text}"
    )

    reply = await provider.chat_json(
        _INSTRUCTION, user_message, timeout=30, provider=provider_override
    )
    if not reply.ok:
        return await _fallback(answer_text, claim_text, reply.error)

    parsed = provider.parse_json_object(reply.content)
    if parsed is None:
        return await _fallback(
            answer_text, claim_text, f"the {reply.provider} model returned malformed JSON"
        )

    supported = bool(parsed.get("supported"))
    confidence = parsed.get("confidence")
    confidence = float(confidence) if isinstance(confidence, (int, float)) else 0.0
    confidence = max(0.0, min(1.0, confidence))

    reason = parsed.get("reason")
    reason = reason.strip() if isinstance(reason, str) and reason.strip() else "no reason given"

    evidence_quote = parsed.get("evidence_quote")
    grounded_quote: str | None = None
    if isinstance(evidence_quote, str) and evidence_quote.strip():
        cleaned = evidence_quote.strip()
        if grounding.is_grounded(cleaned, answer_text):
            grounded_quote = cleaned
        else:
            # A model that invented the quote it used to justify "supported"
            # cannot be trusted on the verdict either — treat as unsupported
            # regardless of what it claimed.
            logger.info("answer analysis discarded an ungrounded evidence quote")
            supported = False
            confidence = min(confidence, 0.2)
            reason = f"{reason} (evidence quote could not be verified against the answer)"

    followup_required = bool(parsed.get("followup_required"))
    if not supported:
        followup_required = True

    return AnswerAnalysis(
        supported=supported,
        confidence=confidence,
        followup_required=followup_required,
        reason=reason,
        evidence_quote=grounded_quote,
        kind=provider.kind_for(reply.provider),
    )
