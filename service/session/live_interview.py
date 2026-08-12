"""Real-time voice relay for interview sessions.

The candidate's browser holds a WebSocket to us; we hold a second WebSocket
to OpenAI's Realtime API. OpenAI is used PURELY as a speech engine — server
VAD for turn/interruption detection, STT for what the candidate said, TTS
for what we tell it to say — never as a second brain deciding what the AI
asks. Every question this module speaks comes from `interview_session.
answer()`/`next_turn()`, the exact same state machine `POST /interview/
answer` already drives; this module only changes what triggers it (a
finalized voice utterance instead of an HTTP POST) and what speaks the
result (OpenAI's TTS instead of the browser's local TTS).

`session.turn_detection.create_response` is set to `false` specifically so
OpenAI's VAD fires `input_audio_buffer.speech_started`/`speech_stopped` for
turn-boundary and barge-in detection WITHOUT ever auto-generating its own
reply. This module is the only thing that ever calls `response.create`, and
always with text `interview_session.answer()` already decided — never a
bare, un-forced `response.create` that would let the model free-run.

Barge-in note: an interruption never touches `interview_session.py`'s state
machine. `answer()` only fires once, on the finalized transcript of what the
candidate actually said — being cut off mid-question is purely an audio-
layer event (stop talking, start listening), absorbed entirely here.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Protocol

from pipeline import supabase_store
from session import codes_store, interview_session, session_store
from session.events import EventType

logger = logging.getLogger("cognihire.live_interview")

OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview"

# Question/followup text is what gets spoken; other turn kinds (complete)
# have no question text to speak — see _speak_turn.
_SPEAKABLE_KINDS = {"question", "followup"}


class LiveSessionError(RuntimeError):
    """A live voice session could not be authorized or started — the caller
    (main.py's WS route) maps this to closing the socket with a clear
    reason, never a silent hang."""


class OpenAIRealtimeConnection(Protocol):
    """The minimal interface this module needs from an OpenAI Realtime WS
    connection — narrow on purpose so tests substitute a fake without a
    real network connection. Matches the subset of `websockets`' client API
    actually used below."""

    async def send(self, message: str) -> None: ...
    async def recv(self) -> str: ...
    async def close(self) -> None: ...


class CandidateConnection(Protocol):
    """The minimal interface this module needs from the candidate's
    WebSocket. FastAPI's WebSocket satisfies this."""

    async def send_text(self, data: str) -> None: ...
    async def send_bytes(self, data: bytes) -> None: ...
    async def receive(self) -> dict: ...
    async def close(self, code: int = 1000) -> None: ...


async def authorize(code: str, session_id: str) -> None:
    """Same check as `_require_code_owns_session` in main.py, reimplemented
    here (not imported) to avoid a main.py <-> session-package circular
    import — main.py imports from `session`, never the reverse."""
    try:
        code_row = await codes_store.fetch_by_code(code)
    except supabase_store.SupabaseError as exc:
        raise LiveSessionError(f"code lookup failed: {exc}") from exc
    if code_row is None or code_row.get("session_id") != session_id:
        raise LiveSessionError("that code does not match this interview session")


@dataclass
class _State:
    """Mutable state for one live session's lifetime — grouped so
    `LiveOrchestrator`'s methods aren't juggling a pile of loose locals."""

    active_response_id: str | None = None
    speaking: bool = False
    pending_item_ids: set[str] = field(default_factory=set)


class LiveOrchestrator:
    """Owns one candidate<->OpenAI relay for the lifetime of a live
    interview WS connection. Constructed with an already-open OpenAI
    connection so tests can inject a fake — this class never calls
    `websockets.connect` itself (see `run_live_session`, which does)."""

    def __init__(self, candidate_ws: CandidateConnection, openai_ws: OpenAIRealtimeConnection, session_id: str):
        self.candidate_ws = candidate_ws
        self.openai_ws = openai_ws
        self.session_id = session_id
        self._state = _State()

    async def _send_openai(self, event: dict) -> None:
        await self.openai_ws.send(json.dumps(event))

    async def configure_session(self) -> None:
        """`create_response: false` is the load-bearing field here — see
        this module's docstring. `interrupt_response: true` lets OpenAI's
        own VAD cancel an in-flight response the instant new speech starts,
        which we still confirm/finish handling in `_on_speech_started`
        rather than assuming it alone is sufficient (a `response.cancel`
        we send ourselves is idempotent against one OpenAI already
        started)."""
        await self._send_openai({
            "type": "session.update",
            "session": {
                "turn_detection": {
                    "type": "server_vad",
                    "create_response": False,
                    "interrupt_response": True,
                },
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
            },
        })

    async def speak(self, text: str) -> None:
        """The only path that ever produces AI speech. Never a bare
        `response.create` conditioned on conversation history — always a
        scripted item with `output_modalities: ["audio"]`, so OpenAI
        performs TTS on exactly this text rather than generating its own
        reply."""
        await self._send_openai({
            "type": "response.create",
            "response": {
                "input": [{
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "input_text", "text": text}],
                }],
                "output_modalities": ["audio"],
            },
        })

    async def speak_current_turn(self) -> bool:
        """Speaks whatever question the session is currently waiting on —
        called once at connect time (greet with the pending question
        without waiting for the candidate to speak first) and again after
        each `answer()` call. Returns False if the session is already
        complete (nothing to speak, caller should end the call)."""
        row = await session_store.fetch_session(self.session_id)
        if row is None:
            raise LiveSessionError(f"no session {self.session_id}")
        turn = interview_session.current_turn(row)
        if turn["kind"] not in _SPEAKABLE_KINDS or not turn.get("question"):
            return False
        await self.speak(turn["question"])
        return True

    async def _on_candidate_utterance(self, text: str) -> None:
        """The one place a voice event becomes a call into the EXACT same
        state machine `POST /interview/answer` uses — same function, same
        signature, just a different caller."""
        result = await interview_session.answer(self.session_id, text)
        turn = result["turn"]
        if turn["kind"] in _SPEAKABLE_KINDS and turn.get("question"):
            await self.speak(turn["question"])
        else:
            await self.candidate_ws.send_text(json.dumps({"type": "interview_complete"}))

    async def _on_speech_started(self) -> None:
        """Barge-in: cancel whatever OpenAI is speaking, tell the browser
        to flush already-buffered audio (audio already sent can't be
        recalled from here), and drop the active response id so any
        in-flight `response.output_audio.delta` for the cancelled response
        gets ignored by `_handle_openai_event` instead of resuming
        playback of a question the candidate already talked over."""
        if not self._state.speaking:
            return
        await self._send_openai({"type": "response.cancel"})
        self._state.active_response_id = None
        self._state.speaking = False
        await self.candidate_ws.send_text(json.dumps({"type": "flush_playback"}))

    async def _handle_openai_event(self, event: dict) -> None:
        event_type = event.get("type")

        if event_type == "response.created":
            self._state.active_response_id = event.get("response", {}).get("id")
            self._state.speaking = True

        elif event_type == "response.output_audio.delta":
            response_id = event.get("response_id")
            # Stale delta for a response we already cancelled — drop it,
            # not forward it, so interrupted audio never resumes playing.
            if response_id != self._state.active_response_id:
                return
            audio_bytes = base64.b64decode(event.get("delta", ""))
            await self.candidate_ws.send_bytes(audio_bytes)

        elif event_type in ("response.output_audio.done", "response.done", "response.cancelled"):
            if event.get("response_id", self._state.active_response_id) == self._state.active_response_id:
                self._state.speaking = False
                self._state.active_response_id = None

        elif event_type == "input_audio_buffer.speech_started":
            await self._on_speech_started()

        elif event_type == "conversation.item.input_audio_transcription.completed":
            transcript = (event.get("transcript") or "").strip()
            if transcript:
                await self._on_candidate_utterance(transcript)

        elif event_type == "error":
            logger.warning("OpenAI Realtime error for session %s: %s", self.session_id, event.get("error"))

    async def forward_candidate_audio(self, frame: bytes) -> None:
        """Browser mic audio -> OpenAI's input buffer. PCM16, matching the
        `input_audio_format` configured in `configure_session`."""
        await self._send_openai({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(frame).decode("ascii"),
        })

    async def run(self) -> None:
        """Two concurrent loops: candidate audio -> OpenAI, and OpenAI
        events -> either forwarded audio or a turn transition. Exits when
        either side closes or the interview completes."""

        async def pump_candidate() -> None:
            while True:
                message = await self.candidate_ws.receive()
                if message.get("type") == "websocket.disconnect":
                    return
                data = message.get("bytes")
                if data:
                    await self.forward_candidate_audio(data)

        async def pump_openai() -> None:
            while True:
                raw = await self.openai_ws.recv()
                await self._handle_openai_event(json.loads(raw))

        await self.configure_session()
        if not await self.speak_current_turn():
            await self.candidate_ws.send_text(json.dumps({"type": "interview_complete"}))
            return

        candidate_task = asyncio.ensure_future(pump_candidate())
        openai_task = asyncio.ensure_future(pump_openai())
        try:
            await asyncio.wait(
                [candidate_task, openai_task], return_when=asyncio.FIRST_COMPLETED,
            )
        finally:
            candidate_task.cancel()
            openai_task.cancel()


ConnectOpenAI = Callable[[], Awaitable[OpenAIRealtimeConnection]]


async def _default_connect_openai() -> OpenAIRealtimeConnection:
    import websockets

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise LiveSessionError("OPENAI_API_KEY is not configured")
    return await websockets.connect(
        OPENAI_REALTIME_URL,
        additional_headers={
            "Authorization": f"Bearer {api_key}",
            "OpenAI-Beta": "realtime=v1",
        },
    )


async def run_live_session(
    candidate_ws: CandidateConnection,
    session_id: str,
    code: str,
    connect_openai: ConnectOpenAI = _default_connect_openai,
) -> None:
    """Entrypoint called by main.py's WS route. `connect_openai` defaults to
    a real OpenAI connection but is swappable — this is the only seam
    `main.py` needs; everything else is `LiveOrchestrator`, which never
    touches the network directly itself."""
    await authorize(code, session_id)
    openai_ws = await connect_openai()
    try:
        orchestrator = LiveOrchestrator(candidate_ws, openai_ws, session_id)
        await orchestrator.run()
    finally:
        await openai_ws.close()
