"""RC1 acceptance test — the full pipeline wired together and driven through
real FastAPI routes, not unit-called functions.

Every other test file in this suite proves one module (or one orchestrator)
in isolation. None of them prove that `main.py`'s routes actually thread a
request through pipeline → session → ai in the right order end to end. This
file does that, using `TestClient` against the real `app` object and a single
in-memory fake standing in for the whole Supabase REST/Storage surface.

## What this proves, and what it doesn't

With no `OPENAI_API_KEY` set (the default in this environment — see
`ai/provider.py`), every AI stage degrades to its deterministic fallback
before making any network call. This test therefore proves the PLUMBING: does
a resume actually flow PDF → text → profile → claims → plan → code →
session → answers → report, with every stage's output actually persisted and
readable by the next one, exactly the way `README.md`'s Ticket 14 asks. It
does NOT prove prompt quality, latency, or cost against a real model — that's
Ticket 15, deliberately out of scope here and gated on a real API key this
environment does not have.
"""

from __future__ import annotations

from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from pipeline import supabase_store
from session import codes_store, session_store


# --- A fake Supabase REST + Storage surface, shared across every store module ----


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
    """One in-memory table store, addressed the way PostgREST addresses
    tables: `eq.` filters, `Prefer: return=representation` on insert,
    `on_conflict` for upsert. Deliberately minimal — just enough of
    PostgREST's contract for the store modules this suite actually uses."""

    def __init__(self):
        self.tables: dict[str, list[dict]] = {
            "candidates": [],
            "candidate_ai_profile": [],
            "interview_codes": [],
            "interview_sessions": [],
            "interview_events": [],
        }
        self.storage: dict[str, bytes] = {}
        self._next_id = {"interview_sessions": 1, "interview_codes": 1}

    def seed_candidate(self, candidate_id, organization_id, resume_path, pdf_bytes):
        self.tables["candidates"].append({
            "id": candidate_id, "organization_id": organization_id,
            "name": "E2E Test Candidate", "email": "e2e@example.com",
            "resume_path": resume_path,
        })
        # supabase_store.download_resume prefixes with RESUME_BUCKET ("resumes")
        self.storage[f"resumes/{resume_path}"] = pdf_bytes

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

        matched = [r for r in rows if matches(r)]
        order = params.get("order")
        if order:
            field = order.split(".")[0]
            matched = sorted(matched, key=lambda r: r.get(field, 0))
        return matched

    async def request(self, method, url, **kwargs):
        parsed = urlparse(url)
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        params.update(kwargs.get("params") or {})

        if "/storage/v1/object/" in parsed.path:
            path = parsed.path.split("/storage/v1/object/", 1)[1]
            data = self.storage.get(path)
            if data is None:
                return _FakeResponse(404)
            return _FakeResponse(200, content=data)

        table = parsed.path.rsplit("/", 1)[-1]
        if table not in self.tables:
            return _FakeResponse(404, payload={"error": f"unknown table {table}"})

        if method == "GET":
            matched = self._filtered(table, params)
            total = len(matched)
            limit = params.get("limit")
            if limit is not None:
                matched = matched[: int(limit)]
            # PostgREST answers 206 Partial Content, not 200, whenever
            # `limit` returns fewer rows than actually matched — this is
            # what caught session_store.next_sequence's real bug (it only
            # accepted 200) against live Supabase; this fake used to always
            # return 200 regardless of `limit` and never would have caught it.
            status = 206 if limit is not None and len(matched) < total else 200
            return _FakeResponse(status, payload=matched,
                                  headers={"content-range": f"*/{total}"})

        if method == "POST":
            body = kwargs.get("json")
            rows = body if isinstance(body, list) else [body]
            on_conflict = params.get("on_conflict")
            inserted = []
            for row in rows:
                row = dict(row)
                if on_conflict and any(
                    r.get(on_conflict) == row.get(on_conflict) for r in self.tables[table]
                ):
                    for existing in self.tables[table]:
                        if existing.get(on_conflict) == row.get(on_conflict):
                            existing.update(row)
                            inserted.append(existing)
                else:
                    if "id" not in row and table in self._next_id:
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

        return _FakeResponse(405)


class _FakeAsyncClient:
    def __init__(self, fake: _FakeSupabase, **_):
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


