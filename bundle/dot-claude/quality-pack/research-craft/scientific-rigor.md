# Scientific Rigor Doctrine

On-demand reference for the research-side agents (`research-data-analyst`, `rigor-reviewer`) and the `/data-analysis` skill. NOT in the global `@`-include chain — loaded only when scientific analysis work is in play, mirroring the `design-craft/` progressive-disclosure pattern.

The premise is Feynman's: *"The first principle is that you must not fool yourself — and you are the easiest person to fool."* Every rule below is an operational form of that sentence. An analysis that runs is not an analysis that is right; the discipline is what separates them.

## §1. The provenance contract

Every reported number is a claim about the world, and a claim without provenance is decoration.

- **Run-manifest beside every result.** Each generated figure or derived dataset gets a sidecar manifest recording: input file paths + content hashes, the producing script + git commit (or an explicit "uncommitted" flag), package versions (`pip freeze` / `conda env export` excerpt), RNG seed, and timestamp. When a number in a manuscript cannot be traced to a manifest, it is unverified by definition. (Pattern: Sandve et al. 2013, "Ten Simple Rules for Reproducible Computational Research", PLOS Comput Biol 9:e1003285 — rules 1, 4, 6, 8; The Turing Way, book.the-turing-way.org.)
- **Raw data is read-only.** Derived outputs live in a separate directory tree. No script ever writes into the raw-data tree; no manual edit ever touches a raw file. If a point must be excluded, it is excluded in code, with a comment naming why.
- **Scripts are the record; notebooks are the scratchpad.** Exploration in a notebook is fine. The result that enters a paper must be reproducible by running a script (or an executed, parameterized notebook via `papermill`/`nbconvert --execute`) from raw data with no hidden state.
- **Seed every stochastic step.** `np.random.default_rng(seed)` with the seed recorded in the manifest. "Roughly the same result each run" is not reproducibility.

## §2. Uncertainty discipline

A value without an uncertainty is not a measurement result.

- **Every reported quantity carries an uncertainty with a named method.** Statistical (from repeated measurements or fit covariance) and systematic (calibration, instrument, model) are stated separately when both matter — do not silently quadrature them into one number without saying so.
- **Propagation is computed, not eyeballed.** Analytic first-order propagation (partial derivatives), the `uncertainties` Python package for algebraic pipelines, or Monte Carlo resampling when the function is nonlinear enough that first-order lies. Name which one was used.
- **Significant figures follow the uncertainty.** Round the uncertainty to 1–2 significant figures; round the value to the same decimal place. `3.14159 ± 0.2` is a contradiction in typography.
- **Dimensional analysis at every equation.** Units are checked symbolically before numbers go in. A fit parameter has units; report them. When an extracted parameter is unphysical, that is a finding about the model, not a rounding detail (see §4).

## §3. Error-bar disclosure

The rules from Cumming, Fidler & Vaux 2007 ("Error bars in experimental biology", J Cell Biol 177:7–11) generalize to all experimental fields:

1. The figure caption states **what the bars are** — SD, SEM, or a confidence interval — every time. An undefined error bar is noise drawn on top of data.
2. **N is stated, and N counts independent replicates**, not repeated readings of the same sample. Repeated readings estimate instrument noise; replicates estimate the quantity's variability.
3. **n = 1 gets no error bar and no significance claim.**
4. For comparisons between conditions, prefer **inferential bars (SEM or CI)** over descriptive SD, and say which.
5. When n is small, **plot the raw points** — a bar hiding three points is worse than the three points.
6. When error bars are smaller than the markers, **say so in the caption** rather than letting the reader infer zero uncertainty.

## §4. Fitting discipline

A converged fit is not a correct model. The checklist:

- **Justify the model** before fitting it — physical grounds, prior literature, or an explicit "empirical parametrization" label. Never present an empirical convenience as a physical extraction. (Canonical example: Simmons-model fits to tunneling IV data routinely return effective masses far below the electron mass — the parameters are a fitting convenience unless independently corroborated, and honest work says so.)
- **Report fit quality, always**: reduced chi-squared when point uncertainties are known, plus a residual plot. Structure in the residuals (trends, waves) means the model is wrong, no matter how good the headline statistic looks.
- **Reduced chi-squared calibration**: ~1 means consistent with stated errors; >> 1 means underestimated errors or wrong model; << 1 means overestimated errors or overfitting. Both directions are findings — neither is "extra good".
- **Parameter uncertainties come from the covariance matrix only when the errors fed in are real.** `scipy.optimize.curve_fit` silently rescales the covariance unless `absolute_sigma=True` — with measured uncertainties, set it and say so; without them, the "parameter errors" are relative-quality indicators, not absolute uncertainties. This single pitfall invalidates more reported fit errors than any other.
- **Guard against over-parametrization.** Compare nested models with an F-test or AIC/BIC before adding a parameter. Two exponentials always fit better than one; that is arithmetic, not evidence.
- **Initial-guess sensitivity check** for nonlinear fits: refit from perturbed starting points; a fit that lands elsewhere is reporting a local minimum, not a result.
- **Fit the rawest usable form of the data.** Fitting smoothed, binned, or otherwise pre-processed data hides correlated errors — when unavoidable, propagate the processing into the error model and disclose it.
- **Never report a parameter without its uncertainty and units.** No exceptions.

## §5. Statistics honesty

- **State what varies and what is fixed** — across traces, samples, devices, days. Aggregating over hidden structure (batch effects, device-to-device drift) manufactures precision.
- **Selection bias is disclosed, not just avoided.** When analysis keeps a subset (traces with plateaus, cells that survived, runs that converged), report total-collected vs total-used and the selection rule. A histogram built from selected events without the selection rule stated is the classic silent bias of experimental practice — reviewers increasingly expect the yield percentage in the caption or methods.
- **No p-hacking shapes**: the analysis choice (test, binning, exclusion rule) is fixed before the comparison is scored wherever possible; when a choice was made after seeing data, say so. Multiple comparisons get corrected or at minimum counted.
- **Correlation language stays correlational.** "Consistent with", not "demonstrates", unless the design supports causation.

## §6. The assumptions log

Every substantive analysis deliverable ends with an explicit **Assumptions & choices** block: binning choices, exclusion rules, calibration constants, background subtraction, outlier policy, smoothing (display-only or not) — each with a one-line WHY. The log is what lets a colleague (or a future you, or a referee) re-derive the result instead of trusting it. An analysis whose choices cannot be enumerated was not designed; it accreted.

## §7. Non-obvious calls

The judgment calls that separate rigorous work from plausible-looking work:

- **Smoothing for display vs fitting the smoothed curve.** Display smoothing is legitimate when labeled; fitting to smoothed data quietly correlates the residuals and shrinks the reported errors. Fit raw, overlay smooth.
- **"The fit converged" vs "the model is right."** Convergence is a property of the optimizer. Model correctness is argued from residuals, alternatives compared, and physical plausibility of parameters.
- **Log axes are physics decisions, not cosmetics.** Choose log when the phenomenon is multiplicative/exponential (decades of conductance, power laws); then remember error bars become asymmetric and quote them accordingly.
- **The outlier you remove is a claim.** Every exclusion is either rule-based (stated in §6) or it is data editing.
- **Precision theater**: quoting six digits from a fit whose dominant systematic is 10% misleads exactly like a fabricated number. Report the honest digit count (§2).
- **Negative results are results.** A fit that fails, a peak that is absent, a null control — recorded with the same provenance as successes; the file that only ever accumulates confirmations is itself a bias instrument.

## §8. How agents use this file

- `research-data-analyst` applies §1–§6 during analysis and emits the §1 run-manifest and §6 assumptions log as part of its deliverable — they are output contracts, not suggestions.
- `rigor-reviewer` audits deliverables against every section and cites the violated §-number in each finding.
- The `/data-analysis` skill sequences the workflow so these checks happen during the work, not as a post-hoc pass.

Companion references: `~/.claude/quality-pack/research-craft/figure-craft.md` (publication figures), `~/.claude/quality-pack/research-craft/citation-integrity.md` (literature and references).

Sources: Cumming, Fidler & Vaux 2007, J Cell Biol 177:7–11 (doi:10.1083/jcb.200611141); Sandve et al. 2013, PLOS Comput Biol 9:e1003285 (doi:10.1371/journal.pcbi.1003285); The Turing Way (book.the-turing-way.org); Feynman, "Cargo Cult Science", Caltech commencement address 1974.
