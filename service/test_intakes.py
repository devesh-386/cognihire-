"""Route-level tests for /intakes — the org -> role -> intake -> candidate
ownership chain. Two isolation layers are exercised: the application-layer
check in main.py (a role_id that belongs to a different org is rejected
before an insert is even attempted) and the status state machine. The
database trigger that makes the same guarantee at the SQL level
(infra/migrations/0008_intakes.sql's check_intake_role_org) is verified
separately against the live Supabase project, not here — a fake REST layer
can't exercise a real Postgres trigger."""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from pipeline import demo_store, supabase_store


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
        self.tables: dict[str, list[dict]] = {"roles": [], "intakes": []}
        self._next_id = 0

    def _new_id(self, prefix: str) -> str:
        self._next_id += 1
        return f"{prefix}-{self._next_id}"

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

        if method == "POST":
            row = dict(kwargs.get("json") or {})
            row.setdefault("id", self._new_id(table))
            row.setdefault("status", "draft")
            self.tables[table].append(row)
            return _FakeResponse(201, payload=[row])

        if method == "PATCH":
            target_id = params.get("id", "").removeprefix("eq.")
            fields = kwargs.get("json") or {}
            for row in self.tables[table]:
                if row.get("id") == target_id:
                    row.update(fields)
            return _FakeResponse(200, payload=[])

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
    for module in (supabase_store, demo_store):
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


def test_create_intake_requires_auth(client):
    resp = client.post("/intakes", json={"role_id": "role-1", "name": "August 2026"})
    assert resp.status_code == 401


def test_create_intake_succeeds_for_a_role_in_the_callers_org(client, fake_supabase):
    fake_supabase.tables["roles"].append({"id": "role-1", "organization_id": "org-1", "title": "Backend Engineer"})

    resp = client.post("/intakes", json={"role_id": "role-1", "name": "August 2026"}, headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["organization_id"] == "org-1"
    assert body["role_id"] == "role-1"
    assert body["status"] == "draft"


def test_create_intake_rejects_a_role_belonging_to_a_different_org(client, fake_supabase):
    fake_supabase.tables["roles"].append({"id": "role-2", "organization_id": "org-2", "title": "Backend Engineer"})

    resp = client.post("/intakes", json={"role_id": "role-2", "name": "Sneaky"}, headers=_auth("org-1"))
    assert resp.status_code == 404


def test_list_intakes_is_scoped_to_the_caller_org(client, fake_supabase):
    fake_supabase.tables["intakes"].append({
        "id": "intake-1", "organization_id": "org-1", "role_id": "role-1", "name": "Org 1's intake", "status": "active",
    })
    fake_supabase.tables["intakes"].append({
        "id": "intake-2", "organization_id": "org-2", "role_id": "role-2", "name": "Org 2's intake", "status": "active",
    })

    resp = client.get("/intakes", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    intakes = resp.json()["intakes"]
    assert [i["id"] for i in intakes] == ["intake-1"]


def test_get_intake_404s_across_the_org_boundary(client, fake_supabase):
    fake_supabase.tables["intakes"].append({
        "id": "intake-3", "organization_id": "org-2", "role_id": "role-2", "name": "Not yours", "status": "active",
    })

    resp = client.get("/intakes/intake-3", headers=_auth("org-1"))
    assert resp.status_code == 404


def test_patch_intake_allows_draft_to_active(client, fake_supabase):
    fake_supabase.tables["intakes"].append({
        "id": "intake-4", "organization_id": "org-1", "role_id": "role-1", "name": "x", "status": "draft",
    })

    resp = client.patch("/intakes/intake-4", json={"status": "active"}, headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "active"


def test_patch_intake_rejects_reopening_a_closed_intake(client, fake_supabase):
    fake_supabase.tables["intakes"].append({
        "id": "intake-5", "organization_id": "org-1", "role_id": "role-1", "name": "x", "status": "closed",
    })

    resp = client.patch("/intakes/intake-5", json={"status": "active"}, headers=_auth("org-1"))
    assert resp.status_code == 409


def test_patch_intake_rejects_an_unknown_status(client, fake_supabase):
    fake_supabase.tables["intakes"].append({
        "id": "intake-6", "organization_id": "org-1", "role_id": "role-1", "name": "x", "status": "draft",
    })

    resp = client.patch("/intakes/intake-6", json={"status": "hired"}, headers=_auth("org-1"))
    assert resp.status_code == 422
