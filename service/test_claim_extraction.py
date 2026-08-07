"""Tests for the claim-extraction AI stage and the provider abstraction
underneath it (`ai/claim_extraction.py`, `ai/provider.py`).

`pytest-asyncio` isn't in requirements, so async entry points are driven with
`asyncio.run` from plain `def test_*` functions rather than adding a new
dependency for it.

Coverage: provider selection, the grounding gate, invalid JSON, timeouts,
OpenAI failure, Ollama failure, empty input, malformed response shape,
happy path.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from ai import claim_extraction, provider


@pytest.fixture(autouse=True)
def _no_real_retry_backoff(monkeypatch):
    """Several tests here return a 500/503, which provider.py now retries
    with a real backoff sleep before degrading. Kept fast and deterministic,
    same as test_provider_retry.py."""

    async def _no_sleep(*_args):
        return None

    monkeypatch.setattr(provider.asyncio, "sleep", _no_sleep)


class _FakeResponse:
    def __init__(self, status_code: int, payload: dict | None = None, headers: dict | None = None):
        self.status_code = status_code
        self._payload = payload or {}
        # Real httpx.Response always has .headers; provider.py's retry
        # logic reads it even on a non-2xx reply.
        self.headers = headers or {}

    def json(self):
        return self._payload


class _FakeAsyncClient:
    """Stands in for httpx.AsyncClient. `responder` maps a call to a
    _FakeResponse or raises the given exception."""

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
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda *a, **k: _FakeAsyncClient(responder)
    )


def _run(coro):
    return asyncio.run(coro)


RESUME = "Built and shipped a React dashboard used by 200+ staff.\nLed a team of 4 engineers."


def _openai_payload(claims: list[dict]) -> dict:
    return {
        "choices": [
            {"message": {"content": json.dumps({"claims": claims})}}
        ]
    }


def _ollama_payload(claims: list[dict]) -> dict:
    return {"message": {"content": json.dumps({"claims": claims})}}


# --- Happy path -------------------------------------------------------------


def test_openai_happy_path_reports_hosted_llm(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200,
            _openai_payload(
                [{"text": "Led a team of 4 engineers.", "skill": None}]
            ),
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "hosted_llm"
    assert result.degraded_reason is None
    assert [c.text for c in result.claims] == ["Led a team of 4 engineers."]


def test_ollama_happy_path_reports_local_llm(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200,
            _ollama_payload(
                [{"text": "Built and shipped a React dashboard used by 200+ staff.", "skill": "React"}]
            ),
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "local_llm"
    assert result.claims[0].skill == "React"


def test_provider_param_overrides_env_default(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    calls = []

    def responder(url, kw):
        calls.append(url)
        return _FakeResponse(200, _ollama_payload([]))

    _patch_client(monkeypatch, responder)

    _run(claim_extraction.extract_claims(RESUME, source="resume", provider_override="ollama"))

    assert calls == [f"{provider.OLLAMA_BASE_URL}/api/chat"]


# --- Empty input --------------------------------------------------------


def test_empty_document_never_calls_the_model(monkeypatch):
    def responder(url, kw):
        raise AssertionError("should not call the model for empty input")

    _patch_client(monkeypatch, responder)

    result = _run(claim_extraction.extract_claims("   ", source="resume"))

    assert result.claims == []
    assert result.kind == "hosted_llm"


# --- Grounding gate -------------------------------------------------------


def test_grounding_gate_rejects_fabricated_claim(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200,
            _openai_payload(
                [
                    {"text": "Led a team of 4 engineers.", "skill": None},
                    {"text": "Won Employee of the Year.", "skill": None},
                ]
            ),
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert [c.text for c in result.claims] == ["Led a team of 4 engineers."]
    assert result.rejected_ungrounded == ["Won Employee of the Year."]
    # A rejected fabrication does not degrade the whole extraction — the
    # model still gets credit (hosted_llm) for what it grounded correctly.
    assert result.kind == "hosted_llm"


def test_grounding_ignores_whitespace_and_case(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200,
            _openai_payload(
                [{"text": "  LED   a team of 4  engineers.  ", "skill": None}]
            ),
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert len(result.claims) == 1
    assert result.rejected_ungrounded == []


# --- Invalid / malformed JSON ---------------------------------------------


def test_invalid_json_degrades_to_heuristic(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200, {"choices": [{"message": {"content": "not json at all"}}]}
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "malformed" in result.degraded_reason
    assert result.claims  # heuristic fallback still ran


def test_json_without_claims_list_degrades(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: _FakeResponse(
            200, _openai_payload_raw({"not_claims": []})
        ),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"


def _openai_payload_raw(content_obj: dict) -> dict:
    return {"choices": [{"message": {"content": json.dumps(content_obj)}}]}


def test_malformed_response_shape_degrades(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    # No "choices" key at all — a shape the real API would never send, but the
    # gateway must not crash on it.
    _patch_client(monkeypatch, lambda url, kw: _FakeResponse(200, {}))

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "unexpected response shape" in result.degraded_reason


# --- Timeout ----------------------------------------------------------------


def test_openai_timeout_degrades_with_reason(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: httpx.TimeoutException("timed out"),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "time" in result.degraded_reason


def test_ollama_timeout_degrades_with_reason(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(
        monkeypatch,
        lambda url, kw: httpx.TimeoutException("timed out"),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "local model" in result.degraded_reason


# --- Provider failure (HTTP errors, unreachable) ---------------------------


def test_openai_http_error_degrades(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(monkeypatch, lambda url, kw: _FakeResponse(500, {}))

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "500" in result.degraded_reason


def test_openai_unreachable_degrades(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "sk-test")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(
        monkeypatch,
        lambda url, kw: httpx.ConnectError("connection refused"),
    )

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "could not reach" in result.degraded_reason


def test_ollama_http_error_degrades(monkeypatch):
    monkeypatch.setattr(provider, "LLM_PROVIDER", "ollama")
    _patch_client(monkeypatch, lambda url, kw: _FakeResponse(503, {}))

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "503" in result.degraded_reason


def test_missing_openai_key_degrades_without_network_call(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")

    def responder(url, kw):
        raise AssertionError("must not call OpenAI with no key configured")

    _patch_client(monkeypatch, responder)

    result = _run(claim_extraction.extract_claims(RESUME, source="resume"))

    assert result.kind == "heuristic_rule"
    assert "API key" in result.degraded_reason


# --- Sanity on the heuristic fallback itself --------------------------------


def test_heuristic_fallback_never_raises_on_any_document(monkeypatch):
    monkeypatch.setattr(provider, "OPENAI_API_KEY", "")
    monkeypatch.setattr(provider, "LLM_PROVIDER", "openai")
    _patch_client(monkeypatch, lambda url, kw: (_ for _ in ()).throw(AssertionError))

    result = _run(claim_extraction.extract_claims("x" * 5000, source="resume"))

    assert result.kind == "heuristic_rule"
    assert isinstance(result.claims, list)
