"""Unit tests for session/live_interview.py's text-in/text-out contract.

The OpenAI Realtime leg is fully faked here — these tests never touch the
network or a real API key. What they actually verify: a finalized voice
transcript calls the EXACT SAME `interview_session.answer()` that `POST
/interview/answer` uses, the next question gets spoken via a scripted
`response.create` (never a bare one that would let OpenAI free-generate),
and barge-in cancels cleanly without corrupting session state.
"""

from __future__ import annotations

import asyncio
import base64
import json

import pytest

from session import codes_store, interview_session, live_interview, session_store


def run(coro):
    return asyncio.run(coro)


class FakeCandidateWS:
    """Records everything sent to the candidate — no real network."""

    def __init__(self):
        self.sent_text: list[dict] = []
        self.sent_bytes: list[bytes] = []
        self.close_codes: list[int] = []

    async def send_text(self, data: str) -> None:
        self.sent_text.append(json.loads(data))

    async def send_bytes(self, data: bytes) -> None:
        self.sent_bytes.append(data)

    async def receive(self) -> dict:
        return {"type": "websocket.disconnect"}

    async def close(self, code: int = 1000) -> None:
        self.close_codes.append(code)


class FakeOpenAIWS:
    """Records every outbound event; `recv()` plays back a canned queue."""

    def __init__(self):
        self.sent: list[dict] = []
        self._queue: asyncio.Queue = asyncio.Queue()

    async def send(self, message: str) -> None:
        self.sent.append(json.loads(message))

    def push(self, event: dict) -> None:
        self._queue.put_nowait(json.dumps(event))

    async def recv(self) -> str:
        return await self._queue.get()

    async def close(self) -> None:
        pass


# --- authorize() -------------------------------------------------------

def test_authorize_accepts_matching_code_and_session(monkeypatch):
    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    run(live_interview.authorize("ABC123", "sess-1"))  # must not raise


def test_authorize_rejects_mismatched_code(monkeypatch):
    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-OTHER"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    with pytest.raises(live_interview.LiveSessionError):
        run(live_interview.authorize("ABC123", "sess-1"))


def test_authorize_rejects_unknown_code(monkeypatch):
    async def fake_fetch_by_code(code):
        return None

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    with pytest.raises(live_interview.LiveSessionError):
        run(live_interview.authorize("NOPE", "sess-1"))


def test_authorize_rejects_a_revoked_code(monkeypatch):
    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1", "status": "revoked"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    with pytest.raises(live_interview.LiveSessionError):
        run(live_interview.authorize("ABC123", "sess-1"))


def test_authorize_rejects_an_expired_code(monkeypatch):
    async def fake_fetch_by_code(code):
        return {
            "code": code, "session_id": "sess-1",
            "expires_at": "2000-01-01T00:00:00+00:00",
        }

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    with pytest.raises(live_interview.LiveSessionError):
        run(live_interview.authorize("ABC123", "sess-1"))


# --- configure_session() -------------------------------------------------

def test_configure_session_disables_auto_response():
    """create_response: false is the field that stops OpenAI from ever
    free-generating a reply — this is the single most important assertion
    in this file. Shape verified against the live GA Realtime API."""
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")
    run(orch.configure_session())

    assert len(openai_ws.sent) == 1
    session = openai_ws.sent[0]["session"]
    assert session["type"] == "realtime"
    turn_detection = session["audio"]["input"]["turn_detection"]
    assert turn_detection["create_response"] is False
    assert turn_detection["interrupt_response"] is True
    # "pcm16" alone 400s live — format must be an object with a rate.
    assert session["audio"]["input"]["format"] == {"type": "audio/pcm", "rate": 24000}
    assert session["audio"]["output"]["format"] == {"type": "audio/pcm", "rate": 24000}


# --- speak() -------------------------------------------------------------

def test_speak_sends_scripted_text_not_bare_response_create():
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")
    run(orch.speak("What's your experience with distributed systems?"))

    assert len(openai_ws.sent) == 1
    event = openai_ws.sent[0]
    assert event["type"] == "response.create"
    # Must carry an explicit scripted input — a bare response.create with no
    # "input" would let the model condition on conversation history and
    # generate its own reply, which is exactly what must never happen.
    assert "input" in event["response"]
    item = event["response"]["input"][0]
    assert item["role"] == "assistant"
    # "input_text" 400s live for an assistant-authored item — must be
    # "output_text".
    assert item["content"][0]["type"] == "output_text"
    assert item["content"][0]["text"] == "What's your experience with distributed systems?"
    assert event["response"]["output_modalities"] == ["audio"]


# --- candidate utterance -> interview_session.answer() -------------------

