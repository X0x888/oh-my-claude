# AGENTS.md

Instructions for AI agents working on the oh-my-claude repository.

## Project Context

oh-my-claude is a cognitive quality harness for Claude Code. It provides bash hooks, skills, and specialist agents that enforce thinking, testing, and review during AI-assisted development. The system is pure bash with zero npm dependencies.

## Architecture

```
oh-my-claude/
  install.sh                  # Merge-safe installer (--bypass-permissions, --no-ios, --model-tier)
  uninstall.sh                # Clean removal
  verify.sh                   # Post-install integrity checker

  bundle/dot-claude/          # Installs to ~/.claude/
    agents/                   # 32 specialist agent definitions (.md)
    output-styles/            # Output format templates
    quality-pack/
      memory/                 # Core, skills, and compact memory files
      scripts/                # 5 lifecycle hook scripts (prompt routing, compaction, session)
    skills/                   # 20 skill definitions, each in <name>/SKILL.md
      autowork/scripts/       # 21 autowork hook scripts and utilities
        common.sh             # Shared functions (JSON, classification, scope)
        lib/state-io.sh       # Extracted state I/O subsystem; sourced by common.sh
        lib/classifier.sh     # Extracted prompt classifier (P0 + P1 + telemetry); sourced by common.sh
        lib/verification.sh   # Extracted verification subsystem (Bash + MCP scoring); sourced by common.sh
    statusline.py             # Custom statusline with context tracking
    CLAUDE.md                 # Installed user-facing CLAUDE.md

  config/
    settings.patch.json       # Settings merged into user's settings.json

  tests/                      # Test scripts (32 bash + 1 python)
    test-agent-verdict-contract.sh
    test-classifier-replay.sh
    test-classifier.sh
    test-common-utilities.sh
    test-concurrency.sh
    test-cross-session-rotation.sh
    test-design-contract.sh
    test-discover-session.sh
    test-discovered-scope.sh
    test-e2e-hook-sequence.sh
    test-finding-list.sh
    test-gate-events.sh
    test-install-artifacts.sh
    test-install-remote.sh
    test-intent-classification.sh
    test-phase8-integration.sh
    test-post-merge-hook.sh
    test-quality-gates.sh
    test-repro-redaction.sh
    test-serendipity-log.sh
    test-session-resume.sh
    test-settings-merge.sh
    test-show-report.sh
    test-stall-detection.sh
    test-state-io.sh
    test-uninstall-merge.sh
    test-verification-lib.sh
    test_statusline.py

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

Reviewer-style agents (`quality-reviewer`, `editor-critic`, `excellence-reviewer`, `metis`, `briefing-analyst`, `design-reviewer`, `abstraction-critic`) must end their output with exactly one line:

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

Total: 7 reviewer-class + 7 lens + 2 planner + 2 researcher + 1 debugger + 2 operations + 2 writer + 9 implementer = **32 agents** (as of v1.19.0). The contract-presence regression net is `tests/test-agent-verdict-contract.sh` — when adding a new agent or role, extend that test's `role_of_agent()` and `allowed_tokens_of_role()` cases in lockstep with this table.

When wiring a new VERDICT vocabulary into a hook consumer, extend the parser regex in `record-reviewer.sh` (or add a new parser as `record-plan.sh` did for `plan_verdict`). Until then, the informational rows above emit the verdict for human readability and forward compatibility — the gate's behavior is unchanged for those agents.

#### Dimension mapping

The prescribed reviewer sequence (Check 4 of stop-guard) enforces distinct dimensions per reviewer on complex tasks:

| Reviewer | Dimension(s) ticked |
|---|---|
| `quality-reviewer` | `bug_hunt`, `code_quality` |
| `metis` | `stress_test` |
| `excellence-reviewer` | `completeness` (plus resets legacy `last_excellence_review_ts`) |
| `editor-critic` | `prose` (only dimension that responds to doc edits) |
| `briefing-analyst` | `traceability` (only required at `traceability_file_count`+ files, default 6) |
| `design-reviewer` | `design_quality` (only required when UI files edited: `.tsx`, `.jsx`, `.vue`, `.svelte`, `.astro`, `.css`, `.scss`, `.sass`, `.less`, `.styl`, `.html`, `.htm`) |
| `abstraction-critic` | None (manual-dispatch only as of v1.19.0; not wired to a stop-guard dimension) |

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

# Unit / integration tests
bash tests/test-intent-classification.sh
bash tests/test-quality-gates.sh
bash tests/test-stall-detection.sh
bash tests/test-e2e-hook-sequence.sh
bash tests/test-concurrency.sh
bash tests/test-install-artifacts.sh
bash tests/test-post-merge-hook.sh
bash tests/test-repro-redaction.sh
bash tests/test-settings-merge.sh
bash tests/test-uninstall-merge.sh
bash tests/test-common-utilities.sh
bash tests/test-session-resume.sh
bash tests/test-discovered-scope.sh
bash tests/test-finding-list.sh
bash tests/test-state-io.sh
bash tests/test-classifier-replay.sh
bash tests/test-serendipity-log.sh
bash tests/test-cross-session-rotation.sh
bash tests/test-classifier.sh
bash tests/test-show-report.sh
bash tests/test-install-remote.sh
python3 -m unittest tests.test_statusline -v
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
