"""Public candidate self-registration, submitted directly from the portal's
own apply page — no Google Form, no Apps Script webhook in the middle.

A candidate reaches this by following a role's public apply link
(`/apply/{role_id}`), which is generated and copied by HR from the Roles
page. `role_id` is the only thing that identifies which organization and
role the application is for; there is nothing else in the request for a
caller to spoof into a different org.

Runs the same pipeline a code-generated-by-HR candidate goes through:
create the candidate row, upload the resume, run it through
`profile_builder` so the interview is grounded in what they actually
submitted, then mint and email an interview code — reusing
`interview_codes.generate` + `notifications.workflow.send_invitation_for_code`
so nothing here duplicates that logic.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime

from notifications import workflow as email_workflow
from pipeline import demo_store, profile_builder
from session import interview_codes


class SelfRegistrationError(RuntimeError):
    """A problem with the submitted data itself (bad role link, bad resume
    encoding) — the caller maps this to a 400/404, not a 503."""


async def register_candidate(
    *,
    role_id: str,
    name: str,
    email: str,
    resume_base64: str,
    preferred_time: datetime | None,
) -> dict:
    role = await demo_store.fetch_role(role_id)
    if role is None:
        raise SelfRegistrationError("that application link is no longer valid")
    organization_id = role["organization_id"]

    try:
        resume_bytes = base64.b64decode(resume_base64, validate=True)
    except binascii.Error as exc:
        raise SelfRegistrationError(f"resume is not valid base64: {exc}") from exc

    candidate = await demo_store.find_candidate_by_email(organization_id, email)
    if candidate is None:
        candidate = await demo_store.create_candidate({
            "organization_id": organization_id, "name": name, "email": email,
        })
    candidate_id = candidate["id"]

    resume_path = f"{organization_id}/{candidate_id}-resume.pdf"
    await demo_store.upload_resume_object(resume_path, resume_bytes)
    await demo_store.update_candidate(candidate_id, {"resume_path": resume_path})

    # The AI's view of this candidate comes entirely from here — same call
    # an HR-added candidate's resume goes through, no shortcut for
    # self-submitted ones.
    profile_result = await profile_builder.process_candidate_resume(candidate_id)

    code_row = await interview_codes.generate(
        candidate_id, organization_id, role["title"],
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
        "organization_id": organization_id,
        "candidate_id": candidate_id,
        "role_title": role["title"],
        "profile_status": profile_result.get("status"),
        "code": code_row["code"],
    }
