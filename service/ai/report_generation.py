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
    # A genuine model's stated certainty in its verdict, 0-1. None when the
    # topic wasn't reached, OR when the model was unavailable and a
    # heuristic ran instead — see `heuristic_similarity` for that case. The
    # two used to share this one field, which let an unverified cosine-
    # similarity score display and average identically to a real model's
    # judgement, with nothing marking the difference.
    confidence: float | None = None
    # A cosine-similarity (or, if embeddings were also unavailable, plain
    # keyword-overlap) score standing in for `confidence` when the model
    # could not be reached — see ai/answer_analysis.py's `_fallback`.
    # Populated instead of, never alongside, `confidence`.
    heuristic_similarity: float | None = None
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
    # Mean of GENUINE model confidence across examined topics that a model
    # actually graded — None if none were. Heuristic-graded topics are
    # deliberately excluded: averaging a cosine-similarity score in with
    # real model certainty would let a degraded, unverified measurement
    # quietly pull this number around as if it were the same kind of thing.
    # A number the reader can discount by, not one that stands in for a
    # decision.
    mean_confidence: float | None
    # How many examined topics were graded by the heuristic fallback rather
    # than a model — surfaced so the reader knows `mean_confidence` doesn't
    # cover the whole interview when this is nonzero.
    topics_graded_by_heuristic: int

    # Truncation disclosure (§4.5): true when the candidate had more usable
    # claims/topics than claim_extraction/question_planning's own caps
    # allowed through. A capped interview built from a subset should say so
    # rather than reading as complete coverage of everything the candidate
    # claimed.
    claims_truncated: bool
    topics_truncated: bool

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
    # Raw counts of client-observed signals (tab/window/fullscreen/connection)
    # keyed by event_type — never a verdict. "3 tab visibility changes" is the
    # whole claim; HR decides what, if anything, that means.
    behavior_signal_counts: dict[str, int] = field(default_factory=dict)
    # Most recent face_verification event's payload, or None if the interview
    # never recorded one (e.g. camera denied, or the check hasn't run yet).
    face_verification: dict | None = None

    def to_dict(self) -> dict:
        return asdict(self)


_BEHAVIOR_EVENT_TYPES = {
    "tab_hidden", "tab_visible", "window_blur", "window_focus",
    "fullscreen_exit", "connection_lost", "connection_restored",
}


def _behavior_summary(events: list[dict]) -> tuple[dict[str, int], dict | None]:
    counts: dict[str, int] = {}
    face_verification: dict | None = None
    for event in events:
        event_type = event.get("event_type")
        if event_type in _BEHAVIOR_EVENT_TYPES:
            counts[event_type] = counts.get(event_type, 0) + 1
        elif event_type == "face_verification":
            face_verification = event.get("payload") or {}
    return counts, face_verification


def build_report(
    plan: QuestionPlan,
    coverage: CoverageState,
    links: list[EvidenceLink],
    role_title: str,
    status: str,
    events: list[dict] | None = None,
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
        is_heuristic = last.analysis_kind == "heuristic_rule"
        topics.append(TopicReport(
            topic=planned.topic,
            claim_text=claim_text,
            objective=planned.objective,
            outcome="supported" if cleared else "not_supported",
            confidence=None if is_heuristic else last.confidence,
            heuristic_similarity=last.confidence if is_heuristic else None,
            evidence_quote=last.evidence_quote,
            reason=last.reason,
            attempts=len(attempts),
        ))

    behavior_signal_counts, face_verification = _behavior_summary(events or [])

    return InterviewReport(
        role_title=role_title,
        status=status,
        completion_percent=coverage.completion_percent,
        topics=topics,
        rejected_ungrounded_topics=list(plan.rejected_ungrounded),
        transparency=_transparency(plan, topics),
        behavior_signal_counts=behavior_signal_counts,
        face_verification=face_verification,
    )


def _transparency(plan: QuestionPlan, topics: list[TopicReport]) -> TransparencyMetrics:
    """Derive the process-disclosure metrics from the plan's provenance and the
    already-built topic reports. Pure counting — no re-judging."""
    examined = [t for t in topics if t.outcome is not None]
    # Only genuine model confidence, never the heuristic stand-in — see
    # TopicReport.heuristic_similarity's own comment on why the two must
    # not be averaged together.
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
        topics_graded_by_heuristic=sum(1 for t in examined if t.heuristic_similarity is not None),
        claims_truncated=plan.claims_truncated,
        topics_truncated=plan.topics_truncated,
    )
