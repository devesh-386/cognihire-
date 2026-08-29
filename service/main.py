"""CogniHire face service.

Deliberately narrow: it extracts a face embedding from one frame and reports
image quality. It does NOT decide whether two faces match.

That separation is the point. The reference implementation this project learns
from did the comparison server-side, applied a threshold of 85 on a scale where
two *different* people score ~50, and returned a fabricated pass when no
enrolled profile existed. Keeping the decision in the client — where the
threshold is documented, tested, and calibratable — means this service has no
opportunity to invent a verdict.

Run:
    uvicorn main:app --port 8000
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional

import cv2
import httpx
import numpy as np
from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, Response
from pydantic import BaseModel

from ai import claim_extraction
from candidates import self_registration
from demo import multi_tenant_seed
from demo import reset as demo_reset
from demo import seed as demo_seed
from demo import tester_account
from google_integration import forms as google_forms
from google_integration import oauth as google_oauth
from notifications import store as email_store
from notifications import workflow as email_workflow
from pipeline import demo_store, google_oauth_store, profile_builder, supabase_store
from security import access_control, rate_limit
from session import codes_store, interview_codes, interview_session, live_interview, session_store
from session.events import EventType

# Ticket 20: without an explicit handler, Python's logging module only ever
# surfaces WARNING+ (via its "handler of last resort") — every logger.info
# call in this codebase (pipeline stage transitions, interview turns) was
# silently going nowhere. A deployed box with no visible logs is not
# something a demo can recover from mid-presentation, so this is configured
# explicitly rather than left to the default. Level is an env var so a noisy
# deploy can be turned down without a code change.
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

logger = logging.getLogger("cognihire.face")

def _refuse_to_boot_misconfigured_in_production() -> None:
    """A missing PORTAL_URL in production used to fail silently — every
    invitation and reminder email a candidate received had a working subject
    line and an empty link, and nothing about a green health check or a
    successful deploy would tell you. An invitation with no link is worse
    than the service refusing to start, so refuse.

    Startup-time, not import-time: raising at import would fire during test
    collection every time `main` is imported, for a condition (`ENVIRONMENT
    =production`) no test sets. The lifespan handler only runs when uvicorn
    actually brings the app up."""
    if os.environ.get("ENVIRONMENT", "development") == "production" and not os.environ.get("PORTAL_URL"):
        raise RuntimeError(
            "PORTAL_URL is not set. In production this means every invitation "
            "and reminder email links nowhere — refusing to start."
        )


def _warn_if_origins_unrestricted_in_production() -> None:
    """ALLOWED_ORIGINS defaults to "*" in docker-compose.api.yml — the file
    whose own header says it is the production stack — so forgetting to set
    it in the VM's .env leaves production wide open by default rather than
    by decision.

    Two things go slack when it is "*". CORS accepts any origin, which is
    the milder half: this service authenticates with bearer tokens held in
    the portal's localStorage, and no cross-origin page can read those, so
    a permissive CORS policy does not by itself hand anyone a session. The
    sharper half is the WebSocket upgrade at `/interview/live/{session_id}`,
    which CORSMiddleware does not cover and which therefore does its own
    Origin check by hand — and that check is written as
    `_allowed_origins == "*" or origin in ...`, so "*" turns it off
    entirely. What still stands behind it is the interview code, which the
    socket demands as its first message.

    A warning rather than a refusal, unlike PORTAL_URL above. That one
    silently broke every candidate's invitation link, so failing the boot
    was strictly better than starting. This one degrades a defence in depth
    while the actual credential checks keep working, and a service that
    refuses to start over it would take the whole hiring pipeline down to
    fix a hardening gap. It is reported by GET /health as `allowed_origins`
    too, so it is visible without reading logs."""
    if os.environ.get("ENVIRONMENT", "development") != "production":
        return
    if _allowed_origins.strip() != "*":
        return
    logger.warning(
        "ALLOWED_ORIGINS is '*' in production. CORS will accept any origin and the "
        "WebSocket Origin check on /interview/live is disabled. Set ALLOWED_ORIGINS "
        "to the portal's and HR app's real origins (comma-separated) in the VM's .env."
    )


@asynccontextmanager
async def _lifespan(app: FastAPI):
    _refuse_to_boot_misconfigured_in_production()
    _warn_if_origins_unrestricted_in_production()
    yield


app = FastAPI(title="CogniHire Face Service", version="0.1.0", lifespan=_lifespan)

# "*" only for local dev. Once this runs on a public VM (Ticket 9), set
# ALLOWED_ORIGINS to the HR app's and candidate web app's actual origins.
_allowed_origins = os.environ.get("ALLOWED_ORIGINS", "*")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _allowed_origins == "*" else _allowed_origins.split(","),
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# Default-deny: every route not explicitly listed in
# security/access_control.py's PUBLIC_ROUTES requires a bearer token to be
# present before it reaches a handler. See that module's docstring — this
# replaces six routes that simply forgot to call `_require_org`.
access_control.install(app)

# ---------------------------------------------------------------------------
# Engine loading
#
# If InsightFace is unavailable the service still starts, but every analysis
# reports embedding_available=false. It never falls back to a cheaper heuristic
# and never reports a result it did not compute — a proctoring system that
# guesses is worse than one that admits it cannot see.
# ---------------------------------------------------------------------------
_face_app = None
ENGINE_ERROR: Optional[str] = None

try:
    from insightface.app import FaceAnalysis

    # Load ONLY detection + recognition.
    #
    # The buffalo_l pack also ships genderage.onnx (a gender and age
    # classifier) and two landmark models. Loading the full pack would run a
    # demographic classifier over every candidate's face for no functional
    # reason — output we never read, on an attribute we have deliberately
    # chosen not to infer. Keeping it out of the process is the difference
    # between a claim we can defend and one that is contradicted by our own
    # dependency list. It also avoids ~143MB of pointless model loading.
    _face_app = FaceAnalysis(
        name="buffalo_l",
        allowed_modules=["detection", "recognition"],
    )
    _face_app.prepare(ctx_id=-1, det_size=(640, 640))
except Exception as exc:  # noqa: BLE001 - report any load failure verbatim
    ENGINE_ERROR = str(exc)
    logger.error("InsightFace unavailable: %s", exc)


class FrameAnalysis(BaseModel):
    engine_available: bool
    engine_error: Optional[str] = None

    face_detected: bool
    embedding_available: bool
    # 512-d ArcFace embedding. Present only when embedding_available is true.
    embedding: Optional[list[float]] = None

    face_size: int = 0
    brightness: float = 0.0
    sharpness: float = 0.0
    recommendations: list[str] = []


def _quality(gray: np.ndarray) -> tuple[float, float]:
    brightness = float(np.mean(gray)) / 255.0 * 100.0
    sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    return brightness, sharpness


def _recommendations(brightness: float, sharpness: float, face_size: int) -> list[str]:
    recs: list[str] = []
    if brightness < 25:
        recs.append("Increase lighting")
    elif brightness > 90:
        recs.append("Reduce glare or backlight")
    if sharpness < 60:
        recs.append("Hold still or clean the lens")
    if face_size == 0:
        recs.append("Ensure your face is visible to the camera")
    elif face_size < 15000:
        recs.append("Move closer to the camera")
    return recs


@app.get("/health")
def health() -> dict:
    """Deploy sanity check. Reports whether each secret/URL is *set*, never
    its value — a fresh Coolify/VM deploy with a missing env var should be
    diagnosable from `curl .../health` alone, without SSHing in to check
    `printenv` or waiting for the first real request to 503."""
    from ai.provider import LLM_PROVIDER

    email_kind = os.environ.get("EMAIL_PROVIDER", "smtp")
    # Mirrors notifications/provider.get_provider()'s own credential check per
    # kind — this is a report of the same decision, not a second opinion, so
    # the two must be kept in sync by hand if a provider's required vars change.
    email_configured = (
        bool(os.environ.get("SENDGRID_API_KEY")) and bool(os.environ.get("EMAIL_FROM_ADDRESS"))
        if email_kind == "sendgrid"
        else bool(os.environ.get("ACS_ENDPOINT"))
        and bool(os.environ.get("ACS_ACCESS_KEY"))
        and bool(os.environ.get("EMAIL_FROM_ADDRESS"))
        if email_kind == "acs"
        else bool(os.environ.get("SMTP_HOST"))
        and bool(os.environ.get("SMTP_USERNAME"))
        and bool(os.environ.get("SMTP_PASSWORD"))
    )

    return {
        "status": "ok",
        "engine_available": _face_app is not None,
        "engine_error": ENGINE_ERROR,
        "llm_provider": LLM_PROVIDER,
        "openai_api_key_set": bool(os.environ.get("OPENAI_API_KEY")),
        "supabase_url_set": bool(supabase_store.SUPABASE_URL),
        "supabase_service_role_key_set": bool(supabase_store.SUPABASE_SERVICE_ROLE_KEY),
        "allowed_origins": _allowed_origins,
        "email_provider": email_kind,
        "email_provider_configured": email_configured,
        # Was invisible from here even though it broke every invitation and
        # reminder email a candidate received (empty link, empty `<a href>`)
        # — the `os.environ.get(name, default)` bug fixed in
        # notifications/workflow.py's _portal_url() and the OAuth callback
        # above. `bool("")` is False, so this reports the same "unset" a
        # genuinely absent value would, which is exactly the case that broke.
        "portal_url_set": bool(os.environ.get("PORTAL_URL")),
        # Whether Google OAuth tokens can actually be encrypted at rest
        # (security/token_crypto.py) — False means google_oauth_store.py's
        # encrypt/decrypt calls will raise on the next read or write, not
        # that tokens are silently stored in plaintext.
        "google_token_encryption_key_set": bool(os.environ.get("GOOGLE_TOKEN_ENCRYPTION_KEY")),
        # The commit this running container was built from — see
        # docker-compose.api.yml's GIT_SHA. None on a deploy that didn't set
        # it (e.g. local dev), distinguishable from an empty string.
        "git_sha": os.environ.get("GIT_SHA") or None,
    }


class ClaimExtractRequest(BaseModel):
    document_text: str
    source: str


class ClaimOut(BaseModel):
    id: str
    text: str
    source: str
    skill: Optional[str] = None


class ClaimExtractResponse(BaseModel):
    claims: list[ClaimOut]
    # "hosted_llm" | "local_llm" | "heuristic_rule" — mirrors
    # `ExtractorKind` in lib/core/claims/claim_extractor.dart. The client
    # renders the label; it never decides which one applies.
    kind: str
    degraded_reason: Optional[str] = None
    rejected_ungrounded: list[str] = []


class ProcessResumeRequest(BaseModel):
    candidate_id: str


@app.post("/resumes/process", dependencies=[Depends(rate_limit.limit("resumes-process", 20))])
async def process_resume(req: ProcessResumeRequest) -> dict:
    """Run the resume pipeline for one candidate.

    Called by the `candidates_resume_uploaded` database trigger when a resume
    lands. Idempotent: re-running re-processes from the PDF and overwrites the
    profile, so a retry after a transient failure is always safe.

    Unauthenticated by design (the DB trigger has no bearer token to send)
    but this is a real LLM-call path per candidate, so it's rate-limited per
    client IP as the cheapest available guard against it being hammered
    directly instead of via the trigger.
    """
    try:
        return await profile_builder.process_candidate_resume(req.candidate_id)
    except supabase_store.SupabaseError as exc:
        # The database is unreachable or misconfigured — we could not even
        # record a failure, so surface it as a 5xx rather than reporting a
        # handled outcome we did not actually persist.
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post(
    "/extract-claims",
    response_model=ClaimExtractResponse,
    dependencies=[Depends(rate_limit.limit("extract-claims", 10))],
)
async def extract_claims(req: ClaimExtractRequest) -> ClaimExtractResponse:
    """The gateway's only claim-extraction entry point.

    Provider (OpenAI vs. Ollama), model name, and the extraction prompt all
    live in `ai_gateway` and are chosen by server config (`LLM_PROVIDER`) —
    never by the request body. A candidate-facing client sends a document
    and a source label; nothing else about how the extraction runs is its
    business.

    Unauthenticated (no HR/candidate identity is meaningful here yet) and it
    is a direct LLM call on arbitrary input, so it's the single most
    abusable route in this file as a free OpenAI proxy without a rate limit
    — hence one here even though nothing else about this route changed.
    """
    result = await claim_extraction.extract_claims(req.document_text, req.source)
    return ClaimExtractResponse(
        claims=[
            ClaimOut(id=c.id, text=c.text, source=c.source, skill=c.skill)
            for c in result.claims
        ],
        kind=result.kind,
        degraded_reason=result.degraded_reason,
        rejected_ungrounded=result.rejected_ungrounded,
    )


class GenerateCodeRequest(BaseModel):
    candidate_id: str
    role_title: str
    required_skills: list[str] = []
    difficulty: str = "standard"
    available_minutes: int = 20
    max_attempts: int = 3
    expires_in_hours: int = 72
    # The interview's scheduled start — doubles as `window_start` (the code
    # isn't redeemable before it) and as what the invitation/reminder emails
    # tell the candidate. Optional: a code can still be generated for
    # "whenever the candidate gets to it" before Ticket 21 existed.
    scheduled_at: Optional[datetime] = None


class InterviewStartRequest(BaseModel):
    code: str


class InterviewAnswerRequest(BaseModel):
    session_id: str
    answer_text: str
    # The candidate's interview code — the same credential `/interview/start`
    # took. `session_id` is a real UUID (low guessability) but is not a
    # secret: it can end up in a browser's history, a referrer header, or a
    # server log. Requiring the code too means holding a leaked session_id
    # alone isn't enough to answer or end someone else's interview.
    code: str


class InterviewFinishRequest(BaseModel):
    session_id: str
    code: str
    reason: str = "interview complete"


# Only signals the portal can actually observe honestly — no claim of
# device/mobile detection a browser cannot make. See EventType's doc comment.
_CLIENT_EVENT_TYPES = {
    "face_verification",
    "tab_hidden",
    "tab_visible",
    "window_blur",
    "window_focus",
    "fullscreen_exit",
    "connection_lost",
    "connection_restored",
}


class InterviewEventRequest(BaseModel):
    session_id: str
    code: str
    event_type: str
    payload: dict = {}


async def _require_code_owns_session(code: str, session_id: str) -> None:
    """Same code+session ownership check `/interview/start` uses to redeem a
    code, run again on every subsequent call the candidate makes against
    that session (answer, event, finish) and on the live voice WebSocket's
    initial handshake (`live_interview.authorize`).

    Ownership alone used to be the whole check: once a code had redeemed a
    session, revoking that code afterward — the exact action HR takes for a
    wrong candidate or a suspected fraud — did nothing. The candidate kept
    answering, kept talking to the live relay, and the interview completed
    normally. Status and expiry are now re-checked on every call, not only
    at redemption, so a revocation actually takes effect mid-interview
    instead of only blocking a session that hasn't started yet."""
    try:
        code_row = await codes_store.fetch_by_code(code)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if code_row is None or code_row.get("session_id") != session_id:
        raise HTTPException(status_code=403, detail="that code does not match this interview session")
    if code_row.get("status") == "revoked":
        raise HTTPException(status_code=403, detail="this interview code has been revoked")
    expires_at = code_row.get("expires_at")
    if expires_at and datetime.fromisoformat(expires_at) < datetime.now(timezone.utc):
        raise HTTPException(status_code=403, detail="this interview code has expired")
    # window_start/window_end are deliberately NOT re-checked here. Those
    # bound when a candidate may START — once a session is legitimately
    # in_progress, the scheduled window closing under them mid-answer must
    # not abort an interview that began on time. Revoked and expired are
    # both "this credential should stop working right now"; the window is
    # not that.


