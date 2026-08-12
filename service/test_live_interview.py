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

    async def send_text(self, data: str) -> None:
        self.sent_text.append(json.loads(data))

    async def send_bytes(self, data: bytes) -> None:
        self.sent_bytes.append(data)

    async def receive(self) -> dict:
        return {"type": "websocket.disconnect"}

    async def close(self, code: int = 1000) -> None:
        pass


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


# --- configure_session() -------------------------------------------------

def test_configure_session_disables_auto_response():
    """create_response: false is the field that stops OpenAI from ever
    free-generating a reply — this is the single most important assertion
    in this file. Shape verified against the live GA Realtime API."""
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1")
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
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1")
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

    monkeypatch.setattr(interview_session, "answer", fake_answer)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1")

    run(orch._on_candidate_utterance("I've used Redis for caching in production."))

    assert calls == [("sess-1", "I've used Redis for caching in production.")]
    assert openai_ws.sent[-1]["type"] == "response.create"
    assert openai_ws.sent[-1]["response"]["input"][0]["content"][0]["text"] == "Tell me about caching."


def test_candidate_utterance_on_completion_notifies_candidate_not_openai(monkeypatch):
    async def fake_answer(session_id, answer_text, provider_override=None):
        return {
            "session_id": session_id,
            "turn": {"kind": "complete", "topic": None, "question": None},
            "coverage": {},
            "analysis": {},
        }

    monkeypatch.setattr(interview_session, "answer", fake_answer)
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1")

    run(orch._on_candidate_utterance("That's everything I know."))

    assert openai_ws.sent == []  # no further speech requested from OpenAI
    assert candidate_ws.sent_text[-1] == {"type": "interview_complete"}


# --- barge-in / interruption ---------------------------------------------

def test_speech_started_while_speaking_cancels_and_flushes():
    candidate_ws = FakeCandidateWS()
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1")
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
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1")
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
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1")
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
    orch = live_interview.LiveOrchestrator(candidate_ws, openai_ws, "sess-1")
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
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1")

    spoke = run(orch.speak_current_turn())

    assert spoke is True
    assert openai_ws.sent[-1]["response"]["input"][0]["content"][0]["text"] == "Tell me about caching."


def test_speak_current_turn_returns_false_when_already_complete(monkeypatch):
    async def fake_fetch_session(session_id):
        return {"status": "complete", "current_topic": None, "last_question": None}

    monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(FakeCandidateWS(), openai_ws, "sess-1")

    spoke = run(orch.speak_current_turn())

    assert spoke is False
    assert openai_ws.sent == []
