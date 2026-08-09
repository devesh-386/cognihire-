"""Tests for POST /internal/candidates/{candidate_id}/auto-invite — the
trigger-facing endpoint that turns a candidate_ai_profile transition into
READY_FOR_INTERVIEW into a real interview code + invitation email, reusing
`interview_codes.generate()` and `notifications/workflow.send_invitation_for_code()`
exactly as `/interview-codes/generate` does.

This isolates the endpoint's own orchestration logic (auth, existence checks,
idempotency, failure containment) by faking its three collaborators —
`supabase_store`, `demo_store`, `codes_store`, `interview_codes`,
`email_workflow` — directly. Each collaborator already has its own test
coverage elsewhere (test_interview_codes.py, notifications' own tests); this
file is not re-proving those.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from pipeline import demo_store, supabase_store
from notifications import workflow as email_workflow
from session import codes_store, interview_codes


CANDIDATE = {
    "id": "cand-1", "organization_id": "org-1", "name": "Ada Lovelace",
    "email": "ada@example.com", "resume_path": "org-1/cand-1-resume.pdf",
    "role_id": "role-1",
}
ROLE = {"id": "role-1", "title": "Backend Engineer", "required_skills": ["python"]}
READY_PROFILE = {"candidate_id": "cand-1", "processing_status": "READY_FOR_INTERVIEW"}
NOT_READY_PROFILE = {"candidate_id": "cand-1", "processing_status": "CLAIMS_READY"}


@pytest.fixture
def client(monkeypatch):
    import main

    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "test-internal-secret")

    async def fake_fetch_candidate(candidate_id):
        return CANDIDATE if candidate_id == "cand-1" else None

    async def fake_fetch_profile(candidate_id):
        return READY_PROFILE if candidate_id == "cand-1" else None

    async def fake_fetch_role(role_id):
        return ROLE if role_id == "role-1" else None

    async def fake_find_live_code(candidate_id):
        return None

    async def fake_generate(candidate_id, organization_id, role_title, **kwargs):
        return {
            "id": "code-1", "code": "ABCD1234", "candidate_id": candidate_id,
            "organization_id": organization_id, "role_title": role_title,
        }

    async def fake_send_invitation(code_row, candidate):
        return {"status": "sent"}

    monkeypatch.setattr(supabase_store, "fetch_candidate", fake_fetch_candidate)
    monkeypatch.setattr(supabase_store, "fetch_profile", fake_fetch_profile)
    monkeypatch.setattr(demo_store, "fetch_role", fake_fetch_role)
    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)
    monkeypatch.setattr(email_workflow, "send_invitation_for_code", fake_send_invitation)

    return TestClient(main.app)


def _post(client, candidate_id="cand-1", secret="test-internal-secret"):
    headers = {"X-Internal-Secret": secret} if secret is not None else {}
    return client.post(f"/internal/candidates/{candidate_id}/auto-invite", headers=headers)


def test_missing_secret_is_rejected(client):
    resp = _post(client, secret=None)
    assert resp.status_code == 401


def test_wrong_secret_is_rejected(client):
    resp = _post(client, secret="not-the-secret")
    assert resp.status_code == 401


def test_candidate_not_found_is_404(client):
    resp = _post(client, candidate_id="cand-missing")
    assert resp.status_code == 404


def test_candidate_not_ready_is_409(client, monkeypatch):
    async def fake_fetch_profile(candidate_id):
        return NOT_READY_PROFILE

    monkeypatch.setattr(supabase_store, "fetch_profile", fake_fetch_profile)
    resp = _post(client)
    assert resp.status_code == 409


def test_candidate_missing_role_id_is_422(client, monkeypatch):
    async def fake_fetch_candidate(candidate_id):
        return {**CANDIDATE, "role_id": None}

    monkeypatch.setattr(supabase_store, "fetch_candidate", fake_fetch_candidate)
    resp = _post(client)
    assert resp.status_code == 422


def test_role_id_pointing_nowhere_is_422(client, monkeypatch):
    async def fake_fetch_role(role_id):
        return None

    monkeypatch.setattr(demo_store, "fetch_role", fake_fetch_role)
    resp = _post(client)
    assert resp.status_code == 422


def test_successful_auto_invite_generates_code_and_sends_email(client):
    resp = _post(client)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "created"
    assert body["code"] == "ABCD1234"
    assert body["email_status"] == "sent"


def test_existing_active_unexpired_code_short_circuits(client, monkeypatch):
    future_expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()

    async def fake_find_live_code(candidate_id):
        return {
            "id": "code-existing", "code": "EXIST999",
            "expires_at": future_expiry, "status": "active",
        }

    generate_calls = []

    async def fake_generate(*a, **k):
        generate_calls.append((a, k))
        return {}

    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)

    resp = _post(client)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "existing"
    assert body["code"] == "EXIST999"
    assert generate_calls == []  # no second code generated


def test_expired_existing_code_does_not_block_a_new_one(client, monkeypatch):
    past_expiry = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()

    async def fake_find_live_code(candidate_id):
        return {
            "id": "code-expired", "code": "OLD11111",
            "expires_at": past_expiry, "status": "active",
        }

    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)

    resp = _post(client)
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "created"
    assert resp.json()["code"] == "ABCD1234"  # the fake `generate`'s output, not the expired one


def test_postgres_style_timestamp_is_not_compared_as_a_string(client, monkeypatch):
    """Regression: `expires_at` used to be compared against
    `datetime.now().isoformat()` as raw strings. Postgres renders timestamptz
    as "2026-08-11 04:50:14.578971+00" (space separator, "+00") while Python
    emits "...T...+00:00", so at index 10 the compare comes down to ' ' (0x20)
    vs 'T' (0x54) — making every code expiring later *the same day* look
    expired, and minting a duplicate code for a candidate who already had a
    usable one. This pins the Postgres wire format specifically."""
    future = datetime.now(timezone.utc) + timedelta(hours=6)
    postgres_style = future.isoformat(sep=" ").replace("+00:00", "+00")

    generate_calls = []

    async def fake_find_live_code(candidate_id):
        return {
            "id": "code-existing", "code": "SAMEDAY1",
            "expires_at": postgres_style, "status": "active",
        }

    async def fake_generate(*a, **k):
        generate_calls.append((a, k))
        return {}

    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)

    resp = _post(client)
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "existing"
    assert generate_calls == []


def test_candidate_who_already_interviewed_is_not_re_invited(client, monkeypatch):
    """A completed interview flips its code to `used`. Re-processing that
    candidate's resume re-fires the trigger, and an active-only lookup would
    find nothing and cheerfully issue a second code — inviting someone who
    has already sat the interview to sit it again."""
    generate_calls = []

    async def fake_find_live_code(candidate_id):
        return {"id": "code-done", "code": "DONE1234", "status": "used"}

    async def fake_generate(*a, **k):
        generate_calls.append((a, k))
        return {}

    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)

    resp = _post(client)
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "already_interviewed"
    assert generate_calls == []


def test_email_provider_failure_does_not_lose_the_code(client, monkeypatch):
    async def fake_send_invitation(code_row, candidate):
        raise RuntimeError("smtp is down")

    monkeypatch.setattr(email_workflow, "send_invitation_for_code", fake_send_invitation)

    resp = _post(client)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "created"
    assert body["code"] == "ABCD1234"
    assert body["email_status"] == "failed"


def test_preferred_time_becomes_a_window_start_and_end(client, monkeypatch):
    """Regression: `supabase_store.fetch_candidate` used to select an explicit
    column list that never included `preferred_time`, so this endpoint always
    read `None` for it regardless of what the candidate actually submitted
    through the Google Form intake — every code came out with no time window
    at all, silently dropping the "valid only for that slot" guarantee."""
    preferred = datetime.now(timezone.utc) + timedelta(days=3)
    preferred_pg_style = preferred.isoformat(sep=" ").replace("+00:00", "+00")

    async def fake_fetch_candidate(candidate_id):
        return {**CANDIDATE, "preferred_time": preferred_pg_style}

    generate_calls = []

    async def fake_generate(candidate_id, organization_id, role_title, **kwargs):
        generate_calls.append(kwargs)
        return {"id": "code-1", "code": "ABCD1234", "candidate_id": candidate_id,
                 "organization_id": organization_id, "role_title": role_title}

    monkeypatch.setattr(supabase_store, "fetch_candidate", fake_fetch_candidate)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)

    resp = _post(client)
    assert resp.status_code == 200, resp.text

    assert len(generate_calls) == 1
    window_start = generate_calls[0]["window_start"]
    window_end = generate_calls[0]["window_end"]
    assert window_start is not None
    assert window_end == window_start + timedelta(hours=1)


def test_repeated_trigger_firing_is_idempotent(client, monkeypatch):
    """Simulates the DB trigger firing twice for the same transition (or the
    webhook being retried): the second call must see the first call's code
    as already-active and must not generate a second one."""
    state = {"code": None}

    async def fake_find_live_code(candidate_id):
        return state["code"]

    async def fake_generate(candidate_id, organization_id, role_title, **kwargs):
        future_expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        state["code"] = {
            "id": "code-1", "code": "ONCE1234",
            "expires_at": future_expiry, "status": "active",
        }
        return state["code"]

    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", fake_find_live_code)
    monkeypatch.setattr(interview_codes, "generate", fake_generate)

    first = _post(client)
    second = _post(client)
    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["status"] == "created"
    assert second.json()["status"] == "existing"
    assert first.json()["code"] == second.json()["code"] == "ONCE1234"
