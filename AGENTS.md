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
| Already-current check (after `git -C "$repo_path" fetch origin`): `installed_version=` matches latest tag AND `installed_sha=` matches `git -C "$repo_path" rev-parse origin/main` | install or update | **Tell the user the harness is already current.** Print version and last-install timestamp. Use `stat -f %Sm ~/.claude/.install-stamp` on macOS or `stat -c %y ~/.claude/.install-stamp` on Linux — pick by `uname -s` (`Darwin` → BSD form, anything else → GNU form), or try one and fall back. Recommend `/ulw-demo` if they haven't seen the gates fire. |

The already-current branch needs `repo_path` and a fresh `git fetch` before the comparison resolves — Step 0 is read-only on the conf, so this branch only completes after the agent has cd'd into `$repo_path` (start of Step 2).

### Step 1 — Fresh install

1. **Clone to the canonical location.** Use `~/.local/share/oh-my-claude` — this matches the curl-pipe-bash bootstrapper (`install-remote.sh`), so future updates work the same way no matter how the user originally installed:
   ```bash
   git clone https://github.com/X0x888/oh-my-claude.git ~/.local/share/oh-my-claude
   ```
   If `~/.local/share/oh-my-claude` already exists, detect what's there before overwriting:
   ```bash
   git -C ~/.local/share/oh-my-claude config --get remote.origin.url 2>/dev/null
   ```
   If the URL matches `X0x888/oh-my-claude`, treat it as an existing clone — skip clone and continue to step 3 (or run `git pull` first). If it returns a different URL or empty, stop and ask the user — do not overwrite a sibling repo.

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

1. Read `repo_path=` from `~/.claude/oh-my-claude.conf`. Capture `installed_sha=` first too — you'll need its old value for the changelog summary.
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
4. Summarize what the pull brought in:
   ```bash
   git -C "$repo_path" log --oneline "$prior_installed_sha"..HEAD
   ```
   (Use the value of `installed_sha=` you captured *before* running `install.sh` — the installer overwrites it.)
5. Continue to **Step 3 — Restart instruction** (only if any bundle file changed; `verify.sh` prints an `Orphans:` block if files were removed).

### Step 3 — Tell the user to restart Claude Code

This is the single highest-leverage instruction in the protocol. Claude Code loads hooks at session start; an already-running session keeps its previous wiring until restart. Skip this step and the user types `/ulw <task>` in their current session, sees no behavioral change, and concludes the install is broken.

After install — and after any update that changed bundle files — **explicitly tell the user**:

> Restart Claude Code (or open a new session) before testing. Already-running sessions keep the previous hook wiring, so `/ulw` will silently no-op until you restart.

If the user is in the same Claude Code session that ran the install, they must start a new session before any harness behavior becomes observable.

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

> oh-my-claude is a cognitive quality harness for Claude Code. After you restart, `/ulw <task>` runs any non-trivial work through specialist agents and quality gates that block until testing and review are done — it works for coding, writing, research, and operations. Run `/ulw-demo` first to feel how the gates fire on a quick walkthrough (under 2 minutes).

The next section is for repo contributors only.

---

## Project Context

> If you're helping a user install or update, the [Agent Install Protocol](#agent-install-protocol--installing-or-updating-oh-my-claude) above is what you want, not this section.

oh-my-claude is a cognitive quality harness for Claude Code. It provides bash hooks, skills, and specialist agents that enforce thinking, testing, and review across coding, writing, research, and operations work. The system is pure bash with zero npm dependencies.

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
      scripts/                # 9 lifecycle scripts (prompt routing, compaction, session, stop-failure, resume-hint, resume-watchdog)
    skills/                   # 25 skill definitions, each in <name>/SKILL.md
      autowork/scripts/       # 33 autowork hook scripts and utilities
        common.sh             # Shared functions (JSON, classification, scope)
        lib/state-io.sh       # Extracted state I/O subsystem; sourced by common.sh
        lib/classifier.sh     # Extracted prompt classifier (P0 + P1 + telemetry); sourced by common.sh
        lib/verification.sh   # Extracted verification subsystem (Bash + MCP scoring); sourced by common.sh
    statusline.py             # Custom statusline with context tracking
    CLAUDE.md                 # Installed user-facing CLAUDE.md

  config/
    settings.patch.json       # Settings merged into user's settings.json

  tests/                      # 80 bash + 1 python test scripts; CLAUDE.md "Testing" lists each one

  tools/                      # Developer tools (not installed)
    replay-classifier-telemetry.sh
    classifier-fixtures/
      regression.jsonl

  docs/                       # Extended documentation
    architecture.md
    customization.md
    faq.md
    prompts.md
