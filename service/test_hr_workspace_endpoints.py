"""Route-level tests for the two Phase 2 backend additions:
- GET /candidates now attaches `processing_status` from candidate_ai_profile.
- GET /interview-codes (new) lists an org's codes with invitation email
  status attached.

Both exist because the HR frontend genuinely cannot show "who's being
processed" or "was this candidate emailed" without them — see main.py's
docstrings on the two routes for why."""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from notifications import store as email_store
from pipeline import demo_store, supabase_store
from session import codes_store, session_store


class _FakeResponse:
    def __init__(self, status_code, payload=None):
        self.status_code = status_code
        self._payload = payload
        self.text = "" if payload is None else str(payload)
        self.content = b"x" if payload is not None else b""

    def json(self):
        return self._payload


class _FakeSupabase:
    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "candidates": [], "candidate_ai_profile": [],
            "interview_codes": [], "interview_code_emails": [],
        }

    def _filtered(self, table, params):
        rows = self.tables[table]

        def matches(row):
            for key, value in params.items():
                if key in ("select", "order", "limit"):
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
            return _FakeResponse(200, payload=self._filtered(table, params))
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


@pytest.fixture
def fake_supabase(monkeypatch):
    fake = _FakeSupabase()
    for module in (supabase_store, session_store, codes_store, demo_store, email_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))
    return fake


@pytest.fixture
def client(fake_supabase, monkeypatch):
    import main

    async def fake_resolve(token):
        # app_metadata, mirroring what GoTrue returns for a real user since
        # migration 0012 — the org id lives where the account holder cannot
        # write it. A fake that kept answering `user_metadata` would let the
        # bypass back in without a single test going red.
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    return TestClient(main.app)


def _auth(org: str) -> dict:
    return {"Authorization": f"Bearer test-token-{org}"}


def test_candidates_list_attaches_processing_status(client, fake_supabase):
    fake_supabase.tables["candidates"].append({
        "id": "cand-1", "organization_id": "org-1", "name": "Ada", "email": "a@example.com",
    })
    fake_supabase.tables["candidate_ai_profile"].append({
        "candidate_id": "cand-1", "organization_id": "org-1", "processing_status": "READY_FOR_INTERVIEW",
    })

    resp = client.get("/candidates", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    candidates = resp.json()["candidates"]
    assert candidates[0]["processing_status"] == "READY_FOR_INTERVIEW"


def test_candidates_list_reports_none_when_no_profile_yet(client, fake_supabase):
    fake_supabase.tables["candidates"].append({
        "id": "cand-2", "organization_id": "org-1", "name": "No Profile Yet", "email": "b@example.com",
    })

    resp = client.get("/candidates", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["candidates"][0]["processing_status"] is None


def test_interview_codes_list_requires_auth(client):
    resp = client.get("/interview-codes")
    assert resp.status_code == 401


def test_interview_codes_list_attaches_invitation_status(client, fake_supabase):
    fake_supabase.tables["interview_codes"].append({
        "id": "code-1", "organization_id": "org-1", "candidate_id": "cand-1",
        "code": "ABCD1234", "role_title": "Backend Engineer", "status": "active",
    })
    fake_supabase.tables["interview_code_emails"].append({
        "code_id": "code-1", "organization_id": "org-1", "email_type": "invitation",
        "status": "sent", "last_error": None,
    })

    resp = client.get("/interview-codes", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    codes = resp.json()["interview_codes"]
    assert codes[0]["invitation_status"] == "sent"
    assert codes[0]["invitation_error"] is None


def test_interview_codes_list_is_scoped_to_the_caller_org(client, fake_supabase):
    fake_supabase.tables["interview_codes"].append({
        "id": "code-2", "organization_id": "org-2", "candidate_id": "cand-2",
        "code": "WXYZ5678", "role_title": "x", "status": "active",
    })

    resp = client.get("/interview-codes", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["interview_codes"] == []


def test_interview_codes_list_reports_no_invitation_status_when_never_sent(client, fake_supabase):
    fake_supabase.tables["interview_codes"].append({
        "id": "code-3", "organization_id": "org-1", "candidate_id": "cand-1",
        "code": "NOEMAIL1", "role_title": "x", "status": "active",
    })

    resp = client.get("/interview-codes", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["interview_codes"][0]["invitation_status"] is None
