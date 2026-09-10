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


# ---------------------------------------------------------------------------
# Shared idioms. Each is implemented once and reused, which is what keeps the
# sixteen figures looking like one figure set rather than sixteen drawings.
# ---------------------------------------------------------------------------

def stack_column(ax, x, w, top, items, *, fig_w, fc, ec, fs=4.2,
                 line_h=0.052, pad=0.030, gap=0.018, weight="normal"):
    """Vertical run of boxes, each sized to its own wrapped content.
    Returns the y of the lowest edge."""
    y = top
    for it in items:
        n = len(fit_text(it, w, fig_w, fs, weight=weight).split("\n"))
        h = n * line_h + pad
        y -= h
        box(ax, x, y, w, h, it, fc=fc, ec=ec, fontsize=fs, weight=weight,
            radius=0.010, fig_w=fig_w)
        y -= gap
    return y + gap


def tree(ax, *, fig_w, root, branches, root_fs=5.0, br_fs=4.4, leaf_fs=3.9):
    """Root over a row of branches, each with a leaf stack beneath."""
    n = len(branches)
    margin, gap = 0.012, 0.010
    col = (1.0 - 2 * margin - gap * (n - 1)) / n

    root_h = 0.075
    root_w = 0.34
    root_x = (1 - root_w) / 2
    root_y = 1.0 - root_h
    box(ax, root_x, root_y, root_w, root_h, root, fc=NAVY, ec=NAVY,
        fontsize=root_fs, weight="bold", color="white", fig_w=fig_w)

    br_top = root_y - 0.085
    lowest = br_top
    for i, (title, leaves) in enumerate(branches):
        x = margin + i * (col + gap)
        nb = len(fit_text(title, col, fig_w, br_fs, weight="bold").split("\n"))
        bh = nb * 0.052 + 0.030
        box(ax, x, br_top - bh, col, bh, title, fc=PEACH, ec=PEACH_EDGE,
            fontsize=br_fs, weight="bold", radius=0.010, fig_w=fig_w)
        elbow(ax, 0.5, root_y, x + col / 2, br_top)
        end = stack_column(ax, x + col * 0.03, col * 0.94,
                           br_top - bh - 0.020, leaves,
                           fig_w=fig_w, fc=BLUE, ec=BLUE_EDGE, fs=leaf_fs)
        ax.plot([x + col / 2, x + col / 2], [br_top - bh, br_top - bh - 0.020],
                color=GREY_EDGE, lw=0.6, zorder=1)
        lowest = min(lowest, end)
    return lowest


def chain(ax, steps, *, fig_w, y, h, x0=0.02, x1=0.98, fs=4.2,
          fcs=None, ecs=None, gap=0.030):
    """Left-to-right process ribbon with arrows between steps."""
    n = len(steps)
    w = (x1 - x0 - gap * (n - 1)) / n
    for i, s in enumerate(steps):
        x = x0 + i * (w + gap)
        fc = (fcs or [BLUE] * n)[i]
        ec = (ecs or [BLUE_EDGE] * n)[i]
        box(ax, x, y, w, h, s, fc=fc, ec=ec, fontsize=fs, radius=0.010,
            fig_w=fig_w)
        if i < n - 1:
            arrow(ax, (x + w + 0.004, y + h / 2),
                  (x + w + gap - 0.004, y + h / 2), color="#8A8A8A", lw=0.8)
    return w


# ---------------------------------------------------------------------------
# Fig. 3 — Taxonomy of technologies for evidence-based screening.
# ---------------------------------------------------------------------------

