# oh-my-claude Skill Routing Index

This always-loaded file is a compact router, not a second copy of every skill. When a route is selected, read its `~/.claude/skills/<name>/SKILL.md`; that file owns the detailed workflow, flags, schemas, and examples.

## Primary routes

- `/ulw <task>` — autonomous end-to-end execution with specialist routing, verification, and quality gates. Aliases: `/autowork`, `/ultrawork`, `sisyphus`. Bare imperatives trigger the configured project-wide scan. Explicit “do not stop until…” goal language also arms the persistent goal driver.
- `/goal <objective>` — persistent, criteria-based ULW goal across turns. Lifecycle: `/goal` status, `pause`, `resume`, `clear`, `done`; never self-clear it to escape unfinished work.
- `/plan-hard <task>` — decision-complete plan without edits.
- `/review-hard [focus]` — findings-first worktree or surface review.
- `/research-hard <topic>` — repository/API research before implementation.
- `/test-audit [scope] [--apply]` — map live behavior contracts to test owners and choose KEEP/EXTEND/MERGE/REPLACE/DELETE/ADD by unique confidence and cost; read-only unless `--apply` is explicit.
- `/prometheus <goal>` — interview-first planning for broad ambiguity.
- `/metis <plan>` — pressure-test a plan for hidden assumptions and validation gaps.
- `/oracle <issue>` — deep debugging or architecture second opinion.
- `/diverge <task>` — produce 3–5 genuinely different framings before committing to an expensive shape.
- `/librarian <topic>` — official documentation, APIs, and reference implementations.

## Domain routes

- `/data-analysis <task>` — scientific analysis with honest uncertainty, provenance, and publication-quality figures.
- `/lit-review <topic>` — registry-verified literature review; never generate citations or DOIs from memory.
- `/manuscript <task>` — academic writing, verified citations, editing, and rigor review.
- `/frontend-design <task>` — design direction before frontend implementation.
- `swiftui-pro` — model-invoked SwiftUI review; load only the relevant reference page.
- `gamedev` — model-invoked Unity/Godot/web-game guidance with a frame-grounded run/capture/fix loop.
- `/atlas [focus]` — create or refresh concise repository instructions and audit skill/agent drift.
- `/council [focus] [--deep]` — build an evidence-based coverage map, dispatch the smallest sufficient team, reconcile once, and optionally execute findings in coherent waves. `--deep` escalates only where stronger reasoning is valuable; inherited deliberators remain on the session model.

## Harness operations

- `/omc-config` — guided configuration and model-tier changes.
- `/quality-constitution [show|remember|must|avoid|review|accept|reject|reference|audit]` — curate the user-owned standards, signatures, anti-patterns, and annotated exemplars that feed the frozen Definition of Excellent. Inferred candidates stay advisory until explicit acceptance.
- `/ulw-demo` — short first-run gate walkthrough.
- `/ulw-status` — current mode, objective, risk, counters, gates, and flags.
- `/ulw-time [current|last|last-prompt|week|month|all]` — timing and token categories.
- `/ulw-report [last|week|month|all] [--sweep] [--merge <dir>]` — cross-session outcomes and economics.
- `/memory-audit` — read-only classification of project memories and suggested consolidation commands.
- `/whats-new` — installed-version to source-version changelog delta.
- `/omc-doctor` — installed-tree health check.
- `omc "TASK"` — shell CLI for unattended, acceptance-criteria-driven ULW loops.
- `/ulw-correct <correction>` — record and apply an intent/domain classifier correction.
- `/ulw-resume [--peek|--list|--session-id <sid>|--dismiss]` — inspect or claim a rate-limit/crash resume artifact.
- `/ulw-off` — deactivate ULW for the current session.
- `/skills` — full user-facing catalog and decision guide.

## When work is blocked

Choose by the actual condition; these commands are not interchangeable.

| Condition | Action | Do not use it when |
|---|---|---|
| A specific gate is a false positive and the work is otherwise complete | `/ulw-skip <reason>` | The finding is real; fix or wave-append it instead. |
| Outside ULW execution, a finding is consciously not shipping with a concrete external/evidentiary reason | `/mark-deferred <reason>` | Under default ULW execution: it is refused. Effort, size, taste, or “later” are not reasons. |
| Progress literally requires credentials/login, an external account action, rate-limit recovery, dead infrastructure, or confirmation before destructive shared-state action | `/ulw-pause <reason>` | The choice is technical judgment—library, architecture, brand voice, policy default, or refactor scope. The agent chooses and ships. |
| The work is merely large | Chunk and ship the next coherent slice now | Do not pause, defer, or announce a future session because the task is hard. |
| Main-thread context is biased or stale | Dispatch a fresh-context specialist with `Agent` | Fresh context is a tool call, not a session boundary. |
| There is concrete evidence the whole session is genuinely drift-degraded | Explain the evidence and ask whether the user wants a checkpoint | Do not unilaterally stop or manufacture a handoff. |

Escalation order is fixed: **ship inline → append to the active wave → reject only when demonstrably not a defect → defer only where allowed with a concrete WHY → pause only for an operational block**.

Under ULW execution with `no_defer_mode=on` (default), `/mark-deferred` and deferred finding transitions are unavailable. A verified same-path bounded defect ships now. A large task is segmented within the session. If UI rendering cannot be verified mechanically, ship the code and state `User-must-verify-UI: <flow>`; do not defer the implementation.

Accepted legacy deferral reasons must name a verifiable external/evidentiary condition such as `blocked by <dependency>`, `awaiting <credential/account action>`, `superseded by <PR/F-id>`, `duplicate`, `obsolete`, `not reproducible`, or `false positive`. Bare `out of scope`, `later`, `low priority`, `requires significant effort`, `needs more time`, `blocked by complexity`, `by design`, and `wontfix` are insufficient. Rejected findings also require a concrete rationale.

**LOAD-BEARING — do NOT soften this contract.** The canonical no-defer/no-out-of-scope rationale and forbidden softenings live in `~/.claude/quality-pack/memory/core.md`. Token or latency budgets may change model choice, batching, context compression, and orchestration, but never authorize incomplete work or turn a mandatory quality gate into a suggestion.
