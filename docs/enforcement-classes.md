# Enforcement Classes — what `core.md` actually binds

> A companion to `docs/bypass-taxonomy.md`. The bypass-taxonomy doc names
> defense categories for stop-guard bypass closures. This doc takes the
> broader view: every rule in `core.md` falls into one of **six**
> enforcement classes, only five of which mechanically bind. The sixth —
> **behavior-only** — depends on model attention and degrades silently.
> Making the line between the two visible lets users (and future
> agents reading the doc) calibrate trust correctly.

## Why this doc exists

`core.md` reads as a single coherent body of binding rules. In practice
it isn't. Some rules are mechanically enforced by hook scripts that
inspect state, tool calls, or prose at lifecycle boundaries; others are
prose the model is *supposed* to attend to but has no mechanical
guardrail.

A user reading `core.md` cannot easily tell the difference. That
ambiguity is doing real epistemic damage — it shifts *perceived* risk
without shifting *actual* risk. The honest move is to publish the line.

The trigger for writing this doc was a real failure mode: the user
reported that an attention-only rule (`Hygiene: clean up after
yourself` in `core.md`) was violated across multiple sessions —
producing 4 stuck `omc-resume-*` tmux sessions accumulating 25-51
CPU-minutes each, plus 56 `/tmp/omc-sterile-tmp-*` dirs — while every
*gated* rule held its line in the same sessions. The taxonomy below
explains why.

## The six classes

| Class | Mechanism | Durability | Lives in |
|---|---|---|---|
| **state-predicate** | Reads ledgered state (`findings.json`, edit-clock, `gate_events.jsonl`). | **Highest** — open-vocabulary prose drift cannot bypass. | `bundle/dot-claude/skills/autowork/scripts/stop-guard.sh` + record-* helpers |
| **single-call-flip** | Refuses a specific script invocation that would atomically flip the work into a bypassable state. | **Medium-high** — surface is small, input validator scoped. | `ulw-pause.sh`, `ulw-correct-record.sh`, `record-finding-list.sh status …` |
| **classifier-misroute** | Anchored to per-prompt classifier output the router writes once and doesn't mutate mid-turn. | **Medium-high** — classifier vocabulary must keep pace. | `lib/classifier.sh` + `prompt-intent-router.sh` |
| **prose-pattern** | Regex on the agent's last assistant message. | **Lowest among mechanical** — open-vocabulary drift; hard cap ≤3 active defenses. | `common.sh` handoff matchers + closing-region scan |
| **PreTool boundary** | Refuses a tool call before execution based on the tool input itself (command string, file path, parameters). | **High when input signature is unambiguous** (e.g., `nohup`/`setsid`); lower when shape-based. | `pretool-intent-guard.sh` (agent-first invariant, contract gates, **bg-spawn hygiene** new in v1.43.x) |
| **behavior-only** | **No mechanism.** Rule lives only as prose in `core.md`, loaded into context, supposed to bind through model attention. | **Lowest, full stop.** Degrades silently with context length. | `core.md` Thinking Quality + most of Workflow + Hygiene + several FORBIDDEN entries |

Classes 1-4 are documented as a unified surface in `docs/bypass-taxonomy.md`
(specifically about stop-guard bypass closures). Class 5 is the **broader
PreTool defense surface** — the agent-first invariant, the commit/push
contract gates, and now the bg-spawn hygiene gate. Class 6 is the
**implicit category** every `core.md` rule that has no script enforcement
falls into; until this doc, it was unnamed.

**Producer coverage is part of a state-predicate's durability.** A correct
Stop condition over `last_edit_ts` is not mechanically binding if one shipped
mutation tool never writes that clock. F-016 closes that gap for NotebookEdit
and Bash: every non-trivially-read-only foreground Bash call in Git receives a
before/after snapshot, including opaque scripts and Git commands whose ambient
helpers/hooks may execute. Snapshot plumbing disables those helpers internally;
delivery compares a normalized worktree identity so expected HEAD/index changes
stay quiet while hook-written bytes do not. Recognized write syntax is the
conservative fallback for ignored/unobservable changes, and oversized,
conflicted, dirty-submodule, and all asynchronous snapshot candidates fail
closed rather than sampling or comparing an unsound state.
The existing Stop predicate then applies unchanged. State-ledger audits must
verify both the consumer predicate and every producer surface, not just grep
for the Stop condition.

## Class detail: PreTool boundary

PreToolUse hooks inspect every tool call before it executes. The
`pretool-intent-guard.sh` script is the canonical home for these
defenses. As of v1.43.x it hosts three distinct gates, all PreTool
boundary class:

| Gate | Trigger | Disable flag |
|---|---|---|
| Agent-first invariant | Workspace mutation under `/ulw` execution before any fresh-context specialist returned | Off by default; enable with `agent_first_gate=on`. The master `OMC_PRETOOL_INTENT_GUARD=false` / `pretool_intent_guard=false` kill switch also disables its denial decision. |
| Commit/push contract | Destructive `git`/`gh` op under `commit_contract_mode=forbidden` or `push_contract_mode=forbidden` | (same as above; gates share the script kill switch) |
| **bg-spawn hygiene** *(v1.43.x)* | Bash command pairing `(until\|while) ... do ... sleep` (loop body marker required) with `run_in_background:true`, trailing `&`, or `nohup`/`setsid`. Quoted prose is stripped before matching so `echo "wait until ready"` doesn't false-positive. | `OMC_BG_SPAWN_GATE=false` / `bg_spawn_gate=false`; also disabled when `OMC_PRETOOL_INTENT_GUARD=false` (gates share the script kill switch) |