```

### Key Components

- **Hook scripts** (`quality-pack/scripts/`, `autowork/scripts/`): Bash scripts triggered by Claude Code lifecycle events (prompt entry, pre-tool-use, tool completion, compaction, session start). They route intents, manage state, and enforce quality gates.
- **common.sh** (`autowork/scripts/common.sh`): Shared utility library. Sources `lib/state-io.sh` for the state I/O subsystem (`read_state`, `write_state`, `write_state_batch`, `with_state_lock`, `with_state_lock_batch`, `ensure_session_dir`, `session_file`, `append_state`, `append_limited_state`), `lib/verification.sh` for verification scoring and MCP-tool classification (`verification_matches_project_test_command`, `verification_has_framework_keyword`, `detect_verification_method`, `score_verification_confidence`, `classify_mcp_verification_tool`, `score_mcp_verification_confidence`, `detect_mcp_verification_outcome`), and `lib/classifier.sh` for prompt classification (`is_imperative_request`, `count_keyword_matches`, `is_ui_request`, `infer_domain`, `classify_task_intent`, `record_classifier_telemetry`, `detect_classifier_misfire`, `is_execution_intent_value`). Continues to provide domain routing, project profile detection (`detect_project_profile`), quality scorecard generation (`build_quality_scorecard`), stall detection helpers (`compute_stall_threshold`, `compute_progress_score`), dimension risk ordering (`order_dimensions_by_risk`), cross-session agent metrics (`record_agent_metric`), defect pattern tracking (`record_defect_pattern`, `get_defect_watch_list`), and the `_cap_cross_session_jsonl` aggregate-rotation helper.
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

#### Universal VERDICT contract (v1.14.0)

In v1.14.0 the VERDICT contract was extended to all 30 agents so the final-line outcome is structured and uniform across roles. The 6 reviewer-class agents above remain unchanged (their `CLEAN`/`SHIP`/`FINDINGS`/`BLOCK` vocabulary is still what `record-reviewer.sh` parses). v1.15.0 adds `visual-craft-lens` (lens-class) bringing the total to 31. v1.19.0 adds `abstraction-critic` (reviewer-class, manual-dispatch only) bringing the total to 32. The 25 non-reviewer agents gained role-appropriate tokens; planners are read by `record-plan.sh` (which now sets `plan_verdict` state) and the rest are forward-looking — read by humans today, available to future hooks.

| Role | Agents | Vocabulary | Meaning | Consumer today |
|---|---|---|---|---|
| Reviewer / critic | (see "Reviewer VERDICT contract" above) | `CLEAN` / `SHIP` / `FINDINGS (N)` / `BLOCK (N)` | No findings → ticks dimension; N findings → blocks until addressed. | `record-reviewer.sh` |
| Lens evaluator | `data-lens`, `design-lens`, `growth-lens`, `product-lens`, `security-lens`, `sre-lens`, `visual-craft-lens` | `CLEAN` / `FINDINGS (N)` | Lens raised N priority findings (or none). | None — informational. The discovered-scope ledger is fed separately by `extract_discovered_findings()` parsing `### Findings`-style headings in the lens body, not by this verdict line. |
| Planner | `prometheus`, `quality-planner` | `PLAN_READY` / `NEEDS_CLARIFICATION` / `BLOCKED` | Plan is decision-complete, needs user input, or blocked. | `record-plan.sh` writes `plan_verdict` to session state. |
| Researcher | `librarian`, `quality-researcher` | `REPORT_READY` / `INSUFFICIENT_SOURCES` | Research is grounded, or sources are insufficient and the main thread should expect uncertainty. | None — informational. |
| Debugger / architect | `oracle` | `RESOLVED` / `HYPOTHESIS` / `NEEDS_EVIDENCE` | Root cause identified, best guess offered, or more data needed. | None — informational. |
| Operations | `atlas`, `chief-of-staff` | `DELIVERED` / `NEEDS_INPUT` / `BLOCKED` | Deliverable is ready, awaiting user decision, or blocked. | None — informational. |
| Writer | `draft-writer`, `writing-architect` | `DELIVERED` / `NEEDS_INPUT` / `NEEDS_RESEARCH` | Draft/structure is ready, awaiting decision, or needs factual research. | None — informational. |
| Implementer | `backend-api-developer`, `devops-infrastructure-engineer`, `frontend-developer`, `fullstack-feature-builder`, `ios-core-engineer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`, `ios-ui-developer`, `test-automation-engineer` | `SHIP` / `INCOMPLETE` / `BLOCKED` | Implementation is complete and verified, partial, or blocked on a hard prerequisite. | None — informational. |

