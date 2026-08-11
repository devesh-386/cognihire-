"""Multi-tenant proof for the demo environment (Part 28 of the intake work).

`demo/seed.py` seeds exactly one organization ("CogniHire Demo Co") and its
tests/routes assume that single-org shape, so this is a separate, additive
module rather than a rewrite of it — nothing here touches `seed.py`,
`DEMO_ORG_NAME`, or their existing tests.

What this proves, with real rows, not by inspection:
- Two organizations both run a "Backend Engineer" role with no collision
  (each role_id -> exactly one organization_id, enforced by the FK).
- One role runs two separate intakes ("August 2026" / "October 2026") whose
  candidates never mix (each candidate.intake_id -> exactly one intake).
- Candidates in different organizations, and different intakes within the
  same organization, are the isolation boundaries a recruiter's view must
  respect — see infra/migrations/0008_intakes.sql's RLS policies, which this
  seed data gives something real to test against instead of a hypothetical.

Idempotent by name/email, same as `demo/seed.py`.
"""

from __future__ import annotations

from pipeline import demo_store, profile_builder

from .pdf import text_to_pdf

_ORGS = [
    {
        "name": "Innotech Solutions",
        "roles": [
            {
                "title": "Backend Engineer",
                "required_skills": ["Go", "PostgreSQL", "Kubernetes"],
                "desirable_skills": ["gRPC"],
                "notes": "Multi-tenant demo — Innotech's own Backend Engineer role, "
                         "distinct from CogniHire Demo Co's role of the same title.",
            },
        ],
        "candidates": [
            {
                "name": "Marcus Webb", "email": "marcus.webb@innotech.demo.cognihire.test",
                "role_title": "Backend Engineer", "intake_name": "August 2026 Intake",
                "resume_text": "Skills\nGo, PostgreSQL, Docker\n\nExperience\nBackend "
                                "engineer building payment services in Go for three years.\n\n"
                                "Education\nBSc Computer Science.",
            },
            {
                "name": "Elena Rossi", "email": "elena.rossi@innotech.demo.cognihire.test",
                "role_title": "Backend Engineer", "intake_name": "October 2026 Intake",
                "resume_text": "Skills\nGo, Kubernetes, gRPC\n\nExperience\nPlatform "
                                "engineer, migrated a monolith to gRPC microservices.\n\n"
                                "Education\nMSc Distributed Systems.",
            },
        ],
    },
    {
        "name": "Vertex Systems",
        "roles": [
            {
                "title": "Backend Engineer",
                "required_skills": ["Java", "PostgreSQL", "AWS"],
                "desirable_skills": ["Kafka"],
                "notes": "Multi-tenant demo — Vertex's own Backend Engineer role, same "
                         "title as Innotech's and CogniHire Demo Co's, different org.",
            },
        ],
        "candidates": [
            {
                "name": "Priya Nair", "email": "priya.nair@vertex.demo.cognihire.test",
                "role_title": "Backend Engineer", "intake_name": "August 2026 Intake",
                "resume_text": "Skills\nJava, AWS, Kafka\n\nExperience\nBuilt event-driven "
                                "billing pipelines on Kafka for a fintech.\n\n"
                                "Education\nBSc Software Engineering.",
            },
        ],
    },
]


async def seed_multi_tenant_demo() -> dict:
    orgs_out = []
    for org_def in _ORGS:
        org = await demo_store.find_organization_by_name(org_def["name"])
        if org is None:
            org = await demo_store.create_organization(org_def["name"])
        org_id = org["id"]

        roles_by_title: dict[str, dict] = {}
        for role_def in org_def["roles"]:
            role = await demo_store.find_role(org_id, role_def["title"])
            if role is None:
                role = await demo_store.create_role({**role_def, "organization_id": org_id})
            roles_by_title[role_def["title"]] = role

        intakes_by_key: dict[tuple[str, str], dict] = {}
        for role in roles_by_title.values():
            existing = await demo_store.list_intakes(org_id, role_id=role["id"])
            for intake in existing:
                intakes_by_key[(role["title"], intake["name"])] = intake

        candidates_out = []
        for c in org_def["candidates"]:
            role = roles_by_title[c["role_title"]]
            key = (c["role_title"], c["intake_name"])
            intake = intakes_by_key.get(key)
            if intake is None:
                intake = await demo_store.create_intake({
                    "organization_id": org_id, "role_id": role["id"], "name": c["intake_name"],
                    "status": "active",
                })
                intakes_by_key[key] = intake

            candidate = await demo_store.find_candidate_by_email(org_id, c["email"])
            if candidate is None:
                candidate = await demo_store.create_candidate({
                    "organization_id": org_id, "name": c["name"], "email": c["email"],
                    "role_id": role["id"], "intake_id": intake["id"],
                })
            candidate_id = candidate["id"]

            resume_path = f"{org_id}/{candidate_id}-resume.pdf"
            await demo_store.upload_resume_object(resume_path, text_to_pdf(c["resume_text"]))
            await demo_store.update_candidate(candidate_id, {"resume_path": resume_path})

            pipeline_result = await profile_builder.process_candidate_resume(candidate_id)

            candidates_out.append({
                "candidate_id": candidate_id, "name": c["name"], "email": c["email"],
                "role_title": role["title"], "intake_id": intake["id"],
                "intake_name": intake["name"], "profile_status": pipeline_result["status"],
            })

        orgs_out.append({
            "organization_id": org_id,
            "organization_name": org_def["name"],
            "roles": [{"id": r["id"], "title": r["title"]} for r in roles_by_title.values()],
            "intakes": [{"id": i["id"], "name": i["name"], "role_title": rt}
                        for (rt, _name), i in intakes_by_key.items()],
            "candidates": candidates_out,
        })

    return {"organizations": orgs_out}
