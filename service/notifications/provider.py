"""Ticket 21 — the email provider boundary.

Everything above this module (`templates.py`, `delivery.py`, `workflow.py`,
the routes in `main.py`) talks to [EmailMessage] in and [EmailSendResult]
out. Nothing above this line knows whether SendGrid, Azure Communication
Services, or plain SMTP actually moved the bytes — same "thin, dumb client"
separation the AI provider boundary (`ai/provider.py`) already uses for
OpenAI vs. Ollama, applied to the same problem in a different subsystem.

Selecting `EMAIL_PROVIDER=sendgrid|acs|smtp` with the matching credentials
unset does not raise — it resolves to [NullEmailProvider], which always
reports a real, honest failure rather than pretending to send. A demo
running with no email credentials configured should show "failed: no email
provider configured" in the HR desktop, never a silent no-op that looks like
success.
"""

from __future__ import annotations

import asyncio
import os
import smtplib
from dataclasses import dataclass
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from typing import Protocol

import httpx


@dataclass(frozen=True)
class EmailMessage:
    to: str
    to_name: str
    subject: str
    html_body: str
    text_body: str


@dataclass(frozen=True)
class EmailSendResult:
    ok: bool
    provider: str
    message_id: str | None = None
    error: str | None = None


class EmailProvider(Protocol):
    name: str

    async def send(self, message: EmailMessage) -> EmailSendResult: ...


class NullEmailProvider:
    """The honest degraded path — see module docstring. Never raises; every
    caller already handles a non-ok [EmailSendResult] as the normal failure
    case, so this needs no special-casing anywhere upstream."""

    name = "none"

    def __init__(self, reason: str):
        self._reason = reason

    async def send(self, message: EmailMessage) -> EmailSendResult:
        return EmailSendResult(ok=False, provider=self.name, error=self._reason)


class SmtpEmailProvider:
    """Fallback provider — works with Gmail SMTP (App Password) or any
    standard SMTP relay. `smtplib` is synchronous, so the actual send runs in
    a worker thread via `asyncio.to_thread` in `delivery.py` — this class
    itself makes no assumption about the event loop."""

    name = "smtp"

    def __init__(self, host: str, port: int, username: str, password: str, from_address: str):
        self._host = host
        self._port = port
        self._username = username
        self._password = password
        self._from_address = from_address

    def send_sync(self, message: EmailMessage) -> EmailSendResult:
        mime = MIMEMultipart("alternative")
        mime["Subject"] = message.subject
        mime["From"] = self._from_address
        mime["To"] = message.to
        mime.attach(MIMEText(message.text_body, "plain"))
        mime.attach(MIMEText(message.html_body, "html"))

        try:
            with smtplib.SMTP(self._host, self._port, timeout=20) as smtp:
                smtp.starttls()
                smtp.login(self._username, self._password)
                smtp.sendmail(self._from_address, [message.to], mime.as_string())
        except Exception as exc:  # noqa: BLE001 - report any transport failure verbatim
            return EmailSendResult(ok=False, provider=self.name, error=str(exc))
        return EmailSendResult(ok=True, provider=self.name)

    async def send(self, message: EmailMessage) -> EmailSendResult:
        # smtplib is blocking; run it off the event loop rather than
        # stalling every other request while this one talks to a mail
        # server.
        return await asyncio.to_thread(self.send_sync, message)


