# CogniHire pipeline evaluation — findings

Harness: `service/eval/harness.py`. Corpus: 5,200 synthetic resumes
(`C:\claude\resume_dataset\resumes.jsonl`), 8 fields × 4 seniority levels.
Offline, deterministic, no LLM key. Drives the real pipeline modules
(`deterministic.resume_parser`, `ai.claim_extraction._heuristic`,
`deterministic.grounding`) read-only.

Reproduce:
```
cd service && ./.venv/Scripts/python.exe -m eval.harness --limit 5200 --out eval/metrics.json
```

## Headline results (5,200 resumes)

| Metric | Result | Reading |
|---|---|---|
| Paraphrase rejection rate | **100.00%** (0 / 48,149 leaked) | Gate refuses every meaning-preserving reword — "select, never author" holds |
| Negation-trap rejection rate | **100.00%** (0 / 51,761 leaked) | "I have not …" + a real claim refused despite verbatim substring — assertion-not-presence holds |
| Verbatim true-positive rate | **99.18%** (425 / 51,761 wrongly rejected) | **One reproducible false-rejection bug — see below** |
| Fallback non-claim lines filtered by gate | 25.05% of 41,600 | Gate is a real safety net over the crude `_heuristic` path |
| Extraction coverage (name/email/skill/exp/edu) | 100% each | Deterministic parser handles this resume format fully |

The defensible paper claim is **not** "100% extraction accuracy" (a
synthetic-data artifact). It is: *the grounding gate rejected 100% of
model-style paraphrases and negation traps across ~100k trials while admitting
99.18% of verbatim claims* — a robustness statement about the safety mechanism.

## BUG (RESOLVED): dotted skill tokens (`Node.js`) were wrongly rejected by the gate

**Status:** fixed in `deterministic/grounding.py::_CLAUSE_BOUNDARY` (terminal
punctuation now counts as a clause boundary only when followed by whitespace or
end-of-string, so a `.` between two word characters no longer splits a token).
Regression tests added to `test_grounding.py`. After the fix, on the same 5,200
resumes: verbatim true-positive **99.18% → 100.00%** (425 → 0 wrongly rejected);
paraphrase rejection **100%** and negation-trap rejection **100%** unchanged;
full suite **412 passed**. Post-fix metrics: `eval/metrics_after.json`.

Original analysis follows.



- **All 425** false rejections contain `Node.js`. **Zero** rejections occur
  without a dotted token.
- **Cause:** `deterministic/grounding.py::_clauses` splits clauses on `[.!?]+`.
  The `.` inside `Node.js` manufactures a clause boundary, so
  `"...using JavaScript, Node.js."` is split into `"...using JavaScript, Node"`
  + `"js."`. `locate` requires the match to sit inside a **single** clause, so
  the claim is never found and `is_grounded` returns `False`.
- **Minimal repro:**
  ```python
  from deterministic import grounding
  doc = "• Developed X using JavaScript, Node.js."
  grounding.is_grounded("Developed X using JavaScript, Node.js.", doc)  # -> False
  grounding.is_grounded("Developed X using JavaScript, Kubernetes.", doc)  # -> True
  ```
- **Impact in production:** any candidate whose resume bullet names a
  period-bearing technology — `Node.js`, `React.js`, `asp.net`, `U.S.`, a
  version like `Python 3.9` — has that claim silently dropped before the
  interview. It is never asked about. This is a coverage/fairness defect, not a
  safety one (it over-rejects, never over-admits), which is why paraphrase and
  negation guards still read 100%.
- **Fix direction (needs its own review — this is the core safety module):**
  make `_CLAUSE_BOUNDARY` not treat a `.` as terminal when it sits between two
  word characters (`\w\.\w`), i.e. only split on `.` followed by whitespace/end.
  Add a regression test with a `Node.js` bullet. Do **not** loosen the
  negation/hedge scope while doing so.

## Caveats (state these in any writeup)

- Corpus is synthetic and uniform (every resume has exactly 8 bullet claims,
  hence `truncated_at_cap 100%` and median 8). Coverage numbers reflect this
  one clean format, not messy real-world PDFs.
- The AI stages (`resume_understanding`, LLM `claim_extraction`,
  `question_planning`, `answer_analysis`) are **not** exercised here — they need
  a provider key. This harness measures the deterministic gate and fallback,
  which are the reproducible, free-to-run parts. A `--live` sampling mode over
  the real LLM path is the natural next addition.
