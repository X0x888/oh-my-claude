# AGENTS.md

This file has two audiences. Read the section that applies to you and skip the rest.

- **AI agent installing or updating oh-my-claude for a user.** Follow the [Agent Install Protocol](#agent-install-protocol--installing-or-updating-oh-my-claude) below. The protocol is the canonical source of truth for the install flow; the README's "AI-assisted install" prompts point here.
- **AI agent contributing to the oh-my-claude codebase** (adding agents/skills/hooks, fixing bugs, doing reviews). Skip to [Project Context](#project-context) for architecture, conventions, state-management rules, and protected design decisions.

---

## Agent Install Protocol — installing or updating oh-my-claude

When the user asks you to install, update, set up, or "add" oh-my-claude, follow these steps in order. Skipping a step usually produces a half-installed harness — hooks not loaded (Step 3), wrong clone path that breaks future updates (Step 1.1), or a missed `/ulw-demo` handoff (Step 4) that leaves the user with no felt-it moment.

### Step 0 — Preflight: detect existing installs

Read `~/.claude/oh-my-claude.conf` (a `key=value` file written by `install.sh`). Relevant keys:

- `installed_version=X.Y.Z` — present if the harness is currently installed.
- `repo_path=/abs/path` — the source repo path the last install was run from.
- `installed_sha=<git-sha>` — the source commit at last install (absent if installed from a non-git source).
- `model_tier=quality|balanced|economy` — user's chosen tier (absent = default `balanced`).

Branch on the conf state. (`installed_sha=` may be absent when the harness was installed from a tarball or `git archive` — in that case, fall back to comparing `installed_version=` against the latest tag and skip the SHA check.)

| Conf state | User asked for | Action |
|---|---|---|
| Conf missing, or conf present but `installed_version=` absent | install / "set up" | Go to **Step 1 — Fresh install**. |
| `installed_version=` present | install / "set up" | Confirm intent: "you already have v$X — reinstall in place, or did you mean update?" If reinstall: skip the clone in Step 1.1 and run `bash "$repo_path/install.sh"` directly. If update: go to **Step 2**. |
| `installed_version=` present | update / "upgrade" / "pull latest" | Go to **Step 2 — Update**. |
| Install-state helper reports `currentness=already-current` (after the repo clone exists locally) | install or update | **Tell the user the harness is already current.** Print version and last-install timestamp. Recommend `/ulw-demo` if they haven't seen the gates fire. |

Once `repo_path` is known and the repo exists locally, prefer the helper below over ad-hoc `grep` / `stat` / `git` snippets:

```bash
bash "$repo_path/tools/install-state-report.sh" --json
```

It refreshes `origin`, detects the remote default branch, reads `~/.claude/.install-stamp`, and returns `install_status`, `currentness`, `latest_tag`, `origin_default_ref`, and `last_install_at` in one place. The already-current branch only resolves after the repo clone exists locally — Step 0 is read-only on the conf, so that helper path starts once the agent has cd'd into `$repo_path` (start of Step 2).

For the human-facing already-current response, prefer the helper's canonical text mode:

```bash
bash "$repo_path/tools/install-state-report.sh" --already-current-summary
```

That emits the exact `Already current: vX.Y.Z (last install: ...)` line used by `install-remote.sh`, so install assistants do not hand-format version/timestamp text.

Failure policy for AI installers — do not improvise around these branches:

- If `installed_version=` is present and the user asked to install, ask whether they mean reinstall or update. Do not assume.
- If `~/.local/share/oh-my-claude` already exists but is not this repo, stop and ask what to do next. Do not overwrite the path or run a foreign `install.sh`.
- If `install.sh` or `verify.sh` exits non-zero, stop. Surface the failing command and output, recommend the next rerun command from the same repo path, and do not give restart or `What next?` guidance until `verify.sh` passes with `Errors: 0`.
- If the user explicitly wants the curl-pipe-bash bootstrapper instead of a manual clone, prefer `OMC_REF=<tag>` plus `OMC_EXPECTED_SHA=<trusted release commit sha/prefix>` over rolling `main`. Source that SHA from the GitHub release's `Verified bootstrap install` / `Trusted release commit` block when available. The bootstrapper accepts any 7-40 char SHA prefix and refuses to run `install.sh` on a mismatch.

### Step 1 — Fresh install

1. **Clone to the canonical location.** Use `~/.local/share/oh-my-claude` — this matches the curl-pipe-bash bootstrapper (`install-remote.sh`), so future updates work the same way no matter how the user originally installed:
   ```bash
   git clone https://github.com/X0x888/oh-my-claude.git ~/.local/share/oh-my-claude
   ```
   If `~/.local/share/oh-my-claude` already exists, detect what's there before overwriting:
   ```bash
   git -C ~/.local/share/oh-my-claude config --get remote.origin.url 2>/dev/null
   ```
   If the URL resolves to `X0x888/oh-my-claude`, treat it as an existing clone — skip clone and continue to step 3 (or run `git pull` first). Accept equivalent GitHub spellings (`git@github.com:X0x888/oh-my-claude.git`, `https://github.com/X0x888/oh-my-claude`, trailing slash, case differences). If it returns a different repo or empty, stop and ask the user — do not overwrite a sibling repo.

2. **One question, only if useful.** Default to model tier `balanced` unless the user has already expressed a preference. Don't ask if they shrug or are unfamiliar — just use the default. Suggested phrasing if you do ask:

   > Default model tier is `balanced` (Opus for planning/review, Sonnet for execution). Want all-Opus (`quality`) or all-Sonnet (`economy`) instead?

   **Do NOT ask about `--bypass-permissions`.** The installer prints a notice about it; the user can opt in later via `bash install.sh --bypass-permissions` once they trust the harness. Asking up-front adds friction without value.

3. **Run the installer.**
   ```bash
   bash ~/.local/share/oh-my-claude/install.sh
   ```
   Add `--model-tier=quality` or `--model-tier=economy` only if the user picked a non-default tier.

4. **Run verify.**
   ```bash
   bash ~/.local/share/oh-my-claude/verify.sh
   ```
   Confirm `Errors: 0`. If errors > 0, surface them and recommend re-running `install.sh`.

5. Continue to **Step 3 — Restart instruction** (mandatory).

### Step 2 — Update an existing install

1. Read `repo_path=` from `~/.claude/oh-my-claude.conf`.
2. Pull and re-install:
   ```bash
   git -C "$repo_path" pull
   bash "$repo_path/install.sh"
   ```
   `install.sh` reads `model_tier=` from conf and re-applies it automatically — no flag needed.
3. Verify:
   ```bash
   bash "$repo_path/verify.sh"
   ```
   If `verify.sh` exits non-zero, stop. Surface the verifier output and recommend re-running `bash "$repo_path/install.sh"` before you offer any restart or `What next?` guidance.
4. Read the last-install outcome:
   ```bash
   bash "$repo_path/tools/install-state-report.sh" --json
   ```
   Use `.last_install.restart_required` as the restart decision. `.last_install.kind`, `.last_install.managed_changes_total`, and `.last_install.settings_changed` explain *why*. For the changelog summary, use `.last_install.previous`, `.last_install.current`, and `.last_install.change_summary` — that artifact is written by `install.sh`, so you do not need a separate `git log` step.
   For the human-facing update summary, prefer the helper's text mode:
   ```bash
   bash "$repo_path/tools/install-state-report.sh" --last-update-summary
   ```
   That emits the same standardized update summary `install.sh` and `install-remote.sh` print.
5. Continue to **Step 3 — Restart instruction** only when `.last_install.restart_required == true`. (`install.sh` still prints an `Orphans:` block in its post-install summary if files were removed.)

### Step 3 — Tell the user to restart Claude Code

This is the single highest-leverage instruction in the protocol. Claude Code loads hooks at session start; an already-running session keeps its previous wiring until restart. Skip this step and the user types `/ulw <task>` in their current session, sees no behavioral change, and concludes the install is broken.

After install — and after any update where `.last_install.restart_required == true` — **explicitly tell the user** this exact line. Prefer emitting the helper below and quoting it verbatim:

```bash
bash "$repo_path/tools/install-state-report.sh" --restart-guidance
```

Expected output:

> Restart Claude Code (or open a new session) before testing. Already-running sessions keep the previous hook wiring, so `/ulw` will silently no-op until you restart.

If the user is in the same Claude Code session that ran the install, they must start a new session before any harness behavior becomes observable. If `.last_install.restart_required == false`, the same helper emits the canonical no-restart sentence for no-op reinstalls and doc-only updates.

### Step 4 — Hand off with the verify "What next?" footer

`verify.sh` prints a "What next?" footer with the recommended first prompts. **Quote it verbatim** in your response — do not paraphrase, do not summarize. The `/ulw-demo` line in that footer is what converts "tool installed" into "tool felt and understood"; paraphrasing tends to drop it.

The footer looks like:

```
What next?
  /omc-config                             -- inspect/change settings (auto-detects mode)
  /ulw-demo                               -- see quality gates in action (recommended first step)
  /ulw fix the failing test and add regression coverage
                                          -- start real work with full quality enforcement
```

### Step 5 — Brief the user (only if they pasted the install prompt without prior context)

If the user pasted "install oh-my-claude" with no surrounding conversation, they may not know what they just installed. Add a two-sentence summary:

> oh-my-claude is a cognitive quality harness for Claude Code. After you restart, `/ulw <task>` runs any non-trivial work through specialist agents and quality gates that block until testing and review are done — it works for coding, native spreadsheet/document/deck workflows, quantitative analysis, writing, research, and operations. Run `/ulw-demo` first to feel how the gates fire on a quick walkthrough (under 2 minutes).

The next section is for repo contributors only.

---

## Project Context

> If you're helping a user install or update, the [Agent Install Protocol](#agent-install-protocol--installing-or-updating-oh-my-claude) above is what you want, not this section.

oh-my-claude is a cognitive quality harness for Claude Code. It provides bash hooks, skills, and specialist agents that enforce thinking, testing, and review across coding, native spreadsheet/document/deck workflows, quantitative analysis, writing, research, and operations work. The system is pure bash with zero npm dependencies.

## Architecture

```
oh-my-claude/
  install.sh                  # Merge-safe installer (--bypass-permissions, --no-ios, --model-tier)
  uninstall.sh                # Clean removal
  verify.sh                   # Post-install integrity checker

  bundle/dot-claude/          # Installs to ~/.claude/
    agents/                   # 34 specialist agent definitions (.md)
    output-styles/            # Two bundled output styles: oh-my-claude.md (compact CLI default) + executive-brief.md (CEO-style status report)
    quality-pack/
      memory/                 # Core, skills, and compact memory files
      scripts/                # 16 lifecycle scripts (prompt routing, first-prompt session-init, compaction, session start [9 hooks incl. drift-check + whats-new + watchdog-health + resume-hint + self-audit-nudge + auto-tune], stop-failure, resume-watchdog, self-audit recorder)
    skills/                   # 31 skill definitions, each in <name>/SKILL.md
      autowork/scripts/       # 42 autowork hook scripts and utilities
        common.sh             # Shared functions (JSON, classification, scope)
        lib/state-io.sh       # Extracted state I/O subsystem; sourced by common.sh
        lib/classifier.sh     # Extracted prompt classifier (P0 + P1 + telemetry); sourced by common.sh
        lib/verification.sh   # Extracted verification subsystem (Bash + MCP scoring); sourced by common.sh
        lib/timing.sh         # Per-tool/subagent timing capture + aggregation (lazy-loaded); sourced by common.sh
        lib/canary.sh         # Model-drift canary (verification-claim vs tool-call mismatch); sourced by common.sh
    statusline.py             # Custom statusline with context tracking
    CLAUDE.md                 # Installed user-facing CLAUDE.md

  config/
    settings.patch.json       # Settings merged into user's settings.json

  evals/realwork/             # Outcome eval scenarios + scorer for minimal-prompt real-work shipping
  tests/                      # 145 bash + 1 python test scripts; CLAUDE.md "Testing" lists each one

  tools/                      # Developer tools (not installed; keep exhaustive)
    audit-published-release-assets.sh
    audit-published-release-attestations.sh
    audit-published-release-bodies.sh
    audit-published-release-states.sh
    audit-published-release-titles.sh
    audit-published-releases.sh
    backfill-project-key.sh
    bootstrap-gate-events-rollup.sh
    build-release-assets.sh
    check-consumer-contracts.sh
    check-flag-coordination.sh
    classifier-fixtures/known_misclassified.jsonl
    classifier-fixtures/regression.jsonl
    cluster-unknown-defects.sh
    hotfix-sweep.sh
    install-state-report.sh
    install-upgrade-sim.sh
    list-ci-pinned-tests.sh
    list-release-automation-surfaces.sh
    stage-release-automation-surfaces.sh
    prepare-release-automation-deployment.sh # coherent pre-push deployment candidate prep
    promote-classifier-fixtures.sh           # one-command /ulw-correct candidate → regression-corpus promotion (v1.47)
    local-ci.sh
    release.sh
    render-release-notes.sh
    render-release-title.sh
    replay-classifier-telemetry.sh
    verify-distribution-readiness.sh         # top-level release/distribution readiness (`--json` available)
    verify-install-readiness.sh              # top-level install/onboarding readiness (`--json` available)
    verify-professional-readiness.sh         # top-level cross-domain product-readiness audit (`--json` available)
    verify-project-readiness.sh              # top-level maintainer release-candidate audit (`--json` available)
    verify-published-release-assets.sh
    verify-published-release-attestations.sh
    verify-published-release-body.sh
    verify-published-release-state.sh
    verify-published-release-title.sh
    verify-published-release.sh              # full published-release audit (`--json` available)
    verify-release-automation-deployment.sh  # remote deployment audit (`--json` available)
    wait-for-release-attestations.sh

  docs/                       # Extended documentation
    architecture.md
    customization.md
    faq.md
    prompts.md
```

### Key Components

- **Hook scripts** (`quality-pack/scripts/`, `autowork/scripts/`): Bash scripts triggered by Claude Code lifecycle events (prompt entry, pre-tool-use, tool completion, compaction, session start). They route intents, manage state, and enforce quality gates.
- **common.sh** (`autowork/scripts/common.sh`): Shared utility library. Sources `lib/state-io.sh` for the state I/O subsystem (`read_state`, `write_state`, `write_state_batch`, `with_state_lock`, `with_state_lock_batch`, `ensure_session_dir`, `session_file`, `append_state`, `append_limited_state`), `lib/verification.sh` for verification scoring and MCP-tool classification (`verification_matches_project_test_command`, `verification_has_framework_keyword`, `detect_verification_method`, `score_verification_confidence`, `classify_mcp_verification_tool`, `score_mcp_verification_confidence`, `detect_mcp_verification_outcome`), `lib/classifier.sh` for prompt classification (`is_imperative_request`, `count_keyword_matches`, `is_ui_request`, `infer_domain`, `classify_task_intent`, `record_classifier_telemetry`, `detect_classifier_misfire`, `is_execution_intent_value`), `lib/timing.sh` for per-tool/subagent timing capture, and `lib/canary.sh` for model-drift canary signals (the latter two lazy-loaded via `_omc_load_timing` / `_omc_load_classifier`). Continues to provide domain routing, project profile detection (`detect_project_profile`), quality scorecard generation (`build_quality_scorecard`), stall detection helpers (`compute_stall_threshold`, `compute_progress_score`), dimension risk ordering (`order_dimensions_by_risk`), cross-session agent metrics (`record_agent_metric`), defect pattern tracking (`record_defect_pattern`, `get_defect_watch_list`), and the `_cap_cross_session_jsonl` aggregate-rotation helper.
- **record-scope-checklist.sh** (`autowork/scripts/record-scope-checklist.sh`): State-backed checklist for example-marker prompts. `prompt-intent-router.sh` arms `exemplifying_scope_required=1` when an execution prompt uses `for instance` / `e.g.` / `such as` / `as needed`; the model records sibling class items in `exemplifying_scope.json`, then marks each `shipped` or `declined` with a concrete WHY. `stop-guard.sh` blocks silent drops while pending items remain.
- **record-delivery-action.sh** (`autowork/scripts/record-delivery-action.sh`): PostToolUse Bash recorder for successful delivery actions (`git commit`, `git push`, `git tag`, and `gh pr/release/issue` publish-class commands). Feeds the delivery-contract gate so prompts that explicitly require commit or publish actions cannot be satisfied by prose alone.
- **lib/state-io.sh** (`autowork/scripts/lib/state-io.sh`): Extracted state I/O module. Sourced by `common.sh` after `validate_session_id` and `log_anomaly` are defined. The lib uses portable readlink resolution so it works whether `common.sh` is installed normally, symlinked into a test HOME, or symlinked to a custom location.
- **lib/classifier.sh** (`autowork/scripts/lib/classifier.sh`): Extracted prompt classification subsystem (~500 lines). Sourced by `common.sh` after every classifier dependency (`project_profile_has`, `is_advisory_request`, `normalize_task_prompt`, etc.) is defined. Behavior identical to the prior in-place definitions; this module exists for clearer ownership and to give the regression suite (`test-intent-classification.sh`, `test-classifier-replay.sh`) a single file of truth for future tuning.
- **lib/verification.sh** (`autowork/scripts/lib/verification.sh`): Extracted verification subsystem (~300 lines). Sourced by `common.sh` immediately after `lib/state-io.sh` (no inter-lib dependencies — pure functions over command text, output, and `OMC_CUSTOM_VERIFY_MCP_TOOLS`). Owns: bash test-command matching (`verification_matches_project_test_command`), framework-keyword detection (`verification_has_framework_keyword`), output-signal heuristics (`verification_output_has_counts`, `verification_output_has_clear_outcome`), the verification-method label and confidence score, plus MCP tool classification, scoring, and outcome detection. Behavior identical to the prior in-place definitions.
- **Agent definitions** (`agents/*.md`): Markdown files defining specialist agents with role descriptions, capabilities, and `disallowedTools` for permission boundaries.
- **Skills** (`skills/<name>/SKILL.md`): Self-contained skill definitions invoked by slash commands or automatic routing.
- **Settings patch** (`config/settings.patch.json`): JSON configuration merged into the user's Claude Code settings during installation.

### State Management

Session state is stored as JSON in `$HOME/.claude/quality-pack/state/<session_id>/session_state.json`. All state reads and writes go through `read_state` and `write_state` / `write_state_batch` in `common.sh`.

Cross-session data is stored alongside the state directory:
- `$HOME/.claude/quality-pack/agent-metrics.json` — agent invocation counts, clean/findings verdicts, rolling confidence averages. Accessed via `record_agent_metric()` / `read_agent_metric()`.
- `$HOME/.claude/quality-pack/defect-patterns.json` — defect category frequencies and recent examples. Accessed via `record_defect_pattern()` / `get_top_defect_patterns()` / `get_defect_watch_list()`. Injected into prompts to prime the model for historically frequent defect categories.

## Conventions

### Bash Scripts

- All scripts begin with `set -euo pipefail`.
- Hook scripts source `common.sh` for shared utilities.
- Hook scripts must exit 0 when `SESSION_ID` is missing or empty. This is a safety guard for cases where the hook is invoked outside a valid session.
- Never hardcode user paths. Use `$HOME` or relative paths.

### State

- All state is JSON, stored in `session_state.json` per session.
- Use `write_state_batch` for atomic multi-key updates.
- Use `read_state` for reads; it returns empty string for missing keys.
- The canonical state-key dictionary lives in `docs/architecture.md` → "State keys in `session_state.json`". When adding a new state key, update that table in the same commit.

### Agents

- Each agent is a single `.md` file in `bundle/dot-claude/agents/`.
- Agents use `disallowedTools` to enforce permission boundaries (e.g., a reviewer agent cannot edit files).
- Agent names should be descriptive and hyphen-separated.

#### Reviewer VERDICT contract

Reviewer-style agents (`quality-reviewer`, `editor-critic`, `excellence-reviewer`, `release-reviewer`, `metis`, `briefing-analyst`, `design-reviewer`, `abstraction-critic`) must end their output with exactly one line:

- `VERDICT: CLEAN` or `VERDICT: SHIP` — no actionable findings, dimension ticks
- `VERDICT: FINDINGS (N)` or `VERDICT: BLOCK (N)` — N blocking findings, dimension does NOT tick

`N=0` should be rendered as `CLEAN`/`SHIP`, never `FINDINGS (0)` — though the parser accepts and re-maps it to clean for safety. The stop-guard's `record-reviewer.sh` hook reads this line to determine whether to tick the reviewer's dimension. Agents that forget the verdict line fall back to a legacy phrase-based detector, but the structured contract is preferred because it removes ambiguity.

##### Stricter-verdict-wins invariant (v1.44-pre)

When multiple reviewers cover the same dimension and their verdicts disagree, the **stricter verdict is authoritative** — pessimism wins across the reviewer chain. cc10x's F11 names the same rule; oh-my-claude enforces it via two mechanisms working together:

1. **Storage-side preservation (`common.sh` dim helpers).** `tick_dimensions_with_verdict` and `set_dimension_verdicts` route through `_write_stricter_dim_verdicts_unlocked`, which reads each dimension's current verdict and writes the stricter of `(current, new)` on the severity ladder `CLEAN/SHIP (0) < FINDINGS (1) < BLOCK (2)`. A CLEAN from quality-reviewer cannot overwrite a FINDINGS from excellence-reviewer on the same dimension.
2. **Gate-side enforcement (`stop-guard.sh` stricter-verdict-wins gate).** After the review-coverage gate confirms all required dimensions are ticked, the stricter-verdict-wins gate scans each required dim's verdict and blocks Stop on any fresh `FINDINGS*`/`BLOCK*`. "Fresh" means the dim ts is at-or-after `last_code_edit_ts` — a stale FINDINGS predating the most recent edit does NOT block (the reviewer hadn't seen the fix).

**Edit-aware override.** When the user addresses findings and re-runs the reviewer, the new CLEAN verdict's ts updates past `last_code_edit_ts` and the storage helper detects the prior FINDINGS is now stale — the new CLEAN wins outright. The gate self-clears on the fix-and-re-review path without requiring an explicit reset surface.

**Why this matters.** Before v1.44-pre, the implicit semantics was "last-reviewer-wins" — whichever reviewer wrote last set the dimension's verdict, and stop-guard only consumed the ts. A quality-reviewer reporting CLEAN AFTER a sibling excellence-reviewer's FINDINGS silently dropped the findings (the dimension's ts was already valid from the CLEAN, and the FINDINGS verdict was stored but never read by any gate). The stricter-wins invariant closes that gap; `tests/test-stricter-verdict-wins.sh` is the regression net.

#### Universal VERDICT contract (v1.14.0)

In v1.14.0 the VERDICT contract was extended beyond the reviewer agents to all agents, so the final-line outcome is structured and uniform across roles; it has grown with the agent set since, and the role-table footer below is authoritative for the live count. The reviewer-class agents above remain unchanged (their `CLEAN`/`SHIP`/`FINDINGS`/`BLOCK` vocabulary is still what `record-reviewer.sh` parses). The non-reviewer agents gained role-appropriate tokens; planners are read by `record-plan.sh` (which now sets `plan_verdict` state) and the rest are forward-looking — read by humans today, available to future hooks.

| Role | Agents | Vocabulary | Meaning | Consumer today |
|---|---|---|---|---|
| Reviewer / critic | (see "Reviewer VERDICT contract" above) | `CLEAN` / `SHIP` / `FINDINGS (N)` / `BLOCK (N)` | No findings → ticks dimension; N findings → blocks until addressed. | `record-reviewer.sh` |
| Lens evaluator | `data-lens`, `design-lens`, `growth-lens`, `product-lens`, `security-lens`, `sre-lens`, `visual-craft-lens` | `CLEAN` / `FINDINGS (N)` | Lens raised N priority findings (or none). | None — informational. The discovered-scope ledger is fed separately by `extract_discovered_findings()` parsing `### Findings`-style headings in the lens body, not by this verdict line. |
| Planner | `prometheus`, `quality-planner` | `PLAN_READY` / `NEEDS_CLARIFICATION` / `BLOCKED` | Plan is decision-complete, needs user input, or blocked. | `record-plan.sh` writes `plan_verdict` to session state. |
| Researcher | `librarian`, `quality-researcher` | `REPORT_READY` / `INSUFFICIENT_SOURCES` | Research is grounded, or sources are insufficient and the main thread should expect uncertainty. | None — informational. |
| Debugger / architect | `oracle` | `RESOLVED` / `HYPOTHESIS` / `NEEDS_EVIDENCE` | Root cause identified, best guess offered, or more data needed. | None — informational. |
| Framer | `divergent-framer` | `FRAMINGS_READY (N)` / `NEEDS_PROBLEM_STATEMENT` / `INSUFFICIENT_OPTIONS` | N candidate framings emitted (3 ≤ N ≤ 5), problem too vague to frame against, or only one credible framing. | None — informational. |
| Operations | `atlas`, `chief-of-staff` | `DELIVERED` / `NEEDS_INPUT` / `BLOCKED` | Deliverable is ready, awaiting user decision, or blocked. | None — informational. |
| Writer | `draft-writer`, `writing-architect` | `DELIVERED` / `NEEDS_INPUT` / `NEEDS_RESEARCH` | Draft/structure is ready, awaiting decision, or needs factual research. | None — informational. |
| Implementer | `backend-api-developer`, `devops-infrastructure-engineer`, `frontend-developer`, `fullstack-feature-builder`, `ios-core-engineer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`, `ios-ui-developer`, `test-automation-engineer` | `SHIP` / `INCOMPLETE` / `BLOCKED` | Implementation is complete and verified, partial, or blocked on a hard prerequisite. | None — informational. |

Total: 8 reviewer-class + 7 lens + 2 planner + 2 researcher + 1 debugger + 1 framer + 2 operations + 2 writer + 9 implementer = **34 agents** (as of v1.32.x; release-reviewer added). The contract-presence regression net is `tests/test-agent-verdict-contract.sh` — when adding a new agent or role, extend that test's `role_of_agent()` and `allowed_tokens_of_role()` cases in lockstep with this table.

When wiring a new VERDICT vocabulary into a hook consumer, extend the parser regex in `record-reviewer.sh` (or add a new parser as `record-plan.sh` did for `plan_verdict`). Until then, the informational rows above emit the verdict for human readability and forward compatibility — the gate's behavior is unchanged for those agents.

#### Structured FINDINGS_JSON contract (v1.28.0)

Eight finding-emitting agents — `quality-reviewer`, `excellence-reviewer`, `release-reviewer`, `oracle`, `abstraction-critic`, `metis`, `design-reviewer`, `briefing-analyst` — emit a single-line `FINDINGS_JSON: [...]` block immediately before the `VERDICT:` line when findings exist. Each finding object: `{severity, category, file, line, claim, evidence, recommended_fix}`. Severity ∈ `{high, medium, low}`. Category ∈ `{bug, missing_test, completeness, security, performance, docs, integration, design, other}`. Empty array `[]` is valid for clean reviews.

The `extract_findings_json` helper in `common.sh` parses the line preferentially over the legacy prose heuristic; `normalize_finding_object` coerces severity aliases (`critical`/`p0`/`p1`/`p2`/`blocker` → `high`/`medium`/`low`) and unknown categories → `other`. The discovered-scope pipeline (`extract_discovered_findings`) takes the JSON path when present and emits rows with a `.structured` field carrying the full payload, falling through to the legacy heuristic only when the line is missing/empty/malformed (fail-open). Single-line array form remains preferred for robust grep/debug workflows; the parser also accepts pretty-printed JSON arrays that start on the `FINDINGS_JSON:` line and close before `VERDICT:`.

`editor-critic` is intentionally excluded from the contract — its findings are prose-quality observations, not severity-anchored structured items. The contract-presence regression net is `tests/test-findings-json.sh`.

#### Dimension mapping

The prescribed reviewer sequence (Check 4 of stop-guard) enforces distinct dimensions per reviewer on complex tasks:

| Reviewer | Dimension(s) ticked |
|---|---|
| `quality-reviewer` | `bug_hunt`, `code_quality` |
| `metis` | `stress_test` |
| `excellence-reviewer` | `completeness` (plus resets legacy `last_excellence_review_ts`) |
| `release-reviewer` | None (manual-dispatch only at release-prep time as of v1.32.x; cumulative-diff cross-wave reviewer, not a per-wave verifier) |
| `editor-critic` | `prose` (only dimension that responds to doc edits) |
| `briefing-analyst` | `traceability` (only required at `traceability_file_count`+ files, default 6) |
| `design-reviewer` | `design_quality` (only required when UI files edited: `.tsx`, `.jsx`, `.vue`, `.svelte`, `.astro`, `.css`, `.scss`, `.sass`, `.less`, `.styl`, `.html`, `.htm`) |
| `abstraction-critic` | None (manual-dispatch only as of v1.19.0; not wired to a stop-guard dimension) |
| `divergent-framer` | None (manual-dispatch only via `/diverge` skill as of v1.31.0; upstream of planning, not a verifier) |

Each dimension ticks via `tick_dimension <name>` in `common.sh`, which wraps `write_state` in `with_state_lock` to prevent concurrent-tick races. Dimensions are validated via timestamp comparison against the relevant edit clock (`last_code_edit_ts` for most, `last_doc_edit_ts` for `prose`), so a post-tick edit implicitly invalidates the dimension without needing an explicit clear.

When adding a new reviewer-style agent that should participate in the prescribed sequence, wire it in `config/settings.patch.json` under `SubagentStop` with the reviewer-type argument: `$HOME/.claude/skills/autowork/scripts/record-reviewer.sh <type>` where `<type>` is `standard`, `excellence`, `prose`, `stress_test`, `traceability`, or `design_quality`. Update this table and the reviewer's agent file to document the new dimension mapping.

#### Discovered-scope capture (advisory specialists)

Separately from the reviewer dimensions above, the universal SubagentStop hook (`record-subagent-summary.sh`) captures findings from **advisory specialists** into a per-session `discovered_scope.jsonl`. Whitelist: `metis`, `briefing-analyst`, `oracle`, `abstraction-critic`, `editor-critic` (added v1.42.x-newer), and the seven council lenses (`security-lens`, `data-lens`, `product-lens`, `growth-lens`, `sre-lens`, `design-lens`, `visual-craft-lens`). Verifier agents (`quality-reviewer`, `excellence-reviewer`, `design-reviewer`, `release-reviewer`) are intentionally excluded — their findings already feed dedicated dimensions. Note `editor-critic` IS captured because it emits ranked findings on prose drafts; the dimension pipeline ticks `prose` independently. **`prometheus` is deliberately NOT on the list** — it returns `PLAN_READY`/`NEEDS_CLARIFICATION`/`BLOCKED` verdicts, not findings; counting it would over-trigger the advisory-no-findings gate.

The capture wiring uses no per-agent matcher (Approach A in the plan), so adding a new advisory specialist requires updating BOTH `discovered_scope_capture_targets()` in `common.sh` AND `_is_advisory_specialist()` in `record-pending-agent.sh` in lockstep (per the CLAUDE.md coordination rule). The downstream stop-guard reads pending count and blocks (cap: 2) when execution intent is active.

**Dual-pipeline participation.** `metis` and `briefing-analyst` participate in **both** the reviewer-dimension pipeline (via `record-reviewer.sh stress_test` / `traceability` matchers) and the discovered-scope ledger (via the universal summary hook). These are independent surfaces: the reviewer pipeline ticks dimensions for the stop-guard's coverage gate; the discovered-scope ledger feeds the completeness gate. They do not deduplicate — when adding or modifying these specialists, update both surfaces deliberately. The same applies to any future advisory specialist that also acts as a verifier.

**Silent-disarm telemetry.** When a whitelisted specialist returns more than 800 characters but the heuristic extractor catches zero findings, `record-subagent-summary.sh` writes a `[anomaly]` row via `log_anomaly`. This makes prose-style drift (specialist drops a `### Findings` heading, switches to prose-only output) visible instead of silently disabling the gate.

#### Design-craft reference surface (`bundle/dot-claude/quality-pack/design-craft/`)

A 6th architectural surface alongside `agents/`, `skills/`, `quality-pack/scripts/`, `quality-pack/memory/`, and `output-styles/`. Contains on-demand reference doctrine consulted by the design-side agents to ground critique and creation in canonical art-historical principles rather than generic vocabulary.

Current contents: `art-taste-doctrine.md` (the anchor — Rothko, Albers, Rams, Tschichold, Hokusai, Vermeer, Mondrian, Cartier-Bresson, Fukasawa, Vignelli, Müller-Brockmann, Klein, Klimt, Bauhaus, Memphis, the 12 Disney animation principles, Maeda's *Laws of Simplicity*, Tufte's data-ink, Susan Kare, Don Norman, Bret Victor), `a11y-doctrine.md`, `design-for-hackers.md`, and `taste-skill-doctrine.md`.

**Consumed by 6 design-side surfaces** (5 agents + 1 skill) — `visual-craft-lens`, `design-reviewer`, `frontend-developer`, `ios-ui-developer`, `design-lens` (UX-trimmed 3-principle variant), and the `frontend-design` SKILL (the other 5 receive the visual-craft 8-principle variant). Each agent inlines the load-bearing principles and references the canonical `~/.claude/quality-pack/design-craft/<file>.md` path so the deep doctrine is one tool-call away. **Intentionally NOT in the global `@`-include chain** — loading several thousand words of design doctrine on every non-UI session is the wrong tax shape; on-demand grounding scoped to design agents is the right shape.

**4-site coordination lockstep** (mirrors the memory-file lockstep): (1) the doctrine file itself, (2) `verify.sh` `required_paths`, (3) inline reference + Art-Taste Calibration section in each consuming agent, (4) `tests/test-art-taste-doctrine.sh` regression net. Adding/removing a design-craft reference requires updating all four; missing any one is a silent failure. Full lockstep is documented at the project root in `CLAUDE.md` Coordination Rules → "Adding or removing a design-craft reference."

#### Bypass-surface taxonomy (v1.42.x-newer, lifted to `docs/bypass-taxonomy.md` in v1.43)

The four-category framework for stop-guard bypass defenses
(**state-predicate**, **prose-pattern**, **single-call-flip**,
**classifier-misroute**) is documented at full length in
**[`docs/bypass-taxonomy.md`](docs/bypass-taxonomy.md)** — a standalone,
project-independent reference. The v1.42.x bypass-closure work added
seven mechanical defenses + one umbrella regression net
(`tests/test-stop-guard-bypass-surface.sh`).

**Application rule (short form — full version in the standalone doc):**

1. Name the category in the design doc / CHANGELOG entry.
2. If the proposal is **prose-pattern** and the live count is already
   ≥3, the proposal MUST first attempt a state-predicate alternative.
   If none exists, the justification goes in CHANGELOG so the next
   reviewer can challenge it.
3. The umbrella regression net must add coverage in the same commit
   per the existing coordination rule.
4. FP-audit notes go in a comment block at the call site so future
   cleanup waves know what to keep.

The taxonomy converts *"should we add another regex?"* from a tactical
decision into a structural one. See the standalone doc for the
four-category table, the current per-category defense inventory, and
the "when to reach for which category" practical guide — that doc is
the single source of truth for the live defense counts.

- Agent `model:` assignments (`opus` or `sonnet`) are set in the bundle but can be overridden at install time via `--model-tier`. The installer rewrites the `model:` line after copying. When adding a new agent, assign `model: opus` for complex reasoning tasks or `model: sonnet` for faster execution tasks. See [customization.md](docs/customization.md#model-tiers) for details.

## Testing

Run these before submitting changes:

```bash
# Syntax validation
bash -n bundle/dot-claude/**/*.sh

# Linting
shellcheck bundle/dot-claude/**/*.sh

# Integration verification
bash verify.sh

# Unit / integration tests — run the full suite using the canonical
# command list in CLAUDE.md → "Testing". CLAUDE.md is the single source
# of truth so this file does not have to track every test addition; the
# tally above (`tests/  # NN bash + 1 python …`) and CLAUDE.md must
# agree on the count.
```

## Protected Design Decisions

Do not change these without discussion in a GitHub issue:

1. **Intent classification order in `classify_task_intent()`**: Imperative intents are matched before advisory intents. This ensures explicit action requests are never misclassified as advice-seeking.

2. **Stop guard block limits**: Review/verification gate is hard-capped at 3 blocks per session. The excellence gate (for multi-file tasks) is capped at 1 block, controlled by a separate `excellence_guard_triggered` flag. These caps prevent runaway execution while giving enough cycles for completeness-focused review and remediation.

3. **Agent permission boundaries via `disallowedTools`**: Each agent's `.md` file specifies which tools it cannot use. This is the primary security boundary -- do not weaken an agent's restrictions without a clear justification.

4. **40% threshold for mixed domain classification**: When no single domain exceeds 40% of signal weight, the task is classified as "mixed" and routed to a generalist agent. Changing this threshold affects routing accuracy across all intents.

5. **Agent-first gate is opt-in as of v1.43+** (`agent_first_gate=off` default). The mandate was firing ~2.2×/session under `model_tier=quality` (main thread and specialists both Opus) without paying for itself — `core.md` Thinking Quality + `model-robustness.md` Mechanism 2 carry the actual concern under default-off. **Telemetry capture is unconditional**: `first_mutation_ts`, `first_mutation_tool`, and `agent_first_gate_state` (the gate state AT mutation time, stamped by both `pretool-intent-guard.sh` and `mark-edit.sh`) all record regardless of the flag, so `/ulw-report` can compare opt-in vs opt-out outcomes per-row. The Stop backstop reads `agent_first_gate_state` from session state (not the live env var), so off→on / on→off toggle mid-session does not produce flag-flip footguns. **Do not re-mandate** without verifying all three justifying premises (smartness-gap, no depth-rule, low round-trip cost) hold again — see `~/.claude/projects/.../memory/project_agent_first_mandate_to_tool.md`. Per-conf-source restrictions (security-load-bearing flags refused from project-level conf to defeat malicious-repo flip attempts) apply to this flag too.

6. **Security-load-bearing flags refuse project-conf overrides** (`pretool_intent_guard`, `bg_spawn_gate`, `agent_first_gate`, `no_defer_mode`). A malicious or unfamiliar repo's `.claude/oh-my-claude.conf` cannot disable defensive gates the user opted into at the user level (`${HOME}/.claude/oh-my-claude.conf`). Env vars still override both as before. When adding a new security-load-bearing flag, add it to the `case` deny-list in `common.sh` `_parse_conf_file` so it can't be project-flipped, and pin a regression test in `tests/test-stop-guard-bypass-surface.sh` F-013.

## Documentation Maintenance

When you add, remove, or rename agents, skills, scripts, or directories, update these files to reflect the change:

- **CLAUDE.md** -- key directories, key files, and testing sections
- **AGENTS.md** -- architecture diagram and component descriptions
- **README.md** -- repository structure, feature descriptions, and counts
- **CONTRIBUTING.md** -- testing and component-addition sections

Counts (agents, skills, scripts) and directory listings go stale fast. Keep them accurate.

## Adding New Components

### Adding an Agent

1. Create `bundle/dot-claude/agents/<agent-name>.md`.
2. Define the agent's role, capabilities, and constraints.
3. Specify `disallowedTools` to enforce permission boundaries appropriate to the role.
4. If the agent handles a specific domain, ensure `infer_domain()` in `common.sh` can route to it.

### Adding a Skill

1. Create `bundle/dot-claude/skills/<skill-name>/SKILL.md`.
2. Define trigger conditions, instructions, and any required scripts.
3. If the skill needs hook scripts, place them in `bundle/dot-claude/skills/<skill-name>/scripts/`.

### Adding a Hook Script

1. Place the script in the appropriate directory:
   - Lifecycle hooks: `bundle/dot-claude/quality-pack/scripts/`
   - Autowork hooks: `bundle/dot-claude/skills/autowork/scripts/`
2. Begin with `set -euo pipefail`.
3. Source `common.sh`: `. "${HOME}/.claude/skills/autowork/scripts/common.sh"`
4. Exit 0 on missing `SESSION_ID`.
5. Register the hook in `config/settings.patch.json` under the appropriate event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `SubagentStop`, or `Stop`).
