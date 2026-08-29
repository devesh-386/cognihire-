"""The Realtime session must ask OpenAI to transcribe the candidate.

The relay is built entirely on one event —
`conversation.item.input_audio_transcription.completed`. The handler for it
was written when the relay was added (ea87b42); the session config that
makes OpenAI emit it never was.

Nothing errored. The AI asked its first question, the candidate answered,
and `_on_candidate_utterance` simply never ran — so `answer()` was never
called, no topic advanced, no event was written, and the interview sat on
question one looking perfectly alive. Reported as "the responses were all
good, but it was not like a conversation."

Every voice feature hangs off that event: grading, the transcript echo, the
greeting, the backchannel. A test on the config is the only place this is
catchable without a live OpenAI socket and a human talking into it.
"""

from __future__ import annotations

import asyncio
import json

from session import live_interview


def run(coro):
    return asyncio.run(coro)


class FakeOpenAIWS:
    def __init__(self):
        self.sent: list[dict] = []

    async def send(self, raw):
        self.sent.append(json.loads(raw))


def _session_update() -> dict:
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator.__new__(live_interview.LiveOrchestrator)
    orch.openai_ws = openai_ws
    run(orch.configure_session())
    updates = [m for m in openai_ws.sent if m.get("type") == "session.update"]
    assert len(updates) == 1, f"expected exactly one session.update, got {len(updates)}"
    return updates[0]["session"]


def test_transcription_is_requested():
    """The bug. Without this key OpenAI transcribes nothing and the relay
    receives no utterances at all."""
    audio_input = _session_update()["audio"]["input"]

    assert "transcription" in audio_input, (
        "no transcription config — conversation.item.input_audio_transcription"
        ".completed will never fire and no answer will ever be graded"
    )
    assert audio_input["transcription"].get("model")


def test_transcription_ships_in_the_same_update_as_the_muzzle():
    """A follow-up session.update carrying only `audio.input.transcription`
    risks replacing the whole `audio.input` object and taking
    `turn_detection` with it. Losing `create_response: false` would let
    OpenAI answer the candidate in its own words — the one thing this relay
    exists to prevent. So both must travel together."""
    audio_input = _session_update()["audio"]["input"]

    assert audio_input["turn_detection"]["create_response"] is False
    assert "transcription" in audio_input


def test_the_muzzle_is_still_in_place():
    """Pinned alongside, because the tempting way to "fix" a transcription
    problem is to start letting the model respond on its own."""
    audio_input = _session_update()["audio"]["input"]

    assert audio_input["turn_detection"]["type"] == "server_vad"
    assert audio_input["turn_detection"]["create_response"] is False
    assert audio_input["turn_detection"]["interrupt_response"] is True


def test_audio_format_and_rate_survive_the_addition():
    """The rate must keep matching the browser's AudioContext (24 kHz in
    live-voice-client.js); the API rejects a mismatch outright."""
    audio = _session_update()["audio"]

    assert audio["input"]["format"] == {"type": "audio/pcm", "rate": 24000}
    assert audio["output"]["format"] == {"type": "audio/pcm", "rate": 24000}


def test_the_transcription_model_is_overridable_without_a_redeploy(monkeypatch):
    """A model id the API stops accepting rejects the entire session.update,
    muzzle included. Being able to change it on the host is the difference
    between an env edit and an emergency deploy."""
    import importlib

    monkeypatch.setenv("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-transcribe")
    reloaded = importlib.reload(live_interview)
    try:
        assert reloaded._TRANSCRIPTION_MODEL == "gpt-4o-transcribe"
    finally:
        monkeypatch.delenv("OPENAI_TRANSCRIBE_MODEL", raising=False)
        importlib.reload(live_interview)
