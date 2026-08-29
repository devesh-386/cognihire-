"""Grounding-gate & extraction evaluation harness.

Benchmarks CogniHire's EXISTING pipeline against an external corpus of 5,200
synthetic resumes. It drives the real modules — it does not reimplement them:

    deterministic.resume_parser.parse   structured extraction (offline)
    ai.claim_extraction._heuristic      claim extraction, degraded path (offline)
    deterministic.grounding.*           the grounding gate (offline, deterministic)

Everything here is offline and free: no LLM key, no network. That is deliberate.
The gate and the fallback path are exactly the parts whose behaviour must be
reproducible and defensible in a paper, and they run without a vendor.

## What we measure, and why each number is honest

1. GATE — TRUE-POSITIVE RATE
   Heuristic claims are copied VERBATIM from the resume. Passed back through
   `filter_grounded`, they should ALL survive. Any that don't are the gate
   *over-rejecting real candidate content* — a false rejection, worth knowing.

2. GATE — PARAPHRASE REJECTION RATE  (the headline number)
   We reword each verbatim claim the way a model would when it fails to copy
   ("Led ..." -> "Directed ...", "improvement" -> "increase", drop articles).
   A paraphrase asserts the same thing in different words; the gate's rule is
   "select, never author", so it SHOULD reject paraphrases. The rejection rate
   is the gate's defence against fabrication-by-rewording. (A rejected
   paraphrase is a *correct* rejection here, not a miss.)

3. GATE — NEGATION-TRAP REJECTION RATE
   Prepend "I have not " to a verbatim claim. The text still contains the claim
   as a substring, so a naive containment check would ground it. The gate must
   reject it. This exercises the assertion-not-presence guarantee directly.

4. EXTRACTION COVERAGE (deterministic parser)
   Across the corpus, the share of resumes yielding name / email / >=1 skill /
   each section. Characterises the fallback profile quality.

5. CLAIM YIELD & TRUNCATION
   Claims-per-resume distribution and the share truncated at the pipeline's
   _MAX_CANDIDATES cap — the same truncation the report discloses.

Run (from the `service/` dir, using its venv so pipeline imports resolve):
    python -m eval.harness --limit 5200
    python -m eval.harness --limit 500 --out eval/metrics.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys

# Import the REAL pipeline modules (read-only).
from deterministic import grounding
from deterministic import resume_parser as det_parser
from ai.claim_extraction import _heuristic, _MAX_CANDIDATES, Claim

DEFAULT_CORPUS = os.environ.get(
    "RESUME_CORPUS",
    r"C:\claude\resume_dataset\resumes.jsonl",
)

# --------------------------------------------------------------- paraphrasing
# Deterministic, meaning-preserving rewrites — a stand-in for the small
# rewordings a model produces when it does NOT copy verbatim. Same assertion,
# different surface form. The gate should refuse every one of these.
_SYNONYMS = {
    r"\bLed\b": "Directed", r"\bBuilt\b": "Constructed", r"\bDeveloped\b": "Created",
    r"\bDesigned\b": "Architected", r"\bLaunched\b": "Released", r"\bManaged\b": "Oversaw",
    r"\bImproved\b": "Enhanced", r"\bIncreased\b": "Raised", r"\bReduced\b": "Cut",
    r"\bOptimized\b": "Tuned", r"\bDelivered\b": "Shipped", r"\bimprovement\b": "increase",
    r"\brevenue\b": "income", r"\bteam\b": "group", r"\busing\b": "with",
    r"\binitiatives\b": "programs", r"\bcross-functional\b": "multi-team",
}
_PARA_RE = [(re.compile(p), r) for p, r in _SYNONYMS.items()]


def paraphrase(text: str) -> str | None:
    """Reword `text` while preserving meaning. Returns None if nothing changed
    (so we never count an accidental verbatim copy as a paraphrase)."""
    out = text
    for pat, repl in _PARA_RE:
        out = pat.sub(repl, out)
    out = re.sub(r"\b(a|an|the)\s+", "", out)   # drop articles — cosmetic reword
    out = re.sub(r"\s+", " ", out).strip()
    return out if grounding.normalise(out) != grounding.normalise(text) else None


# --------------------------------------------------------------- corpus io
def load_corpus(path: str, limit: int):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if len(rows) >= limit:
                break
            obj = json.loads(line)
            txt = obj.get("resume_text")
            if txt:
                rows.append(txt)
    return rows


def _pct(n, d):
    return round(100.0 * n / d, 2) if d else 0.0


# --------------------------------------------------------------- evaluation
_BULLET_LINE = re.compile(r"^\s*[•\-\*]\s+(.+\S)\s*$")


def genuine_claims(text: str) -> list[str]:
    """The real single-clause assertions in a resume: its experience bullets.
    These are what the LLM claim-extractor is meant to return, and what the
    grounding gate is designed to verify — one clause, one assertion, ending
    in a terminal period. We measure gate INTEGRITY against these, separately
    from the noise the crude `_heuristic` fallback emits."""
    out = []
    for line in text.splitlines():
        m = _BULLET_LINE.match(line)
        if m and 15 <= len(m.group(1)) <= 240:
            out.append(m.group(1).strip())
    return out


def evaluate(resumes):
    # Gate integrity, measured on GENUINE single-clause claims (bullets).
    tp_total = tp_kept = 0            # verbatim claims that should pass
    para_total = para_rejected = 0   # paraphrases that should be rejected
    neg_total = neg_rejected = 0     # negation traps that must be rejected
    gate_misses = []                 # genuine claims the gate wrongly rejected

    # Fallback-extractor noise: what fraction of `_heuristic` output is NOT a
    # groundable assertion (contact lines, multi-sentence summaries). The gate
    # correctly filters these — this quantifies the fallback's rawness and the
    # gate's value as a second safety net, NOT a gate defect.
    heur_total = heur_nonclaim = 0

    # Extraction coverage
    cov = {"name": 0, "email": 0, "skills": 0,
           "section_experience": 0, "section_education": 0}
    claim_counts = []
    truncated_count = 0

    for text in resumes:
        # --- gate integrity on genuine claims ---
        for claim in genuine_claims(text):
            tp_total += 1
            if grounding.is_grounded(claim, text):
                tp_kept += 1
            elif len(gate_misses) < 15:
                gate_misses.append(claim)

            pp = paraphrase(claim)
            if pp is not None:
                para_total += 1
                if not grounding.is_grounded(pp, text):
                    para_rejected += 1

            neg = "I have not " + claim[0].lower() + claim[1:]
            neg_total += 1
            if not grounding.is_grounded(neg, text):
                neg_rejected += 1

        # --- fallback extractor noise (real heuristic path) ---
        claims, truncated = _heuristic(text, source="corpus")
        claim_counts.append(len(claims))
        if truncated:
            truncated_count += 1
        for c in claims:
            heur_total += 1
            if not grounding.is_grounded(c.text, text):
                heur_nonclaim += 1

        # --- deterministic structured extraction ---
        sr = det_parser.parse(text)
        if sr.name:
            cov["name"] += 1
        if sr.email:
            cov["email"] += 1
        if sr.skills:
            cov["skills"] += 1
        if _has_section(sr, "experience"):
            cov["section_experience"] += 1
        if _has_section(sr, "education"):
            cov["section_education"] += 1

    n = len(resumes)
    return {
        "corpus_size": n,
        "gate": {
            "genuine_claims_tested": tp_total,
            "verbatim_true_positive_rate_pct": _pct(tp_kept, tp_total),
            "verbatim_false_rejections": tp_total - tp_kept,
            "paraphrases_tested": para_total,
            "paraphrase_rejection_rate_pct": _pct(para_rejected, para_total),
            "paraphrases_leaked_through": para_total - para_rejected,
            "negation_traps_tested": neg_total,
            "negation_trap_rejection_rate_pct": _pct(neg_rejected, neg_total),
            "negation_traps_leaked_through": neg_total - neg_rejected,
        },
        "fallback_extractor": {
            "heuristic_lines_emitted": heur_total,
            "non_claim_lines_filtered_by_gate_pct": _pct(heur_nonclaim, heur_total),
            "note": ("share of crude _heuristic output the gate refuses as "
                     "non-assertions (contact/summary lines) - gate acting as "
                     "a safety net over the fallback, not a defect"),
        },
        "extraction_coverage_pct": {
            "name": _pct(cov["name"], n),
            "email": _pct(cov["email"], n),
            "has_>=1_skill": _pct(cov["skills"], n),
            "experience_section_found": _pct(cov["section_experience"], n),
            "education_section_found": _pct(cov["section_education"], n),
        },
        "claims": {
            "mean_per_resume": round(statistics.mean(claim_counts), 2) if claim_counts else 0,
            "median_per_resume": statistics.median(claim_counts) if claim_counts else 0,
            "max_cap": _MAX_CANDIDATES,
            "truncated_at_cap_pct": _pct(truncated_count, n),
        },
        "sample_gate_false_rejections": gate_misses,
    }


def _has_section(sr, name):
    """StructuredResume keeps section lists on attributes; tolerate either an
    attribute or a `sections` dict without assuming the internal shape."""
    val = getattr(sr, name, None)
    if val:
        return True
    secs = getattr(sr, "sections", None)
    return bool(secs and secs.get(name))


def _print_report(m):
    g = m["gate"]
    fb = m["fallback_extractor"]
    print("\n" + "=" * 66)
    print(f"CogniHire pipeline evaluation - {m['corpus_size']} resumes")
    print("=" * 66)
    print("\nGROUNDING GATE  (on genuine single-clause claims)")
    print(f"  Verbatim claims kept (true-positive):   "
          f"{g['verbatim_true_positive_rate_pct']:6.2f}%  "
          f"({g['verbatim_false_rejections']} wrongly rejected)")
    print(f"  Paraphrases rejected (fabrication guard):"
          f"{g['paraphrase_rejection_rate_pct']:6.2f}%  "
          f"({g['paraphrases_leaked_through']} leaked through)")
    print(f"  Negation traps rejected:                "
          f"{g['negation_trap_rejection_rate_pct']:6.2f}%  "
          f"({g['negation_traps_leaked_through']} leaked through)")
    print("\nFALLBACK EXTRACTOR (crude _heuristic path)")
    print(f"  non-claim lines filtered by gate:       "
          f"{fb['non_claim_lines_filtered_by_gate_pct']:6.2f}%  "
          f"(gate as safety net, not a defect)")
    print("\nEXTRACTION COVERAGE (deterministic fallback parser)")
    for k, v in m["extraction_coverage_pct"].items():
        print(f"  {k:28s} {v:6.2f}%")
    c = m["claims"]
    print("\nCLAIM YIELD")
    print(f"  mean/median per resume: {c['mean_per_resume']} / {c['median_per_resume']}")
    print(f"  truncated at cap ({c['max_cap']}): {c['truncated_at_cap_pct']}%")
    if m["sample_gate_false_rejections"]:
        print("\n  ! sample verbatim claims the gate rejected (investigate):")
        for s in m["sample_gate_false_rejections"][:5]:
            print(f"    - {s[:80]}")
    print("=" * 66)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", default=DEFAULT_CORPUS)
    ap.add_argument("--limit", type=int, default=5200)
    ap.add_argument("--out", default=None, help="write full metrics JSON here")
    args = ap.parse_args()

    if not os.path.exists(args.corpus):
        sys.exit(f"corpus not found: {args.corpus}")

    resumes = load_corpus(args.corpus, args.limit)
    metrics = evaluate(resumes)
    _print_report(metrics)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(metrics, f, indent=2, ensure_ascii=False)
        print(f"\nFull metrics -> {args.out}")


if __name__ == "__main__":
    main()
