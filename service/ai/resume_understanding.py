"""AI stage — resume understanding.

Builds the [CandidateKnowledgeProfile]: the canonical object every later stage
reads. This is the first stage where a model decides anything, and the last
stage that ever sees raw resume text — question planning, the interview,
evidence linking, and reporting all read the profile instead.

## Why this is an AI stage and not a parser

A regex knows that "Skills" is a heading. It does not know that "shipped a
Flutter app to the Play Store" is evidence of release engineering, or that a
cluster of projects points at a backend focus. That understanding is the
product, so it belongs to a model.

`deterministic/resume_parser.py` still runs — as the **fallback** when the
provider is unreachable, not as the primary path. `profile.kind` records which
one produced the result so nothing downstream has to guess.

## Two different verification rules, for two different kinds of output

**Grounded facts** (skills, projects, experience, …) go through
`deterministic/grounding.py`: present verbatim in the source, or discarded. A
model will otherwise upgrade "familiar with Python" to "Python expert", or
list a technology that merely co-occurs with one the resume named.

**Inferences** (domains, strengths, estimated focus) cannot be gated that way —
"Backend" is a reading of a resume, not a quotation from one. So each must
cite grounded values as its `basis`, every cited value is itself checked, and
an inference whose basis does not survive is dropped. A conclusion is allowed;
an unsupported conclusion sitting beside verified facts is not.

The model decides *what matters*. It never decides *what the document says*.
"""

from __future__ import annotations

import logging

from deterministic import grounding, resume_parser

from . import provider
from .knowledge_profile import CandidateKnowledgeProfile, Identity, Inference

logger = logging.getLogger("cognihire.ai.resume_understanding")

_INSTRUCTION = """\
You read a person's resume and build a structured profile of them.

Your output has two different kinds of field, with different rules.

QUOTED FIELDS — identity, skills, technologies, projects, experience,
education, certifications.
Every value must appear VERBATIM in the resume text. Copy it exactly. Do not
reword, normalise capitalisation, expand abbreviations, infer a related
technology, or upgrade a qualifier ("familiar with X" is not "expert in X").
Do not add a skill because it commonly accompanies one that is present. If the
document does not name it, it does not exist.

INFERRED FIELDS — domains, strengths, estimated_focus.
These are your reading of the resume and need not be quotations. But each one
must list, in "basis", the VERBATIM resume lines that led you to it. An
inference you cannot support with quoted evidence must be omitted entirely.

Omit anything you are unsure about. A shorter accurate profile is better than
a longer one containing an invention.

Reply with JSON only, in this exact shape:
{
  "identity": {
    "name": "<verbatim, or null>",
    "degree": "<verbatim, or null>",
    "university": "<verbatim, or null>"
  },
  "skills": ["<verbatim>"],
  "technologies": ["<verbatim>"],
  "projects": ["<verbatim project line>"],
  "experience": ["<verbatim experience line>"],
  "education": ["<verbatim education line>"],
  "certifications": ["<verbatim certification line>"],
  "domains": [{"value": "<your inference>", "basis": ["<verbatim line>"]}],
  "strengths": [{"value": "<your inference>", "basis": ["<verbatim line>"]}],
  "estimated_focus": [{"value": "<your inference>", "basis": ["<verbatim line>"]}]
}
"""

_QUOTED_FIELDS = (
    "skills",
    "technologies",
    "projects",
    "experience",
    "education",
    "certifications",
)

_INFERRED_FIELDS = ("domains", "strengths", "estimated_focus")


def _fallback(resume_text: str, reason: str | None) -> CandidateKnowledgeProfile:
    """Deterministic parsing — grounded fields only.

    The fallback produces NO inferences, and that is deliberate rather than a
    limitation. Inferring a candidate's focus is exactly the judgement a text
    rule cannot make, and emitting a guess here would put an unsupported
    conclusion into the profile under the same field a model's reasoned one
    occupies.
    """
    parsed = resume_parser.parse(resume_text)
    return CandidateKnowledgeProfile(
        identity=Identity(name=parsed.name, email=parsed.email),
        skills=parsed.skills,
        projects=parsed.projects,
        experience=parsed.experience,
        education=parsed.education,
        certifications=parsed.certifications,
        kind="heuristic_rule",
        degraded_reason=reason,
    )


