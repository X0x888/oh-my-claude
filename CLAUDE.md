# oh-my-claude

Cognitive quality harness for Claude Code — bash hooks, specialist agents, and skills that enforce thinking, testing, and review. Pure bash, zero npm dependencies. Installs as a merge-safe overlay into `~/.claude/`.

## Where deeper detail lives

This file is intentionally short. For implementation-level depth, read the source-of-truth doc:

| Topic | Source of truth |
|---|---|
| Components, state-key dictionary, request flow, intent classification, FINDINGS_JSON parser, Wave 3 watchdog, timing-row shapes | `docs/architecture.md` |
| Conf flags — defaults, env vars, behavior (full table) | `docs/customization.md` |
| Reviewer VERDICT contract, universal verdict tokens, FINDINGS_JSON schema, dimension mapping, discovered-scope capture targets | `AGENTS.md` |
| Release process (full pre-flight, bump, post-flight CI verification), code standards, adding new components | `CONTRIBUTING.md` |
| Conf-flag examples with inline defaults | `bundle/dot-claude/oh-my-claude.conf.example` |

If a fact appears here AND in one of the above, that doc is authoritative — keep this file's version a brief pointer, not a duplicated explanation.

## Key Directories

- `bundle/dot-claude/agents/` — 34 specialist agent definitions with `disallowedTools` permission boundaries (v1.32.1 added `release-reviewer`)
- `bundle/dot-claude/quality-pack/scripts/` — 9 lifecycle hooks (prompt routing, compaction, session start, StopFailure capture, resume hint, headless watchdog)
- `bundle/dot-claude/skills/` — 25 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` — 32 autowork hooks + helpers; shared lib `common.sh`; lazy-loaded `lib/{state-io,classifier,verification,timing,canary}.sh`. Per-script detail in `docs/architecture.md`.
- `bundle/dot-claude/output-styles/` — bundled output styles (`oh-my-claude.md` default, `executive-brief.md`); selected via `output_style=` in `oh-my-claude.conf`
- `config/settings.patch.json` — settings merged into user config on install
- `tests/` — bash + python test scripts. Authoritative counts: `find tests/ -maxdepth 1 -name 'test-*.sh' | wc -l` (bash) and `find tests/ -maxdepth 1 -name 'test_*.py' | wc -l` (python). All bash tests CI-pinned in `validate.yml`; pin discipline enforced by `tests/test-coordination-rules.sh`. (v1.36.0 #11: replaced the hardcoded "80 bash + 1 python" enumeration with the grep-from-source pattern used in CONTRIBUTING.md to eliminate the recurring drift surface.)
- `tools/` — developer-only tools (telemetry replay, classifier fixtures, defect-cluster review, consumer-contract lint); not installed
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

# Full bash + python suite
for f in tests/test-*.sh; do bash "$f" || break; done
python3 -m unittest tests.test_statusline -v

# Installation verification
bash verify.sh
```

The CI-pinned test list lives in `.github/workflows/validate.yml`; extract with:
`grep -E '^\s+run:\s+bash tests/test-' .github/workflows/validate.yml | awk '{print $NF}'`

## Coding Rules

