"""AI stage — claim extraction.

Finds the assertions a candidate made about themselves, in their own words.
These are what the interview is *about*: every question, every follow-up, and
every line of the final report traces back to a claim on this list.

Extracted from the RAW resume text, not from the structured profile produced
by `resume_understanding`. The grounding gate checks that each claim appears
verbatim in the source, and checking against a reshaped intermediate would
weaken exactly the guarantee the gate provides.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from deterministic import grounding

from . import provider

_MAX_CANDIDATES = 8

# Models carry the resume's bullet marker across when they copy a line
# verbatim. Stripping it is presentation, not rewording — and it happens
# BEFORE the grounding check, so the check still runs against the
# candidate's own words either way.
_BULLET_PREFIX = re.compile(r"^[\-\*•·▪‣◦]\s*")

_INSTRUCTION = """\
You extract claims a person made about themselves from their own document.

Rules:
1. Copy each claim EXACTLY as it appears in the document. Do not reword, fix
   grammar, expand abbreviations, or merge lines. Verbatim only.
2. A claim is an assertion about what this person did, built, used, led, or
   achieved. Skip headings, contact details, dates alone, and school names.
3. If the document contains no such assertions, return an empty list.
4. Never write a claim that is not present in the document.

Reply with JSON only, in this exact shape:
{"claims": [{"text": "<verbatim line from the document>", "skill": "<one technology named in that line, or null>"}]}
"""


@dataclass
class Claim:
    id: str
    text: str
    source: str
    skill: str | None = None


@dataclass
class ClaimExtraction:
    claims: list[Claim]
    kind: str  # "hosted_llm" | "local_llm" | "heuristic_rule"
    degraded_reason: str | None = None
    rejected_ungrounded: list[str] = field(default_factory=list)


def _heuristic(document_text: str, source: str) -> list[Claim]:
    """Shape-and-length fallback: no model, no meaning, just line filtering."""
    claims: list[Claim] = []
    for raw_line in document_text.splitlines():
        line = _BULLET_PREFIX.sub("", raw_line).strip()
        if 15 <= len(line) <= 240:
            claims.append(Claim(id=f"c{len(claims) + 1}", text=line, source=source))
        if len(claims) >= _MAX_CANDIDATES:
            break
    return claims


def _degrade(document_text: str, source: str, reason: str) -> ClaimExtraction:
    return ClaimExtraction(
        claims=_heuristic(document_text, source),
        kind="heuristic_rule",
        degraded_reason=reason,
    )


async def extract_claims(
    document_text: str, source: str, provider_override: str | None = None
) -> ClaimExtraction:
    """Never raises. An unavailable provider degrades to text rules and says so."""
    if not document_text.strip():
        return ClaimExtraction(claims=[], kind=provider.kind_for(provider.LLM_PROVIDER))

    reply = await provider.chat_json(
        _INSTRUCTION, document_text, timeout=30, provider=provider_override
    )
    if not reply.ok:
        return _degrade(document_text, source, reply.error)

    parsed = provider.parse_json_object(reply.content)
    if parsed is None:
        return _degrade(
            document_text, source, f"the {reply.provider} model returned malformed JSON"
        )

    raw = parsed.get("claims")
    if not isinstance(raw, list):
        return _degrade(
            document_text, source, f"the {reply.provider} model did not return a claims list"
        )

    claims: list[Claim] = []
    rejected: list[str] = []
    seen: set[str] = set()

    for entry in raw:
        if len(claims) >= _MAX_CANDIDATES:
            break
        if not isinstance(entry, dict):
            continue
        text = entry.get("text")
        if not isinstance(text, str):
            continue

        trimmed = _BULLET_PREFIX.sub("", text.strip()).strip()
        if not trimmed:
            continue
        key = grounding.normalise(trimmed)
        if key in seen:
            continue
        seen.add(key)

        if not grounding.is_grounded(trimmed, document_text):
            rejected.append(trimmed)
            continue

        skill = entry.get("skill")
        claims.append(
            Claim(
                id=f"c{len(claims) + 1}",
                text=trimmed,
                source=source,
                skill=skill.strip()
                if isinstance(skill, str) and skill.strip() and skill != "null"
                else None,
            )
        )

    return ClaimExtraction(
        claims=claims,
        kind=provider.kind_for(reply.provider),
        rejected_ungrounded=rejected,
    )
