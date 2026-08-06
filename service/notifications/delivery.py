"""Ticket 21 — retry with exponential backoff, and persisting delivery
status. Deliberately generic over "what kind of email this is": invitation
vs. reminder differ only in which template built the message and which row
in `interview_code_emails` this is updating.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

from . import store as email_store
from .provider import EmailMessage, EmailProvider, get_provider

_MAX_ATTEMPTS = 3
# attempt 1 fails -> wait 1s, attempt 2 fails -> wait 2s, then attempt 3 (no
# wait after — there's nothing left to retry).
_BACKOFF_SECONDS = (1, 2)


async def attempt_send(
    row: dict, message: EmailMessage, provider: EmailProvider | None = None,
) -> dict:
    """Sends `message`, retrying up to `_MAX_ATTEMPTS` times with backoff,
    and persists the outcome onto `row` (an `interview_code_emails` row).
    Never raises — a provider failure ends up recorded as `status='failed'`,
    not an exception the caller has to handle specially. Per the ticket, a
    failed email must never affect interview scheduling."""
    active_provider = provider or get_provider()
    last_error: str | None = None

    for attempt in range(1, _MAX_ATTEMPTS + 1):
        result = await active_provider.send(message)
        now = datetime.now(timezone.utc).isoformat()

        if result.ok:
            await email_store.update(row["id"], {
                "status": "sent", "attempts": attempt,
                "last_attempt_at": now, "sent_at": now, "last_error": None,
            })
            return {**row, "status": "sent", "attempts": attempt, "sent_at": now, "last_error": None}

        last_error = result.error
        await email_store.update(row["id"], {
            "status": "failed", "attempts": attempt,
            "last_attempt_at": now, "last_error": last_error,
        })
        if attempt < _MAX_ATTEMPTS:
            await asyncio.sleep(_BACKOFF_SECONDS[attempt - 1])

    return {**row, "status": "failed", "attempts": _MAX_ATTEMPTS, "last_error": last_error}
