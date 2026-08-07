"""Direct regression test for `session_store.next_sequence`'s HTTP status
handling — found live against real Supabase, not by any prior test.

PostgREST answers `206 Partial Content` (not `200`) whenever a `limit`
returns fewer rows than actually matched the filter. `next_sequence` sends
`limit=1` to read only `content-range`'s total, which the real service
almost always truncates once a session has more than one event — so this
was a real bug: every second-or-later answer in a live interview failed
with `SupabaseError: event count failed: HTTP 206`. Caught in the RC1/e2e
fakes only after they were fixed to actually honor `limit` and return 206
when they truncate; this test pins the fix at the unit level so it can't
regress silently again.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

from session import session_store


def _run(coro):
    return asyncio.run(coro)


class _FakeResponse:
    def __init__(self, status_code, headers=None):
        self.status_code = status_code
        self.headers = headers or {}


class _FakeAsyncClient:
    def __init__(self, status_code, content_range, **_):
        self._status_code = status_code
        self._content_range = content_range

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get(self, url, **kwargs):
        return _FakeResponse(self._status_code, headers={"content-range": self._content_range})


@pytest.fixture(autouse=True)
def fake_supabase_config(monkeypatch):
    monkeypatch.setattr(session_store, "SUPABASE_URL", "https://fake.supabase.co")
    monkeypatch.setattr(session_store, "SUPABASE_SERVICE_ROLE_KEY", "fake-key")


def test_next_sequence_accepts_206_when_limit_truncates_the_match(monkeypatch):
    """The real-world case: a session with several events, `limit=1` cuts
    the response down to one row, PostgREST reports 206."""
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(206, "0-0/4")
    )
    assert _run(session_store.next_sequence("session-1")) == 4


def test_next_sequence_still_accepts_a_plain_200(monkeypatch):
    """A session with zero or one event never gets truncated by `limit=1`,
    so PostgREST answers a plain 200 in that case — must keep working."""
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(200, "*/1")
    )
    assert _run(session_store.next_sequence("session-1")) == 1


def test_next_sequence_still_raises_on_a_real_error_status(monkeypatch):
    """Not a blanket "anything goes" — only 200/206 are ever legitimate
    responses to this request; anything else must still raise."""
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(500, "*/0")
    )
    with pytest.raises(session_store.SupabaseError):
        _run(session_store.next_sequence("session-1"))
