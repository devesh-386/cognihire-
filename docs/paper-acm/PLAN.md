# Build plan — CogniHire paper in the ACM Computing Surveys format

Target format: `3816144.pdf` — Bilal et al., *Impact of Intelligent Technologies on IoV
Security: Integrating Edge Computing and AI*, ACM Comput. Surv. 58(15), Art. 385, Nov 2026.
Supplied by the project guide as the required format.

---

## 1. What the template actually is

| Property | Reference | CogniHire target |
|---|---|---|
| Genre | Survey (no original experiments) | Systematisation **+** original system and experiments |
| Pages | 35 (27 body + 8 refs) | ~30–35 |
| Body words | ~14,200 | ~14,000 |
| References | **214** (527 in-text markers, ~19/page) | **60–90 verified** — see §5 |
| Figures | **16** | **21** (16 new diagrams + 5 existing result plots) |
| Tables | **18** | **18** |
| Sections | 10, three numbering levels | 10, same depth |
| Class | `acmart`, LuaLaTeX | `acmart` |

### Signature conventions to replicate exactly

1. **Fig. 2** — org-chart of the paper's own structure, one coloured box per section and
   subsection. Distinctive; the guide will look for it.
2. **Table 1** — prior-work comparison: `Ref (Year)` rows, ✓/✗ capability columns, `Focus`,
   `Gaps`, `Improvements in This Work`, final row literally **`This Work (2026)`**, plus a
   footnote legend defining symbols (⊕ / ∗ / ‡ / †).
3. **Key Research Questions** — a numbered list of 8, in §1.
4. **Structure of the Paper** — prose paragraph cross-referencing every section.
5. Per-technology rhythm: taxonomy → representative-models table → integration figure →
   recent advancements → open challenges table.
6. Tables carry a `Refs` column and synthesise prior work.
7. Research gaps as em-dash bullets with *italic* lead-ins.

---

## 2. Section mapping

| Ref § | CogniHire § | Primary source material |
|---|---|---|
| 1 Introduction | 1 Introduction | `PAPER.md` §1, `RESEARCH_PAPER.md` §1–3 |
| 2 Related Works | 2 Related Works | `PAPER.md` §2, new literature sweep |
| 3 IoV Arch/Threats/Trends | 3 Automated Hiring: Architecture, Failure Landscape, Regulatory Trends | `RESEARCH_PAPER.md` §2, §4; `blueprint/` |
| 4 EC as Enabler | 4 **Evidence Grounding** as an Enabler | `RESEARCH_PAPER.md` §5.3, §8.4; `prompts/README.md` |
| 5 ML Techniques | 5 **ML for Candidate Screening** | `PAPER.md` §5–6 (nine-model benchmark, all diagnostics) |
| 6 Deep Learning | 6 **DL Components** | `RESEARCH_PAPER.md` §8.2 (LFW calibration); `ML_REDESIGN.md` §2.1–2.4 |
| 7 Synergistic Integration | 7 Synergistic Integration of Grounding + ML + DL | `ML_REDESIGN.md` §3; `MODULES.md` |
| 8 Deployment Experiences | 8 Deployment Experiences and Lessons | `REFERENCE_AUDIT.md`, `RESEARCH_PAPER.md` §8.6, §10 |
| 9 Future Directions | 9 Future Directions | `RESEARCH_PAPER.md` §11; `ML_REDESIGN.md` §14 |
| 10 Conclusion | 10 Conclusion | synthesis |

**"Wherever it talks about multiple models, talk about multiple models."** §5 carries this
twice over: a literature table in the reference's style (their Table 8), *and* our own
nine-model benchmark with significance testing — original evidence the template has no
equivalent of.

---

## 3. Figure manifest (21)

New diagrams to build (16):

