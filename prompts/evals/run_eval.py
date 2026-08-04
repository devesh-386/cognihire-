#!/usr/bin/env python3
"""Eval gate for the interview agent's turn contract.

Checks model outputs against the declarative assertions in
interview_agent_eval.json. Stdlib only, no network: you supply the model's
outputs in a responses file, so the gate runs in CI without Ollama.

    # capture responses however you like (see prompts/README.md), then:
    python run_eval.py --eval interview_agent_eval.json --responses responses.json
    python run_eval.py --eval interview_agent_eval.json --responses responses.json --json

Responses file: {"<case id>": {"say": ..., "kind": ..., ...}, ...}
A missing case counts as a failure, never a skip.

Exit 0 when every case passes, 1 on any failure or malformed output.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

KINDS = {"followup", "probe", "newtopic", "warmup", "clarify", "close"}
ACK_OPENERS = ("i see", "interesting", "got it", "great", "nice", "makes sense")


def contract_errors(out: dict) -> list[str]:
    """Shape violations that make an output unusable regardless of the case."""
    errs = []
    required = ["say", "kind", "quote", "difficulty_delta", "covered", "why"]
    for key in required:
        if key not in out:
            errs.append(f"missing key {key!r}")
    if errs:
        return errs

    # Key order is load-bearing: the stream parser forwards `say` to TTS before
    # the rest of the object has arrived, which only works if it serialises first.
    if next(iter(out)) != "say":
        errs.append(f"'say' must be the first key, got {next(iter(out))!r}")

    if not isinstance(out["say"], str) or not out["say"].strip():
        errs.append("say must be a non-empty string")
    if out["kind"] not in KINDS:
        errs.append(f"kind {out['kind']!r} not in {sorted(KINDS)}")
    if not isinstance(out["quote"], str):
        errs.append("quote must be a string")
    if out["difficulty_delta"] not in (-1, 0, 1):
        errs.append(f"difficulty_delta {out['difficulty_delta']!r} not in -1/0/+1")
    if not isinstance(out["covered"], list):
        errs.append("covered must be an array")
    if not isinstance(out["why"], str) or not out["why"].strip():
        errs.append("why must be a non-empty string")

    # A spoken dash is fine ("groups - or something custom"); a bullet is not.
    say = out.get("say", "")
    if re.search(r"(^|\n)\s*([-*#•]\s|\d+\.\s)", say) or "**" in say:
        errs.append("say contains markup or a list; it is read aloud verbatim")
    return errs


def candidate_text(case: dict) -> str:
    return " ".join(
        t["text"] for t in case["transcript"] if t["role"] == "candidate"
    )


def check(case: dict, out: dict) -> list[str]:
    fails = contract_errors(out)
    if fails:
        return fails

    a = case.get("assert", {})
    say, quote = out["say"], out["quote"]

    if "kind_in" in a and out["kind"] not in a["kind_in"]:
        fails.append(f"kind {out['kind']!r} not in {a['kind_in']}")

    if a.get("quote_empty") and quote != "":
        fails.append(f"quote must be empty for this turn, got {quote[:40]!r}")

    if a.get("quote_in_transcript"):
        spoken = candidate_text(case)
        if not quote:
            fails.append("quote is empty but this turn must be grounded")
        elif quote not in spoken:
            # The whole grounding gate: selected, never authored.
            fails.append(f"quote not verbatim in transcript: {quote[:60]!r}")

    if "delta" in a and out["difficulty_delta"] != a["delta"]:
        fails.append(
            f"difficulty_delta {out['difficulty_delta']} != expected {a['delta']}"
        )

    if "max_words" in a:
        n = len(say.split())
        if n > a["max_words"]:
            fails.append(f"say is {n} words, limit {a['max_words']}")

    for bad in a.get("forbid_substrings", []):
        if bad.lower() in say.lower():
            fails.append(f"say contains forbidden text {bad!r}")

    if "covered_subset" in a:
        allowed = set(a["covered_subset"])
        extra = set(out["covered"]) - allowed
        if extra:
            fails.append(f"covered has unexpected ids {sorted(extra)}")
        if allowed and not set(out["covered"]):
            fails.append(f"covered is empty, expected one of {sorted(allowed)}")

    if a.get("single_question") and say.count("?") > 1:
        fails.append(f"say asks {say.count('?')} questions; one per turn")

    if a.get("no_repeat_asked"):
        norm = lambda s: re.sub(r"[^a-z ]", "", s.lower()).split()
        for prev in case["state"].get("asked_texts", []):
            prev_words, say_words = set(norm(prev)), set(norm(say))
            if prev_words and len(prev_words & say_words) / len(prev_words) > 0.7:
                fails.append(f"say repeats an already-asked question: {prev!r}")

    if case["state"].get("turns_since_ack", 9) < 3:
        if say.lower().lstrip().startswith(ACK_OPENERS):
            fails.append("say opens with an acknowledgment too soon after the last")

    return fails


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--eval", required=True, type=Path)
    p.add_argument("--responses", required=True, type=Path)
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args()

    spec = json.loads(args.eval.read_text(encoding="utf-8"))
    responses = json.loads(args.responses.read_text(encoding="utf-8"))

    results = []
    for case in spec["cases"]:
        out = responses.get(case["id"])
        if out is None:
            results.append({"id": case["id"], "pass": False,
                            "failures": ["no response captured for this case"]})
            continue
        fails = check(case, out)
        results.append({"id": case["id"], "pass": not fails, "failures": fails})

    passed = sum(r["pass"] for r in results)
    total = len(results)

    if args.json:
        print(json.dumps({"passed": passed, "total": total, "cases": results},
                         indent=2))
    else:
        for r in results:
            mark = "PASS" if r["pass"] else "FAIL"
            print(f"[{mark}] {r['id']}")
            for f in r["failures"]:
                print(f"         {f}")
        print(f"\n{passed}/{total} cases passed")

    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
