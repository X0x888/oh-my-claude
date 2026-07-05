---
name: data-analysis
description: Scientific data-analysis workflow — explore, fit with honest uncertainties, and produce publication-quality figures with full provenance. Use for experimental/measurement data (spectra, traces, curves, instrument output) where the output must survive peer review, not just run.
argument-hint: "<analysis task>"
disable-model-invocation: true
---
# Scientific Data Analysis

Analyze experimental data to a publication-credible standard — provenance, uncertainties, and figures a referee cannot bounce.

Primary task:

$ARGUMENTS

## Research-Craft Calibration (read before analyzing)

Full doctrine — read both when the task is substantive:

- `~/.claude/quality-pack/research-craft/scientific-rigor.md` — provenance, uncertainty, fitting, statistics
- `~/.claude/quality-pack/research-craft/figure-craft.md` — journal specs, color, submission-readiness

The non-negotiable baseline, inline:

1. **Run-manifest beside every result** — inputs + hashes, script + commit, package versions, seed, timestamp.
2. **Every value carries an uncertainty with a named method**; significant figures follow the uncertainty.
3. **Error bars defined every time** (SD vs SEM vs CI, with N counting independent replicates — Cumming rules).
4. **Fitting discipline**: justify the model; residual check + reduced chi-squared (read in BOTH directions); `absolute_sigma=True` when real measurement errors go into `curve_fit`; nested-model comparison before adding parameters; no parameter without uncertainty and units.
5. **Selection-bias disclosure**: total-collected vs total-used + the rule, whenever a subset is analyzed.
6. **Assumptions log** closes every deliverable — binning, exclusions, calibration constants, smoothing, each with a WHY.
7. **Figures at final journal size** (Nature ~89 mm / APS 86 mm single column), fonts at/above the journal minimum at that size, Okabe-Ito categorical / viridis-cividis sequential, axes labeled with units — then the figure-craft §7 submission-readiness check, line by line.

## Workflow

1. **Understand the data first.** Format, units, ranges, missingness, outliers; plot raw data before any model is proposed. State what question the analysis must answer.
2. **Dispatch or execute.** For substantive analysis, dispatch `research-data-analyst` (it carries the full rigor contract); trivially small asks can run inline under the same baseline. For repo-convention questions (where do figures live, which style module), check the project before imposing structure.
3. **Model → fit → propagate.** Justify the model, fit with diagnostics, propagate uncertainty to the quantity the user actually cares about.
4. **Figures per figure-craft**, captions carrying N + error definition + method.
5. **Emit the manifest and assumptions log** — they are output contracts, not embellishments.
6. **Audit.** After substantive analysis, dispatch `rigor-reviewer` — it checks provenance, uncertainty treatment, fit validity, selection bias, figure compliance, and stale numeric claims, citing doctrine sections per finding. Act on its findings before declaring done.

## Execution rules

- Follow all `/autowork` operating rules: verify, review, don't stop early.
- Verification here means **running the analysis end-to-end from raw inputs** and confirming the manifest + figures + assumptions log exist and agree with the code — not reasoning that they should.
- Verification-cost discipline: headless matplotlib (`MPLBACKEND=Agg`, never `plt.show()`); figure checks are mechanical-first (code-assertable width/fonts/format/colors), with **at most one** visual read-back of the final figure — repeated image reads are the slowest loop available.
- Reproducibility is part of done: a competent stranger (or tomorrow's session) must be able to regenerate every figure with one command.
- When the data cannot support the question asked (insufficient N, missing calibration, confounded design), say so plainly — that is a result, not a failure.