def fig03_taxonomy() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 2.9)
    low = tree(ax, fig_w=FW,
               root="Technologies for Evidence-Based Candidate Screening",
               branches=[
                   ("Evidence Grounding", [
                       "Verbatim span selection",
                       "Negation and hedge rejection",
                       "Clause-scoped matching",
                       "Import-boundary enforcement",
                   ]),
                   ("Machine Learning", [
                       "Linear and probabilistic",
                       "Instance and kernel methods",
                       "Tree ensembles",
                       "Shallow neural models",
                   ]),
                   ("Deep Learning", [
                       "Face detection (SCRFD)",
                       "Face embedding (ArcFace)",
                       "Sentence encoders",
                       "LLM span proposal",
                   ]),
                   ("Governance and Audit", [
                       "Typed evidence graph",
                       "Calibrated abstention",
                       "Provenance gating",
                       "Regulatory alignment",
                   ]),
               ])
    ax.set_ylim(low - 0.02, 1.0)
    _save(fig, "fig03_taxonomy")


# ---------------------------------------------------------------------------
# Fig. 4 — Replication-corpus screening. Real counts from probe_datasets.py
# and verify_med2425.py; no PRISMA numbers are invented.
# ---------------------------------------------------------------------------

def fig04_review_method() -> None:
    FW = 3.4
    fig, ax = _canvas(FW, 3.4)
    stages = [
        ("Candidate corpora identified\non the Hugging Face Hub", "7", GREY, GREY_EDGE),
        ("Loadable and paired\n(2 failed to load)", "5", GREY, GREY_EDGE),
        ("Passed automated\nexact-hash contamination screen", "1", BLUE, BLUE_EDGE),
        ("Survived normalised-text\ncontamination check", "0", PEACH, PEACH_EDGE),
        ("Usable for replication\nof the within-query diagnostic", "0", PEACH, PEACH_EDGE),
    ]
    x, w = 0.06, 0.70
    y = 0.96
    prev = None
    for label, count, fc, ec in stages:
        n = len(fit_text(label, w, FW, 4.2).split("\n"))
        h = n * 0.055 + 0.036
        y -= h
        box(ax, x, y, w, h, label, fc=fc, ec=ec, fontsize=4.2, radius=0.010,
            fig_w=FW)
        box(ax, x + w + 0.030, y + h / 2 - 0.030, 0.14, 0.060, f"n = {count}",
            fc="white", ec=GREY_EDGE, fontsize=4.4, weight="bold", radius=0.008,
            fig_w=FW)
        if prev is not None:
            arrow(ax, (x + w / 2, prev), (x + w / 2, y + h), color="#8A8A8A")
        prev = y
        y -= 0.045
    ax.set_ylim(y, 1.0)
    _save(fig, "fig04_review_method")


# ---------------------------------------------------------------------------
# Fig. 5 — Layered deployment architecture across the four surfaces.
# ---------------------------------------------------------------------------

def fig05_layered_arch() -> None:
    FW = 3.4
    fig, ax = _canvas(FW, 2.6)
    tiers = [
        ("Recruiter surface", "Flutter application - claim audit review", GREEN, GREEN_EDGE),
        ("Candidate surface", "Next.js portal on Vercel - session and consent", BLUE, BLUE_EDGE),
        ("Inference and logic", "FastAPI service - grounding, ML, face pipeline", PEACH, PEACH_EDGE),
        ("Persistence", "Supabase - event-sourced sessions, 13 tables", GREY, GREY_EDGE),
    ]
    x, w = 0.04, 0.92
    y = 0.96
    for name, sub, fc, ec in tiers:
        s = fit_text(sub, w, FW, 3.8)
        h = (1 + len(s.split("\n"))) * 0.070 + 0.030
        y -= h
        box(ax, x, y, w, h, "", fc=fc, ec=ec, radius=0.010)
        ax.text(x + w / 2, y + h - 0.055, name, ha="center", va="center",
                fontsize=4.8, fontweight="bold", zorder=3)
        ax.text(x + w / 2, y + (h - 0.075) / 2, s, ha="center", va="center",
                fontsize=3.8, color="#4A4A4A", zorder=3, linespacing=1.25)
        y -= 0.045
    ax.set_ylim(y, 1.0)
    _save(fig, "fig05_layered_arch")


