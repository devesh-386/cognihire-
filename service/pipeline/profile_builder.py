"""Orchestration — sequences the stages and records how far the pipeline got.

```
PDF                                    (deterministic)
 ↓  deterministic/pdf_extraction
Resume text                            → TEXT_EXTRACTED
 ↓  ai/resume_understanding  [AI]      + grounding gate
CANDIDATE KNOWLEDGE PROFILE            → STRUCTURED
 ↓  ai/claim_extraction      [AI]      + grounding gate
Grounded claims                        → CLAIMS_READY
 ↓
Profile ready for interview            → READY_FOR_INTERVIEW
```

The Candidate Knowledge Profile is the canonical object; the stages after
this pipeline (question planning, interview, evidence linking, reporting)
read it rather than anything produced here directly.

Everything above the first `[AI]` marker is deterministic; everything below it
is a model's output that has passed a deterministic gate. That boundary is the
architecture's central claim, and it is why the packages are named the way they
are.

Deliberately does NOT build an interview context. Context depends on the
selected role, duration, difficulty, and prompt version — all of which change
after a resume is processed — so it is assembled fresh at interview start from
this profile plus live HR configuration. Persisting it here would guarantee
serving a stale one.
"""

from __future__ import annotations

import logging

from ai import claim_extraction, resume_understanding
from deterministic import pdf_extraction

from . import supabase_store

logger = logging.getLogger("cognihire.pipeline")


async def process_candidate_resume(candidate_id: str) -> dict:
    """Run the full pipeline for one candidate.

    Raises only `SupabaseError` — if the database is unreachable we cannot
    record a failure, so reporting a handled outcome would lose the work
    silently. Every other failure is recorded as FAILED on the profile.
    """
    candidate = await supabase_store.fetch_candidate(candidate_id)
    if candidate is None:
        raise supabase_store.SupabaseError(f"no candidate with id {candidate_id}")

    org_id = candidate["organization_id"]
    resume_path = candidate.get("resume_path")

    async def fail(reason: str) -> dict:
        await supabase_store.upsert_profile(
            candidate_id, org_id, {"processing_status": "FAILED", "error": reason}
        )
        logger.warning("resume pipeline failed for %s: %s", candidate_id, reason)
        return {"candidate_id": candidate_id, "status": "FAILED", "error": reason}

    if not resume_path:
        return await fail("the candidate has no uploaded resume")

    # --- Deterministic: PDF → text --------------------------------------
    try:
        pdf_bytes = await supabase_store.download_resume(resume_path)
    except supabase_store.SupabaseError as exc:
        return await fail(str(exc))

    extraction = pdf_extraction.extract_text(pdf_bytes)
    if not extraction.ok:
        return await fail(extraction.error or "text extraction failed")

    await supabase_store.upsert_profile(
        candidate_id,
        org_id,
        {
            "processing_status": "TEXT_EXTRACTED",
            "resume_text": extraction.text,
            "error": None,
        },
    )

    # --- AI: text → Candidate Knowledge Profile (grounded) --------------
    #
    # This is the last stage that sees raw resume text. Everything after it —
    # claim extraction aside, which needs the source to gate against — reads
    # the profile.
    profile = await resume_understanding.understand(extraction.text)

    await supabase_store.upsert_profile(
        candidate_id,
        org_id,
        {
            "processing_status": "STRUCTURED",
            "knowledge_profile": profile.to_dict(),
            "skills": profile.skills,
            "projects": profile.projects,
            "experience": profile.experience,
            "understanding_kind": profile.kind,
            "understanding_degraded_reason": profile.degraded_reason,
        },
    )

    # --- AI: text → claims (grounded) -----------------------------------
    #
    # From the RAW text, not the structured profile: the gate checks each
    # claim appears verbatim in the source, and checking against a reshaped
    # intermediate would weaken the guarantee it provides.
    claims = await claim_extraction.extract_claims(extraction.text, source="resume")

    await supabase_store.upsert_profile(
        candidate_id,
        org_id,
        {
            "processing_status": "CLAIMS_READY",
            "claims": [
                {"id": c.id, "text": c.text, "source": c.source, "skill": c.skill}
                for c in claims.claims
            ],
            "claim_extraction_kind": claims.kind,
            "degraded_reason": claims.degraded_reason,
            "claims_truncated": claims.claims_truncated,
        },
    )

    # --- Done ------------------------------------------------------------
    #
    # A degraded stage still reaches READY_FOR_INTERVIEW. The output is weaker
    # (text rules, not a model) but it is real, and the profile records which
    # mechanism produced it — blocking the interview would punish the
    # candidate for our provider being down.
    #
    # Nothing verified to ask about is different, and is not ready. This is
    # the same condition `question_planning.plan` refuses on, checked here so
    # it fails where a human can see it: READY_FOR_INTERVIEW is what triggers
    # the auto-invite, so marking this candidate ready would email them a code
    # for an interview whose plan has no topics — which opens, immediately
    # completes, and produces a report reading "complete" with nothing asked.
    # FAILED puts them in the HR dashboard's "Needs attention" list instead,
    # which is exactly where a resume we could not read anything out of
    # belongs.
    if not claims.claims and not profile.grounded_facts:
        return await fail(
            "no grounded claims or facts could be extracted from this resume — "
            "there is nothing verified to build an interview from"
        )

    await supabase_store.upsert_profile(
        candidate_id, org_id, {"processing_status": "READY_FOR_INTERVIEW"}
    )

    return {
        "candidate_id": candidate_id,
        "status": "READY_FOR_INTERVIEW",
        "understanding_kind": profile.kind,
        "understanding_rejected_ungrounded": len(profile.rejected_ungrounded),
        "unsupported_inferences": len(profile.rejected_unsupported_inferences),
        "claim_count": len(claims.claims),
        "claim_extraction_kind": claims.kind,
        "degraded_reason": claims.degraded_reason,
        "rejected_ungrounded": len(claims.rejected_ungrounded),
    }
