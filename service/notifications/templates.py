"""Ticket 21 — email copy. Plain functions, no I/O: given the facts, build
an [EmailMessage]. Kept separate from `workflow.py` so the content can be
reviewed/tested without touching a provider or the database."""

from __future__ import annotations

from datetime import datetime

from .provider import EmailMessage


def _format_when(scheduled_at: datetime | None) -> str:
    # Deliberately not `%-d`/`%-I` — those glibc-only strftime flags crash on
    # Windows, and this module's tests run wherever this repo is checked
    # out, not only on the Linux box this service deploys to.
    if scheduled_at is None:
        return "at your convenience before the code expires"
    local = scheduled_at.astimezone()
    hour12 = local.hour % 12 or 12
    ampm = "AM" if local.hour < 12 else "PM"
    return (
        f"{local.strftime('%A, %B')} {local.day}, {local.year} at "
        f"{hour12}:{local.minute:02d} {ampm} {local.strftime('%Z')}"
    )


def invitation_email(
    *,
    candidate_name: str,
    candidate_email: str,
    role_title: str,
    scheduled_at: datetime | None,
    available_minutes: int,
    code: str,
    portal_url: str,
) -> EmailMessage:
    when = _format_when(scheduled_at)
    text = (
        f"Hi {candidate_name},\n\n"
        f"You've been invited to a CogniHire interview for {role_title}.\n\n"
        f"When: {when}\n"
        f"Duration: about {available_minutes} minutes\n"
        f"Your interview code: {code}\n"
        f"Start here: {portal_url}\n\n"
        "Before you begin, please make sure your browser can access your "
        "camera and microphone, and that you have a stable internet "
        "connection — the interview runs entirely in the browser, no "
        "download required.\n\n"
        "— CogniHire"
    )
    html = (
        f"<p>Hi {candidate_name},</p>"
        f"<p>You've been invited to a CogniHire interview for "
        f"<strong>{role_title}</strong>.</p>"
        f"<p><strong>When:</strong> {when}<br>"
        f"<strong>Duration:</strong> about {available_minutes} minutes<br>"
        f"<strong>Your interview code:</strong> "
        f"<code style=\"font-size:1.1em\">{code}</code></p>"
        f"<p><a href=\"{portal_url}\">Start your interview</a></p>"
        "<p>Before you begin, please make sure your browser can access "
        "your camera and microphone, and that you have a stable internet "
        "connection — the interview runs entirely in the browser, no "
        "download required.</p>"
        "<p>— CogniHire</p>"
    )
    return EmailMessage(
        to=candidate_email, to_name=candidate_name,
        subject=f"Your CogniHire interview for {role_title}",
        html_body=html, text_body=text,
    )


def reminder_email(
    *,
    candidate_name: str,
    candidate_email: str,
    role_title: str,
    minutes_before: int,
    code: str,
    portal_url: str,
) -> EmailMessage:
    when_phrase = "in about an hour" if minutes_before >= 60 else f"in about {minutes_before} minutes"
    text = (
        f"Hi {candidate_name},\n\n"
        f"Reminder: your CogniHire interview for {role_title} starts "
        f"{when_phrase}.\n\n"
        f"Your interview code: {code}\n"
        f"Start here: {portal_url}\n\n"
        "— CogniHire"
    )
    html = (
        f"<p>Hi {candidate_name},</p>"
        f"<p>Reminder: your CogniHire interview for <strong>{role_title}"
        f"</strong> starts {when_phrase}.</p>"
        f"<p><strong>Your interview code:</strong> "
        f"<code style=\"font-size:1.1em\">{code}</code></p>"
        f"<p><a href=\"{portal_url}\">Start your interview</a></p>"
        "<p>— CogniHire</p>"
    )
    return EmailMessage(
        to=candidate_email, to_name=candidate_name,
        subject=f"Reminder: your CogniHire interview starts {when_phrase}",
        html_body=html, text_body=text,
    )
