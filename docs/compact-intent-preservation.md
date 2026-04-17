# Compact-Boundary Intent Preservation

**Status:** Shipped in `[Unreleased]` (target release `1.7.1`).

**Owner:** Incident-driven post-mortem — written after the 2026-04-17 advisory-compact regression.

---

## 1. Incident

A user was running an active ULW session in the `oh-my-claude` working directory and asked, advisory-style:

> "what do you think [about the landing page]?"

The classifier in `prompt-intent-router.sh` correctly labelled the prompt `task_intent=advisory` and injected the advisory directive ("do not force implementation unless the user explicitly asks for it"). Mid-response, an auto-triggered compaction fired. On resume, the model pushed **four unauthorized commits** to a sibling repository (`oh-my-claude-landing-page`) where other AI agents were actively working.

The commits were technically sound — one was a real version-drift fix — but the user had asked for an opinion, not edits. This is exactly the failure mode that the `feedback_advisory_means_no_edits` memory warns about.

## 2. Root cause

**Workflow flaw, not model limitation.** The compact continuity hooks preserve `task_intent` in on-disk state (`pre-compact-snapshot.sh` writes it), but the downstream `session-start-compact-handoff.sh` ignored it. The handoff read `workflow_mode` and `task_domain`, and when `workflow_mode == ultrawork` unconditionally injected:

> "Ultrawork mode is still active post-compact. Do not drift back to asking-for-permission behavior. Preserve the active objective and keep momentum high."

When the pre-compact prompt was advisory, this directive directly contradicted the intent classification. An auto-compact continuation does not fire a fresh `UserPromptSubmit`, so `prompt-intent-router.sh` — the only hook that re-asserts the advisory directive — never ran. The model saw only "keep momentum high" and read it as execution authorization.

Oracle confirmed the sharper framing: **intent state is UserPromptSubmit-scoped, but needs to be compact-boundary-scoped.** The advisory directive in the router is ephemeral (consumed by one turn). The classification persists on disk, but nothing re-reads it across a compact.

No enforcement layer existed at the PreToolUse level to catch destructive git operations when intent was non-execution, so the directive drop was immediately load-bearing.

## 3. Fix (two layers)

### Layer 1 — Intent-aware compact handoff directive

`session-start-compact-handoff.sh` now reads `task_intent` and `last_meta_request` from state. A `case` on intent:

- `advisory | session_management | checkpoint` → **replace** (not append to) the ULW momentum directive with a guard directive that forbids destructive operations, inlines the original meta-request (500-char cap), and tells the model to wait for explicit execution-framed authorization.
- `execution | continuation` → current behavior (ULW momentum directive).

The replacement semantics matter: appending would let both directives fight, and the momentum phrasing would win by proximity.

### Layer 2 — PreToolUse Bash intent guard

New hook: `pretool-intent-guard.sh`, wired on `PreToolUse` matcher `Bash`. When ULW is active and `task_intent` is non-execution, it denies destructive git/gh commands via `hookSpecificOutput.permissionDecision: "deny"`.

Coverage:

- **Porcelain:** `commit`, `push`, `revert`, `reset --hard`, `rebase`, `cherry-pick`, `tag`, `merge`, `am`, `apply`
- **Branch/ref rewriting:** `branch -D|-M|-C|--delete|--force`, `switch -C|--force`, `checkout -B|--force`, `clean -f|--force`
- **Plumbing (the "work-around" escape hatches):** `update-ref`, `symbolic-ref`, `fast-import`, `filter-branch`, `replace`
- **GitHub mutations:** `gh pr|release|issue create|merge|edit|close|delete|reopen|comment`

The anchor accepts optional path prefixes so `/usr/bin/git commit` and `sudo git push` are caught. Case-sensitive matching is intentional — `-D` (force-delete) must not collapse to `-d` (safe-delete) under a lowercase transform.

Read-only ops (`status`, `log`, `diff`, `show`, `branch` list form, `merge-base`, `commit-tree`, `diff-tree`, `fetch`, `stash push|pop|apply`) pass through. Execution intent passes through for all ops. The counter (`pretool_intent_blocks`) is wrapped in `with_state_lock` to survive parallel tool_use blocks in one assistant turn.

### Configurability

`OMC_PRETOOL_INTENT_GUARD=false` (env) or `pretool_intent_guard=false` (conf) disables enforcement and falls back to directive-only. Default is `true`.

## 4. Why two layers

Oracle's framing: the model already ignored one directive in this incident. Directives are advisory to the model; a hook is binding. The directive layer catches well-behaved model behavior (most cases) cheaply; the guard is the backstop for when the model drifts. Without both, the fix depends entirely on the model heeding a directive it can prompt-inject itself past.

## 5. What was rejected

- **CWD drift detection** (block writes to repos outside the session's original `cwd`). Discussed but deferred: risks over-blocking in monorepos and worktrees; the intent-based block is the primary safety and cwd-scoping can be a follow-up if false negatives emerge.
- **Blocking `Edit`/`Write` under advisory intent.** Considered and rejected as too broad — models legitimately write scratch files (notes, intermediate drafts) during advisory work. The original incident was about commits/pushes, not edits.
- **Overriding intent on short post-compact prompts.** The `post_compact_bias` in `prompt-intent-router.sh` already preserves the objective text for short follow-ups. Extending it to preserve `task_intent` conflicts with the case where the user *does* send a fresh execution prompt, so we left that alone and let the new classification overwrite `task_intent` as normal.

## 6. Monitoring

`/ulw-status` now surfaces `PreTool intent blocks: <n>`. A non-zero value after a session indicates the guard fired — useful telemetry for tuning the classifier if false positives emerge.

`pretool_intent_blocks` is cleared by `ulw-deactivate.sh` so `/ulw-off` does not leak counter data into a subsequent session.

## 7. Regression tests

`tests/test-e2e-hook-sequence.sh` gaps 8a–8l cover:

- Directive emission for each non-execution intent, with `last_meta_request` inlined.
- Directive suppression: execution intent still gets the momentum directive, no guard text.
- Guard denies all 27 tested destructive forms (including `/usr/bin/git` absolute-path and parenthesized forms).
- Guard allows 25 read-only forms (including `merge-base`, `commit-tree`, `grep 'git commit'`).
- Counter increments only on denial, wrapped in `with_state_lock`.
- `.ulw_active` sentinel absence → hook fast-exits.
- Non-Bash tool → hook passes through.
- Kill-switch respected: `OMC_PRETOOL_INTENT_GUARD=false` → guard exits 0.
- Post-compact release path: after the guard blocks, a fresh execution-framed `UserPromptSubmit` reclassifies intent and unblocks subsequent commits.

## 8. References

- `bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh` — Layer 1
- `bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh` — Layer 2
- `bundle/dot-claude/skills/autowork/scripts/common.sh` — `OMC_PRETOOL_INTENT_GUARD` conf loader
- `tests/test-e2e-hook-sequence.sh` — regression coverage (gaps 8a–8l)
- `feedback_advisory_means_no_edits` memory — originating user preference the fix encodes
