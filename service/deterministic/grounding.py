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

## Assertion, not just presence

Substring containment alone is not enough: "I have not worked with
Kubernetes" contains the substring "worked with Kubernetes" verbatim, so a
naive containment check grounds a claim that asserts the exact opposite of
what the source says. `locate` therefore requires two things, not one:

1. The match sits inside a single clause (sentence or bullet) — never
   spanning across a boundary, since a source clause carries its own
   subject/negation and a match that crosses into a neighboring clause has
   left that scope behind.
2. The rest of that clause — everything outside the matched span — carries
   no negation or hedge. A candidate string that only becomes true by
   ignoring the word right next to it is not grounded.
"""

from __future__ import annotations

import re

_WHITESPACE = re.compile(r"\s+")

# Sentence/bullet boundaries. Two groups, handled differently below: a run of
# `.!?` is kept as part of the clause it terminates (claims are frequently
# extracted verbatim WITH their trailing period — see claim_extraction.py's
# "copy each claim EXACTLY as it appears" instruction — so stripping it would
# make an otherwise-exact match fail to find its own source line). `;`/`\n`/
# a contrastive conjunction (", but "/" however, ") are pure separators
# between clauses and are dropped instead, the same as before.
#
# The contrastive conjunction split matters for a very ordinary resume
# construction: "I haven't worked with Kubernetes, but I have built systems
# with Docker." is one sentence carrying two opposite assertions. Treating
# the whole sentence as one negation scope would reject the genuinely-true
# Docker claim along with the correctly-rejected Kubernetes one — splitting
# on "but" keeps each half's negation scoped to itself.
_CLAUSE_BOUNDARY = re.compile(
    r"(?P<terminal>[.!?]+)"
    r"|(?P<separator>[;\n]+|,?\s+but\s+|,?\s+however\s*,?\s+|,?\s+although\s+)",
    re.IGNORECASE,
)

# Negation and hedge words/phrases. Word-boundary matched so "notable" does
# not trip on "not". Covers standard negation (not, n't-contractions spelled
# out, never, without, no/none/neither/nor, unable, lack*, cannot, fail(ed)
# to) and epistemic hedges that undercut an assertion without negating it
# outright (unsure, unclear, allegedly, reportedly, supposedly, possibly,
# maybe, might, "may not") — a report claiming a skill on the strength of a
# hedge is still asserting more than the source actually supports.
_NEGATION_HEDGE = re.compile(
    r"\b("
    r"not|never|without|none|neither|nor|unable|"
    r"lacks?|lacking|lacked|cannot|can't|won't|isn't|aren't|wasn't|weren't|"
    r"doesn't|don't|didn't|hasn't|haven't|hadn't|wouldn't|couldn't|shouldn't|"
    r"fail(?:s|ed)?\s+to|"
    r"unsure|unclear|allegedly|reportedly|supposedly|possibly|maybe|might|"
    r"may\s+not"
    r")\b",
    re.IGNORECASE,
)


def normalise(text: str) -> str:
    """Collapse whitespace and case — and nothing else.

    A model re-wrapping a line or changing a bullet's spacing has not changed
    the person's words. Anything beyond that *is* a change, and is refused.
    """
    return _WHITESPACE.sub(" ", text.lower()).strip()


def _clauses(document: str) -> list[tuple[int, int, str]]:
    """Split `document` into (start, end, text) clauses at sentence/bullet
    boundaries, as absolute offsets into `document`. Empty spans (two
    boundaries in a row, e.g. a blank line) are dropped."""
    spans: list[tuple[int, int]] = []
    start = 0
    for m in _CLAUSE_BOUNDARY.finditer(document):
        end = m.end() if m.lastgroup == "terminal" else m.start()
        spans.append((start, end))
        start = m.end()
    spans.append((start, len(document)))
    return [(s, e, document[s:e]) for s, e in spans if e > s]


def _flexible_pattern(candidate: str) -> re.Pattern[str] | None:
    """A case-insensitive pattern matching `candidate` with any run of
    whitespace treated as equivalent to any other — the same tolerance
    `normalise` gives whitespace, but as a regex so a match's offsets can be
    read directly out of the original (un-normalised) document instead of
    mapped back through a length-changing transform."""
    tokens = candidate.strip().split()
    if not tokens:
        return None
    return re.compile(r"\s+".join(re.escape(tok) for tok in tokens), re.IGNORECASE)


def locate(candidate: str, document: str) -> tuple[int, int] | None:
    """Find `candidate` genuinely asserted in `document`.

    Returns the absolute `(start, end)` character offsets of the match in
    `document` when grounded, or `None` when it is not — either because the
    text does not appear at all, or because it only appears inside a clause
    that negates or hedges it.
    """
    pattern = _flexible_pattern(candidate)
    if pattern is None:
        return None
    for clause_start, _clause_end, clause_text in _clauses(document):
        match = pattern.search(clause_text)
        if match is None:
            continue
        outside = clause_text[: match.start()] + clause_text[match.end() :]
        if _NEGATION_HEDGE.search(outside):
            continue
        return (clause_start + match.start(), clause_start + match.end())
    return None


def is_grounded(candidate: str, document: str) -> bool:
    """True when `candidate` genuinely appears — asserted, not negated or
    hedged away — in `document`.

    No fuzzy matching, no token-overlap threshold, no "close enough". A looser
    rule here would re-open exactly the hole this gate exists to close: every
    paraphrase a model produces reads plausibly, which is what makes them
    dangerous rather than obvious.
    """
    if not candidate.strip():
        return False
    return locate(candidate, document) is not None


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