# ---------------------------------------------------------------------------
# Fig. 6 — Failure landscape in automated hiring.
# ---------------------------------------------------------------------------

def fig06_failure_landscape() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 2.5)
    low = tree(ax, fig_w=FW, root="Failure Modes in Automated Candidate Screening",
               branches=[
                   ("Fabricated evidence", [
                       "Heuristics labelled as detections",
                       "Confident pass from missing data",
                       "Hardcoded fallback outputs",
                       "Silent component outage",
                   ]),
                   ("Unvalidated constants", [
                       "Authored similarity thresholds",
                       "Arbitrary telemetry cut-offs",
                       "Uncalibrated confidence",
                   ]),
                   ("Opaque aggregation", [
                       "Composite score with hidden weights",
                       "Non-contestable ranking",
                       "Evidence discarded at design time",
                   ]),
                   ("Provenance gaps", [
                       "Identity checked once at login",
                       "Process data filed, never used",
                       "Unmeasured read as passed",
                   ]),
               ])
    ax.set_ylim(low - 0.02, 1.0)
    _save(fig, "fig06_failure_landscape")


# ---------------------------------------------------------------------------
# Fig. 7 — Grounding gate evaluation. Real trial counts from the offline
# harness over 5,200 synthetic resumes (~100,000 adversarial trials).
# ---------------------------------------------------------------------------

def fig07_failure_distribution() -> None:
    fig, ax = plt.subplots(figsize=(3.4, 2.0))
    cats = ["Verbatim claims\n(should admit)", "Paraphrases\n(must reject)",
            "Negation traps\n(must reject)"]
    trials = [51761, 48149, 51761]
    before = [99.18, 100.0, 100.0]
    after = [100.0, 100.0, 100.0]

    ypos = range(len(cats))
    hgt = 0.34
    ax.barh([y + hgt / 2 for y in ypos], before, hgt, label="Before fix",
            color=BLUE, edgecolor=INK, linewidth=0.6)
    ax.barh([y - hgt / 2 for y in ypos], after, hgt, label="After fix",
            color=PEACH, edgecolor=INK, linewidth=0.6)
    for i, (b, a, t) in enumerate(zip(before, after, trials)):
        ax.text(b + 0.15, i + hgt / 2, f"{b:.2f}%", va="center", fontsize=3.9)
        ax.text(a + 0.15, i - hgt / 2, f"{a:.2f}%", va="center", fontsize=3.9)
        ax.text(101.6, i, f"n={t:,}", va="center", fontsize=3.6, color="#666666")

    ax.set_yticks(list(ypos))
    ax.set_yticklabels(cats, fontsize=4.0)
    ax.set_xlim(98.8, 103.2)
    ax.set_xlabel("Correct-decision rate (%)", fontsize=4.4)
    ax.tick_params(axis="x", labelsize=4.0)
    ax.legend(frameon=False, fontsize=4.0, loc="lower left")
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    ax.grid(axis="x", color="#DDDDDD", lw=0.5)
    ax.set_axisbelow(True)
    fig.tight_layout()
    _save(fig, "fig07_grounding_gate_results")


# ---------------------------------------------------------------------------
# Fig. 8 — Regulatory timeline. Effective dates only; nothing extrapolated.
# ---------------------------------------------------------------------------

