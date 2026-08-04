#!/usr/bin/env python3
"""Self-test for tools/lint/evidence_disposition_schema.py (CH-0.2.1).

Three checks:
  1. Real infra/ tree passes clean (no migrations exist yet, per the
     backlog's own dependency order — Epic 4/5 introduce them).
  2. The clean fixture pair (an evidence table with a normal same-plane FK,
     a self-contained disposition table with no FK at all) passes.
  3. A planted violation — a disposition table with a FOREIGN KEY into an
     evidence-plane table via `claim_audit_id` — is caught. This is the
     Sprint 0 done-when gate: "CI fails ... on a planted evidence<->
     disposition join."
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LINTER = REPO_ROOT / "tools" / "lint" / "evidence_disposition_schema.py"
FIXTURES = REPO_ROOT / "tools" / "lint" / "fixtures" / "ed_boundary"


def run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LINTER), "--root", str(root)],
        capture_output=True,
        text=True,
    )


def main() -> int:
    failures: list[str] = []

    result = run(REPO_ROOT / "infra")
    if result.returncode != 0:
        failures.append("FAIL: real infra/ tree did not pass clean:\n" + result.stdout)
    else:
        print("PASS: real infra/ tree is clean (no migrations exist yet)")

    result = run(FIXTURES / "clean")
    if result.returncode != 0:
        failures.append("FAIL: clean fixture pair was flagged:\n" + result.stdout)
    else:
        print("PASS: clean fixture pair (evidence FK + self-contained disposition) passes")

    result = run(FIXTURES / "planted_violation")
    if result.returncode == 0:
        failures.append("FAIL: planted evidence<->disposition join was NOT caught")
    else:
        print("PASS: planted evidence<->disposition join caught:")
        for line in result.stdout.splitlines():
            if "claim_audit_id" in line or "forbidden join" in line:
                print(f"  {line.strip()}")

    if failures:
        print("\n" + "\n".join(failures))
        return 1
    print("\nevidence_disposition_schema self-test: all checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
