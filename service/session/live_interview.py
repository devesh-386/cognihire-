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
from datetime import datetime, timezone
from typing import Awaitable, Callable, Protocol

from pipeline import supabase_store
from session import codes_store, interview_session, session_store
from session.events import EventType

logger = logging.getLogger("cognihire.live_interview")

# GA API (verified live 2026-08-12) — no OpenAI-Beta header, model is
# gpt-realtime-2, not the retired gpt-4o-realtime-preview.
OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime?model=gpt-realtime-2"

# Question/followup text is what gets spoken; other turn kinds (complete)
# have no question text to speak — see _speak_turn.
_SPEAKABLE_KINDS = {"question", "followup"}

# A finalized OpenAI transcript used to become an `interview_session.answer()`
# call unconditionally — there was no notion of "that wasn't actually an
# answer." The text-typing path has an explicit submit button; a candidate
# asserts "this is my answer" by clicking it. Voice has no equivalent act, so
# "sorry, could you repeat that?" was graded as the candidate's answer,
# judged unsupported, and spent one of `_MAX_ATTEMPTS_PER_TOPIC` (see
# ai/coverage_manager.py) — two clarifying questions and a topic the
# candidate was never actually asked to substantiate twice gets written off
# as "not supported" in the report a recruiter reads.
#
# This is a narrow, conservative gate, not a classifier: it only catches
# short, unambiguous "I didn't catch that" phrasing. A real answer that
# happens to start with "sorry, I mean..." still matches none of these
# (checked against the whole utterance, and these are complete short
# utterances in the training/eval sense — a longer utterance containing one
# of these substrings is deliberately still treated as a real answer,
# enforced by `_LOOKS_LIKE_CLARIFICATION_MAX_CHARS` below).
_CLARIFICATION_PHRASES = (
    "sorry", "come again", "one more time", "repeat that", "repeat the question",
    "say that again", "what was the question", "could you repeat",
    "can you repeat", "didn't catch that", "didn't hear that", "pardon",
)
# A genuine "please repeat" is short. Capped so a real, substantial answer
# that happens to contain "sorry" (e.g. "I'm sorry to say the migration
# failed, so we...") is never caught by this gate — length is what tells
# the two apart, not the phrase alone.
_LOOKS_LIKE_CLARIFICATION_MAX_CHARS = 60

# Below this, a "transcript" is VAD noise, not speech — a stray sound
# finalized into one or two characters. Real short answers ("Yes.", "No.")
# clear this easily; it exists only to stop empty/near-empty noise from
# being graded as a substantive answer.
_MIN_SUBSTANTIVE_UTTERANCE_CHARS = 2

# The same problem `_CLARIFICATION_PHRASES` solves, for the other thing
# candidates say that isn't an answer: hello.
#
# "Hi, this is Devesh here" was being handed to `interview_session.answer()`
# like any other utterance — analysed against a technical claim by a full
# LLM call, judged unsupported because a greeting supports nothing, and
# charged one of `_MAX_ATTEMPTS_PER_TOPIC`. A candidate who opens politely
# lost an attempt on a topic before being asked about it once, and the
# recruiter's report carried an "unsupported" verdict earned by saying
# hello.
#
# It is also the slowest possible way to not answer: that LLM analysis sits
# between the candidate finishing their sentence and hearing anything back,
# so the first thing a greeting gets is several seconds of silence.
#
# Same conservative shape as the clarification gate — a short, unambiguous
# opener, matched against the WHOLE utterance and length-capped, so a real
# answer that happens to begin "Hi, so the way I approached the migration
# was..." is never caught by it.
_GREETING_PHRASES = (
    "hi", "hii", "hey", "hello", "helo", "yo",
    "good morning", "good afternoon", "good evening", "greetings",
    "this is", "my name is", "i am", "i'm", "im ",
    "nice to meet you", "how are you",
)
# A greeting is short. Long enough for "Good morning, my name is Devesh S V
# and I'm here for the backend role"; short enough that a substantive answer
# opening with a pleasantry falls through to real grading.
_LOOKS_LIKE_GREETING_MAX_CHARS = 90