The shared `pretool_intent_guard=false` kill switch disables these denial and
hygiene decisions, but not Bash mutation-baseline capture. That capture is an
observability producer for the later edit-clock Stop predicate; turning off an
intent gate must not make completed workspace edits invisible.

PreTool boundary defenses are **distinct from stop-guard defenses**:

- Stop-guard fires at the end of a turn. Bypasses are about the agent
  stopping short of finishing the work.
- PreTool fires before any specific tool call. Bypasses are about the
  agent executing a tool call that violates an invariant.

Both classes catch different shapes of failure. The bg-spawn gate is the
proof-of-concept that PreTool boundary defenses can also close
attention-only failure modes that prose alone couldn't prevent.

## Class detail: behavior-only

`core.md` rules with no mechanical defense. Reading them is supposed
to be sufficient; the agent is supposed to attend to them on every
turn. The recurring observed failure is that **attention degrades from
the agent's own perspective without feeling like degradation**, and the
rule gets violated without anything firing.

Rules currently in this class (non-exhaustive):

| Rule | core.md anchor | Why it's behavior-only |
|---|---|---|
| Think before acting | Thinking Quality §1 | No tool-call shape correlates 1:1 with "did the agent reason about this step" |
| Favor verification over abstraction on hard problems | Thinking Quality §3 | The advisory-gate at Stop catches the post-hoc residue (claims without code reads) but cannot prevent shallow reasoning in flight |
| Don't retry failing commands in a sleep loop | core.md Hygiene rule | One specific orphan shape (poll-loop + background detach) is now PreTool-boundary enforced via the bg-spawn gate; the *rule itself* remains primarily behavior-only because its scope (traps, tmux cleanup, scratch dirs) is broader than the gate's signature |
| Right-size agent prompts | Workflow §"Right-size agent prompts" | No detector for over-broad agent dispatches; the truncation signature is post-hoc and ambiguous |
| Treat the quality reviewer as the finish line — FORBIDDEN | Anti-Patterns | The `excellence_reviewer` dimension gate catches some cases (`excellence_file_count`+) but not all |
| Stopping implementation when components are missing — FORBIDDEN | Anti-Patterns | The exemplifying-scope gate catches the *example marker* sub-case; the broader rule is behavior-only |
| Engage at full cognitive depth on every prompt | Thinking Quality §2 | The most behavior-only rule in the document; cannot be enforced from outside |
| Hygiene: trap before EXIT, source-side cleanup discipline | Hygiene rule sub-bullets | Some shapes catchable (the bg-spawn gate covers the most common); most are not |

This class is **load-bearing for the harness's overall behavior**, but
its enforcement is structural in the same way it is for any
prompt-based agent-safety system: the rule binds only when the model
attends to it.

## Behavioral telemetry asymmetry

The mechanical classes leave traces:

- `gate_events.jsonl` per-session row on every block / bypass.
- Cross-session aggregation surfaces in `/ulw-report` and `/ulw-status`.
- A user who sees "0 blocks fired" knows nothing was caught — they
  cannot tell if that's because the agent behaved or because a class
  failed to catch a real violation.

The behavior-only class has **zero observability**. A violation
produces no event row, no counter, no `/ulw-report` slice. Every
silent violation looks identical to "no violation occurred." This
asymmetry is the deep epistemic problem the taxonomy makes
visible — and the reason "more rules" isn't always "more safety"
without honest accounting for which rules actually bind.

## How to use this taxonomy when proposing changes

When proposing a change to `core.md`:

1. **Name the class** the new rule will land in.
2. If the proposed class is **behavior-only**, ask whether a mechanical
   class fits instead:
   - Is there a state signature? → state-predicate.
   - Is there a single shell entry point? → single-call-flip.
   - Is there a tool-input shape? → PreTool boundary.
   - Is there a classifier vocabulary gap? → classifier-misroute.
   - Is the only signal free-form prose? → prose-pattern (subject to the
     hard cap of 3 active defenses).
3. If the proposal must remain behavior-only, **say so explicitly** in
   the diff message. Don't let the rule pass for binding by default.
4. If the proposal adds consequential mechanical enforcement, extend the
   nearest retained owner once. PreTool gate decisions normally belong in
   `tests/test-quality-gates.sh`; helper-only behavior belongs in
   `tests/test-common-utilities.sh`.

## See also

- `docs/bypass-taxonomy.md` — stop-guard bypass categories (subset of
  mechanical enforcement; specifically classes 1-4 above)
- `~/.claude/quality-pack/memory/core.md` — the rules these classes
  enforce or fail to enforce
- `bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh` —
  current home of PreTool boundary defenses
- `tests/test-quality-gates.sh` — broad retained gate-decision coverage
- `CHANGELOG.md` — v1.43.x entries for the bg-spawn gate and this doc
