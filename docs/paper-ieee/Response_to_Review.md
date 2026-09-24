---
title: "CogniHire IEEE Paper — Response to Review"
author: "Devesh S V, Department of Computer Science and Engineering, SRM Institute of Science and Technology"
date: "24 September 2026"
---

# Summary

Thank you for the detailed review. Every comment has been addressed in the revised paper. New material comes from the project's own code and saved results; one new experiment was run (a prompt-injection evaluation, comment 4). The paper is now 8 pages with 29 references, and it compiles without errors or bitmap fonts.

While answering comment 2, the check against the code found one real gap: the web report shows the mean model confidence across answers. The paper now states this openly (Table II and Limitations) instead of claiming that nothing is aggregated.

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
| 2 | Clarify the ML role and whether outputs can become a hidden score | New Table II lists every component output, whether it is deployed, what reaches the recruiter, and whether it can act as a hidden score. Verdicts are set by a person, and no model sets one. The sufficiency model is diagnostic only: it is fitted on synthetic data, and the code cannot present it as a finding about a real person. The fit classifiers are not deployed. Identity is a presence gate whose mismatches are logged for review. The remaining gap, the mean-confidence figure in the web report, is disclosed. | Sec. III, Table II, Sec. VII |
| 3 | Define selection versus generation | Formal Definition 1: a claim is selected only if it matches a single-clause span of the résumé exactly, up to case and whitespace, and the rest of that clause has no negation or hedge. Anything else is generation and is discarded. | Sec. IV-A |
| 4 | No prompt-injection evaluation | New evaluation: 20 injection templates at 3 positions in 24 real résumés (1,440 documents), with a fully compromised model that obeys every injection. 0 of 1,800 fabricated claims were admitted. Text the attacker writes into the résumé can become a claim to be questioned, but never a verdict; this limit is stated. | Sec. IV-C, Table V |
| 5 | Dataset card has no licence or labeling procedure | Stated explicitly. The labels are treated as an unvalidated proxy, and the benchmark is used only diagnostically. | Sec. V-A |
| 6 | Pair generation and effective sample size | The pairs are the dataset's own (8,000 pairs; 6,241 train / 1,759 test), then binarized, class-balanced and pooled into 7,910 pairs. Each résumé appears in 12.3 pairs on average and each posting in 22.5. All significance tests are computed over fold-level scores, not rows; the within-résumé binomial test was replaced by a fold-level sign test. | Sec. V-A, Table VII |
| 7 | Label validity (80.6% within-résumé) | Clarified: 19.4% of label variance lies between résumés, enough for a résumé-only model to score 0.660. This is why the within-résumé diagnostic is needed. | Sec. V-C |
| 8 | End-to-end example across grounding, ML and DL | A worked example follows one claim, "Built REST APIs in Django…", through extraction, grounding, interview, answer analysis, identity checks and the reviewer's verdict. Fig. 1 now marks each family's layer. | Sec. III, Fig. 1 |
| 9 | Terminology table | New Table I defines claim, evidence, measurement, signal, verdict, audit and screening. | Table I |
| 10 | End-to-end processing cost | New Table IX with measured costs: claim extraction takes a median 12.1 s per résumé and the grounding gate 1.1 ms per claim. Interview-stage costs were not measured, and the paper says so. | Sec. V-D, Table IX |
| 11 | Separate demonstrated findings from proposed benefits | The conclusion now has two explicit parts: what is demonstrated by measurement, and what is proposed but not yet demonstrated. | Sec. VIII |

# Other corrections found during revision

| Correction | Where |
|---|---|
| The hedge example "some exposure to Kafka" was wrong: the gate does not reject it. Replaced with "possibly used Kafka", which it does. | Sec. IV-A |
| The +0.041 AUROC comparison mixed two models; the same-model figure is +0.048. | Sec. V-C |
| The split-scheme table used 8,000 unbalanced rows, unlike every other experiment; this is now stated. | Table VIII |
| The legal table cited the wrong EU AI Act provisions and overstated HB 3773; it now cites Arts. 12, 14 and 86. | Table XI |
| Figures rebuilt as vector graphics, removing the bitmap fonts that IEEE PDF eXpress rejects. | All figures |

# Open items

1. The conference's required page size (A4 or US Letter).
2. The access date of the dataset in reference [19].
3. Whether 8 pages is within the conference limit.
