"""Generates the publication figures from the experiment outputs.

Paper-only tooling. matplotlib is deliberately NOT added to
`service/requirements.txt`, because that file's floors flow into
`requirements.lock` and from there into the deployed image; figure
generation is not a service dependency. Install it into the venv alone:

    .venv/Scripts/python.exe -m pip install matplotlib

Inputs (produced by the four experiment scripts):
    ml/resume_fit/resume_fit_benchmark_folds.csv
    ml/resume_fit/resume_fit_benchmark.report.json
    ml/synthetic_benchmark_folds.csv
    ml/resume_fit/ablation.report.json
    ml/resume_fit/matching_isolation.report.json

Outputs: docs/paper/figures/*.pdf and *.png

Every figure degrades gracefully: a missing input is reported and skipped
rather than crashing the run, so partial results still produce partial
figures.

Run from `service/`:

    python -m ml.make_figures
"""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SERVICE = Path(__file__).resolve().parent.parent
REPO = SERVICE.parent
FIGDIR = REPO / "docs" / "paper" / "figures"

# Single-column and double-column widths for a two-column article.
COL_W = 3.4
FULL_W = 7.0

# Colourblind-safe (Okabe-Ito), and distinguishable in greyscale by order.
INK = "#1a1a1a"
ACCENT = "#0072B2"
ACCENT2 = "#D55E00"
MUTED = "#999999"

PRETTY = {
    "logistic_regression": "Logistic Reg.",
    "gaussian_nb": "Gaussian NB",
    "knn": "$k$-NN",
    "svm_rbf": "SVM (RBF)",
    "random_forest": "Random Forest",
    "extra_trees": "Extra Trees",
    "gradient_boosting": "Gradient Boost.",
    "hist_gradient_boosting": "Hist. Grad. Boost.",
    "mlp": "MLP",
}

REP_PRETTY = {
    "R1_cosine_1": "R1  cosine (1-d)",
    "R2_relational_10": "R2  relational (10-d)",
    "R3_resume_only_768": "R3  résumé only (768-d)",
    "R4_jd_only_768": "R4  posting only (768-d)",
    "R5_concat_1536": "R5  concat (1536-d)",
    "R6_interaction_1536": "R6  interaction (1536-d)",
}


def _style() -> None:
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["DejaVu Serif", "Times New Roman", "Times"],
        "font.size": 8,
        "axes.labelsize": 8,
        "axes.titlesize": 8.5,
        "xtick.labelsize": 7,
        "ytick.labelsize": 7,
        "legend.fontsize": 7,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.edgecolor": INK,
        "axes.labelcolor": INK,
        "text.color": INK,
        "xtick.color": INK,
        "ytick.color": INK,
        "figure.dpi": 150,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "savefig.pad_inches": 0.02,
        "grid.color": "#DDDDDD",
        "grid.linewidth": 0.5,
    })


