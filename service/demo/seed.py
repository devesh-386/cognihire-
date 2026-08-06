"""Ticket 19 — Demo Environment.

One click creates everything a demo needs: one organization, an HR login,
three roles, and five candidates spanning different resume qualities, each
run through the real, unmodified resume pipeline (`profile_builder`) so
every downstream AI stage sees genuine — if synthetic — data. This module
adds no AI stage and changes no pipeline behavior; it only calls what
Tickets 1-14 already built, the same way the candidate portal or HR desktop
would.

Idempotent by design: re-running finds the existing org/roles/candidates by
name/email instead of duplicating them, so "seed" is safe to call repeatedly
(e.g. after `/demo/reset`, or if a demo run is interrupted).
"""

from __future__ import annotations

from pipeline import demo_store, profile_builder
from session import interview_codes

from .pdf import text_to_pdf
from .seed_data import DEMO_CANDIDATES, DEMO_ORG_NAME, DEMO_ROLES

DEMO_HR_EMAIL = "hr@demo.cognihire.test"
DEMO_HR_PASSWORD = "CogniHireDemo!2026"


async def seed_demo_environment() -> dict:
    org = await demo_store.find_organization_by_name(DEMO_ORG_NAME)
    if org is None:
        org = await demo_store.create_organization(DEMO_ORG_NAME)
    org_id = org["id"]

    hr_user = await demo_store.find_or_create_hr_user(DEMO_HR_EMAIL, DEMO_HR_PASSWORD, org_id)

    roles_by_title: dict[str, dict] = {}
    for role_def in DEMO_ROLES:
        role = await demo_store.find_role(org_id, role_def["title"])
        if role is None:
            role = await demo_store.create_role({**role_def, "organization_id": org_id})
        roles_by_title[role_def["title"]] = role

    candidates_out = []
    for c in DEMO_CANDIDATES:
        candidate = await demo_store.find_candidate_by_email(org_id, c["email"])
        if candidate is None:
            candidate = await demo_store.create_candidate({
                "organization_id": org_id, "name": c["name"], "email": c["email"],
            })
        candidate_id = candidate["id"]

        resume_path = f"{org_id}/{candidate_id}-resume.pdf"
        await demo_store.upload_resume_object(resume_path, text_to_pdf(c["resume_text"]))
        await demo_store.update_candidate(candidate_id, {"resume_path": resume_path})

        # Real pipeline call, not a shortcut — this is what makes the seeded
        # data trustworthy as a demo: it went through the same code path a
        # real candidate's resume does.
        pipeline_result = await profile_builder.process_candidate_resume(candidate_id)

        role = roles_by_title[c["role_title"]]
        code_row = await interview_codes.generate(
            candidate_id, org_id, role["title"],
            required_skills=role.get("required_skills") or [],
            difficulty="standard", available_minutes=20,
        )

        candidates_out.append({
            "candidate_id": candidate_id,
            "name": c["name"],
            "email": c["email"],
            "role_title": role["title"],
            "profile_status": pipeline_result["status"],
            "interview_code": code_row["code"],
        })

    return {
        "organization_id": org_id,
        "organization_name": DEMO_ORG_NAME,
        "hr_login": {"email": DEMO_HR_EMAIL, "password": DEMO_HR_PASSWORD, "user_id": hr_user.get("id")},
        "roles": [{"id": r["id"], "title": r["title"]} for r in roles_by_title.values()],
        "candidates": candidates_out,
    }
