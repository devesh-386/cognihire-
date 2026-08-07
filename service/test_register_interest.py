"""Tests for `/register-interest` — the public site's "email me the
registration link" action.

The security-relevant property here is that the response is identical
whether the send succeeded, failed, or the address belongs to an existing
candidate. The route is unauthenticated and linked from the marketing page,
so a distinguishable response would turn it into an email-enumeration
oracle."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from notifications.provider import EmailSendResult


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("APPLY_FORM_URL", "https://forms.example.com/apply")
    import main
    return TestClient(main.app)


class _RecordingProvider:
    name = "fake"

    def __init__(self, ok=True, error=None):
        self.ok = ok
        self.error = error
        self.sent = []

    async def send(self, message):
        self.sent.append(message)
        return EmailSendResult(ok=self.ok, provider=self.name, error=self.error)


def test_a_valid_address_is_sent_the_form_link(client, monkeypatch):
    provider = _RecordingProvider()
    import main
    monkeypatch.setattr(main, "get_email_provider", lambda: provider)

    resp = client.post("/register-interest", json={"email": "ada@example.com"})

    assert resp.status_code == 200
    assert len(provider.sent) == 1
    message = provider.sent[0]
    assert message.to == "ada@example.com"
    assert "https://forms.example.com/apply" in message.text_body
    assert "https://forms.example.com/apply" in message.html_body


def test_a_failed_send_is_indistinguishable_from_a_successful_one(client, monkeypatch):
    """A candidate must not be able to tell a bounced address from a
    delivered one — see the module docstring."""
    import main

    good = _RecordingProvider()
    monkeypatch.setattr(main, "get_email_provider", lambda: good)
    ok_resp = client.post("/register-interest", json={"email": "ada@example.com"})

    bad = _RecordingProvider(ok=False, error="mailbox does not exist")
    monkeypatch.setattr(main, "get_email_provider", lambda: bad)
    fail_resp = client.post("/register-interest", json={"email": "ada@example.com"})

    assert ok_resp.status_code == fail_resp.status_code == 200
    assert ok_resp.json() == fail_resp.json()


def test_an_obviously_invalid_address_is_rejected(client):
    resp = client.post("/register-interest", json={"email": "not-an-email"})
    assert resp.status_code == 400


def test_an_unconfigured_form_url_fails_loudly_rather_than_emailing_a_broken_link(
    client, monkeypatch
):
    provider = _RecordingProvider()
    import main
    monkeypatch.setattr(main, "get_email_provider", lambda: provider)
    monkeypatch.delenv("APPLY_FORM_URL", raising=False)

    resp = client.post("/register-interest", json={"email": "ada@example.com"})

    assert resp.status_code == 503
    assert provider.sent == [], "no email should go out with an empty form link in it"