# Phase 3's reasons map to HTTP status the way a REST API should read: a
# code that's simply wrong is a 404 (nothing to find), one that exists but
# can't be redeemed right now is a 409 (conflict with its current state).
_CODE_ERROR_STATUS = {"not_found": 404}


@app.post("/interview-codes/generate")
async def generate_interview_code(
    req: GenerateCodeRequest, authorization: str | None = Header(default=None),
) -> dict:
    """The HR desktop's only way to create a code — centralized here so
    generation is auditable and reusable (a later Google Form automation
    calls the same route), never duplicated client-side.

    Requires the same bearer-token org resolution `/roles` etc. already use.
    `organization_id` is never trusted from the request body — it's resolved
    from the token, and the candidate must actually belong to that org — so
    an authenticated caller can only ever mint a code for their own
    organization's candidates, never anyone else's. (The form-webhook and
    demo-seed paths call `session.interview_codes.generate` directly, not
    this HTTP route, so they're unaffected by this.)

    Ticket 21: also fires the invitation email automatically. A failure to
    email is never allowed to fail code generation — the code is real and
    usable either way; the HR desktop's Email Status section is where a
    failed send actually gets surfaced and retried."""
    organization_id = await _require_org(authorization)

    try:
        candidate = await supabase_store.fetch_candidate(req.candidate_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if candidate is None or candidate.get("organization_id") != organization_id:
        # Same response whether the candidate doesn't exist or belongs to
        # someone else's org — distinguishing the two would let a caller
        # probe candidate ids across organizations.
        raise HTTPException(status_code=404, detail="no such candidate")

    try:
        code_row = await interview_codes.generate(
            req.candidate_id, organization_id, req.role_title,
            required_skills=req.required_skills, difficulty=req.difficulty,
            available_minutes=req.available_minutes, max_attempts=req.max_attempts,
            expires_in_hours=req.expires_in_hours, window_start=req.scheduled_at,
        )
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    try:
        candidate = await supabase_store.fetch_candidate(req.candidate_id)
        if candidate is not None and candidate.get("email"):
            await email_workflow.send_invitation_for_code(code_row, candidate)
    except supabase_store.SupabaseError as exc:
        logger.warning("invitation email skipped for code %s: %s", code_row.get("id"), exc)

    return code_row


@app.post("/internal/candidates/{candidate_id}/auto-invite")
async def auto_invite_candidate(
    candidate_id: str, x_internal_secret: str | None = Header(default=None),
) -> dict:
    """Called by the `candidate_ai_profile` trigger the moment a candidate's
    resume processing reaches READY_FOR_INTERVIEW — the auto-registration
    counterpart to HR clicking "Generate code" by hand. Reuses the exact same
    `interview_codes.generate` + `send_invitation_for_code` calls as every
    other path; this route only adds the plumbing to trigger them from a DB
    state transition instead of a person.

    Protected by a shared secret rather than a login — the caller is a
    Postgres trigger, not a person with a bearer token. Idempotent: a
    candidate who already has an
    active code is returned as-is rather than double-invited, so a retried
    or duplicated trigger firing is harmless."""
    expected_secret = os.environ.get("INTERNAL_AUTOINVITE_SECRET", "")
    if not expected_secret or not x_internal_secret or not secrets.compare_digest(
        x_internal_secret, expected_secret
    ):
        raise HTTPException(status_code=401, detail="invalid or missing internal secret")

    try:
        candidate = await supabase_store.fetch_candidate(candidate_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if candidate is None:
        raise HTTPException(status_code=404, detail="no such candidate")
    organization_id = candidate["organization_id"]

    try:
        profile = await supabase_store.fetch_profile(candidate_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if profile is None or profile.get("processing_status") != "READY_FOR_INTERVIEW":
        raise HTTPException(status_code=409, detail="candidate is not ready for interview")

    role_id = candidate.get("role_id")
    if not role_id:
        raise HTTPException(
            status_code=422,
            detail="candidate has no role_id — cannot determine which role to generate a code for",
        )
    try:
        role = await demo_store.fetch_role(role_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if role is None:
        raise HTTPException(status_code=422, detail="candidate's role_id does not match any role")

    try:
        existing = await codes_store.find_live_code_for_candidate(candidate_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if existing is not None and existing.get("status") == "used":
        # They already sat the interview. Re-processing their resume (which
        # is what re-fires this trigger) must not invite them to do it again.
        return {"status": "already_interviewed", "code_id": existing["id"]}
    if existing is not None and existing.get("expires_at"):
        # Parsed, never compared as strings: Postgres renders timestamptz as
        # "2026-08-11 04:50:14.578971+00" (space, "+00") while Python's
        # isoformat() gives "...T...+00:00", so a lexicographic compare reads
        # ' ' < 'T' and calls every code expiring later *today* expired —
        # which would mint a duplicate code for a candidate who already has a
        # perfectly good one. Same `fromisoformat` treatment the rest of
        # session/interview_codes.py already applies to this column.
        if datetime.fromisoformat(existing["expires_at"]) > datetime.now(timezone.utc):
            return {"status": "existing", "code_id": existing["id"], "code": existing["code"]}

    # The candidate's chosen slot (set by the Google Form intake path via
    # intake-webhook; absent for HR-invited or self-registered candidates).
    # window_end is deliberately a full hour after window_start rather than
    # tied to available_minutes — the slot is when the candidate agreed to
    # be free, not the interview's actual duration, and giving no join grace
    # at all would fail anyone who starts a minute after the requested time.
    preferred_time_raw = candidate.get("preferred_time")
    window_start = datetime.fromisoformat(preferred_time_raw) if preferred_time_raw else None
    window_end = window_start + timedelta(hours=1) if window_start else None

    try:
        code_row = await interview_codes.generate(
            candidate_id, organization_id, role["title"],
            required_skills=role.get("required_skills") or [],
            difficulty="standard", available_minutes=20,
            window_start=window_start, window_end=window_end,
        )
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    email_status = "skipped"
    try:
        if candidate.get("email"):
            result = await email_workflow.send_invitation_for_code(code_row, candidate)
            email_status = result.get("status", "unknown")
    except Exception as exc:  # noqa: BLE001 — a failed email must never fail code generation.
        logger.warning("auto-invite email skipped for code %s: %s", code_row.get("id"), exc)
        email_status = "failed"

    return {
        "status": "created", "code_id": code_row["id"], "code": code_row["code"],
        "email_status": email_status,
    }


class ResendInvitationRequest(BaseModel):
    code_id: str


@app.get("/interview-codes/{code_id}/emails")
async def list_code_emails(
    code_id: str, authorization: str | None = Header(default=None),
) -> dict:
    """The HR desktop's Email Status section: one row per email type
    (invitation, reminder_1h, reminder_30m) that has been attempted for this
    code, each with its status, attempt count, and last error.

    Was unauthenticated — any candidate email address plus every send
    attempt's error text, readable by anyone who could enumerate code ids.
    Same org-ownership shape as `/interview/report/{session_id}`: 404, not
    403, on a code that belongs to someone else's org, so a guessed id
    doesn't confirm whether it's real."""
    organization_id = await _require_org(authorization)
    try:
        code_row = await codes_store.fetch_by_id(code_id)
        if code_row is None or code_row.get("organization_id") != organization_id:
            raise HTTPException(status_code=404, detail="no such interview code")
        return {"emails": await email_store.list_for_code(code_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/interview-codes/resend-invitation")
async def resend_invitation(
    req: ResendInvitationRequest, authorization: str | None = Header(default=None),
) -> dict:
    """The HR desktop's "Resend invitation" button.

    Was unauthenticated — anyone who could name a code_id could make this
    service send a real email, on demand, to whatever candidate address was
    on file, with no rate limit anywhere in the call chain."""
    organization_id = await _require_org(authorization)
    try:
        code_row = await codes_store.fetch_by_id(req.code_id)
        if code_row is None or code_row.get("organization_id") != organization_id:
            raise HTTPException(status_code=404, detail="no such interview code")
        candidate = await supabase_store.fetch_candidate(code_row["candidate_id"])
        if candidate is None or not candidate.get("email"):
            raise HTTPException(status_code=409, detail="candidate has no email on file")
        return await email_workflow.resend_invitation(code_row, candidate)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/email/send-due-reminders")
async def send_due_reminders(x_internal_secret: str | None = Header(default=None)) -> dict:
    """The scheduler's entrypoint (Ticket 21's parallel of Ticket 12's
    `reminder-scheduler`) — call on a timer (cron, an external scheduler, or
    a manual poke) to send whatever 1-hour/30-minute reminder is currently
    due across every active interview code.

    The caller is a scheduler, not a logged-in HR user, so this is gated the
    same way `/internal/candidates/{id}/auto-invite` already is: a shared
    secret, not a bearer token. Was unauthenticated — anyone could trigger a
    reminder sweep across every organization's candidates, on demand,
    repeatedly."""
    expected_secret = os.environ.get("INTERNAL_AUTOINVITE_SECRET", "")
    if not expected_secret or not x_internal_secret or not secrets.compare_digest(
        x_internal_secret, expected_secret
    ):
        raise HTTPException(status_code=401, detail="invalid or missing internal secret")
    try:
        return await email_workflow.send_due_reminders(supabase_store.fetch_candidate)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post(
    "/interview/start",
    dependencies=[Depends(rate_limit.limit("interview-start", 10))],
)
async def interview_start(req: InterviewStartRequest) -> dict:
    """Redeem a code and either resume its in-progress session or open a new
    one. The candidate portal never sends an id it wasn't handed by a human
    — only the code.

    This is the interview code's verification endpoint, and the code is the
    candidate's whole credential (see `InterviewAnswerRequest.code`) — which
    makes this the candidate-side equivalent of `/auth/login`, and it had no
    limiter either. Worse, the reply distinguishes a code that doesn't exist
    (404, via `_CODE_ERROR_STATUS`) from one that does but can't be redeemed
    right now (409), so an unlimited caller gets a clean live/dead oracle to
    guess against.

    A code is 8 characters over a 31-symbol alphabet
    (`interview_codes._ALPHABET`), so the space is ~8.5e11 and guessing was
    never going to be fast — but "the search space is large" is not a rate
    limit, and it stops being the only thing standing in the way the moment
    the alphabet or length is ever shortened. 10/minute leaves a legitimate
    candidate (who types one code, once, and retries a couple of times if
    they fat-finger it) untouched.

    The oracle itself stays: telling a candidate "that code has expired"
    rather than "that code was not recognized" is worth more to the honest
    user than it costs against a now-capped attacker."""
    try:
        return await interview_codes.start_with_code(req.code)
    except interview_codes.CodeError as exc:
        raise HTTPException(
            status_code=_CODE_ERROR_STATUS.get(exc.reason, 409),
            detail={"reason": exc.reason, "message": str(exc)},
        ) from exc
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post(
    "/interview/answer",
    dependencies=[Depends(rate_limit.limit("interview-answer", 30))],
)
async def interview_answer(req: InterviewAnswerRequest) -> dict:
    """Record the candidate's answer to the current question and return the
    next turn — a follow-up, the next topic's question, or completion.

    Public and code-authenticated like the rest of the interview flow, and
    every call behind it is an LLM turn — the same "expensive, reachable
    without a bearer token" shape `/extract-claims` is limited for. 30/min
    is far above the ~1 answer/minute a real interview produces."""
    await _require_code_owns_session(req.code, req.session_id)
    try:
        return await interview_session.answer(req.session_id, req.answer_text)
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.websocket("/interview/live/{session_id}")
async def interview_live(websocket: WebSocket, session_id: str) -> None:
    """Real-time voice channel: candidate mic audio in, AI speech out.
    Strictly additive — `/interview/start` and `/interview/answer` are
    untouched and remain the fallback path (see interview-flow.tsx's own
    framing of voice as a layer around the text-turn contract, not a
    replacement for it).

    `CORSMiddleware` doesn't gate WebSocket upgrades, so the Origin check
    below is manual, not inherited from the app-level middleware. The
    interview code is required as the FIRST message after accept, not a
    query param — a query param would put it in proxy/access logs, the
    same leak `InterviewAnswerRequest.code`'s docstring already reasons
    about for session_id."""
    origin = websocket.headers.get("origin", "")
    allowed = _allowed_origins == "*" or origin in _allowed_origins.split(",")
    if not allowed:
        await websocket.close(code=1008)
        return

    await websocket.accept()
    try:
        first_message = await asyncio.wait_for(websocket.receive_text(), timeout=10)
        code = json.loads(first_message).get("code")
    except (asyncio.TimeoutError, json.JSONDecodeError, KeyError):
        await websocket.close(code=1008, reason="expected {\"code\": \"...\"} as the first message")
        return
    if not code:
        await websocket.close(code=1008, reason="missing code")
        return

    try:
        await live_interview.run_live_session(websocket, session_id, code)
    except live_interview.LiveSessionError as exc:
        logger.warning("live interview session %s rejected: %s", session_id, exc)
        await websocket.close(code=1008, reason=str(exc)[:120])
    except WebSocketDisconnect:
        pass


@app.post(
    "/interview/event",
    # Deliberately the loosest of the four: tab_hidden/tab_visible and
    # window_blur/window_focus fire in pairs on every alt-tab, and a nervous
    # candidate glancing at another window generates real bursts. 120/min is
    # high enough not to drop honest telemetry (dropping it would corrupt
    # the very signal HR reads) while still bounding a flood.
    dependencies=[Depends(rate_limit.limit("interview-event", 120))],
)
async def interview_event(req: InterviewEventRequest) -> dict:
    """Record one client-observed signal (face verification result, tab/
    window/fullscreen/connection change) against a session. Same code+session
    auth as /interview/answer. Never interprets the signal — the report layer
    surfaces it as a count, HR draws the conclusion."""
    if req.event_type not in _CLIENT_EVENT_TYPES:
        raise HTTPException(status_code=422, detail=f"unknown event_type: {req.event_type}")
    await _require_code_owns_session(req.code, req.session_id)
    try:
        await interview_session.record_event(
            req.session_id, EventType(req.event_type), req.payload,
        )
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {"recorded": True}


@app.get("/interview/report/{session_id}")
async def interview_report(
    session_id: str, authorization: str | None = Header(default=None),
) -> dict:
    """The evidence-backed report: one entry per planned topic — claim,
    question(s), evidence quote, verdict, confidence. No score, no ranking.
    Built entirely from what's already persisted; no model is called.

    HR-only, same bearer-token org resolution as `/roles` etc. A session_id
    is a real UUID but not treated as secret elsewhere in this file (see
    `InterviewAnswerRequest.code`) — without this check, anyone who obtained
    or guessed one could read a candidate's full interview transcript and
    verdicts. 404 (not 403) on an org mismatch, so this doesn't reveal
    whether a given session_id exists at all to someone outside its org."""
    organization_id = await _require_org(authorization)
    try:
        session_row = await session_store.fetch_session(session_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if session_row is None or session_row.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail=f"no session {session_id}")

    try:
        return await interview_session.report(session_id)
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post(
    "/interview/finish",
    dependencies=[Depends(rate_limit.limit("interview-finish", 10))],
)
async def interview_finish(req: InterviewFinishRequest) -> dict:
    """Abandon a session early (candidate disconnected, timed out, etc).
    A session that runs its plan to completion finishes itself — this is
    only for cutting one short."""
    await _require_code_owns_session(req.code, req.session_id)
    try:
        await interview_session.abandon(req.session_id, req.reason)
        return {"session_id": req.session_id, "status": "abandoned"}
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def intake_application_url(role: dict) -> str | None:
    """The Google Form this role actually collects applications through, or
    None if it has none.

    A form is created per intake by POST /intakes/{id}/google-form and its
    responder URL stored on that intake (`application_url`). Offering it
    here is what makes the auto-generated form the front door: a candidate
    browsing open roles lands on the same form the Apps Script trigger and
    the intake poller already feed into, so every applicant enters through
    one pipeline instead of the portal quietly opening a second one.

    Only an **active** intake's form is offered. A closed intake's form
    still exists and Google will still accept responses on it, so linking
    to it would collect applications for a campaign that is over — and
    those responses would be attributed to the closed intake by
    intake-webhook's formId match, which is worse than not collecting them.

    Nullable rather than a filter: a role with no active intake (or an
    active one whose form was never generated) still belongs in the list,
    and falls back to the portal's own apply page."""
    for intake in role.get("intakes") or []:
        if intake.get("status") == "active" and intake.get("application_url"):
            return intake["application_url"]
    return None


@app.get(
    "/roles/open",
    dependencies=[Depends(rate_limit.limit("roles-open", 30))],
)
async def roles_open() -> dict:
    """Public: lets a candidate with no link yet browse open roles and pick
    one to apply to. Same minimal shape as apply-info — title, org name and
    the role's application URL, never required_skills or notes — since this
    is reachable by anyone."""
    try:
        roles = await demo_store.list_open_roles()
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "roles": [
            {
                "id": role["id"],
                "title": role["title"],
                "organization_name": (role.get("organizations") or {}).get("name", ""),
                "application_url": intake_application_url(role),
            }
            for role in roles
        ]
    }


@app.get(
    "/roles/{role_id}/apply-info",
    dependencies=[Depends(rate_limit.limit("roles-apply-info", 30))],
)
async def role_apply_info(role_id: str) -> dict:
    """Public: lets the portal's apply page show "You're applying for
    {role} at {organization}" before the candidate submits anything. Deliberately
    minimal — title and org name only, never required_skills or notes, since
    this is reachable by anyone with the link."""
    try:
        role = await demo_store.fetch_role(role_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if role is None:
        raise HTTPException(status_code=404, detail="that application link is no longer valid")
    try:
        org = await demo_store.fetch_organization(role["organization_id"])
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "role_title": role["title"],
        "organization_name": org["name"] if org else "",
    }


class SelfRegisterRequest(BaseModel):
    role_id: str
    name: str
    email: str
    resume_base64: str
    preferred_time: Optional[datetime] = None


@app.post(
    "/candidates/apply",
    dependencies=[Depends(rate_limit.limit("candidates-apply", 10))],
)
async def candidate_apply(req: SelfRegisterRequest) -> dict:
    """Public: a candidate applying directly from the portal, no Google Form
    or Apps Script involved. See `candidates/self_registration.py` for the
    actual pipeline — this route only maps its errors to HTTP status."""
    try:
        return await self_registration.register_candidate(
            role_id=req.role_id,
            name=req.name,
            email=req.email,
            resume_base64=req.resume_base64,
            preferred_time=req.preferred_time,
        )
    except self_registration.SelfRegistrationError as exc:
        message = str(exc)
        status_code = 404 if "application link" in message else 400
        raise HTTPException(status_code=status_code, detail=message) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


# ---------------------------------------------------------------------------
# HR portal: auth + org-scoped listing.
#
# A logged-in HR user is a GoTrue user whose user_metadata carries the
# organization_id it belongs to (same shape demo_store already creates for
# the seeded demo HR user). List routes never take an organization_id from
# the client — they resolve it from the bearer token via GoTrue, the same
# way every other org-scoped write in this file already trusts identity.
# ---------------------------------------------------------------------------


class SignupRequest(BaseModel):
    # Required when creating a new organization, ignored when redeeming an
    # invite (the invitation already names the organization, and letting the
    # request name it too would just be a second, spoofable source).
    organization_name: str | None = None
    # The ONLY way into an existing organization. See `_INVITE_TTL_HOURS`.
    invite_token: str | None = None
    name: str | None = None
    email: str
    password: str


class CreateInviteRequest(BaseModel):
    email: str


# Long enough to survive a weekend, short enough that a forgotten invitation
# in someone's inbox is not a standing key to the company's hiring pipeline.
_INVITE_TTL_HOURS = 72


def _hash_invite_token(token: str) -> str:
    """Invitations are stored hashed, so a database dump is not a pile of
    usable ones (migration 0013). SHA-256 without a salt is correct here and
    not a password shortcut: the token is 32 bytes of `secrets` output, so
    there is no dictionary to attack."""
    return hashlib.sha256(token.encode()).hexdigest()


class LoginRequest(BaseModel):
    email: str
    password: str


async def _require_org(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.split(" ", 1)[1]
    try:
        user = await demo_store.resolve_user_from_token(token)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    # app_metadata, never user_metadata: the latter is writable by the account
    # it describes (PUT /auth/v1/user), so reading the caller's organization
    # from it let any recruiter re-point themselves at another company — and
    # the database's RLS policies, which read the same claim, would have
    # agreed. There is deliberately no fallback to user_metadata here; a
    # fallback is the bypass. See migration 0012.
    organization_id = (user.get("app_metadata") or {}).get("organization_id")
    if not organization_id:
        raise HTTPException(status_code=403, detail="account has no organization")
    return organization_id


@app.post("/organizations/invites")
async def create_organization_invite(
    req: CreateInviteRequest, authorization: str | None = Header(default=None),
) -> dict:
    """Invite one person into the caller's own organization.

    The raw token is returned exactly once, here. It is stored hashed, so
    there is no route that can show it again — a lost invitation is reissued,
    never recovered. The org is resolved from the caller's token, never taken
    from the request, so this cannot mint an invitation into someone else's
    company.

    Nothing emails it yet: the caller passes it to the invitee out-of-band.
    Wiring this into `notifications/` is a follow-up, and does not change who
    is allowed to create one."""
    organization_id = await _require_org(authorization)
    token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + timedelta(hours=_INVITE_TTL_HOURS)
    try:
        invite = await demo_store.create_invite({
            "organization_id": organization_id,
            "email": req.email.strip().lower(),
            "token_hash": _hash_invite_token(token),
            "expires_at": expires_at.isoformat(),
        })
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "invite_id": invite["id"],
        "email": invite["email"],
        "expires_at": invite["expires_at"],
        "invite_token": token,
    }


async def _organization_for_signup(req: SignupRequest) -> dict:
    """Which organization this signup lands in, and the only place that
    decides it.

    Signup used to look the organization up by NAME and join it if it
    existed. Names are published by the unauthenticated `/roles/open`, so
    that made "become a recruiter at any company you can name" a two-request
    operation. Now: a new organization, or an invitation. Nothing else."""
    if req.invite_token:
        invite = await demo_store.fetch_live_invite(_hash_invite_token(req.invite_token))
        # One message for every way an invite can be unusable — wrong token,
        # already spent, expired, or issued to a different address. Telling
        # them apart would turn this into an oracle for which invitations
        # exist.
        invalid = HTTPException(
            status_code=403,
            detail={"reason": "invalid_invite", "message": "That invitation is not valid."},
        )
        if invite is None:
            raise invalid
        if datetime.fromisoformat(invite["expires_at"]) < datetime.now(timezone.utc):
            raise invalid
        if invite["email"].strip().lower() != req.email.strip().lower():
            raise invalid

        claimed = await demo_store.mark_invite_accepted(
            invite["id"], datetime.now(timezone.utc).isoformat(),
        )
        if not claimed:
            # Lost the race with a simultaneous redemption of the same
            # invitation. It is spent either way; do not create a second
            # account from it.
            raise invalid

        org = await demo_store.fetch_organization(invite["organization_id"])
        if org is None:
            raise invalid
        return org

    if not req.organization_name or not req.organization_name.strip():
        raise HTTPException(
            status_code=422,
            detail={
                "reason": "organization_name_required",
                "message": "Enter a company name, or use an invitation link.",
            },
        )
    existing = await demo_store.find_organization_by_name(req.organization_name)
    if existing is not None:
        raise HTTPException(
            status_code=409,
            detail={
                "reason": "organization_exists",
                "message": (
                    "An organization with that name already exists. Ask someone "
                    "there to invite you."
                ),
            },
        )
    return await demo_store.create_organization(req.organization_name)


@app.post("/auth/signup")
async def auth_signup(req: SignupRequest) -> dict:
    """Create an HR account and sign it in immediately — the portal has no
    "check your email" step because GoTrue's own email flows aren't wired
    here yet.

    Which organization it lands in is decided entirely by
    `_organization_for_signup`."""
    try:
        org = await _organization_for_signup(req)

        # An address that already has an account is refused outright rather
        # than silently handed the existing user (which is what happened
        # before: `find_or_create_hr_user` returned it without checking the
        # password, then sign-in failed and the caller saw a 503, as though
        # the service were broken). This does let someone learn an address is
        # registered — the standard, accepted trade for a signup form that
        # can tell you why it refused you.
        if await demo_store.find_auth_user_by_email(req.email) is not None:
            raise HTTPException(
                status_code=409,
                detail={
                    "reason": "email_registered",
                    "message": "An account with that email already exists. Sign in instead.",
                },
            )

        await demo_store.create_hr_user(req.email, req.password, org["id"], name=req.name)
        token = await demo_store.sign_in(req.email, req.password)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {
        "access_token": token["access_token"],
        "organization_id": org["id"],
        "organization_name": org["name"],
        "email": req.email,
        "name": req.name,
    }


@app.post(
    "/auth/login",
    dependencies=[Depends(rate_limit.limit("auth-login-ip", 20))],
)
async def auth_login(req: LoginRequest) -> dict:
    """Sign in an HR user.

    Rate-limited on TWO identities, because either one alone leaves the
    other attack open. This is the only route in the file that verifies a
    password, and it was the only public route with no limiter at all —
    every other one (`/extract-claims`, `/candidates/apply`, `/face/analyze`
    …) already had one, so this was an omission, not a decision.

    Per-IP (the dependency above) stops one host spraying a password list.
    It does nothing about a distributed attempt against one account, so the
    per-email bucket below caps attempts on a single address regardless of
    where they come from. Neither is a defence against a botnet spread
    across both axes; that needs an edge layer, same caveat
    `security/rate_limit.py`'s own docstring already carries.

    The email bucket is consumed BEFORE `sign_in` is called, so a wrong
    password costs the attacker a slot exactly like a right one does — a
    limiter that only counted successes would not be a limiter. The cost to
    a real user is that fat-fingering their password five times in a minute
    makes them wait for the rest of it.

    `/auth/signup` already tells a caller whether an address is registered
    (409 `email_registered`, a trade its own docstring accepts). That makes
    recruiter emails harvestable, which is precisely what turns an unlimited
    login route into a practical account takeover — the enumeration is only
    cheap because this cap now exists to blunt what follows it."""
    rate_limit.check("auth-login-email", req.email.strip().lower(), 5)
    try:
        token = await demo_store.sign_in(req.email, req.password)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    # Same claim, same reasoning as `_require_org` above.
    organization_id = (token.get("user", {}).get("app_metadata") or {}).get("organization_id")
    if not organization_id:
        raise HTTPException(status_code=403, detail="account has no organization")

    return {
        "access_token": token["access_token"],
        "organization_id": organization_id,
        "email": req.email,
    }


@app.get("/roles")
async def list_roles(authorization: str | None = Header(default=None)) -> dict:
    organization_id = await _require_org(authorization)
    try:
        return {"roles": await demo_store.list_roles(organization_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/candidates")
async def list_candidates(authorization: str | None = Header(default=None)) -> dict:
    organization_id = await _require_org(authorization)
    try:
        return {"candidates": await demo_store.list_candidates(organization_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def _safe_download_filename(resume_path: str) -> str:
    """The last path segment of `resume_path`, reduced to characters that
    cannot break out of the quoted `filename="..."` in a Content-Disposition
    header.

    That segment is not ours. It is whatever the candidate's browser called
    the file at upload time, carried through `infra/apply-webhook` (and the
    Google Form intake path) into the storage key and back out here. A
    filename containing a double quote closes the quoted string early and
    lets the rest be read as further header parameters; a CR or LF is a
    header-splitting attempt. Starlette rejects the most blatant of those,
    but "the framework probably catches it" is not the check — this is.

    Everything outside [A-Za-z0-9._-] becomes an underscore, leading dots
    are dropped so the result can't be a hidden/relative name, and the
    length is capped. An empty or fully-stripped name falls back to a
    constant rather than emitting `filename=""`.

    The upload side validates this too (see `infra/apply-webhook`), so this
    is the second of two independent checks, not the only one — résumés
    predating that validation are already in the bucket."""
    segment = resume_path.rsplit("/", 1)[-1]
    cleaned = "".join(c if (c.isalnum() and c.isascii()) or c in "._-" else "_" for c in segment)
    cleaned = cleaned.lstrip(".")[:120]
    return cleaned or "resume.pdf"


@app.get("/candidates/{candidate_id}/resume")
async def get_candidate_resume(
    candidate_id: str, authorization: str | None = Header(default=None),
) -> Response:
    """Streams a candidate's uploaded résumé through the backend, which holds
    the only credential (the service-role key) that can read the private
    `resumes` bucket — there is no client-side storage policy for it, by the
    same "nothing shipped in a Flutter web bundle can hold a secret" reasoning
    Ticket 11's doc gives for keeping every AI-gateway credential server-side.

    404 (not 403) on an org mismatch or a missing résumé, same reasoning as
    `/interview/report/{session_id}` above: a guessed candidate_id should not
    reveal whether it belongs to a real candidate in another org, and "never
    uploaded one" is not a fault worth a different status code from "not
    found"."""
    organization_id = await _require_org(authorization)
    try:
        candidate = await supabase_store.fetch_candidate(candidate_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if candidate is None or candidate.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail=f"no candidate {candidate_id}")

    resume_path = candidate.get("resume_path")
    if not resume_path:
        raise HTTPException(status_code=404, detail="no résumé on file for this candidate")

    try:
        content = await supabase_store.download_resume(resume_path)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return Response(
        content=content,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{_safe_download_filename(resume_path)}"'},
    )


class CreateIntakeRequest(BaseModel):
    role_id: str
    name: str


_INTAKE_STATUSES = {"draft", "active", "paused", "closed"}
_INTAKE_TRANSITIONS = {
    "draft": {"active", "closed"},
    "active": {"paused", "closed"},
    "paused": {"active", "closed"},
    "closed": set(),  # terminal — matches interview_codes' revoked/expired/used states
}


class UpdateIntakeStatusRequest(BaseModel):
    status: str


@app.post("/intakes")
async def create_intake(
    req: CreateIntakeRequest, authorization: str | None = Header(default=None),
) -> dict:
    """A specific hiring campaign for a role ("Backend Engineer — August
    2026 Intake"). organization_id is never taken from the request — it's
    resolved from the bearer token, same as every other org-scoped write in
    this file — and the database's own trigger (see infra/migrations/
    0008_intakes.sql) refuses the insert outright if role_id somehow belongs
    to a different org than the caller's, so a spoofed role_id fails closed
    rather than silently creating a cross-org intake."""
    organization_id = await _require_org(authorization)
    try:
        role = await demo_store.fetch_role(req.role_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if role is None or role.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail="no such role")
    try:
        return await demo_store.create_intake({
            "organization_id": organization_id, "role_id": req.role_id, "name": req.name,
        })
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/intakes")
async def list_intakes(
    role_id: str | None = None, authorization: str | None = Header(default=None),
) -> dict:
    organization_id = await _require_org(authorization)
    try:
        return {"intakes": await demo_store.list_intakes(organization_id, role_id=role_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/intakes/{intake_id}")
async def get_intake(
    intake_id: str, authorization: str | None = Header(default=None),
) -> dict:
    organization_id = await _require_org(authorization)
    try:
        intake = await demo_store.fetch_intake(intake_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    # Same org, same 404 whether missing or someone else's — don't let a
    # caller distinguish "doesn't exist" from "exists, not yours".
    if intake is None or intake.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail="no such intake")
    return intake


@app.patch("/intakes/{intake_id}")
async def update_intake_status(
    intake_id: str, req: UpdateIntakeStatusRequest, authorization: str | None = Header(default=None),
) -> dict:
    organization_id = await _require_org(authorization)
    if req.status not in _INTAKE_STATUSES:
        raise HTTPException(status_code=422, detail=f"unknown status: {req.status}")
    try:
        intake = await demo_store.fetch_intake(intake_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if intake is None or intake.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail="no such intake")
    current = intake["status"]
    if req.status != current and req.status not in _INTAKE_TRANSITIONS[current]:
        raise HTTPException(
            status_code=409, detail=f"cannot move intake from {current} to {req.status}",
        )
    fields = {"status": req.status}
    if req.status == "closed":
        fields["closed_at"] = datetime.now(timezone.utc).isoformat()
    try:
        await demo_store.update_intake(intake_id, fields)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {**intake, **fields}


@app.get(
    "/intakes/{intake_id}/apply-info",
    dependencies=[Depends(rate_limit.limit("intakes-apply-info", 30))],
)
async def intake_apply_info(intake_id: str) -> dict:
    """Public: the intake-aware sibling of /roles/{role_id}/apply-info — an
    application form should belong to one specific campaign, not just a
    role, so a role with two active intakes (e.g. an August and an October
    cycle) never has candidates from one bleeding into the other."""
    try:
        intake = await demo_store.fetch_intake(intake_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if intake is None or intake["status"] != "active":
        raise HTTPException(status_code=404, detail="that application link is no longer valid")
    try:
        role = await demo_store.fetch_role(intake["role_id"])
        org = await demo_store.fetch_organization(intake["organization_id"])
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "role_title": role["title"] if role else "",
        "organization_name": org["name"] if org else "",
        "intake_name": intake["name"],
    }


class IntakeApplyRequest(BaseModel):
    name: str
    email: str
    resume_base64: str
    preferred_time: Optional[datetime] = None


@app.post(
    "/intakes/{intake_id}/apply",
    dependencies=[Depends(rate_limit.limit("intakes-apply", 10))],
)
async def intake_apply(intake_id: str, req: IntakeApplyRequest) -> dict:
    """Public: intake-keyed candidate self-registration — the form/link
    itself carries the campaign identity, so the candidate never chooses
    (and can't spoof) an organization or role. See candidates/
    self_registration.py; this route only maps its errors to HTTP status,
    same as the legacy /candidates/apply route below."""
    try:
        return await self_registration.register_candidate(
            intake_id=intake_id, name=req.name, email=req.email,
            resume_base64=req.resume_base64, preferred_time=req.preferred_time,
        )
    except self_registration.SelfRegistrationError as exc:
        message = str(exc)
        status_code = 404 if "application link" in message else 400
        raise HTTPException(status_code=status_code, detail=message) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


# ---------------------------------------------------------------------------
# Google Forms automation (Part 7-9 of the intake work). Per-organization
# OAuth — each company connects its own Google account, so a form an org
# creates lives in that org's own Drive, not a CogniHire-owned one.
# ---------------------------------------------------------------------------


# A signed state is a bearer credential for "attach a Google account to
# this organization", and it used to be good forever. The nonce was
# generated, signed, and then never looked at again — nothing recorded it,
# so nothing could tell a first use from a thousandth. Combined with no
# expiry, a state value recovered from browser history, a referrer header,
# or a proxy log stayed valid indefinitely: replay it with your own consent
# code and your Google account is now the one wired to that company's
# hiring pipeline. That is exactly the account-linking CSRF `state` exists
# to prevent.
_STATE_TTL_SECONDS = 600

# nonce -> the monotonic time it was consumed. In-process, for the same
# reason security/rate_limit.py is: docker-compose.api.yml runs exactly one
# container, and a dict is the smallest thing that actually makes a state
# single-use without adding infrastructure this project doesn't otherwise
# run. A restart forgets them, so a replay is still bounded by the TTL
# above rather than by this — the two controls cover each other's gap, and
# neither is sufficient alone.
_consumed_state_nonces: dict[str, float] = {}


def _sweep_consumed_nonces(now: float) -> None:
    """Drop nonces past the point where the TTL check would reject them
    anyway. Without this the dict only ever grows, one entry per OAuth
    connect attempt, for the life of the process."""
    for nonce in [n for n, at in _consumed_state_nonces.items() if now - at > _STATE_TTL_SECONDS]:
        del _consumed_state_nonces[nonce]


def _sign_state(organization_id: str) -> str:
    secret = os.environ.get("GOOGLE_OAUTH_STATE_SECRET", "")
    if not secret:
        raise HTTPException(status_code=503, detail="Google OAuth is not configured")
    nonce = secrets.token_urlsafe(16)
    # Issued-at is inside the signed payload, so it cannot be edited without
    # invalidating the signature — a state that carried its own unsigned
    # expiry would just be asking the attacker what the expiry should be.
    issued_at = int(time.time())
    payload = f"{organization_id}:{nonce}:{issued_at}"
    signature = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}:{signature}"


def _verify_state(state: str) -> str:
    """Returns the organization_id if the state is genuine, unexpired, and
    not already spent. Raises otherwise — this is what stops a forged or
    replayed callback from attaching an attacker's Google account to
    someone else's organization.

    Parsed from the right, not the left: the signature and issued-at are
    fixed-shape fields at the end, so splitting that way means an
    organization_id containing a colon can never shift the field boundaries
    and change which bytes get signature-checked.
    """
    secret = os.environ.get("GOOGLE_OAUTH_STATE_SECRET", "")
    if not secret:
        raise HTTPException(status_code=503, detail="Google OAuth is not configured")

    payload, _, signature = state.rpartition(":")
    rest, _, issued_at_raw = payload.rpartition(":")
    organization_id, _, nonce = rest.rpartition(":")
    if not signature or not issued_at_raw or not nonce or not organization_id:
        raise HTTPException(status_code=400, detail="malformed state")

    expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    # Signature first: everything below reads fields we have not yet proven
    # were written by us.
    if not secrets.compare_digest(signature, expected):
        raise HTTPException(status_code=400, detail="invalid or expired state")

    try:
        issued_at = int(issued_at_raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="malformed state")
    if time.time() - issued_at > _STATE_TTL_SECONDS:
        raise HTTPException(status_code=400, detail="invalid or expired state")

    now = time.monotonic()
    _sweep_consumed_nonces(now)
    if nonce in _consumed_state_nonces:
        raise HTTPException(status_code=400, detail="invalid or expired state")
    _consumed_state_nonces[nonce] = now

    return organization_id


@app.get("/organizations/{organization_id}/google/connect")
async def google_connect(
    organization_id: str, authorization: str | None = Header(default=None),
) -> dict:
    """Returns the Google consent URL for the caller's org — the portal
    navigates the browser there itself (`window.location.href = ...`)
    rather than this route redirecting directly, since a plain browser
    navigation can't carry the bearer token this route needs to verify the
    caller actually belongs to the org they're connecting."""
    caller_org = await _require_org(authorization)
    if caller_org != organization_id:
        raise HTTPException(status_code=404, detail="no such organization")
    state = _sign_state(organization_id)
    try:
        return {"authorize_url": google_oauth.build_authorize_url(state)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/organizations/{organization_id}/google/status")
async def google_status(
    organization_id: str, authorization: str | None = Header(default=None),
) -> dict:
    caller_org = await _require_org(authorization)
    if caller_org != organization_id:
        raise HTTPException(status_code=404, detail="no such organization")
    try:
        connection = await google_oauth_store.get_connection(organization_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "connected": connection is not None,
        "google_account_email": connection["google_account_email"] if connection else None,
    }


@app.post("/internal/google/access-token")
async def internal_google_access_token(
    organization_id: str, x_internal_secret: str | None = Header(default=None),
) -> dict:
    """Hands a live Google access token to the `intake-form-poller` Edge
    Function, which used to read `access_token`/`refresh_token` straight out
    of `google_oauth_connections`. Those columns are Fernet ciphertext now
    (security/token_crypto.py), so that direct read broke: the function sent
    ciphertext to Google as a refresh token and got HTTP 400 on every run,
    while still returning 200 — a silent failure.

    Deno has no access to the encryption key and should not: the key lives
    with this service, so token handling belongs here too. This route is a
    thin wrapper over the same `get_valid_access_token` every in-process
    caller uses, so decrypt/refresh/re-encrypt stays in exactly one place.

    Shared secret rather than a bearer token, matching
    `/internal/candidates/{id}/auto-invite` — the caller is a scheduled job,
    not a person."""
    expected_secret = os.environ.get("INTERNAL_AUTOINVITE_SECRET", "")
    if not expected_secret or not x_internal_secret or not secrets.compare_digest(
        x_internal_secret, expected_secret
    ):
        raise HTTPException(status_code=401, detail="invalid or missing internal secret")
    try:
        access_token = await google_oauth.get_valid_access_token(organization_id)
    except google_oauth.GoogleOAuthError as exc:
        # Google rejected the refresh (revoked consent, expired refresh
        # token). Distinct from "never connected" below so the poller's
        # failure list says which one it is.
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {"access_token": access_token}


@app.get("/google/oauth/callback")
async def google_oauth_callback(code: str, state: str) -> Response:
    """Hit by Google directly, not the portal — no bearer token available,
    only what `state` proves. See _verify_state."""
    organization_id = _verify_state(state)
    try:
        tokens = await google_oauth.exchange_code_for_tokens(code)
    except google_oauth.GoogleOAuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    # userinfo isn't strictly needed for the flow to work, only so the
    # status endpoint can show HR *which* Google account is connected.
    async with httpx.AsyncClient(timeout=10) as client:
        userinfo_response = await client.get(
            "https://www.googleapis.com/oauth2/v2/userinfo",
            headers={"Authorization": f"Bearer {tokens['access_token']}"},
        )
    google_email = (
        userinfo_response.json().get("email", "") if userinfo_response.status_code == 200 else ""
    )

    try:
        await google_oauth_store.upsert_connection({
            "organization_id": organization_id,
            "google_account_email": google_email,
            "access_token": tokens["access_token"],
            "refresh_token": tokens["refresh_token"],
            "token_expires_at": (
                datetime.now(timezone.utc) + timedelta(seconds=tokens["expires_in"])
            ).isoformat(),
            "scope": tokens.get("scope", ""),
        })
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    # Same `os.environ.get(name, default)` trap as PORTAL_URL_DEFAULT in
    # notifications/workflow.py: docker-compose.api.yml always sets the key
    # (present-but-empty when the host .env doesn't define it), so the
    # default never fired and this redirected to a bare "/settings?..." —
    # relative to api.cognihire.online, which has no such route, so the
    # OAuth flow 404'd on its last step. `or` catches empty, not just absent.
    portal_url = os.environ.get("PORTAL_URL") or "http://localhost:3000"
    return RedirectResponse(f"{portal_url}/settings?google=connected")


@app.post("/intakes/{intake_id}/google-form")
async def create_google_form_for_intake(
    intake_id: str, authorization: str | None = Header(default=None),
) -> dict:
    """The only step that needs no further browser redirect — once an org
    is connected, creating any number of forms afterward is a plain
    server-to-server call, triggerable straight from Flutter."""
    organization_id = await _require_org(authorization)
    try:
        intake = await demo_store.fetch_intake(intake_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if intake is None or intake.get("organization_id") != organization_id:
        raise HTTPException(status_code=404, detail="no such intake")

    try:
        access_token = await google_oauth.get_valid_access_token(organization_id)
    except supabase_store.SupabaseError:
        raise HTTPException(
            status_code=409, detail="connect this organization's Google account first",
        )

    role = await demo_store.fetch_role(intake["role_id"])
    org = await demo_store.fetch_organization(organization_id)
    title = f"CogniHire — {org['name'] if org else organization_id} — " \
            f"{role['title'] if role else 'Role'} — {intake['name']}"
    try:
        form = await google_forms.create_intake_form(access_token, title=title)
    except google_forms.GoogleFormsError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    try:
        await demo_store.update_intake(intake_id, {
            "google_form_id": form["form_id"], "application_url": form["application_url"],
        })
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {**intake, **form}


@app.get("/interviews")
async def list_interviews(authorization: str | None = Header(default=None)) -> dict:
    organization_id = await _require_org(authorization)
    try:
        return {"interviews": await session_store.list_sessions_for_org(organization_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/reports")
async def list_reports(authorization: str | None = Header(default=None)) -> dict:
    organization_id = await _require_org(authorization)
    try:
        return {
            "reports": await session_store.list_sessions_for_org(organization_id, status="complete"),
        }
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/interview-codes")
async def list_interview_codes(authorization: str | None = Header(default=None)) -> dict:
    """Org-scoped code list with invitation email status attached — the
    portal's Interviews list needs both to answer "was this candidate even
    emailed, and did it land" without a request per code. Same bearer-token
    org resolution as every other list route here."""
    organization_id = await _require_org(authorization)
    try:
        codes = await codes_store.list_codes_for_org(organization_id)
        invitations = await email_store.list_invitations_for_org(organization_id)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    invitation_by_code = {row["code_id"]: row for row in invitations}
    for code in codes:
        invitation = invitation_by_code.get(code["id"])
        code["invitation_status"] = invitation["status"] if invitation else None
        code["invitation_error"] = invitation.get("last_error") if invitation else None

    return {"interview_codes": codes}


@app.post("/demo/seed")
async def demo_seed_environment() -> dict:
    """Ticket 19 — one-click demo environment: a fixed demo organization, an
    HR login, three roles, and five candidates with different resume
    profiles, each run through the real resume pipeline. Idempotent —
    existing org/roles/candidates are reused rather than duplicated, so this
    is safe to call again (e.g. after /demo/reset).

    Same non-production guard as `/dev/seed-tester-account`: this creates
    real Supabase data and was previously reachable, unauthenticated, in
    production."""
    _require_non_production()
    try:
        return await demo_seed.seed_demo_environment()
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/dev/seed-multi-tenant-demo")
async def seed_multi_tenant_demo_route() -> dict:
    """Seeds two ADDITIONAL organizations ("Innotech Solutions", "Vertex
    Systems") beyond /demo/seed's single "CogniHire Demo Co" — both run a
    "Backend Engineer" role with no collision, and one role runs two
    separate intakes whose candidates never mix. See demo/
    multi_tenant_seed.py for exactly what this proves and why it's a
    separate module rather than a change to /demo/seed's existing,
    tested, single-org shape.

    Same non-production guard as every other /dev/* route."""
    _require_non_production()
    try:
        return await multi_tenant_seed.seed_multi_tenant_demo()
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/demo/reset")
async def demo_reset_environment() -> dict:
    """Clears interview sessions/events/codes for the demo org and re-seeds
    fresh codes, so the same environment can be re-demoed without manual
    database cleanup. Candidates, profiles, roles, and the org are untouched.

    Same non-production guard as `/dev/seed-tester-account` — this is a
    destructive, unauthenticated route and was previously reachable in
    production."""
    _require_non_production()
    try:
        return await demo_reset.reset_demo_environment()
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


def _require_non_production() -> None:
    """Guards every dev-only route in this file. Default is "development" —
    a deploy that forgets to set ENVIRONMENT must fail closed on the safe
    side (route unavailable), not fail open into production."""
    environment = os.environ.get("ENVIRONMENT", "development")
    if environment == "production":
        raise HTTPException(status_code=404)


@app.post("/dev/seed-tester-account")
async def seed_tester_account() -> dict:
    """Creates (or reuses) one hardcoded HR account — "CogniHire Test
    Company" / tester@cognihire.local — for local/staging manual testing of
    the company portal without going through /auth/signup every time.

    Refuses to run when ENVIRONMENT=production (see `_require_non_production`).
    The account itself is a real Supabase Auth user created through the same
    `demo_store.create_hr_user` call `/demo/seed`'s HR login uses; it signs in
    through the normal `/auth/login` flow like any other HR user — this route
    only exists to save the manual signup step, not to bypass auth.

    Credentials are defined in `demo/tester_account.py` — edit or delete that
    module (and this route) to change or remove the tester account."""
    _require_non_production()
    try:
        return await tester_account.seed_tester_account()
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


# One JPEG video frame at webcam resolution is a few hundred KB; 8MB is
# generous headroom without leaving the door open to an attacker streaming
# an unbounded body at an endpoint that (until Phase 1's default-deny) had
# no auth and no other size control at all.
_MAX_FRAME_BYTES = 8 * 1024 * 1024


@app.post(
    "/face/analyze",
    response_model=FrameAnalysis,
    dependencies=[Depends(rate_limit.limit("face-analyze", 20))],
)
async def analyze_frame(file: UploadFile = File(...)) -> FrameAnalysis:
    raw = await file.read(_MAX_FRAME_BYTES + 1)
    if len(raw) > _MAX_FRAME_BYTES:
        raise HTTPException(status_code=413, detail="frame is larger than 8MB")

    img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return FrameAnalysis(
            engine_available=_face_app is not None,
            engine_error=ENGINE_ERROR,
            face_detected=False,
            embedding_available=False,
            recommendations=["Frame could not be decoded"],
        )

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    brightness, sharpness = _quality(gray)

    if _face_app is None:
        # Honest dead-end: quality metrics only, no invented identity signal.
        return FrameAnalysis(
            engine_available=False,
            engine_error=ENGINE_ERROR,
            face_detected=False,
            embedding_available=False,
            brightness=brightness,
            sharpness=sharpness,
            recommendations=["Face recognition engine unavailable"],
        )

    faces = _face_app.get(img)
    if not faces:
        return FrameAnalysis(
            engine_available=True,
            face_detected=False,
            embedding_available=False,
            brightness=brightness,
            sharpness=sharpness,
            recommendations=_recommendations(brightness, sharpness, 0),
        )

    # Largest face wins: the candidate is the subject nearest the camera.
    face = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    x1, y1, x2, y2 = face.bbox
    face_size = int((x2 - x1) * (y2 - y1))

    return FrameAnalysis(
        engine_available=True,
        face_detected=True,
        embedding_available=True,
        embedding=[float(v) for v in face.embedding],
        face_size=face_size,
        brightness=brightness,
        sharpness=sharpness,
        recommendations=_recommendations(brightness, sharpness, face_size),
    )
