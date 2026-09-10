"""Figure generation for the ACM-format CogniHire paper.

Mirrors the figure conventions of the format template supplied by the project
guide (Bilal et al., ACM Comput. Surv. 58(15), Art. 385). That paper carries 16
figures across 27 body pages -- roughly one visual per 1.7 pages -- and leans on
a small number of recurring visual idioms:

  * a hierarchical org-chart of the paper's own structure (their Fig. 2)
  * taxonomy trees with citation anchors (their Fig. 3)
  * a PRISMA-style review-methodology flow (their Fig. 4)
  * layered / tiered architecture stacks (their Figs. 5, 10, 14)
  * horizontal stacked bar charts for distributions (their Figs. 7, 8)
  * left-to-right process ribbons (their Figs. 9, 11, 16)

Each idiom is implemented once here as a helper and reused, so the figure set
reads as one system rather than sixteen unrelated drawings.

Run from the repository root:

    service/.venv/Scripts/python.exe docs/paper-acm/figures.py

Outputs PDF (vector, for LaTeX) and PNG (300 dpi, for review) into
docs/paper-acm/figures/.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch  # noqa: E402

OUT = Path(__file__).resolve().parent / "figures"

# Palette sampled from the template: muted peach section headers, pale blue
# leaves, dark navy root, thin grey rules. Deliberately low-saturation so the
# figures survive greyscale printing.
NAVY = "#1F3864"
PEACH = "#FBE2D5"
PEACH_EDGE = "#D99C7A"
BLUE = "#DEEAF6"
BLUE_EDGE = "#8FAADC"
GREEN = "#E2EFDA"
GREEN_EDGE = "#A9D08E"
GREY = "#F2F2F2"
GREY_EDGE = "#BFBFBF"
INK = "#1A1A1A"


def _style() -> None:
    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["DejaVu Sans", "Arial", "Helvetica"],
        "font.size": 6.0,
        "text.color": INK,
        "figure.dpi": 150,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "savefig.pad_inches": 0.03,
    })


def _save(fig, name: str) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"{name}.{ext}")
    plt.close(fig)
    print(f"[acm-fig] wrote {name}.pdf / .png")


_MEASURE_FIG = None


def text_width_in(text: str, fontsize: float, weight: str = "normal") -> float:
    """Rendered width of `text` in inches, measured rather than estimated.

    Character-budget estimates do not work here. A per-character em advance
    that is right on average is wrong on any specific string, and the failure
    mode is silent: matplotlib draws text straight through the box edge. Two
    successive estimates (0.50 em, then 0.58 em for bold) both let headings
    such as "Deployment Experiences" overflow, because that string sits exactly
    at the estimated budget while rendering wider. Measuring removes the guess.
    """
    global _MEASURE_FIG
    if _MEASURE_FIG is None:
        _MEASURE_FIG = plt.figure(figsize=(1, 1), dpi=100)
    t = _MEASURE_FIG.text(0, 0, text, fontsize=fontsize, fontweight=weight)
    try:
        bb = t.get_window_extent(renderer=_MEASURE_FIG.canvas.get_renderer())
        return bb.width / _MEASURE_FIG.dpi
    finally:
        t.remove()


def fit_text(text: str, box_w_frac: float, fig_w_in: float, fontsize: float,
             *, fill=0.88, weight="normal") -> str:
    """Greedy-wrap `text` to fit a box `box_w_frac` wide on a `fig_w_in`-inch
    figure, using measured widths. Author-inserted breaks are honoured, then
    each resulting line is re-wrapped if it is still too wide. A single word
    wider than the box is left alone rather than broken."""
    limit = box_w_frac * fig_w_in * fill

    lines: list[str] = []
    for para in text.split("\n"):
        words = para.split()
        if not words:
            lines.append("")
            continue
        cur = words[0]
        for w in words[1:]:
            trial = f"{cur} {w}"
            if text_width_in(trial, fontsize, weight) <= limit:
                cur = trial
            else:
                lines.append(cur)
                cur = w
        lines.append(cur)
    return "\n".join(lines)


def box(ax, x, y, w, h, text, *, fc, ec, fontsize=5.6, weight="normal",
        color=INK, radius=0.012, lw=0.7, fig_w=None, wrap=True):
    """Rounded box with centred text, wrapped to the box width when `fig_w` is
    given. The workhorse of every diagram in this module."""
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0,rounding_size={radius}",
        facecolor=fc, edgecolor=ec, linewidth=lw, zorder=2,
    ))
    if text:
        label = (fit_text(text, w, fig_w, fontsize, weight=weight)
                 if (wrap and fig_w) else text)
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fontsize, fontweight=weight, color=color, zorder=3,
                linespacing=1.22)


def elbow(ax, x0, y0, x1, y1, *, color=GREY_EDGE, lw=0.7):
    """Orthogonal connector: down, across, down — the org-chart idiom."""
    ymid = (y0 + y1) / 2
    ax.plot([x0, x0], [y0, ymid], color=color, lw=lw, zorder=1)
    ax.plot([x0, x1], [ymid, ymid], color=color, lw=lw, zorder=1)
    ax.plot([x1, x1], [ymid, y1], color=color, lw=lw, zorder=1)


def arrow(ax, xy_from, xy_to, *, color=INK, lw=0.8, style="-|>"):
    ax.add_patch(FancyArrowPatch(
        xy_from, xy_to, arrowstyle=style, mutation_scale=7,
        color=color, lw=lw, zorder=4, shrinkA=1, shrinkB=1,
    ))


def _canvas(w, h):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")
    return fig, ax


# ---------------------------------------------------------------------------
# Fig. 2 — Overview of the paper structure.
# The template's signature figure: an org chart of the paper's own sections.
# ---------------------------------------------------------------------------

STRUCTURE = [
    ("Section 3\nAutomated Hiring:\nArchitecture, Failure\nLandscape, Regulation", [
        "Layered Architecture\nand Surfaces",
        "Failure Landscape",
        "Current State and\nIndustry Trends",
        "Landscape of Grounding,\nML, and DL",
    ]),
    ("Section 4\nEvidence Grounding\nas an Enabler", [
        "Grounding-Centric\nExtraction",
        "Integrity Functions\nEnabled by Grounding",
        "Open Challenges in\nGrounded Extraction",
    ]),
    ("Section 5\nML Techniques for\nCandidate Screening", [
        "Taxonomy of ML\nParadigms",
        "Representative Models\nand Use Cases",
        "Nine-Model\nBenchmark",
        "Architectural\nIntegration of ML",
        "Open Challenges and\nResearch Directions",
    ]),
    ("Section 6\nDL for Identity and\nExtraction", [
        "DL Architectures",
        "Applications in Identity\nand Provenance",
        "Threshold Calibration\nand Abstention",
        "Deployment Challenges",
    ]),
    ("Section 7\nSynergistic\nIntegration of\nGrounding-ML-DL", [
        "Motivation for\nIntegration",
        "System Architecture\nand Integration Stack",
        "Evaluated Benefits\nand Impact",
        "Integration Challenges",
        "Standards and\nRegulatory Compliance",
    ]),
    ("Section 8\nDeployment Experiences\nand Lessons", [
        "Use Cases of Grounding,\nML, and DL",
        "Lessons Learned from\nReal Deployments",
    ]),
    ("Section 9\nFuture Directions and\nResearch Opportunities", [
        "Deployment-Aware\nAudit Architectures",
        "Explainable and\nContestable Screening",
        "Privacy-Preserving\nProcess Evidence",
        "Within-Query\nEvaluation Standards",
    ]),
]


def fig02_structure() -> None:
    FW, FH = 7.1, 3.2
    fig, ax = _canvas(FW, FH)

    HEAD_FS, LEAF_FS = 4.7, 4.2
    n = len(STRUCTURE)
    margin, gap = 0.010, 0.007
    col_w = (1.0 - 2 * margin - gap * (n - 1)) / n

    # Height each box needs, derived from the wrapped line count, so nothing
    # overflows and no column is padded taller than its content requires.
    line_h = 0.030          # vertical space per text line, axes fraction
    pad_v = 0.016

    def needed(text, w, fs, weight="normal"):
        lines = fit_text(text, w, FW, fs, weight=weight).split("\n")
        return len(lines) * line_h + pad_v

    head_h = max(needed(t, col_w, HEAD_FS, "bold") for t, _ in STRUCTURE)
    leaf_w = col_w * 0.94
    leaf_hs = [[needed(l, leaf_w, LEAF_FS) for l in leaves] for _, leaves in STRUCTURE]
    leaf_gap = 0.012

    root_h, s2_h = 0.058, 0.058
    top = 0.985
    root_y = top - root_h
    head_y = root_y - 0.085 - head_h

    root_w = 0.20
    root_x = 0.30
    box(ax, root_x, root_y, root_w, root_h, "Structure of the Paper",
        fc=NAVY, ec=NAVY, fontsize=5.8, weight="bold", color="white", fig_w=FW)

    s2_w, s2_x = 0.17, 0.60
    box(ax, s2_x, root_y, s2_w, s2_h, "Section 2  Related Works",
        fc=PEACH, ec=PEACH_EDGE, fontsize=5.0, weight="bold", fig_w=FW)
    ax.plot([root_x + root_w, s2_x], [root_y + root_h / 2, root_y + s2_h / 2],
            color=GREY_EDGE, lw=0.7, zorder=1)

    root_cx = root_x + root_w / 2
    lowest = head_y
    for i, (title, leaves) in enumerate(STRUCTURE):
        cx = margin + i * (col_w + gap)
        centre = cx + col_w / 2
        box(ax, cx, head_y, col_w, head_h, title,
            fc=PEACH, ec=PEACH_EDGE, fontsize=HEAD_FS, weight="bold", fig_w=FW)
        elbow(ax, root_cx, root_y, centre, head_y + head_h)

        y = head_y
        for leaf, lh in zip(leaves, leaf_hs[i]):
            y -= leaf_gap + lh
            lx = cx + (col_w - leaf_w) / 2
            box(ax, lx, y, leaf_w, lh, leaf,
                fc=BLUE, ec=BLUE_EDGE, fontsize=LEAF_FS, radius=0.008, fig_w=FW)
            ax.plot([centre, centre], [y + lh, y + lh + leaf_gap],
                    color=GREY_EDGE, lw=0.6, zorder=1)
        lowest = min(lowest, y)

    ax.set_ylim(lowest - 0.012, 1.0)
    _save(fig, "fig02_paper_structure")


# ---------------------------------------------------------------------------
# Fig. 1 — CogniHire data flow and component interactions.
# Mirrors the template's Fig. 1: stacked horizontal ribbons, each a layer,
# with a vertical band on the right naming the cross-cutting guarantees.
# ---------------------------------------------------------------------------

LAYERS = [
    ("Recruiter Console", "Per-claim audit · evidence · no composite score", GREEN, GREEN_EDGE),
    ("Report Generation", "Deterministic transform · cannot invent a verdict", GREEN, GREEN_EDGE),
    ("Evidence Graph", "Typed nodes and edges · mandatory rationale", BLUE, BLUE_EDGE),
    ("Interview Engine", "Claim-driven planning · adaptive follow-ups", BLUE, BLUE_EDGE),
    ("Grounding Gate", "Verbatim-only · negation and hedge aware", PEACH, PEACH_EDGE),
    ("Perception", "Face embedding · process telemetry · resume parsing", GREY, GREY_EDGE),
    ("Candidate Session", "Resume · camera · typed or spoken answers", GREY, GREY_EDGE),
]

FLOW_NOTES = [
    "Audited claims and cited evidence",
    "Structured verdicts",
    "Linked evidence",
    "Grounded claims",
    "Selected spans only",
    "Measured signals",
]


GUARANTEES = [
    "no composite score",
    "AI selects, never authors",
    "unmeasured is not passed",
    "no demographic inference",
    "no hiring-outcome labels",
]


def fig01_dataflow() -> None:
    FW, FH = 3.4, 3.1
    fig, ax = _canvas(FW, FH)

    NAME_FS, SUB_FS, NOTE_FS = 4.6, 3.5, 3.3
    x0, w = 0.02, 0.635
    bx, bw = x0 + w + 0.035, 0.29
    gap = 0.030
    line_h, pad_v = 0.026, 0.020

    # Pre-wrap so each ribbon is exactly as tall as its own content needs.
    heights, wrapped = [], []
    for name, sub, fc, ec in LAYERS:
        s = fit_text(sub, w, FW, SUB_FS)
        wrapped.append(s)
        heights.append((1 + len(s.split("\n"))) * line_h + pad_v)

    total = sum(heights) + gap * (len(LAYERS) - 1)
    y = 0.02
    ys = []
    for h in reversed(heights):
        ys.append(y)
        y += h + gap
    ys.reverse()   # ys[i] is the bottom of LAYERS[i]

    for i, (name, sub, fc, ec) in enumerate(LAYERS):
        yy, h = ys[i], heights[i]
        box(ax, x0, yy, w, h, "", fc=fc, ec=ec, radius=0.010)
        ax.text(x0 + w / 2, yy + h - pad_v / 2 - line_h * 0.5, name,
                ha="center", va="center", fontsize=NAME_FS,
                fontweight="bold", zorder=3)
        ax.text(x0 + w / 2, yy + (h - line_h - pad_v / 2) / 2, wrapped[i],
                ha="center", va="center", fontsize=SUB_FS, color="#4A4A4A",
                zorder=3, linespacing=1.25)

    # Upward flow annotations sit in the gaps between ribbons.
    for i, note in enumerate(FLOW_NOTES):
        top_of_lower = ys[i + 1] + heights[i + 1]
        ymid = top_of_lower + gap / 2
        arrow(ax, (x0 + 0.055, ymid - gap * 0.30), (x0 + 0.055, ymid + gap * 0.30),
              color="#8A8A8A", lw=0.6)
        ax.text(x0 + 0.085, ymid, note, ha="left", va="center",
                fontsize=NOTE_FS, color="#6B6B6B", style="italic", zorder=3)

    # Cross-cutting guarantees band, wrapped to its own width.
    box(ax, bx, ys[-1], bw, total, "", fc="#EDEDED", ec=GREY_EDGE, radius=0.010)
    ax.text(bx + bw / 2, ys[-1] + total - 0.030, "Structural\nguarantees",
            ha="center", va="top", fontsize=4.2, fontweight="bold", zorder=3,
            linespacing=1.3)
    body = "\n\n".join(fit_text(g, bw, FW, 3.5) for g in GUARANTEES)
    ax.text(bx + bw / 2, ys[-1] + total * 0.42, body,
            ha="center", va="center", fontsize=3.5, color="#4A4A4A",
            zorder=3, linespacing=1.35)

    ax.set_ylim(0, ys[0] + heights[0] + 0.02)
    _save(fig, "fig01_dataflow")


def main() -> int:
    _style()
    fig02_structure()
    fig01_dataflow()
    print(f"[acm-fig] output: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
