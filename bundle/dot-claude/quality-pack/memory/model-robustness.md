# Model-Robustness Methodology

The Thinking Quality rules in `core.md` ask the model to think harder; this file is the **navigation map for the structural mechanisms** that buy quality **independent** of model effort. It names existing harness surfaces, what each catches, and when to escalate — so the model doesn't substitute reasoning-shaped tokens for the mechanism that already exists.

## The Premise

Effort is not the bottleneck. The model can produce reasoning-shaped, verification-shaped, and alternative-shaped tokens without actually reasoning, verifying, or considering alternatives. The harness has to be **structurally robust** because the model often cannot tell when it is anchoring, drifting, or pattern-matching.

Three principles follow:

1. **Structure over judgment.** When the model's judgment is itself the failure mode, mechanical structure forces the right move. The no-defer contract was closed by *removing* defer as an option — not by sharpening the validator. When a model-judgment failure recurs across sessions, the right move is to remove the choice, not to add another rule.
2. **Empirical over reasoned.** A claim grounded in observed evidence ("I ran X and got Y") is worth ten times a claim grounded in reasoning ("X should produce Y because…"). The verification scoring gate hard-codes this; the harness pays for evidence, not for reasoning.
3. **Fresh perspective over accumulated.** Long sessions drift. Sub-dispatch (the `Agent` tool) and council/lens passes give the workflow a clean read on the same code the main thread has been staring at. The cost of a new context window beats the cost of an anchored decision.

## The Two Failure-Mode Families (the dual-failure-mode contract)

The harness compensates for **two equally-weighted** failure-mode families. Both must be closed; both have separate mechanisms. Per `core.md` "Why /ulw exists":

1. **Stopping-short failures** — the model halts before completion. Closed by the **no-defer contract** in `core.md` "The v1.40.0 no-defer contract."
2. **Shallow-thinking failures** — the model produces reasoning-shaped output without actually reasoning. Closed by the **depth-on-every-prompt contract** in `core.md` "Thinking Quality" AND the **mechanism map** below.

**FORBIDDEN — do not consolidate the two families into one.** `core.md` "Anti-Patterns" names this verbatim: *"Collapsing the dual-failure-mode framing (depth + no-defer) back to no-defer-only is the same anti-pattern class"* as softening the no-defer contract. A future session that proposes merging this doctrine with `core.md` or framing it as "redundant priming" is the regress this doctrine and `core.md` were both designed to prevent. The duplication is intentional — load-bearing in both directions.

## The Mechanism Map

These are the existing harness surfaces that produce quality **independent of model effort**. Each one buys you something a not-smart-enough model cannot reliably do. Use the right mechanism for the failure shape; do not substitute reasoning-shaped tokens for the mechanism that exists.

### 1. Verification scoring — *mechanical refusal of verification theater*

Lives in `lib/verification.sh`. Project-test-cmd +40, framework keyword +30, output-counts +20, clear-outcome +10. Minimum 40 to clear the verification gate. A `grep` is +0; `bash tests/test-X.sh` with `PASS` in output is +90.

- **Catches:** verification-shaped tokens emitted without actual verification ("the tests pass," "X is wired in," "the fix works") — the gate scores presence of evidence, not reasoning about evidence.
- **Escalate when:** any code change. The gate fires automatically; the model's job is to produce commands and outputs that *clear* it, not to argue around it.

### 2. Sub-dispatch — *fresh context for biased context*

The `Agent` tool. Specialist agents start with no main-thread context — quality-planner, prometheus, metis, oracle, abstraction-critic, the lenses, librarian, the domain specialists. Documented in `skills.md` and listed in `core.md` Workflow.

- **Catches:** main-thread drift, accumulated bias, anchored framing, pattern-match-without-understanding (a fresh specialist sees the specific case, not the template), and the urge to checkpoint into "a fresh session" (sub-dispatch IS fresh context, no session boundary required).
- **Escalate when:** load-bearing call AND you suspect drift, OR the main thread has been on a single surface for many turns, OR the failure mode is pattern-shaped (template applied without seeing the case-specific difference). The agent-first gate enforces this for `/ulw` execution.

### 3. Council and lens passes — *multi-perspective audit*

`/council` dispatches multiple lenses (product, design, security, data, SRE, growth, visual-craft). Documented in `skills.md`.

