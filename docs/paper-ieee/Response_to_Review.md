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
| 4 | No prompt-injection evaluation | New evaluation: 20 injection templates at 3 positions in 24 real resumes (1,440 documents), with a fully compromised model that obeys every injection. 0 of 1,800 fabricated claims were admitted. Text the attacker writes into the resume can become a claim to be questioned, but never a verdict; this limit is stated. | Sec. IV-D, Table VI |
| 5 | Dataset card has no licence or labeling procedure | Stated explicitly. The labels are treated as an unvalidated proxy, and the benchmark is used only diagnostically. | Sec. V-A |
| 6 | Pair generation and effective sample size | The pairs are the dataset's own (8,000 pairs; 6,241 train / 1,759 test), then binarized, class-balanced and pooled into 7,910 pairs. Each resume appears in 12.3 pairs on average and each posting in 22.5. All significance tests are computed over fold-level scores, not rows; the within-resume binomial test was replaced by a fold-level sign test. | Sec. V-A, Table VIII |
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

This review was of the earlier 8-page version. Two new experiments were run for it: a gate ablation on 24 real resumes, and four further injection vectors plus multilingual instructions. New statistics come from the saved per-fold results. One system change was made: the per-answer confidence is no longer shown to reviewers. Points that need data we do not have are stated in the paper as limitations or future work, not claimed as done.

## Major comments

| # | Comment | Response | Where |
|---|---|---|---|
| 1 | Novelty against related techniques | New comparison table covering retrieval-augmented generation, citation/provenance generation, hallucination detection, extractive information extraction, injection filtering and the gate | Sec. II, Table I |
| 2 | 100% grounding is synthetic only | New ablation on 24 independently written real resumes: 950 genuine claims, 947 negation traps, 947 hedge traps, 344 paraphrases and 955 cross-sentence spans, with zero errors. The synthetic 100% is now qualified to the generator's patterns. A large manually annotated benchmark is listed as future work. | Sec. IV-B, IV-C, Table V |
| 3 | ML leakage: resumes shared across folds | Grouped-by-resume validation (0.703 AUROC) is reported. Entity-disjoint cross-validation has not yet been run and is listed as future work. | Sec. V-D, Sec. VIII |
| 4 | Only ten folds; confidence intervals and effect sizes | Added a Friedman effect size (Kendall's W = 0.48), a corrected resampled t-test with Holm correction (no significant pairwise difference from the MLP) and 95% intervals for mean AUROC, all overlapping. Repeated cross-validation is future work. | Sec. V-B |
| 5 | No end-to-end validation | Stated as not demonstrated; end-to-end validation on consented sessions is the first next step | Sec. VII, VIII |
| 6 | No reviewer study | Stated as untested; a controlled reviewer study (agreement, review time, consistency) is planned | Sec. VII, VIII |
| 7 | LFW is not the candidate population | 95% intervals added; face evaluation stratified by demographics, device and lighting is listed as required future work | Sec. VI, VIII |
| 8 | Regulatory claims read as compliance | Reworded to "architectural correspondence"; legal compliance is stated as outside the paper's scope | Sec. VII |
| 9 | Per-answer confidence as a hidden score | The confidence is used only to choose a follow-up question (below 0.6). It is uncalibrated, never aggregated and no longer shown to the reviewer; this was changed in the portal and app during this revision. A follow-up adds evidence but sets no verdict. | Sec. VII, Table III |
| 10 | No ablation | New Table V removes each gate check in turn. Without the negation check all 947 negated and 947 hedged claims are admitted; without clause scoping 38.5% of genuine claims are lost and 565 cross-sentence spans admitted. The import boundary, value-free type and human verdict are structural and are argued rather than ablated. | Sec. IV-C, Table V |
| 11 | Injection beyond text templates | Tested zero-width characters, Cyrillic homoglyphs, split instructions, HTML hidden text and Spanish, Hindi, Chinese and French instructions: 0 fabricated outputs admitted. Image and PDF-metadata vectors are stated as untested. | Sec. IV-D |
| 12 | Dataset provenance | The missing licence and labeling procedure are stated, the labels are treated as an unvalidated proxy, and the benchmark is used only diagnostically | Sec. V-A |
| 13 | Latency incomplete | Extraction and gate timings reported; untimed stages are stated; end-to-end timing is future work | Sec. V-D |
| 14 | Code only on request | Pending the author's decision on a public repository | Data Availability |
| 15 | Rhetorical language | The opening anecdote, the anecdote about another system and "a fallback ... is worse than an outage" were removed; "overwhelmingly" was softened in the abstract | Abstract, Sec. I, Sec. VII |

## Minor comments

| Comment | Response |
|---|---|
| Resume spelling | "resume" is used throughout |
| Define AUROC, ECE, FAR, FRR | Defined at first use |
| Why 0.1266; how the EER sweep selects it | Explained: the equal-error-rate point, because no validated cost ratio between false accepts and false rejects exists |
| Why 2,200 / 1,000 LFW pairs | These are LFW's standard development training and test splits |
| Confidence intervals for face metrics | Wilson 95%: FAR 0.018–0.049, FRR 0.021–0.054 |
| Pair counts per grounding category | Given in Tables IV and V |
| Qwen2.5 4 discarded of 193; manual annotation | The 4 were text the model wrote rather than selected; the 189 admitted claims were not manually annotated, as the paper now states |
| Is confidence calibrated / seen by the reviewer / does follow-up selection influence assessment | Not calibrated; not shown; a follow-up adds evidence but sets no verdict |
| Threat-model diagram or table | Described in text (fully compromised extractor); no space for a separate table within 6 pages |
| Synthetic generator details and independence | Not expanded, for lack of space; the harness is part of the released code |
| Combine tables | For the 6-page limit, the learning-curve, latency, split-scheme, cost and regulatory tables were folded into the text |

Adding Tables I and V renumbered the tables: the review's numbers do not match the current paper.

# Formatting

The paper is set in A4 and fits the 6-page limit. All text is in Times; the monospace terms were replaced with ordinary text, and the accented spelling of "resume" is replaced by the plain form throughout. To fit 6 pages, four secondary figures and tables (learning curve, latency plot, split-scheme table, cost table) and the regulatory mapping table were folded into the text; every result they reported is still stated.
