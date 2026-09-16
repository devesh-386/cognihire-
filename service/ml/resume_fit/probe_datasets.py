"""Probe candidate replication datasets before committing to one.

The paper's threat-to-validity #1 is that every result rests on a single
benchmark. A replication is only worth running on a corpus that satisfies
three conditions, and most candidates fail at least one:

  1. **Independence.** It must not contain the original. Several public
     resume-fit datasets are derived from or merged with
     `cnamuangtoun/resume-job-description-fit`; replicating on a superset of
     the original measures nothing. We test this directly by hashing the
     text pairs and intersecting.

  2. **Recurring entities.** The within-query diagnostic (paper §6.4) needs
     resumes that appear with several postings, at least one positive and
     one negative. A corpus of 1:1 resume-posting pairs cannot support it at
     all, which rules out most "resume scoring" datasets.

  3. **A usable fit label**, binarisable the same way.

This script reports those three properties for each candidate and makes no
decision. Run it, read the table, then choose.

    python -m ml.resume_fit.probe_datasets
"""

from __future__ import annotations

import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

CANDIDATES = [
    "med2425/resume-job-fit-merged-v1",
    "netsol/resume-score-details",
    "batuhanmtl/job_resume_fit",
    "OlaniyanIsrael/job_resume_fit",
    "aswindhanasekar/job_resume_fit",
    "nonameee12233/job-resume-matching",
]

ORIGINAL = "cnamuangtoun/resume-job-description-fit"

# Column-name guesses; datasets are inconsistent about naming.
RESUME_KEYS = ["resume_text", "resume", "Resume", "cv", "cv_text", "resume_str"]
JD_KEYS = ["job_description_text", "job_description", "jd", "Job Description",
           "job_description_str", "jd_text", "description"]
LABEL_KEYS = ["label", "Label", "fit", "match", "score", "ats_score", "target"]


def _pick(colnames, candidates):
    for c in candidates:
        if c in colnames:
            return c
    # fall back to fuzzy contains
    low = {c.lower(): c for c in colnames}
    for c in candidates:
        for k, orig in low.items():
            if c.lower() in k:
                return orig
    return None


def _h(text: str) -> str:
    return hashlib.sha1(str(text).strip().encode("utf-8", "ignore")).hexdigest()[:16]


def _original_hashes():
    from datasets import load_dataset
    ds = load_dataset(ORIGINAL)
    pairs, resumes = set(), set()
    for split in ds:
        for r in ds[split]:
            pairs.add((_h(r["resume_text"]), _h(r["job_description_text"])))
            resumes.add(_h(r["resume_text"]))
    return pairs, resumes


def probe(name: str, orig_pairs, orig_resumes) -> dict:
    from datasets import load_dataset
    out = {"dataset": name}
    try:
        ds = load_dataset(name)
    except Exception as e:  # noqa: BLE001 - report, never crash the sweep
        out["error"] = f"{type(e).__name__}: {str(e)[:140]}"
        return out

    split = "train" if "train" in ds else list(ds.keys())[0]
    rows = ds[split]
    cols = list(rows.features.keys())
    out["splits"] = {s: len(ds[s]) for s in ds}
    out["columns"] = cols

    rk = _pick(cols, RESUME_KEYS)
    jk = _pick(cols, JD_KEYS)
    lk = _pick(cols, LABEL_KEYS)
    out["mapped"] = {"resume": rk, "jd": jk, "label": lk}
    if not (rk and jk):
        out["verdict"] = "UNUSABLE - no resume/JD pair columns"
        return out

    # Cap the scan; we only need structure, not the whole corpus.
    n = min(len(rows), 20000)
    sub = rows.select(range(n))
    rh = [_h(x) for x in sub[rk]]
    jh = [_h(x) for x in sub[jk]]

    out["scannedRows"] = n
    out["uniqueResumes"] = len(set(rh))
    out["uniquePostings"] = len(set(jh))

    per_resume = defaultdict(list)
    if lk:
        labels = [str(x) for x in sub[lk]]
        out["labelCounts"] = dict(Counter(labels).most_common(8))
        for h, lab in zip(rh, labels):
            per_resume[h].append(lab)
        multi = [v for v in per_resume.values() if len(v) >= 2]
        varying = [v for v in multi if len(set(v)) > 1]
        out["resumesWithMultiplePostings"] = len(multi)
        out["resumesWithVaryingLabel"] = len(varying)
    else:
        out["labelCounts"] = None

    # Contamination against the original.
    pair_set = set(zip(rh, jh))
    out["pairOverlapWithOriginal"] = len(pair_set & orig_pairs)
    out["pairOverlapPct"] = round(100.0 * len(pair_set & orig_pairs) / max(1, len(pair_set)), 2)
    out["resumeOverlapPct"] = round(
        100.0 * len(set(rh) & orig_resumes) / max(1, len(set(rh))), 2)

    # Verdict
    reasons = []
    if out["pairOverlapPct"] > 5:
        reasons.append(f"contaminated ({out['pairOverlapPct']}% pairs shared with original)")
    if not lk:
        reasons.append("no label column")
    if out.get("resumesWithVaryingLabel", 0) < 30:
        reasons.append(f"too few resumes with a varying label "
                       f"({out.get('resumesWithVaryingLabel', 0)}) - within-query test not possible")
    out["verdict"] = "USABLE" if not reasons else "REJECT: " + "; ".join(reasons)
    return out


def main() -> int:
    print(f"[probe] hashing original ({ORIGINAL}) ...")
    orig_pairs, orig_resumes = _original_hashes()
    print(f"[probe] original: {len(orig_pairs)} unique pairs, {len(orig_resumes)} unique resumes\n")

    results = []
    for name in CANDIDATES:
        print(f"[probe] {name} ...")
        r = probe(name, orig_pairs, orig_resumes)
        results.append(r)
        if "error" in r:
            print(f"          ERROR {r['error']}")
        else:
            print(f"          rows={r.get('scannedRows')} "
                  f"resumes={r.get('uniqueResumes')} postings={r.get('uniquePostings')} "
                  f"varyingLabel={r.get('resumesWithVaryingLabel')} "
                  f"overlap={r.get('pairOverlapPct')}%")
            print(f"          cols={r['columns']}")
            print(f"          -> {r['verdict']}")
        print()

    out = Path(__file__).parent / "probe_datasets.report.json"
    out.write_text(json.dumps(results, indent=2))
    print(f"[probe] wrote {out}")

    usable = [r["dataset"] for r in results if r.get("verdict") == "USABLE"]
    print(f"\n[probe] USABLE candidates: {usable if usable else 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
