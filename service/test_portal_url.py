"""`os.environ.get(name, default)` only returns `default` when the key is
ABSENT. `docker-compose.api.yml` sets `PORTAL_URL: ${PORTAL_URL:-}`, which
means the key is always PRESENT in the container, just empty when the host
`.env` doesn't define it — so the lookup returned `""`, never the default,
and every invitation/reminder email a candidate received had `Start here: `
followed by nothing and `<a href="">`. Same bug, same fix, in two places:
the invitation/reminder link builder and the Google OAuth callback redirect.

These tests set `PORTAL_URL=""` explicitly (not just leave it unset) because
that empty-but-present state is the actual failure mode in production — a
test that only checked the unset case would have passed against the broken
code.
"""

from __future__ import annotations

import importlib

import pytest
from fastapi.testclient import TestClient

from notifications import workflow


def test_empty_string_portal_url_falls_back_to_the_default(monkeypatch):
    monkeypatch.setenv("PORTAL_URL", "")
    assert workflow._portal_url() == workflow.PORTAL_URL_DEFAULT


def test_a_real_portal_url_is_used_as_is(monkeypatch):
    monkeypatch.setenv("PORTAL_URL", "https://app.cognihire.online")
    assert workflow._portal_url() == "https://app.cognihire.online"


def test_unset_portal_url_also_falls_back(monkeypatch):
    monkeypatch.delenv("PORTAL_URL", raising=False)
    assert workflow._portal_url() == workflow.PORTAL_URL_DEFAULT


def test_startup_refuses_to_boot_in_production_with_no_portal_url(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setenv("PORTAL_URL", "")
    monkeypatch.setenv("SUPABASE_URL", "https://fake.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "fake-key")

    import main
    importlib.reload(main)
    try:
        with pytest.raises(RuntimeError, match="PORTAL_URL"):
            with TestClient(main.app):
                pass
    finally:
        monkeypatch.delenv("ENVIRONMENT", raising=False)
        importlib.reload(main)


def test_startup_succeeds_in_production_with_a_real_portal_url(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setenv("PORTAL_URL", "https://app.cognihire.online")
    monkeypatch.setenv("SUPABASE_URL", "https://fake.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "fake-key")

    import main
    importlib.reload(main)
    try:
        with TestClient(main.app) as client:
            assert client.get("/health").json()["portal_url_set"] is True
    finally:
        monkeypatch.delenv("ENVIRONMENT", raising=False)
        importlib.reload(main)


def test_health_reports_portal_url_set_as_false_for_an_empty_string(monkeypatch):
    """`bool("")` is False — this is what made the misconfiguration
    invisible from `/health` in the first place: an empty-but-present
    PORTAL_URL looked no different from a genuinely unset one, except that
    nothing surfaced it as either."""
    monkeypatch.setenv("PORTAL_URL", "")
    import main
    importlib.reload(main)
    try:
        with TestClient(main.app) as client:
            assert client.get("/health").json()["portal_url_set"] is False
    finally:
        importlib.reload(main)


def test_health_reports_the_deployed_git_sha(monkeypatch):
    """deploy.yml's freshness check reads this field to prove the running
    container is actually the commit it just built — `llm_provider` used to
    stand in for this, but it's identical across every build regardless of
    which commit shipped it."""
    monkeypatch.setenv("GIT_SHA", "abc123def456")
    import main
    importlib.reload(main)
    try:
        with TestClient(main.app) as client:
            assert client.get("/health").json()["git_sha"] == "abc123def456"
    finally:
        importlib.reload(main)


def test_health_reports_git_sha_as_none_when_unset(monkeypatch):
    monkeypatch.delenv("GIT_SHA", raising=False)
    import main
    importlib.reload(main)
    try:
        with TestClient(main.app) as client:
            assert client.get("/health").json()["git_sha"] is None
    finally:
        importlib.reload(main)
