"""Deterministic processing — no model decides anything in this package.

Everything here is code whose output is fully explained by its input: PDF text
extraction, the fallback resume parser, and the grounding gate that verifies
what the AI stages produce.

The split between this package and `ai/` is the architecture's central claim.
`deterministic/` is what CogniHire can promise; `ai/` is what it can produce
but must then verify. Nothing in this package may import from `ai/` — the
verifier of a model's output cannot itself be a model.
"""

from . import grounding, pdf_extraction, resume_parser

__all__ = ["grounding", "pdf_extraction", "resume_parser"]
