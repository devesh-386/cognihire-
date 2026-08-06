"""Tests for the interview engine: coverage_manager, answer_analysis,
interview.

The load-bearing properties: coverage tracking never lies about what was
covered, answer analysis grounds its evidence in the actual answer (not the
resume, not an invention), and question generation stays anchored to a plan
topic's own already-grounded material.
"""

from __future__ import annotations

import asyncio
import json

import httpx

from ai import provider
from ai.answer_analysis import AnswerAnalysis, analyze
from ai.coverage_manager import CoverageState, TopicOutcome, evaluate, next_topic
from ai.interview import TurnKind, generate_followup, generate_question, next_turn
from ai.question_planning import PlannedTopic, QuestionPlan


def _run(coro):
    return asyncio.run(coro)


class _FakeResponse:
    def __init__(self, status_code, payload=None):
        self.status_code = status_code
        self._payload = payload or {}

    def json(self):
        return self._payload


class _FakeAsyncClient:
    def __init__(self, responder):
        self._responder = responder

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, **kwargs):
        result = self._responder(url, kwargs)
        if isinstance(result, Exception):
            raise result
        return result


def _patch_model(monkeypatch, payload_obj=None, error=None, capture=None):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")

    def responder(url, kw):
        if capture is not None:
            capture.append(kw)
        if error is not None:
            return error
        return _FakeResponse(
            200, {"choices": [{"message": {"content": json.dumps(payload_obj)}}]}
        )

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))


PLAN = QuestionPlan(
    topics=[
        PlannedTopic(topic="React dashboard", objective="Verify ownership.",
                     grounded_in=["Built and shipped a React dashboard used by 200+ staff."], minutes=8),
        PlannedTopic(topic="Team leadership", objective="Verify leadership.",
                     grounded_in=["Led a team of 4 engineers."], minutes=5),
    ],
    kind="hosted_llm",
)


# --- coverage_manager --------------------------------------------------------


def test_all_unattempted_topics_are_remaining():
    state = evaluate(PLAN, {})
    assert state.remaining == ["React dashboard", "Team leadership"]
    assert state.covered == []
    assert state.completion_percent == 0
    assert state.recommended_next == "React dashboard"
    assert not state.is_complete


def test_supported_topic_is_covered():
    outcomes = {"React dashboard": TopicOutcome("React dashboard", supported=True, attempted=True)}
    state = evaluate(PLAN, outcomes)
    assert "React dashboard" in state.covered
    assert state.remaining == ["Team leadership"]
    assert state.completion_percent == 50


def test_attempted_but_unsupported_stays_remaining_and_is_flagged():
    outcomes = {"React dashboard": TopicOutcome("React dashboard", supported=False, attempted=True)}
    state = evaluate(PLAN, outcomes)
    assert "React dashboard" in state.unsupported
    assert "React dashboard" in state.remaining
    assert "React dashboard" not in state.covered


def test_all_covered_marks_complete():
    outcomes = {t.topic: TopicOutcome(t.topic, supported=True, attempted=True) for t in PLAN.topics}
    state = evaluate(PLAN, outcomes)
    assert state.is_complete
    assert state.completion_percent == 100
    assert state.recommended_next is None


def test_empty_plan_is_immediately_complete():
    state = evaluate(QuestionPlan(topics=[]), {})
    assert state.is_complete
    assert state.completion_percent == 100


def test_next_topic_resolves_the_planned_topic_object():
    state = evaluate(PLAN, {})
    topic = next_topic(PLAN, state)
    assert topic.topic == "React dashboard"
    assert topic.grounded_in == ["Built and shipped a React dashboard used by 200+ staff."]


def test_next_topic_is_none_when_complete():
    state = CoverageState(is_complete=True, recommended_next=None)
    assert next_topic(PLAN, state) is None


# --- answer_analysis ---------------------------------------------------------


CLAIM = "Led a team of 4 engineers."
QUESTION = "Tell me about leading that team."
ANSWER = "I ran daily standups and unblocked two engineers who were stuck on the auth migration."


def test_supported_answer_with_grounded_evidence(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "supported": True,
            "confidence": 0.85,
            "followup_required": False,
            "evidence_quote": "I ran daily standups and unblocked two engineers who were stuck on the auth migration.",
            "reason": "Specific, concrete detail about day-to-day leadership.",
        },
    )

    result = _run(analyze(QUESTION, ANSWER, CLAIM))

    assert result.supported
    assert result.confidence == 0.85
    assert not result.followup_required
    assert result.evidence_quote == ANSWER
    assert result.kind == "hosted_llm"


def test_fabricated_evidence_quote_forces_unsupported(monkeypatch):
    """A model that invents the quote it uses to justify 'supported' cannot be
    trusted on the verdict either."""
    _patch_model(
        monkeypatch,
        {
            "supported": True,
            "confidence": 0.9,
            "followup_required": False,
            "evidence_quote": "I personally rewrote the entire backend in a weekend.",
            "reason": "Sounds convincing.",
        },
    )

    result = _run(analyze(QUESTION, ANSWER, CLAIM))

    assert not result.supported
    assert result.confidence <= 0.2
    assert result.evidence_quote is None
    assert result.followup_required


