"""Public candidate self-registration, submitted directly from the portal's
own apply page — no Google Form, no Apps Script webhook in the middle.

Two ways in:
- `/apply/{role_id}` (legacy — role-keyed, no intake attached; kept working
  for any link already handed out before intakes existed).
- `/intakes/{intake_id}/apply` (current — intake-keyed, so a role running
  two campaigns at once, e.g. an August and an October cycle, never mixes
  their candidates). Prefer this path going forward.

Either way, the id in the URL is the only thing that identifies which
organization/role/intake the application is for — there is nothing else in
the request for a caller to spoof into a different org.

Runs the same pipeline a code-generated-by-HR candidate goes through:
create the candidate row, upload the resume, run it through
`profile_builder` so the interview is grounded in what they actually
submitted, then mint and email an interview code — reusing
`interview_codes.generate` + `notifications.workflow.send_invitation_for_code`
so nothing here duplicates that logic.

## What this route may not do

This is the ONE candidate-facing route with no login and no invitation
token — the id in the URL is the only thing identifying the org/role/intake,
and email is self-reported. That combination used to let a caller submit an
application under an email that already had a real candidate record, and the
handler would silently overwrite that person's resume, extracted text and AI
profile, mint a NEW interview code bound to their candidate_id, and hand that
code back in the HTTP response — to the caller, not to the victim.

The interview code is never returned here now, for anyone, new candidate or
existing. Email is the only delivery channel for a code; a value in an HTTP
response is not. And a submission that matches an existing candidate record
never touches that candidate: no resume overwrite, no profile re-run, no new
code. It resends whatever invitation is already on file, to the address
already on file, and returns the identical shape a first-time application
gets — so the response itself cannot be used to probe whether an email is
already a candidate.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime, timedelta

from notifications import workflow as email_workflow
from pipeline import demo_store, profile_builder
from session import codes_store, interview_codes


class SelfRegistrationError(RuntimeError):
    """A problem with the submitted data itself (bad role/intake link, bad
    resume encoding) — the caller maps this to a 400/404, not a 503."""


# A resume is a document, not a video. 15MB covers a genuinely long,
# image-heavy CV with room to spare, while still bounding the OCR fallback's
# cost (deterministic/pdf_extraction.py renders every page at 200dpi) against
# an oversized upload to a route nothing else in this stack rate-limits by
# body size.
_MAX_RESUME_BYTES = 15 * 1024 * 1024

# The first 5 bytes of every PDF, regardless of version. Checked before the
# bytes are handed to Storage or `pypdf` — this route accepts whatever a
# stranger's browser sends as "resume_base64", and a magic-byte check is the
# cheapest thing that refuses a renamed non-PDF before it reaches a parser.
_PDF_MAGIC = b"%PDF-"


def _decode_resume(resume_base64: str) -> bytes:
    try:
        resume_bytes = base64.b64decode(resume_base64, validate=True)
    except binascii.Error as exc:
        raise SelfRegistrationError(f"resume is not valid base64: {exc}") from exc
    if len(resume_bytes) > _MAX_RESUME_BYTES:
        raise SelfRegistrationError("resume is larger than the 15MB limit")
    if not resume_bytes.startswith(_PDF_MAGIC):
        raise SelfRegistrationError("resume does not look like a PDF")
    return resume_bytes


async def _resend_for_existing_candidate(candidate: dict) -> None:
    """An application matching a candidate we already have. Never touches
    their resume, profile, or mints a new code — only resends whatever
    invitation already exists for whatever live code they already hold.
    Silently does nothing if neither exists yet (e.g. their first
    application is still mid-pipeline): there is nothing safe to resend, and
    this path must never create one, only resend one."""
    existing_code = await codes_store.find_live_code_for_candidate(candidate["id"])
    if existing_code is None or not candidate.get("email"):
        return
    try:
        await email_workflow.resend_invitation(existing_code, candidate)
    except Exception:  # noqa: BLE001 — same fail-open rule as the new-candidate
        # path below: a delivery failure here must not turn into a different,
        # more informative response than the happy path gets.
        pass


async def register_candidate(
    *,
    role_id: str | None = None,
    intake_id: str | None = None,
    name: str,
    email: str,
    resume_base64: str,
    preferred_time: datetime | None,
) -> dict:
    """Exactly one of role_id/intake_id is expected — intake_id is the
    intake-aware path (also resolves role_id from it); role_id alone is the
    legacy path and leaves the candidate's intake_id unset, same as every
    candidate created before intakes existed."""
    intake = None
    if intake_id is not None:
        intake = await demo_store.fetch_intake(intake_id)
        if intake is None or intake["status"] != "active":
            raise SelfRegistrationError("that application link is no longer valid")
        role_id = intake["role_id"]

    role = await demo_store.fetch_role(role_id)
    if role is None:
        raise SelfRegistrationError("that application link is no longer valid")
    organization_id = role["organization_id"]

    # Decoded and size/type-checked before anything is looked up — a bad
    # upload should fail the same way regardless of whether the email
    # happens to match an existing candidate.
    resume_bytes = _decode_resume(resume_base64)

    existing = await demo_store.find_candidate_by_email(organization_id, email)
    if existing is not None:
        await _resend_for_existing_candidate(existing)
        return {
            "organization_id": organization_id,
            "role_title": role["title"],
            "intake_id": intake["id"] if intake is not None else None,
            "status": "application_received",
        }

    fields = {"organization_id": organization_id, "name": name, "email": email, "role_id": role_id}
    if intake is not None:
        fields["intake_id"] = intake["id"]
    candidate = await demo_store.create_candidate(fields)
    candidate_id = candidate["id"]

    resume_path = f"{organization_id}/{candidate_id}-resume.pdf"
    await demo_store.upload_resume_object(resume_path, resume_bytes)
    await demo_store.update_candidate(candidate_id, {"resume_path": resume_path})

    # The AI's view of this candidate comes entirely from here — same call
    # an HR-added candidate's resume goes through, no shortcut for
    # self-submitted ones.
    await profile_builder.process_candidate_resume(candidate_id)

    code_row = await interview_codes.generate(
        candidate_id, organization_id, role["title"],
        required_skills=role.get("required_skills") or [],
        difficulty="standard", available_minutes=20,
        window_start=preferred_time,
        window_end=preferred_time + timedelta(hours=1) if preferred_time else None,
    )

    try:
        await email_workflow.send_invitation_for_code(code_row, candidate)
    except Exception:  # noqa: BLE001 — mirrors /interview-codes/generate: a
        # failed email must never fail registration, the code is still real.
        pass

    # No `code` field. Ever. Email is the only delivery channel for it — a
    # value in this response is available to whoever made the HTTP request,
    # which is not necessarily the person whose email address was given.
    return {
        "organization_id": organization_id,
        "role_title": role["title"],
        "intake_id": intake["id"] if intake is not None else None,
        "status": "application_received",
    }
