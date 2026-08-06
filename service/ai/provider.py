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

    @property
    def ok(self) -> bool:
        return self.content is not None


async def _openai_chat_json(system: str, user: str, timeout: int) -> ModelReply:
    if not OPENAI_API_KEY:
        return ModelReply(None, "openai", "no OpenAI API key is configured on this server")

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
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
    return ModelReply(content, "openai")


async def _ollama_chat_json(system: str, user: str, timeout: int) -> ModelReply:
    try:
        async with httpx.AsyncClient(timeout=max(timeout, 90)) as client:
            response = await client.post(
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
    return ModelReply(content, "ollama")


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
