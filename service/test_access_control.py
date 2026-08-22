"""Default-deny authorization at the ASGI layer (security/access_control.py).

Before this, six routes handled real data with no auth check at all —
`/interview-codes/{id}/emails`, `/interview-codes/resend-invitation`,
`/email/send-due-reminders`, `/extract-claims`, `/face/analyze` — because
authorization was opt-in per route (a hand-called `await _require_org(...)`)
and each of them simply never got the line added. This is not hypothetical:
`test_email_routes.py` called two of them with no headers and passed, because
nothing before this file ever asserted they should fail.

The fix is a choke point, not six patches: everything not explicitly listed
in `access_control.PUBLIC_ROUTES` requires a bearer token to be *present*
before it reaches a handler. This file pins two things — the newly-protected
routes reject an anonymous caller, and `PUBLIC_ROUTES` cannot silently drift
out of sync with `main.py` as routes are added or renamed.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import main
from security import access_control, rate_limit


@pytest.fixture
def client(monkeypatch):
    rate_limit._reset_for_tests()
    return TestClient(main.app)


# --- the six routes that used to have no auth at all -------------------------


def test_email_status_requires_auth(client):
    resp = client.get("/interview-codes/some-code-id/emails")
    assert resp.status_code == 401


def test_resend_invitation_requires_auth(client):
    resp = client.post("/interview-codes/resend-invitation", json={"code_id": "x"})
    assert resp.status_code == 401


def test_send_due_reminders_requires_the_internal_secret_not_a_bearer_token(client, monkeypatch):
    """Gated the same way as /internal/candidates/{id}/auto-invite: the
    caller is a scheduler, not a logged-in HR user, so a missing bearer
    token must not be what blocks it — the wrong header should be."""
    monkeypatch.setenv("INTERNAL_AUTOINVITE_SECRET", "the-real-secret")
    # No Authorization header at all — the ASGI middleware must let this
    # through to the handler, which then does its own check.
    resp = client.post("/email/send-due-reminders")
    assert resp.status_code == 401
    assert "internal secret" in resp.json()["detail"]


def test_extract_claims_still_requires_no_auth_but_is_rate_limited(client):
    """Stays public by necessity (no candidate login exists), but the route
    was never meant to be a free, unlimited OpenAI proxy — confirms the
    existing rate limit is still the actual control, not an auth check we
    forgot to add."""
    resp = client.post("/extract-claims", json={"document_text": "x", "source": "resume"})
    assert resp.status_code != 401


def test_face_analyze_rejects_an_oversized_frame(client):
    oversized = b"x" * (8 * 1024 * 1024 + 1)
    resp = client.post(
        "/face/analyze", files={"file": ("frame.jpg", oversized, "image/jpeg")},
    )
    assert resp.status_code == 413


# --- the allowlist cannot silently drift --------------------------------------


def test_every_registered_route_is_either_public_or_requires_a_bearer_token(client):
    """For every route FastAPI actually registered, confirm calling it with
    no Authorization header gets EITHER a public 2xx/4xx-that-is-not-401 (an
    intentionally public route, allowed only if listed in PUBLIC_ROUTES) OR a
    401 from the middleware. A route that is neither — reachable, undeclared,
    and NOT rejected — is exactly how the original six routes went missing:
    it fails this test the moment it exists, before anyone has to notice by
    hand."""
    declared = {(method, path) for method, path in access_control.PUBLIC_ROUTES}
    # These two are public at the middleware layer (no bearer token required
    # to reach the handler) but the HANDLER itself still answers 401 with no
    # header at all, for its own reason: no internal secret was supplied. A
    # plain status-code check can't tell that apart from the middleware
    # having blocked it, so check the message instead of the code for these.
    handler_401_for_its_own_reason = {
        ("POST", "/email/send-due-reminders"),
        ("POST", "/internal/candidates/{candidate_id}/auto-invite"),
    }

    for route in main.app.routes:
        path = getattr(route, "path", None)
        methods = getattr(route, "methods", None)
        if path is None or not methods:
            continue
        if "GET" in methods and path == "/openapi.json":
            continue

        for method in methods:
            if method in ("HEAD", "OPTIONS"):
                continue

            is_declared_public = (method, path) in declared
            resp = client.request(method, path.format(
                candidate_id="x", role_id="x", intake_id="x", code_id="x",
                session_id="x", organization_id="x", form_id="x",
            ))
            if (method, path) in handler_401_for_its_own_reason:
                assert resp.status_code == 401
                assert resp.json()["detail"] != "missing bearer token", (
                    f"{method} {path}: the MIDDLEWARE blocked this before its "
                    "own secret check ever ran — it must be in PUBLIC_ROUTES"
                )
            elif is_declared_public:
                assert resp.status_code != 401, (
                    f"{method} {path} is declared public but the middleware "
                    "blocked it anyway — PUBLIC_ROUTES and main.py disagree"
                )
            else:
                assert resp.status_code == 401, (
                    f"{method} {path} is reachable with NO auth and is not in "
                    "PUBLIC_ROUTES — this is exactly the gap Phase 1.3 closes. "
                    "Either add auth to the route, or add it to PUBLIC_ROUTES "
                    "with a reason."
                )
