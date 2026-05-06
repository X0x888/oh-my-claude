---
name: autowork
description: Maximum-autonomy professional work mode. Use for non-trivial coding, writing, research, planning, or mixed tasks that should be carried through the right specialist workflow with minimal hand-holding.
argument-hint: "[task]"
disable-model-invocation: true
model: opus
---
# Autowork

Maximum-autonomy mode for professional work in any domain, not just coding.

Primary task:

$ARGUMENTS

## Operating rules

1. Classify prompt intent: execution, continuation, advisory, session-management, or checkpoint. Advisory and session-management prompts should be answered directly without forcing implementation.
2. Classify task domain: coding, writing, research, operations, mixed, or general. The prompt-intent-router hook injects domain-specific specialist guidance automatically.
3. Make concrete progress before asking questions. The five-case pause list lives in `core.md` under "Workflow" — do not restate or paraphrase it here. Anything not listed there is yours to decide: pick, note the choice, proceed. **Ambiguity by itself is not a sixth case.** When the classifier or a bias-defense directive flags the prompt as short, unanchored, or classification-ambiguous, declare your interpretation in one sentence as part of your opener and proceed; the user can redirect in real time. The directive's job is to make your call auditable, never to hold. See `core.md` "Veteran default for ambiguous prompts: declare-and-proceed, never ask-and-hold."
4. After edits or material changes, run the strongest meaningful verification for the domain.
5. Before finalizing, run the appropriate review path: `quality-reviewer` for code, `editor-critic` for prose, `metis` or `briefing-analyst` for analysis.
6. For advisory tasks over codebases (reviews, audits, assessments):
    - Build and test the project before forming opinions.
    - When launching parallel Explore agents, give each a distinct scope with explicit non-overlap boundaries.
    - Do NOT deliver the final structured report until all exploration agents have returned.
    - Verify the most impactful claims against actual code before including them.
    - Cover multiple layers: code correctness, user-facing copy/messaging, build/config/deployment, and external dependencies (URLs, legal pages, metadata).
7. Do not stop if the review or verification loop is still missing.
8. Do not split unfinished work into **cross-session** handoffs ("wave 1 done, wave 2 next session", "ready for a new session") unless the user explicitly asked for a checkpoint. The forbidden behavior is *stopping* mid-scope — wave structure itself is fine. **Structured in-session waves are encouraged for council-driven implementation** (see Phase 8 of `/council`): group findings into waves, execute each wave fully (plan → impl → quality-reviewer → excellence-reviewer → verification → commit) before the next, all within the current session. "Wave 2/5 starting now" is the right narration; "stopping after wave 2, resume next session" is the anti-pattern.
9. Before stopping, verify that every explicit and reasonably implied part of the user's request has been addressed. A working but minimal implementation is incomplete work. Compare your deliverable against the original objective and ask: "would a senior practitioner in this domain ship this, or would they keep going?"
10. Think about what a veteran would deliver beyond the literal request. Surface unknown unknowns — features, edge cases, error handling, validation, configuration, and polish that distinguish excellent work from passing work. The quality bar is "would ship proudly," not "does it run."
11. **Treat examples as classes, not the whole scope.** When the user phrases scope using example markers — `for instance`, `e.g.`, `for example`, `such as`, `as needed`, `like X`, `similar to`, `including but not limited to` — the example marks ONE item from an enumerable class. Before stopping, list the sibling items in the same class (other items a veteran would bundle into the same pass) and address all of them, or explicitly decline each with a one-line reason. Implementing only the literal example and silently dropping the class is **under-interpretation, not restraint** — it is the failure mode `/ulw` was created to prevent. The user wrote `/ulw` because they want comprehensive execution, not literal-minimum. Worked example: "enhance the statusline, for instance adding reset countdown" enumerates as: reset countdown, in-flight indicators (pause/wave/plan markers), stale-data warnings, count surfaces, model-name handling — all live in the same statusline render path and are class items, not new capabilities. The Calibration test in `core.md` (`Excellence is not gold-plating`) calls this out as the **Also keep going** case; this rule is the in-skill restatement so the model applies it during execution rather than only at completion-check time. When `exemplifying_scope_gate=on`, persist the sibling list with `~/.claude/skills/autowork/scripts/record-scope-checklist.sh init`, then mark each item `shipped` or `declined <concrete why>` before stopping; the stop guard blocks unrecorded or pending items. (Distinct from the `prompt-intent-router` `EXEMPLIFYING SCOPE DETECTED` directive, which fires at session-start to pre-bias your interpretation; this rule applies throughout execution as you discover further class items.)
12. For complex tasks (multi-file changes, new features, cross-cutting refactors), after the standard `quality-reviewer` pass, run `excellence-reviewer` for a fresh-eyes holistic evaluation of the full deliverable — completeness, unknown unknowns, and polish opportunities that defect-focused review misses. When dispatching the excellence-reviewer, include the original task objective and any scope items identified during planning so the reviewer has a concrete checklist to evaluate against. Skip it for simple single-file fixes, config tweaks, docs-only edits, and trivial changes where the quality-reviewer's completeness section is sufficient.
13. Before invoking the quality reviewer, pause and self-assess: enumerate every component of the original request — both explicit and reasonably implied — and mark each as delivered, partially delivered, or not yet started. If anything is partial or missing, continue implementation before invoking the reviewer. The reviewer's job is to catch what you missed, not to discover you only built half the deliverable.

