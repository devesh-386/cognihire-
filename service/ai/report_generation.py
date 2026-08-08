"""Report generation — the final shape a reviewer reads: one row per planned
topic, Claim → Evidence → Verdict, plus what the interview never got to.

Deliberately NOT a model call, same reasoning as `coverage_manager` and
`evidence_linking`: every fact here was already decided and gated upstream.
A report that asked a model to summarize the interview would risk it
softening an unsupported verdict into something that reads better, which is
exactly the "composite score with nothing behind it" failure this whole
codebase (see `lib/features/dashboard/dashboard_screen.dart`'s doc comment)
refuses elsewhere. This module only reshapes `evidence_linking`'s output —
still no rating, no ranking, no hiring recommendation.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

from .coverage_manager import SUPPORTED_THRESHOLD, CoverageState
from .evidence_linking import EvidenceLink
from .question_planning import QuestionPlan


@dataclass
class TopicReport:
    topic: str
    claim_text: str
    objective: str
    # None if the topic was planned but the interview never reached it.
    outcome: str | None = None  # "supported" | "not_supported" | None
    confidence: float | None = None
    evidence_quote: str | None = None
    reason: str | None = None
    attempts: int = 0

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class InterviewReport:
    role_title: str
    status: str
    completion_percent: int
    topics: list[TopicReport] = field(default_factory=list)
    # Topics the planner proposed but discarded for lacking a grounded claim
    # to tie to — reported so a reviewer can see what was considered and
    # rejected, not just what made the final plan.
    rejected_ungrounded_topics: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def build_report(
    plan: QuestionPlan,
    coverage: CoverageState,
    links: list[EvidenceLink],
    role_title: str,
    status: str,
) -> InterviewReport:
    """One `TopicReport` per planned topic, using each topic's LAST attempt —
    a follow-up supersedes the question it followed, since it's a second,
    more informed judgement of the same claim, not a separate one."""
    links_by_topic: dict[str, list[EvidenceLink]] = {}
    for link in links:
        links_by_topic.setdefault(link.topic, []).append(link)

    topics: list[TopicReport] = []
    for planned in plan.topics:
        attempts = links_by_topic.get(planned.topic, [])
        claim_text = planned.grounded_in[0] if planned.grounded_in else planned.topic

        if not attempts:
            topics.append(TopicReport(
                topic=planned.topic, claim_text=claim_text, objective=planned.objective,
            ))
            continue

        last = attempts[-1]
        # Same bar `coverage_manager.evaluate` applies, imported rather than
        # re-stated: a verdict the model flagged supported but was only 0.05
        # sure of is not evidence, and a report that called it "supported"
        # while the completion percentage disagreed was the exact drift this
        # shared constant exists to prevent.
        cleared = last.supported and last.confidence >= SUPPORTED_THRESHOLD
        topics.append(TopicReport(
            topic=planned.topic,
            claim_text=claim_text,
            objective=planned.objective,
            outcome="supported" if cleared else "not_supported",
            confidence=last.confidence,
            evidence_quote=last.evidence_quote,
            reason=last.reason,
            attempts=len(attempts),
        ))

    return InterviewReport(
        role_title=role_title,
        status=status,
        completion_percent=coverage.completion_percent,
        topics=topics,
        rejected_ungrounded_topics=list(plan.rejected_ungrounded),
    )
