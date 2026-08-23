"""Tests for the question-planning AI stage.

The load-bearing properties: a plan may only cover ground the candidate
actually claimed, and a provider outage costs interview *quality* rather than
costing the candidate their interview.
"""

from __future__ import annotations

import asyncio
import json

import httpx

from ai import embeddings, provider, question_planning
from ai.knowledge_profile import CandidateKnowledgeProfile, Inference

CLAIMS = [
    "Built and shipped a React dashboard used by 200+ staff.",
    "Led a team of 4 engineers.",
]

PROFILE = CandidateKnowledgeProfile(
    skills=["React", "Python"],
    projects=["CogniHire - interview intelligence"],
    estimated_focus=[Inference(value="Frontend", basis=["React"])],
    kind="hosted_llm",
)


def _run(coro):
    return asyncio.run(coro)


class _FakeResponse:
    def __init__(self, status_code, payload=None):
        self.status_code = status_code
        self._payload = payload or {}

    def json(self):
        return self._payload


class _FakeAsyncClient:
    def __init__(self, responder):
        self._responder = responder

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, **kwargs):
        result = self._responder(url, kwargs)
        if isinstance(result, Exception):
            raise result
        return result


def _patch_model(monkeypatch, payload_obj=None, error=None, capture=None):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")

    def responder(url, kw):
        if capture is not None:
            capture.append(kw)
        if error is not None:
            return error
        return _FakeResponse(
            200, {"choices": [{"message": {"content": json.dumps(payload_obj)}}]}
        )

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))


async def _plan(**kwargs):
    return await question_planning.plan(
        profile=kwargs.pop("profile", PROFILE),
        claims=kwargs.pop("claims", CLAIMS),
        role_title=kwargs.pop("role_title", "Frontend Engineer"),
        **kwargs,
    )


# --- Happy path -------------------------------------------------------------


def test_plan_keeps_topics_grounded_in_a_claim(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "Scaling the React dashboard",
                    "objective": "Establish real ownership of the frontend work.",
                    "grounded_in": ["Built and shipped a React dashboard used by 200+ staff."],
                    "minutes": 8,
                }
            ],
            "coverage": ["frontend delivery"],
        },
    )

    result = _run(_plan())

    assert result.kind == "hosted_llm"
    assert len(result.topics) == 1
    assert result.topics[0].minutes == 8
    assert result.estimated_minutes == 8
    assert result.coverage == ["frontend delivery"]
    assert not result.is_degraded


def test_topic_may_be_grounded_in_a_profile_fact(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "Python depth",
                    "objective": "Check breadth beyond the dashboard.",
                    "grounded_in": ["Python"],
                    "minutes": 5,
                }
            ],
            "coverage": [],
        },
    )

    result = _run(_plan())

    assert len(result.topics) == 1
    assert result.topics[0].grounded_in == ["Python"]


# --- The grounding rule -----------------------------------------------------


def test_topic_not_tied_to_any_claim_is_dropped(monkeypatch):
    """The planner must not introduce subject matter of its own."""
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "Kubernetes operations",
                    "objective": "Assess infra skills.",
                    "grounded_in": ["Ran production Kubernetes clusters"],
                    "minutes": 5,
                },
                {
                    "topic": "Team leadership",
                    "objective": "Probe the leadership claim.",
                    "grounded_in": ["Led a team of 4 engineers."],
                    "minutes": 5,
                },
            ],
            "coverage": [],
        },
    )

    result = _run(_plan())

    assert [t.topic for t in result.topics] == ["Team leadership"]
    assert result.rejected_ungrounded == ["Kubernetes operations"]


def test_plan_with_no_grounded_topics_degrades_to_fallback(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "Invented topic",
                    "objective": "n/a",
                    "grounded_in": ["Something never said"],
                    "minutes": 5,
                }
            ],
            "coverage": [],
        },
    )

    result = _run(_plan())

    assert result.kind == "heuristic_rule"
    assert "no topics tied to a verified claim" in result.degraded_reason
    # The fallback still covers the real claims.
    assert len(result.topics) >= 1


def test_inferences_are_labelled_and_not_quotable(monkeypatch):
    """The planner is shown inferences as context but told not to treat them
    as claims — and a topic grounded only in one is refused."""
    capture: list = []
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "Frontend focus",
                    "objective": "n/a",
                    "grounded_in": ["Frontend"],
                    "minutes": 5,
                }
            ],
            "coverage": [],
        },
        capture=capture,
    )

    result = _run(_plan())

    sent = capture[0]["json"]["messages"][1]["content"]
    assert "INFERRED CONTEXT" in sent
    assert "NOT the candidate's words" in sent
    # "Frontend" is an inference, not a claim or grounded fact → refused.
    assert result.kind == "heuristic_rule"


def test_raw_resume_text_is_never_sent(monkeypatch):
    """Everything flows through the structured profile."""
    capture: list = []
    _patch_model(
        monkeypatch,
        {"topics": [{"topic": "T", "objective": "o", "grounded_in": ["Python"], "minutes": 5}]},
        capture=capture,
    )

    _run(_plan())

    sent = capture[0]["json"]["messages"][1]["content"]
    # The profile's fields appear; nothing resembling a raw document does.
    assert "Python" in sent
    assert "deveshsv" not in sent


