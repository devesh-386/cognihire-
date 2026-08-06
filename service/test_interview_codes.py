"""Tests for the interview-code system: generation, redemption, and the
states that make a code unusable."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from session import codes_store, interview_codes, interview_session, session_store, state_machine


def _run(coro):
    return asyncio.run(coro)


class _FakeCodesStore:
    def __init__(self):
        self.rows: dict[str, dict] = {}
        self._next_id = 1

    async def create_code(self, fields):
        cid = f"code-{self._next_id}"
        self._next_id += 1
        row = {
            "id": cid, "session_id": None, "attempts_used": 0, "status": "active",
            "window_start": None, "window_end": None,
            **fields,
        }
        self.rows[cid] = row
        return row

    async def fetch_by_code(self, code):
        return next((r for r in self.rows.values() if r["code"] == code), None)

    async def fetch_by_session(self, session_id):
        return next((r for r in self.rows.values() if r["session_id"] == session_id), None)

    async def update_code(self, code_id, fields):
        self.rows[code_id].update(fields)


class _FakeSessionStore:
    def __init__(self):
        self.sessions: dict[str, dict] = {}
        self._next_id = 1

    async def create_session(self, fields):
        sid = fields.get("id") or f"session-{self._next_id}"
        self._next_id += 1
        row = {**fields, "id": sid}
        self.sessions[sid] = row
        return row

    async def fetch_session(self, session_id):
        return self.sessions.get(session_id)

    async def update_session(self, session_id, fields):
        self.sessions[session_id].update(fields)

    async def append_event(self, event):
        pass

    async def next_sequence(self, session_id):
        return 0


@pytest.fixture
def fake_codes(monkeypatch):
    store = _FakeCodesStore()
    monkeypatch.setattr(codes_store, "create_code", store.create_code)
    monkeypatch.setattr(codes_store, "fetch_by_code", store.fetch_by_code)
    monkeypatch.setattr(codes_store, "fetch_by_session", store.fetch_by_session)
    monkeypatch.setattr(codes_store, "update_code", store.update_code)
    return store


@pytest.fixture
def fake_sessions(monkeypatch):
    store = _FakeSessionStore()
    monkeypatch.setattr(session_store, "create_session", store.create_session)
    monkeypatch.setattr(session_store, "fetch_session", store.fetch_session)
    monkeypatch.setattr(session_store, "update_session", store.update_session)
    monkeypatch.setattr(session_store, "append_event", store.append_event)
    monkeypatch.setattr(session_store, "next_sequence", store.next_sequence)
    return store


async def _fake_start_factory(fake_sessions, session_id):
    """A fake `interview_session.start` that also writes the row a resume/
    complete check needs, so patching it doesn't leave `fake_sessions` out
    of sync with what `start_with_code` believes happened."""
    await fake_sessions.create_session({
        "id": session_id, "status": state_machine.IN_PROGRESS,
        "current_topic": "React dashboard", "last_question": "Tell me about it.",
        "coverage_state": {"completion_percent": 0}, "outcomes": {},
    })
    fake_sessions.sessions[session_id]["id"] = session_id
    return {
        "session_id": session_id,
        "turn": {"kind": "question", "topic": "React dashboard", "question": "Tell me about it."},
        "coverage": {"completion_percent": 0},
    }


def test_generate_creates_an_active_code(fake_codes):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer"))
    assert row["status"] == "active"
    assert row["attempts_used"] == 0
    assert len(row["code"]) == 8


def test_start_with_unknown_code_raises_not_found(fake_codes, fake_sessions):
    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code("NOSUCH01"))
    assert exc.value.reason == "not_found"


def test_start_with_expired_code_raises(fake_codes, fake_sessions):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer", expires_in_hours=1))
    _run(codes_store.update_code(row["id"], {
        "expires_at": (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
    }))
    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code(row["code"]))
    assert exc.value.reason == "expired"


def test_start_with_revoked_code_raises(fake_codes, fake_sessions):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer"))
    _run(codes_store.update_code(row["id"], {"status": "revoked"}))
    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code(row["code"]))
    assert exc.value.reason == "revoked"


def test_start_outside_window_raises(fake_codes, fake_sessions):
    future = datetime.now(timezone.utc) + timedelta(hours=1)
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer",
                                         window_start=future))
    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code(row["code"]))
    assert exc.value.reason == "not_yet_open"


def test_start_calls_interview_session_and_links_the_new_session(fake_codes, fake_sessions, monkeypatch):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer"))

    async def fake_start(candidate_id, organization_id, role_title, **kwargs):
        return await _fake_start_factory(fake_sessions, "session-x")

    monkeypatch.setattr(interview_session, "start", fake_start)

    result = _run(interview_codes.start_with_code(row["code"]))

    assert result["session_id"] == "session-x"
    updated = _run(codes_store.fetch_by_code(row["code"]))
    assert updated["session_id"] == "session-x"
    assert updated["attempts_used"] == 1


def test_resuming_an_in_progress_session_does_not_consume_an_attempt(fake_codes, fake_sessions, monkeypatch):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer"))

    async def fake_start(candidate_id, organization_id, role_title, **kwargs):
        return await _fake_start_factory(fake_sessions, "session-x")

    monkeypatch.setattr(interview_session, "start", fake_start)
    _run(interview_codes.start_with_code(row["code"]))

    fake_sessions.sessions["session-x"]["status"] = state_machine.IN_PROGRESS
    fake_sessions.sessions["session-x"]["current_topic"] = "React dashboard"
    fake_sessions.sessions["session-x"]["last_question"] = "Tell me about it."
    fake_sessions.sessions["session-x"]["coverage_state"] = {"completion_percent": 0}

    result = _run(interview_codes.start_with_code(row["code"]))

    assert result["session_id"] == "session-x"
    assert result["turn"]["question"] == "Tell me about it."
    updated = _run(codes_store.fetch_by_code(row["code"]))
    assert updated["attempts_used"] == 1  # unchanged — this was a resume, not a new attempt


def test_starting_a_completed_sessions_code_raises_already_used(fake_codes, fake_sessions, monkeypatch):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer"))

    async def fake_start(candidate_id, organization_id, role_title, **kwargs):
        return await _fake_start_factory(fake_sessions, "session-x")

    monkeypatch.setattr(interview_session, "start", fake_start)
    _run(interview_codes.start_with_code(row["code"]))
    fake_sessions.sessions["session-x"]["status"] = state_machine.COMPLETE

    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code(row["code"]))
    assert exc.value.reason == "already_used"


def test_max_attempts_exceeded(fake_codes, fake_sessions, monkeypatch):
    row = _run(interview_codes.generate("cand-1", "org-1", "Backend Engineer", max_attempts=1))
    call_count = {"n": 0}

    async def fake_start(candidate_id, organization_id, role_title, **kwargs):
        call_count["n"] += 1
        return await _fake_start_factory(fake_sessions, f"session-{call_count['n']}")

    monkeypatch.setattr(interview_session, "start", fake_start)
    _run(interview_codes.start_with_code(row["code"]))
    # Mark the session abandoned so a second call falls through to the
    # attempts check instead of resuming.
    fake_sessions.sessions["session-1"]["status"] = state_machine.ABANDONED

    with pytest.raises(interview_codes.CodeError) as exc:
        _run(interview_codes.start_with_code(row["code"]))
    assert exc.value.reason == "max_attempts_exceeded"
