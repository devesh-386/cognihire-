"""Ticket 21 — the email workflow: an automatic invitation when a code is
generated, two scheduled reminders, and an explicit resend action.

Every function here is idempotent in the way its name implies — see each
docstring for exactly what that means for it, since "don't duplicate a
reminder" and "resend always sends" are deliberately different rules for
different actions.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable

from . import store as email_store
from . import templates
from .delivery import attempt_send
from pipeline import supabase_store

PORTAL_URL_DEFAULT = "http://localhost:3000"


def _portal_url() -> str:
    # `os.environ.get(name, default)` only returns `default` when the key is
    # ABSENT — and it is never absent here. docker-compose.api.yml sets
    # `PORTAL_URL: ${PORTAL_URL:-}`, which is present-but-empty whenever the
    # host .env doesn't define it, so the lookup returned "" and every
    # invitation/reminder email a candidate received had `Start here: `
    # followed by nothing and an `<a href="">`. `or` falls through on falsy,
    # not just absent, which is what this needed.
    return os.environ.get("PORTAL_URL") or PORTAL_URL_DEFAULT


def _parse(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


async def _organization_name(organization_id: str) -> str | None:
    """Best-effort only — a lookup failure must never block an invitation or
    reminder from sending. The email just omits the company line, same
    fail-open rule the rest of this module already follows."""
    try:
        org = await supabase_store.fetch_organization(organization_id)
    except supabase_store.SupabaseError:
        return None
    return org.get("name") if org else None


async def send_invitation_for_code(code_row: dict, candidate: dict) -> dict:
    """Called right after a code is generated. Idempotent: if an invitation
    row already exists (any status), this returns it unchanged rather than
    sending a second one — the explicit action for "send it again" is
    [resend_invitation]."""
    existing = await email_store.find(code_row["id"], "invitation")
    if existing is not None:
        return existing

    row = await email_store.create_pending(code_row["id"], code_row["organization_id"], "invitation")
    message = templates.invitation_email(
        candidate_name=candidate.get("name") or "there",
        candidate_email=candidate["email"],
        role_title=code_row["role_title"],
        scheduled_at=_parse(code_row.get("window_start")),
        available_minutes=code_row.get("available_minutes") or 20,
        code=code_row["code"],
        portal_url=_portal_url(),
        organization_name=await _organization_name(code_row["organization_id"]),
    )
    return await attempt_send(row, message)


async def resend_invitation(code_row: dict, candidate: dict) -> dict:
    """The HR desktop's explicit "Resend invitation" action — always sends,
    regardless of the existing row's status, because a candidate asking for
    the email again is a real request, not a duplicate to suppress."""
    existing = await email_store.find(code_row["id"], "invitation")
    row = existing or await email_store.create_pending(
        code_row["id"], code_row["organization_id"], "invitation"
    )
    message = templates.invitation_email(
        candidate_name=candidate.get("name") or "there",
        candidate_email=candidate["email"],
        role_title=code_row["role_title"],
        scheduled_at=_parse(code_row.get("window_start")),
        available_minutes=code_row.get("available_minutes") or 20,
        code=code_row["code"],
        portal_url=_portal_url(),
        organization_name=await _organization_name(code_row["organization_id"]),
    )
    return await attempt_send(row, message)


async def send_reminder_for_code(
    code_row: dict, candidate: dict, email_type: str, minutes_before: int,
) -> dict:
    """Sends one reminder for one code. Idempotent per the database's unique
    constraint on (code_id, email_type): if a row already exists — sent OR
    failed — this returns it unchanged rather than sending again. A failed
    reminder still gets [attempt_send]'s own retries within this one call;
    it is not re-triggered by a later scheduler run."""
    existing = await email_store.find(code_row["id"], email_type)
    if existing is not None:
        return existing

    row = await email_store.create_pending(code_row["id"], code_row["organization_id"], email_type)
    message = templates.reminder_email(
        candidate_name=candidate.get("name") or "there",
        candidate_email=candidate["email"],
        role_title=code_row["role_title"],
        minutes_before=minutes_before,
        code=code_row["code"],
        portal_url=_portal_url(),
        organization_name=await _organization_name(code_row["organization_id"]),
    )
    return await attempt_send(row, message)


# (email_type, minutes before the interview this reminder targets, how
# close to that target counts as "due" on a given scheduler tick).
_REMINDER_WINDOWS = (
    ("reminder_1h", 60, timedelta(minutes=5)),
    ("reminder_30m", 30, timedelta(minutes=5)),
)


async def send_due_reminders(
    fetch_candidate: Callable[[str], Awaitable[dict | None]],
) -> dict:
    """The scheduler's entrypoint — Ticket 21's parallel of Ticket 12's
    `reminder-scheduler` Edge Function, for the interview-code system
    instead of the legacy invitations flow. Call this on a timer (cron, an
    external scheduler, or a manual poke) and it sends whatever reminder is
    currently due across every active code.

    `fetch_candidate` is injected — production passes
    `pipeline.supabase_store.fetch_candidate`; tests pass a fake — so this
    module has no direct dependency on the candidates table's store shape.
    """
    now = datetime.now(timezone.utc)
    sent = []
    skipped = 0

    for code_row in await email_store.list_active_codes():
        window_start = _parse(code_row.get("window_start"))
        if window_start is None:
            continue
        due_in = window_start - now

        for email_type, minutes_before, tolerance in _REMINDER_WINDOWS:
            target = timedelta(minutes=minutes_before)
            if abs(due_in - target) > tolerance:
                continue
            # Checked here, not just inside send_reminder_for_code: this
            # tells "genuinely sent this run" apart from "already existed
            # from an earlier run" so `sent` only ever reports new activity,
            # not every code that happens to still be in its due window.
            if await email_store.find(code_row["id"], email_type) is not None:
                continue
            candidate = await fetch_candidate(code_row["candidate_id"])
            if candidate is None:
                skipped += 1
                continue
            try:
                result = await send_reminder_for_code(code_row, candidate, email_type, minutes_before)
            except supabase_store.SupabaseError:
                # A failure on one code (including a genuine create_pending
                # race against another scheduler tick — the unique
                # (code_id, email_type) constraint is what actually
                # guarantees no duplicate send, this is just the exception
                # path when two ticks lose that race at the same instant)
                # must never abort reminders for every other due candidate
                # in this same batch. The next tick retries it.
                skipped += 1
                continue
            sent.append({
                "code_id": code_row["id"], "email_type": email_type,
                "status": result.get("status"),
            })

    return {"checked_at": now.isoformat(), "sent": sent, "skipped": skipped}