class SendGridEmailProvider:
    """Talks to SendGrid's `POST /v3/mail/send` directly over `httpx` — same
    pattern as every other external call in this service, no SDK dependency
    added for one endpoint."""

    name = "sendgrid"

    def __init__(self, api_key: str, from_address: str, from_name: str):
        self._api_key = api_key
        self._from_address = from_address
        self._from_name = from_name

    async def send(self, message: EmailMessage) -> EmailSendResult:
        payload = {
            "personalizations": [{"to": [{"email": message.to, "name": message.to_name}]}],
            "from": {"email": self._from_address, "name": self._from_name},
            "subject": message.subject,
            "content": [
                {"type": "text/plain", "value": message.text_body},
                {"type": "text/html", "value": message.html_body},
            ],
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                "https://api.sendgrid.com/v3/mail/send",
                headers={"Authorization": f"Bearer {self._api_key}", "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code not in (200, 201, 202):
            return EmailSendResult(
                ok=False, provider=self.name,
                error=f"SendGrid HTTP {response.status_code}: {response.text[:200]}",
            )
        return EmailSendResult(
            ok=True, provider=self.name,
            message_id=response.headers.get("X-Message-Id"),
        )


class AzureCommunicationEmailProvider:
    """Talks to Azure Communication Services' Email `send` REST operation.
    ACS uses HMAC-signed requests in its own SDKs; the connection-string
    shape (`endpoint=...;accesskey=...`) is what the SDK normally hides —
    kept here as a plain `httpx` call, same reasoning as [SendGridEmailProvider]."""

    name = "acs"

    def __init__(self, endpoint: str, access_key: str, from_address: str):
        self._endpoint = endpoint.rstrip("/")
        self._access_key = access_key
        self._from_address = from_address

    async def send(self, message: EmailMessage) -> EmailSendResult:
        payload = {
            "senderAddress": self._from_address,
            "recipients": {"to": [{"address": message.to, "displayName": message.to_name}]},
            "content": {
                "subject": message.subject,
                "plainText": message.text_body,
                "html": message.html_body,
            },
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                f"{self._endpoint}/emails:send?api-version=2023-03-31",
                headers={"Authorization": f"Bearer {self._access_key}", "Content-Type": "application/json"},
                json=payload,
            )
        if response.status_code not in (200, 202):
            return EmailSendResult(
                ok=False, provider=self.name,
                error=f"ACS HTTP {response.status_code}: {response.text[:200]}",
            )
        return EmailSendResult(ok=True, provider=self.name)


def get_provider() -> EmailProvider:
    """Reads `EMAIL_PROVIDER` (default `smtp`) and the matching credential
    env vars. Missing credentials for the selected provider resolve to
    [NullEmailProvider] with a specific reason — never a crash, never a
    silent pretend-send."""
    kind = os.environ.get("EMAIL_PROVIDER", "smtp")

    if kind == "sendgrid":
        api_key = os.environ.get("SENDGRID_API_KEY", "")
        from_address = os.environ.get("EMAIL_FROM_ADDRESS", "")
        if not api_key or not from_address:
            return NullEmailProvider("SENDGRID_API_KEY / EMAIL_FROM_ADDRESS not configured")
        return SendGridEmailProvider(
            api_key, from_address, os.environ.get("EMAIL_FROM_NAME", "CogniHire")
        )

    if kind == "acs":
        endpoint = os.environ.get("ACS_ENDPOINT", "")
        access_key = os.environ.get("ACS_ACCESS_KEY", "")
        from_address = os.environ.get("EMAIL_FROM_ADDRESS", "")
        if not endpoint or not access_key or not from_address:
            return NullEmailProvider("ACS_ENDPOINT / ACS_ACCESS_KEY / EMAIL_FROM_ADDRESS not configured")
        return AzureCommunicationEmailProvider(endpoint, access_key, from_address)

    # Default / explicit "smtp".
    host = os.environ.get("SMTP_HOST", "")
    username = os.environ.get("SMTP_USERNAME", "")
    password = os.environ.get("SMTP_PASSWORD", "")
    from_address = os.environ.get("EMAIL_FROM_ADDRESS", username)
    if not host or not username or not password:
        return NullEmailProvider("SMTP_HOST / SMTP_USERNAME / SMTP_PASSWORD not configured")
    port = int(os.environ.get("SMTP_PORT", "587"))
    return SmtpEmailProvider(host, port, username, password, from_address)
