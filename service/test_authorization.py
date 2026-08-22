"""Route-level tests for the Phase 1 security fixes: every route that used
to trust a client-supplied id (organization_id, candidate_id, session_id) now
either resolves identity from a bearer token or requires the interview code
that was already the candidate's real credential. Also covers the
non-production gate on /demo/seed and /demo/reset, and the rate limiter on
the public AI-expensive routes.

Uses the same in-memory PostgREST-shaped fake as test_email_routes.py /
test_end_to_end.py, kept local rather than imported so this file's fixtures
don't depend on another test module's internals.
"""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from pipeline import demo_store, supabase_store
from session import codes_store, session_store


class _FakeResponse:
    def __init__(self, status_code, payload=None, headers=None):
        self.status_code = status_code
        self._payload = payload
        self.headers = headers or {}
        self.text = "" if payload is None else str(payload)
        self.content = b"x" if payload is not None else b""

    def json(self):
        return self._payload


class _FakeSupabase:
    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "candidates": [], "candidate_ai_profile": [],
            "interview_codes": [], "interview_sessions": [], "interview_events": [],
        }
        self._next_id = {"interview_sessions": 1, "interview_codes": 1}

    def seed_candidate(self, candidate_id, organization_id, email="c@example.com"):
        self.tables["candidates"].append({
            "id": candidate_id, "organization_id": organization_id,
            "name": "Test Candidate", "email": email, "resume_path": None,
        })

    def seed_session(self, session_id, organization_id, **extra):
        self.tables["interview_sessions"].append({
            "id": session_id, "organization_id": organization_id,
            "status": "in_progress", "role_title": "Backend Engineer",
            "question_plan": {"topics": []}, "coverage_state": {"completion_percent": 0},
            "outcomes": {}, "current_topic": None, "last_question": None,
            **extra,
        })

    def seed_code(self, code_id, code, session_id=None, **extra):
        self.tables["interview_codes"].append({
            "id": code_id, "code": code, "session_id": session_id,
            "attempts_used": 1, "max_attempts": 3, "status": "active",
            "candidate_id": "cand-x", "organization_id": "org-1",
            "role_title": "Backend Engineer", "required_skills": [],
            "expires_at": "2099-01-01T00:00:00+00:00",
            "window_start": None, "window_end": None,
            **extra,
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
            return _FakeResponse(200, payload=self._filtered(table, params))

        if method == "POST":
            body = kwargs.get("json")
            rows = body if isinstance(body, list) else [body]
            inserted = []
            for row in rows:
                row = dict(row)
                if "id" not in row and table in self._next_id:
                    row["id"] = f"{table}-{self._next_id[table]}"
                    self._next_id[table] += 1
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
    for module in (supabase_store, session_store, codes_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))
    return fake


@pytest.fixture
def client(fake_supabase, monkeypatch):
    import main
    from security import rate_limit

    rate_limit._reset_for_tests()

    async def fake_resolve(token):
        if token == "bad-token":
            raise supabase_store.SupabaseError("invalid or expired session")
        # app_metadata, mirroring what GoTrue returns for a real user since
        # migration 0012 — the org id lives where the account holder cannot
        # write it. A fake that kept answering `user_metadata` would let the
        # bypass back in without a single test going red.
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    return TestClient(main.app)


def _auth(org: str) -> dict:
    return {"Authorization": f"Bearer test-token-{org}"}


# --- where the caller's organization comes from ------------------------------
#
# The whole tenant boundary rests on one question: which JWT claim decides
# which company you are in. It used to be `user_metadata`, which GoTrue lets
# the account holder rewrite with its own token — so a recruiter could point
# themselves at another company and BOTH enforcement layers (these routes and
# the database's RLS policies, which read the same claim) would have agreed.
# These two tests pin the answer on the backend side.


def test_org_is_not_taken_from_user_writable_metadata(client, monkeypatch, fake_supabase):
    """A token carrying an organization ONLY in user_metadata grants nothing.

    This is the exact shape an attacker produces with
    `supabase.auth.updateUser({data: {organization_id: '<victim>'}})`.
    """
    async def user_metadata_only(token):
        return {"user_metadata": {"organization_id": "org-victim"}, "app_metadata": {}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", user_metadata_only)
    fake_supabase.seed_candidate("cand-victim", "org-victim")

    resp = client.get("/candidates", headers={"Authorization": "Bearer anything"})
    assert resp.status_code == 403, resp.text


def test_user_metadata_cannot_override_the_real_org(client, monkeypatch, fake_supabase):
    """When both claims are present, the service-role-only one wins.

    A user who rewrites their own metadata keeps exactly the access their
    real organization already gave them.
    """
    async def both_claims(token):
        return {
            "app_metadata": {"organization_id": "org-1"},      # what the admin API set
            "user_metadata": {"organization_id": "org-2"},     # what the user forged
        }

    monkeypatch.setattr(demo_store, "resolve_user_from_token", both_claims)
    fake_supabase.seed_candidate("cand-victim", "org-2")

    resp = client.post(
        "/interview-codes/generate",
        json={"candidate_id": "cand-victim", "organization_id": "org-2", "role_title": "x"},
        headers={"Authorization": "Bearer forged"},
    )
    assert resp.status_code == 404, resp.text


# --- /interview-codes/generate ----------------------------------------------


def test_generate_without_auth_is_rejected(client):
    resp = client.post("/interview-codes/generate", json={
        "candidate_id": "cand-1", "organization_id": "org-1", "role_title": "x",
    })
    assert resp.status_code == 401


def test_generate_with_invalid_token_is_rejected(client):
    resp = client.post(
        "/interview-codes/generate",
        json={"candidate_id": "cand-1", "organization_id": "org-1", "role_title": "x"},
        headers={"Authorization": "Bearer bad-token"},
    )
    assert resp.status_code == 401


def test_generate_for_a_candidate_in_another_org_is_rejected(client, fake_supabase):
    # The attack this closes: an authenticated HR user from org-1 tries to
    # mint an interview code for a candidate that actually belongs to org-2
    # — before this fix, `organization_id` came straight from the request
    # body and nothing checked it against the candidate's real org.
    fake_supabase.seed_candidate("cand-victim", "org-2")

    resp = client.post(
        "/interview-codes/generate",
        json={"candidate_id": "cand-victim", "organization_id": "org-2", "role_title": "x"},
        headers=_auth("org-1"),
    )
    assert resp.status_code == 404


def test_generate_for_own_org_candidate_succeeds(client, fake_supabase):
    fake_supabase.seed_candidate("cand-1", "org-1")
    resp = client.post(
        "/interview-codes/generate",
        json={"candidate_id": "cand-1", "organization_id": "org-1", "role_title": "x"},
        headers=_auth("org-1"),
    )
    assert resp.status_code == 200, resp.text
    assert len(resp.json()["code"]) == 8


# --- /interview/report/{session_id} -----------------------------------------


def test_report_without_auth_is_rejected(client, fake_supabase):
    fake_supabase.seed_session("sess-1", "org-1")
    resp = client.get("/interview/report/sess-1")
    assert resp.status_code == 401


def test_report_for_another_orgs_session_is_a_clean_404(client, fake_supabase):
    # The attack this closes: HR from org-1 (or anyone who obtained/guessed
    # a session_id) reading another org's full interview transcript and
    # verdicts, which was previously unauthenticated entirely.
    fake_supabase.seed_session("sess-victim", "org-2")
    resp = client.get("/interview/report/sess-victim", headers=_auth("org-1"))
    assert resp.status_code == 404


def test_report_for_own_orgs_session_succeeds(client, fake_supabase):
    fake_supabase.seed_session("sess-1", "org-1")
    resp = client.get("/interview/report/sess-1", headers=_auth("org-1"))
    assert resp.status_code == 200, resp.text


# --- /interview/answer and /interview/finish --------------------------------


def test_answer_with_wrong_code_is_rejected(client, fake_supabase):
    # The attack this closes: a stranger who obtained a session_id (browser
    # history, a referrer header, a log line) but not the candidate's actual
    # code could previously submit answers on, or end, someone else's
    # interview — session_id alone used to be treated as sufficient proof.
    fake_supabase.seed_session("sess-1", "org-1", current_topic="t1", last_question="Q?")
    fake_supabase.seed_code("code-1", "REALCODE", session_id="sess-1")

    resp = client.post("/interview/answer", json={
        "session_id": "sess-1", "answer_text": "hi", "code": "WRONGCOD",
    })
    assert resp.status_code == 403


def test_answer_with_correct_code_is_allowed_through_to_the_session_logic(client, fake_supabase):
    fake_supabase.seed_session("sess-1", "org-1", current_topic="t1", last_question="Q?")
    fake_supabase.seed_code("code-1", "REALCODE", session_id="sess-1")

    resp = client.post("/interview/answer", json={
        "session_id": "sess-1", "answer_text": "hi", "code": "REALCODE",
    })
    # Not asserting 200 here — the session/AI logic itself isn't this file's
    # concern (see test_session.py / test_interview_engine.py) — only that
    # the code check does not block a legitimate caller with a 403.
    assert resp.status_code != 403


def test_finish_with_wrong_code_is_rejected(client, fake_supabase):
    fake_supabase.seed_session("sess-1", "org-1")
    fake_supabase.seed_code("code-1", "REALCODE", session_id="sess-1")

    resp = client.post("/interview/finish", json={
        "session_id": "sess-1", "code": "WRONGCOD",
    })
    assert resp.status_code == 403


# --- /demo/seed and /demo/reset ---------------------------------------------


def test_demo_seed_is_blocked_in_production(client, monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    resp = client.post("/demo/seed")
    assert resp.status_code == 404


def test_demo_reset_is_blocked_in_production(client, monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    resp = client.post("/demo/reset")
    assert resp.status_code == 404


# --- rate limiting -----------------------------------------------------------


def test_extract_claims_is_rate_limited(client, monkeypatch):
    # The bucket allows 10/minute (main.py) — the 11th from the same client
    # IP within the window must be rejected, regardless of what the route
    # itself would otherwise do with the payload.
    from ai import claim_extraction

    async def fake_extract(document_text, source):
        from ai.claim_extraction import ClaimExtraction
        return ClaimExtraction(claims=[], kind="heuristic_rule",
                                degraded_reason=None, rejected_ungrounded=[])

    monkeypatch.setattr(claim_extraction, "extract_claims", fake_extract)

    statuses = []
    for _ in range(11):
        resp = client.post("/extract-claims", json={"document_text": "x", "source": "resume"})
        statuses.append(resp.status_code)

    assert statuses[:10] == [200] * 10
    assert statuses[10] == 429
