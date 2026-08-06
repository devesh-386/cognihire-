"""Evidence linking — turns the interview's event log into the structure the
report reads: one link per attempt, Claim → Question → Answer → Evidence →
Verdict, instead of a transcript a reader has to reconstruct by eye.

Deliberately NOT a model call, for the same reason as `coverage_manager`: by
the time an interview has run, every fact this module needs — which claim
was probed, what was asked, what was answered, whether it held up — was
already decided and gated by an earlier stage (`question_planning`,
`interview`, `answer_analysis`). This module asserts nothing new about the
candidate; it re-shapes decisions already made. That's also why it lives in
`ai/` per the pipeline shape in `ai/__init__.py`, but is exempt from both the
grounding-gate and downstream-profile-only guards in
`test_architecture_boundary.py`, exactly like `coverage_manager`.

## Why this reads generic event dicts, not `session` module types

`session/` orchestrates `ai/`, so `ai/` importing from `session/` would be a
cycle. Every event this module needs was already serialized into
`interview_events.payload` by `session/interview_session.py`, so evidence
linking takes that plain dict list directly — `session/interview_session.py`
is free to call this module and hand back the result without either package
depending on the other's internal types.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

from .question_planning import QuestionPlan


@dataclass
class EvidenceLink:
    topic: str
    claim_text: str
    question: str
    answer_text: str
    supported: bool
    confidence: float
    reason: str
    evidence_quote: str | None = None
    # "question" | "followup" — a follow-up link is a second attempt at the
    # same topic, kept distinct rather than overwriting the first so a
    # reviewer can see the candidate was given a second chance.
    turn_kind: str = "question"

    def to_dict(self) -> dict:
        return asdict(self)


def build_links(plan: QuestionPlan, events: list[dict]) -> list[EvidenceLink]:
    """Walk the ordered event log and pair each question/follow-up with the
    answer and analysis that followed it.

    `events` are `interview_events` rows (or equivalent dicts) with
    `event_type` and `payload`, already ordered by `sequence` — the order
    `session_store.list_events` returns them in. A question with no answer
    yet (the interview is still in progress) is simply not linked; there is
    nothing to report about a turn that has not happened.
    """
    claims_by_topic = {t.topic: (t.grounded_in[0] if t.grounded_in else t.topic) for t in plan.topics}

    links: list[EvidenceLink] = []
    pending: dict | None = None  # the most recent unanswered question/followup

    for event in events:
        event_type = event.get("event_type")
        payload = event.get("payload") or {}

        if event_type in ("question", "followup"):
            pending = {"kind": event_type, "topic": payload.get("topic"), "question": payload.get("question")}
        elif event_type == "answer" and pending is not None:
            pending["answer_text"] = payload.get("answer_text", "")
        elif event_type == "analysis" and pending is not None and "answer_text" in pending:
            topic = pending["topic"] or ""
            links.append(EvidenceLink(
                topic=topic,
                claim_text=claims_by_topic.get(topic, topic),
                question=pending.get("question") or "",
                answer_text=pending["answer_text"],
                supported=bool(payload.get("supported")),
                confidence=float(payload.get("confidence") or 0.0),
                reason=payload.get("reason") or "",
                evidence_quote=payload.get("evidence_quote"),
                turn_kind=pending["kind"],
            ))
            pending = None

    return links
