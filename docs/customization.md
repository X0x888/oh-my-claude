# Customization

oh-my-claude is designed to be modified. Every component -- agents, quality gates, domain routing, output style, statusline -- is a plain file you can edit directly. This guide covers what's configurable and how to change it without breaking the harness.

---

## Permission Modes

Claude Code prompts for permission before running bash commands, editing files, and similar operations. oh-my-claude supports three approaches:

**Default (prompted)**: Install without flags. Claude Code asks for confirmation on sensitive operations. The harness hooks still fire, but you'll see permission dialogs during normal use.

```bash
bash install.sh
```

**Bypass mode**: Install with `--bypass-permissions`. This skips Claude Code's built-in permission prompts, letting the harness run without interruption. The quality gates (stop guard, review requirement, verification requirement) still apply. Bypass-permissions affects Claude Code's confirmations, not the harness's enforcement.

```bash
bash install.sh --bypass-permissions
```

**Per-session**: You can toggle permissions at any time using Claude Code's built-in `/permissions` command within a session. This does not affect the harness configuration.

---

## Model Tiers

oh-my-claude assigns each specialist agent a model (`opus` or `sonnet`) in its definition file. The default split uses Opus for complex reasoning agents (planning, review, debugging) and Sonnet for faster execution agents (frontend, backend, research).

You can override this split at install time with the `--model-tier` flag:

```bash
bash install.sh --model-tier=quality    # all agents use Opus
bash install.sh --model-tier=balanced   # default split (Opus for planning/review, Sonnet for execution)
bash install.sh --model-tier=economy    # all agents use Sonnet
```

### Switching tiers after installation

A convenience script is installed at `~/.claude/switch-tier.sh` so you can switch tiers from anywhere without navigating to the repository:

```bash
bash ~/.claude/switch-tier.sh quality    # switch to all-Opus
bash ~/.claude/switch-tier.sh economy    # switch to all-Sonnet
bash ~/.claude/switch-tier.sh            # show current tier
```

For quality and economy tiers, the script updates agent `model:` lines in-place via sed -- no full reinstall, no backup cycle. For the balanced tier, it restores bundle defaults from the saved repo path. The tier choice is persisted to `oh-my-claude.conf`.

| Tier | Opus agents | Sonnet agents | Best for |
|---|---|---|---|
| `quality` | All 23 | 0 | Users with high usage limits who prioritize quality over cost |
| `balanced` | 9 (planning, review, debugging, writing, operations) | 13 (execution, research, domain specialists) | Most users (default) |
| `economy` | 0 | All 23 | Users on tighter plans or budget-conscious API usage |

### How it works

The chosen tier is saved to `~/.claude/oh-my-claude.conf`. On subsequent installs, the tier is automatically re-applied unless you pass a different `--model-tier` flag. The flag always takes precedence over the saved value.

For `balanced`, the bundle defaults are used as-is. For `quality` and `economy`, the installer rewrites the `model:` line in each agent's frontmatter after copying the bundle files.

### Per-agent overrides

If you need finer control than the three presets, edit individual agent files after installation:

```bash
# Change a specific agent to use Opus
tmp=$(mktemp) && sed 's/^model: sonnet$/model: opus/' ~/.claude/agents/librarian.md > "$tmp" && mv "$tmp" ~/.claude/agents/librarian.md
```

Per-agent edits are overwritten on the next install. To preserve them, either re-apply manually after each install, or change the agent definition in your local clone of the repository before installing.

### Thinking effort

Agent-level thinking effort (extended thinking budget) is not currently configurable. The `effortLevel` setting in `settings.json` affects only the main thread. This is a Claude Code platform limitation -- when Claude Code adds agent-level thinking control, the tier system can be extended to support it.

---

## Other install flags

**`--git-hooks`** — writes `.git/hooks/post-merge` into the source checkout so that every `git pull` (or any other merge) checks whether the bundle has drifted from the last install. When drift is detected, the hook prints a yellow `[oh-my-claude] Bundle changes detected after merge.` banner and prints the installer command. The hook is non-blocking — it never aborts the underlying git operation. Set `OMC_AUTO_INSTALL=1` in your environment to have the hook re-run `install.sh` automatically (useful for CI / trusted environments). `install.sh` never overwrites a pre-existing non-oh-my-claude hook at the same path; a foreign hook keeps the slot. `uninstall.sh` removes the hook only if it carries the `# oh-my-claude post-merge auto-sync` signature.

```bash
bash install.sh --git-hooks              # one-time opt-in during install
```

**`--no-ios`** — skip the 4 iOS-specific specialist agents (`ios-core-engineer`, `ios-ui-developer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`) during install. The flag removes any `~/.claude/agents/ios-*.md` files; `frontend-developer` is unaffected even though it covers some web/native overlap. Saves ~15 KB in `~/.claude/agents/` and reduces `/agents` picker noise if you don't ship iOS.

```bash
bash install.sh --no-ios
```

---

## Bug reports with omc-repro

`~/.claude/omc-repro.sh` packages a session's state into a shareable tarball. User-prompt and assistant-message fields (`last_user_prompt`, `last_assistant_message`, `current_objective`, `last_meta_request` in session state; `prompt_preview` in classifier telemetry; `text` in recent_prompts) are truncated to 80 chars before bundling. Override with `OMC_REPRO_REDACT_CHARS`:

```bash
bash ~/.claude/omc-repro.sh                            # bundle the latest session
bash ~/.claude/omc-repro.sh --list                     # list recent sessions
bash ~/.claude/omc-repro.sh <session-id>               # bundle a specific session
OMC_REPRO_REDACT_CHARS=200 bash ~/.claude/omc-repro.sh # keep more context
```

The script never falls back to unredacted copies on jq failure — a corrupt row is dropped rather than leaked. Always review the bundle (`tar -xzf ~/omc-repro-*.tar.gz -C /tmp`) before sharing if you have additional privacy concerns.

