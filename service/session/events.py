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


@dataclass
class SessionEvent:
    session_id: str
    sequence: int
    event_type: EventType
    payload: dict

    def to_dict(self) -> dict:
        d = asdict(self)
        d["event_type"] = self.event_type.value
        return d