def fig08_regulatory_timeline() -> None:
    FW = 3.4
    fig, ax = _canvas(FW, 1.9)
    events = [
        ("2020", "Illinois AI Video\nInterview Act\n(820 ILCS 42)"),
        ("2023", "NYC Local Law 144\nbias audit and\nnotification"),
        ("2024", "EU AI Act\n(Reg. 2024/1689)\nemployment = high risk"),
        ("2026", "Illinois HB 3773\namends Human\nRights Act"),
    ]
    y_line = 0.72
    ax.plot([0.05, 0.95], [y_line, y_line], color=GREY_EDGE, lw=1.0, zorder=1)
    n = len(events)
    for i, (year, label) in enumerate(events):
        x = 0.11 + i * (0.78 / (n - 1))
        ax.plot([x], [y_line], marker="o", ms=3.2, color=NAVY, zorder=3)
        ax.text(x, y_line + 0.10, year, ha="center", va="bottom",
                fontsize=5.0, fontweight="bold")
        w = 0.21
        s = fit_text(label, w, FW, 3.8)
        h = len(s.split("\n")) * 0.085 + 0.045
        box(ax, x - w / 2, y_line - 0.10 - h, w, h, s, fc=PEACH,
            ec=PEACH_EDGE, fontsize=3.8, radius=0.010, wrap=False)
        ax.plot([x, x], [y_line, y_line - 0.10], color=GREY_EDGE, lw=0.6, zorder=1)
    ax.set_ylim(0.0, 1.0)
    _save(fig, "fig08_regulatory_timeline")


# ---------------------------------------------------------------------------
# Fig. 9 — Compliance practices as a left-to-right ribbon.
# ---------------------------------------------------------------------------

def fig09_standards() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 1.15)
    chain(ax, [
        "Bias audit\npublished annually\n(NYC LL144)",
        "Candidate\nnotification and\nconsent",
        "Human oversight\nof every\ndecision",
        "Traceable evidence\nretained per\nclaim",
        "No demographic\ninference at\nany stage",
    ], fig_w=FW, y=0.20, h=0.62, fs=4.2,
        fcs=[GREY, BLUE, BLUE, PEACH, GREEN],
        ecs=[GREY_EDGE, BLUE_EDGE, BLUE_EDGE, PEACH_EDGE, GREEN_EDGE])
    _save(fig, "fig09_standards")


# ---------------------------------------------------------------------------
# Fig. 10 — The grounding gate, as a decision pipeline.
# ---------------------------------------------------------------------------

def fig10_grounding_gate() -> None:
    FW = 3.4
    fig, ax = _canvas(FW, 2.9)
    steps = [
        ("Language model proposes a claim span", BLUE, BLUE_EDGE),
        ("Verbatim substring of the resume?", PEACH, PEACH_EDGE),
        ("Assertion scope free of negation?", PEACH, PEACH_EDGE),
        ("Free of hedging qualifiers?", PEACH, PEACH_EDGE),
        ("Contained within one clause?", PEACH, PEACH_EDGE),
        ("Claim admitted with character offsets", GREEN, GREEN_EDGE),
    ]
    x, w = 0.04, 0.66
    y = 0.96
    prev = None
    for label, fc, ec in steps:
        n = len(fit_text(label, w, FW, 4.2).split("\n"))
        h = n * 0.062 + 0.038
        y -= h
        box(ax, x, y, w, h, label, fc=fc, ec=ec, fontsize=4.2, radius=0.010,
            fig_w=FW)
        if prev is not None:
            arrow(ax, (x + w / 2, prev), (x + w / 2, y + h), color="#8A8A8A")
        if fc is PEACH:
            arrow(ax, (x + w, y + h / 2), (x + w + 0.135, y + h / 2),
                  color="#B04A2A", lw=0.7)
            ax.text(x + w + 0.068, y + h / 2 + 0.020, "no", fontsize=3.6,
                    color="#B04A2A", ha="center", va="bottom", zorder=5)
        prev = y
        y -= 0.048
    box(ax, x + w + 0.14, y + 0.05, 0.14, 0.30, "discarded",
        fc="#F6E0DA", ec=PEACH_EDGE, fontsize=3.8, radius=0.010, fig_w=FW)
    ax.set_ylim(y, 1.0)
    _save(fig, "fig10_grounding_gate")


# ---------------------------------------------------------------------------
# Fig. 11 — End-to-end grounded extraction flow.
# ---------------------------------------------------------------------------

