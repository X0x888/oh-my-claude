---
name: autowork
description: Maximum-autonomy professional work mode. Use for non-trivial coding, writing, research, planning, or mixed tasks that should be carried through the right specialist workflow with minimal hand-holding.
argument-hint: "[task]"
disable-model-invocation: true
---
# Autowork

Primary task:

$ARGUMENTS

`core.md` owns the no-defer, pause, scope, and depth contracts. The prompt router owns current intent/domain/risk classification and model guidance. Follow those injected decisions; this skill adds only the orchestration loop below.

## Orchestration loop

1. **Frame.** Preserve the router's execution/continuation opener. For advisory or session-management intent, answer directly and do not mutate. For ambiguous execution, state one reasonable interpretation and proceed; ambiguity alone is not a pause case.
2. **Shape.** For non-trivial work, use the smallest specialist set that materially improves the result. Give parallel agents non-overlapping questions and a shared evidence packet or precise paths; do not make each rediscover the repository. Use a planner once for a stable multi-wave graph, then reuse its slices until a dependency, risk, or verified assumption changes.
3. **Execute.** Make coherent, testable changes. Examples name a class, not necessarily the whole class: record sibling scope through `record-scope-checklist.sh` when that gate is active. Segment large work into in-session waves rather than stopping between them.
4. **Verify.** Inspect existing proof before adding tests; choose `KEEP`, `EXTEND`, `MERGE`, `REPLACE`, `DELETE`, or `ADD` by unique behavioral value, stability, runtime, and maintenance cost. Run affected proof after the final relevant mutation, then the broad suite once only when risk or the delivery boundary warrants it. Keep full logs on disk and inject only the outcome, counts, and failing tail. Lint-only is not sufficient for executable behavior.
5. **Review one settled revision.** Run the universal surface reviewer (`quality-reviewer` for code, `editor-critic` for prose) plus only the adaptive dimensions and semantic risks that current evidence requires. Launch distinct required reviewers concurrently, keep the diff frozen until all return, reconcile once, and remediate once. When `excellence-reviewer` runs in parallel, dispatch quality-reviewer with `REVIEW MODE: defects-only` to avoid duplicate completeness analysis.
6. **Re-review economically.** Give a remediation reviewer prior finding IDs/anchors and the newly changed hunks. Re-run only roles whose surfaces changed; expand to the full diff when public contracts, dependencies, or multiple surfaces changed.
7. **Preflight, then close once.** Confirm every explicit and reasonably implied item, proof, verdict, and delivery action. Before completion prose, require the hidden `OMC INTERNAL CLOSEOUT PREFLIGHT: READY` context; if it has not arrived, run `bash "$HOME/.claude/skills/autowork/scripts/closeout-preflight.sh" "${CLAUDE_SESSION_ID}"`. `NOT_READY` means continue working without a provisional summary. After `READY`, call no more tools and write one self-contained cumulative replacement covering the original objective, all material changes, exact verification, findings/dispositions, residual risks, and next state—never a delta from an earlier attempt. Every material closeout includes standalone `**Changed.**`/`**Shipped.**`, `**Verification.**`, `**Objective coverage.**` (or the stricter `/goal` `**Goal achieved.**` block), and `**Next.**` labels.

## Fan-out policy

- Start with one strong primary agent. Add another only for independent domain coverage, unresolved uncertainty, conflicting evidence, sensitive edits, weak verification, or a meaningful finding.
- Quality is economically primary: a cheaper model that causes extra turns, false findings, or rework is more expensive. Follow the quality-first model resolver; inherited deliberators ride the current session model, and temporary model names are never hard-coded here.
- `workflow_substrate=on` authorizes the Workflow tool for observable heavy shapes—at least three waves or roughly ten projected dispatches. Small work stays in-thread to avoid orchestration overhead.
- Reviewer findings are evidence-bearing inputs, not automatic truth. Verify cited evidence, act by default, and reject only through a concrete false-positive/not-reproducible path. Mechanical gate blocks are not reviewer opinions and cannot be reasoned around.

## Delivery discipline

- The user's request is permission. Ask only for a genuine operational blocker or user-owned destructive/shared-state decision named by `core.md`.
- Do not split unfinished scope across sessions. “Wave 2/5 starting now” is valid; “wave 2 next session” is not.
- Prefer ship inline → wave-append → evidence-backed reject. Under default ULW execution, effort, size, taste, or “later” do not authorize deferral.
- Before review, self-check requested components so the reviewer finds subtle defects rather than discovering half the task was never built.
- Before Stop, re-read changed files, run proof, resolve structured findings, and make any requested commit/publish action.
- Final output leads with the result, names changed behavior and exact verification, and surfaces only real residual risk. Do not restate long gate narration.
