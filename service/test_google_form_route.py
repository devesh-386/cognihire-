"""How POST /intakes/{id}/google-form reports a dead Google connection.

This app is deliberately kept in Google's "Testing" publishing status to
skip verification review (infra/README.md's Google setup, step 2). Google
expires a Testing-mode app's refresh tokens after seven days, so a working
connection dies on its own exactly one week after it was made, with nothing
logged and no warning.

When that happened, `_refresh` raised GoogleOAuthError, nothing caught it,
and the route answered a bare 500 — "the server is broken" for a condition
that is neither the server's fault nor fixable by anyone reading a stack
trace. The sibling route POST /internal/google/access-token had caught this
since it was written; this one never did.

Observed live on 2026-08-29: a connection stored 2026-08-11 with
token_expires_at 2026-08-18 returned 500 on every form-creation attempt.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from google_integration import oauth as google_oauth
from pipeline import demo_store, supabase_store

ORG = "org-1"
INTAKE = {"id": "intake-1", "organization_id": ORG, "role_id": "role-1", "name": "August 2026"}


@pytest.fixture
def client(monkeypatch):
    import main

    async def fake_resolve(token):
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    async def fake_fetch_intake(intake_id):
        return dict(INTAKE) if intake_id == INTAKE["id"] else None

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    monkeypatch.setattr(demo_store, "fetch_intake", fake_fetch_intake)
    return TestClient(main.app)


def _auth(org: str = ORG) -> dict:
    return {"Authorization": f"Bearer test-token-{org}"}


def test_an_expired_refresh_token_is_a_409_not_a_500(client, monkeypatch):
    """The bug this file exists for."""

    async def refuse(_organization_id):
        raise google_oauth.GoogleOAuthError(
            "token refresh failed: HTTP 400 {'error': 'invalid_grant'}"
        )

    monkeypatch.setattr(google_oauth, "get_valid_access_token", refuse)

    resp = client.post(f"/intakes/{INTAKE['id']}/google-form", headers=_auth())

    assert resp.status_code == 409, resp.text


def test_the_409_names_the_remedy(client, monkeypatch):
    """A status code alone does not tell an HR user what to do, and the one
    thing that fixes this is a browser consent flow nobody would guess at
    from "conflict"."""

    async def refuse(_organization_id):
        raise google_oauth.GoogleOAuthError("token refresh failed: HTTP 400")

    monkeypatch.setattr(google_oauth, "get_valid_access_token", refuse)

    detail = client.post(f"/intakes/{INTAKE['id']}/google-form", headers=_auth()).json()["detail"]

    assert "reconnect" in detail.lower()


def test_google_internals_do_not_leak_into_the_message(client, monkeypatch):
    """The raised error carries Google's raw body. It goes in the `from`
    chain for the logs, not to the caller."""

    async def refuse(_organization_id):
        raise google_oauth.GoogleOAuthError(
            "token refresh failed: HTTP 400 {'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'}"
        )

    monkeypatch.setattr(google_oauth, "get_valid_access_token", refuse)

    detail = client.post(f"/intakes/{INTAKE['id']}/google-form", headers=_auth()).json()["detail"]

    assert "invalid_grant" not in detail


def test_a_never_connected_org_still_says_connect_first(client, monkeypatch):
    """The pre-existing branch, pinned so the new one did not displace it.
    Same 409 — both are fixed by the same consent flow — but the wording has
    to differ, or an HR user who never connected is told to *re*connect."""

    async def missing(_organization_id):
        raise supabase_store.SupabaseError("organization org-1 has no Google connection")

    monkeypatch.setattr(google_oauth, "get_valid_access_token", missing)

    resp = client.post(f"/intakes/{INTAKE['id']}/google-form", headers=_auth())

    assert resp.status_code == 409
    assert "connect this organization's Google account first" in resp.json()["detail"]


def test_another_orgs_intake_is_still_404_before_google_is_touched(client, monkeypatch):
    """Ownership is checked first; a caller from another org must not be
    able to learn that this intake exists from a Google-flavoured error."""

    async def explode(_organization_id):
        raise AssertionError("Google must not be reached for someone else's intake")

    monkeypatch.setattr(google_oauth, "get_valid_access_token", explode)

    resp = client.post(f"/intakes/{INTAKE['id']}/google-form", headers=_auth("org-2"))

    assert resp.status_code == 404
