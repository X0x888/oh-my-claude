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

- `bundle/dot-claude/agents/` — 34 specialist agent definitions; the 24 advisory/review agents carry `disallowedTools` permission boundaries, the 10 domain builders can edit
- `bundle/dot-claude/quality-pack/scripts/` — 16 lifecycle hooks. Per-hook detail in `docs/architecture.md`.
- `bundle/dot-claude/skills/` — 31 skill definitions, each in `<name>/SKILL.md`
- `bundle/dot-claude/skills/autowork/scripts/` — 42 autowork hooks + helpers; shared lib `common.sh`; lazy-loaded `lib/{state-io,classifier,verification,timing,canary}.sh`. Per-script detail in `docs/architecture.md`.
- `bundle/dot-claude/output-styles/` — bundled output styles (`oh-my-claude.md` default, `executive-brief.md`); selected via `output_style=` in `oh-my-claude.conf`
- `bundle/dot-claude/quality-pack/design-craft/` — on-demand design-craft references (`art-taste-doctrine.md`, `a11y-doctrine.md`, `design-for-hackers.md`, `taste-skill-doctrine.md`); loaded by 6 design-side surfaces (5 visual-craft 8-principle, 1 UX-trimmed 3-principle), NOT in the global @-include chain. Lockstep contract in Coordination Rules.
- `config/settings.patch.json` — settings merged into user config on install
- `evals/realwork/` — outcome-oriented ULW scenarios and scorer for minimal-prompt real-work shipping
- `tests/` — bash + python test scripts. Authoritative counts: `find tests/ -maxdepth 1 -name 'test-*.sh' | wc -l` (bash) and `find tests/ -maxdepth 1 -name 'test_*.py' | wc -l` (python). All bash tests CI-pinned in `validate.yml`; pin discipline enforced by `tests/test-coordination-rules.sh`.
- `tools/` — developer-only tools (release/distribution verification + deployment audit + manifest-driven staging/candidate helpers + top-level readiness checks, including `tools/verify-professional-readiness.sh` for the cross-domain product-readiness audit, `tools/verify-install-readiness.sh` for first-run install/onboarding proof, `tools/verify-project-readiness.sh` for the one-shot maintainer release-candidate audit, `tools/prepare-release-automation-deployment.sh` for coherent pre-push deployment candidate prep, and `tools/verify-distribution-readiness.sh` for the split local-candidate vs remote-deployment release audit, plus the canonical release-automation surface manifest and `--json` machine-readable audit modes, telemetry replay, classifier fixtures, defect-cluster review, consumer-contract lint); not installed
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
`bash tools/list-ci-pinned-tests.sh .github/workflows/validate.yml`

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
  - Currently guarded helpers: `is_session_management_request`, `is_checkpoint_request`, `derive_verification_contract_required` (v1.40.x SRE-1).

## Coordination Rules — keep in lockstep

When making any of these changes, update ALL listed sites in the same commit. Missing one is a silent failure. Ordered by historical violation frequency (most-violated first).

- **Adding/removing/renaming a flag in `oh-my-claude.conf`** → all THREE definition sites:
  1. `bundle/dot-claude/skills/autowork/scripts/common.sh` — `_parse_conf_file()` case statement (the parser)
  2. `bundle/dot-claude/oh-my-claude.conf.example` — documented entry with default + env var + purpose
  3. `bundle/dot-claude/skills/autowork/scripts/omc-config.sh` — `emit_known_flags()` table row (the `/omc-config` skill backend)

  Missing any one is a silent failure: in parser but not example → undiscoverable; in example but not parser → silently ignored; missing from `omc-config.sh` → not settable via the skill UX. Flags read by `statusline.py` (e.g., `installation_drift_check`) parse via Python — skip (1) but still need (2) and (3).

  **Plus a required evaluation (v1.47, security):** the project-conf deny-list in `_parse_conf_file` is fail-open by construction — every new flag is settable from a repo's `.claude/oh-my-claude.conf` unless explicitly listed. For each new flag ask: *can a hostile repo flipping this disable an enforcement/safety surface or cause unexpected data persistence when the user merely `cd`s in?* If yes → add to the deny-list case arm + `tests/test-stop-guard-bypass-surface.sh` F-013 (membership pin + behavioral assertion) + `docs/customization.md` "Project-conf security restriction". If no → no edit, but the evaluation is part of the checklist. Current members: `pretool_intent_guard`, `bg_spawn_gate`, `agent_first_gate`, `no_defer_mode`, `quality_policy`, `repo_lessons`, `auto_tune`.
