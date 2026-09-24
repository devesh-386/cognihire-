# CogniHire — IEEE conference version

Six-page IEEEtran condensation of the ACM survey in `../paper-acm/`.

Build (needs TeX Live with IEEEtran, pgfplots, TikZ):

```bash
pdflatex CogniHire_IEEE.tex && pdflatex CogniHire_IEEE.tex
```

All figures are vector TikZ/pgfplots. `figs/fig4_folds.tex` and
`figs/fig5_curve.tex` are generated from `service/ml/resume_fit/resume_fit_benchmark_folds.csv`,
`service/ml/synthetic_benchmark_folds.csv` and `service/ml/resume_fit/ablation.report.json`.
