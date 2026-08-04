#!/usr/bin/env python3
"""CH-0.2.2 — vocabulary-ban linter (ED-46), enforcing ED-03 and ED-04.

ED-03: no composite score — enforced by the absence of a field, not by
policy. ED-04: no hire/no-hire training labels — the system has no path to
the dataset that trains biased hiring models.

This linter scans source files for identifiers that would reintroduce either
concept: a composite/aggregate/overall "score" field, or a hire/no-hire
decision field.

## Why a blocklist of compound identifiers, not the bare word "score"

The codebase legitimately uses "score" ~74 times today — similarity scores,
calibration scores, per-claim sufficiency scores, biometric FAR/FRR scores.
All of those are honest, scoped, per-measurement values; none of them is a
composite judgement about a person. Banning the substring "score" would
false-positive on all of them and teach engineers to ignore the linter.

What ED-03 actually forbids is a *composite* — one number standing in for a
whole candidate. The blocklist below targets that shape of identifier
specifically (overallScore, hireScore, compositeScore, ...), plus ED-04's
hire/no-hire decision vocabulary. A name not on this list is not
automatically safe; a name matching it is presumptively a violation, unless a
reviewer explicitly widens the list with a documented reason (never silently
narrows it).

## Why comments are stripped before matching

Several existing files *document* these exact bans in prose — e.g.
`workspace_stats.dart`: "There is no overall score, no per-candidate
ranking, no hiring score". Matching raw text would make the linter fire on
the very comments that explain the guarantee it enforces. This linter
strips `//`, `///`, and `/* */` comments before scanning, so it checks code
identifiers only.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Directories to scan. Extend this list as new services are added (backend
# DTOs, SQL migrations) — do not silently narrow it.
SCAN_ROOTS = [REPO_ROOT / "lib"]
SCAN_GLOBS = ["*.dart"]

# Compound identifiers that reintroduce a composite score (ED-03) or a
# hire/no-hire decision (ED-04). Case-insensitive, word-boundary matched
# against identifier-shaped tokens only (see IDENTIFIER_RE).
BANNED_TERMS = [
    # ED-03 — composite score
    "overallScore", "compositeScore", "aggregateScore", "totalScore",
    "finalScore", "hiringScore", "candidateScore", "rankingScore",
    "matchScore", "fitScore", "overallRating", "compositeRating",
    "aggregateRating", "hireabilityScore",
    # ED-04 — hire/no-hire decision or training label
    "hireDecision", "noHireDecision", "shouldHire", "willHire",
    "recommendHire", "hireRecommendation", "autoHire", "autoReject",
    "hireable", "hireability", "passFail", "hireNoHire", "hireOrNoHire",
]

# Matches identifier-shaped tokens (camelCase, PascalCase, snake_case) so we
# compare whole names, not substrings buried in unrelated words.
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# Strips block comments, then line comments (including /// doc comments),
# leaving strings/code intact. Good enough for a linter over Dart source —
# not a full parser, but sufcient to separate "code identifiers" from "prose
# explaining what does not exist".
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"//.*")


def strip_comments(source: str) -> str:
    source = BLOCK_COMMENT_RE.sub("", source)
    source = LINE_COMMENT_RE.sub("", source)
    return source


def banned_set() -> set[str]:
    return {t.lower() for t in BANNED_TERMS}


def find_violations(path: Path) -> list[tuple[int, str]]:
    """Return (line_number, identifier) for every banned identifier found in
    the CODE (comments stripped) of `path`. Line numbers are computed
    against the comment-stripped text mapped back to original line numbers
    via a per-line pass, so reported line numbers stay accurate for the
    original file.
    """
    banned = banned_set()
    violations: list[tuple[int, str]] = []
    text = path.read_text(encoding="utf-8")

    # Strip comments per-line-preserving-newlines so line numbers stay
    # aligned with the original file (important for actionable CI output).
    stripped = BLOCK_COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    for line_no, line in enumerate(stripped.splitlines(), start=1):
        code_only = LINE_COMMENT_RE.sub("", line)
        for match in IDENTIFIER_RE.finditer(code_only):
            token = match.group(0)
            if token.lower() in banned:
                violations.append((line_no, token))
    return violations


def main(argv: list[str]) -> int:
    """--root <dir> may be repeated to override SCAN_ROOTS (used by the
    self-test in tools/lint/test_vocab_ban.py to point the scanner at
    fixture files instead of the real lib/ tree)."""
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
        for glob in SCAN_GLOBS:
            for path in root.rglob(glob):
                violations = find_violations(path)
                if violations:
                    all_violations[path] = violations

    if all_violations:
        print("Vocabulary-ban linter (ED-46 / ED-03 / ED-04): VIOLATIONS FOUND\n")
        for path, violations in sorted(all_violations.items()):
            try:
                rel = path.relative_to(REPO_ROOT)
            except ValueError:
                rel = path
            for line_no, token in violations:
                print(f"  {rel}:{line_no}: banned identifier `{token}`")
        print(
            "\nThese identifiers reintroduce a composite score (ED-03) or a "
            "hire/no-hire decision (ED-04). Remove the field, or if this is "
            "a deliberate, reviewed exception, widen tools/lint/vocab_ban.py's "
            "BANNED_TERMS list with a comment explaining why."
        )
        return 1

    print("Vocabulary-ban linter (ED-46 / ED-03 / ED-04): clean.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
