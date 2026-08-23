"""Route-level tests for the per-org Google OAuth connect/status/callback
flow (Part 8 of the intake work). Google's own endpoints are faked
alongside Supabase's, dispatched by host, since the callback route talks to
both in one request."""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from cryptography.fernet import Fernet
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
    monkeypatch.setenv("GOOGLE_TOKEN_ENCRYPTION_KEY", Fernet.generate_key().decode())
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


def test_tokens_are_encrypted_in_the_stored_row_not_plaintext(client, fake_backend):
    """The bug this closes: google_oauth_connections.access_token/refresh_token
    were written verbatim — readable by anyone with DB read access (a leaked
    service-role key, a backup, a misconfigured RLS policy) without needing
    to touch Google at all."""
    connect_resp = client.get("/organizations/org-1/google/connect", headers=_auth("org-1"))
    state = parse_qs(urlparse(connect_resp.json()["authorize_url"]).query)["state"][0]
    client.get(
        "/google/oauth/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )

    stored = fake_backend._connections[0]
    assert stored["access_token"] != "fake-access-token"
    assert stored["refresh_token"] != "fake-refresh-token"
    assert "fake-access-token" not in stored["access_token"]


def test_creating_a_form_without_a_connection_asks_to_connect_first(client, fake_backend):
    fake_backend.tables["intakes"].append({
        "id": "intake-1", "organization_id": "org-1", "role_id": "role-1", "name": "August 2026", "status": "active",
    })
    resp = client.post("/intakes/intake-1/google-form", headers=_auth("org-1"))
    assert resp.status_code == 409
    assert "connect" in resp.json()["detail"].lower()


# --- /internal/google/access-token -------------------------------------
#
# The intake-form-poller Edge Function used to read access_token/
# refresh_token straight out of google_oauth_connections. Once those columns
# became Fernet ciphertext, that read sent ciphertext to Google as a refresh
# token (HTTP 400) while the function still returned 200 — a silent, total
# failure of Google Forms polling. These tests pin the replacement: Deno asks
# this service for a token, and never touches the encrypted columns.


def _seed_connection(fake_backend, org, *, expires_at):
    """Seed a row the way the DB really holds it — ciphertext, not plaintext."""
    import datetime

    from security import token_crypto

    fake_backend._connections = getattr(fake_backend, "_connections", [])
    fake_backend._connections.append({
        "organization_id": org,
        "google_account_email": "hr@innotech.example",
        "access_token": token_crypto.encrypt("stored-access-token"),
        "refresh_token": token_crypto.encrypt("stored-refresh-token"),
        "token_expires_at": expires_at.isoformat(),
        "scope": "forms.body drive.file",
    })


def _future(seconds=3600):
    import datetime
    return datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)


def _past(seconds=3600):
    import datetime
    return datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds)


def _internal(secret="fake-internal-secret") -> dict:
    return {"x-internal-secret": secret}


def test_access_token_rejects_a_missing_secret(client, monkeypatch):
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "fake-internal-secret")
    resp = client.post("/internal/google/access-token", params={"organization_id": "org-1"})
    assert resp.status_code == 401


def test_access_token_rejects_a_wrong_secret(client, monkeypatch):
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "fake-internal-secret")
    resp = client.post(
        "/internal/google/access-token",
        params={"organization_id": "org-1"}, headers=_internal("not-the-secret"),
    )
    assert resp.status_code == 401


def test_access_token_refuses_when_no_secret_is_configured(client, monkeypatch):
    # An unset INTERNAL_AUTOINVITE_SECRET must fail closed, not authorise
    # everyone by comparing "" to "".
    monkeypatch.delenv("INTERNAL_AUTOINVITE_SECRET", raising=False)
    resp = client.post(
        "/internal/google/access-token",
        params={"organization_id": "org-1"}, headers=_internal(""),
    )
    assert resp.status_code == 401


def test_access_token_returns_503_when_the_org_never_connected(client, monkeypatch):
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "fake-internal-secret")
    resp = client.post(
        "/internal/google/access-token",
        params={"organization_id": "org-nope"}, headers=_internal(),
    )
    # The poller keys "skip this intake quietly" off exactly this status.
    assert resp.status_code == 503


def test_access_token_decrypts_a_live_stored_token(client, fake_backend, monkeypatch):
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "fake-internal-secret")
    _seed_connection(fake_backend, "org-1", expires_at=_future())

    resp = client.post(
        "/internal/google/access-token",
        params={"organization_id": "org-1"}, headers=_internal(),
    )

    assert resp.status_code == 200, resp.text
    # Plaintext out, even though the row holds ciphertext. This is the exact
    # value the old Edge Function failed to produce.
    assert resp.json()["access_token"] == "stored-access-token"


def test_access_token_refreshes_an_expired_token_without_storing_plaintext(
    client, fake_backend, monkeypatch,
):
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "fake-internal-secret")
    _seed_connection(fake_backend, "org-1", expires_at=_past())

    resp = client.post(
        "/internal/google/access-token",
        params={"organization_id": "org-1"}, headers=_internal(),
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["access_token"] == "fake-access-token"

    # Google was asked to refresh with the DECRYPTED refresh token. Sending
    # ciphertext here is precisely what produced HTTP 400 on every run.
    assert fake_backend.google_token_calls
    assert fake_backend.google_token_calls[-1]["refresh_token"] == "stored-refresh-token"

    # And the refreshed token went back to the DB re-encrypted. The old Edge
    # Function wrote it in plaintext, silently corrupting the column for the
    # service that owns the key.
    from security import token_crypto

    stored = [c for c in fake_backend._connections if c["organization_id"] == "org-1"][-1]
    assert stored["access_token"] != "fake-access-token"
    assert token_crypto.decrypt(stored["access_token"]) == "fake-access-token"
