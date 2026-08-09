"""Diagnostics: how much signal is actually in this dataset, and where?

Ran because feature engineering hit a wall — 1 feature scored 0.642 AUC and
10 features over 5x the data scored 0.657. When more information barely
moves a number, the next move is to find out what the data can support
before fitting anything else against it.

Three questions:
  1. Label consistency — does the same (resume, JD) pair ever carry
     conflicting labels? That sets a hard ceiling nothing can beat.
  2. Resume-only baseline — can you predict the label from the resume alone,
     ignoring the job description entirely? High = the label is mostly "is
     this a strong resume", not "does it match this posting".
  3. JD-only baseline — same question from the other side.
"""

from __future__ import annotations

from collections import Counter, defaultdict

from ml.resume_fit.data import _binarize


def main() -> int:
    from datasets import load_dataset

    ds = load_dataset("cnamuangtoun/resume-job-description-fit")
    train, test = ds["train"], ds["test"]

    # --- 1. Conflicting labels on identical pairs -------------------------
    pair_labels = defaultdict(set)
    for row in list(train) + list(test):
        key = (row["resume_text"], row["job_description_text"])
        pair_labels[key].add(_binarize(row["label"]))
    conflicting = sum(1 for labels in pair_labels.values() if len(labels) > 1)
    print(f"[diag] unique pairs: {len(pair_labels)}, "
          f"pairs with conflicting labels: {conflicting}")

    # --- 2. Resume-only baseline -----------------------------------------
    # Learn each resume's majority label in train, apply it to test. Only
    # scored on test resumes actually seen in train.
    resume_votes = defaultdict(Counter)
    for row in train:
        resume_votes[row["resume_text"]][_binarize(row["label"])] += 1

    hits = total = unseen = 0
    for row in test:
        votes = resume_votes.get(row["resume_text"])
        if not votes:
            unseen += 1
            continue
        predicted = votes.most_common(1)[0][0]
        hits += predicted == _binarize(row["label"])
        total += 1
    print(f"[diag] resume-only baseline (ignores the job description entirely): "
          f"{hits / total:.4f} on {total} rows ({unseen} test rows had an unseen resume)")

    # --- 3. JD-only baseline ---------------------------------------------
    jd_votes = defaultdict(Counter)
    for row in train:
        jd_votes[row["job_description_text"]][_binarize(row["label"])] += 1
    hits = total = unseen = 0
    for row in test:
        votes = jd_votes.get(row["job_description_text"])
        if not votes:
            unseen += 1
            continue
        predicted = votes.most_common(1)[0][0]
        hits += predicted == _binarize(row["label"])
        total += 1
    if total:
        print(f"[diag] jd-only baseline: {hits / total:.4f} on {total} rows "
              f"({unseen} test rows had an unseen JD)")
    else:
        print(f"[diag] jd-only baseline: not computable — all {unseen} test "
              "job descriptions are unseen in train (this is the intended split)")

    # --- 4. How consistent is a single resume's label across postings? ----
    # If a resume is labeled 'fit' for every posting it appears with, the
    # label is a property of the resume, not of the match.
    per_resume = defaultdict(set)
    for row in list(train) + list(test):
        per_resume[row["resume_text"]].add(_binarize(row["label"]))
    single = sum(1 for v in per_resume.values() if len(v) == 1)
    print(f"[diag] resumes whose label never varies across postings: "
          f"{single}/{len(per_resume)} ({single / len(per_resume):.1%})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