| # | Figure | Type | Mirrors |
|---|---|---|---|
| 1 | CogniHire data flow and component interactions | layered flow | their Fig. 1 |
| 2 | **Overview of the paper structure** | org chart | their Fig. 2 |
| 3 | Taxonomy of automated-hiring technologies and key publications | tree | their Fig. 3 |
| 4 | Literature review methodology (six-stage screening) | PRISMA-style flow | their Fig. 4 |
| 5 | Layered architecture of CogniHire (four surfaces) | stack | their Fig. 5 |
| 6 | Failure landscape in automated hiring | taxonomy | their Fig. 6 |
| 7 | Distribution of failure modes in deployed screening tools | bar chart | their Fig. 7 |
| 8 | Regulatory timeline: LL144, HB 3773, EU AI Act | timeline chart | their Fig. 8 |
| 9 | Standards and compliance practices in automated hiring | process graphic | their Fig. 9 |
| 10 | Evidence-grounding gate architecture | block diagram | their Fig. 10 |
| 11 | Grounding data flow: extraction → gate → audit | flow | their Fig. 11 |
| 12 | Evolution of ML in candidate screening | timeline | their Fig. 12 |
| 13 | ML algorithm families and their screening roles | mapping | their Fig. 13 |
| 14 | Multi-tier ML integration architecture | tiered | their Fig. 14 |
| 15 | DL architectures in the identity pipeline | block | their Fig. 15 |
| 16 | Integrated grounding–ML–DL feedback loop | loop | their Fig. 16 |

Existing result plots to reuse (5): convergence-and-power, representation ablation,
matching isolation, efficiency Pareto, learning curve.

---

## 4. Table manifest (18)

| # | Table | Content |
|---|---|---|
| 1 | Comparison of existing hiring-AI work and gaps | **signature** — ✓/✗ matrix ending in `This Work (2026)` |
| 2 | Automated-hiring failure modes, manifestations, implications | |
| 3 | Traditional vs current screening solutions | |
| 4 | Key advantages of evidence grounding | |
| 5 | Integrity features enabled by grounding + real applications | |
| 6 | Future grounding technologies and their impact | |
| 7 | ML paradigms for candidate screening | |
| 8 | ML-based studies in résumé/candidate screening | literature, `Refs` column |
| 9 | **Nine-model benchmark results** | original — AUROC, accuracy, F1, ECE, latency, size |
| 10 | DL architectures: advantages, limitations, use cases | |
| 11 | Challenges, impacts, solutions for DL-based screening | |
| 12 | Key metrics before vs after integration | LFW threshold 0.50 → 0.1266; FRR 0.414 → 0.034 |
| 13 | Key barriers and concise solutions | |
| 14 | Mapping ML/DL mechanisms to compliance functions | LL144, HB 3773, EU AI Act |
| 15 | Case studies: entities, tech, core impacts | |
| 16 | DL application domains in screening | |
| 17 | Lessons learned from deployment | draws on `REFERENCE_AUDIT.md` |
| 18 | Research areas: core challenges and key questions | |

---

## 5. The citation constraint — read this

The template carries **214 references**. The current experimental paper has 10.

`ML_REDESIGN.md` §0 records that **fabricated primary research has already been caught in
this project once**, and mandates that every citation be fetched and read before use. That
rule holds here without exception.

Consequently:

- Every reference will be retrieved and verified against a primary source before it enters
  the bibliography.
- A realistic verified total is **60–90**, built up across several working passes.
- **214 will not be reached**, and the gap will not be closed by padding, by citing work not
  read, or by inventing entries.

A paper with 80 verified references is a real paper. A paper with 214 references of which
130 were invented is misconduct, and it is the specific failure this project has already
been burned by once. If the guide requires a higher count, the honest route is more reading
time, not more entries.

---

## 6. Work sequence

1. **Skeleton** — `paper.tex` in `acmart` with all 10 sections and full subsection depth.
2. **Figures** — generate the 16 new diagrams programmatically (matplotlib), reuse 5 plots.
3. **Tables** — 18, drawing on existing verified results wherever possible.
4. **Body** — ~14,000 words, section by section.
5. **References** — verified in batches; bibliography grows as the sweep proceeds.
6. **Validation** — structural check, number cross-check against JSON reports, figure/label audit.

Output directory: `docs/paper-acm/`. The existing `docs/paper/` study is left intact; it
remains the standalone arXiv submission and is the source for §5.
