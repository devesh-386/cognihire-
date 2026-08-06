"""Coverage tracking — decides what's left to ask, not what to ask.

Deliberately NOT a model call. "Which topics are covered" and "what's the
completion percentage" are arithmetic over structured state (the plan plus
the answer analyses so far), not a judgement — a model here would be guessing
at something the interview engine already knows exactly. This is why the
module lives in `ai/` (it's part of the interview pipeline, per the directory
shape) but never touches `provider.py` and is exempt from the grounding-gate
requirement in `test_architecture_boundary.py`: it produces no new factual
claim about the candidate, only a summary of decisions already made.

The interview engine calls this after every answer to decide whether to
follow up, move to the next topic, or stop.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

from .question_planning import PlannedTopic, QuestionPlan


@dataclass
class TopicOutcome:
    """One topic's state after zero or more turns against it."""

    topic: str
    supported: bool = False
    attempted: bool = False
    best_confidence: float = 0.0
    attempts: int = 0


@dataclass
class CoverageState:
    covered: list[str] = field(default_factory=list)
    remaining: list[str] = field(default_factory=list)
    # Attempted but never reached a supported answer — worth surfacing
    # distinctly from "never asked": these are claims the candidate could not
    # substantiate, which is itself a reportable outcome.
    unsupported: list[str] = field(default_factory=list)
    completion_percent: int = 0
    recommended_next: str | None = None
    is_complete: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


# A topic counts as covered once an answer against it clears this bar. Below
# it, the candidate is treated as not yet having substantiated the claim —
# worth a follow-up rather than moving on.
_SUPPORTED_THRESHOLD = 0.6

# A topic that still isn't supported after this many attempts stops being
# retried and is written off as unsupported instead of asked again. Without
# this, a candidate (or a fully degraded, model-less run — see
# `answer_analysis._fallback`, which never claims support) can keep a topic
# in `remaining` forever, and the interview never reaches `is_complete`.
_MAX_ATTEMPTS_PER_TOPIC = 2


def evaluate(
    plan: QuestionPlan,
    outcomes_by_topic: dict[str, TopicOutcome],
) -> CoverageState:
    """Summarise where the interview stands.

    `outcomes_by_topic` is owned by the caller (the interview engine), keyed
    by `PlannedTopic.topic`, updated after each answer analysis. This function
    is pure — it draws no conclusion `outcomes_by_topic` doesn't already
    contain.
    """
    if not plan.topics:
        return CoverageState(is_complete=True, completion_percent=100)

    covered: list[str] = []
    unsupported: list[str] = []
    remaining: list[str] = []

    for topic in plan.topics:
        outcome = outcomes_by_topic.get(topic.topic)
        if outcome is None or not outcome.attempted:
            remaining.append(topic.topic)
        elif outcome.supported:
            covered.append(topic.topic)
        else:
            unsupported.append(topic.topic)
            # Retry an unsupported topic up to the cap; beyond that, write it
            # off rather than asking again — `unsupported` already records it
            # as a reportable outcome, distinct from silently dropping it.
            if outcome.attempts < _MAX_ATTEMPTS_PER_TOPIC:
                remaining.append(topic.topic)

    total = len(plan.topics)
    done = total - len(remaining)
    completion = round(100 * done / total) if total else 100

    return CoverageState(
        covered=covered,
        remaining=remaining,
        unsupported=unsupported,
        completion_percent=completion,
        recommended_next=remaining[0] if remaining else None,
        is_complete=not remaining,
    )


def next_topic(plan: QuestionPlan, state: CoverageState) -> PlannedTopic | None:
    """The `PlannedTopic` object for `state.recommended_next`, or None."""
    if state.recommended_next is None:
        return None
    for topic in plan.topics:
        if topic.topic == state.recommended_next:
            return topic
    return None
