"""Tests for deterministic/grounding.py — the gate that decides whether a
model's claim about a candidate actually appears in the source document.

The regression these exist to pin down: substring containment alone grounds
a claim against a source clause that asserts the exact opposite ("I have not
worked with Kubernetes" contains "worked with Kubernetes" verbatim).
"""

from __future__ import annotations

from deterministic import grounding


# --- the bug this closes ------------------------------------------------------


def test_negated_claim_is_not_grounded():
    resume = "Skills: Python, Django. I have not worked with Kubernetes in production."
    assert not grounding.is_grounded("worked with Kubernetes", resume)


def test_negated_claim_via_contraction_is_not_grounded():
    resume = "I haven't worked with Kubernetes."
    assert not grounding.is_grounded("worked with Kubernetes", resume)


def test_hedged_claim_is_not_grounded():
    resume = "I might have touched Kubernetes briefly during onboarding."
    assert not grounding.is_grounded("touched Kubernetes", resume)


def test_negation_in_a_different_clause_does_not_leak_across():
    """The negation gate is scoped to the clause the match sits in — a
    negation elsewhere in the document must not poison an unrelated,
    genuinely-asserted claim in a different sentence."""
    resume = "I have not worked with Kubernetes. I have worked with Docker extensively."
    assert grounding.is_grounded("worked with Docker extensively", resume)


def test_a_negated_and_a_true_claim_in_one_sentence_are_judged_separately():
    """A very ordinary resume construction: one sentence carrying both a
    denial and a genuine assertion, joined by "but". The negation must not
    leak across the conjunction and reject the true half along with the
    correctly-rejected one."""
    resume = "I haven't worked with Kubernetes, but I have built systems with Docker."
    assert not grounding.is_grounded("worked with Kubernetes", resume)
    assert grounding.is_grounded("built systems with Docker", resume)


def test_negation_after_the_match_still_blocks_it():
    resume = "Worked with Kubernetes, though never in a production environment."
    assert not grounding.is_grounded("Worked with Kubernetes", resume)


# --- ordinary grounding still works -------------------------------------------


def test_plain_assertion_is_grounded():
    resume = "Led a team of 4 engineers to ship a React dashboard."
    assert grounding.is_grounded("Led a team of 4 engineers", resume)


def test_claim_with_trailing_period_matches_its_source_line():
    """Claims are extracted verbatim, trailing period included — the clause
    splitter must keep sentence-terminal punctuation attached to its clause
    rather than stripping it, or an exact verbatim copy stops matching its
    own source line."""
    resume = "- Led a team of 4 engineers.\n- Shipped a React dashboard."
    assert grounding.is_grounded("Led a team of 4 engineers.", resume)


def test_case_and_whitespace_are_ignored():
    resume = "LED   a Team of  4 Engineers."
    assert grounding.is_grounded("led a team of 4 engineers", resume)


def test_fabricated_text_is_not_grounded():
    resume = "Built a dashboard in React."
    assert not grounding.is_grounded("Built a dashboard in Angular", resume)


def test_empty_candidate_is_never_grounded():
    assert not grounding.is_grounded("", "anything at all")
    assert not grounding.is_grounded("   ", "anything at all")


# --- locate() offsets ----------------------------------------------------------


def test_locate_returns_offsets_into_the_original_document():
    resume = "Summary.\nLed a team of 4 engineers."
    start, end = grounding.locate("Led a team of 4 engineers", resume)
    assert resume[start:end] == "Led a team of 4 engineers"


def test_locate_returns_none_when_not_grounded():
    assert grounding.locate("never mentioned at all", "some other text") is None


# --- filter_grounded -----------------------------------------------------------


def test_filter_grounded_splits_kept_and_rejected_respecting_negation():
    resume = "I have worked with Docker. I have not worked with Kubernetes."
    kept, rejected = grounding.filter_grounded(
        ["worked with Docker", "worked with Kubernetes", "invented a time machine"],
        resume,
    )
    assert kept == ["worked with Docker"]
    assert rejected == ["worked with Kubernetes", "invented a time machine"]
