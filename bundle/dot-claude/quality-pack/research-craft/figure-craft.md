# Figure Craft Doctrine

On-demand reference for `research-data-analyst`, `rigor-reviewer`, and the `/data-analysis` + `/manuscript` skills. NOT in the global `@`-include chain — loaded when publication figures are in play. Complements `design-craft/` (which owns UI surfaces); this file owns **print-destined scientific figures**, where the constraints are journal-mechanical, not brand-aesthetic.

## §1. A figure is an argument

One figure, one message. If the message cannot be stated in one sentence, it is two figures. The caption carries the argument stand-alone: what is plotted, how it was obtained (method + key conditions), what N is, and **what the error bars are** (see `scientific-rigor.md` §3). A reader who sees only the figures and captions should leave with the paper's claims — referees routinely read exactly that way.

## §2. Journal mechanical specs

Design at **final printed size** from the first draft — never design a full-screen plot and scale it down (fonts and line weights scale down with it, which is the #1 cause of unreadable figures). The numbers that matter, from the publishers' own artwork guidelines:

| Venue family | Single column | Double column | Minimum lettering | Notes |
|---|---|---|---|---|
| Nature / Springer Nature | ~89 mm | ~183 mm | 5–7 pt at final size; 8 pt bold panel labels (a, b, c) | Max height ~170 mm; sans-serif (Arial/Helvetica) |
| APS (PRL, PRB, PR Applied) | 86 mm (3 3/8 in) | ~172 mm | lettering ≥ 2 mm tall | Line weight ≥ 0.5 pt; raster ≥ 600 dpi |
| ACS (JACS, Nano Lett., ACS Nano) | 3.25 in (82.5 mm) | 7 in (178 mm) | ≥ 4.5 pt Helvetica/Arial | Line art 1200 ppi; halftone 300 ppi |

(Sources: nature.com formatting guide; APS Physical Review Style and Notation Guide, journals.aps.org/authors; ACS graphics preparation, pubs.acs.org. Re-check the target journal's current page before submission — these drift slowly but they do drift.)

Working rule: set the matplotlib figure width to the target column width in inches (89 mm = 3.50 in; 86 mm = 3.39 in; 183 mm = 7.20 in) and never rescale afterward.

## §3. Color discipline

- **Categorical**: the Okabe-Ito colorblind-safe palette is the default — `#000000`, `#E69F00`, `#56B4E9`, `#009E73`, `#F0E442`, `#0072B2`, `#D55E00`, `#CC79A7` (Okabe & Ito 2008, jfly.uni-koeln.de/color). 3–5 series per panel; beyond that, facet.
- **Sequential**: `viridis` (perceptually uniform) or `cividis` (optimized for red-green color-vision deficiency). **Never rainbow/jet** — it manufactures false boundaries and is the canonical bad-colormap example in the perceptual-uniformity literature.
- **Diverging** (signed data around a meaningful zero): `RdBu_r` or `coolwarm`, centered on the zero.
- **Redundant encoding**: distinguish series by marker shape and line style as well as color, so grayscale print and photocopies survive. Check every figure once in grayscale.
- Color means something or it is not used. Decorative color is chartjunk (§6).

## §4. The matplotlib baseline

A publication figure starts from a deliberate rcParams block, not library defaults:

```python
import matplotlib.pyplot as plt

MM = 1 / 25.4  # mm→inch
plt.rcParams.update({
    "figure.figsize": (89 * MM, 60 * MM),   # single column, final size
    "font.size": 7, "axes.labelsize": 7,     # at/above journal minimum AT FINAL SIZE
    "legend.fontsize": 6, "xtick.labelsize": 6, "ytick.labelsize": 6,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Helvetica", "DejaVu Sans"],
    "lines.linewidth": 1.0, "axes.linewidth": 0.5,
    "pdf.fonttype": 42, "ps.fonttype": 42,   # embed TrueType — editable text, no Type-3 traps
    "savefig.dpi": 600,
})
fig, ax = plt.subplots(layout="constrained")  # not tight_layout-after-the-fact
```

- **Vector formats (PDF/EPS/SVG) for line art**; high-DPI PNG/TIFF (≥600 dpi, per §2) only for image-like panels (heatmaps with many cells, micrographs).
- **[SciencePlots](https://github.com/garrettj403/SciencePlots)** (`pip install SciencePlots`, then `plt.style.use(["science", "nature"])`) is a maintained shortcut providing `science`, `nature`, and `ieee` styles plus colorblind-safe cycles — a sane base to override rather than a replacement for knowing §2's numbers.
- Multi-panel figures: consistent fonts/weights across panels (mixed panel typography is the visual tell of assembled-not-designed), bold lowercase panel labels, shared axes where the comparison is the point.
- Every axis is labeled with quantity **and unit** (`Conductance (G/G₀)`, `Bias (V)`). Dimensionless is a unit statement too.

## §5. Uncertainty on the page

- Error bars per `scientific-rigor.md` §3: defined in the caption, N stated, inferential-vs-descriptive named.
- Dense series → **shaded uncertainty band** instead of a picket fence of bars.
- On log axes, uncertainties are asymmetric — draw the true asymmetric interval, don't symmetrize for looks.
- When bars are smaller than markers, the caption says so explicitly.
- Fits drawn over data: plot the **residuals** (inset or sub-panel) when the fit quality is part of the claim.

## §6. Anti-patterns (ban these)

- Rainbow/jet colormaps; red-green-only series distinctions.
- Screenshot-of-a-plot pasted into a manuscript (raster text, wrong size, lost vectors).
- Double y-axes without a forcing reason — they invite false correlation reading; prefer stacked panels.
- Smoothed curves presented as data — display smoothing is labeled or absent (`scientific-rigor.md` §7).
- Unlabeled insets, unlabeled arrows, "see text" captions.
- Legends restating the axis label; legends outside the column width.
- Gridlines heavier than data; box-and-spine clutter the style file already handles.
- Font sizes below the §2 journal minimum after placement at final size — the single most common resubmission request.

## §7. Submission-readiness check

Run mechanically before calling any figure done — each line is checkable without judgment:

1. Figure width equals the target column width (mm), and it was **designed** at that size, not scaled to it.
2. Smallest text ≥ the journal minimum (§2) at final size.
3. Colors drawn from a colorblind-safe cycle (§3); grayscale check passed; series distinguishable by shape/style too.
4. Every axis labeled with unit; every panel labeled; caption defines error bars + N + method in one read.
5. Vector format for line art; ≥600 dpi for rasters; fonts embedded (fonttype 42).
6. The run-manifest (`scientific-rigor.md` §1) for this figure exists and points at the exact script + commit + data hash that produced it.
7. The figure's one-sentence message (§1) is actually visible — one visual pass on the final composed figure (a fresh eye, a fresh agent, or a single image read-back) confirms it. Lines 1–6 are mechanical and code-checkable — run them in the script first; do not iterate aesthetics through repeated image read-backs (each is a heavyweight vision round; the mechanical checks are the loop, vision is the confirmation).

## §8. How agents use this file

- `research-data-analyst` applies §2–§5 while producing figures and runs the §7 check before returning them; the check's outcome (each line pass/fail) is part of its deliverable.
- `rigor-reviewer` audits figures against §2–§7 and cites the violated §-number per finding.
- `/manuscript` treats §1 (caption carries the argument) as a drafting requirement, not a polish step.

Companion: `~/.claude/quality-pack/research-craft/scientific-rigor.md` (error-bar semantics, provenance), `~/.claude/quality-pack/research-craft/citation-integrity.md` (references).
