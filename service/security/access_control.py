"""Default-deny authorization at the ASGI layer.

Every route in `main.py` used to decide its own authorization by hand-calling
`await _require_org(authorization)` — opt-in, per route, easy to omit. Six
routes did: `/interview-codes/{id}/emails`, `/interview-codes/resend-
invitation`, `/email/send-due-reminders` (triggers the reminder sweep across
every organization), `/extract-claims` (a free OpenAI proxy on arbitrary
text), and `/face/analyze` (an unmetered biometric-embedding endpoint). None
of them were auth-worthy by design; they were auth-worthy by nobody having
written the line yet.

This module inverts the default. `PUBLIC_PATHS` is the complete, reviewed
list of routes that may be reached with no bearer token — every one of them
carries a reason. Everything else requires `Authorization: Bearer <token>` to
be *present* before the request reaches a handler; whether that token is
valid, and which organization it grants, is still `_require_org`'s job. This
middleware answers one question only: is a token required here at all.

Matched against the ASGI scope, not FastAPI's dependency graph, so a route
added to `main.py` without ever importing this module is still covered — the
opt-in mistake this replaces cannot be reintroduced by omission.
"""

from __future__ import annotations

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import compile_path
from starlette.types import ASGIApp

# (method, path template) — path templates use the same `{name}` syntax as
# the FastAPI route they cover, so a path here can drift out of sync with
# main.py only if nobody ever calls it, which the test below on
# `app.routes` prevents.
PUBLIC_ROUTES: list[tuple[str, str]] = [
    # Deploy/monitoring — no identity to check.
    ("GET", "/health"),

    # Public browsing — a candidate with no link yet finds a role to apply
    # to. Minimal response shape (title, org name); see each route's own
    # docstring in main.py.
    ("GET", "/roles/open"),
    ("GET", "/roles/{role_id}/apply-info"),
    ("GET", "/intakes/{intake_id}/apply-info"),

    # Candidate self-registration — this IS the front door; a candidate has
    # no account to authenticate with. Each is separately rate-limited and,
    # since Phase 1.4, may not overwrite an existing candidate's record.
    ("POST", "/candidates/apply"),
    ("POST", "/intakes/{intake_id}/apply"),

    # The interview itself — a candidate authenticates with their interview
    # code in the request body, not a bearer token; see
    # `_require_code_owns_session` in main.py.
    ("POST", "/interview/start"),
    ("POST", "/interview/answer"),
    ("POST", "/interview/event"),
    ("POST", "/interview/finish"),

    # Server-to-server, each gated by its own shared secret rather than a
    # human bearer token — the caller is a Postgres trigger or a scheduler,
    # not a logged-in person. `/resumes/process` has no secret at all
    # (see its docstring: the DB trigger that calls it has no token to send)
    # and is instead rate-limited per client IP.
    ("POST", "/resumes/process"),
    ("POST", "/internal/candidates/{candidate_id}/auto-invite"),
    ("POST", "/email/send-due-reminders"),

    # Hit directly by Google's OAuth redirect — no bearer token is available
    # to send; authenticity comes from `_verify_state`'s HMAC, not from this
    # layer.
    ("GET", "/google/oauth/callback"),

    # Creating an account, or the two credential-verification calls that
    # precede having a token at all.
    ("POST", "/auth/signup"),
    ("POST", "/auth/login"),

    # Direct LLM/vision calls with no HR or candidate identity to check yet.
    # Public by necessity (the candidate portal has no login), so the
    # control here is a rate limit and a body-size cap, not a token — see
    # `rate_limit.limit(...)` on each route and the cap enforced in
    # `analyze_frame`.
    ("POST", "/extract-claims"),
    ("POST", "/face/analyze"),

    # Dev/staging convenience, not HR-facing — each already refuses outright
    # with `_require_non_production()` the instant ENVIRONMENT=production, so
    # adding a bearer-token requirement on top would only add friction to
    # local setup without closing any real gap; the guard IS the control.
    ("POST", "/demo/seed"),
    ("POST", "/demo/reset"),
    ("POST", "/dev/seed-multi-tenant-demo"),
    ("POST", "/dev/seed-tester-account"),
]

_COMPILED = [
    (method, compile_path(path)[0]) for method, path in PUBLIC_ROUTES
]


def _is_public(method: str, path: str) -> bool:
    if method == "OPTIONS":
        # CORS preflight carries no Authorization header by construction —
        # the browser sends it before deciding whether to attach one. Every
        # preflight is allowed through; the real request behind it is still
        # checked normally.
        return True
    return any(m == method and pattern.match(path) for m, pattern in _COMPILED)


class RequireAuthMiddleware(BaseHTTPMiddleware):
    """Refuses any request outside `PUBLIC_ROUTES` that carries no bearer
    token, before it reaches a route handler. Does not itself validate the
    token or resolve an organization — `_require_org` still does that, and
    still returns 401 for a garbage or expired one. This layer only closes
    the gap where a route forgot to call `_require_org` at all.
    """

    async def dispatch(self, request: Request, call_next):
        if _is_public(request.method, request.url.path):
            return await call_next(request)

        authorization = request.headers.get("authorization", "")
        if not authorization.lower().startswith("bearer ") or len(authorization) <= 7:
            return JSONResponse(
                {"detail": "missing bearer token"}, status_code=401,
            )

        return await call_next(request)


def install(app: ASGIApp) -> None:
    app.add_middleware(RequireAuthMiddleware)
