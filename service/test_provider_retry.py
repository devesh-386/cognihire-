"""Tests for `ai/provider.py`'s retry-on-429/5xx: a rate limit or transient
server error should be retried within one call, not immediately handed to
the caller as a degraded reply — the exact loose end found live in
production (2026-08-06), where a real OpenAI request hit HTTP 429 and
degraded a question-generation turn to the heuristic fallback."""

from __future__ import annotations

import asyncio

import httpx
import pytest

from ai import provider


def _run(coro):
    return asyncio.run(coro)


class _FakeResponse:
    def __init__(self, status_code, payload=None, headers=None):
        self.status_code = status_code
        self._payload = payload or {}
        self.headers = headers or {}

    def json(self):
        return self._payload


def _openai_success_payload():
    return {"choices": [{"message": {"content": '{"ok": true}'}}]}


@pytest.fixture(autouse=True)
def no_real_sleep(monkeypatch):
    async def _no_sleep(*_args):
        return None

    monkeypatch.setattr(provider.asyncio, "sleep", _no_sleep)


@pytest.fixture(autouse=True)
def openai_key(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "test-key")


def test_a_single_429_is_retried_and_then_succeeds(monkeypatch):
    responses = [
        _FakeResponse(429, headers={"retry-after": "0"}),
        _FakeResponse(200, _openai_success_payload()),
    ]
    calls = {"n": 0}

    async def fake_post(self, url, **kwargs):
        calls["n"] += 1
        return responses.pop(0)

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    reply = _run(provider.chat_json("system", "user", provider="openai"))

    assert reply.ok
    assert reply.content == '{"ok": true}'
    assert calls["n"] == 2


def test_persistent_429_still_degrades_after_the_retry_budget(monkeypatch):
    calls = {"n": 0}

    async def fake_post(self, url, **kwargs):
        calls["n"] += 1
        return _FakeResponse(429)

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    reply = _run(provider.chat_json("system", "user", provider="openai"))

    assert not reply.ok
    assert "429" in reply.error
    # 1 initial attempt + _MAX_RETRIES retries, never more.
    assert calls["n"] == 1 + provider._MAX_RETRIES


def test_a_non_retryable_status_is_not_retried(monkeypatch):
    calls = {"n": 0}

    async def fake_post(self, url, **kwargs):
        calls["n"] += 1
        return _FakeResponse(401)

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    reply = _run(provider.chat_json("system", "user", provider="openai"))

    assert not reply.ok
    assert calls["n"] == 1, "a 401 will never succeed on retry, so it must not be retried"


def test_a_transient_503_is_retried(monkeypatch):
    responses = [_FakeResponse(503), _FakeResponse(200, _openai_success_payload())]
    calls = {"n": 0}

    async def fake_post(self, url, **kwargs):
        calls["n"] += 1
        return responses.pop(0)

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    reply = _run(provider.chat_json("system", "user", provider="openai"))

    assert reply.ok
    assert calls["n"] == 2


def test_retry_after_header_with_a_bad_value_falls_back_to_backoff(monkeypatch):
    """A malformed Retry-After must not crash the retry loop."""
    responses = [
        _FakeResponse(429, headers={"retry-after": "not-a-number"}),
        _FakeResponse(200, _openai_success_payload()),
    ]

    async def fake_post(self, url, **kwargs):
        return responses.pop(0)

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    reply = _run(provider.chat_json("system", "user", provider="openai"))

    assert reply.ok