def _make_pdf(text: str) -> bytes:
    """A minimal, genuinely-extractable single-page PDF — same construction
    as `test_pipeline.py`'s `_make_pdf`, kept local so this file proves the
    pipeline without importing another test module's fixtures."""
    lines = text.splitlines()
    parts = [b"BT /F1 12 Tf 50 750 Td 14 TL"]
    for line in lines:
        escaped = line.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
        parts.append(f"({escaped}) Tj T*".encode("latin-1", "replace"))
    parts.append(b"ET")
    stream = b"\n".join(parts)

    objects = [
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        b"<< /Type /Page /Parent 4 0 R /Resources << /Font << /F1 1 0 R >> >> "
        b"/MediaBox [0 0 612 792] /Contents 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Catalog /Pages 4 0 R >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref_offset = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 5 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF"
    ).encode()
    return bytes(out)


RESUME_TEXT = """Ada Lovelace
Senior Backend Engineer

Skills
Python, PostgreSQL, React, Docker

Experience
Built and shipped a React dashboard used by 200+ staff at Analytical Engines Inc.
Led a team of 4 engineers delivering the payments platform migration.
Designed the PostgreSQL schema for a multi-tenant SaaS product handling 10M rows.

Education
BSc Mathematics, University of London.
"""


@pytest.fixture
def fake_supabase(monkeypatch):
    fake = _FakeSupabase()
    # Each store module did `from pipeline.supabase_store import SUPABASE_URL,
    # SUPABASE_SERVICE_ROLE_KEY` — that copies the value at import time, so
    # patching only `supabase_store`'s attribute leaves session_store.py and
    # codes_store.py's own bound names untouched. Patch every copy.
    for module in (supabase_store, session_store, codes_store):
        monkeypatch.setattr(module, "SUPABASE_URL", "https://fake.supabase.co")
        monkeypatch.setattr(module, "SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key")
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(fake))
    return fake


