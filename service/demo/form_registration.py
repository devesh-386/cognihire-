"""Public candidate registration from an external form (Google Forms via an
Apps Script webhook, or any client that can POST this shape).

Replaces HR manually creating a candidate and generating a code by hand: a
candidate fills out the public form, this route creates the candidate, feeds
their resume through the real pipeline (`profile_builder`) so the interview
is driven by what they actually submitted, generates a code for their
preferred time, and emails it to them — reusing the exact same code
generation + invitation-email path `/interview-codes/generate` already uses,
so nothing here duplicates that logic.

Protected by a shared secret (`FORM_WEBHOOK_SECRET`) rather than a login,
since the caller is a script, not a person.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime

from notifications import workflow as email_workflow
from pipeline import demo_store, profile_builder
from session import interview_codes


class FormRegistrationError(RuntimeError):
    """A problem with the submitted data itself (bad resume encoding, etc.),
    as opposed to a Supabase/config failure — the caller maps this to a 400
    rather than a 503."""


async def register_candidate(
    *,
    organization_name: str,
    name: str,
    email: str,
    role_title: str,
    resume_base64: str,
    preferred_time: datetime | None,
) -> dict:
    try:
        resume_bytes = base64.b64decode(resume_base64, validate=True)
    except binascii.Error as exc:
        raise FormRegistrationError(f"resume is not valid base64: {exc}") from exc

    org = await demo_store.find_organization_by_name(organization_name)
    if org is None:
        org = await demo_store.create_organization(organization_name)
    org_id = org["id"]

    role = await demo_store.find_role(org_id, role_title)
    if role is None:
        role = await demo_store.create_role({
            "organization_id": org_id, "title": role_title,
            "required_skills": [], "desirable_skills": [], "notes": "",
        })

    candidate = await demo_store.find_candidate_by_email(org_id, email)
    if candidate is None:
        candidate = await demo_store.create_candidate({
            "organization_id": org_id, "name": name, "email": email,
        })
    candidate_id = candidate["id"]

    resume_path = f"{org_id}/{candidate_id}-resume.pdf"
    await demo_store.upload_resume_object(resume_path, resume_bytes)
    await demo_store.update_candidate(candidate_id, {"resume_path": resume_path})

    # The AI's view of this candidate comes entirely from here — same call
    # the seeded demo data goes through, no shortcut for real submissions.
    profile_result = await profile_builder.process_candidate_resume(candidate_id)

    code_row = await interview_codes.generate(
        candidate_id, org_id, role_title,
        required_skills=role.get("required_skills") or [],
        difficulty="standard", available_minutes=20,
        window_start=preferred_time,
    )

    try:
        await email_workflow.send_invitation_for_code(code_row, candidate)
    except Exception:  # noqa: BLE001 — mirrors /interview-codes/generate: a
        # failed email must never fail registration, the code is still real.
        pass

    return {
        "organization_id": org_id,
        "candidate_id": candidate_id,
        "role_title": role_title,
        "profile_status": profile_result.get("status"),
        "code": code_row["code"],
    }
