---
title: "CogniHire IEEE Paper — Response to Review"
author: "Devesh S V, Department of Computer Science and Engineering, SRM Institute of Science and Technology"
date: "24 September 2026"
---

# Summary

Thank you for the detailed review. Every comment has been addressed in the revised paper. New material comes from the project's own code and saved results; one new experiment was run (a prompt-injection evaluation, comment 4). The paper is 6 pages with 29 references, and it compiles without errors or bitmap fonts.

While answering comment 2, the check against the code found one real gap: the web report showed the mean model confidence across answers, a single number a recruiter could read as a score. That figure has now been removed from the system itself (report service and portal), and the paper records the change in its Limitations section.

Section, table and figure numbers below refer to the revised paper.

# Notes in the text

| Your note | Change made | Where |
|---|---|---|
| Fig. 1 looks incomplete | Redrawn to show the complete path, ending at the human reviewer, with braces marking where DL, grounding and ML operate | Fig. 1 |
| Some words in italics; remove bold | All emphasis bold and italics removed from the body. Italics remain only for IEEE run-in paragraph headings and the two terms being defined in Definition 1, and journal names in the references, as IEEE style requires. (The bold abstract is set by the IEEE template itself.) | Throughout |
| Introduce every table and figure in the text before it appears | Every table and figure is now introduced by a sentence stating what it shows, placed before the float | Throughout |
| Fig. 2 lacks clarity | Redrawn as four numbered checks, each with an example of what it rejects | Fig. 2 |
| Fig. 3 (gate results): improve clarity | Replaced by a compact table of the three results before and after the fix | Table IV |
| Fig. 4 (per-fold results) not clear | Redrawn larger from the raw per-fold data; the text and caption now explain how to read the box plots | Fig. 3 |
| At least 20 references | 29 references, all cited in the text, including statistics methods, hallucination, prompt injection, face-analysis bias and the embedding and language models used | References |

# Review comments

| # | Comment | Response | Where |
|---|---|---|---|
| 1 | State which mechanisms are novel | The introduction now says the audit-not-score philosophy is a design stance, not the novelty, and lists three specific novel mechanisms: the assertion-scoped grounding gate, the value-free result type for failed measurements, and the within-query diagnostic. The other contributions are labeled empirical. | Sec. I |
| 2 | Clarify the ML role and whether outputs can become a hidden score | New Table III lists every component output, whether it is deployed, what reaches the recruiter, and whether it can act as a hidden score. Verdicts are set by a person, and no model sets one. The sufficiency model is diagnostic only: it is fitted on synthetic data, and the code cannot present it as a finding about a real person. The fit classifiers are not deployed. Identity is a presence gate whose mismatches are logged for review. The one aggregate that could act as a score, a mean-confidence figure in the web report, has been removed from the system. | Sec. III, Table III, Sec. VII |
| 3 | Define selection versus generation | Formal Definition 1: a claim is selected only if it matches a single-clause span of the resume exactly, up to case and whitespace, and the rest of that clause has no negation or hedge. Anything else is generation and is discarded. | Sec. IV-A |
| 4 | No prompt-injection evaluation | New evaluation: 20 injection templates at 3 positions in 24 real resumes (1,440 documents), with a fully compromised model that obeys every injection. 0 of 1,800 fabricated claims were admitted. Text the attacker writes into the resume can become a claim to be questioned, but never a verdict; this limit is stated. | Sec. IV-C, Table V |
| 5 | Dataset card has no licence or labeling procedure | Stated explicitly. The labels are treated as an unvalidated proxy, and the benchmark is used only diagnostically. | Sec. V-A |
| 6 | Pair generation and effective sample size | The pairs are the dataset's own (8,000 pairs; 6,241 train / 1,759 test), then binarized, class-balanced and pooled into 7,910 pairs. Each resume appears in 12.3 pairs on average and each posting in 22.5. All significance tests are computed over fold-level scores, not rows; the within-resume binomial test was replaced by a fold-level sign test. | Sec. V-A, Table VII |
| 7 | Label validity (80.6% within-resume) | Clarified: 19.4% of label variance lies between resumes, enough for a resume-only model to score 0.660. This is why the within-resume diagnostic is needed. | Sec. V-C |
| 8 | End-to-end example across grounding, ML and DL | A worked example follows one claim, "Built REST APIs in Django…", through extraction, grounding, interview, answer analysis, identity checks and the reviewer's verdict. Fig. 1 now marks each family's layer. | Sec. III, Fig. 1 |
| 9 | Terminology table | New Table II defines claim, evidence, measurement, signal, verdict, audit and screening. | Table II |
| 10 | End-to-end processing cost | Measured costs added: claim extraction takes a median 12.1 s per resume and the grounding gate 1.1 ms per claim. Interview-stage costs were not measured, and the paper says so. | Sec. V-D |
| 11 | Separate demonstrated findings from proposed benefits | The conclusion now has two explicit parts: what is demonstrated by measurement, and what is proposed but not yet demonstrated. | Sec. VIII |

