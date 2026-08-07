"""The interview lifecycle: start a session, record an answer, get the next turn.

This is the piece Ticket 10 deliberately left out: `ai/interview.py` is a
pure function over state the *caller* has to assemble and persist. This
module is that caller. It owns no AI judgement of its own — every decision
about the candidate still comes from `ai/` — its job is purely: load state,
call the right stage in the right order, persist what happened, hand back
the next turn.

## Why the plan is persisted here, unlike everywhere else in `ai/`

`ai/question_planning.py` explicitly does not persist plans, because a plan
depends on HR configuration that can change between interviews and a stored
plan would go stale. That reasoning does not apply to a plan already
attached to one *specific, already-started* session — it was built once, at
session start, from the candidate/role/difficulty pinned at that moment, and
its only job from then on is letting this exact session resume after a
request boundary or a server restart. It never outlives the session it was
built for.
"""

from __future__ import annotations

from ai import answer_analysis, evidence_linking, question_planning, report_generation
from ai.coverage_manager import CoverageState, TopicOutcome, evaluate
from ai.interview import InterviewTurn, TurnKind, next_turn
from ai.knowledge_profile import CandidateKnowledgeProfile
from ai.question_planning import PlannedTopic, QuestionPlan
from pipeline import supabase_store

from . import session_store, state_machine
from .events import EventType, SessionEvent


class SessionError(RuntimeError):
    """A request the session's current state cannot honour — e.g. answering
    a session that already completed, or starting one for a candidate whose
    profile isn't ready. Distinct from `SupabaseError`, which means storage
    itself failed."""


def _plan_from_dict(d: dict) -> QuestionPlan:
    topics = [PlannedTopic(**t) for t in d.get("topics", [])]
    return QuestionPlan(
        topics=topics,
        coverage=d.get("coverage", []),
        estimated_minutes=d.get("estimated_minutes", 0),
        kind=d.get("kind", "heuristic_rule"),
        degraded_reason=d.get("degraded_reason"),
        rejected_ungrounded=d.get("rejected_ungrounded", []),
    )


def _outcomes_from_dict(d: dict) -> dict[str, TopicOutcome]:
    return {topic: TopicOutcome(**outcome) for topic, outcome in d.items()}


def _outcomes_to_dict(outcomes: dict[str, TopicOutcome]) -> dict:
    return {topic: outcome.__dict__ for topic, outcome in outcomes.items()}


async def _next_event_sequence(session_id: str, cache: list[int]) -> int:
    """`cache` is a one-item mutable box so a single call sequence doesn't
    need a round-trip per event within the same request."""
    cache[0] += 1
    return cache[0]


async def start(
    candidate_id: str,
    organization_id: str,
    role_title: str,
    required_skills: list[str] | None = None,
    difficulty: str = "standard",
    available_minutes: int = 20,
    provider_override: str | None = None,
) -> dict:
    """Load the candidate's profile, build a plan, open a session, return turn one."""
    profile_row = await supabase_store.fetch_profile(candidate_id)
    if profile_row is None:
        raise SessionError(f"no AI profile exists for candidate {candidate_id}")
    if profile_row.get("processing_status") != "READY_FOR_INTERVIEW":
        raise SessionError(
            f"candidate {candidate_id} is not ready for interview "
            f"(status: {profile_row.get('processing_status')})"
        )

    profile = CandidateKnowledgeProfile.from_dict(profile_row.get("knowledge_profile") or {})
    claims = [c["text"] for c in (profile_row.get("claims") or []) if isinstance(c, dict) and c.get("text")]

    plan = await question_planning.plan(
        profile, claims, role_title,
        required_skills=required_skills, difficulty=difficulty,
        available_minutes=available_minutes, provider_override=provider_override,
    )
    coverage = evaluate(plan, {})
    turn = await next_turn(plan, coverage, provider_override=provider_override)

    row = await session_store.create_session({
        "candidate_id": candidate_id,
        "organization_id": organization_id,
        "status": state_machine.IN_PROGRESS if turn.kind != TurnKind.COMPLETE else state_machine.COMPLETE,
        "role_title": role_title,
        "question_plan": plan.to_dict(),
        "coverage_state": coverage.to_dict(),
        "outcomes": {},
        "current_topic": turn.topic,
        "last_question": turn.question,
    })
    session_id = row["id"]

    seq = [0]
    await session_store.append_event(
        SessionEvent(session_id, await _next_event_sequence(session_id, seq),
                     EventType.SESSION_STARTED, {"role_title": role_title}).to_dict()
    )
    await session_store.append_event(
        SessionEvent(session_id, await _next_event_sequence(session_id, seq),
                     EventType(turn.kind.value), turn.to_dict()).to_dict()
    )

    return {"session_id": session_id, "turn": turn.to_dict(), "coverage": coverage.to_dict()}


