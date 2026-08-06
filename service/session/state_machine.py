"""Legal status transitions for an interview session.

Pure and side-effect free on purpose: whether a transition is allowed should
be answerable without a database round-trip, so `interview_session.py` can
reject an illegal call (e.g. answering a session that already finished)
before it touches storage.
"""

from __future__ import annotations

NOT_STARTED = "not_started"
IN_PROGRESS = "in_progress"
COMPLETE = "complete"
ABANDONED = "abandoned"

_STATUSES = {NOT_STARTED, IN_PROGRESS, COMPLETE, ABANDONED}

# Terminal states have no outgoing edges — a finished session stays finished.
_ALLOWED: dict[str, set[str]] = {
    NOT_STARTED: {IN_PROGRESS, ABANDONED},
    IN_PROGRESS: {IN_PROGRESS, COMPLETE, ABANDONED},
    COMPLETE: set(),
    ABANDONED: set(),
}


class IllegalTransition(ValueError):
    """Raised when the orchestrator asks for a transition the state machine forbids."""


def can_transition(current: str, target: str) -> bool:
    if current not in _STATUSES or target not in _STATUSES:
        raise ValueError(f"unknown session status: {current!r} -> {target!r}")
    return target in _ALLOWED[current]


def require_transition(current: str, target: str) -> None:
    if not can_transition(current, target):
        raise IllegalTransition(f"cannot move a session from {current!r} to {target!r}")


def is_terminal(status: str) -> bool:
    return status in (COMPLETE, ABANDONED)
