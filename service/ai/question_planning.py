"""AI stage — question planning.

Decides *what the interview should cover* and in what order, before any
natural language is generated. The interview stage then turns this plan into
conversation.

## Why planning is separate from asking

An interview model left to invent questions on its own produces a session
nobody can reproduce or defend: coverage depends on whatever the model
happened to focus on, two runs of the same candidate differ, and "why was this
asked?" has no answer beyond the transcript. Splitting the decision from the
phrasing makes the interview **inspectable before it happens** — HR can see the
plan, and every question traces to a planned topic which traces to a grounded
claim.

It also makes the two halves independently improvable: a better planner
changes what gets covered without touching conversational quality, and vice
versa.

## What a plan may be built from

The plan is derived from the [CandidateKnowledgeProfile] and the grounded
claims — never from raw resume text, which this stage never sees. Every topic
must reference a claim or a grounded profile fact, so the interview cannot
drift onto something the candidate never asserted.

## Why plans are not stored

A plan depends on the role, difficulty, duration, and objective — all HR
configuration that changes independently of the candidate. Persisting one
would serve a stale plan the first time a setting changed, the same reason
interview context is assembled fresh. Plans are built at interview start and
kept for the life of that session only.
"""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass, field

from deterministic import grounding

from . import provider
from .knowledge_profile import CandidateKnowledgeProfile

logger = logging.getLogger("cognihire.ai.question_planning")

# A plan longer than this cannot be covered in any realistic session, and a
# planner that returns thirty topics is usually padding rather than finding
# genuine ground to cover.
_MAX_TOPICS = 12

_DIFFICULTIES = ("foundational", "standard", "probing")

_INSTRUCTION = """\
You plan a technical interview. You do NOT write interview questions — a
later stage does that. Your job is to decide what to cover and in what order.

You are given a candidate's verified profile, the claims they made, and the
role they applied for.

Rules:
1. Every topic must be tied to a specific claim or profile fact you were
   given, quoted verbatim in "grounded_in". Do not plan a topic about
   something the candidate never asserted.
2. Order topics by what would most inform a hiring decision: the claims most
   central to the role first, so a session that runs short still covers what
   matters.
3. Prefer depth on a few real claims over shallow coverage of many.
4. "objective" states what asking about this topic is meant to establish.
5. Allocate "minutes" realistically against the total time you are given.

Reply with JSON only, in this exact shape:
{
  "topics": [
    {
      "topic": "<what to explore>",
      "objective": "<what this is meant to establish>",
      "grounded_in": ["<verbatim claim or profile fact>"],
      "minutes": 5
    }
  ],
  "coverage": ["<the aspects of the role this plan covers>"]
}
"""


@dataclass
class PlannedTopic:
    topic: str
    objective: str
    grounded_in: list[str] = field(default_factory=list)
    minutes: int = 5


@dataclass
class QuestionPlan:
    topics: list[PlannedTopic] = field(default_factory=list)
    coverage: list[str] = field(default_factory=list)
    estimated_minutes: int = 0

    kind: str = "heuristic_rule"
    degraded_reason: str | None = None

    # Topics the planner proposed that were not tied to anything the candidate
    # actually claimed, and were therefore dropped.
    rejected_ungrounded: list[str] = field(default_factory=list)

    @property
    def is_degraded(self) -> bool:
        return self.degraded_reason is not None

    def to_dict(self) -> dict:
        return asdict(self)


