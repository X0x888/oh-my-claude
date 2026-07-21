# oh-my-claude

Cognitive quality harness for Claude Code — bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Where deeper detail lives

This file is intentionally short. For implementation-level depth, read the source-of-truth doc:

| Topic | Source of truth |
|---|---|
| Components, state-key dictionary, request flow, intent classification, FINDINGS_JSON parser, Wave 3 watchdog, timing-row shapes | `docs/architecture.md` |
| Conf flags — defaults, env vars, behavior (full table) | `docs/customization.md` |
| Frozen five-axis quality contract, evidence/frontier protocol, Quality Constitution authority, blind A/B claim | `docs/definition-of-excellent.md` |
| Reviewer VERDICT contract, universal verdict tokens, FINDINGS_JSON schema, dimension mapping, discovered-scope capture targets | `AGENTS.md` |
| Release process (full pre-flight, bump, post-flight CI verification), code standards, adding new components | `CONTRIBUTING.md` |
| Conf-flag examples with inline defaults | `bundle/dot-claude/oh-my-claude.conf.example` |

If a fact appears here AND in one of the above, that doc is authoritative — keep this file's version a brief pointer, not a duplicated explanation.

## Key Directories

- `bundle/dot-claude/agents/` — 37 specialist agent definitions; the 26 inspection/judgment agents deny the four direct editor tools and request plan mode (Bash remains available), while the 11 domain builders retain editor tools
- `bundle/dot-claude/quality-pack/scripts/` — 16 lifecycle hooks. Per-hook detail in `docs/architecture.md`.
- `bundle/dot-claude/skills/` — 36 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` — 51 autowork hooks + helpers; shared lib `common.sh`; eager `lib/{state-io,verification}.sh`, lazy common-loaders `lib/{classifier,timing,quality-contract}.sh`, and directly consumed `lib/{canary,quality-constitution-authority,plan-publication-transaction}.sh`. Per-script detail in `docs/architecture.md`.
- `bundle/dot-claude/output-styles/` — bundled output styles (`oh-my-claude.md` default, `executive-brief.md`); selected via `output_style=` in `oh-my-claude.conf`
- `bundle/dot-claude/quality-pack/design-craft/` — on-demand design-craft references (`art-taste-doctrine.md`, `a11y-doctrine.md`, `design-for-hackers.md`, `taste-skill-doctrine.md`); loaded by 6 design-side surfaces (5 visual-craft 8-principle, 1 UX-trimmed 3-principle), NOT in the global @-include chain. Lockstep contract in Coordination Rules.
- `bundle/dot-claude/quality-pack/research-craft/` — on-demand research-craft references (`scientific-rigor.md`, `citation-integrity.md`, `figure-craft.md`); loaded by the research-side surfaces (`research-data-analyst`, `literature-scout`, `rigor-reviewer`, `draft-writer`, `editor-critic` + the `data-analysis`/`lit-review`/`manuscript` skills), NOT in the global @-include chain. Lockstep contract in Coordination Rules.
- `config/settings.patch.json` — settings merged into user config on install
- `evals/realwork/` — outcome-oriented ULW scenarios and scorer for minimal-prompt real-work shipping
- `tests/` — 7 essential Bash suites. `tests/README.md` is the ownership manifest.
- `tools/` — developer-only tools (release/distribution verification + deployment audit + manifest-driven staging/candidate helpers + compact readiness checks, including retained intent/gate/realwork and install/uninstall views, the composite maintainer release-candidate audit, coherent pre-push deployment candidate prep, and split local-candidate vs remote-deployment release audit, plus machine-readable modes, telemetry replay, classifier fixtures, defect-cluster review, and consumer-contract lint); not installed
- `docs/` — architecture, customization, FAQ, glossary, prompts, showcase

## Key Files

- `VERSION` — canonical version source of truth (single line)
- `install.sh` — merge-safe installer (supports `--bypass-permissions`, `--no-ios`, `--model-tier`)
- `install-remote.sh` — curl-pipe-bash bootstrapper that clones to `~/.local/share/oh-my-claude` then runs `install.sh`
- `uninstall.sh` — clean removal of installed harness
- `verify.sh` — post-install integrity checker (paths, JSON, hooks, syntax)
- `bundle/dot-claude/switch-tier.sh` — convenience script to switch model tier post-install
- `bundle/dot-claude/statusline.py` — custom Claude Code statusline widget

## Testing

```bash
# Syntax + lint (CI parity — shellcheck warnings ARE fatal)
find bundle/ -name '*.sh' -print0 | xargs -0 shellcheck -x --severity=warning
find . -name '*.json' -not -path './.git/*' -print0 | xargs -0 -n1 python3 -m json.tool --no-ensure-ascii > /dev/null

