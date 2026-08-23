"""Unit tests for security/rate_limit.py.

`_client_ip` had no test coverage at all before this file — the module's own
docstring justified trusting `X-Forwarded-For` by citing an nginx that
doesn't exist anywhere in this deploy (docker-compose.api.yml defines one
service, publishing 8000 directly), which made the whole limiter bypassable
by any caller who simply set the header themselves. These tests pin the
fixed behaviour: the header is untrusted by default, and the actual TCP
peer — not spoofable the way a header is — is what gets rate-limited.
"""

from __future__ import annotations

import asyncio

import pytest
from starlette.requests import Request

from security import rate_limit


def _request(*, client_host: str | None, forwarded_for: str | None = None) -> Request:
    headers = []
    if forwarded_for is not None:
        headers.append((b"x-forwarded-for", forwarded_for.encode()))
    scope = {
        "type": "http",
        "headers": headers,
        "client": (client_host, 12345) if client_host is not None else None,
    }
    return Request(scope)


def _run(coro):
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def reset():
    rate_limit._reset_for_tests()
    yield
    rate_limit._reset_for_tests()


# --- _client_ip --------------------------------------------------------------


def test_forwarded_for_is_ignored_by_default(monkeypatch):
    """The attack this closes: without a real proxy in front, a caller sets
    X-Forwarded-For to a fresh value on every request and the limiter treats
    each one as a different, never-before-seen caller — unlimited effective
    throughput against a route that's supposed to be capped."""
    monkeypatch.setattr(rate_limit, "_TRUST_FORWARDED_FOR", False)
    req = _request(client_host="203.0.113.9", forwarded_for="198.51.100.1")
    assert rate_limit._client_ip(req) == "203.0.113.9"


def test_forwarded_for_last_hop_is_trusted_when_explicitly_enabled(monkeypatch):
    """Opt-in path: TRUST_FORWARDED_FOR=true is a deliberate statement that a
    real proxy sits in front and overwrites this header — the LAST entry is
    what that proxy actually appended, not whatever a client prepended."""
    monkeypatch.setattr(rate_limit, "_TRUST_FORWARDED_FOR", True)
    req = _request(client_host="10.0.0.5", forwarded_for="9.9.9.9, 198.51.100.1")
    assert rate_limit._client_ip(req) == "198.51.100.1"


def test_no_client_and_no_header_falls_back_to_unknown():
    req = _request(client_host=None)
    assert rate_limit._client_ip(req) == "unknown"


# --- limiting behaviour, keyed on the real peer -------------------------------


def test_spoofed_forwarded_for_does_not_bypass_the_limit(monkeypatch):
    """The concrete exploit: hammering a route while setting a different
    X-Forwarded-For value every time must still hit the cap, because the
    header is no longer what's being keyed on."""
    monkeypatch.setattr(rate_limit, "_TRUST_FORWARDED_FOR", False)
    dependency = rate_limit.limit("test-bucket", 3)

    async def hit(i):
        await dependency(_request(client_host="203.0.113.9", forwarded_for=f"1.2.3.{i}"))

    _run(hit(1))
    _run(hit(2))
    _run(hit(3))
    with pytest.raises(Exception) as exc:
        _run(hit(4))
    assert "429" in str(exc.value) or getattr(exc.value, "status_code", None) == 429


def test_different_real_peers_have_independent_limits(monkeypatch):
    monkeypatch.setattr(rate_limit, "_TRUST_FORWARDED_FOR", False)
    dependency = rate_limit.limit("test-bucket-2", 1)

    _run(dependency(_request(client_host="203.0.113.1")))
    # A different real IP is a different bucket entirely — must not inherit
    # the first caller's exhausted limit.
    _run(dependency(_request(client_host="203.0.113.2")))


# --- stale-key sweep -----------------------------------------------------


def test_sweep_drops_keys_whose_window_has_fully_aged_out():
    rate_limit._hits[("bucket-a", "1.1.1.1")].append(0.0)  # ancient
    rate_limit._hits[("bucket-b", "2.2.2.2")].append(1_000_000.0)  # "now"

    rate_limit._sweep_stale_keys(now=1_000_000.0)

    assert ("bucket-a", "1.1.1.1") not in rate_limit._hits
    assert ("bucket-b", "2.2.2.2") in rate_limit._hits


def test_sweep_runs_periodically_without_needing_every_key_hit_again(monkeypatch):
    """The leak this closes: a key that stops being called never trims
    itself again (the trim only runs when THAT key is next hit) — so
    `_hits` only ever grew. The sweep is what reclaims a caller who made one
    burst of requests and never came back."""
    monkeypatch.setattr(rate_limit, "_TRUST_FORWARDED_FOR", False)
    monkeypatch.setattr(rate_limit, "_SWEEP_EVERY_N_CALLS", 2)
    dependency = rate_limit.limit("sweep-bucket", 100)

    _run(dependency(_request(client_host="203.0.113.50")))
    assert ("sweep-bucket", "203.0.113.50") in rate_limit._hits

    # Push the window artificially into the past so the next sweep considers
    # it stale, then trigger two more calls (a different, live key) to cross
    # the sweep threshold without ever calling the stale key again.
    rate_limit._hits[("sweep-bucket", "203.0.113.50")][0] -= rate_limit._WINDOW_SECONDS + 1

    _run(dependency(_request(client_host="203.0.113.51")))
    _run(dependency(_request(client_host="203.0.113.52")))

    assert ("sweep-bucket", "203.0.113.50") not in rate_limit._hits