---

## User-Override Layer

Files in `~/.claude/omc-user/` are **never overwritten** by `install.sh`. Use this directory for customizations that should survive updates.

The default template is `~/.claude/omc-user/overrides.md`, which is loaded after the bundle defaults via the `@` reference in `CLAUDE.md`. Anything you put here takes effect in every session.

### What to put in overrides.md

- **Custom anti-patterns**: `FORBIDDEN: [your rule]`
- **Relaxed rules**: `Override: when working on prototypes, skip the excellence-reviewer gate`
- **Domain-specific guidance**: `When working on [your project type], always [your preference]`
- **Specialist preferences**: `Prefer oracle over metis for debugging in this codebase`

### What NOT to put here

- Threshold tuning (stall detection, file counts) — use `~/.claude/oh-my-claude.conf` instead
- Model tier changes — use `bash ~/.claude/switch-tier.sh <tier>` instead

### The override is additive

`overrides.md` is loaded **after** the bundle's `core.md`, `skills.md`, and `compact.md`. Your rules supplement the defaults; they don't replace them. To override a specific default rule, explicitly state the override in your file.

---

## Adding Your Own Agents

Agent definitions live in `~/.claude/agents/`. Each agent is a single markdown file with YAML frontmatter.

To add a new agent:

1. Create `~/.claude/agents/<agent-name>.md`.
2. Define the frontmatter:

```yaml
---
name: my-agent
description: When to invoke this agent (shown in agent selection UI).
disallowedTools: Write, Edit, MultiEdit
model: opus
permissionMode: plan
maxTurns: 20
memory: user
---
```

3. Write the agent's system prompt below the frontmatter.

Key settings:

- **`disallowedTools`**: Comma-separated list of tools the agent cannot use. For read-only agents (reviewers, analysts, researchers), set `Write, Edit, MultiEdit` to prevent unsupervised file mutations. The main thread retains exclusive write access.
- **`model`**: Which model the agent uses. Set to `opus` for complex reasoning, `sonnet` for faster/cheaper operations.
- **`maxTurns`**: Maximum number of tool-use turns before the agent must return. Prevents runaway agents.

  **Subagent-side budget, not parent-side.** Every subagent's output is hard-truncated to 1000 characters before it reaches the parent session -- see `skills/autowork/scripts/reflect-after-agent.sh:41`, which calls `truncate_chars 1000 "${message}"` when building the `finding_context` injection. The `maxTurns` cap only governs how many tool calls a subagent can make during its own investigation; a higher cap does *not* expand the amount of subagent output that lands in the parent conversation. In other words, raising `maxTurns` costs subagent compute time and API spend but has **zero parent-context cost**. The 1.1.0 rationale for lowering reviewer caps ("to limit context bloat") did not hold once this boundary was accounted for.

  **Rule of thumb for new agents:** size `maxTurns` to the agent's investigative scope, not to a parent-context budget. Deep investigators (reviewers that read every changed file, debuggers tracing multi-file bugs, researchers surveying a codebase) warrant 25-30+. Quick extractors and single-question helpers can stay at 12-18. When in doubt, err high -- truncated reviews are expensive in rework, and the injection boundary makes a larger subagent budget cheap in context.
- **`permissionMode`**: Set to `plan` for read-only agents so they skip permission prompts for non-destructive operations.

---

## Adding Your Own Skills

Skills live in `~/.claude/skills/<skill-name>/SKILL.md`. Each skill is a markdown file with YAML frontmatter that defines when and how it activates.

To add a new skill:

1. Create the directory: `~/.claude/skills/<skill-name>/`
2. Create `SKILL.md` with frontmatter:

```yaml
---
name: my-skill
description: What this skill does (used for matching).
argument-hint: "[task description]"
---
```

3. Write the skill's instructions below the frontmatter.
4. If the skill needs hook scripts, place them in `~/.claude/skills/<skill-name>/scripts/` and register them in `~/.claude/settings.json` under the appropriate hook event.

The skill is invoked with `/my-skill <arguments>`. The `$ARGUMENTS` placeholder in the skill body is replaced with whatever the user passes.

---

## Tuning Quality Gates

The stop guard (`skills/autowork/scripts/stop-guard.sh`) enforces seven independent gates: advisory inspection, session handoff, review/verification, review coverage (prescribed reviewer sequence), excellence review, opt-in metis-on-plan, and final-closure auditability. The first six guard the work itself; the last one guards the user-facing closeout so the result can be audited without follow-up questions. The block-limited gates cap how many times they can prevent Claude from stopping.

### Adjusting block limits

Edit `stop-guard.sh` and change the comparison values:

- **Advisory inspection gate** (line ~52): `advisory_guard_blocks -lt 1` -- Change `1` to increase or decrease the cap.
- **Session handoff gate** (line ~68): `session_handoff_blocks -lt 2` -- Change `2`.
- **Review/verification gate** (line ~114): `guard_blocks -ge 2` -- Change `2`.

Setting any cap to `0` effectively disables that gate.

### Disabling a specific guard

To disable a guard entirely, add `exit 0` at the beginning of its check block, or remove the corresponding section from the script. For example, to disable the session handoff guard, comment out or remove the `has_unfinished_session_handoff` block (lines ~65-73).

To disable all quality gates, remove the Stop hook entry from `~/.claude/settings.json`:

```json
"Stop": []
```

### Disabling verification for non-code domains

The stop guard already skips the verification check for writing, research, operations, and general domains. It only requires `last_verify_ts` for coding and mixed tasks. To change which domains require verification, edit the `case` statement on lines ~93-102 of `stop-guard.sh`.

### Configurable thresholds

Several configurable thresholds can be tuned via `~/.claude/oh-my-claude.conf` without editing hook scripts:

