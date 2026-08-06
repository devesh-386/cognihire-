"""The Candidate Knowledge Profile — the canonical representation of a person.

Every downstream AI stage (question planning, the interview, evidence linking,
reporting) reads this object. **None of them reads the resume text.** That is
the point: the profile is the single source of truth, so improving how a
candidate is understood is one stage's job rather than a change rippling
through every consumer.

## Grounded facts vs. inferences — the distinction this file exists to keep

A profile mixes two categories that must never be confused:

**Grounded facts** (`skills`, `projects`, `experience`, `education`,
`certifications`, `technologies`, and `identity`) are text the candidate
actually wrote. Each has passed `deterministic/grounding.py` and appears
verbatim in the source document. These are *the candidate's claims*.

**Inferences** (`domains`, `strengths`, `estimated_focus`) are conclusions a
model drew. "Backend" is not a phrase in most resumes; it is a reading of one.
These can never pass the grounding gate, because they are not quotations — so
rather than smuggle them in beside the facts, they are a distinct type
([Inference]) that **must cite the grounded values it was derived from**.

An inference with no surviving basis is discarded. That rule is what stops the
profile from becoming a place where a model's opinion quietly acquires the
authority of something the candidate said. A reviewer looking at "estimated
focus: Machine Learning" can always ask *from what?* and get an answer made of
the person's own words.

This is the same principle as the claim grounding gate, applied to a category
of output that gating alone cannot handle.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass
class Identity:
    """Who the profile is about. Every field is grounded or None.

    `name` is a guess even when grounded — it is the text that looked like a
    name, not verified identity. Identity verification is the face service's
    job, and nothing here should be treated as establishing who a person is.
    """

    name: str | None = None
    email: str | None = None
    degree: str | None = None
    university: str | None = None


@dataclass
class Inference:
    """A conclusion a model drew, and the candidate's own words behind it.

    `basis` is non-empty by construction — see [CandidateKnowledgeProfile] and
    `resume_understanding`. An inference that cannot name its evidence is not
    recorded, because an unsupported conclusion presented next to grounded
    facts reads as one of them.
    """

    value: str
    basis: list[str] = field(default_factory=list)

    @property
    def is_supported(self) -> bool:
        return bool(self.basis)


@dataclass
class CandidateKnowledgeProfile:
    """The canonical candidate object. Read by every downstream AI stage."""

    identity: Identity = field(default_factory=Identity)

    # --- Grounded: verbatim from the source document --------------------
    skills: list[str] = field(default_factory=list)
    technologies: list[str] = field(default_factory=list)
    projects: list[str] = field(default_factory=list)
    experience: list[str] = field(default_factory=list)
    education: list[str] = field(default_factory=list)
    certifications: list[str] = field(default_factory=list)

    # --- Inferred: a model's reading, each citing grounded evidence -----
    domains: list[Inference] = field(default_factory=list)
    strengths: list[Inference] = field(default_factory=list)
    estimated_focus: list[Inference] = field(default_factory=list)

    # --- Provenance ------------------------------------------------------
    # Which mechanism produced this: "hosted_llm" | "local_llm" |
    # "heuristic_rule". The effective one, never the requested one.
    kind: str = "heuristic_rule"
    degraded_reason: str | None = None

    # Values the model produced that the grounding gate refused, and
    # inferences dropped for having no surviving basis. Kept visible: a model
    # inventing content is a reportable event, not a silent no-op.
    rejected_ungrounded: list[str] = field(default_factory=list)
    rejected_unsupported_inferences: list[str] = field(default_factory=list)

    @property
    def grounded_facts(self) -> list[str]:
        """Every verbatim value in the profile.

        This is what an inference's `basis` must draw from, and what question
        planning treats as established rather than concluded.
        """
        return [
            *self.skills,
            *self.technologies,
            *self.projects,
            *self.experience,
            *self.education,
            *self.certifications,
        ]

    @property
    def is_degraded(self) -> bool:
        return self.degraded_reason is not None

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, raw: dict) -> "CandidateKnowledgeProfile":
        """Rebuild from stored JSON. Tolerant of missing keys: a profile
        written by an older pipeline version must still load rather than
        crash an interview that is about to start."""

        def inferences(key: str) -> list[Inference]:
            items = raw.get(key) or []
            out = []
            for item in items:
                if isinstance(item, dict) and item.get("value"):
                    out.append(
                        Inference(
                            value=item["value"],
                            basis=[b for b in (item.get("basis") or []) if isinstance(b, str)],
                        )
                    )
            return out

        def strings(key: str) -> list[str]:
            items = raw.get(key) or []
            return [i for i in items if isinstance(i, str)]

        identity_raw = raw.get("identity") or {}
        return cls(
            identity=Identity(
                name=identity_raw.get("name"),
                email=identity_raw.get("email"),
                degree=identity_raw.get("degree"),
                university=identity_raw.get("university"),
            ),
            skills=strings("skills"),
            technologies=strings("technologies"),
            projects=strings("projects"),
            experience=strings("experience"),
            education=strings("education"),
            certifications=strings("certifications"),
            domains=inferences("domains"),
            strengths=inferences("strengths"),
            estimated_focus=inferences("estimated_focus"),
            kind=raw.get("kind", "heuristic_rule"),
            degraded_reason=raw.get("degraded_reason"),
            rejected_ungrounded=strings("rejected_ungrounded"),
            rejected_unsupported_inferences=strings("rejected_unsupported_inferences"),
        )
