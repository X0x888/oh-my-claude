# Compact-Boundary Intent Preservation

**Status:** Shipped in `1.7.1`.

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

**Flag normalization.** A post-review pass found that the `git <verb>` regex required the verb adjacent to `git`, so configured-override forms like `git -c commit.gpgsign=false commit`, `git --no-pager commit`, and `git --git-dir=/path commit` slipped through. The guard now runs each command through `_normalize_git_flags` — a single-sed strip of top-level flags between `git`/`gh` and the verb — before matching. The separate-arg branch names the complete set of flags git(1) documents as accepting a space-separated argument (`-c`, `-C`, `--git-dir`, `--work-tree`, `--exec-path`, `--namespace`, `--super-prefix`, `--config-env`, `--attr-source`); without the explicit list, the fallback single-token branch would consume the flag but leave its following value token in place, sitting between `git` and the verb and defeating the match (e.g. `git --git-dir /tmp/repo commit` would normalize to `git /tmp/repo commit`). The single-token branch handles the `=value` forms of the same flags along with all bare flags (`--no-pager`, `-X`, etc.). Regression coverage lives in gap 8p.

**Allow-list.** Another post-review pass found that the original regex also blocked *recovery* and *read-only* invocations that share a verb with a destructive op: `git rebase --abort|--continue|--skip|--quit`, `git merge --abort`, `git push --dry-run|-n`, `git commit --dry-run`, `git tag -l|--list`. These are exactly the commands a model under advisory intent needs when a prior interactive operation left the working tree in a half-applied state. The guard now checks an allow-list (`_cmd_is_allowed_variant`) before the destructive match and lets these through. Regression coverage lives in gap 8q.

**Compound-command correctness.** Commands are split on `&&`, `||`, `;`, and `|`; each segment is evaluated independently. This keeps `git rebase --abort && git push --force` denying on the push (rather than short-circuiting on the allow-listed rebase), and lets `git rebase --abort && git status` pass as the safe compound it is. Regression coverage lives in gap 8r.

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

`tests/test-e2e-hook-sequence.sh` gaps 8a–8r cover:

- Directive emission for each non-execution intent, with `last_meta_request` inlined.
- Directive suppression: execution intent still gets the momentum directive, no guard text.
- Guard denies all 27 tested destructive forms (including `/usr/bin/git` absolute-path and parenthesized forms).
- Guard allows 25 read-only forms (including `merge-base`, `commit-tree`, `grep 'git commit'`).
- Counter increments only on denial, wrapped in `with_state_lock`.
- `.ulw_active` sentinel absence → hook fast-exits.
- Non-Bash tool → hook passes through.
- Kill-switch respected: `OMC_PRETOOL_INTENT_GUARD=false` → guard exits 0.
- Post-compact release path: after the guard blocks, a fresh execution-framed `UserPromptSubmit` reclassifies intent and unblocks subsequent commits.
- Flag-injection bypass closure (gap 8p): `git -c user.email=x commit`, `git --no-pager commit`, `git --git-dir=/path commit`, `git -C /tmp commit`, stacked `-c` forms, absolute-path plus flag, and `sudo git -c …` all block.
- Allow-list correctness (gap 8q): recovery forms (`--abort|--continue|--skip|--quit` on rebase/merge/cherry-pick/revert/am), dry-run forms (`push --dry-run`, `push -n`, `commit --dry-run`), and list forms (`tag -l`, `tag --list`) pass through without incrementing the counter.
- Compound correctness (gap 8r): allow-variant chained with a destructive op still denies on the destructive segment (`git rebase --abort && git push --force`, `git tag --list && git -c ... commit`, `echo foo | git commit -F -`), and a compound of two safe segments stays allowed.

## 8. Known coverage gaps

The PreTool guard is a command-line pattern matcher, not a shell parser. Three boundary forms are **not covered** and are documented here rather than silently blessed:

