"""Tests for Ticket 21's email workflow: successful sends, provider
failures, retry-with-backoff, duplicate-reminder prevention, and the
explicit resend action. Unit-level, in the same style as
`test_interview_codes.py` — fake store functions monkeypatched directly
onto the real module objects, no HTTP layer, since nothing here is proving
the Supabase REST shape (that's `store.py`'s job, exercised transitively by
`test_end_to_end.py` and `test_demo_seed.py`)."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from notifications import delivery, workflow
from notifications import store as email_store
from notifications.provider import EmailSendResult
from notifications.templates import invitation_email


def _run(coro):
    return asyncio.run(coro)


class _FakeEmailStore:
    def __init__(self):
        self.rows: dict[str, dict] = {}
        self._next_id = 1
        self._active_codes: list[dict] = []

    async def find(self, code_id, email_type):
        return next(
            (r for r in self.rows.values()
             if r["code_id"] == code_id and r["email_type"] == email_type),
            None,
        )

    async def create_pending(self, code_id, organization_id, email_type):
        rid = f"email-{self._next_id}"
        self._next_id += 1
        row = {
            "id": rid, "code_id": code_id, "organization_id": organization_id,
            "email_type": email_type, "status": "pending", "attempts": 0,
            "last_error": None, "last_attempt_at": None, "sent_at": None,
        }
        self.rows[rid] = row
        return row

    async def update(self, row_id, fields):
        self.rows[row_id].update(fields)

    async def list_for_code(self, code_id):
        return [r for r in self.rows.values() if r["code_id"] == code_id]

    def set_active_codes(self, codes):
        self._active_codes = codes

    async def list_active_codes(self):
        return list(self._active_codes)


class _FakeProvider:
    """`outcomes` is consumed in order, one per `.send()` call; the last
    entry repeats once exhausted."""

    name = "fake"

    def __init__(self, outcomes):
        self._outcomes = list(outcomes)
        self.calls = 0

    async def send(self, message):
        result = self._outcomes[min(self.calls, len(self._outcomes) - 1)]
        self.calls += 1
        return result


def _code_row(**overrides):
    return {
        "id": "code-1", "code": "ABCD1234", "organization_id": "org-1",
        "candidate_id": "cand-1", "role_title": "Backend Engineer",
        "available_minutes": 20, "window_start": None,
        **overrides,
    }


def _candidate(**overrides):
    return {"id": "cand-1", "name": "Ada Lovelace", "email": "ada@example.com", **overrides}


def _message():
    return invitation_email(
        candidate_name="Ada", candidate_email="ada@example.com",
        role_title="Backend Engineer", scheduled_at=None,
        available_minutes=20, code="ABCD1234", portal_url="http://x",
    )


@pytest.fixture(autouse=True)
def fake_store(monkeypatch):
    fake = _FakeEmailStore()
    for target in (email_store, workflow.email_store, delivery.email_store):
        monkeypatch.setattr(target, "find", fake.find)
        monkeypatch.setattr(target, "create_pending", fake.create_pending)
        monkeypatch.setattr(target, "update", fake.update)
        monkeypatch.setattr(target, "list_for_code", fake.list_for_code)
        monkeypatch.setattr(target, "list_active_codes", fake.list_active_codes)
    # Retries would otherwise really sleep 1s/2s per test. A plain no-op
    # coroutine, not `asyncio.sleep(0)` — that would resolve through the
    # very attribute this line just patched and recurse forever.
    async def _no_sleep(*_args):
        return None

    monkeypatch.setattr(delivery.asyncio, "sleep", _no_sleep)
    return fake


# --- delivery.attempt_send: success, failure, retry-then-succeed ------------

def test_successful_send_marks_sent_on_first_attempt(fake_store):
    provider = _FakeProvider([EmailSendResult(ok=True, provider="fake", message_id="m1")])
    row = _run(email_store.create_pending("code-1", "org-1", "invitation"))

    result = _run(delivery.attempt_send(row, _message(), provider=provider))

    assert result["status"] == "sent"
    assert result["attempts"] == 1
    assert provider.calls == 1
    assert fake_store.rows[row["id"]]["status"] == "sent"


def test_failed_provider_is_marked_failed_after_retry_limit(fake_store):
    provider = _FakeProvider([
        EmailSendResult(ok=False, provider="fake", error="timeout"),
        EmailSendResult(ok=False, provider="fake", error="timeout"),
        EmailSendResult(ok=False, provider="fake", error="timeout"),
    ])
    row = _run(email_store.create_pending("code-1", "org-1", "invitation"))

    result = _run(delivery.attempt_send(row, _message(), provider=provider))

    assert result["status"] == "failed"
    assert result["attempts"] == 3
    assert result["last_error"] == "timeout"
    assert provider.calls == 3
    assert fake_store.rows[row["id"]]["status"] == "failed"


def test_retry_then_succeed_records_the_successful_attempt_count(fake_store):
    provider = _FakeProvider([
        EmailSendResult(ok=False, provider="fake", error="rate limited"),
        EmailSendResult(ok=False, provider="fake", error="rate limited"),
        EmailSendResult(ok=True, provider="fake", message_id="m2"),
    ])
    row = _run(email_store.create_pending("code-1", "org-1", "invitation"))

    result = _run(delivery.attempt_send(row, _message(), provider=provider))

    assert result["status"] == "sent"
    assert result["attempts"] == 3
    assert provider.calls == 3


# --- workflow: idempotency rules ---------------------------------------------

def test_sending_invitation_twice_does_not_send_a_second_email(fake_store, monkeypatch):
    calls = {"n": 0}

    async def fake_attempt_send(row, message, provider=None):
        calls["n"] += 1
        await email_store.update(row["id"], {"status": "sent", "attempts": 1})
        return {**row, "status": "sent", "attempts": 1}

    monkeypatch.setattr(workflow, "attempt_send", fake_attempt_send)

    code = _code_row()
    candidate = _candidate()
    first = _run(workflow.send_invitation_for_code(code, candidate))
    second = _run(workflow.send_invitation_for_code(code, candidate))

    assert calls["n"] == 1, "the second call should not have attempted a send at all"
    assert first["id"] == second["id"]
    assert len(_run(email_store.list_for_code(code["id"]))) == 1


def test_duplicate_reminder_is_not_sent_twice(fake_store, monkeypatch):
    calls = {"n": 0}

    async def fake_attempt_send(row, message, provider=None):
        calls["n"] += 1
        await email_store.update(row["id"], {"status": "sent", "attempts": 1})
        return {**row, "status": "sent", "attempts": 1}

    monkeypatch.setattr(workflow, "attempt_send", fake_attempt_send)

    code = _code_row()
    candidate = _candidate()
    first = _run(workflow.send_reminder_for_code(code, candidate, "reminder_1h", 60))
    second = _run(workflow.send_reminder_for_code(code, candidate, "reminder_1h", 60))

    assert calls["n"] == 1, "the second call should not have attempted a send at all"
    assert first["id"] == second["id"]


def test_resend_sends_again_even_though_the_invitation_was_already_sent(fake_store, monkeypatch):
    calls = {"n": 0}

    async def fake_attempt_send(row, message, provider=None):
        calls["n"] += 1
        await email_store.update(row["id"], {"status": "sent", "attempts": 1})
        return {**row, "status": "sent", "attempts": 1}

    monkeypatch.setattr(workflow, "attempt_send", fake_attempt_send)

    code = _code_row()
    candidate = _candidate()
    _run(workflow.send_invitation_for_code(code, candidate))
    assert calls["n"] == 1

    _run(workflow.resend_invitation(code, candidate))
    assert calls["n"] == 2, "resend must send again, not short-circuit like a normal invitation call"

    rows = _run(email_store.list_for_code(code["id"]))
    assert len(rows) == 1, "resend reuses the existing row rather than creating a duplicate"


# --- workflow: scheduler entrypoint -----------------------------------------

def test_send_due_reminders_only_fires_for_codes_within_the_reminder_window(fake_store, monkeypatch):
    calls = []

    async def fake_attempt_send(row, message, provider=None):
        calls.append(row["email_type"])
        await email_store.update(row["id"], {"status": "sent", "attempts": 1})
        return {**row, "status": "sent", "attempts": 1}

    monkeypatch.setattr(workflow, "attempt_send", fake_attempt_send)

    now = datetime.now(timezone.utc)
    due_soon = _code_row(id="code-due", window_start=(now + timedelta(minutes=59)).isoformat())
    far_out = _code_row(id="code-far", candidate_id="cand-2",
                         window_start=(now + timedelta(hours=5)).isoformat())
    no_window = _code_row(id="code-none", candidate_id="cand-3", window_start=None)
    fake_store.set_active_codes([due_soon, far_out, no_window])

    async def fetch_candidate(candidate_id):
        return _candidate(id=candidate_id, email=f"{candidate_id}@example.com")

    result = _run(workflow.send_due_reminders(fetch_candidate))

    sent_code_ids = {s["code_id"] for s in result["sent"]}
    assert sent_code_ids == {"code-due"}
    assert result["sent"][0]["email_type"] == "reminder_1h"
    assert calls == ["reminder_1h"]

    # Calling it again is a no-op for the same code — the row from the first
    # run already exists, so `send_reminder_for_code` short-circuits before
    # ever calling `attempt_send` again.
    result_again = _run(workflow.send_due_reminders(fetch_candidate))
    assert result_again["sent"] == []
    assert calls == ["reminder_1h"]
