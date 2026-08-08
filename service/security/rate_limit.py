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

import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request

_WINDOW_SECONDS = 60.0
_hits: dict[tuple[str, str], deque] = defaultdict(deque)


def _client_ip(request: Request) -> str:
    # Trusts X-Forwarded-For only because this service always sits behind
    # the deploy's own nginx (see docker-compose.api.yml) — a direct client
    # can't reach uvicorn without going through it first.
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def limit(bucket: str, max_requests: int):
    """FastAPI dependency factory: `Depends(rate_limit.limit("extract-claims", 10))`
    allows `max_requests` calls per client IP per rolling minute for that
    bucket, independent of every other bucket."""

    async def _dependency(request: Request) -> None:
        key = (bucket, _client_ip(request))
        now = time.monotonic()
        window = _hits[key]
        while window and now - window[0] > _WINDOW_SECONDS:
            window.popleft()
        if len(window) >= max_requests:
            raise HTTPException(status_code=429, detail="too many requests — try again in a minute")
        window.append(now)

    return _dependency


def _reset_for_tests() -> None:
    """Test-only: rate limit state is module-level and would otherwise leak
    between test functions that share a client IP (they all do — TestClient
    has no real network)."""
    _hits.clear()