def test_candidate_utterance_calls_answer_and_speaks_next_question(monkeypatch):
    calls = []

    async def fake_answer(session_id, answer_text, provider_override=None):
        calls.append((session_id, answer_text))
        return {
            "session_id": session_id,
            "turn": {"kind": "question", "topic": "systems-design", "question": "Tell me about caching."},
            "coverage": {},
            "analysis": {},
        }

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")

    run(orch._on_candidate_utterance("I've used Redis for caching in production."))

    assert calls == [("sess-1", "I've used Redis for caching in production.")]
    assert openai_ws.sent[-1]["type"] == "response.create"
    # Two responses now, not one: an immediate backchannel while `answer()`
    # runs its LLM analysis, then the next question carried in on a bridge
    # phrase. The question text itself is unchanged and still comes from
    # the state machine — the bridge is a scripted prefix, not a rewrite.
    spoken = [
        msg["response"]["input"][0]["content"][0]["text"]
        for msg in openai_ws.sent if msg["type"] == "response.create"
    ]
    assert spoken == ["Mm-hmm.", "Thanks. Tell me about caching."]


def test_candidate_utterance_announces_turn_to_the_ui(monkeypatch):
    """The spoken question is mirrored to the browser as text so the
    on-screen question tracks the audio instead of going stale."""
    async def fake_answer(session_id, answer_text, provider_override=None):
        return {
            "session_id": session_id,
            "turn": {"kind": "question", "topic": "systems-design", "question": "Tell me about caching."},
            "coverage": {"completion_percent": 40},
            "analysis": {},
        }

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    candidate_ws = FakeCandidateWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, FakeOpenAIWS(), "sess-1", "CODE1")

    run(orch._on_candidate_utterance("Redis, mostly."))

    announced = candidate_ws.sent_text[-1]
    assert announced["type"] == "turn"
    assert announced["turn"]["question"] == "Tell me about caching."
    assert announced["coverage"] == {"completion_percent": 40}


def test_candidate_utterance_on_completion_notifies_candidate_not_openai(monkeypatch):
    async def fake_answer(session_id, answer_text, provider_override=None):
        return {
            "session_id": session_id,
            "turn": {"kind": "complete", "topic": None, "question": None},
            "coverage": {},
            "analysis": {},
        }

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1", "CODE1")

    run(orch._on_candidate_utterance("That's everything I know."))

    # The backchannel is unavoidable here and correct: it goes out the
    # moment the candidate stops speaking, before `answer()` has run and
    # therefore before anyone knows this was the last answer. What still
    # must not happen is a further QUESTION — completion is signalled to the
    # browser, never spoken at OpenAI.
    spoken = [
        msg["response"]["input"][0]["content"][0]["text"]
        for msg in openai_ws.sent if msg["type"] == "response.create"
    ]
    assert spoken == ["Mm-hmm."]
    assert candidate_ws.sent_text[-1] == {"type": "interview_complete"}


# --- mid-interview revocation ---------------------------------------------
#
# `authorize()` used to run once, at WebSocket connect. HR revoking a code
# after the candidate was already talking to the relay did nothing: the
# socket stayed open, kept accepting audio, and the interview completed as
# if nothing had happened. `_on_candidate_utterance` now re-runs the same
# check on every turn, since that is the one point in an open connection
# where "is this credential still good" can be asked without a background
# poller.


def test_a_revoked_code_stops_the_next_utterance_from_being_answered(monkeypatch):
    answer_calls = []

    async def fake_answer(session_id, answer_text, provider_override=None):
        answer_calls.append(answer_text)
        return {"session_id": session_id, "turn": {"kind": "complete"}, "coverage": {}, "analysis": {}}

    # Revoked NOW, unlike the "accepts" fakes above — this is what HR
    # clicking "revoke" mid-interview looks like from this function's POV.
    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1", "status": "revoked"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    candidate_ws = FakeCandidateWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, FakeOpenAIWS(), "sess-1", "CODE1")

    with pytest.raises(live_interview.LiveSessionError):
        run(orch._on_candidate_utterance("Still talking, unaware anything changed."))

    # The turn was never answered — revocation is checked BEFORE the model
    # is ever asked to judge anything, not after.
    assert answer_calls == []
    # And the candidate actually sees a closed connection, not a socket that
    # silently stops responding.
    assert candidate_ws.close_codes == [1008]


def test_an_expired_code_stops_the_next_utterance_from_being_answered(monkeypatch):
    async def fake_answer(session_id, answer_text, provider_override=None):
        raise AssertionError("must not be called once the code has expired")

    async def fake_fetch_by_code(code):
        return {
            "code": code, "session_id": "sess-1",
            "expires_at": "2000-01-01T00:00:00+00:00",
        }

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    candidate_ws = FakeCandidateWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, FakeOpenAIWS(), "sess-1", "CODE1")

    with pytest.raises(live_interview.LiveSessionError):
        run(orch._on_candidate_utterance("Anything."))

    assert candidate_ws.close_codes == [1008]


# --- not every transcript is an answer ------------------------------------
#
# The typed-answer path has a submit button — an explicit act of asserting
# "this is my answer." Voice has no equivalent: every finalized transcript
# used to become an `interview_session.answer()` call unconditionally, so
# "sorry, could you repeat that?" was judged, marked unsupported, and spent
# one of the topic's limited attempts.


