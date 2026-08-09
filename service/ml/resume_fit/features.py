"""Feature extraction for the resume<->job-fit model.

The first version of this model used a single feature — cosine similarity
between two whole-document embeddings — and scored 0.642 AUC / 59.8%
accuracy. One blurry number cannot distinguish "right domain, wrong
seniority" from "genuinely a good fit", so this module adds structure the
classifier can actually learn from.

## A constraint this dataset imposes

The dataset's own train/test split is by **job description**: the test fold
contains 71 job descriptions that appear nowhere in train, while 476 of its
477 resumes DO appear in train. That makes it an honest "can this model
handle a new job posting" test, but it also means any feature keyed to a
resume's identity (its length, its raw embedding, a resume-only statistic)
lets the model memorize which resumes tend to be labeled fit and score well
without understanding matching at all.

Every feature here is therefore a *relational* one — computed between the
resume and the job description, never from either alone. That is a
deliberate accuracy sacrifice in exchange for a number that means what it
claims to mean.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Sequence

import numpy as np

# Words carrying no matching signal — without this, every resume/JD pair
# shares "and"/"the"/"experience" and the overlap features compress toward a
# constant.
_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have",
    "in", "is", "it", "its", "of", "on", "or", "our", "that", "the", "to", "was",
    "were", "will", "with", "you", "your", "we", "us", "this", "these", "those",
    "they", "their", "them", "he", "she", "his", "her", "i", "me", "my", "all",
    "can", "not", "but", "if", "then", "than", "so", "such", "who", "which",
    "what", "when", "where", "how", "any", "each", "more", "most", "other",
    "some", "only", "own", "same", "also", "up", "out", "about", "into", "over",
    "work", "working", "job", "role", "team", "company", "position", "candidate",
    "must", "should", "would", "may", "including", "etc",
}

_TOKEN_RE = re.compile(r"[a-z][a-z0-9+#.]{1,}")

# Seniority ladder — the single most common way a resume can look topically
# perfect and still be a bad fit. Ordered, so a distance is meaningful.
_SENIORITY_TERMS = {
    "intern": 0, "internship": 0, "trainee": 0,
    "junior": 1, "entry": 1, "associate": 1, "graduate": 1,
    "mid": 2, "intermediate": 2,
    "senior": 3, "sr": 3, "lead": 4, "principal": 5, "staff": 4,
    "manager": 4, "director": 5, "head": 5, "vp": 6, "chief": 6, "executive": 6,
}

_YEARS_RE = re.compile(r"(\d{1,2})\s*\+?\s*(?:years?|yrs?)")


def tokenize(text: str) -> list[str]:
    return [t for t in _TOKEN_RE.findall(text.lower()) if t not in _STOPWORDS and len(t) > 2]


@dataclass(frozen=True)
class DocumentStats:
    """Corpus-level statistics used to weight rare terms. Fitted on TRAIN
    ONLY and then applied to test — computing IDF over the combined corpus
    would leak test-fold term distributions into training."""

    idf: dict[str, float]

    @staticmethod
    def fit(documents: Sequence[str]) -> "DocumentStats":
        n = len(documents)
        document_frequency: dict[str, int] = {}
        for doc in documents:
            for token in set(tokenize(doc)):
                document_frequency[token] = document_frequency.get(token, 0) + 1
        idf = {
            token: math.log((n + 1) / (df + 1)) + 1.0
            for token, df in document_frequency.items()
        }
        return DocumentStats(idf=idf)

    def weight(self, token: str) -> float:
        # An unseen token is rare by definition — give it the weight of a
        # term seen once rather than zero, which would silently ignore
        # exactly the specific skills that matter most.
        return self.idf.get(token, math.log(len(self.idf) + 1) + 1.0 if self.idf else 1.0)


def _max_seniority(tokens: Sequence[str]) -> int | None:
    levels = [_SENIORITY_TERMS[t] for t in tokens if t in _SENIORITY_TERMS]
    return max(levels) if levels else None


def _max_years(text: str) -> int | None:
    matches = [int(m) for m in _YEARS_RE.findall(text.lower())]
    # Cap: "20+ years" and "30 years" are the same signal, and uncapped
    # values let one outlier dominate a standardized feature.
    return min(max(matches), 25) if matches else None


FEATURE_NAMES = [
    "embedding_cosine",
    "token_jaccard",
    "idf_weighted_coverage",
    "jd_term_coverage",
    "rare_term_overlap",
    "seniority_gap",
    "seniority_known",
    "years_gap",
    "years_known",
    "length_ratio",
]


def extract(
    *,
    resume_text: str,
    job_description_text: str,
    embedding_cosine: float,
    stats: DocumentStats,
) -> list[float]:
    """One feature vector for one (resume, job description) pair.

    Every value is relational — see the module docstring for why nothing
    here may be computed from the resume alone.
    """
    resume_tokens = tokenize(resume_text)
    jd_tokens = tokenize(job_description_text)
    resume_set, jd_set = set(resume_tokens), set(jd_tokens)

    shared = resume_set & jd_set
    union = resume_set | jd_set

    jaccard = len(shared) / len(union) if union else 0.0

    # How much of what the JD *asks for* does the resume actually cover,
    # weighted so a rare, specific skill counts far more than a common word.
    jd_weight_total = sum(stats.weight(t) for t in jd_set)
    shared_weight = sum(stats.weight(t) for t in shared)
    idf_coverage = shared_weight / jd_weight_total if jd_weight_total > 0 else 0.0

    # Unweighted version of the same idea — the two disagree in useful ways
    # when a JD is mostly boilerplate.
    jd_coverage = len(shared) / len(jd_set) if jd_set else 0.0

    # Restricted to genuinely rare terms — the specific technologies and
    # certifications that most separate a real match from a topical one.
    rare_shared = [t for t in shared if stats.weight(t) > 3.0]
    rare_jd = [t for t in jd_set if stats.weight(t) > 3.0]
    rare_overlap = len(rare_shared) / len(rare_jd) if rare_jd else 0.0

    resume_seniority = _max_seniority(resume_tokens)
    jd_seniority = _max_seniority(jd_tokens)
    if resume_seniority is None or jd_seniority is None:
        seniority_gap, seniority_known = 0.0, 0.0
    else:
        # Signed: a candidate below the asked-for level is a different
        # problem from one far above it, and the model should be able to
        # learn that asymmetry rather than see one absolute distance.
        seniority_gap, seniority_known = float(resume_seniority - jd_seniority), 1.0

    resume_years = _max_years(resume_text)
    jd_years = _max_years(job_description_text)
    if resume_years is None or jd_years is None:
        years_gap, years_known = 0.0, 0.0
    else:
        years_gap, years_known = float(resume_years - jd_years), 1.0

    # Relational, not a raw resume length: how verbose is the resume
    # relative to the posting it is answering.
    length_ratio = (
        len(resume_tokens) / len(jd_tokens) if jd_tokens else 0.0
    )
    length_ratio = min(length_ratio, 10.0)

    return [
        embedding_cosine,
        jaccard,
        idf_coverage,
        jd_coverage,
        rare_overlap,
        seniority_gap,
        seniority_known,
        years_gap,
        years_known,
        length_ratio,
    ]


def to_matrix(rows: Sequence[Sequence[float]]) -> np.ndarray:
    return np.asarray(rows, dtype=float)
