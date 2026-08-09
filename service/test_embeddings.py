"""Tests for `ai/embeddings.py` and `ai/semantic_similarity.py`.

Same harness as `test_claim_extraction.py`: httpx.AsyncClient is faked so no
test depends on a live Ollama or OpenAI endpoint, and `asyncio.run` drives
the async entry points since pytest-asyncio isn't a dependency here.

Coverage: cosine similarity math, provider selection and failure handling for
embed(), and that the two similarity matchers degrade to None/no-match
instead of fabricating a score when an embedding is unavailable.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

from ai import embeddings, provider, semantic_similarity


def _run(coro):
    return asyncio.run(coro)


class _FakeResponse:
    def __init__(self, status_code: int, payload: dict | None = None):
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


def _patch_client(monkeypatch, responder):
    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder))


# --- cosine_similarity --------------------------------------------------------


def test_cosine_similarity_identical_vectors_is_one():
    assert embeddings.cosine_similarity([1.0, 0.0], [1.0, 0.0]) == pytest.approx(1.0)


def test_cosine_similarity_orthogonal_vectors_is_zero():
    assert embeddings.cosine_similarity([1.0, 0.0], [0.0, 1.0]) == pytest.approx(0.0)


def test_cosine_similarity_opposite_vectors_is_negative_one():
    assert embeddings.cosine_similarity([1.0, 0.0], [-1.0, 0.0]) == pytest.approx(-1.0)


def test_cosine_similarity_zero_vector_is_none():
    assert embeddings.cosine_similarity([0.0, 0.0], [1.0, 0.0]) is None


def test_cosine_similarity_mismatched_length_is_none():
    assert embeddings.cosine_similarity([1.0], [1.0, 0.0]) is None


# --- embed() ------------------------------------------------------------------


def test_embed_empty_text_is_none():
    assert _run(embeddings.embed("")) is None
    assert _run(embeddings.embed("   ")) is None


def test_embed_ollama_happy_path(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(200, {"embedding": [0.1, 0.2, 0.3]}),
    )
    assert _run(embeddings.embed("hello")) == [0.1, 0.2, 0.3]


def test_embed_ollama_unreachable_is_none(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(monkeypatch, lambda url, kw: httpx.ConnectError("refused"))
    assert _run(embeddings.embed("hello")) is None


def test_embed_ollama_bad_status_is_none(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(monkeypatch, lambda url, kw: _FakeResponse(500, {}))
    assert _run(embeddings.embed("hello")) is None


def test_embed_ollama_malformed_shape_is_none(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(monkeypatch, lambda url, kw: _FakeResponse(200, {"unexpected": True}))
    assert _run(embeddings.embed("hello")) is None


def test_embed_openai_without_key_is_none(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "")
    assert _run(embeddings.embed("hello")) is None


def test_embed_openai_happy_path(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(200, {"data": [{"embedding": [0.4, 0.5]}]}),
    )
    assert _run(embeddings.embed("hello")) == [0.4, 0.5]


# --- semantic_similarity --------------------------------------------------------


def _fake_embed_fixed(vectors: dict[str, list[float]]):
    async def _fake(text, *, timeout=30, provider_override=None):
        return vectors.get(text)

    return _fake


def test_match_claims_to_requirements_picks_best_scoring_claim(monkeypatch):
    vectors = {
        "knows React": [1.0, 0.0],
        "Built a React dashboard.": [0.95, 0.05],
        "Led a bake sale.": [0.0, 1.0],
    }
    monkeypatch.setattr(embeddings, "embed", _fake_embed_fixed(vectors))

    results = _run(
        semantic_similarity.match_claims_to_requirements(
            ["knows React"], ["Built a React dashboard.", "Led a bake sale."]
        )
    )
    assert len(results) == 1
    assert results[0].best_claim == "Built a React dashboard."
    assert results[0].score > semantic_similarity._MATCH_FLOOR


def test_match_claims_to_requirements_below_floor_is_no_match(monkeypatch):
    vectors = {
        "knows Rust": [1.0, 0.0],
        "Led a bake sale.": [0.0, 1.0],
    }
    monkeypatch.setattr(embeddings, "embed", _fake_embed_fixed(vectors))

    results = _run(
        semantic_similarity.match_claims_to_requirements(["knows Rust"], ["Led a bake sale."])
    )
    assert results[0].best_claim is None
    assert results[0].score == pytest.approx(0.0)


def test_match_claims_to_requirements_no_claims_is_none_score():
    results = _run(semantic_similarity.match_claims_to_requirements(["knows Rust"], []))
    assert results == [semantic_similarity.RequirementMatch("knows Rust", None, None)]


def test_match_claims_to_requirements_degraded_when_embedding_unavailable(monkeypatch):
    async def _always_none(text, *, timeout=30, provider_override=None):
        return None

    monkeypatch.setattr(embeddings, "embed", _always_none)

    results = _run(
        semantic_similarity.match_claims_to_requirements(["knows Rust"], ["Built a thing."])
    )
    assert results[0].score is None
    assert results[0].degraded is True


def test_match_answer_to_concepts_matches_by_meaning(monkeypatch):
    vectors = {
        "The system splits work across several servers so no one machine is a bottleneck.": [1.0, 0.0],
        "load balancing": [0.98, 0.02],
        "unicorns": [0.0, 1.0],
    }
    monkeypatch.setattr(embeddings, "embed", _fake_embed_fixed(vectors))

    results = _run(
        semantic_similarity.match_answer_to_concepts(
            "The system splits work across several servers so no one machine is a bottleneck.",
            ["load balancing", "unicorns"],
        )
    )
    assert results[0].concept == "load balancing"
    assert results[0].matched is True
    assert results[1].matched is False


def test_match_answer_to_concepts_empty_answer_embedding_is_no_match(monkeypatch):
    async def _always_none(text, *, timeout=30, provider_override=None):
        return None

    monkeypatch.setattr(embeddings, "embed", _always_none)

    results = _run(semantic_similarity.match_answer_to_concepts("", ["load balancing"]))
    assert results == [semantic_similarity.ConceptMatch("load balancing", None, False)]
