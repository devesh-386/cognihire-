"""Fixture: deliberately violates ED-03/ED-04, Python side. Used ONLY by
tools/lint/test_vocab_ban.py to prove the linter catches a real violation —
never scanned as part of the real service/ tree. Mirrors the exact failure
mode this scope extension exists to catch: mean_confidence and
completion_percent folded into one new composite field.
"""

from dataclasses import dataclass


@dataclass
class CandidateDecision:
    overall_score: float
    hire_decision: bool
