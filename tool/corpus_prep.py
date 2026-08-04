"""Turn the Kaggle resume CSV into a JSONL sample the Dart harness can read.

    python tool/corpus_prep.py --csv "C:/Users/dev/Downloads/Resume/Resume.csv" \
        --out tool/corpus/sample.jsonl --per-category 5

## Why this exists rather than parsing CSV in Dart

The corpus ships as a 56MB CSV whose `Resume_str` fields contain embedded
newlines and quotes. Parsing that correctly needs a real CSV reader, and adding
a `csv` package dependency to the app's pubspec — for a one-off offline
evaluation — would put a dependency in the shipped app that the shipped app
never uses. Python already has the reader in its standard library, so the
conversion happens here and `tool/corpus_eval.dart` reads JSONL with
`dart:convert` and no new dependency.

## What it will not do

It does not clean, normalise, or repair the resume text. The whole point of the
exercise is to find out what the real pipeline does with real input, and a
sampler that tidied its input first would be measuring a corpus that does not
exist. The text goes through byte-for-byte.

Every exclusion is counted and printed. A sampler that silently dropped rows
would make the pipeline look better than it is.
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import random
import sys
from pathlib import Path

# The dataset has rows whose entire "resume" is a fragment — the shortest is 21
# characters. Those are not resumes and measuring extraction against them tells
# us about the corpus, not the extractor. They are excluded *and counted*.
MIN_CHARS = 200


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument(
        "--per-category",
        type=int,
        default=5,
        help="resumes sampled per category (stratified). 0 = take everything.",
    )
    ap.add_argument(
        "--categories",
        default="",
        help="comma-separated category filter, e.g. INFORMATION-TECHNOLOGY,ENGINEERING",
    )
    ap.add_argument(
        "--seed",
        type=int,
        default=20260731,
        help="fixed so a rerun samples the same resumes and results stay comparable",
    )
    args = ap.parse_args()

    csv.field_size_limit(10**9)

    wanted = {c.strip().upper() for c in args.categories.split(",") if c.strip()}

    by_category: dict[str, list[dict]] = collections.defaultdict(list)
    too_short = 0
    filtered_out = 0
    total = 0

    with args.csv.open(encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            total += 1
            category = (row.get("Category") or "UNKNOWN").strip()
            if wanted and category.upper() not in wanted:
                filtered_out += 1
                continue
            text = row.get("Resume_str") or ""
            if len(text.strip()) < MIN_CHARS:
                too_short += 1
                continue
            by_category[category].append(
                {"id": row.get("ID", ""), "category": category, "text": text}
            )

    rng = random.Random(args.seed)
    sample: list[dict] = []
    for category in sorted(by_category):
        rows = by_category[category]
        rows.sort(key=lambda r: r["id"])  # deterministic before shuffling
        rng.shuffle(rows)
        sample.extend(rows if args.per_category == 0 else rows[: args.per_category])

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as fh:
        for row in sample:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    lengths = sorted(len(r["text"]) for r in sample)
    print(f"read          {total} rows from {args.csv}")
    if wanted:
        print(f"filtered out  {filtered_out} (not in --categories)")
    print(f"excluded      {too_short} shorter than {MIN_CHARS} chars")
    print(f"sampled       {len(sample)} across {len(by_category)} categories")
    if lengths:
        print(
            f"chars         min {lengths[0]}  "
            f"median {lengths[len(lengths) // 2]}  max {lengths[-1]}"
        )
    print(f"wrote         {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