async def answer(
    session_id: str,
    answer_text: str,
    provider_override: str | None = None,
) -> dict:
    """Record an answer to the session's current question and return the next turn."""
    row = await session_store.fetch_session(session_id)
    if row is None:
        raise SessionError(f"no session {session_id}")
    if row["status"] != state_machine.IN_PROGRESS:
        raise SessionError(f"session {session_id} is {row['status']}, not in_progress")

    plan = _plan_from_dict(row["question_plan"])
    outcomes = _outcomes_from_dict(row.get("outcomes") or {})
    current_topic_name = row["current_topic"]
    topic = next((t for t in plan.topics if t.topic == current_topic_name), None)
    if topic is None:
        raise SessionError(f"session {session_id} has no current topic to answer")

    claim_text = topic.grounded_in[0] if topic.grounded_in else topic.topic
    analysis = await answer_analysis.analyze(
        row.get("last_question") or topic.topic, answer_text, claim_text,
        provider_override=provider_override,
    )

    prior = outcomes.get(current_topic_name, TopicOutcome(topic=current_topic_name))
    outcomes[current_topic_name] = TopicOutcome(
        topic=current_topic_name,
        supported=prior.supported or analysis.supported,
        attempted=True,
        best_confidence=max(prior.best_confidence, analysis.confidence),
        attempts=prior.attempts + 1,
    )

    new_coverage = evaluate(plan, outcomes)
    turn = await next_turn(
        plan, new_coverage, last_answer_text=answer_text, last_analysis=analysis,
        provider_override=provider_override,
    )

    is_complete = turn.kind == TurnKind.COMPLETE

    # Events appended BEFORE the session row is mutated, not after. These two
    # writes aren't transactional — Supabase REST gives us no cross-table
    # transaction here — so whichever one goes first determines what a
    # client-visible failure actually means. With the row updated first (the
    # original order), a failure appending events left the session already
    # advanced to the next topic while the caller received an error and
    # believed nothing had happened; a naive retry of the same answer then
    # landed on a DIFFERENT topic than the one it was meant for — silently,
    # with no indication anything had gone wrong. Found live: a transient
    # `next_sequence` failure (a separate bug, since fixed) left exactly one
    # real session in that corrupted state.
    #
    # Event appends first means a failure here still leaves the session row
    # untouched — `current_topic`/`last_question` still point at the
    # question the candidate was actually just asked — so a retry with the
    # same answer re-analyzes against the SAME topic. Not free (the model
    # gets called again), but never silently wrong.
    seq = [await session_store.next_sequence(session_id)]
    for event_type, payload in (
        (EventType.ANSWER, {"topic": current_topic_name, "answer_text": answer_text}),
        (EventType.ANALYSIS, analysis.to_dict()),
        (EventType.COVERAGE_UPDATE, new_coverage.to_dict()),
        (EventType(turn.kind.value) if not is_complete else EventType.SESSION_COMPLETE, turn.to_dict()),
    ):
        await session_store.append_event(
            SessionEvent(session_id, await _next_event_sequence(session_id, seq),
                         event_type, payload).to_dict()
        )

    await session_store.update_session(session_id, {
        "status": state_machine.COMPLETE if is_complete else state_machine.IN_PROGRESS,
        "coverage_state": new_coverage.to_dict(),
        "outcomes": _outcomes_to_dict(outcomes),
        "current_topic": turn.topic,
        "last_question": turn.question,
    })

    if is_complete:
        # Best-effort: a code failing to flip to 'used' does not affect the
        # session, which is already the real source of truth for "can this
        # be resumed or restarted" (see interview_codes.redeem). This just
        # keeps the HR-facing code list from calling a finished code active.
        from . import codes_store
        linked_code = await codes_store.fetch_by_session(session_id)
        if linked_code is not None:
            await codes_store.update_code(linked_code["id"], {"status": "used"})

    return {
        "session_id": session_id,
        "turn": turn.to_dict(),
        "coverage": new_coverage.to_dict(),
        "analysis": analysis.to_dict(),
    }


def current_turn(row: dict) -> dict:
    """Reconstruct the turn a session is currently waiting on, from its
    stored columns — no AI call, since the question was already generated
    and persisted (`last_question`/`current_topic`) when this session state
    was last written. Used to resume a session (browser refresh, retry)
    without re-asking the model for a question it already produced."""
    if row["status"] == state_machine.COMPLETE or row["current_topic"] is None:
        return InterviewTurn(kind=TurnKind.COMPLETE).to_dict()
    return InterviewTurn(
        kind=TurnKind.QUESTION,
        topic=row["current_topic"],
        question=row["last_question"],
    ).to_dict()


async def report(session_id: str) -> dict:
    """Build the evidence-backed report for a session, from its stored plan
    and event log. Reads only what's already persisted — no model call, no
    re-judging an answer differently than it was judged live."""
    row = await session_store.fetch_session(session_id)
    if row is None:
        raise SessionError(f"no session {session_id}")

    plan = _plan_from_dict(row["question_plan"])
    coverage = CoverageState(**row["coverage_state"])
    events = await session_store.list_events(session_id)

    links = evidence_linking.build_links(plan, events)
    result = report_generation.build_report(
        plan, coverage, links, row["role_title"], row["status"],
    )
    return result.to_dict()


async def abandon(session_id: str, reason: str) -> None:
    row = await session_store.fetch_session(session_id)
    if row is None:
        raise SessionError(f"no session {session_id}")
    state_machine.require_transition(row["status"], state_machine.ABANDONED)

    await session_store.update_session(session_id, {"status": state_machine.ABANDONED})
    seq = [await session_store.next_sequence(session_id)]
    await session_store.append_event(
        SessionEvent(session_id, await _next_event_sequence(session_id, seq),
                     EventType.SESSION_ABANDONED, {"reason": reason}).to_dict()
    )
