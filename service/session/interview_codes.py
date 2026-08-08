"""Interview codes — the front door for Phase 3: a candidate should never
sign in, they should enter a code an HR reviewer generated for them.

```
HR desktop → POST /interview-codes/generate → code
candidate  → POST /interview/start {code}   → validated → session
```

Generation is centralized here rather than in the HR desktop client, per the
explicit instruction this was scoped against: the client is a caller, never
a source of truth, matching the AI Gateway's "thin, dumb client" rule
elsewhere in this codebase.
"""

from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from . import codes_store, interview_session, session_store, state_machine


class CodeError(RuntimeError):
    """A code that cannot be redeemed right now, with a caller-facing reason
    (`self.reason`) distinct from the human-readable message — the portal
    renders its own copy per reason rather than displaying `str(exc)`."""

    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


# Ambiguous characters (0/O, 1/I/L) excluded — a code is read off a screen or
# an email and typed by hand.
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_CODE_LENGTH = 8


def _generate_code_string() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(_CODE_LENGTH))


async def generate(
    candidate_id: str,
    organization_id: str,
    role_title: str,
    required_skills: list[str] | None = None,
    difficulty: str = "standard",
    available_minutes: int = 20,
    max_attempts: int = 3,
    expires_in_hours: int = 72,
    window_start: datetime | None = None,
    window_end: datetime | None = None,
) -> dict:
    """Create a code. Does not check the candidate's resume-processing
    status — a code can be generated before the resume finishes processing;
    `interview_session.start` is what enforces `READY_FOR_INTERVIEW`, at
    redemption time, when it's actually about to matter."""
    now = datetime.now(timezone.utc)
    code = _generate_code_string()

    # Astronomically unlikely at 32^8 codes, but a store-level unique
    # constraint means a collision would surface as a 503, not a silent
    # overwrite — worth one retry before giving up.
    for _ in range(3):
        existing = await codes_store.fetch_by_code(code)
        if existing is None:
            break
        code = _generate_code_string()

    row = await codes_store.create_code({
        "code": code,
        "organization_id": organization_id,
        "candidate_id": candidate_id,
        "role_title": role_title,
        "required_skills": required_skills or [],
        "difficulty": difficulty,
        "available_minutes": available_minutes,
        "max_attempts": max_attempts,
        "expires_at": (now + timedelta(hours=expires_in_hours)).isoformat(),
        "window_start": window_start.isoformat() if window_start else None,
        "window_end": window_end.isoformat() if window_end else None,
    })
    return row


async def start_with_code(code: str, _retries_left: int = 3) -> dict:
    """Validate a code and either resume its in-progress session or start a
    new one. Raises `CodeError` for every way a code can be unusable —
    the caller (the gateway route) maps `reason` to an HTTP status.

    Two simultaneous redemptions of the same code used to both pass the
    attempts check, both create a session, and race to overwrite the code's
    `session_id` — a real duplicate-session bug, not hypothetical. The
    attempts-increment below is now an atomic compare-and-swap
    (`codes_store.claim_code`) instead of a plain read-then-write; a request
    that loses the race re-fetches and either resumes the session the winner
    just created, or retries, rather than creating a second one."""
    row = await codes_store.fetch_by_code(code)
    if row is None:
        raise CodeError("not_found", "That code was not recognized.")

    if row["status"] == "revoked":
        raise CodeError("revoked", "This interview code has been revoked.")

    now = datetime.now(timezone.utc)
    if datetime.fromisoformat(row["expires_at"]) < now:
        raise CodeError("expired", "This interview code has expired.")

    window_start = row.get("window_start")
    if window_start and datetime.fromisoformat(window_start) > now:
        raise CodeError("not_yet_open", "This interview hasn't opened yet.")
    window_end = row.get("window_end")
    if window_end and datetime.fromisoformat(window_end) < now:
        raise CodeError("window_closed", "This interview's window has closed.")

    if row["session_id"]:
        session = await session_store.fetch_session(row["session_id"])
        if session is not None:
            if session["status"] == state_machine.COMPLETE:
                raise CodeError("already_used", "This interview has already been completed.")
            if session["status"] == state_machine.IN_PROGRESS:
                # Resume rather than restart — a refresh or a dropped
                # connection should not cost the candidate their progress
                # or count against their attempts.
                return {
                    "session_id": session["id"],
                    "turn": interview_session.current_turn(session),
                    "coverage": session["coverage_state"],
                }
            # abandoned: falls through to start a fresh attempt below.

    if row["attempts_used"] >= row["max_attempts"]:
        raise CodeError("max_attempts_exceeded", "This code has no attempts remaining.")

    claimed = await codes_store.claim_code(row["id"], row["attempts_used"], row["attempts_used"] + 1)
    if not claimed:
        # Lost the race: another request claimed this code between our read
        # and our write. Its session should exist (or be about to) — retry
        # from the top so we resume it, rather than starting a second one.
        if _retries_left <= 0:
            raise CodeError(
                "conflict",
                "This code is being redeemed right now — please try again in a moment.",
            )
        return await start_with_code(code, _retries_left=_retries_left - 1)

    result = await interview_session.start(
        row["candidate_id"], row["organization_id"], row["role_title"],
        required_skills=row.get("required_skills") or [],
        difficulty=row.get("difficulty") or "standard",
        available_minutes=row.get("available_minutes") or 20,
    )
    await codes_store.update_code(row["id"], {"session_id": result["session_id"]})
    return result