def _save(fig, name: str) -> None:
    FIGDIR.mkdir(parents=True, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(FIGDIR / f"{name}.{ext}")
    plt.close(fig)
    print(f"[figures] wrote {name}.pdf / .png")


def _read_folds(path: Path) -> dict[str, dict[str, list[float]]]:
    out: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    with path.open() as fh:
        for row in csv.DictReader(fh):
            for key in ("auc", "accuracy", "f1", "predict_us_per_row", "fit_s", "size_kb", "ece"):
                if row.get(key) not in (None, "", "None"):
                    out[row["model"]][key].append(float(row[key]))
    return out


def _load_json(path: Path):
    if not path.exists():
        print(f"[figures] SKIP - missing {path.name}")
        return None
    return json.loads(path.read_text())


# ---------------------------------------------------------------------------


def fig_convergence_and_power() -> None:
    """The core two-panel argument: models converge on the real task, and the
    same protocol separates them decisively on synthetic data with planted
    signal. Panel (b) is the power analysis that makes panel (a) informative
    rather than merely inconclusive."""
    real_p = SERVICE / "ml" / "resume_fit" / "resume_fit_benchmark_folds.csv"
    syn_p = SERVICE / "ml" / "synthetic_benchmark_folds.csv"
    if not real_p.exists() or not syn_p.exists():
        print("[figures] SKIP fig1 - benchmark folds missing")
        return

    real, syn = _read_folds(real_p), _read_folds(syn_p)
    syn_report = _load_json(SERVICE / "ml" / "synthetic_benchmark.report.json")
    bayes = syn_report["bayesOptimalAccuracy"] if syn_report else None

    order = sorted(real, key=lambda m: sum(real[m]["auc"]) / len(real[m]["auc"]))

    fig, axes = plt.subplots(1, 2, figsize=(FULL_W, 2.9))

    for ax, data, metric, title, ceiling, clabel in (
        (axes[0], real, "auc", "(a) Résumé–posting fit (real)", None, None),
        (axes[1], syn, "accuracy", "(b) Synthetic control (planted signal)", bayes,
         "Bayes-optimal ceiling"),
    ):
        vals = [data[m][metric] for m in order]
        bp = ax.boxplot(vals, orientation="horizontal", widths=0.62, patch_artist=True,
                        medianprops=dict(color=ACCENT2, linewidth=1.2),
                        flierprops=dict(marker=".", markersize=3, markerfacecolor=MUTED,
                                        markeredgecolor="none"))
        for patch in bp["boxes"]:
            patch.set_facecolor("#EAEFF5")
            patch.set_edgecolor(INK)
            patch.set_linewidth(0.7)
        for element in ("whiskers", "caps"):
            for item in bp[element]:
                item.set_color(INK)
                item.set_linewidth(0.7)

        ax.set_yticks(range(1, len(order) + 1))
        ax.set_yticklabels([PRETTY[m] for m in order])
        ax.set_xlabel("AUROC" if metric == "auc" else "Accuracy")
        ax.set_title(title, loc="left")
        ax.grid(axis="x", zorder=0)
        ax.set_axisbelow(True)

        if ceiling is not None:
            ax.axvline(ceiling, color=ACCENT2, linestyle="--", linewidth=0.9, zorder=3)
            lo, hi = ax.get_xlim()
            ax.set_xlim(lo, max(hi, ceiling + 0.012))
            ax.text(ceiling - 0.004, len(order) + 0.15, f"{clabel} ({ceiling:.3f})",
                    color=ACCENT2, fontsize=6.2, va="center", ha="right")

    axes[0].axvline(0.5, color=MUTED, linestyle=":", linewidth=0.9)
    axes[0].text(0.5, 0.35, "  chance", color=MUTED, fontsize=6.2,
                 va="bottom", ha="right", rotation=90)
    axes[1].set_yticklabels([])

    fig.tight_layout()
    _save(fig, "fig1_convergence_and_power")


def fig_representation_ablation() -> None:
    """Best AUROC per representation. The load-bearing comparison is R3
    (résumé only, posting never seen) against R2 and R6."""
    rep = _load_json(SERVICE / "ml" / "resume_fit" / "ablation.report.json")
    if rep is None:
        return

    def _best_auc(r):
        best = rep["bestModelPerRepresentation"][r]
        return rep["representations"][r][best]["auc"]

    # Ascending, so barh (which draws bottom-up) renders best at the top.
    order = sorted(rep["representations"], key=lambda r: _best_auc(r)["mean"])

    means, stds, labels = [], [], []
    for r in order:
        s = _best_auc(r)
        means.append(s["mean"])
        stds.append(s["std"])
        labels.append(REP_PRETTY.get(r, r))

    fig, ax = plt.subplots(figsize=(COL_W, 2.5))
    ypos = range(len(order))
    # R3 and R4 are the "cannot possibly be matching" probes - mark them.
    colors = [ACCENT2 if r in ("R3_resume_only_768", "R4_jd_only_768") else ACCENT
              for r in order]
    ax.barh(list(ypos), means, xerr=stds, height=0.62, color=colors,
            edgecolor=INK, linewidth=0.6, error_kw=dict(ecolor=INK, lw=0.7, capsize=2))
    ax.set_yticks(list(ypos))
    ax.set_yticklabels(labels)
    ax.set_xlabel("AUROC (best model per representation)")
    ax.set_xlim(0.5, max(means) + max(stds) + 0.03)
    ax.axvline(0.5, color=MUTED, linestyle=":", linewidth=0.9)
    ax.grid(axis="x")
    ax.set_axisbelow(True)
    for i, (m, s) in enumerate(zip(means, stds)):
        ax.text(m + s + 0.004, i, f"{m:.3f}", va="center", fontsize=6.5)
    fig.tight_layout()
    _save(fig, "fig2_representation_ablation")


def fig_efficiency_pareto() -> None:
    """Accuracy is decoupled from cost: the cheapest and most expensive models
    sit within noise of each other."""
    path = SERVICE / "ml" / "resume_fit" / "resume_fit_benchmark_folds.csv"
    if not path.exists():
        print("[figures] SKIP fig4 - benchmark folds missing")
        return
    data = _read_folds(path)

    fig, ax = plt.subplots(figsize=(COL_W, 2.5))
    for model, d in data.items():
        x = sum(d["predict_us_per_row"]) / len(d["predict_us_per_row"])
        y = sum(d["auc"]) / len(d["auc"])
        ax.scatter(x, y, s=22, color=ACCENT, edgecolor=INK, linewidth=0.5, zorder=3)
        ax.annotate(PRETTY[model], (x, y), textcoords="offset points",
                    xytext=(4, 3), fontsize=6.2)
    ax.set_xscale("log")
    ax.set_xlabel(r"Inference latency ($\mu$s per row, log scale)")
    ax.set_ylabel("AUROC")
    ax.grid(True)
    ax.set_axisbelow(True)
    fig.tight_layout()
    _save(fig, "fig4_efficiency_pareto")


def fig_learning_curve() -> None:
    """Flat curve = signal-limited, not data-limited."""
    rep = _load_json(SERVICE / "ml" / "resume_fit" / "ablation.report.json")
    if rep is None or "learningCurve_R2_randomForest" not in rep:
        return
    curve = rep["learningCurve_R2_randomForest"]
    x = [c["trainRows"] for c in curve]
    y = [c["auc_mean"] for c in curve]
    e = [c["auc_std"] for c in curve]

    fig, ax = plt.subplots(figsize=(COL_W, 2.2))
    ax.errorbar(x, y, yerr=e, marker="o", markersize=3.5, color=ACCENT,
                ecolor=MUTED, elinewidth=0.8, capsize=2, linewidth=1.1)
    ax.set_xlabel("Training rows")
    ax.set_ylabel("AUROC")
    ax.grid(True)
    ax.set_axisbelow(True)
    fig.tight_layout()
    _save(fig, "fig5_learning_curve")


def fig_matching_isolation() -> None:
    """Within-résumé pairwise ranking against between-résumé. Chance is 0.5.
    This is the figure that separates 'ranks résumés' from 'ranks matches'."""
    rep = _load_json(SERVICE / "ml" / "resume_fit" / "matching_isolation.report.json")
    if rep is None:
        return

    reps = list(rep["pairwiseRanking"].keys())
    labels = {"relational_10": "Relational (10-d)", "interaction_1536": "Interaction (1536-d)"}

    fig, ax = plt.subplots(figsize=(COL_W, 2.2))
    width = 0.34
    xs = range(len(reps))
    between = [rep["pairwiseRanking"][r]["betweenResumePairAccuracy"] for r in reps]
    within = [rep["pairwiseRanking"][r]["withinResumePairAccuracy"] for r in reps]
    werr = [rep["pairwiseRanking"][r].get("withinResumeStd") or 0.0 for r in reps]

    ax.bar([x - width / 2 for x in xs], between, width, label="Between résumés",
           color=ACCENT, edgecolor=INK, linewidth=0.6)
    ax.bar([x + width / 2 for x in xs], within, width, yerr=werr, label="Within a résumé",
           color=ACCENT2, edgecolor=INK, linewidth=0.6,
           error_kw=dict(ecolor=INK, lw=0.7, capsize=2))
    ax.axhline(0.5, color=INK, linestyle="--", linewidth=0.9)
    ax.text(-0.55, 0.507, "chance", fontsize=6.2, ha="left", va="bottom")

    # The point of the figure: the between-résumé bar moves, the within one does not.
    if len(reps) == 2:
        ax.annotate("", xy=(1 - width / 2, between[1]), xytext=(0 - width / 2, between[0]),
                    arrowprops=dict(arrowstyle="->", color=ACCENT, lw=0.9))
        ax.text(0.5 - width / 2, max(between) + 0.014,
                f"{between[1] - between[0]:+.3f}", color=ACCENT,
                fontsize=6.8, ha="center", va="bottom")
        ax.annotate("", xy=(1 + width / 2, within[1] + werr[1] + 0.006),
                    xytext=(0 + width / 2, within[0] + werr[0] + 0.006),
                    arrowprops=dict(arrowstyle="->", color=ACCENT2, lw=0.9,
                                    linestyle=(0, (3, 2))))
        ax.text(1 + width / 2, within[1] + werr[1] + 0.016,
                f"{within[1] - within[0]:+.3f} (n.s.)", color=ACCENT2,
                fontsize=6.8, ha="center", va="bottom")

    ax.set_xticks(list(xs))
    ax.set_xticklabels([labels.get(r, r) for r in reps])
    ax.set_ylabel("Pairwise ranking accuracy")
    ax.set_ylim(0.40, max(max(between), max(within)) + 0.10)
    ax.set_xlim(-0.6, len(reps) - 0.4)
    ax.legend(frameon=False, loc="upper left", ncol=2,
              bbox_to_anchor=(0.0, 1.0), handlelength=1.2, columnspacing=1.0)
    ax.grid(axis="y")
    ax.set_axisbelow(True)
    fig.tight_layout()
    _save(fig, "fig3_matching_isolation")


def main() -> int:
    _style()
    fig_convergence_and_power()
    fig_representation_ablation()
    fig_efficiency_pareto()
    fig_learning_curve()
    fig_matching_isolation()
    print(f"[figures] output directory: {FIGDIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
