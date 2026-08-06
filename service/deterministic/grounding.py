"""The grounding gate — deterministic verification of AI output.

This module is the reason a model is allowed to touch a candidate's resume at
all. Every AI stage that emits a *factual* claim about a person (a skill they
have, a project they built, a thing they said) passes its output through here
first, and anything that cannot be found in the source document is discarded.

The rule the whole system rests on: **a model may SELECT text, it may never
AUTHOR it.** A fabricated fact attributed to a candidate is the single worst
output CogniHire could produce, and no amount of downstream care recovers from
it — so the check lives here, is deterministic, and is deliberately strict.

This file must never import from `ai/`. The verifier of a model's output
cannot itself be a model.
"""

from __future__ import annotations

import re

_WHITESPACE = re.compile(r"\s+")


def normalise(text: str) -> str:
    """Collapse whitespace and case — and nothing else.

    A model re-wrapping a line or changing a bullet's spacing has not changed
    the person's words. Anything beyond that *is* a change, and is refused.
    """
    return _WHITESPACE.sub(" ", text.lower()).strip()


def is_grounded(candidate: str, document: str) -> bool:
    """True when `candidate` genuinely appears in `document`.

    No fuzzy matching, no token-overlap threshold, no "close enough". A looser
    rule here would re-open exactly the hole this gate exists to close: every
    paraphrase a model produces reads plausibly, which is what makes them
    dangerous rather than obvious.
    """
    if not candidate.strip():
        return False
    return normalise(candidate) in normalise(document)


def filter_grounded(
    candidates: list[str], document: str
) -> tuple[list[str], list[str]]:
    """Split `candidates` into (kept, rejected) by groundedness.

    Rejections are returned rather than dropped: a model inventing content is
    exactly the failure this system exists to refuse, so it must be visible
    when it happens, not silently swallowed.
    """
    kept: list[str] = []
    rejected: list[str] = []
    seen: set[str] = set()

    for item in candidates:
        cleaned = item.strip()
        if not cleaned:
            continue
        key = normalise(cleaned)
        if key in seen:
            continue
        seen.add(key)

        if is_grounded(cleaned, document):
            kept.append(cleaned)
        else:
            rejected.append(cleaned)

    return kept, rejected