# Complete essential Bash portfolio (normally around two minutes)
bash tools/run-tests.sh

# Python statusline syntax (no dedicated suite)
python3 -c 'import pathlib; p=pathlib.Path("bundle/dot-claude/statusline.py"); compile(p.read_bytes(), str(p), "exec")'

# Installation verification
bash verify.sh
```

Tests are maintained evidence, not an append-only archive. Extend a retained
owner before adding a file. The default portfolio must remain under ten minutes;
interactive test work is capped at 20 minutes or 30% of task effort unless the
user explicitly authorizes more. See `tests/README.md` and `AGENTS.md`
"Verification economics."

## Coding Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`. Multi-step state updates subject to concurrent SubagentStop hooks must go through `with_state_lock` (or `with_state_lock_batch` for multi-key atomic writes).
- Sidecar artifacts live alongside `session_state.json` and bypass the lock where append-only/per-tool lifecycle semantics require it: `rate_limit_status.json`, `resume_request.json`, bounded/redacted `provisional_closeouts.jsonl`, bounded/redacted `verification_receipts.jsonl`, generation-scoped atomic non-content `.closeout-material-generations/*.nonce` files, and transient `.bash-mutation-baselines/*.json` / `.bash-edit-outcomes/*.json` pairs consumed across Pre/PostTool events. Detail in `docs/architecture.md` "State Management".
- Cross-session data lives in `~/.claude/quality-pack/` as JSON files with their own lock mechanisms. Never store cross-session data inside session directories.
- Cross-session project identity: use `_omc_project_key` (git-remote-first, cwd-hash fallback) for "same upstream project?" semantics — survives worktrees and clones at different paths. Use `_omc_project_id` (cwd-only) only when cwd-divergence IS the signal you want.
- Per-project configuration: `load_conf()` reads `$HOME/.claude/oh-my-claude.conf` (user-level), then walks up from `$PWD` for `.claude/oh-my-claude.conf` (project overrides). Env vars take precedence over both. Every flag's behavior + default + env var lives in `docs/customization.md` and `bundle/dot-claude/oh-my-claude.conf.example` — keep them in lockstep (see Coordination Rules).
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.

## Critical Gotchas

- **Stop orchestration and output schema.** Claude Code runs all matching handlers for one event in parallel, so managed Stop behavior MUST remain behind the single `stop-dispatch.sh` settings entry; array order is not sequencing. The dispatcher owns stdout and normally calls guard → timing → canary → archive deterministically. A structural waiting claim is first-class only when the same Stop payload's `background_tasks` (or compatible `session_crons`) registry proves the awaited task live: named OMC work needs current pending/objective/enforcement correlation plus exact runtime ID when supplied; generic waits need textual correlation. Present-empty recovers immediately, while omitted/malformed remains unknown/legacy. Verified waits run no gate, prompt-end accounting, finalizer, provisional closeout, or continuation counter. Background Agent completion arrives through synthetic `<task-notification>`, not a second Agent PostTool event: the prompt router preserves the user contract, consumes global same-native FIFO before interval validation, caps no-outcome resume attempts, tombstones terminal/foreign ended rows, and stores the newest 128 platform-event receipts so duplicate wakes cannot steal newer outcomes. A missing `tool-use-id` uses best-effort full-body dedupe. Current Claude Code accepts `hookSpecificOutput.additionalContext` from Stop/SubagentStop as non-error continuation feedback, while older clients dropped it: `stop-dispatch.sh` version-gates the Stop path and falls back to `decision: "block"` + `reason`. Keep user-visible receipts/cards on top-level `systemMessage`. `PostToolBatch` preflight must inject context only (never stop the loop), and `MessageDisplay` transformations must stay display-only. Retained coverage owners are `tests/test-session-resume.sh`, `tests/test-quality-gates.sh`, and `tests/test-common-utilities.sh`; extend the nearest owner only for a consequential behavior change.