| Key | Default | What it controls |
|-----|---------|-----------------|
| `stall_threshold` | `12` | Consecutive Read/Grep calls before stall detection fires |
| `excellence_file_count` | `3` | Unique edited files that trigger the excellence review gate |
| `dimension_gate_file_count` | `3` | Unique edited files that trigger the prescribed-sequence dimension gate. Set to a high value (e.g. 100) to effectively disable the dimension gate. |
| `traceability_file_count` | `6` | Unique edited files above which the dimension gate additionally requires `briefing-analyst` for traceability. |
| `state_ttl_days` | `7` | Days before stale session state directories are swept |
| `verify_confidence_threshold` | `40` | Minimum verification confidence (0-100) to pass the quality gate |
| `custom_verify_mcp_tools` | _(empty)_ | Pipe-separated glob patterns for additional MCP tools that count as verification (e.g. `mcp__my_cypress__*`). Also requires a matching PostToolUse hook entry in `settings.json`. |
| `installation_drift_check` | `true` | When `true`, the statusline appends a yellow `↑v<repo>` segment whenever `${repo_path}/VERSION` is newer than the bundled `installed_version` (semver-aware; deliberate downgrades do not trigger). Surfaces the "I pulled but forgot to re-run `install.sh`" case. Requires `repo_path` to be present in the conf — `install.sh` writes it on every install. Local-only check; no network. Set to `false` to suppress the indicator. |
| `pretool_intent_guard` | `true` | When `true`, the PreToolUse `pretool-intent-guard.sh` hook denies destructive git/gh commands (commit, push, revert, reset --hard, rebase, branch -D, gh pr create, etc.) while `task_intent` is `advisory`, `session_management`, or `checkpoint`. Closes the 2026-04-17 regression where an advisory prompt followed by a compact could result in unauthorized commits. Set to `false` to disable enforcement and rely on the directive layer alone (e.g. if the classifier's advisory detection over-fires in your workflow). See `docs/compact-intent-preservation.md`. |
| `wave_override_ttl_seconds` | `1800` | (v1.21.0) Freshness window for the wave-execution exception in `pretool-intent-guard.sh`. **Prerequisite: a council Phase 8 wave plan persisted via `record-finding-list.sh init` (i.e., `<session>/findings.json` exists with a non-empty `waves[]`).** Manual wave-style work without an emitted finding list does NOT trigger the override — `/council` is the structured signal. When a Phase 8 plan is active (any wave is `pending` or `in_progress`) and the plan's `updated_ts` is within this many seconds, the gate allows `git commit` (only) even under advisory/session_management/checkpoint intent — the persisted plan IS the user's standing authorization, and per-wave confirmation is the forbidden "Should I proceed?" anti-pattern. Other destructive ops (push, force-push, reset --hard, rebase, tag, gh pr create, etc.) still require fresh execution intent. Stale wave plans (older than the TTL) do NOT trigger the override, so an abandoned plan does not leak authorization into unrelated later work. Lower to tighten; raise if your wave cycles legitimately exceed 30 minutes. Env: `OMC_WAVE_OVERRIDE_TTL_SECONDS`. |
| `classifier_telemetry` | `on` | When `on`, `prompt-intent-router.sh` writes a per-turn row `{ts, intent, domain, prompt_preview (200 chars), pretool_blocks_observed}` to `<session>/classifier_telemetry.jsonl` and the next prompt's hook may annotate misfire rows when a PreTool block fired under a non-execution classification. Set to `off` to disable all recording — useful for shared machines, regulated codebases, or any workflow where writing user prompt previews to disk is unwanted. With `off`, `/ulw-status --classifier` has nothing to show and the cross-session `classifier_misfires.jsonl` is not populated. |
| `gate_level` | `full` | Enforcement depth for the stop-guard quality gates. `full` (default) enables all gates including review coverage and excellence; `standard` enables quality + excellence gates; `basic` enables only the quality gate. Lower this on prototypes or solo branches where the full sequence is overhead. Env: `OMC_GATE_LEVEL`. |
| `guard_exhaustion_mode` | `scorecard` | Behavior when a gate's block cap is reached. `scorecard` (default) emits a quality scorecard then releases the stop; `block` keeps blocking; `silent` releases without output. Legacy aliases accepted: `warn` → `scorecard`, `strict` → `block`, `release` → `silent`. Env: `OMC_GUARD_EXHAUSTION_MODE`. |
| `discovered_scope` | `on` | When `on`, advisory-specialist findings (council lenses, `metis`, `briefing-analyst`) are captured to `<session>/discovered_scope.jsonl` and the stop-guard blocks until pending rows are addressed under execution intent. Block cap is 2 by default; raised to `N+1` when a Council Phase 8 wave plan with `N` waves is active, so the gate stays useful across legitimate wave-by-wave commits. Set to `off` as a kill switch when heuristic extraction is too noisy on a project's prose style. Env: `OMC_DISCOVERED_SCOPE`. |
| `council_deep_default` | `off` | When `on`, auto-triggered council dispatches (broad project-evaluation prompts under `/ulw` that match `is_council_evaluation_request`) inherit `--deep` behavior — each lens uses `model: opus` instead of the default `sonnet`. Explicit `/council --deep` always escalates regardless of this flag; explicit `/council` (no flag) is unaffected. The router also honors an inline `--deep` token in the prompt text (e.g. `/ulw evaluate the project --deep`) independently of this conf flag. Cost: meaningfully higher per auto-triggered run — leave `off` unless you want every auto-detected council to be opus-grade. Env: `OMC_COUNCIL_DEEP_DEFAULT`. |
| `auto_memory` | `on` | When `on`, the auto-memory wrap-up rule (`memory/auto-memory.md`) and compact-time memory sweep (`memory/compact.md`) write `project_*.md`, `feedback_*.md`, `user_*.md`, and `reference_*.md` files into your `memory/` directory at session-stop and pre-compact moments. Set to `off` for shared machines, regulated codebases, or projects where session memory should not accrue across runs. Explicit user requests ("remember that...", "save this as memory") still apply regardless. Helper: `is_auto_memory_enabled()` in `common.sh`. Env: `OMC_AUTO_MEMORY`. |
| `metis_on_plan_gate` | `off` | (v1.19.0 bias-defense) When `on`, the stop-guard's Check 6 blocks Stop on a complex plan (`plan_complexity_high=1` — set by `record-plan.sh` based on step count, file count, wave count, or risky keywords paired with non-trivial scope) until `metis` has run a stress-test review since the plan was recorded. Independent of `gate_level` — opt-in users get this gate even on `basic`. Block cap: 1 per plan cycle (resets on every fresh plan). The gate inherits `/ulw-skip` semantics from the global skip path. Env: `OMC_METIS_ON_PLAN_GATE`. Off by default because the existing soft `PLAN COMPLEXITY NOTICE` from `record-plan.sh` already advises most users; flip on when you want the harness to enforce, not just suggest. **Fire frequency**: once per high-complexity plan; expect a real friction tax on migration/refactor/schema work and on multi-wave council Phase 8 plans. Trivial plans (≤5 steps, ≤3 files, no waves, no risky keywords) never trip it. |
| `prometheus_suggest` | `off` | (v1.19.0 bias-defense; reframed v1.24.0) When `on`, the prompt-intent-router injects an `AMBIGUOUS PRODUCT-SHAPED PROMPT` directive on fresh execution prompts that look short and product-shaped (build/create/design + app/dashboard/feature/onboarding/etc.) without specific code anchors. **Declare-and-proceed contract**: tells the model to state its scope interpretation (audience, primary success criterion, one or two non-goals) in one or two declarative sentences as part of its opener and proceed — never to pause for confirmation. `/prometheus` is reserved for the credible-approach-split case from `core.md` (two interpretations credibly incompatible AND choosing wrong would cost rework), not a default-on hold. Mutually exclusive with `intent_verify_directive` on the same turn (prometheus suppresses intent-verify to avoid double-framing). Env: `OMC_PROMETHEUS_SUGGEST`. Off by default to avoid false-positive grief on prompts you knew you wanted to drive directly. **Fire frequency**: fires on short product-shaped prompts like "build a dashboard"; will not fire when your prompt names a file, line ref, function call, multi-component path, or backtick-fenced identifier. Continuation/advisory/session-management/checkpoint prompts skip the bias-defense block entirely. |
| `intent_verify_directive` | `off` | (v1.19.0 bias-defense; reframed v1.24.0) When `on`, the prompt-intent-router injects an `INTENT VERIFICATION` directive on fresh execution prompts that are short and unanchored (no file path, line ref, function name, or backtick-fenced identifier). **Declare-and-proceed contract**: tells the model to state its interpretation of the goal in one declarative sentence as part of its opener (e.g., "I'm interpreting this as &lt;X&gt; and proceeding now") and start work — never to pause for confirmation. The user can interrupt and redirect in real time if the call is wrong. Pause case is narrow: only stop when both confidence is low AND the wrong call would be hard to reverse. Lighter than `prometheus_suggest` — one declarative sentence vs two plus non-goals. Suppressed when `prometheus_suggest` already fired on the same turn. Env: `OMC_INTENT_VERIFY_DIRECTIVE`. Off by default; expect frequent firing on short maintenance prompts ("bump version", "run tests", "fix the failing test") when you flip it on — the framing is the point, not friction. |
| `exemplifying_directive` | `on` | (v1.23.0 bias-defense) When `on`, the prompt-intent-router injects an `EXEMPLIFYING SCOPE DETECTED` directive on fresh execution prompts that use example markers (`for instance`, `e.g.`, `such as`, `as needed`, `including but not limited to`, etc.). It tells the model to treat the example as one item from an enumerable class and enumerate sibling items a veteran would bundle into the same pass. Env: `OMC_EXEMPLIFYING_DIRECTIVE`. |
| `exemplifying_scope_gate` | `on` | When `on`, example-marker execution prompts must produce `<session>/exemplifying_scope.json` via `record-scope-checklist.sh init`, then mark every sibling item `shipped` or `declined` with a concrete WHY before Stop. This hardens `exemplifying_directive` so a prompt like "improve the statusline, for instance reset countdown" cannot silently ship only the named example. Block cap: 2 unless `guard_exhaustion_mode=block`. Env: `OMC_EXEMPLIFYING_SCOPE_GATE`. |
| `prompt_text_override` | `on` | (v1.23.0) When `on`, the PreTool intent guard re-reads the latest user prompt and allows a destructive command when every destructive segment is authorized by the prompt text, even if `task_intent` was misclassified. Compound safety still applies: `git commit && git push --force` requires both verbs to be authorized. Env: `OMC_PROMPT_TEXT_OVERRIDE`. |
| `mark_deferred_strict` | `on` | (v1.23.0) When `on`, `/mark-deferred` rejects low-information reasons such as `out of scope`, `not in scope`, `follow-up`, or `later`. Reasons must name a concrete WHY (`requires X`, `blocked by F-001`, `duplicate`, etc.) so deferral cannot become a silent-skip escape hatch. Env: `OMC_MARK_DEFERRED_STRICT`. |
| `time_tracking` | `on` | Per-tool / per-subagent time-distribution capture. Two universal-matcher hooks (`pretool-timing.sh` + `posttool-timing.sh`) append start/end rows to `<session>/timing.jsonl` (lock-free; sub-PIPE_BUF append via O_APPEND). The Stop hook emits the polished `─── Time breakdown ───` card as `systemMessage` (the documented user-visible Stop output field) when the session releases (suppressed during a stop-guard block). Surfaces via `/ulw-time` (current / last / last-prompt / week / month / all), `/ulw-status`, and `/ulw-report`. Set to `off` on shared machines or when residual disk noise (one JSONL per session) is unwanted; the hooks fast-path-out in <1ms when off. Env: `OMC_TIME_TRACKING`. |
| `time_tracking_xs_retain_days` | `30` | Cross-session timing rollup retention horizon. Per-session `timing.jsonl` files inherit `state_ttl_days`; this independent flag governs the global aggregate at `~/.claude/quality-pack/timing.jsonl` because workflow data (which agents/tools you used heaviest) is more privacy-sensitive than gate telemetry. Rows older than the cutoff are dropped on the regular state-TTL sweep. Env: `OMC_TIME_TRACKING_XS_RETAIN_DAYS`. |
| `model_drift_canary` | `on` | (v1.26.0) When `on`, `canary-claim-audit.sh` runs at Stop time as a third entry in the Stop-hook chain (after `stop-guard.sh` and `stop-time-summary.sh`). Parses the model's last assistant message for assertive verification claims with code anchors (`I (verified\|checked\|read\|examined\|inspected\|reviewed\|confirmed\|validated\|ran\|tested\|executed\|opened\|loaded\|grepped\|searched) <code-anchor>`) and compares the count to verification-class tool calls fired in the same `prompt_seq` epoch (Read, Bash, Grep, Glob, WebFetch, NotebookRead — Edit/Write/TaskCreate are mutations and don't count). Per-event verdict in `{clean, covered, low_coverage, unverified}`. `unverified` (≥2 claims, 0 tools) is the strongest silent-confab signal. **Hard dependency**: `time_tracking=on` — when timing is off the canary short-circuits cleanly. Soft in-session alert fires at session-cumulative `unverified` count ≥2. Surfaces in `/ulw-report` "Model-drift canary" section. Informational (never blocks Stop) so an audit error never becomes a failure mode. Env: `OMC_MODEL_DRIFT_CANARY`. |
| `divergence_directive` | `on` | (v1.32.0 bias-defense) When `on`, the prompt-intent-router injects a `DIVERGENT-FRAMING DIRECTIVE` on prompts where `is_paradigm_ambiguous_request` matches — paradigm-shape decisions across signals like X-vs-Y choice, `how should we`, `best/right/optimal way/approach/architecture`, paradigm-decision verb + abstract noun (`design/architect/model the X strategy/pattern/approach/state machine/...`), `is there a better way`, migration/adoption (`migrate from X to Y`, `consider switching/adopting`). Teaches inline lateral thinking: enumerate 2-3 alternative framings (label + mental model + EASY/HARD affordance), pick one with a one-line reason plus a "redirect if" clause, escalate to explicit `/diverge` only when high-stakes AND inline enumeration feels shallow. Excludes bug-fix vocabulary and code-anchored prompts (unless an X-vs-Y signal overrides). Fires on advisory + execution + continuation; skipped only on session_management / checkpoint. Independent of the narrowing (`prometheus_suggest`, `intent_verify_directive`) and surface-widening (`intent_broadening`) directives — paradigm enumeration is a third axis. Env: `OMC_DIVERGENCE_DIRECTIVE`. |
| `directive_budget` | `balanced` | (v1.33.0 router composition) Controls how many SOFT router directives are allowed to stack on one prompt. Modes: `maximum` (widest aperture), `balanced` (default; preserves the high-value ULW soft layers and trims lower-priority prompt tax), `minimal` (aggressive trimming), `off` (legacy/unbounded emission). HARD directives still emit regardless. Suppressions are not silent: emitted directive footprint shows in `/ulw-report` and `/ulw-status`, and suppressed directives surface in `/ulw-report` under "Router directive suppressions". Env: `OMC_DIRECTIVE_BUDGET`. |
| `inferred_contract` | `on` | (v1.34.0 Delivery Contract v2) When `on`, mark-edit and stop-guard infer required adjacent surfaces from the *actual edits* made during the session — not just from explicit prompt wording. Six conservative rules: **R1** ≥2 code files edited but no test edited (suppressed when fresh passing high-confidence verification ran AFTER the last code edit); **R2** `VERSION` bumped without `CHANGELOG.md`/`RELEASE_NOTES.md` touched; **R3a** `oh-my-claude.conf.example` edited without `common.sh` `_parse_conf_file` touched (parser-site lockstep); **R3b** `oh-my-claude.conf.example` edited without `omc-config.sh` `emit_known_flags` table touched (config-table lockstep); **R4** migration file edited without changelog/release notes; **R5** ≥4 code files edited but no README/docs/ touched. R3a + R3b together enforce the conf-flag triple-write rule from CLAUDE.md "Coordination Rules". Inferred surfaces fold into `delivery_contract_blocking_items` alongside v1's prompt-stated surfaces; show-status surfaces both; `/ulw-report` aggregates rule-fire frequency under "Delivery contract fires". Re-evaluated lazily on each NEW unique-path mark-edit (not on duplicates) and once at stop-guard, with the read-derive-write window held under `with_state_lock` for atomicity against concurrent mark-edits. Skipped on advisory/writing/research turns and when the prompt explicitly forbade commits. Skip-paths exclude `node_modules/`, `vendor/`, `dist/`, `build/`, `.next/`, `.turbo/`, `.cache/`, `target/`, `.git/`, and harness state directories so vendor regen does not pollute counts. Non-goals: generic "config" inference beyond R3 (no portable lockstep partner), UI state coverage (framework-specific; tracked via existing `design_review` dimension). First-session aggressiveness: R1 reliably trips on the first 2-file edit before any verification has populated the suppression baseline — run a quick verify once. Env: `OMC_INFERRED_CONTRACT`. |