- **Adding or removing a skill directory or agent file** → `verify.sh` (`required_paths`) AND `uninstall.sh` (`SKILL_DIRS` / `AGENT_FILES`). These two lists must stay parallel — otherwise uninstall leaks files or verify silently passes a broken install.
- **Adding or removing a memory file in `bundle/dot-claude/quality-pack/memory/`** → 4 sites: (1) the file itself, (2) `bundle/dot-claude/CLAUDE.md` @-include list (loads it on every session), (3) `verify.sh` `required_paths` (catches broken installs), (4) `tests/test-coordination-rules.sh` Contract 6 — memory-file lockstep. Missing any one is a silent failure: file without @-include → never loaded; @-include without file → broken `@`-import on session start; required_paths missing → install verification silently passes a broken install. Memory files are load-bearing doctrine surfaces — once added, removing them requires the same anti-pattern audit as softening the no-defer or depth contracts (see `core.md` "FORBIDDEN — softening the contract").
- **Adding or removing a design-craft reference in `bundle/dot-claude/quality-pack/design-craft/`** → 4 sites: (1) the file itself, (2) `verify.sh` `required_paths`, (3) at least one inline reference (with the canonical `~/.claude/quality-pack/design-craft/<file>.md` path) + Art-Taste Calibration section in each of 6 consuming surfaces (5 agents + 1 skill) — 5 visual-craft consumers (`visual-craft-lens`, `design-reviewer`, `frontend-developer`, `ios-ui-developer`, and the `frontend-design` SKILL) and 1 UX-trimmed consumer (`design-lens`, with a scope-bounded 3-principle variant — Cartier-Bresson, Fukasawa, §8 committee-vs-person — that deliberately excludes visual-craft principles to honor the design-lens/visual-craft-lens scope boundary), (4) `tests/test-art-taste-doctrine.sh` regression net (or sibling test if a new file). NOT in the global `@`-include chain — these references are on-demand reads scoped to design surfaces (avoids loading ~4000 words on every non-UI session). Missing any site is a silent failure: file without verify path → broken install passes silently; surface missing the inline reference → the agent reverts to generic-vocabulary critique; no regression test → all of the above can drift across releases without anyone noticing.
- **Adding or removing a user-invocable skill** → `README.md` (skill table), `bundle/dot-claude/skills/skills/SKILL.md` (user-facing index), `bundle/dot-claude/quality-pack/memory/skills.md` (in-session memory). Missing causes either a discoverability gap (user can't find the skill) or a memory gap (Claude doesn't know to suggest it).
- **Adding/removing/renaming agents, skills, scripts, or directories** → `README.md`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`. Counts and directory listings drift fast — keep them accurate.
- **Adding or removing files under `tools/`** → `AGENTS.md` `tools/` inventory AND `tests/test-coordination-rules.sh` Contract 7 must stay in lockstep with the live `tools/` tree (including nested fixture files such as `classifier-fixtures/*.jsonl`). If the tool participates in release/distribution automation, also update `tools/list-release-automation-surfaces.sh` and the release/doc regression net.
- **Cutting a release tag or editing release history** → `CHANGELOG.md` headings and semver git tags must stay 1:1. `tests/test-coordination-rules.sh` contract C5 enforces tag-to-heading parity; use a tag-aware clone when running it locally.
- **Adding a new state key** → `docs/architecture.md` "State keys in `session_state.json`" table.
- **Changing `/ulw` workflow behavior** (routing, directives, gates, reviewer sequence, auto-dispatch, status/report surfaces) → document four things in the same change: the user failure mode being fixed, the effect on automation/babysitting, the latency/token cost, and the verification proving the tradeoff is worth it. Internal elegance alone does not count as a ULW improvement.
- **Adding telemetry, counters, or report slices** → ship the full closure in one commit: write path, read path, user-visible surface (`/ulw-report`, `/ulw-status`, `/ulw-time`, statusline, install summary, or equivalent), regression test, and if history matters, a compatibility/backfill rule. Partial telemetry ships are treated as incomplete.
- **Adding a new reviewer-style agent** → "Procedural wiring" 6-step checklist in `CONTRIBUTING.md` "Reviewer-agent additions" (settings-patch wiring, VERDICT contract line, dimension mapping table in `AGENTS.md`, matcher-name + count assertions in `tests/test-settings-merge.sh`, simulator + sequence test in `tests/test-e2e-hook-sequence.sh`).
- **Adding a new finding-emitting agent** → "FINDINGS_JSON contract" 4-step checklist in `CONTRIBUTING.md` "Reviewer-agent additions": agent `.md` instruction line, `tests/test-findings-json.sh` regression net, `discovered_scope_capture_targets` in `common.sh` (if findings should feed the discovered-scope gate), `AGENTS.md` documentation row.
- **Adding or relaxing a stop-guard bypass defense** (v1.42.x stop-guard bypass closure work) → MUST update both the umbrella regression net `tests/test-stop-guard-bypass-surface.sh` AND the per-surface test (`test-mark-deferred.sh`, `test-ulw-pause.sh`, `test-common-utilities.sh`, etc.). Missing the umbrella update is a silent failure: per-surface tests can drift while the umbrella still passes only because it asserts narrower invariants. The umbrella file is the cross-cutting regression net; it must catch every defense that the per-surface tests cover. Defenses currently wired include: F-001 handoff regex synonyms + permission-coded continuation asks, F-003 ulw-pause judgment validator, F-005 ulw-correct mid-turn downgrade refusal, F-008 advisory-no-findings gate, F-010 rejected-finding subjective-token tightening, F-010b final-closure closing-region scan, F-011 ulw-skip post-edit refusal, F-012 agent-first-gate opt-in Stop backstop, F-013 project-conf security-flag deny-list. The umbrella test `tests/test-stop-guard-bypass-surface.sh` is the authoritative current list (it also covers F-002 and F-051). Adding a new bypass defense requires a new section in the umbrella; relaxing an existing defense requires the umbrella tests to be updated explicitly (the test file's job is to ensure relaxations are conscious, not silent).
- **Updating the advisory-specialist list for finding capture** → `discovered_scope_capture_targets` in `common.sh` AND `_is_advisory_specialist` in `record-pending-agent.sh` must stay parallel. The first feeds `record-subagent-summary.sh`'s discovered-scope extraction; the second feeds the v1.42.x advisory-no-findings stop-guard gate (counts only the listed types). Missing either → either silent capture skip OR counter mismatch.

## Release Process

Full checklist (pre-flight CHANGELOG + CI parity, bump + tag, post-flight CI verification) lives in `CONTRIBUTING.md` "Release Process". Two non-negotiables:

- shellcheck `--severity=warning` warnings ARE CI-fatal — clear them locally before tagging
- Post-flight `gh run watch --exit-status` pinned to the tag SHA must return `success` before declaring shipped
