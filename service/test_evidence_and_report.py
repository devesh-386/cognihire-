"""Tests for evidence_linking and report_generation — both pure/deterministic,
reshaping data other stages already gated. No model to fake here."""

from __future__ import annotations

import asyncio

import pytest

from ai.coverage_manager import CoverageState
from ai.evidence_linking import build_links
from ai.question_planning import PlannedTopic, QuestionPlan
from ai.report_generation import build_report
from pipeline import supabase_store
from session import interview_session, session_store, state_machine


def _run(coro):
    return asyncio.run(coro)


PLAN = QuestionPlan(
    topics=[
        PlannedTopic(topic="React dashboard", objective="Verify ownership.",
                     grounded_in=["Built and shipped a React dashboard used by 200+ staff."], minutes=8),
        PlannedTopic(topic="Team leadership", objective="Verify leadership.",
                     grounded_in=["Led a team of 4 engineers."], minutes=5),
    ],
    kind="hosted_llm",
    rejected_ungrounded=["Invented a time machine"],
)


def _event(seq, event_type, payload):
    return {"session_id": "s1", "sequence": seq, "event_type": event_type, "payload": payload}


EVENTS = [
    _event(1, "session_started", {"role_title": "Backend Engineer"}),
    _event(2, "question", {"topic": "React dashboard", "question": "Tell me about the dashboard."}),
    _event(3, "answer", {"topic": "React dashboard", "answer_text": "I built it end to end."}),
    _event(4, "analysis", {
        "supported": True, "confidence": 0.9, "reason": "Concrete.",
        "evidence_quote": "I built it end to end.",
    }),
    _event(5, "coverage_update", {"completion_percent": 50}),
    _event(6, "question", {"topic": "Team leadership", "question": "Tell me about leading the team."}),
    _event(7, "answer", {"topic": "Team leadership", "answer_text": "It went fine."}),
    _event(8, "analysis", {
        "supported": False, "confidence": 0.3, "reason": "Too vague.", "evidence_quote": None,
    }),
    _event(9, "followup", {"topic": "Team leadership", "question": "Be more specific?"}),
    _event(10, "answer", {"topic": "Team leadership", "answer_text": "I ran daily standups."}),
    _event(11, "analysis", {
        "supported": True, "confidence": 0.8, "reason": "Concrete detail.",
        "evidence_quote": "I ran daily standups.",
    }),
]


def test_build_links_pairs_each_question_with_its_answer_and_analysis():
    links = build_links(PLAN, EVENTS)

    assert len(links) == 3
    first = links[0]
    assert first.topic == "React dashboard"
    assert first.claim_text == "Built and shipped a React dashboard used by 200+ staff."
    assert first.answer_text == "I built it end to end."
    assert first.supported is True
    assert first.turn_kind == "question"


def test_build_links_keeps_the_followup_as_a_separate_link():
    links = build_links(PLAN, EVENTS)
    team_links = [link for link in links if link.topic == "Team leadership"]

    assert len(team_links) == 2
    assert team_links[0].turn_kind == "question"
    assert team_links[0].supported is False
    assert team_links[1].turn_kind == "followup"
    assert team_links[1].supported is True


def test_build_links_ignores_an_unanswered_question():
    events = EVENTS + [_event(12, "question", {"topic": "New topic", "question": "?"})]
    links = build_links(PLAN, events)
    assert not any(link.topic == "New topic" for link in links)


def test_report_uses_each_topics_last_attempt():
    links = build_links(PLAN, EVENTS)
    coverage = CoverageState(completion_percent=100, is_complete=True)

    report = build_report(PLAN, coverage, links, "Backend Engineer", "complete")

    assert report.role_title == "Backend Engineer"
    assert report.completion_percent == 100
    leadership = next(t for t in report.topics if t.topic == "Team leadership")
    assert leadership.outcome == "supported"
    assert leadership.attempts == 2
    assert leadership.evidence_quote == "I ran daily standups."


def test_report_marks_unattempted_topics_with_no_outcome():
    coverage = CoverageState(completion_percent=0, is_complete=False)
    report = build_report(PLAN, coverage, [], "Backend Engineer", "in_progress")

    for topic in report.topics:
        assert topic.outcome is None
        assert topic.attempts == 0


def test_report_surfaces_rejected_ungrounded_topics():
    report = build_report(PLAN, CoverageState(), [], "Backend Engineer", "in_progress")
    assert report.rejected_ungrounded_topics == ["Invented a time machine"]


def test_transparency_metrics_reflect_provenance_and_grounding():
    links = build_links(PLAN, EVENTS)
    coverage = CoverageState(completion_percent=100, is_complete=True)
    report = build_report(PLAN, coverage, links, "Backend Engineer", "complete")

    t = report.transparency
    assert t is not None
    # Planned by a model, not the fallback.
    assert t.planned_by == "hosted_llm"
    assert t.used_ai_planner is True
    assert t.planning_degraded_reason is None
    # Two topics survived the gate, one ("Invented a time machine") was
    # rejected: 2 of 3 proposed → 0.667.
    assert t.topics_planned == 2
    assert t.topics_grounding_rejected == 1
    assert t.grounding_rate == 0.667
    # Both topics examined; both end supported (leadership's follow-up, the
    # last attempt, cleared the bar), each with a verbatim evidence quote.
    assert t.topics_examined == 2
    assert t.supported == 2
    assert t.not_supported == 0
    assert t.topics_with_direct_evidence == 2
    # Mean of React 0.9 and leadership's last attempt 0.8 = 0.85.
    assert t.mean_confidence == 0.85


def test_transparency_metrics_flag_the_deterministic_fallback():
    fallback_plan = QuestionPlan(
        topics=list(PLAN.topics),
        kind="heuristic_rule",
        degraded_reason="the provider was unreachable",
    )
    report = build_report(fallback_plan, CoverageState(), [], "Backend Engineer", "in_progress")

    t = report.transparency
    assert t is not None
    assert t.used_ai_planner is False
    assert t.planning_degraded_reason == "the provider was unreachable"
    # Nothing examined yet → no mean confidence, not a fabricated 0.
    assert t.mean_confidence is None
    # Nothing was rejected, so grounding is vacuously perfect rather than 0/0.
    assert t.grounding_rate == 1.0


# --- interview_session.report against a fake store ----------------------------


class _FakeStore:
    def __init__(self, session_row, events):
        self._session_row = session_row
        self._events = events

    async def fetch_session(self, session_id):
        return self._session_row if session_id == self._session_row["id"] else None

    async def list_events(self, session_id):
        return self._events


@pytest.fixture
def fake_store(monkeypatch):
    row = {
        "id": "s1",
        "role_title": "Backend Engineer",
        "status": "complete",
        "question_plan": PLAN.to_dict(),
        "coverage_state": CoverageState(completion_percent=100, is_complete=True).to_dict(),
        "outcomes": {},
        "current_topic": None,
        "last_question": None,
    }
    store = _FakeStore(row, EVENTS)
    monkeypatch.setattr(session_store, "fetch_session", store.fetch_session)
    monkeypatch.setattr(session_store, "list_events", store.list_events)
    return store


def test_session_report_end_to_end(fake_store):
    result = _run(interview_session.report("s1"))

    assert result["role_title"] == "Backend Engineer"
    assert result["completion_percent"] == 100
    leadership = next(t for t in result["topics"] if t["topic"] == "Team leadership")
    assert leadership["outcome"] == "supported"


def test_session_report_raises_for_unknown_session(fake_store):
    with pytest.raises(interview_session.SessionError):
        _run(interview_session.report("no-such-session"))