def fig11_grounding_flow() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 1.15)
    chain(ax, [
        "Resume\nPDF to text",
        "Deterministic\nsegmentation",
        "Model selects\ncandidate spans",
        "Grounding gate\nverbatim check",
        "Typed claims\nwith offsets",
        "Interview plan\nbuilt from claims",
    ], fig_w=FW, y=0.20, h=0.62, fs=4.2,
        fcs=[GREY, GREY, BLUE, PEACH, GREEN, GREEN],
        ecs=[GREY_EDGE, GREY_EDGE, BLUE_EDGE, PEACH_EDGE, GREEN_EDGE, GREEN_EDGE])
    _save(fig, "fig11_grounding_flow")


# ---------------------------------------------------------------------------
# Fig. 12 — Evolution of screening automation.
# ---------------------------------------------------------------------------

def fig12_ml_evolution() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 1.15)
    chain(ax, [
        "Keyword\nmatching",
        "Boolean applicant\ntracking rules",
        "Learned relevance\nranking",
        "Embedding\nsimilarity",
        "Grounded evidence\naudit",
    ], fig_w=FW, y=0.20, h=0.62, fs=4.3,
        fcs=[GREY, GREY, BLUE, BLUE, GREEN],
        ecs=[GREY_EDGE, GREY_EDGE, BLUE_EDGE, BLUE_EDGE, GREEN_EDGE])
    _save(fig, "fig12_ml_evolution")


# ---------------------------------------------------------------------------
# Fig. 13 — Algorithm families mapped to their screening roles.
# ---------------------------------------------------------------------------

def fig13_ml_roles() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 2.4)
    low = tree(ax, fig_w=FW, root="Model Families Evaluated in This Work",
               branches=[
                   ("Linear and probabilistic", [
                       "Logistic regression",
                       "Gaussian naive Bayes",
                       "Role: interpretable baseline",
                   ]),
                   ("Instance and kernel", [
                       "k-nearest neighbours",
                       "RBF support vector machine",
                       "Role: non-parametric contrast",
                   ]),
                   ("Tree ensembles", [
                       "Random forest, extra trees",
                       "Gradient and histogram boosting",
                       "Role: tabular strong baseline",
                   ]),
                   ("Neural", [
                       "Multi-layer perceptron",
                       "Role: learned interactions",
                   ]),
               ])
    ax.set_ylim(low - 0.02, 1.0)
    _save(fig, "fig13_ml_roles")


# ---------------------------------------------------------------------------
# Fig. 14 — Where each learned component runs.
# ---------------------------------------------------------------------------

def fig14_ml_tiers() -> None:
    FW = 3.4
    fig, ax = _canvas(FW, 2.4)
    tiers = [
        ("Offline", "Training, calibration, export gates", GREY, GREY_EDGE),
        ("Service", "Face embedding, claim extraction, scoring", PEACH, PEACH_EDGE),
        ("On device", "Sufficiency scoring, telemetry capture", BLUE, BLUE_EDGE),
        ("Human", "Reviewer adjudicates every claim", GREEN, GREEN_EDGE),
    ]
    x, w = 0.04, 0.92
    y = 0.96
    for name, sub, fc, ec in tiers:
        s = fit_text(sub, w, FW, 3.9)
        h = (1 + len(s.split("\n"))) * 0.075 + 0.030
        y -= h
        box(ax, x, y, w, h, "", fc=fc, ec=ec, radius=0.010)
        ax.text(x + w / 2, y + h - 0.058, name, ha="center", va="center",
                fontsize=4.8, fontweight="bold", zorder=3)
        ax.text(x + w / 2, y + (h - 0.080) / 2, s, ha="center", va="center",
                fontsize=3.9, color="#4A4A4A", zorder=3, linespacing=1.25)
        y -= 0.048
    ax.set_ylim(y, 1.0)
    _save(fig, "fig14_ml_tiers")


# ---------------------------------------------------------------------------
# Fig. 15 — Identity pipeline, ending in a three-valued result.
# ---------------------------------------------------------------------------