Example `~/.claude/oh-my-claude.conf`:

```
stall_threshold=20
excellence_file_count=5
dimension_gate_file_count=5
traceability_file_count=10
state_ttl_days=14
verify_confidence_threshold=40
installation_drift_check=true
exemplifying_scope_gate=on
```

Values can also be overridden via environment variables (`OMC_STALL_THRESHOLD`, `OMC_EXCELLENCE_FILE_COUNT`, `OMC_DIMENSION_GATE_FILE_COUNT`, `OMC_TRACEABILITY_FILE_COUNT`, `OMC_STATE_TTL_DAYS`, `OMC_VERIFY_CONFIDENCE_THRESHOLD`, `OMC_CUSTOM_VERIFY_MCP_TOOLS`, `OMC_INSTALLATION_DRIFT_CHECK`, `OMC_PRETOOL_INTENT_GUARD`, `OMC_WAVE_OVERRIDE_TTL_SECONDS`). Environment variables take precedence over the conf file, and both override the built-in defaults. `OMC_REPRO_REDACT_CHARS` (default `80`) is env-only and controls the truncation length applied by `~/.claude/omc-repro.sh`.

### Recipe: shell-only / lint-as-tests projects

For projects where the primary automated check is a linter — pure-bash utilities, config-only repositories, spec-only documentation packages — the default `verify_confidence_threshold=40` can block legitimate stop attempts because `bash -n` and `shellcheck` score `30`. Rather than lowering the threshold globally (which weakens verification for every project), use per-project configuration to scope the override:

```bash
# From inside the project root:
mkdir -p .claude
cat > .claude/oh-my-claude.conf <<'EOF'
# Pure-bash project — lint IS the test. Relax the verification floor
# from 40 to 30 so shellcheck and bash -n can satisfy the quality gate.
verify_confidence_threshold=30
EOF
```

The harness walks up from `$PWD` looking for `.claude/oh-my-claude.conf`, so this override applies only when Claude Code is invoked from this project. The user-level `~/.claude/oh-my-claude.conf` keeps the `40` default for every other repo, and the existing `custom_verify_patterns` mechanism still lets you register project-specific test wrappers:

```
# Also in .claude/oh-my-claude.conf — name a wrapper script so the gate
# can recognize it as a higher-confidence project test command.
custom_verify_patterns=\b(run-tests\.sh|check\.sh)\b
```

If you later add an actual test suite, drop the threshold override and let the higher-confidence verification path satisfy the default gate.

---

## Domain Keywords

The domain classifier (`infer_domain()` in `skills/autowork/scripts/lib/classifier.sh`) scores prompts by counting keyword matches. To improve classification for your workflow, add keywords to the relevant pattern.

Each domain's keywords are defined as a regex pattern passed to `count_keyword_matches`. For example, the coding keywords:

```bash
coding_score=$(count_keyword_matches '\b(bugs?|fix|debug|refactor|implement|...)\b' "${text}")
```

