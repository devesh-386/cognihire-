"""Route-level tests for Ticket 21: does `/interview-codes/generate`
actually fire the invitation, does `/interview-codes/{id}/emails` reflect
it, and does `/interview-codes/resend-invitation` work — through the real
FastAPI routes, not the workflow functions directly (`test_email_workflow.py`
already covers those). Reuses the same in-memory PostgREST-shaped fake as
`test_end_to_end.py`, extended with the `interview_code_emails` table."""

from __future__ import annotations

import asyncio
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from notifications import delivery
from pipeline import supabase_store
from session import codes_store, session_store


class _FakeResponse:
    def __init__(self, status_code, payload=None, headers=None, content=b""):
        self.status_code = status_code
        self._payload = payload
        self.headers = headers or {}
        self.content = content
        self.text = "" if payload is None else str(payload)

    def json(self):
        return self._payload


class _FakeSupabase:
    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "candidates": [], "candidate_ai_profile": [],
            "interview_codes": [], "interview_sessions": [],
            "interview_events": [], "interview_code_emails": [],
        }
        self._next_id = {"interview_sessions": 1, "interview_codes": 1, "interview_code_emails": 1}

    def seed_candidate(self, candidate_id, organization_id, email):
        self.tables["candidates"].append({
            "id": candidate_id, "organization_id": organization_id,
            "name": "Test Candidate", "email": email, "resume_path": None,
        })

    def _filtered(self, table, params):
        rows = self.tables[table]

        def matches(row):
            for key, value in params.items():
                if key in ("select", "order", "limit", "on_conflict"):
                    continue
                if isinstance(value, str) and value.startswith("eq."):
                    if str(row.get(key)) != value[3:]:
                        return False
            return True

        return [r for r in rows if matches(r)]

    async def request(self, method, url, **kwargs):
        parsed = urlparse(url)
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        params.update(kwargs.get("params") or {})

        table = parsed.path.rsplit("/", 1)[-1]
        if table not in self.tables:
            return _FakeResponse(404, payload={"error": f"unknown table {table}"})

        if method == "GET":
            matched = self._filtered(table, params)
            total = len(matched)
            limit = params.get("limit")
            if limit is not None:
                matched = matched[: int(limit)]
            # PostgREST answers 206, not 200, when `limit` truncates the
            # result below what matched. Modeled here because a count read
            # that only accepted 200 was a real live bug (since removed).
            status = 206 if limit is not None and len(matched) < total else 200
            return _FakeResponse(status, payload=matched, headers={"content-range": f"*/{total}"})

        if method == "POST":
            body = kwargs.get("json")
            rows = body if isinstance(body, list) else [body]
            inserted = []
            for row in rows:
                row = dict(row)
                if "id" not in row and table in self._next_id:
                    row["id"] = f"{table}-{self._next_id[table]}"
                    self._next_id[table] += 1
                # Models migration 0011's BEFORE INSERT trigger: the
                # service omits `sequence` and the database allocates it
                # per session. Without this the fake would store events
                # with no sequence at all and `order=sequence.asc` reads
                # would silently stop reflecting real ordering.
                if table == "interview_events" and row.get("sequence") is None:
                    row["sequence"] = 1 + max(
                        [r.get("sequence", 0) for r in self.tables[table]
                         if r.get("session_id") == row.get("session_id")] or [0]
                    )
                row.setdefault("version", 0)
                row.setdefault("session_id", None)
                row.setdefault("attempts_used", 0)
                row.setdefault("status", row.get("status", "active"))
                row.setdefault("window_start", None)
                row.setdefault("window_end", None)
                self.tables[table].append(row)
                inserted.append(row)
            return _FakeResponse(201, payload=inserted)

        if method == "PATCH":
            body = kwargs.get("json") or {}
            matched = self._filtered(table, params)
            for row in matched:
                row.update(body)
            return _FakeResponse(200, payload=matched)

        return _FakeResponse(405)


class _FakeAsyncClient:
    def __init__(self, fake, **_):
        self._fake = fake

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get(self, url, **kwargs):
        return await self._fake.request("GET", url, **kwargs)

    async def post(self, url, **kwargs):
        return await self._fake.request("POST", url, **kwargs)

    async def patch(self, url, **kwargs):
        return await self._fake.request("PATCH", url, **kwargs)


