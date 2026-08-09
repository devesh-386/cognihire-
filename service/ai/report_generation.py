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
class TransparencyMetrics:
    """How much of this report is model judgement, and how much the grounding
    gate refused — surfaced so a reviewer can weigh the report knowing where it
    came from, rather than reading every line as equally authoritative.

    Every field is derived from data already decided upstream (the plan's
    provenance, the grounding gate's rejections, the per-topic verdicts). This
    is not a new judgement about the candidate — it is a disclosure about the
    process, which is exactly what this product argues an evaluation owes its
    reader. Deliberately still no score: these are counts and a source label,
    never combined into one number.
    """

    # Which mechanism planned this interview: "hosted_llm" | "local_llm" |
    # "heuristic_rule". The deterministic fallback ran if a provider was
    # unreachable — a weaker interview, and the reader should know which they
    # are looking at.
    planned_by: str
    used_ai_planner: bool
    # Populated only when the fallback ran; states plainly why.
    planning_degraded_reason: str | None

    # Grounding discipline. `topics_grounding_rejected` counts topics the
    # planner proposed that were dropped for not tracing to anything the
    # candidate actually claimed. `grounding_rate` is the fraction of proposed
    # topics that survived the gate — 1.0 means the planner invented nothing.
    topics_planned: int
    topics_grounding_rejected: int
    grounding_rate: float

    # Of the planned topics, how many the interview actually reached, and of
    # those, how many produced a verbatim evidence quote rather than a verdict
    # with nothing to point at.
    topics_examined: int
    topics_with_direct_evidence: int

    supported: int
    not_supported: int
    # Mean model confidence across examined topics, or None if none were
    # examined. A number the reader can discount by, not one that stands in
    # for a decision.
    mean_confidence: float | None

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
    # How much of this report is model judgement vs. what the gate refused.
    # Optional so an older stored report still loads; always set by build_report.
    transparency: TransparencyMetrics | None = None

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
        transparency=_transparency(plan, topics),
    )


def _transparency(plan: QuestionPlan, topics: list[TopicReport]) -> TransparencyMetrics:
    """Derive the process-disclosure metrics from the plan's provenance and the
    already-built topic reports. Pure counting — no re-judging."""
    examined = [t for t in topics if t.outcome is not None]
    confidences = [t.confidence for t in examined if t.confidence is not None]

    planned = len(plan.topics)
    rejected = len(plan.rejected_ungrounded)
    proposed = planned + rejected
    # If the planner proposed nothing (e.g. the empty-profile fallback), the
    # gate rejected nothing, so grounding is vacuously perfect rather than 0/0.
    grounding_rate = planned / proposed if proposed else 1.0

    return TransparencyMetrics(
        planned_by=plan.kind,
        used_ai_planner=plan.kind != "heuristic_rule",
        planning_degraded_reason=plan.degraded_reason,
        topics_planned=planned,
        topics_grounding_rejected=rejected,
        grounding_rate=round(grounding_rate, 3),
        topics_examined=len(examined),
        topics_with_direct_evidence=sum(1 for t in examined if t.evidence_quote),
        supported=sum(1 for t in examined if t.outcome == "supported"),
        not_supported=sum(1 for t in examined if t.outcome == "not_supported"),
        mean_confidence=(
            round(sum(confidences) / len(confidences), 3) if confidences else None
        ),
    )