- **Embedded newlines in a single command.** Compound-command splitting in `_normalize_git_flags` operates on `&&`, `||`, `;`, and `|` — not on literal `\n` inside an argument. A single invocation like `bash -c $'git status\ngit push'` passes through as one segment; only the first verb (`git status`) is seen, and the second verb hides inside the quoted-string argument. Adding `\n` to the split set would misread heredoc bodies and multi-line shell fragments that are not intended as command sequences, so the guard errs toward the semantics real shells use and accepts the edge case.
- **Process substitution.** `sh <(echo 'git commit')` and `eval "$(cat some-script.sh)"` run a child shell against input we do not see. The destructive verb lives inside the nested command substitution, not in the visible argv.
- **Language-runtime wrappers.** Any invocation that runs git through another language (Python's `subprocess`, Node child-process APIs, Ruby `system`, direct writes to `.git/refs/`) executes git behavior without ever naming the `git` binary on the command line. No argv-level guard can catch these.

None of these are credible real-world bypasses — models that Claude Code actually dispatches do not compose heredoc-wrapped git invocations spontaneously, and a deliberate bypass is already outside the directive layer's threat model. The gaps exist because narrowing them would cost more than it saves:

- Splitting on newlines would over-match legitimate multi-line heredocs, breaking the release checklist's `git commit -m "$(cat <<'EOF' … EOF)"` pattern.
- Parsing through `$(...)` and `<(...)` requires a real shell parser; the guard would cease to be a single-sed hook and would instead need a bash/zsh AST walker.

If you are hardening the guard for a compliance-driven threat model, the correct next layer is not to widen the regex — it is to (a) tighten the intent classifier so advisory prompts with edit-adjacent language do not fall into `advisory` incorrectly, and (b) add a post-action audit (e.g. a git `post-commit` hook) that alerts on unexpected commits during advisory-classified sessions. Both are out of scope for this post-mortem.

## 9. References

- `bundle/dot-claude/quality-pack/scripts/session-start-compact-handoff.sh` — Layer 1
- `bundle/dot-claude/skills/autowork/scripts/pretool-intent-guard.sh` — Layer 2
- `bundle/dot-claude/skills/autowork/scripts/common.sh` — `OMC_PRETOOL_INTENT_GUARD` and `OMC_WAVE_OVERRIDE_TTL_SECONDS` conf loaders
- `tests/test-e2e-hook-sequence.sh` — regression coverage (gaps 8a–8r)
- `tests/test-pretool-intent-guard.sh` — focused regression suite for the gate, including wave-active override coverage (v1.21.0)
- `feedback_advisory_means_no_edits` memory — originating user preference the fix encodes

---

## 10. Wave-execution exception (v1.21.0)

### 10.1 Follow-on incident

After Layer 2 shipped, a different failure mode surfaced: the **same gate** that prevented unauthorized commits in the original incident now produced a disturbing UX during legitimate council Phase 8 wave execution. A user reported their session emitting:

> "To reach the Wave 1 + Wave 2 line and proceed to Wave 3 (spatial layout mode using the embedding centroids Wave 1 already produces): a single 'yes' reauthorizes commit."

A system-injected `UserPromptSubmit` frame (scheduled `/loop` tick, post-compact resume, or SessionStart handoff) had flipped `task_intent` to `advisory` mid-Phase-8. The gate then denied the user's already-authorized per-wave commit, and the prior block-reason text — *"ask the user to confirm execution intent before retrying"* — coached the model directly into the `core.md` FORBIDDEN anti-pattern: *"Asking 'Should I proceed?' or 'Would you like me to…' when the user has already requested the work."*

### 10.2 Fix

Three coordinated changes in `pretool-intent-guard.sh`:

**(a) Wave-active override (`_wave_execution_active` + `_wave_override_command_safe`).** When `findings.json` records a council Phase 8 plan with at least one wave still `pending` or `in_progress`, AND its `updated_ts` is within `OMC_WAVE_OVERRIDE_TTL_SECONDS` (default `1800` = 30 min), the gate short-circuits and allows the operation. The override is intentionally narrow:

- **Scope:** `git commit` only — the canonical per-wave operation in the Phase 8 protocol. Push, force-push, tag, rebase, reset --hard, branch -D, gh pr create, etc. still require fresh execution intent.
- **Compound safety:** `_wave_override_command_safe` re-walks every shell segment (the destructive matcher stops at the first hit) and only fires if EVERY destructive segment is a `git commit`. So `git commit -m wave && git push --force` still denies on the force-push.
- **Freshness gate:** stale `findings.json` from an abandoned plan does NOT trigger the override. Without the TTL, a session that started a wave plan, walked away, then resumed unrelated work would carry the per-wave authorization indefinitely.

**(b) Reason-text rewrite.** The verbose first-block message no longer contains the *"ask the user to confirm execution intent"* phrasing that induced the anti-pattern. New text explicitly enumerates the FORBIDDEN patterns (one-word affirmation gates, "Should I proceed?" framings, manufactured permission prompts) and tells the model to propose a concrete imperative the user can paste back verbatim (e.g., *"To unblock, reply with: implement wave 3"*). The terse second-block message is similarly hardened.

**(c) Telemetry.** A new `wave_override` event type is recorded to `gate_events.jsonl` whenever the override fires, with `intent` and `denied_segment` for forensic auditing. `show-report.sh` surfaces this as an "Overrides" column in the per-gate table and a `wave-override allow(s)` suffix in the totals line.

### 10.3 Configurability

- `OMC_WAVE_OVERRIDE_TTL_SECONDS` (env) or `wave_override_ttl_seconds` (conf, in `oh-my-claude.conf`). Default `1800` seconds. Lower to tighten; raise if your wave cycles legitimately exceed 30 minutes between commits.
- `OMC_PRETOOL_INTENT_GUARD=false` still disables the entire gate (and therefore the override too).

### 10.4 What was rejected

- **Broadening the override to `git push`.** Phase 8 commits per wave but does not auto-push between waves; pushing is a separate user decision. Allowing push under the override would re-open the original threat surface (unauthorized publication during advisory).
- **Detecting "system-injected vs user-typed" UserPromptSubmit frames at the classifier level.** Considered, deferred. The classifier would need a reliable signal (markers in the injected text, frame metadata) and the wave-active heuristic gives us most of the benefit at zero classifier complexity. Revisit if the override misses cases that a frame-shape detector would catch.
- **Allowing the override regardless of `findings.json` age.** Would protect more legitimate Phase 8 commits but at the cost of stale plans leaking authorization. The 30-minute window aligns with typical per-wave cycle time (plan + impl + review + verify + commit ≈ 10-25 minutes) while disqualifying abandoned plans.

### 10.5 Regression tests

`tests/test-pretool-intent-guard.sh` (19 cases / 42 assertions) locks in:

- The deny paths for advisory and session_management intents.
- The wave-active override (positive: T5, T15) and its non-application (T6 completed plan, T7 empty waves, T13 non-commit destructive ops, T14 compound `commit && force-push`, T16 stale plan, T18 commit-substring false-match).
- Configurable TTL via env (T17) AND via `oh-my-claude.conf` (T17b — the conf-parser regression that the v1.21.0 review caught: docs advertised the conf key but the parser entry was missing on the initial implementation).
- Kill-switch bypass (T11), non-Bash tool short-circuit (T8), and the verbose-vs-terse first/second block coaching (T9, T10, T12).
- Text contract: deny reason MUST NOT contain `say yes`, `single yes`, `reauthorize`, `confirm with yes`; MUST include `concrete imperative`, `reply with:`, `FORBIDDEN`.

`tests/test-show-report.sh` Test 18 verifies the new "Overrides" column and `wave-override allow(s)` totals suffix. The e2e Gap 8s assertions in `test-e2e-hook-sequence.sh` were updated to match the rewritten verbose reason text (`What to do:` / `What NOT to do` / `concrete imperative` markers).