def test_unsupported_verdict_always_requires_followup(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "supported": False,
            "confidence": 0.6,
            "followup_required": False,  # model says no, but this must be overridden
            "evidence_quote": None,
            "reason": "Too vague.",
        },
    )

    result = _run(analyze(QUESTION, "It went fine.", CLAIM))

    assert result.followup_required


def test_empty_answer_is_unsupported_without_calling_the_model(monkeypatch):
    def responder(url, kw):
        raise AssertionError("must not call the model for an empty answer")

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))

    result = _run(analyze(QUESTION, "   ", CLAIM))

    assert not result.supported
    assert result.followup_required
    assert "no answer" in result.reason


def test_provider_outage_degrades_to_heuristic_and_always_follows_up(monkeypatch):
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    result = _run(analyze(QUESTION, ANSWER, CLAIM))

    assert result.kind == "heuristic_rule"
    assert not result.supported
    assert result.followup_required
    assert result.degraded_reason


def test_confidence_is_clamped_to_valid_range(monkeypatch):
    _patch_model(
        monkeypatch,
        {"supported": True, "confidence": 5.0, "followup_required": False,
         "evidence_quote": None, "reason": "x"},
    )

    result = _run(analyze(QUESTION, ANSWER, CLAIM))

    assert 0.0 <= result.confidence <= 1.0


# --- interview: question / follow-up generation ------------------------------


def test_question_uses_only_the_topics_own_grounded_material(monkeypatch):
    capture: list = []
    _patch_model(monkeypatch, {"question": "Walk me through building that dashboard."}, capture=capture)

    turn = _run(generate_question(PLAN.topics[0]))

    assert turn.kind == TurnKind.QUESTION
    assert turn.topic == "React dashboard"
    assert turn.question == "Walk me through building that dashboard."
    sent = capture[0]["json"]["messages"][1]["content"]
    assert "Built and shipped a React dashboard used by 200+ staff." in sent
    # Nothing from the other topic should leak into this prompt.
    assert "Led a team of 4 engineers." not in sent


def test_question_generation_degrades_to_a_template(monkeypatch):
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    turn = _run(generate_question(PLAN.topics[0]))

    assert turn.generation_kind == "heuristic_rule"
    assert turn.question
    assert turn.degraded_reason


def test_followup_references_the_failure_reason(monkeypatch):
    capture: list = []
    _patch_model(monkeypatch, {"question": "What specifically did you unblock?"}, capture=capture)
    analysis = AnswerAnalysis(
        supported=False, confidence=0.3, followup_required=True,
        reason="Too vague, no specific example.", kind="hosted_llm",
    )

    turn = _run(generate_followup(PLAN.topics[0], "It went well.", analysis))

    assert turn.kind == TurnKind.FOLLOWUP
    sent = capture[0]["json"]["messages"][1]["content"]
    assert "Too vague, no specific example." in sent


# --- interview: end-to-end turn orchestration --------------------------------


def test_next_turn_asks_the_first_topic_when_nothing_attempted(monkeypatch):
    _patch_model(monkeypatch, {"question": "Tell me about the dashboard."})
    state = evaluate(PLAN, {})

    turn = _run(next_turn(PLAN, state))

    assert turn.kind == TurnKind.QUESTION
    assert turn.topic == "React dashboard"


def test_next_turn_follows_up_when_required(monkeypatch):
    _patch_model(monkeypatch, {"question": "Can you be more specific?"})
    state = evaluate(PLAN, {})
    analysis = AnswerAnalysis(
        supported=False, confidence=0.2, followup_required=True,
        reason="vague", kind="hosted_llm",
    )

    turn = _run(next_turn(PLAN, state, last_answer_text="it was fine", last_analysis=analysis))

    assert turn.kind == TurnKind.FOLLOWUP
    assert turn.topic == "React dashboard"


def test_next_turn_moves_on_when_supported(monkeypatch):
    _patch_model(monkeypatch, {"question": "Tell me about leading the team."})
    outcomes = {"React dashboard": TopicOutcome("React dashboard", supported=True, attempted=True)}
    state = evaluate(PLAN, outcomes)
    analysis = AnswerAnalysis(supported=True, confidence=0.9, followup_required=False, reason="good", kind="hosted_llm")

    turn = _run(next_turn(PLAN, state, last_answer_text="detailed answer", last_analysis=analysis))

    assert turn.kind == TurnKind.QUESTION
    assert turn.topic == "Team leadership"


def test_next_turn_completes_when_all_covered(monkeypatch):
    def responder(url, kw):
        raise AssertionError("must not call the model when the interview is complete")

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))

    outcomes = {t.topic: TopicOutcome(t.topic, supported=True, attempted=True) for t in PLAN.topics}
    state = evaluate(PLAN, outcomes)

    turn = _run(next_turn(PLAN, state))

    assert turn.kind == TurnKind.COMPLETE
    assert turn.question is None