@pytest.fixture
def fake_supabase(monkeypatch):
    fake = _FakeSupabase()
    from notifications import store as email_store

    for module in (supabase_store, session_store, codes_store, email_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))

    async def _no_sleep(*_args):
        return None

    monkeypatch.setattr(delivery.asyncio, "sleep", _no_sleep)
    return fake


@pytest.fixture
def client(fake_supabase, monkeypatch):
    import main
    from pipeline import demo_store
    from security import rate_limit

    rate_limit._reset_for_tests()

    # /interview-codes/generate now resolves the caller's org from a bearer
    # token (same pattern as /roles) instead of trusting the request body.
    # This fake fixture has no real GoTrue to authenticate against, so the
    # token resolution itself is monkeypatched — any "Bearer test-token-org-1"
    # header resolves to organization_id "org-1", which is all these tests need.
    async def fake_resolve(token):
        # app_metadata, mirroring what GoTrue returns for a real user since
        # migration 0012 — the org id lives where the account holder cannot
        # write it. A fake that kept answering `user_metadata` would let the
        # bypass back in without a single test going red.
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    return TestClient(main.app)


_AUTH_ORG_1 = {"Authorization": "Bearer test-token-org-1"}


def test_generating_a_code_fires_an_invitation_email(fake_supabase, client):
    fake_supabase.seed_candidate("cand-1", "org-1", "ada@example.com")

    resp = client.post("/interview-codes/generate", json={
        "candidate_id": "cand-1", "organization_id": "org-1", "role_title": "Backend Engineer",
    }, headers=_AUTH_ORG_1)
    assert resp.status_code == 200, resp.text
    code_id = resp.json()["id"]

    # /interview-codes/{id}/emails now requires auth (Phase 1.3) — it used
    # to leak candidate email addresses and send-attempt error text to any
    # caller who could name a code_id.
    emails = client.get(f"/interview-codes/{code_id}/emails", headers=_AUTH_ORG_1).json()["emails"]
    assert len(emails) == 1
    assert emails[0]["email_type"] == "invitation"
    # No EMAIL_PROVIDER configured in this sandbox — the honest degraded
    # path (NullEmailProvider) reports a real failure, never a fake success.
    assert emails[0]["status"] == "failed"
    assert "not configured" in emails[0]["last_error"]
    assert emails[0]["attempts"] == 3, "retry limit should have been exhausted"


def test_generating_a_code_for_a_candidate_with_no_email_skips_silently(fake_supabase, client):
    fake_supabase.tables["candidates"].append({
        "id": "cand-2", "organization_id": "org-1", "name": "No Email", "email": None,
        "resume_path": None,
    })

    resp = client.post("/interview-codes/generate", json={
        "candidate_id": "cand-2", "organization_id": "org-1", "role_title": "Backend Engineer",
    }, headers=_AUTH_ORG_1)
    assert resp.status_code == 200, resp.text
    code_id = resp.json()["id"]

    emails = client.get(f"/interview-codes/{code_id}/emails", headers=_AUTH_ORG_1).json()["emails"]
    assert emails == []


def test_resend_invitation_creates_a_new_attempt(fake_supabase, client):
    fake_supabase.seed_candidate("cand-3", "org-1", "resend@example.com")
    resp = client.post("/interview-codes/generate", json={
        "candidate_id": "cand-3", "organization_id": "org-1", "role_title": "Backend Engineer",
    }, headers=_AUTH_ORG_1)
    code_id = resp.json()["id"]

    # /interview-codes/resend-invitation now requires auth (Phase 1.3) — it
    # used to let anyone who could name a code_id make this service send a
    # real email on demand, with no rate limit anywhere in the chain.
    resend_resp = client.post(
        "/interview-codes/resend-invitation", json={"code_id": code_id}, headers=_AUTH_ORG_1,
    )
    assert resend_resp.status_code == 200, resend_resp.text
    assert resend_resp.json()["status"] == "failed"

    emails = client.get(f"/interview-codes/{code_id}/emails", headers=_AUTH_ORG_1).json()["emails"]
    assert len(emails) == 1, "resend reuses the same invitation row, does not duplicate it"