To add a keyword:

1. Open `~/.claude/skills/autowork/scripts/lib/classifier.sh` (the classifier subsystem; sourced by `common.sh`).
2. Find the `infer_domain()` function (search for `infer_domain()` to avoid line-number drift).
3. Add your keyword to the appropriate domain's regex pattern, separated by `|`.
4. Keywords are matched case-insensitively. Use `\b` word boundaries to avoid partial matches.

Example -- adding "terraform" and "ansible" to the coding domain:

```bash
coding_score=$(count_keyword_matches '\b(...|terraform|ansible)\b' "${text}")
```

---

## Cognitive Defaults

The file `~/.claude/quality-pack/memory/core.md` defines the baseline thinking and behavior standards loaded into every session. It covers:

- **Thinking quality**: Plan-before-act, reflect-after-result, diagnose-before-fix.
- **Workflow rules**: Classify intent, classify domain, delegate to specialists, test after changes.
- **Code quality**: No placeholder stubs, no restating comments, no decorative comments.
- **Anti-patterns**: Forbidden behaviors (asking "should I proceed?", chaining tools without reasoning).
- **Failure recovery**: Stop retrying after 3 identical failures, switch approach or delegate.

To adjust these defaults, edit `core.md` directly. Changes take effect in new sessions. The file is loaded via `@` import in `~/.claude/CLAUDE.md`, so no registration step is needed.

To add new defaults, append new sections or bullet points. To relax a rule, remove or soften the relevant line. The "anti-patterns" section uses `FORBIDDEN:` labels -- removing a label removes the hard enforcement.

---

## Statusline

The statusline is a Python script (`~/.claude/statusline.py`) that renders a two-line status bar showing:

- **Line 1**: Model name, working directory, ULW mode indicator (when active), git branch (with dirty indicator), active output style.
- **Line 2**: Context window usage bar (color-coded: green < 70%, yellow 70-89%, red >= 90%), usage percentage, input/output token counts, session cost (with `*` when ULW active to signal subagent costs are excluded), session duration. Conditionally appends: rate limit usage (`RL:%`), prompt cache hit ratio (`C:%`), and API latency ratio (`API:%`) when data is available.

### Customizing the display

Edit `statusline.py` directly. The `main()` function assembles two lines from parsed JSON data:

- To change colors, modify the ANSI constants at the top of the file (`CYAN`, `YELLOW`, `GREEN`, etc.).
- To change the bar width, modify the `width` parameter in `make_bar()` (default: 18 characters).
- To add or remove fields, edit the `line_one_parts` or `line_two_parts` assembly in `main()`.
- To change the context threshold colors, edit `bar_color()` (defaults: green < 70%, yellow 70-89%, red >= 90%).

