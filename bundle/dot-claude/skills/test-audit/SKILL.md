---
name: test-audit
description: Audit whether a project's tests still earn their runtime and maintenance cost. Maps behavior contracts to owners, identifies redundant or obsolete proof, and recommends KEEP, EXTEND, MERGE, REPLACE, DELETE, or ADD with evidence. Use --apply to implement proven portfolio changes.
argument-hint: "[scope] [--apply]"
disable-model-invocation: true
---
# Test Audit

Audit the test portfolio as maintained evidence, not an append-only archive. The goal is the smallest stable set that catches consequential regressions at an acceptable feedback cost. A high test count, high line coverage, old age, or an always-green history proves neither value nor waste.

Default budget: 20 minutes or 30% of the parent task, whichever comes first.
Do not inspect every assertion, run every suite, or build new audit machinery
inside that budget. If deeper proof would exceed it, report the residual risk
and ask for explicit authorization before continuing.

Arguments:

- `[scope]` limits the audit to a subsystem, behavior, changed path, or test family. With no scope, start from changed production paths and the slowest/most overlapping test families rather than reading every assertion indiscriminately.
- `--apply` authorizes implementing well-supported extensions, consolidations, replacements, or retirements. Without it, remain read-only and return the evidence table plus exact proposed changes.

## Workflow

1. **Establish the boundary.** Identify the behaviors and failure modes the scope must protect, their risk, and the delivery boundary (local iteration, pull request, release, migration, or incident fix).
2. **Inventory owners and cost at portfolio level.** Start with suite purpose, runtime, and overlap; inspect individual assertions only for a disputed high-consequence owner. If the repository exposes an audit command, use it. In oh-my-claude, `bash tools/run-tests.sh --audit` and `--list` are sufficient inventory inputs.
3. **Classify deliberately.** Assign exactly one action to each relevant owner:
   - `KEEP` — unique, stable proof at an appropriate layer.
   - `EXTEND` — the owner is right but needs the changed scenario.
   - `MERGE` — overlapping tests can share one clearer owner without losing detection power.
   - `REPLACE` — a cheaper or more stable layer can prove the same contract.
   - `DELETE` — the behavior contract is retired, or stronger retained proof demonstrably subsumes it.
   - `ADD` — a material live failure mode has no owner at any appropriate layer.
4. **Use proportional retirement evidence.** Require mutation/replay evidence only for a unique high-consequence owner. Duplicate, peripheral, obsolete, or low-consequence suites may be retired from ownership, overlap, and cost evidence; Git history is the recovery path. Never delete a test merely to make a failing run pass.
5. **Optimize the feedback path.** Put proof at the cheapest stable layer. During implementation run affected tests first; run the broad suite once when the change's coupling/risk or a release boundary warrants it. Slow end-to-end tests remain justified when only the integrated path can establish the contract.
6. **Apply, if authorized.** Prefer extending an existing owner over creating another file. Keep behavior names and failure intent legible. Update runner/CI ownership and contributor documentation when a portfolio boundary changes.
7. **Verify proportionally.** Prefer syntax, reference, runner-inventory, and CI-configuration checks for a portfolio-only change. Run affected retained proof once only when the budget and risk justify it; do not turn a deletion task into a new test-maintenance project.

## Output contract

Lead with the decision and estimated feedback-time impact. Then provide a compact table:

| Contract / failure | Current owner | Action | Evidence | Runtime / maintenance cost | Retained or new owner |
|---|---|---|---|---|---|

Separate proven changes from hypotheses that still need mutation or historical evidence. State the exact affected verification and whether a broad run is warranted now or only at the release boundary. If `--apply` was used, list changed/deleted test owners and the proof that no live contract became unowned.

Do not recommend test deletion from age, count, slowness, or aesthetic dislike alone. Do not use line coverage as the sole reason to add a test. Confidence per cost is the objective; behavioral risk is the constraint.
