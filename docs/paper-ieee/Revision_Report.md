---
title: "CogniHire IEEE Paper — Revision Report"
subtitle: "Response to review comments"
author: "Devesh S V, Department of Computer Science and Engineering, SRM Institute of Science and Technology"
date: "24 September 2026"
---

# Summary

Following your review, the paper was audited in full: format, figures, references, legal claims, and every number against the saved experimental data. The audit found **22 issues: 7 critical, 10 major and 5 minor.** Twenty-one are fixed in the revised paper. The remaining one, page size, depends on the conference's requirements and is listed under Pending items.

The revised paper is still six pages and compiles without errors. It now contains no bitmap fonts, so it can pass IEEE PDF eXpress. Every experimental result not listed below was recomputed from the raw data and matches exactly.

| Severity | Found | Fixed | Pending |
|---|---|---|---|
| Critical | 7 | 7 | 0 |
| Major | 10 | 9 | 1 |
| Minor | 5 | 5 | 0 |

Table and figure numbers below refer to the version you reviewed. In the revised paper they are renumbered, because old Fig. 3 became a table.

# How the audit was done

1. **Data check.** Every reported number was recomputed from the saved per-fold results and experiment reports in the project repository.
2. **IEEE format check.** The PDF was checked against the IEEE conference template and PDF eXpress rules: page size, embedded fonts, float order, captions, citation order and reference style.
3. **Figure and table check.** Each page was rendered and inspected for legibility, font consistency, overlaps and placement.
4. **Claims check.** Every related-work and legal statement was compared with the cited source.

# Critical issues (all fixed)

| # | Location | Issue | Correction |
|---|---|---|---|
| C1 | Figs. 2, 4, 5 | The figures were raster crops that embedded bitmap (Type 3) fonts. IEEE PDF eXpress rejects these. | All three redrawn as vector graphics directly from the experimental data. |
| C2 | Fig. 2 | Figure text was about 4 pt, below the roughly 8 pt minimum, and could not be read in print. | Redrawn at column width with legible labels. |
| C3 | Table IV, Sec. V-C | The split-scheme experiment used all 8,000 rows without class balancing, while every other experiment uses 7,910 balanced pairs. The text did not say so. | Caption and text now state the 8,000-row, class-weighted setup. |
| C4 | Sec. V-B | "+0.041 pooled AUROC" compared two different models (MLP and random forest). | Same-model comparison reported instead: +0.048 (0.688 to 0.737). The conclusion is unchanged and slightly stronger. |
| C5 | Table VI | The legal mapping overstated the law. Illinois HB 3773 does not create a right to explanation, and human oversight is EU AI Act Art. 14, not Annex III. | Table now cites EU AI Act Arts. 12, 14 and 86 precisely. HB 3773 is cited only for notice and non-discrimination. |
| C6 | Sec. II, ref. [12] | Platt (1999) was cited for threshold calibration, which it does not address. | Citation and reference removed. |
| C7 | References | References were not numbered in order of first citation, as IEEE requires. | Renumbered in citation order. |

# Major issues

| # | Location | Issue | Correction |
|---|---|---|---|
| M1 | Fig. 1 | Full-page-width figure with a panel that repeated Table I. | Redrawn at single-column width. |
| M2 | Fig. 3 | Six bars used to show one change (99.18% to 100%). | Replaced by a compact results table. |
| M3 | Fig. 6 | Labels were too small and overlapped the data points. | Redrawn with readable, non-overlapping labels. |
| M4 | Figs. 4, 6, Table II | Model names were spelled inconsistently. | One naming scheme used throughout. |
| M5 | Figs. 2, 4, 5 | These figures used a sans-serif font; the paper uses Times. | All figures now use the paper's font. |
| M6 | References | The online dataset had no access date; the legal references had no official identifiers. | Access date and official identifiers added. |
| M7 | Sec. III, Table I | Poor justification left large gaps between words. | Reset as a list; table set ragged-right. |
| M8 | Sec. IV-B | One line ran into the margin. | Fixed. |
| M9 | Structure | There was no Future Work. | Section renamed "Conclusion and Future Work", with three concrete next steps. |
| M10 | Page size | US Letter. Many IEEE conferences in India require A4. | **Pending:** to be set once the conference requirement is confirmed. |

# Minor issues (all fixed)

| # | Location | Issue | Correction |
|---|---|---|---|
| m1 | Table V | An empty AUC cell ("—") looked like missing data. | The threshold-independent AUC (0.9785) is now stated once in the text. |
| m2 | Sec. V-B | "p = 0.445" could not be reproduced exactly from the per-fold data. | Reported as p > 0.4; the conclusion is unchanged. |
| m3 | Table II caption | Monospace text inside a small-caps caption. | Plain caption text. |
| m4 | Table VI | A vague "All" in the instrument column. | Specific instrument named. |
| m5 | Sec. VI | "ArcFace" was hyphenated across a line break. | Hyphenation blocked. |

# Results verified as correct

| Result | Source data | Status |
|---|---|---|
| All nine-classifier AUROC, ECE, latency and size values | Per-fold benchmark results | Exact match |
| Friedman and Holm-corrected Wilcoxon tests | Benchmark report | Exact match |
| Synthetic positive control (χ² = 55.42, Bayes-optimal 0.925) | Synthetic benchmark report | Exact match |
| Tuning gain of at most 0.0077 AUROC | Tuning report | Exact match |
| Representation ablation (0.660, 0.755, 87%) and learning curve | Ablation report | Exact match |
| 80.6% within-résumé variance and pairwise accuracies | Matching-isolation report | Exact match |
| Face threshold 0.1266, FAR 0.030, FRR 0.034 | Face calibration report | Exact match |
| Grounding gate: 425 of 51,761 = 0.82% | Arithmetic | Exact match |

All 14 academic references were checked for authors, venue, volume and pages.

# Pending items

1. Confirm the conference's required page size (A4 or US Letter).
2. Confirm the dataset access date in reference [12].
3. Add a public repository link to the Data Availability statement, if the code is to be released.
