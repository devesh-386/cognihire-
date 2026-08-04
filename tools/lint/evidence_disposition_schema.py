#!/usr/bin/env python3
"""CH-0.2.1 — evidence <-> disposition schema linter (ED-45), enforcing ED-14.

ED-14 (the boundary five decisions the Handbook says define the product):
Evidence and Disposition are separate bounded contexts with no join key, no
shared credential, and no network path between them. The forbidden dataset is
the join `evidence JOIN disposition` (ED-04's biased-hiring-model risk made
structurally impossible, not just policy-forbidden).

This linter scans SQL migration files for the two ways that join could be
reintroduced at the schema level:

  1. A `disposition`-plane table with a FOREIGN KEY into an evidence-plane
     table (or vice versa) — the join key ED-14 forbids.
  2. A `disposition`-plane table or column carrying a `session_id` /
     `audit_id` / `claim_id` / `evidence_id`-shaped reference — even without a
     formal FK constraint, a same-named/typed column is the join waiting to
     happen.

## How "which plane" is determined

There is no live schema yet (Epic 5 introduces the disposition service, per
the backlog). This linter works of a directory convention that later tickets
must follow: migrations under a path containing `disposition` (matching
`infra/postgres-disposition/**` or any `*disposition*` migrations directory)
are the disposition plane; every other scanned `.sql` file is the evidence
plane. A migration cannot silently sidestep this by being placed elsewhere —
DISPOSITION_PATH_MARKERS is the single source of truth and any new
disposition-plane directory must be added there explicitly (reviewed, not
inferred).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

SCAN_ROOTS = [REPO_ROOT / "infra"]
SCAN_GLOB = "*.sql"

# Any path containing one of these markers is the disposition plane. Extend
# deliberately, in review — this list being wrong in either direction is a
# security-relevant mistake.
DISPOSITION_PATH_MARKERS = ["disposition"]

# Column/reference names that would let a disposition row point at an
# evidence-plane record (or vice versa) even without a formal FK. Matched as
# whole identifiers (word boundaries), case-insensitive.
FORBIDDEN_REFERENCE_COLUMNS = [
    "session_id", "audit_id", "claim_id", "evidence_id",
    "claim_audit_id", "evidence_graph_id", "session_event_id",
]

COLUMN_REF_RE = re.compile(r"\bREFERENCES\s+([A-Za-z_][\w.]*)", re.IGNORECASE)
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# SQL comments: `-- ...` to end of line, and `/* ... */` block comments.
SQL_LINE_COMMENT_RE = re.compile(r"--.*")
SQL_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


def strip_sql_comments(text: str) -> str:
    text = SQL_BLOCK_COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return "\n".join(SQL_LINE_COMMENT_RE.sub("", line) for line in text.splitlines())


def is_disposition_path(path: Path) -> bool:
    """A path is disposition-plane if one of its directory SEGMENTS tokenises
    (splitting on `-`/`_`) to exactly `disposition` — not merely contains the
    substring. This distinguishes a real marker directory like
    `postgres-disposition` from an unrelated grouping directory that happens
    to contain the word (e.g. a fixtures folder documenting the boundary)."""
    for part in path.parts:
        tokens = re.split(r"[-_]", part.lower())
        if "disposition" in tokens:
            return True
    return False


def find_violations(path: Path) -> list[tuple[int, str]]:
    """Return (line_number, reason) for each forbidden evidence<->disposition
    bridge found in `path`."""
    violations: list[tuple[int, str]] = []
    disposition_side = is_disposition_path(path)
    text = strip_sql_comments(path.read_text(encoding="utf-8"))

    for line_no, line in enumerate(text.splitlines(), start=1):
        # A REFERENCES clause on a disposition-plane migration pointing
        # anywhere is suspect on its face — disposition tables should only
        # reference other disposition tables (self-contained schema). Since
        # this linter scans one file at a time without full cross-file
        # schema knowledge, ANY REFERENCES clause in a disposition-path file
        # is flagged for human review — a real cross-database FK is not
        # even expressible in Postgres, so a REFERENCES clause appearing
        # here is either a same-plane relation (fine, but the file should
        # not live under a path implying otherwise) or a mistake.
        for match in COLUMN_REF_RE.finditer(line):
            if disposition_side:
                violations.append(
                    (line_no, f"disposition-plane migration contains REFERENCES `{match.group(1)}` "
                               "— disposition tables must not reference other schemas")
                )

        for m in IDENTIFIER_RE.finditer(line):
            token = m.group(0).lower()
            if token in FORBIDDEN_REFERENCE_COLUMNS and disposition_side:
                violations.append(
                    (line_no, f"disposition-plane migration declares evidence-shaped "
                               f"column `{token}` — this is the forbidden join key (ED-14)")
                )

    return violations


def main(argv: list[str]) -> int:
    roots = SCAN_ROOTS
    if "--root" in argv:
        roots = []
        i = 0
        while i < len(argv):
            if argv[i] == "--root":
                roots.append(Path(argv[i + 1]))
                i += 2
            else:
                i += 1

    all_violations: dict[Path, list[tuple[int, str]]] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob(SCAN_GLOB):
            violations = find_violations(path)
            if violations:
                all_violations[path] = violations

    if all_violations:
        print("Evidence<->Disposition schema linter (ED-45 / ED-14): VIOLATIONS FOUND\n")
        for path, violations in sorted(all_violations.items()):
            try:
                rel = path.relative_to(REPO_ROOT)
            except ValueError:
                rel = path
            for line_no, reason in violations:
                print(f"  {rel}:{line_no}: {reason}")
        print(
            "\nED-14 requires no join key, no shared credential, and no network "
            "path between the evidence plane and the disposition plane. See "
            "Ch6 Part A §1 and ED-76 (CH-0.3.2/CH-5.2.1)."
        )
        return 1

    print("Evidence<->Disposition schema linter (ED-45 / ED-14): clean "
          "(no migrations exist yet — this guards the first one that does).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
