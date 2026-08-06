"""Enforces the deterministic/AI boundary in code, not just in documentation.

The architecture's central claim is that `deterministic/` is what CogniHire
can promise and `ai/` is what it produces but must then verify. That claim is
worth nothing if the verifier can quietly start calling a model, so it is
checked here rather than left to reviewer discipline.

Mirrors the ED-boundary linter under `tools/lint/` in spirit: a structural
rule the codebase states about itself should fail a test when broken, not
merely read well in a docstring.
"""

from __future__ import annotations

import ast
import pathlib

_SERVICE_ROOT = pathlib.Path(__file__).parent


def _imports_in(path: pathlib.Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            found.append(node.module)
            # `from . import x` inside deterministic/ resolves to a sibling,
            # which is fine; only absolute cross-package imports matter here.
    return found


def _modules_in(package: str) -> list[pathlib.Path]:
    return sorted((_SERVICE_ROOT / package).glob("*.py"))


def test_deterministic_never_imports_ai():
    """The verifier of a model's output cannot itself be a model.

    If this fails, the grounding gate (or PDF extraction, or the fallback
    parser) has taken a dependency on a model — which would mean a
    fabrication could be validated by the same class of system that produced
    it.
    """
    offenders = []
    for path in _modules_in("deterministic"):
        for imported in _imports_in(path):
            if imported == "ai" or imported.startswith("ai."):
                offenders.append(f"{path.name} imports {imported}")

    assert not offenders, (
        "deterministic/ must not depend on ai/: " + "; ".join(offenders)
    )


def test_only_provider_module_reads_vendor_credentials():
    """API keys belong in exactly one module.

    A second module reading `OPENAI_API_KEY` directly would mean a stage could
    reach a vendor without going through the provider abstraction — the thing
    that makes swapping providers a config change.
    """
    offenders = []
    for package in ("ai", "deterministic", "pipeline"):
        for path in _modules_in(package):
            if path.name == "provider.py":
                continue
            text = path.read_text(encoding="utf-8")
            if "OPENAI_API_KEY" in text or "OLLAMA_BASE_URL" in text:
                offenders.append(path.name)

    assert not offenders, (
        "vendor credentials/URLs may only be read in ai/provider.py; found in: "
        + ", ".join(offenders)
    )


def test_pipeline_holds_no_prompts():
    """Orchestration decides order and durability, never meaning.

    A prompt appearing in pipeline/ means an AI stage's behaviour is defined
    outside the package that owns AI behaviour.
    """
    offenders = []
    for path in _modules_in("pipeline"):
        text = path.read_text(encoding="utf-8")
        if "_INSTRUCTION" in text or "You extract" in text or "Reply with JSON" in text:
            offenders.append(path.name)

    assert not offenders, "prompts belong in ai/, found in: " + ", ".join(offenders)


def test_downstream_stages_read_the_profile_not_raw_resume_text():
    """The Candidate Knowledge Profile is the canonical object.

    `resume_understanding` builds it from raw text, and `claim_extraction`
    needs the source document to gate claims against. Every stage after those
    — question planning, and the interview / evidence-linking / reporting
    stages to come — must take the profile instead, so improving how a
    candidate is understood stays a one-stage change.

    Checked by signature: a downstream stage taking a `resume_text` parameter
    has bypassed the profile.
    """
    upstream = {"__init__.py", "provider.py", "knowledge_profile.py",
                "resume_understanding.py", "claim_extraction.py"}
    # evidence_linking.py and report_generation.py take a `QuestionPlan` and
    # a list of already-gated `EvidenceLink`s, never `resume_text` — they are
    # downstream by the same rule, just not listed as an exception to it.
    offenders = []

    for path in _modules_in("ai"):
        if path.name in upstream:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                args = [a.arg for a in node.args.args + node.args.kwonlyargs]
                if "resume_text" in args or "document_text" in args:
                    offenders.append(f"{path.name}:{node.name}")

    assert not offenders, (
        "stages after resume_understanding must read the CandidateKnowledgeProfile, "
        "not raw resume text; found: " + ", ".join(offenders)
    )


def test_every_ai_stage_imports_the_grounding_gate():
    """Any AI stage emitting factual claims about a person must ground them.

    Exemptions and why:
      - provider.py         transport; returns raw model output for a stage
                             to gate, produces no claim of its own
      - knowledge_profile.py data shapes only, no model call
      - coverage_manager.py bookkeeping over decisions other stages already
                             made and already gated; makes no model call and
                             asserts no new fact about the candidate
      - interview.py         generates question PHRASING, not a claim about
                             the candidate — restricted to a plan topic's
                             already-grounded material instead (see
                             test_interview_only_references_grounded_topic_material)
      - evidence_linking.py  reshapes the event log into links; every fact in
                             a link was already gated when the answer that
                             produced it was analyzed
      - report_generation.py reshapes evidence_linking's output; same reason
    Every other module in ai/ produces a claim or an inference and must call
    the gate.
    """
    exempt = {
        "__init__.py",
        "provider.py",
        "knowledge_profile.py",
        "coverage_manager.py",
        "interview.py",
        "evidence_linking.py",
        "report_generation.py",
    }
    missing = []
    for path in _modules_in("ai"):
        if path.name in exempt:
            continue
        if "grounding" not in path.read_text(encoding="utf-8"):
            missing.append(path.name)

    assert not missing, (
        "AI stages must pass output through deterministic/grounding.py; "
        "missing in: " + ", ".join(missing)
    )