The statusline is registered in `~/.claude/settings.json` under `statusLine`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline.py",
  "padding": 0
}
```

Git information is cached for 5 seconds per working directory to avoid performance overhead from repeated `git` calls.

---

## Output Style

oh-my-claude ships with two built-in output styles. Both are copied into `~/.claude/output-styles/` on every install; the active one is whatever `outputStyle` in `~/.claude/settings.json` points at. Pick the voice that fits your work.

| Style | Filename | When to choose |
|-------|----------|----------------|
| **`oh-my-claude`** (default) | `oh-my-claude.md` | Day-to-day coding sessions. Compact, polished CLI presentation. Bold-label cards (`**Bottom line.**`, `**Changed.**`, `**Verification.**`, `**Risks.**`, `**Next.**`), implementation-first framing, brevity bias. |
| **`executive-brief`** | `executive-brief.md` | Reports to stakeholders, multi-wave work, anything where decisiveness reads better than density. CEO-style status report — headline first, status verbs (`Shipped`, `Blocked`, `At-risk`, `In-flight`, `Deferred`, `No-op`), explicit `**Risks.**` and `**Asks.**` sections, horizontal rules between primary sections. |

Both declare `keep-coding-instructions: true`, so Claude Code's coding-system-prompt (specialist-agent expectations, tool-use conventions) is preserved underneath either style.

### Voice preview — side-by-side

The same `/ulw` outcome rendered in both bundled styles. Use this preview to calibrate before flipping the conf flag — both surfaces cite the command and the count; the point is the **posture and word choice**, not whether numbers exist.

**`oh-my-claude` voice:**

> **Bottom line.** Added the new bundled style and wired it into install / uninstall / verify; tests pass.
>
> **Changed.**
> - `bundle/dot-claude/output-styles/executive-brief.md` (new file).
> - `output_style` conf enum extended to `opencode|executive|preserve`.
>
> **Verification.** `bash tests/test-settings-merge.sh` → `194 passed, 0 failed`.
>
> **Next.** Commit and update docs.

**`executive-brief` voice (same outcome):**

> **Headline.** Style shipped. 194 of 194 merge tests pass. No blockers, no asks.
>
> ---
>
> **Shipped.**
> - `bundle/dot-claude/output-styles/executive-brief.md` (new file, 218 lines).
> - `output_style` enum extended: `opencode | executive | preserve`.
>
> **Verification.**
> - `bash tests/test-settings-merge.sh` → `194 passed, 0 failed`.
>
> **Next.** Commit the wave; update `CHANGELOG.md`.

**What changes between the two:** lead label (`Bottom line.` vs `Headline.`), verb framing (`Added` vs `shipped`), explicit negative confirmation (`No blockers, no asks` — silence-means-none discipline applied to the headline itself), the horizontal rule between headline and body, and the tighter bullet cadence. **What does not change:** the cited command, the cited count, the `**Next.**` close. Both styles refuse to say `tests pass` without naming what passed.

If neither voice fits, see [Custom styles](#custom-styles) below for the upgrade-safe pattern.

### Switching between bundled styles

The fastest path is `/omc-config` — pick the value you want for `output_style` and re-run install:

| Conf value | settings.outputStyle written |
|------------|------------------------------|
| `output_style=opencode` (default) | `oh-my-claude` |
| `output_style=executive` | `executive-brief` |
| `output_style=preserve` | (untouched) |

When the conf flag is `opencode` or `executive`, `bash install.sh` rewrites `settings.outputStyle` on every install — switching the conf value moves you between bundled styles. A `settings.outputStyle` that does NOT match a bundled name (e.g. your own custom style) is preserved automatically.

You can also set the value directly:

```bash
jq '.outputStyle = "executive-brief"' ~/.claude/settings.json > /tmp/s.json && \
   mv /tmp/s.json ~/.claude/settings.json
# or revert:
jq '.outputStyle = "oh-my-claude"' ~/.claude/settings.json > /tmp/s.json && \
   mv /tmp/s.json ~/.claude/settings.json
```

The `outputStyle` value in `~/.claude/settings.json` must match the `name:` field in the chosen style file's frontmatter exactly (case-sensitive).

### Custom styles

> **Important:** `~/.claude/output-styles/oh-my-claude.md` and `~/.claude/output-styles/executive-brief.md` are overwritten on every install (`bash install.sh` rsyncs the bundle and your in-place edits do not survive an upgrade). The patterns below are upgrade-safe.

**Recommended — copy a bundled style to a new file with a different `name:`.** Preserves your customizations across upgrades.

```bash
cp ~/.claude/output-styles/oh-my-claude.md \
   ~/.claude/output-styles/my-style.md
# Edit ~/.claude/output-styles/my-style.md and change the frontmatter:
#   name: My Style
# Then point your settings at the new name:
jq '.outputStyle = "My Style"' ~/.claude/settings.json > /tmp/s.json && \
   mv /tmp/s.json ~/.claude/settings.json
