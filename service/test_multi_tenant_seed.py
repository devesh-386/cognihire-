"""Proves the multi-tenant demo seed (demo/multi_tenant_seed.py, Part 28 of
the intake work) does what it claims: two organizations both run a "Backend
Engineer" role with no collision, one role runs two separate intakes whose
candidates never mix, and re-seeding is idempotent — same fake-PostgREST
pattern as test_demo_seed.py, extended with an `intakes` table."""

from __future__ import annotations

import asyncio
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from demo import multi_tenant_seed
from pipeline import demo_store, supabase_store
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


class _FakeBackend:
    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "organizations": [], "roles": [], "candidates": [], "intakes": [],
            "candidate_ai_profile": [], "interview_codes": [],
        }
        self.storage: dict[str, bytes] = {}
        self._next_id = {t: 1 for t in self.tables}

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

        if "/storage/v1/object/" in parsed.path:
            path = parsed.path.split("/storage/v1/object/", 1)[1]
            if method == "POST":
                self.storage[path] = kwargs.get("content", b"")
                return _FakeResponse(200)
            data = self.storage.get(path)
            return _FakeResponse(200, content=data) if data is not None else _FakeResponse(404)

        table = parsed.path.rsplit("/", 1)[-1]
        if table not in self.tables:
            return _FakeResponse(404, payload={"error": f"unknown table {table}"})

        if method == "GET":
            return _FakeResponse(200, payload=self._filtered(table, params))

        if method == "POST":
            body = kwargs.get("json")
            rows = body if isinstance(body, list) else [body]
            inserted = []
            for row in rows:
                row = dict(row)
                row.setdefault("id", f"{table}-{self._next_id[table]}")
                self._next_id[table] += 1
                row.setdefault("status", row.get("status", "active"))
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
    def __init__(self, fake: _FakeBackend, **_):
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


def _run(coro):
    return asyncio.run(coro)


@pytest.fixture
def fake_backend(monkeypatch):
    fake = _FakeBackend()
    for module in (supabase_store, session_store, codes_store, demo_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))
    return fake


def test_seeds_two_organizations(fake_backend):
    result = _run(multi_tenant_seed.seed_multi_tenant_demo())

    names = {org["organization_name"] for org in result["organizations"]}
    assert names == {"Innotech Solutions", "Vertex Systems"}
    assert len(fake_backend.tables["organizations"]) == 2


def test_backend_engineer_title_does_not_collide_across_orgs(fake_backend):
    result = _run(multi_tenant_seed.seed_multi_tenant_demo())

    backend_roles = [r for org in result["organizations"] for r in org["roles"] if r["title"] == "Backend Engineer"]
    assert len(backend_roles) == 2
    assert backend_roles[0]["id"] != backend_roles[1]["id"]

    role_orgs = {row["organization_id"] for row in fake_backend.tables["roles"] if row["title"] == "Backend Engineer"}
    assert len(role_orgs) == 2


def test_one_role_runs_two_separate_intakes(fake_backend):
    result = _run(multi_tenant_seed.seed_multi_tenant_demo())

    innotech = next(o for o in result["organizations"] if o["organization_name"] == "Innotech Solutions")
    intake_names = {i["name"] for i in innotech["intakes"]}
    assert intake_names == {"August 2026 Intake", "October 2026 Intake"}

    candidates_by_intake = {}
    for c in innotech["candidates"]:
        candidates_by_intake.setdefault(c["intake_id"], []).append(c["name"])
    # Two intakes, two candidates, one each — never sharing a pipeline.
    assert len(candidates_by_intake) == 2
    assert all(len(names) == 1 for names in candidates_by_intake.values())


def test_every_candidate_has_organization_role_and_intake_set(fake_backend):
    _run(multi_tenant_seed.seed_multi_tenant_demo())

    for row in fake_backend.tables["candidates"]:
        assert row.get("organization_id")
        assert row.get("role_id")
        assert row.get("intake_id")


def test_seeding_twice_does_not_duplicate_anything(fake_backend):
    _run(multi_tenant_seed.seed_multi_tenant_demo())
    _run(multi_tenant_seed.seed_multi_tenant_demo())

    assert len(fake_backend.tables["organizations"]) == 2
    assert len(fake_backend.tables["roles"]) == 2
    assert len(fake_backend.tables["intakes"]) == 3  # 2 for Innotech, 1 for Vertex
    assert len(fake_backend.tables["candidates"]) == 3
