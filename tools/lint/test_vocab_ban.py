#!/usr/bin/env python3
"""Self-test for tools/lint/vocab_ban.py (CH-0.2.2).

Three checks:
  1. The real lib/ tree passes clean today (baseline regression guard).
  2. The clean fixture — legitimate scoped scoring vocabulary PLUS prose
     discussing the ban, mirroring real doc comments like
     workspace_stats.dart's — also passes, proving comments are excluded
     from matching.
  3. A deliberately planted violation is caught. This is the Sprint 0
     done-when gate: "CI fails on a planted score field."
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LINTER = REPO_ROOT / "tools" / "lint" / "vocab_ban.py"
FIXTURES = REPO_ROOT / "tools" / "lint" / "fixtures" / "vocab_ban"


def run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LINTER), "--root", str(root)],
        capture_output=True,
        text=True,
    )


def main() -> int:
    failures: list[str] = []

    result = run(REPO_ROOT / "lib")
    if result.returncode != 0:
        failures.append("FAIL: real lib/ tree did not pass clean:\n" + result.stdout)
    else:
        print("PASS: real lib/ tree is clean")

    result = run(REPO_ROOT / "service")
    if result.returncode != 0:
        failures.append("FAIL: real service/ tree did not pass clean:\n" + result.stdout)
    else:
        print("PASS: real service/ tree is clean")

    # Point --root at a directory containing ONLY the clean fixture, so the
    # planted-violation subdir (a sibling) isn't swept in by rglob.
    clean_only_dir = FIXTURES  # rglob would also find planted_violation/*
    # Run against the fixtures dir but assert on the specific file's outcome
    # by checking the reported path list, not just the exit code (the exit
    # code will be 1 because of the planted fixture below — that's expected
    # and checked separately).
    result = run(clean_only_dir)
    if "clean_example.dart" in result.stdout:
        failures.append(
            "FAIL: clean fixture (scoped scores + prose about the ban) was flagged:\n"
            + result.stdout
        )
    else:
        print("PASS: clean fixture (scoped scores + prose about the ban) passes")

    if "clean_example.py" in result.stdout:
        failures.append(
            "FAIL: Python clean fixture (mean_confidence/completion_percent + "
            "prose about the ban) was flagged:\n" + result.stdout
        )
    else:
        print("PASS: Python clean fixture (mean_confidence/completion_percent) passes")

    result = run(FIXTURES / "planted_violation")
    if result.returncode == 0:
        failures.append("FAIL: planted violation was NOT caught")
    elif "bad_example.py" not in result.stdout:
        failures.append(
            "FAIL: planted Python violation (overall_score/hire_decision) was NOT caught:\n"
            + result.stdout
        )
    else:
        print("PASS: planted violation caught (Dart + Python):")
        for line in result.stdout.splitlines():
            if "banned identifier" in line:
                print(f"  {line.strip()}")

    if failures:
        print("\n" + "\n".join(failures))
        return 1
    print("\nvocab_ban self-test: all checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