- **Reviewer cleanup journal.** Cleanup-only ignored outcomes are write-ahead roll-forward records, not accepted evidence and not rollback artifacts. Commit the versioned outcome with exact pending/start fingerprints plus the immutable harness `lifecycle_dispatch_id` before removing either row; after that commit, never delete/restore or age-prune the unresolved outcome on a downstream failure. Foreground/background consumers and replay/admission must reconcile that exact identity before consuming the outcome, resuming, or offering/admitting a replacement. Accepted summary-first reviewer/planner outcomes stay outside this protocol so the second role hook can settle their effects-complete claim/start pair.

- **Lazy-loaded libs (v1.27.0+).** `lib/classifier.sh` and `lib/timing.sh` are sourced via `_omc_load_classifier` / `_omc_load_timing` (idempotent loaders). Hot-path hooks that do not need a lib `export OMC_LAZY_CLASSIFIER=1` / `OMC_LAZY_TIMING=1` BEFORE sourcing `common.sh` to skip the eager parse cost.
  - **Rule when adding a new function in `common.sh` that calls a classifier or timing function**: call `_omc_load_classifier` (or `_omc_load_timing`) at the top of the new function. Otherwise opted-out hooks that transitively reach it crash with `command not found`.
  - Classifier functions to watch for: `is_imperative_request`, `classify_task_intent`, `infer_domain`, `is_completeness_request`, `is_exemplifying_request`, `is_council_evaluation_request`, `is_execution_intent_value`, `is_ui_request`, `is_exhaustive_authorization_request`. Timing-lib functions: any `timing_*`.
  - Currently guarded helpers: `is_session_management_request`, `is_checkpoint_request`, `derive_verification_contract_required` (v1.40.x SRE-1).

## Coordination Rules — keep in lockstep

When making any of these changes, update ALL listed sites in the same commit. Missing one is a silent failure. Ordered by historical violation frequency (most-violated first).

- **Adding/removing/renaming a flag in `oh-my-claude.conf`** → all THREE definition sites:
  1. `bundle/dot-claude/skills/autowork/scripts/common.sh` — `_parse_conf_file()` case statement (the parser)
  2. `bundle/dot-claude/oh-my-claude.conf.example` — documented entry with default + env var + purpose
  3. `bundle/dot-claude/skills/autowork/scripts/omc-config.sh` — `emit_known_flags()` table row (the `/omc-config` skill backend)

  Missing any one is a silent failure: in parser but not example → undiscoverable; in example but not parser → silently ignored; missing from `omc-config.sh` → not settable via the skill UX. Flags read by `statusline.py` (e.g., `installation_drift_check`) parse via Python — skip (1) but still need (2) and (3).

  **Plus a required evaluation (v1.47, security):** the project-conf deny-list in `_parse_conf_file` is fail-open by construction — every new flag is settable from a repo's `.claude/oh-my-claude.conf` unless explicitly listed. For each new flag ask: *can a hostile repo flipping this disable an enforcement/safety surface, choose model cost/strength, arm background fan-out, broaden proof admission, cause unexpected data persistence, delete cross-project data, split hook/daemon views of shared artifacts, or control a user-global settings/scheduler/executable authority when the user merely `cd`s in?* If yes → add it to the deny-list case arm, extend `tests/test-quality-gates.sh`, and update `docs/customization.md` "Project-conf security restriction". If no → no edit, but the evaluation is part of the checklist. Current members: `pretool_intent_guard`, `bg_spawn_gate`, `agent_first_gate`, `no_defer_mode`, `quality_policy`, `definition_of_excellent`, `quality_constitution`, `taste_learning`, `quality_constitution_max_context_chars`, `model_tier`, `model_overrides`, `council_deep_default`, `workflow_substrate`, `repo_lessons`, `auto_tune`, `output_style`, `resume_watchdog`, `resume_watchdog_cooldown_secs`, `resume_session_ttl_secs`, `resume_request_ttl_days`, `resume_scan_max_sessions`, `claude_bin`, `state_ttl_days`, `time_tracking_xs_retain_days`, `custom_verify_mcp_tools`, `custom_verify_patterns`.