- Never hardcode user paths. Use `$HOME` or relative paths.
- All bash scripts must use `set -euo pipefail`.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.
- State is JSON in `session_state.json`, accessed via `read_state` / `write_state`. Multi-step state updates subject to concurrent SubagentStop hooks must go through `with_state_lock` (or `with_state_lock_batch` for multi-key atomic writes).
- Sidecar JSON artifacts live alongside `session_state.json` and bypass the lock for cross-process safety: `rate_limit_status.json` (written by `statusline.py` from Claude Code's statusLine `rate_limits`) and `resume_request.json` (written by `stop-failure-handler.sh` on `StopFailure`). Detail in `docs/architecture.md` "State Management".
- Cross-session data lives in `~/.claude/quality-pack/` as JSON files with their own lock mechanisms. Never store cross-session data inside session directories.
- Cross-session project identity: use `_omc_project_key` (git-remote-first, cwd-hash fallback) for "same upstream project?" semantics — survives worktrees and clones at different paths. Use `_omc_project_id` (cwd-only) only when cwd-divergence IS the signal you want.
- Per-project configuration: `load_conf()` reads `$HOME/.claude/oh-my-claude.conf` (user-level), then walks up from `$PWD` for `.claude/oh-my-claude.conf` (project overrides). Env vars take precedence over both. Every flag's behavior + default + env var lives in `docs/customization.md` and `bundle/dot-claude/oh-my-claude.conf.example` — keep them in lockstep (see Coordination Rules).
- Prefer readable code over micro-optimizations. When quality and speed conflict, choose quality.
- Do not break existing install paths, config merges, or hook interfaces for performance gains.

## Critical Gotchas

- **Stop hook output schema.** Stop and SubagentStop hooks **cannot** emit `hookSpecificOutput.additionalContext` — Claude Code silently drops the field. Use top-level `systemMessage` (visible) or `decision: "block"` with `reason` (block path). Tests must assert both positive (`systemMessage` present) AND negative (`hookSpecificOutput` absent). The `additionalContext` field IS supported on: SessionStart, Setup, SubagentStart, UserPromptSubmit, UserPromptExpansion, PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch. Regression net: `tests/test-timing.sh` T29.

- **Lazy-loaded libs (v1.27.0+).** `lib/classifier.sh` and `lib/timing.sh` are sourced via `_omc_load_classifier` / `_omc_load_timing` (idempotent loaders). Hot-path hooks that do not need a lib `export OMC_LAZY_CLASSIFIER=1` / `OMC_LAZY_TIMING=1` BEFORE sourcing `common.sh` to skip the eager parse cost.
  - **Rule when adding a new function in `common.sh` that calls a classifier or timing function**: call `_omc_load_classifier` (or `_omc_load_timing`) at the top of the new function. Otherwise opted-out hooks that transitively reach it crash with `command not found`.
  - Classifier functions to watch for: `is_imperative_request`, `classify_task_intent`, `infer_domain`, `is_completeness_request`, `is_exemplifying_request`, `is_council_evaluation_request`, `is_execution_intent_value`, `is_ui_request`, `is_exhaustive_authorization_request`. Timing-lib functions: any `timing_*`.
  - Currently guarded helpers: `is_session_management_request`, `is_checkpoint_request`.

## Coordination Rules — keep in lockstep

When making any of these changes, update ALL listed sites in the same commit. Missing one is a silent failure. Ordered by historical violation frequency (most-violated first).

- **Adding/removing/renaming a flag in `oh-my-claude.conf`** → all THREE definition sites:
  1. `bundle/dot-claude/skills/autowork/scripts/common.sh` — `_parse_conf_file()` case statement (the parser)
  2. `bundle/dot-claude/oh-my-claude.conf.example` — documented entry with default + env var + purpose
  3. `bundle/dot-claude/skills/autowork/scripts/omc-config.sh` — `emit_known_flags()` table row (the `/omc-config` skill backend)

  Missing any one is a silent failure: in parser but not example → undiscoverable; in example but not parser → silently ignored; missing from `omc-config.sh` → not settable via the skill UX. Flags read by `statusline.py` (e.g., `installation_drift_check`) parse via Python — skip (1) but still need (2) and (3).
- **Adding or removing a skill directory or agent file** → `verify.sh` (`required_paths`) AND `uninstall.sh` (`SKILL_DIRS` / `AGENT_FILES`). These two lists must stay parallel — otherwise uninstall leaks files or verify silently passes a broken install.
- **Adding or removing a user-invocable skill** → `README.md` (skill table), `bundle/dot-claude/skills/skills/SKILL.md` (user-facing index), `bundle/dot-claude/quality-pack/memory/skills.md` (in-session memory). Missing causes either a discoverability gap (user can't find the skill) or a memory gap (Claude doesn't know to suggest it).
- **Adding/removing/renaming agents, skills, scripts, or directories** → `README.md`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`. Counts and directory listings drift fast — keep them accurate.
- **Cutting a release tag or editing release history** → `CHANGELOG.md` headings and semver git tags must stay 1:1. `tests/test-coordination-rules.sh` contract C5 enforces tag-to-heading parity; use a tag-aware clone when running it locally.
- **Adding a new state key** → `docs/architecture.md` "State keys in `session_state.json`" table.
- **Changing `/ulw` workflow behavior** (routing, directives, gates, reviewer sequence, auto-dispatch, status/report surfaces) → document four things in the same change: the user failure mode being fixed, the effect on automation/babysitting, the latency/token cost, and the verification proving the tradeoff is worth it. Internal elegance alone does not count as a ULW improvement.
- **Adding telemetry, counters, or report slices** → ship the full closure in one commit: write path, read path, user-visible surface (`/ulw-report`, `/ulw-status`, `/ulw-time`, statusline, install summary, or equivalent), regression test, and if history matters, a compatibility/backfill rule. Partial telemetry ships are treated as incomplete.
- **Adding a new reviewer-style agent** → "Procedural wiring" 6-step checklist in `CONTRIBUTING.md` "Reviewer-agent additions" (settings-patch wiring, VERDICT contract line, dimension mapping table in `AGENTS.md`, matcher-name + count assertions in `tests/test-settings-merge.sh`, simulator + sequence test in `tests/test-e2e-hook-sequence.sh`).
- **Adding a new finding-emitting agent** → "FINDINGS_JSON contract" 4-step checklist in `CONTRIBUTING.md` "Reviewer-agent additions": agent `.md` instruction line, `tests/test-findings-json.sh` regression net, `discovered_scope_capture_targets` in `common.sh` (if findings should feed the discovered-scope gate), `AGENTS.md` documentation row.

## Release Process

Full checklist (pre-flight CHANGELOG + CI parity, bump + tag, post-flight CI verification) lives in `CONTRIBUTING.md` "Release Process". Two non-negotiables:

- shellcheck `--severity=warning` warnings ARE CI-fatal — clear them locally before tagging
- Post-flight `gh run watch --exit-status` pinned to the tag SHA must return `success` before declaring shipped
