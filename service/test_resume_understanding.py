"""Tests for the resume-understanding AI stage and the grounding gate it
depends on.

The load-bearing property here is that a model may SELECT text but never
AUTHOR it. Most of these tests exist to prove a plausible invention gets
discarded rather than stored.
"""

from __future__ import annotations

import asyncio
import json

import httpx

from ai import provider, resume_understanding
from deterministic import grounding

RESUME = """\
Devesh S
deveshsv.386@gmail.com

Skills
Python, Flutter, PostgreSQL

Projects
- CogniHire - verified-claim interview intelligence

Experience
- Led a team of 4 engineers.
"""


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


def _patch_model(monkeypatch, payload_obj=None, error=None):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")

    def responder(url, kw):
        if error is not None:
            return error
        return _FakeResponse(
            200, {"choices": [{"message": {"content": json.dumps(payload_obj)}}]}
        )

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))


# --- The grounding gate itself ---------------------------------------------


def test_grounding_accepts_verbatim_text():
    assert grounding.is_grounded("Led a team of 4 engineers.", RESUME)


def test_grounding_ignores_case_and_whitespace():
    assert grounding.is_grounded("  LED  a team   of 4 engineers. ", RESUME)


def test_grounding_rejects_paraphrase():
    assert not grounding.is_grounded("Managed four engineers", RESUME)


def test_grounding_rejects_empty():
    assert not grounding.is_grounded("   ", RESUME)


def test_filter_grounded_splits_and_deduplicates():
    kept, rejected = grounding.filter_grounded(
        ["Python", "Python", "Rust", "Flutter"], RESUME
    )
    assert kept == ["Python", "Flutter"]
    assert rejected == ["Rust"]


# --- The AI stage -----------------------------------------------------------