- **Catches:** single-perspective blind spots that no individual specialist can see.
- **Escalate when:** broad evaluation, "what's missing?" questions, project-strategic moves, or any time the model alone has been making coverage decisions.

### 4. Stop-guard — *mechanical refusal at named failure shapes*

Lives in `stop-guard.sh`. Multiple F-id-numbered bypass surfaces closed across v1.27.0–v1.42.x; the `project_v1_42_x_stop_guard_bypass_closure.md` memory documents the most recent batch. Exact F-id list lives in the script; do not pin a count here (drifts every release).

- **Catches:** specific known stop-without-completion shapes — handoff regex synonyms, ulw-pause judgment-validator, mid-turn intent downgrades, advisory-no-findings, rejected-finding subjectivity, closing-region scan, post-edit refusal.
- **Escalate when:** the gate fires automatically. **Do not try to reason around it** — the gate exists because the model's reasoning was *the* failure mode the bypass exploited.

### 5. No-defer contract — *option removal beats option refinement*

Lives in `core.md` "The v1.40.0 no-defer contract." Under ULW execution with `no_defer_mode=on` (default): `/mark-deferred` refuses, `record-finding-list.sh status <id> deferred` refuses, stop-guard hard-blocks on any deferred status.

- **Catches:** "weak defer with a plausible-sounding WHY" — the failure mode the validator could never reliably catch via regex.
- **Escalate when:** the gate fires automatically. The model's job is to ship, wave-append, or reject-as-not-a-defect — not to find a defer phrasing that passes.

### 6. Findings ledger — *preserve discovered scope*

`record-finding-list.sh`. Per-session `findings.json` tracking every finding from advisory specialists, councils, and reviewers.

- **Catches:** silent drops of discovered work, the exemplifying-scope gap where the user said "for instance X" and the model shipped only X.
- **Escalate when:** any council pass, any advisory specialist that produces findings, any time the prompt uses exemplifying language ("for instance," "e.g.," "such as").

### 7. Wave execution — *chunk big work without segmenting cross-session*

Documented in `skills.md` under `/council` Phase 8. Group findings into 5-10-finding waves by surface area; execute each wave fully (plan → impl → quality-reviewer → excellence-reviewer → verify → commit) before the next.

- **Catches:** "too heavy for this session" rationalization, the cross-session-handoff anti-pattern named in `core.md` Workflow.
- **Escalate when:** ≥10 findings need execution, or the work would otherwise produce "wave N done, wave N+1 next session" prose.

### 8. Excellence + quality reviewer chain — *two-pass review*

Auto-fires per `core.md` Workflow. `quality-reviewer` catches defects; `excellence-reviewer` catches completeness, polish, and unknown-unknowns with fresh eyes.

- **Catches:** premature completion claims, the "I'm done" reflex before the work is actually done.
- **Escalate when:** any non-trivial change. The chain runs automatically; the model's job is to *act on findings*, not to skim past them.

### 9. Auto-memory and compaction sweep — *context preservation*

Documented in `auto-memory.md` and `compact.md`. Wrap-up memory pass after substantial sessions; compaction-boundary sweep when context is about to compress.

- **Catches:** context drift, recall-vs-observation confusion, loss of decision rationale across sessions.
- **Escalate when:** the wrap-up rule auto-fires at session stop, and the compact rule auto-fires before compaction. The model's job is to identify what's *non-derivable* from `git log`/CHANGELOG/source — that's the signal worth keeping.

## The Mechanism-First Principle

When the model's judgment is the failure mode, **mechanism beats more judgment-based instruction**. The right move when a failure mode recurs across sessions is not "add another rule"; it is (in order):

1. **Use the existing mechanism** that catches the shape (the map above).
2. **Sub-dispatch a fresh specialist** if no existing mechanism fires.
3. **Accept the paradigm-level move** — see "When the mechanisms run out" below.

What the right move is *not*: another habit list, another regex predicate, another lifecycle hook, another classifier rule. Per `project_v1_43_audit_paradigm_concerns.md`, those are the deferred paradigm shapes that mechanically-resembled fixes but produced more bypass surface, not less.

## When The Mechanisms Run Out — The Four Genuine Gaps

Four model failure modes do **not** have a fully structural mechanism in the current harness. They are documented here so the model knows where its judgment is the only line of defense — *and* so future paradigm-level work has named targets.