Total: 8 reviewer-class + 7 lens + 2 planner + 2 researcher + 1 debugger + 1 framer + 2 operations + 2 writer + 9 implementer = **34 agents** (as of v1.32.x; release-reviewer added). The contract-presence regression net is `tests/test-agent-verdict-contract.sh` — when adding a new agent or role, extend that test's `role_of_agent()` and `allowed_tokens_of_role()` cases in lockstep with this table.

When wiring a new VERDICT vocabulary into a hook consumer, extend the parser regex in `record-reviewer.sh` (or add a new parser as `record-plan.sh` did for `plan_verdict`). Until then, the informational rows above emit the verdict for human readability and forward compatibility — the gate's behavior is unchanged for those agents.

#### Structured FINDINGS_JSON contract (v1.28.0)

Eight finding-emitting agents — `quality-reviewer`, `excellence-reviewer`, `release-reviewer`, `oracle`, `abstraction-critic`, `metis`, `design-reviewer`, `briefing-analyst` — emit a single-line `FINDINGS_JSON: [...]` block immediately before the `VERDICT:` line when findings exist. Each finding object: `{severity, category, file, line, claim, evidence, recommended_fix}`. Severity ∈ `{high, medium, low}`. Category ∈ `{bug, missing_test, completeness, security, performance, docs, integration, design, other}`. Empty array `[]` is valid for clean reviews.

The `extract_findings_json` helper in `common.sh` parses the line preferentially over the legacy prose heuristic; `normalize_finding_object` coerces severity aliases (`critical`/`p0`/`p1`/`p2`/`blocker` → `high`/`medium`/`low`) and unknown categories → `other`. The discovered-scope pipeline (`extract_discovered_findings`) takes the JSON path when present and emits rows with a `.structured` field carrying the full payload, falling through to the legacy heuristic only when the line is missing/empty/malformed (fail-open). Single-line array form is required for robust grep-based extraction; pretty-printed JSON is intentionally NOT supported.

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

Separately from the reviewer dimensions above, the universal SubagentStop hook (`record-subagent-summary.sh`) captures findings from **advisory specialists** into a per-session `discovered_scope.jsonl`. Whitelist: `metis`, `briefing-analyst`, and the seven council lenses (`security-lens`, `data-lens`, `product-lens`, `growth-lens`, `sre-lens`, `design-lens`, `visual-craft-lens`). Verifier agents (`quality-reviewer`, `excellence-reviewer`, `editor-critic`, `design-reviewer`) are intentionally excluded — their findings already feed dedicated dimensions. The capture wiring uses no per-agent matcher (Approach A in the plan), so adding a new advisory specialist requires only updating `discovered_scope_capture_targets()` in `common.sh`. The downstream stop-guard reads pending count and blocks (cap: 2) when execution intent is active.

**Dual-pipeline participation.** `metis` and `briefing-analyst` participate in **both** the reviewer-dimension pipeline (via `record-reviewer.sh stress_test` / `traceability` matchers) and the discovered-scope ledger (via the universal summary hook). These are independent surfaces: the reviewer pipeline ticks dimensions for the stop-guard's coverage gate; the discovered-scope ledger feeds the completeness gate. They do not deduplicate — when adding or modifying these specialists, update both surfaces deliberately. The same applies to any future advisory specialist that also acts as a verifier.

**Silent-disarm telemetry.** When a whitelisted specialist returns more than 800 characters but the heuristic extractor catches zero findings, `record-subagent-summary.sh` writes a `[anomaly]` row via `log_anomaly`. This makes prose-style drift (specialist drops a `### Findings` heading, switches to prose-only output) visible instead of silently disabling the gate.
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