def _grounded_identity_field(value: object, resume_text: str) -> tuple[str | None, str | None]:
    """Returns (kept, rejected) for one identity field."""
    if not isinstance(value, str) or not value.strip():
        return None, None
    cleaned = value.strip()
    if grounding.is_grounded(cleaned, resume_text):
        return cleaned, None
    return None, cleaned


async def understand(
    resume_text: str, provider_override: str | None = None
) -> CandidateKnowledgeProfile:
    """Never raises. An unavailable provider degrades to the deterministic
    parser with the reason recorded."""
    if not resume_text.strip():
        return CandidateKnowledgeProfile(kind="heuristic_rule")

    reply = await provider.chat_json(
        _INSTRUCTION, resume_text, timeout=45, provider=provider_override
    )
    if not reply.ok:
        return _fallback(resume_text, reply.error)

    parsed = provider.parse_json_object(reply.content)
    if parsed is None:
        return _fallback(resume_text, f"the {reply.provider} model returned malformed JSON")

    profile = CandidateKnowledgeProfile(kind=provider.kind_for(reply.provider))
    rejected: list[str] = []

    # --- Quoted fields: verbatim or discarded ---------------------------
    for field_name in _QUOTED_FIELDS:
        raw = parsed.get(field_name)
        values = [v for v in raw if isinstance(v, str)] if isinstance(raw, list) else []
        kept, dropped = grounding.filter_grounded(values, resume_text)
        setattr(profile, field_name, kept)
        rejected.extend(dropped)

    # --- Identity -------------------------------------------------------
    identity_raw = parsed.get("identity")
    identity_raw = identity_raw if isinstance(identity_raw, dict) else {}

    name, name_rejected = _grounded_identity_field(identity_raw.get("name"), resume_text)
    degree, degree_rejected = _grounded_identity_field(identity_raw.get("degree"), resume_text)
    university, uni_rejected = _grounded_identity_field(
        identity_raw.get("university"), resume_text
    )
    rejected.extend(r for r in (name_rejected, degree_rejected, uni_rejected) if r)

    profile.identity = Identity(
        name=name,
        # Email is matched deterministically rather than trusted from the
        # model: one wrong character produces a plausible address that reaches
        # a real stranger, and a regex over the source cannot invent one.
        email=resume_parser.parse(resume_text).email,
        degree=degree,
        university=university,
    )

    # --- Inferred fields: must cite surviving grounded evidence ---------
    unsupported: list[str] = []
    for field_name in _INFERRED_FIELDS:
        raw = parsed.get(field_name)
        items = raw if isinstance(raw, list) else []
        kept_inferences: list[Inference] = []

        for item in items:
            if not isinstance(item, dict):
                continue
            value = item.get("value")
            if not isinstance(value, str) or not value.strip():
                continue

            raw_basis = item.get("basis")
            basis_values = (
                [b for b in raw_basis if isinstance(b, str)] if isinstance(raw_basis, list) else []
            )
            # The cited evidence is itself gated. A model that invents both a
            # conclusion and the quote supporting it must not get credit for
            # having shown its work.
            surviving_basis, dropped_basis = grounding.filter_grounded(
                basis_values, resume_text
            )
            rejected.extend(dropped_basis)

            if surviving_basis:
                kept_inferences.append(
                    Inference(value=value.strip(), basis=surviving_basis)
                )
            else:
                unsupported.append(value.strip())

        setattr(profile, field_name, kept_inferences)

    profile.rejected_ungrounded = rejected
    profile.rejected_unsupported_inferences = unsupported

    if rejected or unsupported:
        logger.info(
            "resume understanding discarded %d ungrounded value(s) and "
            "%d unsupported inference(s)",
            len(rejected),
            len(unsupported),
        )

    return profile