def test_a_clarification_request_re_asks_instead_of_being_graded(monkeypatch):
    async def fake_answer(session_id, answer_text, provider_override=None):
        raise AssertionError("a request to repeat the question must not be graded")

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    async def fake_fetch_session(session_id):
        return {"status": "in_progress", "current_topic": "systems-design",
                "last_question": "Tell me about caching."}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")

    run(orch._on_candidate_utterance("Sorry, could you repeat that?"))

    # The question got spoken again — not graded, not skipped.
    assert openai_ws.sent[-1]["response"]["input"][0]["content"][0]["text"] == "Tell me about caching."


def test_near_empty_noise_re_asks_instead_of_being_graded(monkeypatch):
    async def fake_answer(session_id, answer_text, provider_override=None):
        raise AssertionError("near-empty noise must not be graded as an answer")

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    async def fake_fetch_session(session_id):
        return {"status": "in_progress", "current_topic": "systems-design",
                "last_question": "Tell me about caching."}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")

    run(orch._on_candidate_utterance("h"))

    assert openai_ws.sent[-1]["response"]["input"][0]["content"][0]["text"] == "Tell me about caching."


def test_a_short_real_answer_still_gets_graded(monkeypatch):
    """The gate must not swallow genuinely short answers — pins that this is
    a narrow, deliberate filter, not an accidentally-broad one."""
    calls = []

    async def fake_answer(session_id, answer_text, provider_override=None):
        calls.append(answer_text)
        return {"session_id": session_id, "turn": {"kind": "complete"}, "coverage": {}, "analysis": {}}

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), FakeOpenAIWS(), "sess-1", "CODE1")

    run(orch._on_candidate_utterance("Redis."))

    assert calls == ["Redis."]


def test_a_long_answer_that_happens_to_start_with_sorry_still_gets_graded(monkeypatch):
    """Length is what tells a real answer apart from a clarification request
    — the phrase alone isn't enough, or a candidate apologizing mid-answer
    ("Sorry, I mean the primary index, not the replica...") would get
    silently discarded instead of graded."""
    calls = []

    async def fake_answer(session_id, answer_text, provider_override=None):
        calls.append(answer_text)
        return {"session_id": session_id, "turn": {"kind": "complete"}, "coverage": {}, "analysis": {}}

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), FakeOpenAIWS(), "sess-1", "CODE1")

    long_answer = (
        "Sorry, I mean the primary index handled it, not the replica — we "
        "moved the read traffic there after the migration finished."
    )
    run(orch._on_candidate_utterance(long_answer))

    assert calls == [long_answer]


# --- barge-in / interruption ---------------------------------------------

def test_speech_started_while_speaking_cancels_and_flushes():
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1", "CODE1")
    orch._state.speaking = True
    orch._state.active_response_id = "resp-1"

    run(orch._on_speech_started())

    assert {"type": "response.cancel"} in openai_ws.sent
    assert orch._state.speaking is False
    assert orch._state.active_response_id is None
    assert candidate_ws.sent_text[-1] == {"type": "flush_playback"}


def test_speech_started_while_not_speaking_is_a_noop():
    """No cancel should fire for speech that starts while the AI isn't
    talking — that's just the candidate's normal turn, not a barge-in."""
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1", "CODE1")
    orch._state.speaking = False

    run(orch._on_speech_started())

    assert openai_ws.sent == []
    assert candidate_ws.sent_text == []


def test_stale_audio_delta_after_cancel_is_dropped():
    """A response.output_audio.delta that arrives for a response we already
    cancelled must never reach the candidate — otherwise an interrupted
    question briefly resumes playing after the candidate spoke over it."""
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1", "CODE1")
    orch._state.active_response_id = None  # already cancelled

    stale_audio = base64.b64encode(b"late-audio-bytes").decode("ascii")
    run(orch._handle_openai_event({
        "type": "response.output_audio.delta",
        "response_id": "resp-CANCELLED",
        "delta": stale_audio,
    }))

    assert candidate_ws.sent_bytes == []


def test_live_audio_delta_for_active_response_is_forwarded():
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1", "CODE1")
    orch._state.active_response_id = "resp-1"

    audio_bytes = b"real-audio-bytes"
    run(orch._handle_openai_event({
        "type": "response.output_audio.delta",
        "response_id": "resp-1",
        "delta": base64.b64encode(audio_bytes).decode("ascii"),
    }))

    assert candidate_ws.sent_bytes == [audio_bytes]


# --- speak_current_turn() -------------------------------------------------

def test_speak_current_turn_speaks_the_pending_question(monkeypatch):
    async def fake_fetch_session(session_id):
        return {"status": "in_progress", "current_topic": "systems-design", "last_question": "Tell me about caching."}

    monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")

    spoke = run(orch.speak_current_turn())

    assert spoke is True
    assert openai_ws.sent[-1]["response"]["input"][0]["content"][0]["text"] == "Tell me about caching."


def test_speak_current_turn_returns_false_when_already_complete(monkeypatch):
    async def fake_fetch_session(session_id):
        return {"status": "complete", "current_topic": None, "last_question": None}

    monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1", "CODE1")

    spoke = run(orch.speak_current_turn())

    assert spoke is False
    assert openai_ws.sent == []