# What a person says while they are still listening to you.
#
# The candidate finishes a sentence and then hears nothing, because
# `interview_session.answer()` runs a full LLM analysis before there is a
# next question to speak. Several seconds of dead air after every answer is
# what makes this feel like dictation into a form rather than a
# conversation. These go out the instant the transcript lands, so the pause
# is filled while the real work happens behind it.
#
# Deliberately empty of judgement. "Mm-hmm" says *I heard you*; "great
# answer" would say *I rated you*, which is a disposition, expressed to the
# candidate, mid-interview — the one thing ED-14 and ED-46 exist to keep
# out of this system. A warmer noise is not worth becoming an AI that
# grades people to their face.
#
# Rotated rather than random so the same answer twice does not get the same
# noise twice, and so tests can assert on the sequence.
_BACKCHANNELS = ("Mm-hmm.", "I see.", "Right.", "Okay.", "Got it.")

# Carries the conversation into the next question instead of jumping
# straight to it. Same rule as above: acknowledges, never appraises.
_QUESTION_BRIDGES = ("Thanks.", "Understood.", "Okay.", "Right.")

# How long to wait for a backchannel to finish before speaking the next
# question. The Realtime API rejects a second `response.create` while one
# is active, and a backchannel is under a second of audio against an
# analysis measured in seconds, so this should never be reached — it exists
# so a wedged response cannot silently strand the interview instead of
# asking the next question slightly early.
_SPEECH_SETTLE_TIMEOUT_SECONDS = 5.0


def _is_greeting(text: str) -> bool:
    """True for a short opener that is social, not substantive.

    Anchored at the start rather than searched anywhere in the utterance:
    "hi" appears inside "architecture" and "this is" inside "this is how we
    sharded it", and either would silently stop a real answer from being
    graded — a far worse failure than missing a greeting.
    """
    stripped = text.strip()
    if len(stripped) > _LOOKS_LIKE_GREETING_MAX_CHARS:
        return False
    lowered = stripped.lower().lstrip("“\"'")
    return any(lowered.startswith(phrase) for phrase in _GREETING_PHRASES)


def _first_name(full_name: str | None) -> str | None:
    """The candidate's own name, as they gave it on the application form —
    never anything the model produced. Title-cased because intake stores
    whatever was typed ("devesh s v") and a greeting should not read as
    though it were shouted or mumbled."""
    if not full_name:
        return None
    first = full_name.strip().split()
    return first[0].title() if first else None