1. **Pattern-match without understanding.** Recognizing a familiar pattern and applying the template without checking what's different about this specific case ("this looks like a feature toggle" — without noticing the toggle helper assumes synchronous reads and your case is async).
2. **Confidence miscalibration.** Expressing conclusions with confidence that does not track evidence strength ("clearly this means X" — when the evidence is one grep result).
3. **Fabrication-from-training.** Asserting APIs, flags, function signatures, or paths from training-data memory without verifying against current source. *This one has a partial mechanism — the `core.md` "Before recommending from memory" rule and the FORBIDDEN bullet on third-party library usage from memory — but no mechanical gate, only the rule. Real verification still depends on the model running `grep` or reading source.*
4. **Mandate-narrowing / completion-criteria substitution.** Under an open-ended mandate (*be exhaustive*, *push to excellence*, *explore more*) the model silently swaps it for a closeable subset — the surfaced findings, a wave checklist — that it can actually finish, completes that subset genuinely, and reports "done": it mistakes the **sample for the ceiling** and **correct for complete**. It cannot self-detect the swap because the subset's completion is *real* and emits no deferral artifact (no "I'm deferring" language, no dropped finding) for a reactive gate to catch. *Partial mechanism (v1.46-pre+): the objective-contract gate now releases only on a RECORDED fresh-context completeness audit (excellence-reviewer, sharpened to ask "what is the largest worthwhile thing NOT done, and is each omission cost/risk-forbidden or evidence-allowed?") — Mechanism 2 applied to the completion judgment, moving release off the model's self-attestation. This LOWERS the miss-rate (a fresh agent has no sunk-cost identity in the shipped subset) but does NOT close the gap: "is the open mandate exhausted?" is NLU-hard, and a fresh auditor manufactures a (better-calibrated) finish line too — the recursion is bounded once, not broken. Do not let the mechanism's existence relax this naming: treating the audit as PROOF of exhaustion is the false-comfort failure.*

The paradigm-correct answer for all four is **input enrichment** per `project_v1_43_audit_paradigm_concerns.md` Finding 5 — completion-criteria contracts, verification-by-running-not-reasoning, fresh-context sub-dispatch as the primary compensation — not another habit list or directive layer. None of these paradigm shapes have shipped; they are documented as deferred.

In the interim, the closest existing compensation is **sub-dispatch with a fresh specialist** (Mechanism 2 above). A fresh-context agent naturally surfaces what the main thread's pattern-matching missed, calibrates its own confidence to what it can observe, and grounds claims in source it just read. When the main thread is in any of these three modes, the right next move is not "try harder" — it is the `Agent` tool.

## What This Doctrine Is NOT

- **Not a new instruction layer, not adversarial framing, not a softening of the no-defer contract.** This is a navigation map for *existing* mechanisms; adding habits/rules/directives would be the regress `project_v1_43_audit_paradigm_concerns.md` named. The dual-failure-mode contract — no-defer (closes stopping-short) + depth-on-every-prompt (closes shallow-thinking) — remains load-bearing; this file is its structural complement.
- **Not optional or consolidate-able.** Future sessions will be tempted to merge this with `core.md`. **Resist.** `core.md` "Anti-Patterns" names the consolidation pattern as forbidden. A reviewer who flags this file as "redundant priming" is exhibiting the failure mode the duplication exists to prevent.
- **Not a substitute for paradigm-level work.** The three genuine gaps need paradigm moves, not more rules.

## Coupling to Other Doctrine

- **`core.md`** holds the **rules** — what the model must and must not do.
- **`skills.md`** holds the **mechanism invocation details** — full skill names, arguments, and decision triggers.
- **`compact.md`** + **`auto-memory.md`** hold the **context-preservation rules** for Mechanism 9.
- **`project_v1_43_audit_paradigm_concerns.md`** holds the **paradigm-level future work** the genuine gaps defer to. When a future session proposes a structural fix for pattern-match, miscalibration, or fabrication, read that memory first — the user has already costed the obvious moves and named which paradigm shape is the next-correct one.

When in doubt about which mechanism applies, read the map above. When the map runs out, sub-dispatch fresh. When that runs out, accept that the gap is paradigm-shaped and defer the work explicitly rather than papering it over.
