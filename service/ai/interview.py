"""AI stage — the interview engine.

Ties `question_planning`, `answer_analysis`, and `coverage_manager` into one
turn-by-turn loop:

```
Load plan + coverage state
        ↓
coverage_manager.next_topic  ─── None → interview complete
        ↓
last answer needed a follow-up?
   yes → generate_followup (grounded in that topic + the prior exchange)
   no  → generate_question (grounded in that topic's plan entry)
        ↓
[ caller collects the candidate's spoken answer — outside this module ]
        ↓
answer_analysis.analyze
        ↓
coverage_manager.evaluate  → updated state
        ↓
repeat
```

## Why this module never sees raw resume text or the resume itself

Everything it needs — what to ask about, what "good" looks like — was already
decided by `question_planning` and gated there. This module's only job is
turning a `PlannedTopic` into a spoken question and deciding, from a
`CoverageState`, what happens next. Enforced by
`test_downstream_stages_read_the_profile_not_raw_resume_text`.

## Why question phrasing has no verbatim grounding gate

A question is not a claim about the candidate — "Tell me more about the React
dashboard" asserts nothing that needs verifying. What this module is not
allowed to do is state a fact ABOUT the candidate in the question's own voice
("Since you led four engineers for two years, ...") that goes beyond what the
topic's `grounded_in` actually says. The prompts below are written to keep the
model asking rather than asserting, and `test_question_never_asserts_ungrounded_fact`
checks generated text stays anchored to the topic's own grounded material
rather than inventing detail.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum

from .answer_analysis import AnswerAnalysis
from .coverage_manager import CoverageState, next_topic
from .question_planning import PlannedTopic, QuestionPlan
from . import provider

_QUESTION_INSTRUCTION = """\
You are conducting a technical interview. Turn the topic below into one
natural, conversational question. Do not state any fact about the candidate
that is not already given to you — ask about what they wrote, don't assert it
back to them as established. Keep it to one or two sentences.

Reply with JSON only: {"question": "<the question to ask>"}
"""

_FOLLOWUP_INSTRUCTION = """\
The candidate's last answer needs a follow-up. You are given the topic, their
answer, and why it fell short. Ask ONE natural follow-up question that
targets specifically what was missing. Do not restate the original question.
Do not assert new facts about the candidate.

Reply with JSON only: {"question": "<the follow-up question>"}
"""


class TurnKind(str, Enum):
    QUESTION = "question"
    FOLLOWUP = "followup"
    COMPLETE = "complete"


@dataclass
class InterviewTurn:
    kind: TurnKind
    topic: str | None = None
    question: str | None = None
    # "hosted_llm" | "local_llm" | "heuristic_rule" | None (COMPLETE has none)
    generation_kind: str | None = None
    degraded_reason: str | None = None

    def to_dict(self) -> dict:
        d = asdict(self)
        d["kind"] = self.kind.value
        return d


# A phrased question this short is almost certainly the model failing to
# produce real content rather than being genuinely terse — fall back to the
# topic's own objective rather than asking something that thin.
_MIN_QUESTION_CHARS = 8


def _fallback_question(topic: PlannedTopic, reason: str) -> InterviewTurn:
    return InterviewTurn(
        kind=TurnKind.QUESTION,
        topic=topic.topic,
        question=f"Tell me about: {topic.topic}",
        generation_kind="heuristic_rule",
        degraded_reason=reason,
    )


def _fallback_followup(topic: PlannedTopic, reason: str) -> InterviewTurn:
    return InterviewTurn(
        kind=TurnKind.FOLLOWUP,
        topic=topic.topic,
        question="Can you go into more detail, with a specific example?",
        generation_kind="heuristic_rule",
        degraded_reason=reason,
    )


async def generate_question(
    topic: PlannedTopic, provider_override: str | None = None
) -> InterviewTurn:
    """Never raises. An unavailable provider falls back to a plain templated
    question — weaker phrasing, but the interview is never blocked on it."""
    user_message = (
        f"TOPIC: {topic.topic}\nOBJECTIVE: {topic.objective}\n"
        f"WHAT THE CANDIDATE SAID (verbatim, the only facts you may reference):\n"
        + "\n".join(f"- {g}" for g in topic.grounded_in)
    )

    reply = await provider.chat_json(
        _QUESTION_INSTRUCTION, user_message, timeout=20, provider=provider_override
    )
    if not reply.ok:
        return _fallback_question(topic, reply.error)

    parsed = provider.parse_json_object(reply.content)
    question = parsed.get("question") if parsed else None
    if not isinstance(question, str) or len(question.strip()) < _MIN_QUESTION_CHARS:
        return _fallback_question(
            topic, f"the {reply.provider} model returned no usable question"
        )

    return InterviewTurn(
        kind=TurnKind.QUESTION,
        topic=topic.topic,
        question=question.strip(),
        generation_kind=provider.kind_for(reply.provider),
    )


async def generate_followup(
    topic: PlannedTopic,
    last_answer: str,
    last_analysis: AnswerAnalysis,
    provider_override: str | None = None,
) -> InterviewTurn:
    """Never raises. Falls back to a generic probe rather than blocking."""
    user_message = (
        f"TOPIC: {topic.topic}\nCANDIDATE'S ANSWER: {last_answer}\n"
        f"WHY IT FELL SHORT: {last_analysis.reason}"
    )

    reply = await provider.chat_json(
        _FOLLOWUP_INSTRUCTION, user_message, timeout=20, provider=provider_override
    )
    if not reply.ok:
        return _fallback_followup(topic, reply.error)

    parsed = provider.parse_json_object(reply.content)
    question = parsed.get("question") if parsed else None
    if not isinstance(question, str) or len(question.strip()) < _MIN_QUESTION_CHARS:
        return _fallback_followup(
            topic, f"the {reply.provider} model returned no usable follow-up"
        )

    return InterviewTurn(
        kind=TurnKind.FOLLOWUP,
        topic=topic.topic,
        question=question.strip(),
        generation_kind=provider.kind_for(reply.provider),
    )


async def next_turn(
    plan: QuestionPlan,
    coverage: CoverageState,
    last_answer_text: str | None = None,
    last_analysis: AnswerAnalysis | None = None,
    provider_override: str | None = None,
) -> InterviewTurn:
    """The single entry point the caller (HTTP layer, once built) drives.

    `coverage` reflects state as of the most recent `coverage_manager.evaluate`
    call — this function does not itself update coverage; the caller re-runs
    `evaluate` after storing the answer and analysis, then calls this again
    for the next turn.
    """
    topic = next_topic(plan, coverage)
    if topic is None:
        return InterviewTurn(kind=TurnKind.COMPLETE)

    if last_analysis is not None and last_analysis.followup_required and last_answer_text:
        return await generate_followup(
            topic, last_answer_text, last_analysis, provider_override
        )

    return await generate_question(topic, provider_override)
