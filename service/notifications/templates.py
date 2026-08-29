"""Ticket 21 — email copy. Plain functions, no I/O: given the facts, build
an [EmailMessage]. Kept separate from `workflow.py` so the content can be
reviewed/tested without touching a provider or the database."""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from .provider import EmailMessage

# The timezone the CANDIDATE reads, which is not the timezone the server runs
# in. `scheduled_at.astimezone()` — what this module used to call — converts to
# the host's local zone; the deployed VM runs UTC, so a candidate who asked for
# 11:45 in India was emailed "6:15 AM UTC" and would have missed the interview
# by five and a half hours. The stored `timestamptz` was always correct; only
# the rendering was wrong.
#
# A fixed offset rather than a `ZoneInfo` lookup on purpose: India has never
# observed daylight saving, so IST is UTC+5:30 year-round with no transition to
# get wrong, and a fixed offset needs no tzdata package — which is not present
# by default on Windows, where this module's tests also run.
_DISPLAY_OFFSET_MINUTES = int(os.environ.get("INTERVIEW_DISPLAY_UTC_OFFSET_MINUTES", "330"))
_DISPLAY_TZ_NAME = os.environ.get("INTERVIEW_DISPLAY_TZ_NAME", "IST")
_DISPLAY_TZ = timezone(timedelta(minutes=_DISPLAY_OFFSET_MINUTES), _DISPLAY_TZ_NAME)


def _interview_url(portal_url: str, code: str) -> str:
    """The deep link that lands the candidate on the interview page with their
    code already filled in.

    This grants nothing. `/interview` reads `?code=` purely to prefill the
    form (portal/app/interview/page.tsx), and the code is still validated
    server-side by `/interview/start` against expiry, revocation and attempt
    count — the same checks a hand-typed code goes through, enforced in the
    database RPCs (migrations 0018/0019), not in the URL. Prefilling a field is
    not authorization; the code IS the credential either way, and it was
    already being emailed in plaintext next to this link."""
    return f"{portal_url.rstrip('/')}/interview?code={quote(code)}"


def _format_when(scheduled_at: datetime | None) -> str:
    # Deliberately not `%-d`/`%-I` — those glibc-only strftime flags crash on
    # Windows, and this module's tests run wherever this repo is checked
    # out, not only on the Linux box this service deploys to.
    if scheduled_at is None:
        return "at your convenience before the code expires"
    local = scheduled_at.astimezone(_DISPLAY_TZ)
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
    organization_name: str | None = None,
) -> EmailMessage:
    when = _format_when(scheduled_at)
    # Best-effort: a missing org name (lookup failure, deleted org) never
    # blocks sending — the line is just omitted, same fail-open rule as
    # everything else in this module.
    company_line = f" at {organization_name}" if organization_name else ""
    company_line_html = f" at <strong>{organization_name}</strong>" if organization_name else ""
    text = (
        f"Hi {candidate_name},\n\n"
        f"You've been invited to a CogniHire interview for {role_title}"
        f"{company_line}.\n\n"
        f"When: {when}\n"
        f"Duration: about {available_minutes} minutes\n"
        f"Your interview code: {code}\n"
        f"Start here: {_interview_url(portal_url, code)}\n\n"
        "Before you begin, please make sure your browser can access your "
        "camera and microphone, and that you have a stable internet "
        "connection — the interview runs entirely in the browser, no "
        "download required.\n\n"
        "— CogniHire"
    )
    html = (
        f"<p>Hi {candidate_name},</p>"
        f"<p>You've been invited to a CogniHire interview for "
        f"<strong>{role_title}</strong>{company_line_html}.</p>"
        f"<p><strong>When:</strong> {when}<br>"
        f"<strong>Duration:</strong> about {available_minutes} minutes<br>"
        f"<strong>Your interview code:</strong> "
        f"<code style=\"font-size:1.1em\">{code}</code></p>"
        f"<p><a href=\"{_interview_url(portal_url, code)}\">Start your interview</a></p>"
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


def registration_email(*, candidate_email: str, form_url: str) -> EmailMessage:
    """Sent when someone asks for a registration link from the public site.

    Addressed generically — at this point all we have is an email address,
    and inventing a name from the local part ("hi, deveshsv.386") reads worse
    than not trying."""
    text = (
        "Hello,\n\n"
        "Thanks for your interest in interviewing with CogniHire.\n\n"
        f"Register here: {form_url}\n\n"
        "The form asks for your details, the role you're applying for, and "
        "your résumé. Once it's in, we'll email you an interview code and a "
        "time.\n\n"
        "The interview runs entirely in your browser and takes about 20 "
        "minutes. You'll need a working camera, microphone, and a stable "
        "internet connection.\n\n"
        "If you didn't request this, you can ignore this email.\n\n"
        "— CogniHire"
    )
    html = (
        "<p>Hello,</p>"
        "<p>Thanks for your interest in interviewing with CogniHire.</p>"
        f'<p><a href="{form_url}">Register here</a></p>'
        "<p>The form asks for your details, the role you're applying for, "
        "and your résumé. Once it's in, we'll email you an interview code "
        "and a time.</p>"
        "<p>The interview runs entirely in your browser and takes about 20 "
        "minutes. You'll need a working camera, microphone, and a stable "
        "internet connection.</p>"
        "<p style=\"color:#6c5b4e;font-size:0.9em\">If you didn't request "
        "this, you can ignore this email.</p>"
        "<p>— CogniHire</p>"
    )
    return EmailMessage(
        to=candidate_email, to_name="",
        subject="Register for your CogniHire interview",
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
    organization_name: str | None = None,
) -> EmailMessage:
    when_phrase = "in about an hour" if minutes_before >= 60 else f"in about {minutes_before} minutes"
    company_line = f" at {organization_name}" if organization_name else ""
    company_line_html = f" at <strong>{organization_name}</strong>" if organization_name else ""
    text = (
        f"Hi {candidate_name},\n\n"
        f"Reminder: your CogniHire interview for {role_title}{company_line} "
        f"starts {when_phrase}.\n\n"
        f"Your interview code: {code}\n"
        f"Start here: {_interview_url(portal_url, code)}\n\n"
        "— CogniHire"
    )
    html = (
        f"<p>Hi {candidate_name},</p>"
        f"<p>Reminder: your CogniHire interview for <strong>{role_title}"
        f"</strong>{company_line_html} starts {when_phrase}.</p>"
        f"<p><strong>Your interview code:</strong> "
        f"<code style=\"font-size:1.1em\">{code}</code></p>"
        f"<p><a href=\"{_interview_url(portal_url, code)}\">Start your interview</a></p>"
        "<p>— CogniHire</p>"
    )
    return EmailMessage(
        to=candidate_email, to_name=candidate_name,
        subject=f"Reminder: your CogniHire interview starts {when_phrase}",
        html_body=html, text_body=text,
    )
