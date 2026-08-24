"""In-process rate limiting for the handful of routes that are both publicly
reachable (no auth) and expensive (an LLM call, or an email send).

Single-container deployment (`docker-compose.api.yml` runs exactly one
`cognihire-face-service`) — a dict keyed by (bucket, client IP) with a fixed
rolling window is the smallest thing that actually stops a script hammering
`/extract-claims` for free OpenAI calls, without adding Redis or any other
infrastructure this project doesn't otherwise run. It is not a defense
against a distributed attacker spreading requests across many IPs; that
needs an edge/CDN layer, which is out of scope for what's being fixed here.
"""

from __future__ import annotations

import os
import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request

_WINDOW_SECONDS = 60.0
_hits: dict[tuple[str, str], deque] = defaultdict(deque)
_calls_since_sweep = 0
# A key that stops being called (the common case: one burst, then nothing)
# never gets its now-stale deque trimmed again — the `while` loop below only
# runs when THAT key is next hit, and by definition nothing hits it again.
# Reactive-only trimming is therefore an unbounded-growth leak: `_hits`
# never loses a key, only ever gains them. Swept periodically instead of on
# every call, since a full dict scan on every request is wasted work at any
# real traffic volume — the sweep only needs to run often enough that the
# leak's growth rate stays bounded, not on every single request.
_SWEEP_EVERY_N_CALLS = 500

# X-Forwarded-For is a header any client can set on a raw HTTP request —
# trusting it as "the real client IP" is only valid when something ahead of
# this process is KNOWN to overwrite whatever the client sent with the truth
# (a reverse proxy that discards inbound X-Forwarded-For and appends its own
# view of the connecting peer). `docker-compose.api.yml` — the only file that
# actually describes this deploy — defines exactly one service, publishing
# 8000 directly; no proxy is in it. Whatever previously justified trusting
# this header described infrastructure that isn't in the repo, which means
# rate limiting was keyed on a value every request already fully controlled:
# `X-Forwarded-For: 1.2.3.4` (attacker's own choice, spammed to a fresh
# "unique caller" every request) bypassed the limiter entirely.
#
# Default is therefore the actual TCP peer — not spoofable the way a header
# is, since it's the address the socket connection came from, not something
# carried inside the request. If this service is later placed behind a real
# proxy that overwrites X-Forwarded-For (Coolify/Traefik, a CDN), set
# TRUST_FORWARDED_FOR=true deliberately, at the same time that proxy is
# actually put in place — not before, and not by default.
_TRUST_FORWARDED_FOR = os.environ.get("TRUST_FORWARDED_FOR", "").lower() == "true"


def _client_ip(request: Request) -> str:
    if _TRUST_FORWARDED_FOR:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            # The LAST hop, not the first: a chain of proxies appends to
            # this header, so the entry closest to us is the one the
            # nearest actual proxy wrote — entries a client prepended
            # itself all sit before it. Still trust-the-proxy, not
            # cryptographic; correct only because TRUST_FORWARDED_FOR is an
            # explicit statement that a real proxy sits in front.
            return forwarded.split(",")[-1].strip()
    return request.client.host if request.client else "unknown"


def check(bucket: str, identity: str, max_requests: int) -> None:
    """Consume one slot for `identity` in `bucket`, or raise 429.

    Split out of `limit()` so a route can rate-limit on something the ASGI
    scope doesn't know about — specifically the email address a login
    attempt names, which only exists once the body has been parsed. IP is
    the only identity available to a dependency; for credential-verification
    routes it is not the only one that matters. See `/auth/login`.
    """
    global _calls_since_sweep
    key = (bucket, identity)
    now = time.monotonic()
    window = _hits[key]
    while window and now - window[0] > _WINDOW_SECONDS:
        window.popleft()
    if len(window) >= max_requests:
        raise HTTPException(status_code=429, detail="too many requests — try again in a minute")
    window.append(now)

    _calls_since_sweep += 1
    if _calls_since_sweep >= _SWEEP_EVERY_N_CALLS:
        _calls_since_sweep = 0
        _sweep_stale_keys(now)


def limit(bucket: str, max_requests: int):
    """FastAPI dependency factory: `Depends(rate_limit.limit("extract-claims", 10))`
    allows `max_requests` calls per client IP per rolling minute for that
    bucket, independent of every other bucket."""

    async def _dependency(request: Request) -> None:
        check(bucket, _client_ip(request), max_requests)

    return _dependency


def _sweep_stale_keys(now: float) -> None:
    """Drop every (bucket, ip) whose window has entirely aged out. Called
    periodically from `_dependency`, not on every request — see
    `_SWEEP_EVERY_N_CALLS`. A snapshot of `.items()` is taken before
    mutating, since deleting from a dict while iterating it directly raises
    `RuntimeError: dictionary changed size during iteration`."""
    stale = [key for key, window in _hits.items() if not window or now - window[-1] > _WINDOW_SECONDS]
    for key in stale:
        del _hits[key]


def _reset_for_tests() -> None:
    """Test-only: rate limit state is module-level and would otherwise leak
    between test functions that share a client IP (they all do — TestClient
    has no real network)."""
    global _calls_since_sweep
    _hits.clear()
    _calls_since_sweep = 0
