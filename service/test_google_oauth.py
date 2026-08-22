"""Route-level tests for the per-org Google OAuth connect/status/callback
flow (Part 8 of the intake work). Google's own endpoints are faked
alongside Supabase's, dispatched by host, since the callback route talks to
both in one request."""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from pipeline import demo_store, google_oauth_store, supabase_store


class _FakeResponse:
    def __init__(self, status_code, payload=None):
        self.status_code = status_code
        self._payload = payload
        self.text = "" if payload is None else str(payload)

    def json(self):
        return self._payload


class _FakeBackend:
    def __init__(self):
        self.tables: dict[str, list[dict]] = {"intakes": [], "roles": [], "organizations": []}
        self.google_token_calls: list[dict] = []

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

        if "accounts.google.com" in parsed.netloc or "oauth2.googleapis.com" in parsed.netloc:
            self.google_token_calls.append(kwargs.get("data", {}))
            return _FakeResponse(200, payload={
                "access_token": "fake-access-token",
                "refresh_token": "fake-refresh-token",
                "expires_in": 3600,
                "scope": "forms.body drive.file",
            })
        if "googleapis.com/oauth2/v2/userinfo" in url:
            return _FakeResponse(200, payload={"email": "hr@innotech.example"})

        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        params.update(kwargs.get("params") or {})
        table = parsed.path.rsplit("/", 1)[-1]
        if table == "google_oauth_connections":
            if method == "GET":
                return _FakeResponse(200, payload=self._filtered("intakes", params) and [] or
                                      [r for r in getattr(self, "_connections", []) if
                                       r.get("organization_id") == params.get("organization_id", "eq.").removeprefix("eq.")])
            if method == "POST":
                if not hasattr(self, "_connections"):
                    self._connections = []
                row = dict(kwargs.get("json") or {})
                self._connections = [c for c in self._connections if c["organization_id"] != row["organization_id"]]
                self._connections.append(row)
                return _FakeResponse(201, payload=[row])
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

    async def post(self, url, **kwargs):
        return await self._fake.request("POST", url, **kwargs)


@pytest.fixture
def fake_backend(monkeypatch):
    fake = _FakeBackend()
    for module in (supabase_store, demo_store, google_oauth_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))
    return fake


@pytest.fixture
def client(fake_backend, monkeypatch):
    import main

    async def fake_resolve(token):
        # app_metadata, mirroring what GoTrue returns for a real user since
        # migration 0012 — the org id lives where the account holder cannot
        # write it. A fake that kept answering `user_metadata` would let the
        # bypass back in without a single test going red.
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_ID", "fake-client-id")
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_SECRET", "fake-client-secret")
    monkeypatch.setenv("GOOGLE_OAUTH_REDIRECT_URI", "https://api.cognihire.online/google/oauth/callback")
    monkeypatch.setenv("GOOGLE_OAUTH_STATE_SECRET", "fake-state-secret")
    return TestClient(main.app)


def _auth(org: str) -> dict:
    return {"Authorization": f"Bearer test-token-{org}"}


def test_connect_requires_auth(client):
    resp = client.get("/organizations/org-1/google/connect")
    assert resp.status_code == 401


def test_connect_rejects_a_different_orgs_id(client):
    resp = client.get("/organizations/org-2/google/connect", headers=_auth("org-1"))
    assert resp.status_code == 404


def test_connect_returns_a_google_authorize_url(client):
    resp = client.get("/organizations/org-1/google/connect", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    url = resp.json()["authorize_url"]
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "client_id=fake-client-id" in url
    assert "state=org-1" in url  # state begins with the org id, unsigned parts stay readable


def test_connect_503s_clearly_when_oauth_client_is_not_configured(client, monkeypatch):
    monkeypatch.delenv("GOOGLE_OAUTH_CLIENT_ID", raising=False)
    resp = client.get("/organizations/org-1/google/connect", headers=_auth("org-1"))
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"]


def test_status_reports_not_connected_before_any_callback(client):
    resp = client.get("/organizations/org-1/google/status", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"connected": False, "google_account_email": None}


def test_callback_rejects_a_tampered_state(client):
    resp = client.get(
        "/google/oauth/callback",
        params={"code": "auth-code", "state": "org-1:nonce:not-the-real-signature"},
        follow_redirects=False,
    )
    assert resp.status_code == 400


def test_callback_stores_the_connection_and_status_then_reports_it(client, fake_backend):
    connect_resp = client.get("/organizations/org-1/google/connect", headers=_auth("org-1"))
    state = parse_qs(urlparse(connect_resp.json()["authorize_url"]).query)["state"][0]

    callback_resp = client.get(
        "/google/oauth/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    assert callback_resp.status_code in (302, 307), callback_resp.text

    status_resp = client.get("/organizations/org-1/google/status", headers=_auth("org-1"))
    assert status_resp.json() == {"connected": True, "google_account_email": "hr@innotech.example"}


def test_creating_a_form_without_a_connection_asks_to_connect_first(client, fake_backend):
    fake_backend.tables["intakes"].append({
        "id": "intake-1", "organization_id": "org-1", "role_id": "role-1", "name": "August 2026", "status": "active",
    })
    resp = client.post("/intakes/intake-1/google-form", headers=_auth("org-1"))
    assert resp.status_code == 409
    assert "connect" in resp.json()["detail"].lower()
