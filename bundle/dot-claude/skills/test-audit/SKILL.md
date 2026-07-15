---
name: test-audit
description: Audit whether a project's tests still earn their runtime and maintenance cost. Maps behavior contracts to owners, identifies redundant or obsolete proof, and recommends KEEP, EXTEND, MERGE, REPLACE, DELETE, or ADD with evidence. Use --apply to implement proven portfolio changes.
argument-hint: "[scope] [--apply]"
disable-model-invocation: true
---
# Test Audit

Audit the test portfolio as maintained evidence, not an append-only archive. The goal is the smallest stable set that catches consequential regressions at an acceptable feedback cost. A high test count, high line coverage, old age, or an always-green history proves neither value nor waste.

Arguments:

- `[scope]` limits the audit to a subsystem, behavior, changed path, or test family. With no scope, start from changed production paths and the slowest/most overlapping test families rather than reading every assertion indiscriminately.
- `--apply` authorizes implementing well-supported extensions, consolidations, replacements, or retirements. Without it, remain read-only and return the evidence table plus exact proposed changes.

## Workflow

1. **Establish the boundary.** Identify the behaviors and failure modes the scope must protect, their risk, and the delivery boundary (local iteration, pull request, release, migration, or incident fix).
2. **Inventory owners and cost.** Map each live contract to the test or check that owns it. Record layer, runtime when measurable, fixture/setup burden, flake history or brittleness evidence, and overlap with other owners. If the repository exposes a change-aware runner or audit command, use it; in oh-my-claude's source tree, use `bash tools/run-tests.sh --audit` and `bash tools/run-tests.sh --list` as inputs, not as automatic deletion authority.
3. **Classify deliberately.** Assign exactly one action to each relevant owner:
   - `KEEP` — unique, stable proof at an appropriate layer.
   - `EXTEND` — the owner is right but needs the changed scenario.
   - `MERGE` — overlapping tests can share one clearer owner without losing detection power.
   - `REPLACE` — a cheaper or more stable layer can prove the same contract.
   - `DELETE` — the behavior contract is retired, or stronger retained proof demonstrably subsumes it.
   - `ADD` — a material live failure mode has no owner at any appropriate layer.
4. **Prove retirement.** Before `MERGE`, `REPLACE`, or `DELETE`, establish the retained owner's equivalence with a deliberate mutation/counterfactual, historical defect replay, contract trace, or comparably strong evidence. Run the retained proof against the failure it claims to catch. Never delete merely because a test is old, slow, flaky, implementation-coupled, or always green; repair or replace a valuable owner. Never delete a test to make a failing run pass.
5. **Optimize the feedback path.** Put proof at the cheapest stable layer. During implementation run affected tests first; run the broad suite once when the change's coupling/risk or a release boundary warrants it. Slow end-to-end tests remain justified when only the integrated path can establish the contract.
6. **Apply, if authorized.** Prefer extending an existing owner over creating another file. Keep behavior names and failure intent legible. Update runner/CI ownership and contributor documentation when a portfolio boundary changes.
7. **Verify the portfolio, not just green status.** Re-run affected retained/changed proof, exercise any retirement counterfactual, then run the appropriate broad/release check once. A green suite with an unowned live contract is incomplete; a red test is evidence to diagnose, not a deletion cue.

## Output contract

Lead with the decision and estimated feedback-time impact. Then provide a compact table:

| Contract / failure | Current owner | Action | Evidence | Runtime / maintenance cost | Retained or new owner |
|---|---|---|---|---|---|

Separate proven changes from hypotheses that still need mutation or historical evidence. State the exact affected verification and whether a broad run is warranted now or only at the release boundary. If `--apply` was used, list changed/deleted test owners and the proof that no live contract became unowned.

Do not recommend test deletion from age, count, slowness, or aesthetic dislike alone. Do not use line coverage as the sole reason to add a test. Confidence per cost is the objective; behavioral risk is the constraint.