# --- Degradation ------------------------------------------------------------


def test_provider_outage_falls_back_to_claim_order(monkeypatch):
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    result = _run(_plan(available_minutes=20))

    assert result.kind == "heuristic_rule"
    assert "time" in result.degraded_reason
    assert [t.topic for t in result.topics] == CLAIMS
    assert all(t.grounded_in for t in result.topics)


def test_fallback_plan_flags_truncation_when_time_caps_the_topic_count(monkeypatch):
    """The heuristic fallback caps topics to what `available_minutes` can
    fit (`count = min(len(ordered), available_minutes // 5)`) — when that's
    fewer than the claims actually available, the plan must say so rather
    than silently covering a subset."""
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    result = _run(_plan(available_minutes=5))  # fits only 1 of 2 claims

    assert len(result.topics) == 1
    assert result.topics_truncated is True


def test_provider_outage_orders_fallback_by_relevance_to_required_skills(monkeypatch):
    """The fallback plan is claim-order by default (see
    test_provider_outage_falls_back_to_claim_order), but when required_skills
    are given and embeddings are available, the more relevant claim goes
    first — this is the "ML-based question selection" the heuristic path
    otherwise has no way to do."""
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    vectors = {
        "Rust": [0.0, 1.0],
        "Built and shipped a React dashboard used by 200+ staff.": [0.1, 0.9],
        "Led a team of 4 engineers.": [1.0, 0.0],
    }

    async def _fake_embed(text, *, timeout=30, provider_override=None):
        return vectors.get(text)

    monkeypatch.setattr(embeddings, "embed", _fake_embed)

    result = _run(_plan(available_minutes=20, required_skills=["Rust"]))

    assert result.kind == "heuristic_rule"
    assert [t.topic for t in result.topics] == [
        "Built and shipped a React dashboard used by 200+ staff.",
        "Led a team of 4 engineers.",
    ]


def test_provider_outage_with_unavailable_embeddings_keeps_claim_order(monkeypatch):
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    async def _always_none(text, *, timeout=30, provider_override=None):
        return None

    monkeypatch.setattr(embeddings, "embed", _always_none)

    result = _run(_plan(available_minutes=20, required_skills=["Rust"]))

    assert [t.topic for t in result.topics] == CLAIMS


def test_malformed_json_falls_back(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda *a, **k: _FakeAsyncClient(
            lambda url, kw: _FakeResponse(200, {"choices": [{"message": {"content": "nope"}}]})
        ),
    )

    result = _run(_plan())

    assert result.kind == "heuristic_rule"
    assert "malformed" in result.degraded_reason


def test_no_claims_and_no_facts_refuses_to_plan(monkeypatch):
    """An interview built on nothing would have to invent its subject."""

    def responder(url, kw):
        raise AssertionError("must not call the model with nothing to plan against")

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))

    result = _run(_plan(profile=CandidateKnowledgeProfile(), claims=[]))

    assert result.topics == []
    assert "no grounded claims" in result.degraded_reason


# --- Bounds -----------------------------------------------------------------


def test_topic_count_is_capped(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": f"Topic {i}",
                    "objective": "o",
                    "grounded_in": ["Python"],
                    "minutes": 5,
                }
                for i in range(50)
            ],
            "coverage": [],
        },
    )

    result = _run(_plan())

    assert len(result.topics) == question_planning._MAX_TOPICS
    assert result.topics_truncated is True


def test_topic_count_under_the_cap_is_not_flagged_truncated(monkeypatch):
    _patch_model(
        monkeypatch,
        {"topics": [{"topic": "Topic 1", "objective": "o", "grounded_in": ["Python"], "minutes": 5}], "coverage": []},
    )
    result = _run(_plan())
    assert result.topics_truncated is False


def test_claims_truncated_is_passed_through_from_the_caller(monkeypatch):
    """This stage never sees the raw claim count claim_extraction started
    with — only the already-capped list — so `claims_truncated` must be
    whatever the caller (session/interview_session.start) says it is,
    unrelated to this stage's own topic count."""
    _patch_model(
        monkeypatch,
        {"topics": [{"topic": "Topic 1", "objective": "o", "grounded_in": ["Python"], "minutes": 5}], "coverage": []},
    )
    result = _run(_plan(claims_truncated=True))
    assert result.claims_truncated is True


def test_absurd_minutes_are_replaced_with_a_default(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "topics": [
                {
                    "topic": "T",
                    "objective": "o",
                    "grounded_in": ["Python"],
                    "minutes": 9999,
                }
            ],
            "coverage": [],
        },
    )

    result = _run(_plan())

    assert result.topics[0].minutes == 5


def test_unknown_difficulty_falls_back_to_standard(monkeypatch):
    capture: list = []
    _patch_model(
        monkeypatch,
        {"topics": [{"topic": "T", "objective": "o", "grounded_in": ["Python"], "minutes": 5}]},
        capture=capture,
    )

    _run(_plan(difficulty="impossible"))

    assert "DIFFICULTY: standard" in capture[0]["json"]["messages"][1]["content"]
