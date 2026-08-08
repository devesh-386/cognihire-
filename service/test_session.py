"""Tests for the session orchestrator: state_machine (pure) and
interview_session (start/answer/abandon against a fake store + fake model).

The fake store is an in-memory dict keyed like the real Supabase tables would
be — this tests the orchestration logic (what gets loaded, what gets called
in what order, what gets persisted) without asserting anything about REST
transport, which `session_store.py`'s shape already documents.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from ai import provider
from pipeline import supabase_store
from session import codes_store, interview_session, session_store, state_machine


def _run(coro):
    return asyncio.run(coro)


# --- state_machine -----------------------------------------------------------


def test_not_started_can_move_to_in_progress_or_abandoned():
    assert state_machine.can_transition(state_machine.NOT_STARTED, state_machine.IN_PROGRESS)
    assert state_machine.can_transition(state_machine.NOT_STARTED, state_machine.ABANDONED)
    assert not state_machine.can_transition(state_machine.NOT_STARTED, state_machine.COMPLETE)


def test_terminal_states_have_no_outgoing_transitions():
    assert not state_machine.can_transition(state_machine.COMPLETE, state_machine.IN_PROGRESS)
    assert not state_machine.can_transition(state_machine.ABANDONED, state_machine.IN_PROGRESS)
    assert state_machine.is_terminal(state_machine.COMPLETE)
    assert state_machine.is_terminal(state_machine.ABANDONED)


def test_require_transition_raises_on_illegal_move():
    with pytest.raises(state_machine.IllegalTransition):
        state_machine.require_transition(state_machine.COMPLETE, state_machine.IN_PROGRESS)


def test_unknown_status_raises():
    with pytest.raises(ValueError):
        state_machine.can_transition("bogus", state_machine.IN_PROGRESS)


# --- interview_session: fake store + fake model -------------------------------


class _FakeStore:
    """In-memory stand-in for the Supabase-backed session_store/supabase_store."""

    def __init__(self):
        self.sessions: dict[str, dict] = {}
        self.events: list[dict] = []
        self._next_id = 1
        self.profile: dict | None = None

    async def fetch_profile(self, candidate_id):
        return self.profile

    async def create_session(self, fields):
        sid = f"session-{self._next_id}"
        self._next_id += 1
        row = {"id": sid, **fields}
        self.sessions[sid] = row
        return row

    async def fetch_session(self, session_id):
        return self.sessions.get(session_id)

    async def update_session(self, session_id, fields):
        self.sessions[session_id].update(fields)

    async def append_event(self, event):
        self.events.append(event)

    async def next_sequence(self, session_id):
        return sum(1 for e in self.events if e["session_id"] == session_id)


PROFILE_ROW = {
    "candidate_id": "cand-1",
    "processing_status": "READY_FOR_INTERVIEW",
    "knowledge_profile": {
        "identity": {"name": "Ada", "email": None, "degree": None, "university": None},
        "skills": ["React"],
        "technologies": [],
        "projects": ["Built and shipped a React dashboard used by 200+ staff."],
        "experience": ["Led a team of 4 engineers."],
        "education": [],
        "certifications": [],
        "domains": [],
        "strengths": [],
        "estimated_focus": [],
        "kind": "hosted_llm",
        "degraded_reason": None,
        "rejected_ungrounded": [],
        "rejected_unsupported_inferences": [],
    },
    "claims": [
        {"id": "c1", "text": "Led a team of 4 engineers.", "source": "resume", "skill": None},
    ],
}


@pytest.fixture(autouse=True)
def fake_store(monkeypatch):
    store = _FakeStore()
    monkeypatch.setattr(supabase_store, "fetch_profile", store.fetch_profile)
    monkeypatch.setattr(session_store, "create_session", store.create_session)
    monkeypatch.setattr(session_store, "fetch_session", store.fetch_session)
    monkeypatch.setattr(session_store, "update_session", store.update_session)
    monkeypatch.setattr(session_store, "append_event", store.append_event)
    monkeypatch.setattr(session_store, "next_sequence", store.next_sequence)
    # No interview code is linked to sessions created in these tests — the
    # real lookup would hit the network, so stub it to "not linked" rather
    # than pulling the whole codes system into every session test.
    monkeypatch.setattr(codes_store, "fetch_by_session", lambda session_id: _no_linked_code())
    return store


async def _no_linked_code():
    return None


class _FakeResponse:
    def __init__(self, status_code, payload):
        self.status_code = status_code
        self._payload = payload

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
        return self._responder(url, kwargs)


def _patch_model_sequence(monkeypatch, replies: list[dict]):
    """Each call to the model returns the next reply in `replies`, in order —
    lets one test drive plan -> question -> analysis -> next question without
    hand-matching prompts."""
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    calls = {"i": 0}

    def responder(url, kw):
        payload = replies[min(calls["i"], len(replies) - 1)]
        calls["i"] += 1
        return _FakeResponse(200, {"choices": [{"message": {"content": json.dumps(payload)}}]})

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))


PLAN_REPLY = {
    "topics": [
        {
            "topic": "Team leadership",
            "objective": "Verify leadership.",
            "grounded_in": ["Led a team of 4 engineers."],
            "minutes": 10,
        }
    ],
    "coverage": ["leadership"],
}
QUESTION_REPLY = {"question": "Tell me about leading that team."}


def test_start_raises_when_no_profile_exists(fake_store):
    fake_store.profile = None
    with pytest.raises(interview_session.SessionError):
        _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))


def test_start_raises_when_profile_not_ready(fake_store):
    fake_store.profile = {**PROFILE_ROW, "processing_status": "CLAIMS_READY"}
    with pytest.raises(interview_session.SessionError):
        _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))


def test_start_refuses_a_plan_with_no_topics(fake_store, monkeypatch):
    """A session with no topics used to open, immediately complete, and
    produce a report saying the interview finished — a claim about a
    candidate that nothing supports. Refused at the point the fabricated
    report would have been created."""
    # Ready, but with nothing grounded to interview against — the state
    # `profile_builder` now refuses to produce, guarded here too because this
    # is where the fabricated report would be written.
    fake_store.profile = {
        "candidate_id": "cand-1",
        "processing_status": "READY_FOR_INTERVIEW",
        "knowledge_profile": {},
        "claims": [],
    }

    with pytest.raises(interview_session.SessionError):
        _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))

    assert fake_store.sessions == {}


def test_start_builds_a_plan_and_returns_the_first_question(fake_store, monkeypatch):
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])

    result = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))

    assert result["turn"]["kind"] == "question"
    assert result["turn"]["topic"] == "Team leadership"
    session_id = result["session_id"]
    row = fake_store.sessions[session_id]
    assert row["status"] == state_machine.IN_PROGRESS
    assert row["current_topic"] == "Team leadership"
    event_types = [e["event_type"] for e in fake_store.events if e["session_id"] == session_id]
    assert event_types == ["session_started", "question"]


def test_answer_supported_completes_the_single_topic_plan(fake_store, monkeypatch):
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]

    _patch_model_sequence(
        monkeypatch,
        [
            {
                "supported": True,
                "confidence": 0.9,
                "followup_required": False,
                "evidence_quote": "I ran the standups myself.",
                "reason": "Concrete detail.",
            }
        ],
    )

    result = _run(
        interview_session.answer(session_id, "I ran the standups myself.")
    )

    assert result["analysis"]["supported"] is True
    assert result["turn"]["kind"] == "complete"
    row = fake_store.sessions[session_id]
    assert row["status"] == state_machine.COMPLETE


def test_answer_unsupported_asks_a_followup_and_stays_in_progress(fake_store, monkeypatch):
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]

    _patch_model_sequence(
        monkeypatch,
        [
            {
                "supported": False,
                "confidence": 0.3,
                "followup_required": True,
                "evidence_quote": None,
                "reason": "Too vague.",
            },
            {"question": "Can you be more specific about your role?"},
        ],
    )

    result = _run(interview_session.answer(session_id, "It went fine."))

    assert result["turn"]["kind"] == "followup"
    row = fake_store.sessions[session_id]
    assert row["status"] == state_machine.IN_PROGRESS
    assert row["current_topic"] == "Team leadership"


def test_a_later_verdict_replaces_an_earlier_supported_one(fake_store, monkeypatch):
    """Regression. `answer` used to record `supported = prior.supported or
    analysis.supported`, so once a topic was ever marked supported nothing
    could take it back — while `report_generation` read only the last
    attempt. A topic contradicted on its follow-up therefore counted toward
    `completion_percent` while the report printed "not supported" for it.

    The path below is the realistic one: a first answer the model supports
    but is only 0.3 sure of (so the topic stays open for a follow-up), then a
    follow-up the model is 0.9 sure is NOT supported. Under the old sticky
    rule the surviving `supported=True` plus that high confidence marked the
    topic covered — a confident rejection flipping a claim to substantiated.
    """
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]

    _patch_model_sequence(monkeypatch, [
        {"supported": True, "confidence": 0.3, "followup_required": True,
         "evidence_quote": None, "reason": "Plausible but thin."},
        {"question": "Can you give a specific example?"},
    ])
    _run(interview_session.answer(session_id, "I led the team."))

    _patch_model_sequence(monkeypatch, [
        {"supported": False, "confidence": 0.9, "followup_required": False,
         "evidence_quote": None, "reason": "Contradicted the earlier answer."},
    ])
    result = _run(interview_session.answer(session_id, "Actually someone else led it."))

    row = fake_store.sessions[session_id]
    assert row["outcomes"]["Team leadership"]["supported"] is False
    assert "Team leadership" not in result["coverage"]["covered"]
    assert "Team leadership" in result["coverage"]["unsupported"]


def test_a_failed_event_append_leaves_the_session_row_untouched(fake_store, monkeypatch):
    """Regression test for a real bug found live: the session row used to be
    updated BEFORE events were appended, so a failure appending events (a
    transient Supabase error, a network blip — anything) left the session
    silently advanced to the next topic while the caller received an error
    and had no way to know the interview had actually moved on. A client
    that naively retried the same answer then landed on the WRONG topic.

    Event appends now happen first — a failure there must leave the session
    row exactly as it was before this call, so a retry is safe."""
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]
    row_before = dict(fake_store.sessions[session_id])

    _patch_model_sequence(
        monkeypatch,
        [{
            "supported": True, "confidence": 0.9, "followup_required": False,
            "evidence_quote": "I led it end to end.", "reason": "Specific enough.",
        }],
    )

    async def failing_append_event(event):
        raise supabase_store.SupabaseError("simulated transient failure")

    monkeypatch.setattr(session_store, "append_event", failing_append_event)

    with pytest.raises(supabase_store.SupabaseError):
        _run(interview_session.answer(session_id, "I led it end to end."))

    assert fake_store.sessions[session_id] == row_before, (
        "the session row must be unchanged after a failed event append — "
        "otherwise a client-visible error can hide a real state change"
    )


def test_answering_a_completed_session_raises(fake_store, monkeypatch):
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]
    fake_store.sessions[session_id]["status"] = state_machine.COMPLETE

    with pytest.raises(interview_session.SessionError):
        _run(interview_session.answer(session_id, "anything"))


def test_abandon_marks_the_session_and_logs_an_event(fake_store, monkeypatch):
    fake_store.profile = PROFILE_ROW
    _patch_model_sequence(monkeypatch, [PLAN_REPLY, QUESTION_REPLY])
    started = _run(interview_session.start("cand-1", "org-1", "Backend Engineer"))
    session_id = started["session_id"]

    _run(interview_session.abandon(session_id, "candidate disconnected"))

    assert fake_store.sessions[session_id]["status"] == state_machine.ABANDONED
    last_event = fake_store.events[-1]
    assert last_event["event_type"] == "session_abandoned"
    assert last_event["payload"]["reason"] == "candidate disconnected"


def test_abandon_unknown_session_raises(fake_store):
    with pytest.raises(interview_session.SessionError):
        _run(interview_session.abandon("no-such-session", "x"))