- **Adding or removing a skill directory or agent file** → `verify.sh` (`required_paths`) AND `uninstall.sh` (`SKILL_DIRS` / `AGENT_FILES`). These two lists must stay parallel — otherwise uninstall leaks files or verify silently passes a broken install.
- **Adding or removing a memory file in `bundle/dot-claude/quality-pack/memory/`** → keep the file, `bundle/dot-claude/CLAUDE.md` @-include list, and `verify.sh` `required_paths` in lockstep. Memory files are load-bearing doctrine surfaces; removing one requires the same anti-pattern audit as softening the no-defer or depth contracts.
- **Adding or removing a design-craft reference in `bundle/dot-claude/quality-pack/design-craft/`** → keep the file, `verify.sh` `required_paths`, and the canonical inline references in consuming agents/skills in lockstep. These references remain on-demand rather than globally included.
- **Adding or removing a research-craft reference in `bundle/dot-claude/quality-pack/research-craft/`** → keep the file, `verify.sh` `required_paths`, and canonical inline references in consuming agents/skills in lockstep. These references remain on-demand rather than globally included.
- **Adding or removing a user-invocable skill** → `README.md` (skill table), `bundle/dot-claude/skills/skills/SKILL.md` (user-facing index), `bundle/dot-claude/quality-pack/memory/skills.md` (in-session memory). Missing causes either a discoverability gap (user can't find the skill) or a memory gap (Claude doesn't know to suggest it).
- **Adding/removing/renaming agents, skills, scripts, or directories** → `README.md`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`. Counts and directory listings drift fast — keep them accurate.
- **Adding or removing files under `tools/`** → keep the `AGENTS.md` inventory in lockstep. If the tool participates in release/distribution automation, also update `tools/list-release-automation-surfaces.sh`.
- **Cutting a release tag or editing release history** → `CHANGELOG.md` headings and semver git tags must stay 1:1; audit this directly from a tag-aware clone.
- **Adding a new state key** → `docs/architecture.md` "State keys in `session_state.json`" table.
- **Changing `/ulw` workflow behavior** (routing, directives, gates, reviewer sequence, auto-dispatch, status/report surfaces) → document four things in the same change: the user failure mode being fixed, the effect on automation/babysitting, the latency/token cost, and the verification proving the tradeoff is worth it. Internal elegance alone does not count as a ULW improvement.
- **Adding telemetry, counters, or report slices** → ship the full closure in one commit: write path, read path, user-visible surface (`/ulw-report`, `/ulw-status`, `/ulw-time`, statusline, install summary, or equivalent), regression test, and if history matters, a compatibility/backfill rule. Partial telemetry ships are treated as incomplete.
- **Growing stable model context** → inspect the combined always-loaded memory chain, default output style, and orchestration shell directly. Move examples/catalog detail to on-demand skills/docs; a ceiling increase needs receipt-backed quality justification.
- **Adding a new reviewer-style agent** → follow `CONTRIBUTING.md` "Reviewer-agent additions" and extend `tests/test-quality-gates.sh` only when gate behavior changes.
- **Adding a new finding-emitting agent** → update its contract instruction, `discovered_scope_capture_targets` when applicable, and `AGENTS.md`; extend `tests/test-quality-gates.sh` only when admission behavior changes.
- **Adding or relaxing a stop-guard bypass defense** → update the nearest retained owner (`tests/test-quality-gates.sh` or `tests/test-common-utilities.sh`) with one focused assertion for the consequential decision. Do not recreate per-surface and umbrella duplicates.
- **Updating the advisory-specialist list for finding capture** → `discovered_scope_capture_targets` in `common.sh` AND `_is_advisory_specialist` in `record-pending-agent.sh` must stay parallel. The first feeds `record-subagent-summary.sh`'s discovered-scope extraction; the second feeds the v1.42.x advisory-no-findings stop-guard gate (counts only the listed types). Missing either → either silent capture skip OR counter mismatch.

## Release Process

Full checklist (pre-flight CHANGELOG + CI parity, bump + tag, post-flight CI verification) lives in `CONTRIBUTING.md` "Release Process". Two non-negotiables:

- shellcheck `--severity=warning` warnings ARE CI-fatal — clear them locally before tagging
- Post-flight `gh run watch --exit-status` pinned to the tag SHA must return `success` before declaring shipped