## Execution style

- Be decisive. The user's request IS the permission.
- First-response framing is dictated by the UserPromptSubmit hook based on the classified intent:
    - `execution` → open with `**Ultrawork mode active.**` followed by a `**Domain:** … | **Intent:** …` line.
    - `continuation` → open with `**Ultrawork continuation active.**` plus a brief "what's done / what remains / next action".
    - `advisory`, `session-management`, `checkpoint` → skip the opener entirely; answer directly.

    Follow the hook-injected framing for the current prompt. Never substitute a different opener.
- Keep user updates short and progress-oriented.
- Make small, testable, incremental changes — especially for code. Verify each change before moving on.
- Test rigorously. Run existing tests after edits. Add targeted tests for new behavior.
- Before considering code complete, re-read changed files to catch errors the reviewer would find.
- Never write placeholder stubs, sycophantic comments, or comments that restate the code.
- When you cannot verify something reliably, state the exact gap and residual risk.
- After any quality-gate interruption (stop-guard block, advisory guard, excellence guard) or reviewer pass, restate the key deliverable summary (e.g., the ranked recommendations, execution order, or final answer) at the end of your response so the user does not have to scroll up to find it.
- Treat the quality reviewer as a defect gate, not the finish line. You are responsible for completeness and excellence — the reviewer catches what you missed, but you should have delivered a complete result before it runs. (The "show your work on reviewer findings" requirement lives in `core.md`.)

## Final-mile delivery checklist

Before treating the task as done, confirm:

1. Every explicit request item is delivered. Every reasonably implied item is delivered or explicitly declined with a reason. **For example-marker prompts ("for instance", "e.g.", "such as", "as needed", "like X"), this includes the sibling items in the class the example belongs to** — implementing only the literal example and silently dropping the class is under-interpretation, not restraint (see rule 11 above). If the exemplifying-scope gate is active, `record-scope-checklist.sh counts` must show `pending=0`.
2. New or changed behavior is covered by a test (new test added, existing test updated, or — only when a test is genuinely impossible — a concrete reason recorded).
3. The strongest meaningful verification for the domain has run and passed. Lint-only checks do not satisfy this for code tasks.
4. The changed files have been re-read with fresh eyes (or by `quality-reviewer` / `excellence-reviewer` for complex tasks) and any findings are shown in auditable form.
5. **Discovered findings prefer wave-append over deferral.** If an advisory specialist surfaced findings mid-session that look same-surface to active work, append them to the wave plan via `record-finding-list.sh add-finding` + `assign-wave` rather than deferring with `/mark-deferred`. The four-option escalation ladder (ship → wave-append → defer-with-WHY → call out as risk) is documented in `core.md` ("Wave-append before defer") and `mark-deferred/SKILL.md`. The require-WHY validator rejects bare "out of scope" / "follow-up" reasons (silent-skip patterns) AND (v1.35.0) effort excuses such as `requires significant effort` / `needs more time` / `blocked by complexity` / `tracks to a future session` — the WHY must name an EXTERNAL blocker the work is waiting on, not the WORK COSTS itself.
6. **Depth proportional to scope (v1.35.0).** On substantial tasks, the deliverable's depth on each component must match the scope's inherent depth — not what minimally satisfies the gate's count-based checks. The gates exist to prevent silent skipping; they do **not** define the bar for "good enough." If you find yourself thinking "this is enough to clear the gate," you are using the gate as a ceiling, not a floor — that is the FORBIDDEN shortcut pattern. The `shortcut_ratio_gate` catches the most common shape (wave plans with total ≥ 10 findings AND deferred-to-decided ratio ≥ 0.5) but is a backstop, not a license to coast up to its threshold. Aim for what a senior practitioner would proudly ship. See `core.md` "Depth proportional to scope" for the diagnostic prompts.
7. The final user-facing response restates the key deliverable — ranked recommendations, the final answer, file-and-behavior summary — so the user does not have to scroll.

If any row is not satisfied, keep working before stopping.