def fig15_dl_identity() -> None:
    FW = 7.1
    fig, ax = _canvas(FW, 1.35)
    w = chain(ax, [
        "Frame\ncapture",
        "SCRFD\ndetection",
        "ArcFace\n512-d embedding",
        "Cosine to\nenrolment centroid",
        "Calibrated threshold\n0.1266 (LFW EER)",
    ], fig_w=FW, y=0.42, h=0.52, fs=4.2,
        fcs=[GREY, BLUE, BLUE, BLUE, PEACH],
        ecs=[GREY_EDGE, BLUE_EDGE, BLUE_EDGE, BLUE_EDGE, PEACH_EDGE])
    x_last = 0.02 + 4 * (w + 0.030)
    for i, (lab, fc, ec) in enumerate([
            ("Verified", GREEN, GREEN_EDGE),
            ("Mismatch", "#F6E0DA", PEACH_EDGE),
            ("Unchecked (no value)", GREY, GREY_EDGE)]):
        bx = 0.02 + i * (0.32 + 0.010)
        box(ax, bx, 0.04, 0.32, 0.24, lab, fc=fc, ec=ec, fontsize=4.0,
            radius=0.010, fig_w=FW)
        arrow(ax, (x_last + w / 2, 0.42), (bx + 0.16, 0.28), color="#8A8A8A", lw=0.7)
    _save(fig, "fig15_dl_identity")


# ---------------------------------------------------------------------------
# Fig. 16 — The integrated loop, with the human as the terminal authority.
# ---------------------------------------------------------------------------

def fig16_feedback_loop() -> None:
    """Four stages arranged on a ring, with the reviewer at the centre.

    The arrows are drawn as outward arcs rather than straight chords: a chord
    between adjacent ring nodes passes straight through the middle of the
    figure, which in the first draft ran every connector through the centre
    box and through the node labels.
    """
    FW = 3.4
    fig, ax = _canvas(FW, 2.7)

    w, h = 0.34, 0.19
    nodes = [
        (0.33, 0.81, "Grounding\nclaims with offsets", PEACH, PEACH_EDGE),
        (0.66, 0.45, "ML\nevidence sufficiency", BLUE, BLUE_EDGE),
        (0.33, 0.09, "DL\nidentity and provenance", BLUE, BLUE_EDGE),
        (0.00, 0.45, "Evidence graph\ntyped and cited", GREEN, GREEN_EDGE),
    ]
    centres = []
    for x, y, lab, fc, ec in nodes:
        box(ax, x, y, w, h, lab, fc=fc, ec=ec, fontsize=3.9, radius=0.010,
            fig_w=FW)
        centres.append((x + w / 2, y + h / 2))

    for i in range(len(centres)):
        a, b = centres[i], centres[(i + 1) % len(centres)]
        ax.add_patch(FancyArrowPatch(
            a, b, arrowstyle="-|>", mutation_scale=7, color="#8A8A8A",
            lw=0.8, zorder=1, shrinkA=16, shrinkB=16,
            connectionstyle="arc3,rad=-0.42",
        ))

    box(ax, 0.30, 0.455, 0.40, 0.135, "Human reviewer\ndecides", fc="white",
        ec=NAVY, fontsize=4.1, weight="bold", radius=0.010, fig_w=FW, lw=1.1)
    ax.set_xlim(-0.06, 1.06)
    ax.set_ylim(0.03, 1.03)
    _save(fig, "fig16_feedback_loop")


def main() -> int:
    _style()
    fig01_dataflow()
    fig02_structure()
    fig03_taxonomy()
    fig04_review_method()
    fig05_layered_arch()
    fig06_failure_landscape()
    fig07_failure_distribution()
    fig08_regulatory_timeline()
    fig09_standards()
    fig10_grounding_gate()
    fig11_grounding_flow()
    fig12_ml_evolution()
    fig13_ml_roles()
    fig14_ml_tiers()
    fig15_dl_identity()
    fig16_feedback_loop()
    print(f"[acm-fig] output: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
