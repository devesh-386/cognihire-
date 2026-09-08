"""Is `med2425/resume-job-fit-merged-v1` independent of the original?

`probe_datasets.py` reported 0% pair overlap with
`cnamuangtoun/resume-job-description-fit` and passed it as USABLE. That
result is not credible on its face: the scanned slice contains exactly 642
unique resumes and 280 unique postings, which are precisely the counts of
the ORIGINAL dataset's train split. Identical entity cardinality with zero
content overlap is the signature of a false negative --- most likely the
corpus was re-uploaded with normalised whitespace or encoding, so exact
SHA-1 hashes of the raw text no longer collide.

This script settles it three ways:

  1. the dataset's own `source` column, which should name its constituents;
  2. hashing on AGGRESSIVELY normalised text (lowercased, all whitespace
     collapsed, punctuation stripped) rather than raw text;
  3. a prefix check --- first 120 normalised characters --- which survives
     truncation and trailing-content differences that whole-document
     hashing does not.

A replication run on a corpus that contains the original measures nothing,
so this has to be answered before any experiment is worth running.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter

CANDIDATE = "med2425/resume-job-fit-merged-v1"
ORIGINAL = "cnamuangtoun/resume-job-description-fit"

_WS = re.compile(r"\s+")
_PUNCT = re.compile(r"[^a-z0-9 ]+")


def norm(text: str) -> str:
    t = str(text).lower()
    t = _PUNCT.sub(" ", t)
    return _WS.sub(" ", t).strip()


def h(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8", "ignore")).hexdigest()[:16]


def main() -> int:
    from datasets import load_dataset

    print(f"[verify] loading {ORIGINAL} ...")
    orig = load_dataset(ORIGINAL)
    o_res_norm, o_jd_norm, o_pairs = set(), set(), set()
    o_res_prefix = set()
    for split in orig:
        for r in orig[split]:
            rn, jn = norm(r["resume_text"]), norm(r["job_description_text"])
            o_res_norm.add(h(rn))
            o_jd_norm.add(h(jn))
            o_pairs.add((h(rn), h(jn)))
            o_res_prefix.add(rn[:120])
    print(f"[verify] original: {len(o_res_norm)} resumes, {len(o_jd_norm)} postings, "
          f"{len(o_pairs)} pairs (normalised)")

    print(f"[verify] loading {CANDIDATE} ...")
    cand = load_dataset(CANDIDATE)

    # 1. What does its own `source` column say?
    print("\n[verify] --- (1) self-declared source column ---")
    for split in cand:
        rows = cand[split]
        if "source" in rows.features:
            n = min(len(rows), 40000)
            counts = Counter(rows.select(range(n))["source"])
            print(f"[verify] split={split} (first {n} rows): {dict(counts.most_common(10))}")
        else:
            print(f"[verify] split={split}: no `source` column")

    # 2 + 3. Normalised overlap.
    print("\n[verify] --- (2,3) normalised-text overlap ---")
    for split in cand:
        rows = cand[split]
        n = min(len(rows), 40000)
        sub = rows.select(range(n))
        rn = [norm(x) for x in sub["resume"]]
        jn = [norm(x) for x in sub["jd"]]
        rh = [h(x) for x in rn]
        jh = [h(x) for x in jn]
        pairs = set(zip(rh, jh))

        res_ov = len(set(rh) & o_res_norm) / max(1, len(set(rh)))
        jd_ov = len(set(jh) & o_jd_norm) / max(1, len(set(jh)))
        pair_ov = len(pairs & o_pairs) / max(1, len(pairs))
        prefix_ov = len({x[:120] for x in rn} & o_res_prefix) / max(1, len({x[:120] for x in rn}))

        print(f"[verify] split={split} rows={n} "
              f"uniqRes={len(set(rh))} uniqJD={len(set(jh))} uniqPairs={len(pairs)}")
        print(f"           resume overlap (normalised full)  : {res_ov:.1%}")
        print(f"           posting overlap (normalised full) : {jd_ov:.1%}")
        print(f"           PAIR overlap (normalised)         : {pair_ov:.1%}")
        print(f"           resume overlap (120-char prefix)  : {prefix_ov:.1%}")

    print("\n[verify] A high resume/posting overlap means the corpus is built from the "
          "same documents as the original and cannot serve as an independent replication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
