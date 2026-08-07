"""Tests for Ticket 19's demo environment: seeding is idempotent, produces
a genuine (pipeline-processed) candidate per resume profile, and reset
clears interview activity while preserving the seeded org/roles/candidates."""

from __future__ import annotations

import asyncio
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from demo import reset as demo_reset
from demo import seed as demo_seed
from demo.seed_data import DEMO_CANDIDATES, DEMO_ORG_NAME, DEMO_ROLES
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
    """Same minimal PostgREST-shaped fake as `test_end_to_end.py`, extended
    with organizations/roles/candidates, `in.`-filtered DELETE, and a tiny
    GoTrue admin-users stand-in — everything the demo seed/reset flow
    touches beyond what the RC1 fake covered."""

    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "organizations": [], "roles": [], "candidates": [],
            "candidate_ai_profile": [], "interview_codes": [],
            "interview_sessions": [], "interview_events": [],
        }
        self.storage: dict[str, bytes] = {}
        self.auth_users: list[dict] = []
        self._next_id = {t: 1 for t in self.tables}
        self._next_auth_id = 1

    def _filtered(self, table, params):
        rows = self.tables[table]

        def matches(row):
            for key, value in params.items():
                if key in ("select", "order", "limit", "on_conflict"):
                    continue
                if not isinstance(value, str):
                    continue
                if value.startswith("eq."):
                    if str(row.get(key)) != value[3:]:
                        return False
                elif value.startswith("in."):
                    allowed = value[3:].strip("()").split(",")
                    if str(row.get(key)) not in allowed:
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

        if "/auth/v1/admin/users" in parsed.path:
            if method == "GET":
                return _FakeResponse(200, payload={"users": self.auth_users})
            if method == "POST":
                body = kwargs.get("json") or {}
                user = {"id": f"auth-user-{self._next_auth_id}", **body}
                self._next_auth_id += 1
                self.auth_users.append(user)
                return _FakeResponse(200, payload=user)
            return _FakeResponse(405)

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
            # result below what matched — see session_store.next_sequence's
            # real 206 bug this fake now models.
            status = 206 if limit is not None and len(matched) < total else 200
            return _FakeResponse(status, payload=matched, headers={"content-range": f"*/{total}"})

        if method == "POST":
            body = kwargs.get("json")
            rows = body if isinstance(body, list) else [body]
            on_conflict = params.get("on_conflict")
            inserted = []
            for row in rows:
                row = dict(row)
                if on_conflict and any(r.get(on_conflict) == row.get(on_conflict) for r in self.tables[table]):
                    for existing in self.tables[table]:
                        if existing.get(on_conflict) == row.get(on_conflict):
                            existing.update(row)
                            inserted.append(existing)
                else:
                    if "id" not in row:
                        row["id"] = f"{table}-{self._next_id[table]}"
                        self._next_id[table] += 1
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

        if method == "DELETE":
            matched = self._filtered(table, params)
            self.tables[table] = [r for r in self.tables[table] if r not in matched]
            return _FakeResponse(204)

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

    async def request(self, method, url, **kwargs):
        return await self._fake.request(method, url, **kwargs)


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


def test_seed_creates_org_hr_login_roles_and_all_candidates(fake_backend):
    result = _run(demo_seed.seed_demo_environment())

    assert result["organization_name"] == DEMO_ORG_NAME
    assert result["hr_login"]["email"]
    assert len(result["roles"]) == len(DEMO_ROLES)
    assert len(result["candidates"]) == len(DEMO_CANDIDATES)

    for candidate in result["candidates"]:
        # Every candidate went through the real pipeline in degraded mode —
        # the same guarantee RC1 (Ticket 14) already proved for one
        # candidate, now asserted across all five demo profiles.
        assert candidate["profile_status"] == "READY_FOR_INTERVIEW"
        assert len(candidate["interview_code"]) == 8

    assert len(fake_backend.tables["candidate_ai_profile"]) == len(DEMO_CANDIDATES)
    assert len(fake_backend.auth_users) == 1


def test_seeding_twice_does_not_duplicate_anything(fake_backend):
    _run(demo_seed.seed_demo_environment())
    _run(demo_seed.seed_demo_environment())

    assert len(fake_backend.tables["organizations"]) == 1
    assert len(fake_backend.tables["roles"]) == len(DEMO_ROLES)
    assert len(fake_backend.tables["candidates"]) == len(DEMO_CANDIDATES)
    assert len(fake_backend.auth_users) == 1


def test_reset_clears_sessions_and_codes_but_keeps_candidates(fake_backend):
    seeded = _run(demo_seed.seed_demo_environment())
    org_id = seeded["organization_id"]

    # Simulate a rehearsal run: one session, one event, both tied to the org.
    fake_backend.tables["interview_sessions"].append({
        "id": "demo-session-1", "organization_id": org_id, "candidate_id": "x",
        "status": "complete",
    })
    fake_backend.tables["interview_events"].append({
        "id": 1, "session_id": "demo-session-1", "sequence": 1,
        "event_type": "session_started", "payload": {},
    })
    codes_before = len(fake_backend.tables["interview_codes"])
    assert codes_before == len(DEMO_CANDIDATES)

    result = _run(demo_reset.reset_demo_environment())

    assert result["status"] == "reset"
    assert result["sessions_deleted"] == 1
    assert not fake_backend.tables["interview_sessions"]
    assert not fake_backend.tables["interview_events"]
    # Fresh codes were re-issued, one per candidate, as part of restoring
    # initial state.
    assert len(fake_backend.tables["interview_codes"]) == len(DEMO_CANDIDATES)

    # Candidates, profiles, roles, and the org itself were never touched.
    assert len(fake_backend.tables["candidates"]) == len(DEMO_CANDIDATES)
    assert len(fake_backend.tables["candidate_ai_profile"]) == len(DEMO_CANDIDATES)
    assert len(fake_backend.tables["organizations"]) == 1


def test_reset_without_a_prior_seed_reports_no_environment(fake_backend):
    result = _run(demo_reset.reset_demo_environment())
    assert result["status"] == "no_demo_environment"