def _fallback(
    claims: list[str], available_minutes: int, reason: str | None
) -> QuestionPlan:
    """Deterministic plan: cover the claims in the order they were extracted.

    Weaker than a planned interview — it has no notion of what matters for the
    role — but it is real coverage of real claims, and it means a provider
    outage costs interview *quality* rather than costing the candidate their
    interview.
    """
    if not claims:
        return QuestionPlan(kind="heuristic_rule", degraded_reason=reason)

    count = min(len(claims), max(1, available_minutes // 5))
    per_topic = max(1, available_minutes // count) if count else available_minutes

    topics = [
        PlannedTopic(
            topic=claim,
            objective="Establish whether the candidate can substantiate this claim.",
            grounded_in=[claim],
            minutes=per_topic,
        )
        for claim in claims[:count]
    ]

    return QuestionPlan(
        topics=topics,
        coverage=["claims as stated, in resume order"],
        estimated_minutes=sum(t.minutes for t in topics),
        kind="heuristic_rule",
        degraded_reason=reason,
    )


def _render_inputs(
    profile: CandidateKnowledgeProfile,
    claims: list[str],
    role_title: str,
    required_skills: list[str],
    difficulty: str,
    available_minutes: int,
) -> str:
    """Build the planner's user message from structured inputs only.

    Note what is absent: the resume text. This stage reads the profile, and
    the profile is the contract.
    """
    lines = [
        f"ROLE: {role_title}",
        f"REQUIRED SKILLS: {', '.join(required_skills) if required_skills else '(none specified)'}",
        f"DIFFICULTY: {difficulty}",
        f"TOTAL TIME: {available_minutes} minutes",
        "",
        "CANDIDATE CLAIMS (verbatim, verified against their resume):",
    ]
    lines.extend(f"- {c}" for c in claims) if claims else lines.append("(none)")

    lines.append("")
    lines.append("PROFILE FACTS (verbatim):")
    facts = profile.grounded_facts
    lines.extend(f"- {f}" for f in facts) if facts else lines.append("(none)")

    # Inferences are offered as context but clearly labelled, so the planner
    # can use a reading of the candidate without mistaking it for something
    # they asserted.
    inferred = [
        *(f"focus: {i.value}" for i in profile.estimated_focus),
        *(f"domain: {i.value}" for i in profile.domains),
        *(f"strength: {i.value}" for i in profile.strengths),
    ]
    if inferred:
        lines.append("")
        lines.append("INFERRED CONTEXT (a model's reading, NOT the candidate's words —")
        lines.append("do not treat these as claims or quote them in grounded_in):")
        lines.extend(f"- {i}" for i in inferred)

    return "\n".join(lines)


async def plan(
    profile: CandidateKnowledgeProfile,
    claims: list[str],
    role_title: str,
    required_skills: list[str] | None = None,
    difficulty: str = "standard",
    available_minutes: int = 20,
    provider_override: str | None = None,
) -> QuestionPlan:
    """Build a question plan. Never raises.

    `claims` are the grounded claim texts from `claim_extraction`. `profile`
    supplies role-relevant context. Raw resume text is deliberately not a
    parameter — everything flows through the structured profile.
    """
    required_skills = required_skills or []
    if difficulty not in _DIFFICULTIES:
        difficulty = "standard"

    if not claims and not profile.grounded_facts:
        # Nothing verified to ask about. An interview built on nothing would
        # have to invent its subject matter, which is the failure this whole
        # system refuses.
        return QuestionPlan(
            kind="heuristic_rule",
            degraded_reason="the candidate profile contains no grounded claims to interview against",
        )

    reply = await provider.chat_json(
        _INSTRUCTION,
        _render_inputs(
            profile, claims, role_title, required_skills, difficulty, available_minutes
        ),
        timeout=45,
        provider=provider_override,
    )
    if not reply.ok:
        return _fallback(claims, available_minutes, reply.error)

    parsed = provider.parse_json_object(reply.content)
    if parsed is None:
        return _fallback(
            claims, available_minutes, f"the {reply.provider} model returned malformed JSON"
        )

    raw_topics = parsed.get("topics")
    if not isinstance(raw_topics, list):
        return _fallback(
            claims,
            available_minutes,
            f"the {reply.provider} model did not return a topics list",
        )

    # A topic may only be grounded in something the candidate actually
    # asserted, so the planner cannot introduce subject matter of its own.
    permitted = [*claims, *profile.grounded_facts]

    topics: list[PlannedTopic] = []
    rejected: list[str] = []

    for entry in raw_topics:
        if len(topics) >= _MAX_TOPICS:
            break
        if not isinstance(entry, dict):
            continue

        topic = entry.get("topic")
        if not isinstance(topic, str) or not topic.strip():
            continue

        raw_basis = entry.get("grounded_in")
        basis_values = (
            [b for b in raw_basis if isinstance(b, str)] if isinstance(raw_basis, list) else []
        )
        surviving = [
            b for b in basis_values if any(grounding.is_grounded(b, p) for p in permitted)
        ]

        if not surviving:
            rejected.append(topic.strip())
            continue

        objective = entry.get("objective")
        minutes = entry.get("minutes")

        topics.append(
            PlannedTopic(
                topic=topic.strip(),
                objective=objective.strip()
                if isinstance(objective, str) and objective.strip()
                else "Establish whether the candidate can substantiate this claim.",
                grounded_in=surviving,
                minutes=minutes if isinstance(minutes, int) and 0 < minutes <= 60 else 5,
            )
        )

    if not topics:
        return _fallback(
            claims,
            available_minutes,
            f"the {reply.provider} model produced no topics tied to a verified claim",
        )

    raw_coverage = parsed.get("coverage")
    coverage = (
        [c for c in raw_coverage if isinstance(c, str)] if isinstance(raw_coverage, list) else []
    )

    if rejected:
        logger.info("question planning discarded %d ungrounded topic(s)", len(rejected))

    return QuestionPlan(
        topics=topics,
        coverage=coverage,
        estimated_minutes=sum(t.minutes for t in topics),
        kind=provider.kind_for(reply.provider),
        rejected_ungrounded=rejected,
    )
