# CogniHire — ACM Computing Surveys format

Written to the format supplied by the project guide: Bilal et al., *Impact of
Intelligent Technologies on IoV Security*, ACM Comput. Surv. 58(15), Art. 385.

## Files

| File | Contents |
|---|---|
| `paper.tex` | Preamble, front matter, sections 1-2, `\input`s the rest |
| `sec03_04.tex` | Landscape and regulation; evidence grounding |
| `sec05_07.tex` | ML; DL; synergistic integration |
| `sec08_10.tex` | Deployment; future directions; conclusion; statements |
| `references.bib` | 15 entries, each verified against a primary source |
| `figures/` | 21 figures as PDF (vector) and PNG |
| `figures.py` | Regenerates the 16 diagrams |
| `PLAN.md` | Template analysis and the build plan |

## Build

```bash
cd docs/paper-acm
pdflatex paper && bibtex paper && pdflatex paper && pdflatex paper
```

Requires the `acmart` class (`tlmgr install acmart`, or build on Overleaf).

**Not compile-tested** — no TeX toolchain was available on the machine where this
was written. Structure is validated (balanced braces and environments, no
dangling refs, no orphan citations, all figures present); expect one round of
minor build fixes.

## Format match

| | Template | This paper |
|---|---|---|
| Sections | 10 | 10 |
| Figures | 16 | 21 |
| Tables | 18 | 23 |
| References | 214 | 15 verified |

The reference count is the deliberate gap. `ML_REDESIGN.md` records that
fabricated citations have already been caught in this project once, so every
entry here was fetched and read first. Reaching 214 would require either months
of reading or invention; padding was not an option considered.

## Regenerating figures

```bash
service/.venv/Scripts/python.exe docs/paper-acm/figures.py
```

The four result plots (`fig1`, `fig2`, `fig4`, `fig5`) come from
`docs/paper/figures/` and are produced by `service/ml/make_figures.py`.
