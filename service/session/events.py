"""The append-only turn-by-turn log for one interview session.

Every state-changing thing the orchestrator does gets one event, in order.
This is what makes a session replayable and auditable after the fact — the
`interview_sessions` row holds only the current state, but `interview_events`
holds how it got there, which is what a transparent report (Ticket 13) reads.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum


class EventType(str, Enum):
    SESSION_STARTED = "session_started"
    QUESTION = "question"
    FOLLOWUP = "followup"
    ANSWER = "answer"
    ANALYSIS = "analysis"
    COVERAGE_UPDATE = "coverage_update"
    SESSION_COMPLETE = "session_complete"
    SESSION_ABANDONED = "session_abandoned"
    SESSION_TIME_EXPIRED = "session_time_expired"

    # Client-observed signals, recorded as-is — never a verdict. The report
    # layer surfaces these as counts ("3 tab visibility changes"), never as
    # "candidate cheated". See ADAPTIVE_INTERVIEW_ENGINE_DESIGN.md /
    # PRODUCT_OVERVIEW.md for why: a browser cannot reliably attribute a tab
    # switch to cheating vs. a dropped notes app, so this layer only records,
    # it never interprets.
    FACE_VERIFICATION = "face_verification"
    TAB_HIDDEN = "tab_hidden"
    TAB_VISIBLE = "tab_visible"
    WINDOW_BLUR = "window_blur"
    WINDOW_FOCUS = "window_focus"
    FULLSCREEN_EXIT = "fullscreen_exit"
    CONNECTION_LOST = "connection_lost"
    CONNECTION_RESTORED = "connection_restored"


@dataclass
class SessionEvent:
    """`sequence` is assigned by the database, not here — see migration 0011.
    The service used to pick it from a count of existing events, which raced
    with itself whenever two events for one session were written concurrently
    and lost the loser to the `unique (session_id, sequence)` constraint. Left
    None, the column is omitted from the insert and a BEFORE INSERT trigger
    allocates it under a per-session lock."""

    session_id: str
    event_type: EventType
    payload: dict
    sequence: int | None = None

    def to_dict(self) -> dict:
        d = asdict(self)
        d["event_type"] = self.event_type.value
        if d["sequence"] is None:
            del d["sequence"]
        return d
