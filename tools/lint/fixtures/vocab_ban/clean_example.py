"""Fixture: legitimate scoped scoring vocabulary, Python side. Mirrors real
usage in service/ai/report_generation.py — mean_confidence averages ONLY
genuine model confidence (never combined with completion_percent or any
other measurement into a new field), and completion_percent is coverage,
not a judgement. Neither is a composite standing in for a hiring decision.

This file also contains prose that talks ABOUT the ban, to prove the linter
ignores docstrings/comments: "there is no overall score, no hiring score,
no hire decision" — same sentence the Dart clean fixture uses.
"""

from dataclasses import dataclass


@dataclass
class TopicReport:
    mean_confidence: float | None
    completion_percent: int
    # A per-measurement similarity score, never a composite.
    similarity_score: float