# Other corrections found during revision

| Correction | Where |
|---|---|
| The hedge example "some exposure to Kafka" was wrong: the gate does not reject it. Replaced with "possibly used Kafka", which it does. | Sec. IV-A |
| The +0.041 AUROC comparison mixed two models; the same-model figure is +0.048. | Sec. V-C |
| The split-scheme table used 8,000 unbalanced rows, unlike every other experiment; this is now stated. | Sec. V-D |
| The legal table cited the wrong EU AI Act provisions and overstated HB 3773; it now cites Arts. 12, 14 and 86. | Sec. VII |
| Figures rebuilt as vector graphics, removing the bitmap fonts that IEEE PDF eXpress rejects. | All figures |

# Second review (7.8/10, major revision)

This review was of the earlier 8-page version. Several points were already fixed by the 6-page revision: figures reduced, the legal table folded into text, and grouped-by-resume validation reported. The remaining points were addressed as follows. Items that need new data are stated as limitations, not claimed as done.

| Point raised | Change made | Where |
|---|---|---|
| Novelty against related techniques unclear | New comparison table: RAG, citation/provenance generation, hallucination detection, extractive IE, injection filtering, and the gate | Sec. II, Table I |
| Meaning and use of model confidence | Stated: per-answer confidence in [0, 1], used only to trigger a follow-up below 0.6; not calibrated; never aggregated | Sec. VII, Limitations |
| 100% gate results overstated | Qualified to the synthetic generator's patterns, not arbitrary real phrasing | Sec. IV-B |
| Regulatory claims read as compliance | Reworded to "architectural correspondence"; legal compliance stated as out of scope | Sec. VII |
| Rhetorical or anecdotal wording | Opening anecdote and the audit anecdote about another system removed; "overwhelmingly" softened in the abstract | Abstract, Sec. I, Sec. VII |
| Metrics not defined | AUROC, ECE, FAR and FRR defined where first used | Sec. V-B, Sec. VI |
| EER threshold choice and LFW pair counts | Explained: EER is used because no validated cost ratio exists; the 2,200 and 1,000 pairs are LFW's development train and test splits | Sec. VI |
| Leakage across entities | Grouped-by-resume score (0.703) reported; fully entity-disjoint folds listed as future work | Sec. V-D |
| No ablation, real attacks, end-to-end validation, reviewer study or demographic face evaluation | Each listed explicitly as a limitation or a future-work item | Sec. VII, Sec. VIII |
| Reproducibility | Code and results are available on request; a public repository link can be added before camera-ready | Data Availability |

Adding the comparison table renumbered the tables: the old Tables I–VII are now II–VIII.

# Formatting

The paper is set in A4 and fits the 6-page limit. All text is in Times; the monospace terms were replaced with ordinary text, and the accented spelling of "resume" is replaced by the plain form throughout. To fit 6 pages, four secondary figures and tables (learning curve, latency plot, split-scheme table, cost table) and the regulatory mapping table were folded into the text; every result they reported is still stated.