```

**Alternative — opt out of any bundled style.** Set `output_style=preserve` in `~/.claude/oh-my-claude.conf` (or via `/omc-config`) and re-run install. The installer will leave your `outputStyle` setting untouched (including a pre-set custom value). Both bundled style files are still copied to `~/.claude/output-styles/` for reference, but `~/.claude/settings.json` is not modified.

### Modifying a bundled style (discouraged)

Editing `oh-my-claude.md` or `executive-brief.md` in place works for the current session but is overwritten on the next `bash install.sh`. Use the copy-to-new-file pattern above unless you are intentionally testing a one-shot change. The HTML comment at the top of each bundled file warns about this.

### Composition with Claude Code's built-in styles

Claude Code ships its own output styles (`Default`, `Explanatory`, `Learning`) — both bundled oh-my-claude styles declare `keep-coding-instructions: true`, which means Claude Code's coding-system-prompt (specialist-agent expectations, tool-use conventions) is preserved underneath. Switching to `Explanatory` or `Learning` swaps that surface entirely; the harness's specialist routing still works because agents have their own definitions, but the model's default coding posture changes. Using two output styles concurrently is not supported by Claude Code — only one is active per session.

---

## Ghostty Theme

oh-my-claude includes a Ghostty terminal theme in `config/ghostty/themes/`. The installer copies the theme and a config snippet to the appropriate Ghostty directories.

To modify the theme:

1. Edit the theme file in `config/ghostty/themes/`.
2. Colors are defined as hex values in Ghostty's theme format.
3. Re-run `bash install.sh` to copy the updated theme, or edit the installed copy directly at `~/.config/ghostty/themes/`.

The config snippet (`config/ghostty/config.snippet.ini`) sets the active theme and any terminal-level settings. If you use a different terminal emulator, this component can be ignored.

---

## Updating oh-my-claude

To update to a newer version, pull the latest changes and re-run the installer:

```bash
cd /path/to/oh-my-claude
git pull
bash install.sh
```

Use the same flags you used on the original install (e.g., `--bypass-permissions`, `--model-tier=economy`). The model tier is persisted in `~/.claude/oh-my-claude.conf` and re-applied automatically, so you only need to pass `--model-tier` again if you want to change it.

### What happens on update

1. **Backup**: Every file that will be overwritten is copied to `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`.
2. **Overwrite**: All agents, skills, hook scripts, output styles, statusline, and quality-pack memory files are replaced from the bundle via `rsync`.
3. **Merge**: `settings.json` is merged (user additions preserved, harness hooks updated).
4. **Re-apply**: Model tier is re-applied from `oh-my-claude.conf` if present.
5. **Verify**: Run `bash verify.sh` to confirm the update succeeded.

### What survives an update

- `settings.json` user additions (custom hooks, custom settings) -- merged, not overwritten.
- `~/.claude/oh-my-claude.conf` -- not in the bundle, never touched by rsync.
- Custom agent files you created (not shipped in the bundle) -- rsync adds files but does not delete extras.
- Custom skill directories you created -- same reason.

### What gets overwritten

All files that exist in the `bundle/dot-claude/` directory, including: agent definitions, skill definitions, hook scripts, `common.sh`, quality-pack memory files (`core.md`, `skills.md`, `compact.md`), `statusline.py`, output styles, and `CLAUDE.md`.

If you customized any bundled file, your changes are lost on update. The backup directory contains the previous version for manual recovery.

---

## Rollback and Recovery

Every install creates a timestamped backup at `~/.claude/backups/oh-my-claude-{TIMESTAMP}/`. This directory mirrors the structure of `~/.claude/` and contains every file that was overwritten, plus a copy of `settings.json`.

### Restore a single file

```bash
# Find the most recent backup
ls -t ~/.claude/backups/ | head -1

# Copy the file back
cp ~/.claude/backups/oh-my-claude-20260407-143000/agents/quality-planner.md ~/.claude/agents/quality-planner.md
```

### Full rollback

```bash
# Find the backup to restore from
BACKUP=~/.claude/backups/oh-my-claude-20260407-143000

# Copy everything back (preserves your current settings.json merge)
rsync -a "$BACKUP/" ~/.claude/ --exclude=settings.json

# Or include settings.json if you want the pre-update version
rsync -a "$BACKUP/" ~/.claude/
```

This restores backed-up files but does not remove files added by the new version. If the update introduced new agents or scripts, those will remain alongside the restored files.

### Recover settings.json

The backup always includes the pre-install `settings.json`:

```bash
cp ~/.claude/backups/oh-my-claude-20260407-143000/settings.json ~/.claude/settings.json
```

---

## Configuration Safety

Not all customizations carry the same risk. This matrix classifies files by how safe they are to edit and whether changes survive updates.

| Category | Files | Risk | Survives update? |
|---|---|---|---|
| **Safe, persistent** | `settings.json` (user-added hooks/settings) | Low | Yes (merged) |
| **Safe, persistent** | `oh-my-claude.conf` | Low | Yes (not in bundle) |
| **Safe, persistent** | Custom agents you create in `~/.claude/agents/` | Low | Yes (not in bundle) |
| **Safe, persistent** | Custom skills you create in `~/.claude/skills/` | Low | Yes (not in bundle) |
| **Safe, overwritten** | Agent `.md` files (model, maxTurns) | Low | No (re-apply or use `--model-tier`) |
| **Moderate, overwritten** | `quality-pack/memory/core.md` | Medium | No |
| **Moderate, overwritten** | `output-styles/oh-my-claude.md` | Medium | No |
| **Moderate, overwritten** | `statusline.py` | Medium | No |
| **High risk, overwritten** | `skills/autowork/scripts/stop-guard.sh` | High | No |
| **High risk, overwritten** | `skills/autowork/scripts/common.sh` | High | No |
| **High risk, overwritten** | Other hook scripts in `skills/autowork/scripts/` | High | No |

**Rule of thumb**: If a file ships in `bundle/dot-claude/`, it will be overwritten on the next install. Prefer out-of-bundle customization (creating new agents, new skills, adding to `settings.json`) over modifying bundled files.

### AI-assisted configuration

You can ask Claude (or another AI assistant) to modify harness configuration. Some changes are safe; others can break the quality gate system.

**Safe for AI to edit:**
- `settings.json` -- adding custom hooks, changing `outputStyle` or `effortLevel`.
- `oh-my-claude.conf` -- changing model tier.
- Creating new agent files in `~/.claude/agents/`.
- Creating new skill directories in `~/.claude/skills/`.
- `quality-pack/memory/core.md` -- adjusting cognitive defaults, relaxing rules.

**Risky for AI to edit (understand before changing):**
- `stop-guard.sh` -- modifying quality gate logic can disable enforcement.
- `common.sh` -- changes affect all hooks (intent classification, domain scoring, state management).
- `prompt-intent-router.sh` -- changing intent routing can break the workflow loop.
- Intent classification order in `common.sh` -- the check order is a [protected design decision](architecture.md).

If you ask an AI agent to modify hook scripts, review the changes carefully before starting a new session. A broken hook script can cause silent failures (the harness stops enforcing without any visible error).