@pytest.fixture
def client(fake_supabase, monkeypatch):
    import main  # imported here so the fixture's env patches are live first
    from pipeline import demo_store
    from security import rate_limit

    rate_limit._reset_for_tests()

    # /interview-codes/generate and /interview/report now resolve the
    # caller's org from a bearer token — see test_email_routes.py's client
    # fixture for the same pattern and why it's needed here.
    async def fake_resolve(token):
        return {"user_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    return TestClient(main.app)


_AUTH_E2E_ORG = {"Authorization": "Bearer test-token-e2e-org-1"}


def test_full_pipeline_resume_to_hr_report(fake_supabase, client):
    """The RC1 acceptance path: one candidate, walked stage by stage, with
    each stage's persisted output asserted before moving to the next —
    exactly the "do not proceed until verified" contract from the ticket."""

    # --- Stage: Google Form / apply-webhook equivalent -----------------------
    # (candidate + resume already in Storage — the trigger that creates this
    # is tested live against production in the Ticket 14 DB smoke test, not
    # here; this file starts from its effect.)
    fake_supabase.seed_candidate(
        "e2e-cand-1", "e2e-org-1", "e2e-org-1/e2e-cand-1-resume.pdf", _make_pdf(RESUME_TEXT)
    )
    assert fake_supabase.tables["candidates"], "candidate not seeded"

    # --- Stage: PDF extraction -> Resume understanding -> Claims -------------
    resp = client.post("/resumes/process", json={"candidate_id": "e2e-cand-1"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "READY_FOR_INTERVIEW"
    assert body["claim_count"] > 0, "no claims were extracted from real resume text"
    # Degraded (no API key) is expected and correct here — this proves the
    # fallback path works, which matters MORE before real tokens are spent.
    assert body["understanding_kind"] == "heuristic_rule"
    assert body["claim_extraction_kind"] == "heuristic_rule"

    profile_row = fake_supabase.tables["candidate_ai_profile"][0]
    assert profile_row["processing_status"] == "READY_FOR_INTERVIEW"
    assert profile_row["knowledge_profile"]["skills"], "knowledge profile has no skills"
    assert len(profile_row["claims"]) == body["claim_count"]

    # --- Stage: Interview code generation -------------------------------------
    resp = client.post("/interview-codes/generate", json={
        "candidate_id": "e2e-cand-1", "organization_id": "e2e-org-1",
        "role_title": "Backend Engineer",
    }, headers=_AUTH_E2E_ORG)
    assert resp.status_code == 200, resp.text
    code = resp.json()["code"]
    assert len(code) == 8
    assert fake_supabase.tables["interview_codes"][0]["status"] == "active"

    # --- Stage: Candidate portal -> /interview/start (question planning) -----
    resp = client.post("/interview/start", json={"code": code})
    assert resp.status_code == 200, resp.text
    turn1 = resp.json()
    session_id = turn1["session_id"]
    assert turn1["turn"]["kind"] == "question"
    assert turn1["turn"]["question"], "no question was generated"

    session_row = fake_supabase.tables["interview_sessions"][0]
    assert session_row["status"] == "in_progress"
    assert session_row["question_plan"]["topics"], "no topics were planned"

    # --- Stage: interview loop (answer -> analysis -> coverage -> next turn) -
    turn = turn1
    rounds = 0
    while turn["turn"]["kind"] != "complete" and rounds < 20:
        resp = client.post("/interview/answer", json={
            "session_id": session_id,
            "code": code,
            "answer_text": "I personally built and led this, working closely "
                            "with the team end to end and shipping it to production.",
        })
        assert resp.status_code == 200, resp.text
        turn = resp.json()
        assert "analysis" in turn
        rounds += 1
    assert turn["turn"]["kind"] == "complete", "interview did not reach completion"
    assert rounds > 0, "interview completed without a single answer turn"

    final_session = next(r for r in fake_supabase.tables["interview_sessions"]
                          if r["id"] == session_id)
    assert final_session["status"] == "complete"
    assert final_session["coverage_state"]["completion_percent"] == 100

    events = [e for e in fake_supabase.tables["interview_events"] if e["session_id"] == session_id]
    event_types = {e["event_type"] for e in events}
    assert {"session_started", "question", "answer", "analysis",
            "coverage_update", "session_complete"} <= event_types

    # The code should have flipped to 'used' now that its session completed.
    linked_code = fake_supabase.tables["interview_codes"][0]
    assert linked_code["status"] == "used"

    # --- Stage: candidate portal -> /interview/event (face check + behavior) --
    resp = client.post("/interview/event", json={
        "session_id": session_id, "code": code,
        "event_type": "face_verification",
        "payload": {"face_detected": True, "similarity": 0.94},
    })
    assert resp.status_code == 200, resp.text
    for event_type in ("tab_hidden", "tab_visible", "tab_hidden", "tab_visible"):
        resp = client.post("/interview/event", json={
            "session_id": session_id, "code": code, "event_type": event_type,
        })
        assert resp.status_code == 200, resp.text

    resp = client.post("/interview/event", json={
        "session_id": session_id, "code": code, "event_type": "not_a_real_event",
    })
    assert resp.status_code == 422, "unknown event_type should be rejected"

    # --- Stage: Evidence linking + report generation --------------------------
    resp = client.get(f"/interview/report/{session_id}", headers=_AUTH_E2E_ORG)
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["role_title"] == "Backend Engineer"
    assert report["completion_percent"] == 100
    assert report["topics"], "report has no topics"
    assert all(t["outcome"] is not None for t in report["topics"]), (
        "every planned topic was answered, so none should be missing an outcome"
    )
    assert report["behavior_signal_counts"]["tab_hidden"] == 2
    assert report["behavior_signal_counts"]["tab_visible"] == 2
    assert report["face_verification"] == {"face_detected": True, "similarity": 0.94}

    # --- Stage: HR desktop's read model ----------------------------------------
    # The Flutter "AI Interviews" screen reads interview_sessions/events
    # straight from Supabase (not through the gateway) — this asserts the
    # rows it depends on are exactly what got persisted above.
    assert session_row["role_title"] == "Backend Engineer"
    assert session_row["candidate_id"] == "e2e-cand-1"


def test_starting_with_an_unrecognized_code_is_a_clean_404(fake_supabase, client):
    resp = client.post("/interview/start", json={"code": "NOSUCH01"})
    assert resp.status_code == 404
    assert resp.json()["detail"]["reason"] == "not_found"


def test_processing_a_candidate_with_no_resume_reports_failed_not_a_crash(fake_supabase, client):
    fake_supabase.tables["candidates"].append({
        "id": "e2e-cand-no-resume", "organization_id": "e2e-org-1",
        "name": "No Resume", "email": "x@example.com", "resume_path": None,
    })
    resp = client.post("/resumes/process", json={"candidate_id": "e2e-cand-no-resume"})
    assert resp.status_code == 200
    assert resp.json()["status"] == "FAILED"
