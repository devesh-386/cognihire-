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

import logging
import os
import secrets
from datetime import datetime, timezone
from typing import Optional

import cv2
import numpy as np
from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from ai import claim_extraction
from candidates import self_registration
from demo import reset as demo_reset
from demo import seed as demo_seed
from demo import tester_account
from notifications import store as email_store
from notifications import workflow as email_workflow
from pipeline import demo_store, profile_builder, supabase_store
from security import rate_limit
from session import codes_store, interview_codes, interview_session, session_store

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

app = FastAPI(title="CogniHire Face Service", version="0.1.0")

# "*" only for local dev. Once this runs on a public VM (Ticket 9), set
# ALLOWED_ORIGINS to the HR app's and candidate web app's actual origins.
_allowed_origins = os.environ.get("ALLOWED_ORIGINS", "*")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _allowed_origins == "*" else _allowed_origins.split(","),
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

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


async def _require_code_owns_session(code: str, session_id: str) -> None:
    try:
        code_row = await codes_store.fetch_by_code(code)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if code_row is None or code_row.get("session_id") != session_id:
        raise HTTPException(status_code=403, detail="that code does not match this interview session")


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

    try:
        code_row = await interview_codes.generate(
            candidate_id, organization_id, role["title"],
            required_skills=role.get("required_skills") or [],
            difficulty="standard", available_minutes=20,
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
async def list_code_emails(code_id: str) -> dict:
    """The HR desktop's Email Status section: one row per email type
    (invitation, reminder_1h, reminder_30m) that has been attempted for this
    code, each with its status, attempt count, and last error."""
    try:
        return {"emails": await email_store.list_for_code(code_id)}
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/interview-codes/resend-invitation")
async def resend_invitation(req: ResendInvitationRequest) -> dict:
    """The HR desktop's "Resend invitation" button."""
    try:
        code_row = await codes_store.fetch_by_id(req.code_id)
        if code_row is None:
            raise HTTPException(status_code=404, detail="no such interview code")
        candidate = await supabase_store.fetch_candidate(code_row["candidate_id"])
        if candidate is None or not candidate.get("email"):
            raise HTTPException(status_code=409, detail="candidate has no email on file")
        return await email_workflow.resend_invitation(code_row, candidate)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/email/send-due-reminders")
async def send_due_reminders() -> dict:
    """The scheduler's entrypoint (Ticket 21's parallel of Ticket 12's
    `reminder-scheduler`) — call on a timer (cron, an external scheduler, or
    a manual poke) to send whatever 1-hour/30-minute reminder is currently
    due across every active interview code."""
    try:
        return await email_workflow.send_due_reminders(supabase_store.fetch_candidate)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/interview/start")
async def interview_start(req: InterviewStartRequest) -> dict:
    """Redeem a code and either resume its in-progress session or open a new
    one. The candidate portal never sends an id it wasn't handed by a human
    — only the code."""
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


@app.post("/interview/answer")
async def interview_answer(req: InterviewAnswerRequest) -> dict:
    """Record the candidate's answer to the current question and return the
    next turn — a follow-up, the next topic's question, or completion."""
    await _require_code_owns_session(req.code, req.session_id)
    try:
        return await interview_session.answer(req.session_id, req.answer_text)
    except interview_session.SessionError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


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


@app.post("/interview/finish")
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


@app.get(
    "/roles/open",
    dependencies=[Depends(rate_limit.limit("roles-open", 30))],
)
async def roles_open() -> dict:
    """Public: lets a candidate with no link yet browse open roles and pick
    one to apply to. Same minimal shape as apply-info — title and org name,
    never required_skills or notes — since this is reachable by anyone."""
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
    organization_name: str
    name: str | None = None
    email: str
    password: str


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
    organization_id = (user.get("user_metadata") or {}).get("organization_id")
    if not organization_id:
        raise HTTPException(status_code=403, detail="account has no organization")
    return organization_id


@app.post("/auth/signup")
async def auth_signup(req: SignupRequest) -> dict:
    """Creates the organization (first signup for that name) or joins an
    existing one, then creates the HR user and signs them in immediately —
    the portal never issues a "check your email" step because GoTrue's own
    email flows aren't wired here yet."""
    try:
        org = await demo_store.find_organization_by_name(req.organization_name)
        if org is None:
            org = await demo_store.create_organization(req.organization_name)
        await demo_store.find_or_create_hr_user(
            req.email, req.password, org["id"], name=req.name,
        )
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


@app.post("/auth/login")
async def auth_login(req: LoginRequest) -> dict:
    try:
        token = await demo_store.sign_in(req.email, req.password)
    except supabase_store.SupabaseError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    organization_id = (token.get("user", {}).get("user_metadata") or {}).get("organization_id")
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


@app.post("/face/analyze", response_model=FrameAnalysis)
async def analyze_frame(file: UploadFile = File(...)) -> FrameAnalysis:
    raw = await file.read()

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