def _is_clarification_request(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) > _LOOKS_LIKE_CLARIFICATION_MAX_CHARS:
        return False
    lowered = stripped.lower()
    return any(phrase in lowered for phrase in _CLARIFICATION_PHRASES)


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
    import — main.py imports from `session`, never the reverse. Keep the two
    in sync by hand.

    Called at WebSocket handshake AND again from `_on_candidate_utterance`
    on every turn — the handshake alone only stops a NEW connection attempt
    made after a revocation; a socket already open when HR revokes stays
    open and keeps accepting audio until the candidate next speaks. That
    residual window (revoked mid-silence, no further check until the
    candidate's next utterance) is real and not closed by this function
    alone — see `_on_candidate_utterance`'s own comment for why a full fix
    (a background poll independent of candidate speech) is deliberately
    out of scope here."""
    try:
        code_row = await codes_store.fetch_by_code(code)
    except supabase_store.SupabaseError as exc:
        raise LiveSessionError(f"code lookup failed: {exc}") from exc
    if code_row is None or code_row.get("session_id") != session_id:
        raise LiveSessionError("that code does not match this interview session")
    if code_row.get("status") == "revoked":
        raise LiveSessionError("this interview code has been revoked")
    expires_at = code_row.get("expires_at")
    if expires_at and datetime.fromisoformat(expires_at) < datetime.now(timezone.utc):
        raise LiveSessionError("this interview code has expired")


def _finished_event() -> asyncio.Event:
    """An Event that starts SET — "not currently speaking" is the initial
    truth, and a cleared Event would make the first question wait out the
    settle timeout before being asked."""
    event = asyncio.Event()
    event.set()
    return event


@dataclass
class _State:
    """Mutable state for one live session's lifetime — grouped so
    `LiveOrchestrator`'s methods aren't juggling a pile of loose locals."""

    active_response_id: str | None = None
    speaking: bool = False
    pending_item_ids: set[str] = field(default_factory=set)
    # Set whenever nothing is being spoken, so a caller can wait for the
    # channel to go quiet before starting the next response rather than
    # polling `speaking`. Starts set: at connect time nothing is speaking.
    speech_finished: asyncio.Event = field(default_factory=_finished_event)
    # One rotation counter per phrase list. Sharing a single counter across
    # both made the bridge depend on how many backchannels had been spoken,
    # which is neither meaningful nor predictable.
    filler_indices: dict[int, int] = field(default_factory=dict)


class LiveOrchestrator:
    """Owns one candidate<->OpenAI relay for the lifetime of a live
    interview WS connection. Constructed with an already-open OpenAI
    connection so tests can inject a fake — this class never calls
    `websockets.connect` itself (see `run_live_session`, which does)."""

    def __init__(
        self, candidate_ws: CandidateConnection, openai_ws: OpenAIRealtimeConnection,
        session_id: str, code: str,
    ):
        self.candidate_ws = candidate_ws
        self.openai_ws = openai_ws
        self.session_id = session_id
        # Kept so `_on_candidate_utterance` can re-check ownership/status on
        # every turn, not just once at connect — see `authorize`'s own
        # comment on why a WebSocket needs this where an HTTP route doesn't.
        self.code = code
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
        started).

        Shape verified live end-to-end against the GA Realtime API (the
        Beta shape — flat `input_audio_format`/`output_audio_format`
        strings, no `session.type` — was fully removed 2026-05-12 and 400s
        with `beta_api_shape_disabled`). `format` is an object with both
        `type` (`audio/pcm`, `audio/pcmu`, or `audio/pcma` — a bare
        `"pcm16"` string 400s) and a required `rate` — confirmed via a
        `session.updated` echo showing `create_response: false,
        interrupt_response: true` actually applied, not just accepted."""
        await self._send_openai({
            "type": "session.update",
            "session": {
                "type": "realtime",
                "audio": {
                    "input": {
                        "format": {"type": "audio/pcm", "rate": 24000},
                        "turn_detection": {
                            "type": "server_vad",
                            "create_response": False,
                            "interrupt_response": True,
                        },
                    },
                    "output": {
                        "format": {"type": "audio/pcm", "rate": 24000},
                        "voice": "alloy",
                    },
                },
            },
        })

    async def speak(self, text: str) -> None:
        """The only path that ever produces AI speech. Never a bare
        `response.create` conditioned on conversation history — always a
        scripted item with `output_modalities: ["audio"]`, so OpenAI
        performs TTS on exactly this text rather than generating its own
        reply.

        Content type is `output_text`, not `input_text` — verified against
        the live API, which 400s an assistant-authored item's content with
        `invalid_value: 'input_text'. Value must be 'output_text'`."""
        await self._send_openai({
            "type": "response.create",
            "response": {
                "input": [{
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": text}],
                }],
                "output_modalities": ["audio"],
            },
        })

    async def _announce_turn(self, turn: dict, coverage: dict | None = None) -> None:
        """Mirrors the spoken question to the candidate's UI as text, so the
        on-screen question and progress stay in step with the audio — the
        same fields `POST /interview/answer` already returns, just pushed
        instead of polled. Display only; the audio is the real channel."""
        await self.candidate_ws.send_text(json.dumps({
            "type": "turn",
            "turn": turn,
            "coverage": coverage,
        }))

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
        await self._announce_turn(turn, row.get("coverage_state"))
        await self.speak(turn["question"])
        return True

    async def _on_candidate_utterance(self, text: str) -> None:
        """The one place a voice event becomes a call into the EXACT same
        state machine `POST /interview/answer` uses — same function, same
        signature, just a different caller.

        Re-authorizes first. This is the fix's actual enforcement point: HR
        revoking a code while a candidate is silent (nothing to trigger a
        check) leaves the socket open until the candidate next speaks, but
        the moment they do, this runs before that speech becomes another
        answer. Closes the socket itself (not just raises) so the candidate
        sees a clean disconnect rather than the connection going silently
        dead — see `run`'s `finally` for why raising alone wouldn't produce
        that."""
        try:
            await authorize(self.code, self.session_id)
        except LiveSessionError as exc:
            await self.candidate_ws.close(code=1008)
            raise LiveSessionError(f"revoked mid-interview: {exc}") from exc

        # Not every finalized transcript is an answer — see the module-level
        # comment on `_CLARIFICATION_PHRASES`. Re-speaking the pending
        # question costs nothing against the interview state machine: no
        # `answer()` call, no attempt spent, no event appended. If the
        # session somehow has nothing left to speak (a narrow race with the
        # session completing elsewhere), fall through silently rather than
        # telling the candidate to hold on for a question that isn't coming.
        stripped = text.strip()
        if len(stripped) < _MIN_SUBSTANTIVE_UTTERANCE_CHARS or _is_clarification_request(stripped):
            await self.speak_current_turn()
            return

        # Greeted, not answered. Handled before `answer()` so it costs no
        # LLM call and no attempt — which is also what makes it fast: the
        # candidate hears their name back immediately instead of waiting
        # out an analysis of a sentence that was never an answer.
        if _is_greeting(stripped):
            await self._greet_back()
            return

        # Said before the analysis, not after — that is the whole point.
        # `answer()` runs an LLM call, and until this existed the candidate
        # got several seconds of silence at the end of every answer.
        await self._backchannel()

        result = await interview_session.answer(self.session_id, text)
        turn = result["turn"]
        if turn["kind"] in _SPEAKABLE_KINDS and turn.get("question"):
            await self._announce_turn(turn, result.get("coverage"))
            # One response at a time: the Realtime API rejects a second
            # `response.create` while the backchannel is still playing.
            await self._wait_until_quiet()
            await self.speak(f"{self._next_filler(_QUESTION_BRIDGES)} {turn['question']}")
        else:
            await self._wait_until_quiet()
            await self.candidate_ws.send_text(json.dumps({"type": "interview_complete"}))

    def _next_filler(self, phrases: tuple[str, ...]) -> str:
        """Rotates through `phrases` so the same answer twice never draws
        the same noise twice — which is what makes canned acknowledgement
        sound canned.

        Counters are per phrase list, keyed by identity: a backchannel
        spoken between two questions must not shift which bridge comes
        next.
        """
        key = id(phrases)
        index = self._state.filler_indices.get(key, 0)
        self._state.filler_indices[key] = index + 1
        return phrases[index % len(phrases)]

    async def _backchannel(self) -> None:
        """The "mm-hmm" a listener gives while still thinking.

        Scripted and spoken through `speak` like everything else, so the
        model still authors nothing. It acknowledges being heard and says
        nothing about quality: an interviewer that tells a candidate their
        answer was good has expressed a disposition to them mid-interview,
        which is exactly what this system promises it does not do.

        Best-effort. If the channel cannot take it the interview must carry
        on regardless — a missing "mm-hmm" is a worse-feeling interview, a
        raised exception here would be no interview at all.
        """
        try:
            await self.speak(self._next_filler(_BACKCHANNELS))
        except Exception:  # noqa: BLE001 - deliberately never fatal
            logger.warning("backchannel failed", exc_info=True)

    async def _wait_until_quiet(self) -> None:
        """Blocks until nothing is being spoken, or the settle timeout.

        On timeout it returns anyway rather than raising: asking the next
        question a moment early is a far smaller failure than an interview
        that stops asking questions.
        """
        try:
            await asyncio.wait_for(
                self._state.speech_finished.wait(),
                timeout=_SPEECH_SETTLE_TIMEOUT_SECONDS,
            )
        except asyncio.TimeoutError:
            logger.warning("speech did not settle within the timeout; continuing")

    async def _greet_back(self) -> None:
        """Answer a greeting with a greeting, then ask the pending question
        again so the interview picks up where it was.

        The wording is ours and the name is the candidate's own, read from
        the record intake created. Nothing here is model-authored: OpenAI
        performs TTS on this exact string via `speak`, the same muzzled
        path every question goes through. Letting the model improvise a
        reply would be the one place in this system where it speaks for
        itself, and a warmer hello is not worth that.

        A failure to read the name is not a failure to greet — the
        candidate said hello and deserves an answer either way, so the
        nameless form is used rather than falling through to grading a
        greeting.
        """
        name = None
        try:
            row = await session_store.fetch_session(self.session_id)
            if row and row.get("candidate_id"):
                candidate = await supabase_store.fetch_candidate(row["candidate_id"])
                name = _first_name((candidate or {}).get("name"))
        except supabase_store.SupabaseError:
            logger.warning("greeting: could not read candidate name", exc_info=True)

        greeting = (
            f"Hi {name}, nice to meet you." if name else "Hi, nice to meet you."
        )
        await self.speak(greeting)
        await self.speak_current_turn()

    async def _echo_candidate_transcript(self, text: str) -> None:
        """Send the candidate their own words back, for display only.

        In the typed path a candidate watches their answer appear in the
        textarea as they speak it. In live voice they saw nothing at all:
        no way to tell "it heard me and I said that" from "it misheard me"
        until the report, by which point the interview is over. Speaking
        into a screen that never acknowledges you is also what made the
        live channel feel less like a conversation than the typed fallback,
        despite being the more capable of the two.

        Display only — grading is unchanged and still runs off the same
        transcript in `_on_candidate_utterance`, which applies its own
        clarification and attempt-spending rules. Nothing here can affect
        what reaches the report.

        Noise is filtered with the same threshold the state machine uses,
        so a stray sound finalized into one character never flashes on
        screen as though the candidate said it. A clarification request
        ("sorry, could you repeat that?") IS echoed, deliberately: the
        candidate really said it, and seeing it is how they know the system
        heard them ask rather than ignored them.
        """
        stripped = text.strip()
        if len(stripped) < _MIN_SUBSTANTIVE_UTTERANCE_CHARS:
            return
        await self.candidate_ws.send_text(json.dumps({
            "type": "candidate_transcript", "text": stripped,
        }))

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
        # Releases anyone waiting on the channel going quiet. Without this,
        # a candidate talking over a backchannel would strand the next
        # question until the settle timeout expired.
        self._state.speech_finished.set()
        await self.candidate_ws.send_text(json.dumps({"type": "flush_playback"}))

    async def _handle_openai_event(self, event: dict) -> None:
        event_type = event.get("type")

        if event_type == "response.created":
            self._state.active_response_id = event.get("response", {}).get("id")
            self._state.speaking = True
            self._state.speech_finished.clear()

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
                self._state.speech_finished.set()

        elif event_type == "input_audio_buffer.speech_started":
            await self._on_speech_started()

        elif event_type == "conversation.item.input_audio_transcription.completed":
            transcript = (event.get("transcript") or "").strip()
            if transcript:
                await self._echo_candidate_transcript(transcript)
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
            done, _ = await asyncio.wait(
                [candidate_task, openai_task], return_when=asyncio.FIRST_COMPLETED,
            )
            # `asyncio.wait` never raises a task's exception itself — it
            # just reports the task as done, exception attached and
            # otherwise silent. Without retrieving it here, a mid-interview
            # revocation (see `_on_candidate_utterance`) would end the call
            # with no trace of why, the same blind spot the OpenAI-error
            # branch in `_handle_openai_event` already logs instead of
            # swallowing.
            for task in done:
                exc = task.exception() if task.cancelled() is False else None
                if exc is not None and not isinstance(exc, asyncio.CancelledError):
                    logger.warning(
                        "live interview session %s ended: %s", self.session_id, exc,
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
    # No OpenAI-Beta header — the GA endpoint 400s with
    # beta_api_shape_disabled if it's present (verified live).
    return await websockets.connect(
        OPENAI_REALTIME_URL,
        additional_headers={"Authorization": f"Bearer {api_key}"},
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
        orchestrator = LiveOrchestrator(candidate_ws, openai_ws, session_id, code)
        await orchestrator.run()
    finally:
        await openai_ws.close()