def test_understanding_keeps_grounded_values(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "identity": {"name": "Devesh S"},
            "skills": ["Python", "Flutter"],
            "projects": ["CogniHire - verified-claim interview intelligence"],
            "experience": ["Led a team of 4 engineers."],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.kind == "hosted_llm"
    assert result.skills == ["Python", "Flutter"]
    assert result.identity.name == "Devesh S"
    assert result.rejected_ungrounded == []


def test_understanding_discards_invented_skill(monkeypatch):
    """The classic failure: a model lists a technology that co-occurs with one
    that is present, but which the resume never names."""
    _patch_model(
        monkeypatch,
        {
            "identity": {"name": "Devesh S"},
            "skills": ["Python", "Django", "Kubernetes"],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.skills == ["Python"]
    assert sorted(result.rejected_ungrounded) == ["Django", "Kubernetes"]


def test_understanding_discards_upgraded_qualifier(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": ["Python expert"],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.skills == []
    assert result.rejected_ungrounded == ["Python expert"]


def test_understanding_discards_wrong_name(monkeypatch):
    """A model confidently naming the wrong person is worse than no name."""
    _patch_model(
        monkeypatch,
        {
            "identity": {"name": "Jane Doe"},
            "skills": [],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.identity.name is None
    assert "Jane Doe" in result.rejected_ungrounded


def test_email_comes_from_the_document_not_the_model(monkeypatch):
    """A single wrong character produces a plausible address that reaches the
    wrong person, so email is matched deterministically."""
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": [],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.identity.email == "deveshsv.386@gmail.com"


def test_provider_outage_falls_back_to_deterministic_parser(monkeypatch):
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    result = _run(resume_understanding.understand(RESUME))

    assert result.kind == "heuristic_rule"
    assert "time" in result.degraded_reason
    # The fallback still produced something real.
    assert "Python" in result.skills


def test_malformed_json_falls_back(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda *a, **k: _FakeAsyncClient(
            lambda url, kw: _FakeResponse(
                200, {"choices": [{"message": {"content": "not json"}}]}
            )
        ),
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.kind == "heuristic_rule"
    assert "malformed" in result.degraded_reason


def test_missing_key_falls_back_without_network_call(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")

    def responder(url, kw):
        raise AssertionError("must not call OpenAI with no key configured")

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))

    result = _run(resume_understanding.understand(RESUME))

    assert result.kind == "heuristic_rule"
    assert "API key" in result.degraded_reason


def test_empty_resume_never_calls_the_model(monkeypatch):
    def responder(url, kw):
        raise AssertionError("should not call the model for empty input")

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))

    result = _run(resume_understanding.understand("   "))

    assert result.skills == []
    assert result.kind == "heuristic_rule"


def test_non_list_fields_do_not_crash(monkeypatch):
    """A model returning a string where a list was asked for is malformed
    input, not an exception."""
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": "Python",
            "projects": None,
            "experience": [],
            "education": [],
            "certifications": [],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.skills == []
    assert result.projects == []


# --- Inferences: conclusions must cite grounded evidence --------------------


def test_inference_with_grounded_basis_is_kept(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": ["Python"],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
            "estimated_focus": [
                {"value": "Backend", "basis": ["Led a team of 4 engineers."]}
            ],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert len(result.estimated_focus) == 1
    assert result.estimated_focus[0].value == "Backend"
    assert result.estimated_focus[0].basis == ["Led a team of 4 engineers."]
    assert result.estimated_focus[0].is_supported


def test_inference_without_basis_is_dropped(monkeypatch):
    """An unsupported conclusion sitting beside verified facts reads as one of
    them, so it is refused rather than stored."""
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": [],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
            "strengths": [{"value": "Strong communicator", "basis": []}],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.strengths == []
    assert "Strong communicator" in result.rejected_unsupported_inferences


def test_inference_with_fabricated_basis_is_dropped(monkeypatch):
    """A model that invents both a conclusion AND the quote supporting it must
    not get credit for having shown its work."""
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": [],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
            "domains": [
                {"value": "Fintech", "basis": ["Built payment systems at scale"]}
            ],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.domains == []
    assert "Fintech" in result.rejected_unsupported_inferences
    assert "Built payment systems at scale" in result.rejected_ungrounded


def test_inference_keeps_only_the_surviving_basis(monkeypatch):
    _patch_model(
        monkeypatch,
        {
            "identity": {},
            "skills": [],
            "projects": [],
            "experience": [],
            "education": [],
            "certifications": [],
            "domains": [
                {
                    "value": "Team leadership",
                    "basis": ["Led a team of 4 engineers.", "Managed a department"],
                }
            ],
        },
    )

    result = _run(resume_understanding.understand(RESUME))

    assert result.domains[0].basis == ["Led a team of 4 engineers."]
    assert "Managed a department" in result.rejected_ungrounded


def test_fallback_emits_no_inferences(monkeypatch):
    """A text rule cannot judge focus; emitting a guess would put an
    unsupported conclusion in the same field a reasoned one occupies."""
    _patch_model(monkeypatch, error=httpx.TimeoutException("slow"))

    result = _run(resume_understanding.understand(RESUME))

    assert result.estimated_focus == []
    assert result.domains == []
    assert result.strengths == []


def test_profile_roundtrips_through_json():
    """A profile written by the pipeline must reload for an interview that is
    about to start."""
    from ai.knowledge_profile import CandidateKnowledgeProfile, Identity, Inference

    original = CandidateKnowledgeProfile(
        identity=Identity(name="Devesh S", email="d@example.com"),
        skills=["Python"],
        domains=[Inference(value="Backend", basis=["Led a team of 4 engineers."])],
        kind="hosted_llm",
    )

    restored = CandidateKnowledgeProfile.from_dict(original.to_dict())

    assert restored.identity.name == "Devesh S"
    assert restored.skills == ["Python"]
    assert restored.domains[0].value == "Backend"
    assert restored.domains[0].basis == ["Led a team of 4 engineers."]
    assert restored.kind == "hosted_llm"


def test_profile_from_partial_dict_does_not_crash():
    """An older pipeline version's output must still load."""
    from ai.knowledge_profile import CandidateKnowledgeProfile

    restored = CandidateKnowledgeProfile.from_dict({"skills": ["Go"]})

    assert restored.skills == ["Go"]
    assert restored.domains == []
    assert restored.identity.name is None


def test_grounded_facts_collects_every_quoted_field():
    from ai.knowledge_profile import CandidateKnowledgeProfile

    profile = CandidateKnowledgeProfile(
        skills=["Python"], projects=["CogniHire"], certifications=["AWS SAA"]
    )

    assert set(profile.grounded_facts) == {"Python", "CogniHire", "AWS SAA"}
