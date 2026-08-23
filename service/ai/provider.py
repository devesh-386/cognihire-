"""The LLM provider abstraction — the only code in CogniHire that speaks to a
model vendor.

Every AI stage (`resume_understanding`, `claim_extraction`, and the question
generation / interview / reporting stages to come) calls `chat_json()` here.
None of them know which provider answered. Swapping OpenAI for Ollama, or for
anything else later, is one env var and one adapter — no stage changes.

Keys live only in this process's environment. No client — Flutter, web, or
otherwise — ever holds one, which is what makes it safe to ship a web build.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass

import httpx

logger = logging.getLogger("cognihire.ai.provider")

LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "openai")

OPENAI_BASE_URL = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:7b")

OLLAMA_EMBED_MODEL = os.environ.get("OLLAMA_EMBED_MODEL", "nomic-embed-text")
OPENAI_EMBED_MODEL = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")

# Rate limiting (429) and momentary 5xx are exactly the responses a retry can
# fix; anything else (400, 401, a malformed body) means retrying would just
# get the same answer, so those still degrade on the first response.
_RETRYABLE_STATUS = {429, 500, 502, 503, 504}
_MAX_RETRIES = 2
_BASE_BACKOFF_SECONDS = 1.0
# A candidate is waiting live for the next question — retries add latency to
# an interactive turn, so the wait per attempt is capped regardless of what
# a provider's Retry-After header asks for.
_MAX_BACKOFF_SECONDS = 5.0


async def _post_with_retry(client: httpx.AsyncClient, url: str, **kwargs) -> httpx.Response:
    """POST with up to `_MAX_RETRIES` extra attempts for a transient
    failure — a busy moment at the provider should not immediately degrade
    an interview turn to the heuristic fallback. Honors a numeric
    `Retry-After` header when present, otherwise backs off exponentially.
    Every other status is still returned on the first response, same as
    before this existed."""
    response = await client.post(url, **kwargs)
    for attempt in range(_MAX_RETRIES):
        if response.status_code not in _RETRYABLE_STATUS:
            return response

        retry_after = response.headers.get("retry-after")
        try:
            delay = float(retry_after) if retry_after else _BASE_BACKOFF_SECONDS * (2**attempt)
        except ValueError:
            delay = _BASE_BACKOFF_SECONDS * (2**attempt)
        await asyncio.sleep(min(delay, _MAX_BACKOFF_SECONDS))

        response = await client.post(url, **kwargs)
    return response


@dataclass
class ModelReply:
    """A model's answer, or an honest account of why there isn't one.

    `content` is None exactly when `error` is set. Callers are expected to
    degrade on that rather than raise — an AI stage that crashes the request
    because a vendor was slow is worse than one that falls back and says so.
    """

    content: str | None
    provider: str  # "openai" | "ollama"
    error: str | None = None
    # Which exact model answered, and at what temperature — persisted
    # downstream (e.g. AnswerAnalysis) so a verdict is reproducible after the
    # fact, not just attributable to "openai" in general. Always 0 today
    # (both adapters hardcode it below); carried as a real field rather than
    # assumed so a verdict's record doesn't silently go stale if that ever
    # changes. None on a failed call — no model actually answered.
    model: str | None = None
    temperature: float | None = None

    @property
    def ok(self) -> bool:
        return self.content is not None


async def _openai_chat_json(system: str, user: str, timeout: int) -> ModelReply:
    if not OPENAI_API_KEY:
        return ModelReply(None, "openai", "no OpenAI API key is configured on this server")

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await _post_with_retry(
                client,
                f"{OPENAI_BASE_URL}/chat/completions",
                headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                json={
                    "model": OPENAI_MODEL,
                    "temperature": 0,
                    "response_format": {"type": "json_object"},
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
    except httpx.TimeoutException:
        return ModelReply(None, "openai", "the hosted model did not answer in time")
    except httpx.HTTPError as exc:
        return ModelReply(None, "openai", f"could not reach the hosted model service ({exc})")

    if response.status_code != 200:
        return ModelReply(
            None, "openai", f"the hosted model service answered HTTP {response.status_code}"
        )

    try:
        content = response.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError):
        return ModelReply(None, "openai", "the hosted model returned an unexpected response shape")

    if not content or not content.strip():
        return ModelReply(None, "openai", "the hosted model returned no content")
    return ModelReply(content, "openai", model=OPENAI_MODEL, temperature=0)


async def _ollama_chat_json(system: str, user: str, timeout: int) -> ModelReply:
    try:
        async with httpx.AsyncClient(timeout=max(timeout, 90)) as client:
            response = await _post_with_retry(
                client,
                f"{OLLAMA_BASE_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "stream": False,
                    "format": "json",
                    "options": {"temperature": 0},
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
    except httpx.TimeoutException:
        return ModelReply(None, "ollama", "the local model did not answer in time")
    except httpx.HTTPError as exc:
        return ModelReply(None, "ollama", f"could not reach the local model service ({exc})")

    if response.status_code != 200:
        return ModelReply(
            None, "ollama", f"the local model service answered HTTP {response.status_code}"
        )

    try:
        content = response.json()["message"]["content"]
    except (KeyError, ValueError):
        return ModelReply(None, "ollama", "the local model returned an unexpected response shape")

    if not content or not content.strip():
        return ModelReply(None, "ollama", "the local model returned no content")
    return ModelReply(content, "ollama", model=OLLAMA_MODEL, temperature=0)


async def chat_json(
    system: str, user: str, timeout: int = 30, provider: str | None = None
) -> ModelReply:
    """Ask the configured model for a JSON object. Never raises.

    `provider` overrides the server default for callers that need a specific
    backend (an offline-demo toggle, a test). It is never taken from a
    candidate-facing request.
    """
    active = provider or LLM_PROVIDER
    if active == "ollama":
        return await _ollama_chat_json(system, user, timeout)
    return await _openai_chat_json(system, user, timeout)


def parse_json_object(reply_content: str) -> dict | None:
    """Parse a model's reply into a dict, or None if it isn't one.

    Models occasionally wrap JSON in prose or a code fence despite being asked
    not to; that is a malformed answer, and returning None lets the caller
    degrade instead of guessing at the intent.
    """
    try:
        parsed = json.loads(reply_content)
    except (json.JSONDecodeError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def kind_for(provider: str) -> str:
    """The `*_llm` label recorded on a profile for this provider."""
    return "local_llm" if provider == "ollama" else "hosted_llm"


async def _ollama_embed(text: str, timeout: int) -> list[float] | None:
    try:
        async with httpx.AsyncClient(timeout=max(timeout, 60)) as client:
            response = await client.post(
                f"{OLLAMA_BASE_URL}/api/embeddings",
                json={"model": OLLAMA_EMBED_MODEL, "prompt": text},
            )
    except httpx.HTTPError:
        return None

    if response.status_code != 200:
        return None

    try:
        vector = response.json()["embedding"]
    except (KeyError, ValueError):
        return None
    if not isinstance(vector, list) or not vector:
        return None
    return [float(x) for x in vector]


async def _openai_embed(text: str, timeout: int) -> list[float] | None:
    if not OPENAI_API_KEY:
        return None

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
                f"{OPENAI_BASE_URL}/embeddings",
                headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
                json={"model": OPENAI_EMBED_MODEL, "input": text},
            )
    except httpx.HTTPError:
        return None

    if response.status_code != 200:
        return None

    try:
        vector = response.json()["data"][0]["embedding"]
    except (KeyError, IndexError, ValueError):
        return None
    if not isinstance(vector, list) or not vector:
        return None
    return [float(x) for x in vector]


async def embed(text: str, timeout: int = 30, provider: str | None = None) -> list[float] | None:
    """Ask the configured model for a text embedding. Never raises.

    Same shape as `chat_json`: an unreachable or unconfigured provider
    returns None rather than raising, so callers (`ai/embeddings.py`)
    degrade instead of crashing a request.
    """
    if not text or not text.strip():
        return None
    active = provider or LLM_PROVIDER
    if active == "ollama":
        return await _ollama_embed(text, timeout)
    return await _openai_embed(text, timeout)
