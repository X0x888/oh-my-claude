---
name: omc-config
description: Guided oh-my-claude configuration via multi-choice prompts — first-time setup walkthrough, post-update review, or ad-hoc inspect/change. Auto-detects mode from `~/.claude/oh-my-claude.conf`. Use when the user asks to install, set up, configure, update, walk through settings, change flags, turn the watchdog or bias-defense on/off, switch model tier, or any phrase like "help me install/update/configure oh-my-claude", "show my settings", "what flags do I have on".
argument-hint: [setup | update | change]
---

# /omc-config — guided oh-my-claude configuration

This skill walks the user through oh-my-claude's runtime flags using `AskUserQuestion` so they never have to type values or grep `~/.claude/oh-my-claude.conf` manually. It auto-detects three modes:

- **setup** — first time through the skill (post-install, no `omc_config_completed=` sentinel yet)
- **update** — bundle version is newer than `installed_version` (after `git pull && bash install.sh`)
- **change** — already configured; user wants to inspect or adjust

The user can override detection by passing `setup`, `update`, or `change` as the argument.

The skill's primary artifact is `oh-my-claude.conf`, and it never edits session state. Three deliberate side effects keep the selected persistent configuration real immediately: changing a model tier/override can rewrite agent assignments via `switch-tier.sh`; enabling the watchdog can register its scheduler via `install-resume-watchdog.sh`; and every explicit user-scope `output_style` write atomically reconciles the bundled `settings.json` `outputStyle` field while preserving a custom style. A conflicting `OMC_OUTPUT_STYLE` is reported and still governs a later installer invocation; it does not silently prevent materialization of the saved choice the user just requested.

---

## Step 1 — Detect mode and show current state

Run mode detection:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh detect-mode
```

Possible outputs:

- `not-installed` — `~/.claude/oh-my-claude.conf` is missing or has no `installed_version`. Tell the user to run `install.sh` first (or follow `AGENTS.md` § "Agent Install Protocol") and stop. Do not proceed.
- `setup` — first-time framing.
- `update` — upgrade framing.
- `change` — ad-hoc framing.

If the user passed an argument (`setup`, `update`, or `change`), use that instead of the detected value.

Then dump the current effective config so they can see what's active before deciding:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh show
```

Relay the output verbatim. Stars (`*`) in the table flag values that differ from defaults — the user wants to see those.

---

## Step 2 — Frame the choice

Print a short preamble matched to the mode (2–3 lines max):

- **setup** — "First-time configuration. Pick a profile or fine-tune individual flags. The recommended profile (Zero Steering) applies oh-my-claude's intended posture: maximum automation + adaptive strict gates for high-risk work."
- **update** — "Welcome back. The bundle is newer than your installed version (table above). Your current values are starred against defaults — review them, then either keep them, switch to a profile, or fine-tune individual flags. (Note: update mode does not auto-detect which flags are new in this release; it surfaces the *current state* against *current defaults*. To see what changed in this release, read `CHANGELOG.md`.)"
- **change** — "Pick a profile to overwrite settings, or 'Fine-tune' to change individual flags."

---

## Step 3 — Profile + scope (one `AskUserQuestion` call, two questions)

Call `AskUserQuestion` once with both questions in the same tool invocation. The user answers both before any work happens.

**Question 1 — header `Profile`** (single-select, 4 options + auto-Other for cancel/aliases)

```
question: "Which profile should I apply? (To make no changes, pick Other and type 'cancel'.)"
options:
  - label: "Zero Steering (Recommended)"
    description: "Maximum automation, Opus execution, inherited deliberation, and high-risk gates that block until proof is green."
  - label: "Balanced"
    description: "Standard gates + low-friction bias-defense, sonnet model, watchdog off. Good for daily use."
  - label: "Minimal"
    description: "Basic gates, no telemetry, watchdog off, economy model. For shared/regulated machines."
  - label: "Review my defaults & fine-tune"
    description: "Walk individual flag clusters. Inspect what changed since your last config, or mix-and-match."
```

v1.39.0 W4 collapsed the prior "Maximum Quality + Automation" option — it mapped to the same preset as "Zero Steering" and showing both was confusing for new users. The `maximum` token remains a valid backend alias (a user with `maximum` in their conf or someone typing it via Other still gets the same posture).

The auto-injected "Other" option lets the user type `cancel` to bail without writes. If the user types `cancel` (case-insensitive) or any non-matching synonym, treat it as a cancel: print "No changes made." and stop. Do NOT call `mark-completed`. Do NOT proceed to Step 4. The skill should leave the conf untouched.

**Question 2 — header `Scope`** (single-select, 2 options)

```
question: "Where should I write the config?"
options:
  - label: "User-wide (Recommended)"
    description: "~/.claude/oh-my-claude.conf — applies to every project on this machine."
  - label: "This project only"
    description: "./.claude/oh-my-claude.conf — overrides project-safe settings here. Security, persistence, machine-wide scheduler/output, model authority, and statusline preferences remain user-wide."
```

Map the user's answers back to short tokens:

- "Zero Steering (Recommended)" → `zero-steering`
- "Balanced" → `balanced`
- "Minimal" → `minimal`
- "Review my defaults & fine-tune" → `custom`
- "User-wide (Recommended)" → `user`
- "This project only" → `project`

If the user typed something via the auto-injected "Other" option:
- Text matching `cancel` / `quit` / `exit` / `stop` / `no` (case-insensitive) → bail. Print "No changes made." and stop. Do NOT call `mark-completed`.
- Text matching `maximum` (legacy alias for Zero Steering, preserved for back-compat) → treat as `zero-steering`.
- Anything else → treat as `custom` and walk Step 4's fine-tune path. (If the typed text matches a profile name like `zero-steering`/`balanced`/`minimal`, treat it as that profile.)

---

## Step 4 — Apply

### Path A — preset

If `$PROFILE` is `zero-steering`, `maximum`, `balanced`, or `minimal`:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh apply-preset "$SCOPE" "$PROFILE"
```

This writes the preset atomically. Validation runs first, so a bad value never half-writes the conf. At `project` scope the backend deliberately omits every user-only key in the runtime deny-list (security/enforcement, repository persistence, auto-tune, and model authority) and says so in its output; the user's existing tier remains active and no installed agent files are rewritten.

### Path B — fine-tune

Walk the clusters below (six at user scope, three at project scope). Use one
`AskUserQuestion` call per cluster. The Definition & Taste cluster deliberately
uses one call containing four short questions because its controls form one
authority boundary and must still be independently selectable.

**Cluster 1 — Quality gates** (single-select)

```
question: "How strictly should the quality gates enforce?"
header: "Gates"
options:
  - label: "Full enforcement, scorecard at cap (Recommended)"
    description: "gate_level=full, guard_exhaustion_mode=scorecard. All gates run; when block-cap hits, surface a scorecard and release."
  - label: "Full enforcement, blocking at cap"
    description: "gate_level=full, guard_exhaustion_mode=block. Same gates, but cap-hit keeps blocking — strictest posture."
  - label: "Standard (no dimension gate)"
    description: "gate_level=standard. Quality + excellence gates only; skips dimension/traceability ceiling."
  - label: "Basic (quality gate only)"
    description: "gate_level=basic. Single quality gate; minimal interruption."
```

Emit `gate_level=<value>` and (if option 1 or 2) `guard_exhaustion_mode=<value>`.

**Cluster 2 — Definition of Excellent & Taste** (four single-select questions,
user scope only)

If `$SCOPE` is `project`, skip this cluster and emit none of its four flags.
Briefly note that the frozen quality bar and learned taste are user-owned and a
project cannot weaken or rewrite them.

If `$SCOPE` is `user`, send one `AskUserQuestion` call with these four questions:

```
question: "When should the five-axis Definition of Excellent be mandatory?"
header: "Definition"
options:
  - label: "Adaptive (Recommended)"
    description: "Freeze the deliberate, distinctive, coherent, visionary, and complete bar for serious, broad, risky, or explicitly ambitious execution. definition_of_excellent=adaptive."
  - label: "Always"
    description: "Require a frozen five-axis contract for every execution objective, including small routine work. definition_of_excellent=always."
  - label: "Off"
    description: "Disable the Definition contract and its mutation/Stop gates. definition_of_excellent=off."

question: "Should approved Quality Constitution standards shape new contracts?"
header: "Constitution"
options:
  - label: "Consume standards (Recommended)"
    description: "Compile applicable user-approved project/global standards into the frozen contract. quality_constitution=on."
  - label: "Ignore standards"
    description: "Keep approved standards stored but do not consume them when planning. quality_constitution=off."

question: "How should repeated taste signals be learned?"
header: "Taste"
options:
  - label: "Review candidates (Recommended)"
    description: "Record candidates, but require explicit user approval before they become active standards. taste_learning=review."
  - label: "Adaptive advisory"
    description: "Repeated signals may activate as advisory taste; they never become blocking authority without explicit approval. taste_learning=adaptive."
  - label: "Do not learn"
    description: "Do not record or activate inferred taste candidates. Explicit Constitution entries remain available. taste_learning=off."

question: "How much compiled Constitution context may a planner receive?"
header: "Taste budget"
options:
  - label: "Balanced 2400 (Recommended)"
    description: "Enough room for applicable standards while bounding prompt tax. quality_constitution_max_context_chars=2400."
  - label: "Compact 1200"
    description: "Prefer a smaller prompt footprint for simple standards sets. quality_constitution_max_context_chars=1200."
  - label: "Expanded 4000"
    description: "Preserve more applicable standards for dense professional workflows. quality_constitution_max_context_chars=4000."
```

Always emit all four selected values at user scope:
`definition_of_excellent=<adaptive|always|off>`,
`quality_constitution=<on|off>`,
`taste_learning=<off|review|adaptive>`, and
`quality_constitution_max_context_chars=<1200|2400|4000>`.

**Cluster 3 — Advisory routing** (multi-select)

```
question: "Which advisory directives should I inject? (multi-select)"
header: "Advisory"
multiSelect: true
options:
  - label: "Declare-and-proceed scope interpretation on vague product-shaped prompts"
    description: "When a short product-shaped prompt arrives without anchors, the router tells the model to state its scope interpretation (audience, primary success criterion, non-goals) in one or two declarative sentences as part of its opener, then proceed. /prometheus is reserved for the credible-approach-split case. Catches the bias-blind 'confident wrong' mode without producing a hold."
  - label: "Declare-and-proceed goal interpretation on short unanchored prompts"
    description: "On unanchored prompts, the model states its interpretation of the goal in one declarative sentence as part of its opener (e.g., 'I'm interpreting this as <X> and proceeding now'), then starts work. Lighter than the product-shaped variant — one declarative sentence vs two plus non-goals. The user can redirect in real time; the directive never produces a hold."
  - label: "Block stop on complex plans until metis stress-tests"
    description: "Hard gate: a plan with ≥5 steps / ≥3 files / ≥2 waves can't reach Stop until metis has reviewed it."
```

For each selected option, emit `<flag>=on`. For unselected options, do NOT emit `<flag>=off` — leave the user's prior value alone unless they explicitly want to disable. (If the user wants to disable, they can re-run the skill and pick a profile.)

**Cluster 4 — Memory & telemetry** (multi-select)

```
question: "Which memory and telemetry features should be enabled? (multi-select)"
header: "Memory/Telemetry"
multiSelect: true
options:
  - label: "Cross-session auto-memory (Recommended)"
    description: "Writes project_*/feedback_*/user_*/reference_*.md at session-stop and pre-compact. auto_memory=on."
  - label: "Per-turn classifier telemetry"
    description: "Each prompt classification is recorded for later /ulw-report introspection. classifier_telemetry=on."
  - label: "Capture resume_request.json on rate-limit kill (Recommended)"
    description: "When the 5h/7d cap fires, the original objective is captured so /ulw-resume can replay. stop_failure_capture=on."
  - label: "Discovered-scope finding capture (Recommended)"
    description: "Advisory specialists' findings are gated by stop-guard; explicit defer/ship required. discovered_scope=on."
  - label: "Per-prompt time-distribution capture (Recommended)"
    description: "Records where each prompt's wall time goes (per-tool / per-subagent) and surfaces a Stop epilogue + /ulw-time skill. time_tracking=on."
```

For selected options, emit the corresponding `<flag>=on`. For unselected, do NOT emit `=off`.

**Cluster 5 — Model cost tier** (single-select, user scope only)

If `$SCOPE` is `project`, skip this cluster and emit no `model_tier` or
`model_overrides` pair. Briefly note that model strength/cost is user-controlled
and the current user-wide tier remains active. Do not silently redirect a
project-scoped choice into global config.

If `$SCOPE` is `user`, ask:

```
question: "Which model tier?"
header: "Cost"
options:
  - label: "Quality (execution on Opus)"
    description: "Opus-execution posture, highest fixed-agent cost. Deliberators ride the user-selected session model. model_tier=quality."
  - label: "Balanced (Recommended)"
    description: "Planning/review ride the session model, Sonnet for execution. model_tier=balanced."
  - label: "Economy (adaptive Sonnet-first)"
    description: "Inherited deliberators plus Sonnet specialists, with Sonnet low-risk routing and high-risk escalation when weaker retries would cost more. model_tier=economy."
```

At user scope, always emit `model_tier=<value>` (single-select — the user has
explicitly chosen). At project scope, emit neither model flag.

**Cluster 6 — Output style** (single-select, user scope only)

If `$SCOPE` is `project`, skip this cluster and emit no `output_style` pair.
The preference synchronizes user-wide `~/.claude/settings.json`, so a
project-scoped config must not change it as a side effect.

```
question: "Output style installer behavior?"
header: "Style"
options:
  - label: "Bundle oh-my-claude style (Recommended)"
    description: "Compact, polished CLI presentation. Bold-label cards (Bottom line / Changed / Verification / Risks / Next), implementation-first framing, brevity bias. Sets settings.outputStyle to 'oh-my-claude'. output_style=opencode."
  - label: "Bundle executive-brief style (CEO report)"
    description: "CEO-style status report. Headline first (BLUF), status verbs (Shipped / Blocked / At-risk / In-flight / Deferred / No-op), explicit Risks and Asks sections, horizontal rules between primary sections. For decisive, signal-heavy reports. Sets settings.outputStyle to 'executive-brief'. output_style=executive."
  - label: "Preserve my settings.json"
    description: "Skip the outputStyle merge entirely so install never touches settings.json. Both bundled files are still copied to ~/.claude/output-styles/ for reference. Use when you have your own output style. output_style=preserve."
```

At user scope, always emit `output_style=<value>` (single-select — the user has
explicitly chosen).

After all applicable clusters:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh set "$SCOPE" <each k=v collected above>
```

Validation runs before write. If any validation fails, the script exits 2 — surface the error to the user and either re-ask the offending cluster or hand off.

---

## Step 5 — Conditional side effects

Several flags need action beyond writing the conf. Run these after Step 4 commits.

### 5a — Tier change

Both `apply-preset user` and `set user model_tier=...` invoke `apply-tier`
automatically when the tier changes. `set user model_overrides=...` also
reapplies the current tier when the override set changes, so direct-skill
frontmatter and next-prompt live routing agree without a reinstall or second
command; a batch changing both model keys still invokes the switcher once.
Project presets omit all runtime-denied user-only keys, and direct project
writes of any such key are rejected before any config or agent-file mutation.
For model controls specifically, changing or clearing overrides under the
quality tier forces a canonical declaration restore before applying the new
set, preventing a removed pin from lingering in direct-skill frontmatter.

### 5b — Watchdog scheduler

Only perform this step for `$SCOPE=user`. Project presets omit the user-only
`resume_watchdog` switch, and project configuration must never register a
machine-wide scheduler. At user scope, read the new `resume_watchdog` value. If
it's `on` AND the user has not previously run the watchdog installer
(heuristic: `~/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist` on
macOS, `~/.config/systemd/user/oh-my-claude-resume-watchdog.timer` on Linux —
check existence), ask:

```
question: "Install the watchdog scheduler now?"
header: "Watchdog"
options:
  - label: "Install scheduler now (Recommended)"
    description: "Registers the LaunchAgent (macOS) or systemd user-timer (Linux) so the watchdog runs every ~2 minutes. Without this, resume_watchdog=on is just a flag — the daemon needs the scheduler."
  - label: "Set the flag only — install later"
    description: "Run `bash ~/.claude/install-resume-watchdog.sh` yourself when you're ready."
```

If the user picks "Install scheduler now":

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh install-watchdog
```

Relay the installer's stdout (it confirms platform, sets the flag if not already set, runs a dry-tick, prints log paths).

If the scheduler is already installed (file existence check above), skip the question and just note it in the summary.

---

## Step 6 — Stamp completion and summarize

**Only run `mark-completed` after Step 5 finishes** (including any conditional watchdog scheduler install). If the user bailed at Step 3 ("cancel") or aborted between Step 4 and Step 5, do NOT mark-completed — leave the user in `setup` mode so the next invocation re-offers the wizard. The sentinel is "this user has been through the full wizard once," and partial walks should not satisfy it.

Once the user has confirmed their full set of choices (profile applied + tier rewritten if needed + watchdog resolved), stamp the sentinel. It always lands in `~/.claude/oh-my-claude.conf` (per-machine flag, not per-project), so the scope argument is ignored — pass it if you like, but the path is fixed:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh mark-completed
```

Then print a final summary:

```
oh-my-claude configured.
  Profile:   <zero-steering|maximum|balanced|minimal|custom>
  Scope:     <user|project>
  Definition:<adaptive|always|off> (Constitution <on|off>; taste <off|review|adaptive>)
  Watchdog:  <installed|flag set|off>
  Tier:      <tier> (agents <rewritten|unchanged>; `user-wide preserved` for project scope)
  Conf:      <path>
```

Add a one-line restart hint when needed:

- If `gate_level`, `guard_exhaustion_mode`, `quality_policy`, or any `*_file_count` changed → "The new gate setting applies on the next prompt or relevant hook; no restart is required."
- If user-scope `model_tier` changed → "Tier change applied to agent files; new sessions use the new tier automatically."
- If project scope was selected → "Protected security/enforcement boundaries, persistence promotion, auto-tune, model authority, machine-wide watchdog/output/retention settings, and statusline display preferences remain user-wide; privacy-sensitive project controls may reduce capture but cannot re-enable a user opt-out. This project cannot weaken the protected user-only enforcement boundaries, write team memory, self-tune global policy, silently change model strength/spend, register a scheduler, delete cross-project data, or publish dead display overrides."
- If any Definition/Constitution control changed → "Definition and taste changes apply on the next real user prompt; no restart is required."
- If only watchdog/memory/telemetry flags changed → no restart needed.

Then offer one follow-up:

- "Run `/ulw-status` to confirm the active flags."

---

## When NOT to run

- The user hasn't installed oh-my-claude yet — Step 1 surfaces this via `not-installed`.
- The user wants to inspect ONLY (no changes) — `bash ~/.claude/skills/autowork/scripts/omc-config.sh show` gives them that without the question flow.
- The user wants to change agent model assignments only with no flag work — `bash ~/.claude/switch-tier.sh <tier>` is the direct command.
- The user wants to manage arbitrary `settings.json` hooks, permissions, or env vars — that's the `update-config` skill's domain. This skill only synchronizes `settings.outputStyle` as the documented side effect of changing `output_style`.

---

## Edge cases

- **Project scope without `.claude/` dir.** `set`/`apply-preset` create the directory. Note this in the summary so the user knows.
- **User-only flags at project scope.** Direct writes fail atomically for `pretool_intent_guard`, `bg_spawn_gate`, `agent_first_gate`, `no_defer_mode`, `quality_policy`, `definition_of_excellent`, `quality_constitution`, `taste_learning`, `quality_constitution_max_context_chars`, `model_tier`, `model_overrides`, `council_deep_default`, `workflow_substrate`, `repo_lessons`, `auto_tune`, `output_style`, `resume_watchdog`, `resume_watchdog_cooldown_secs`, `resume_session_ttl_secs`, `resume_request_ttl_days`, `resume_scan_max_sessions`, `claude_bin`, `state_ttl_days`, `time_tracking_xs_retain_days`, `custom_verify_mcp_tools`, `custom_verify_patterns`, `installation_drift_check`, `statusline_retention`, and `statusline_width`. Project presets omit deny-listed keys they contain. Use user scope; for model controls, a deliberate launch-time `OMC_MODEL_TIER` / `OMC_MODEL_OVERRIDES` environment value is also supported. Council depth and Workflow substrate are user-owned model/cost/execution postures; custom-verification matchers are restricted because they broaden which tool calls may mint verification evidence; resume TTL/scan breadth are restricted so project hooks and the machine-wide watchdog cannot disagree about claimability.
- **Monotonic project privacy/authorization/notices.** Project conf may turn `classifier_telemetry`, `auto_memory`, `prompt_persist`, `stop_failure_capture`, `transcript_archive`, `time_tracking`, `token_tracking`, `model_drift_canary`, and `blindspot_inventory` off, but cannot turn one on over a user/default opt-out. It may reduce `resume_request_per_cwd_cap`, but cannot raise it or choose unlimited `0` unless the user baseline is already unlimited. It may shorten `wave_override_ttl_seconds`, but cannot widen the user/default stale-wave commit-authorization window. It may suppress `whats_new_session_hint` or `self_audit_nudge`, but cannot re-enable a machine-wide notice the user disabled. Direct unsafe writes fail atomically; project presets omit unsafe promotions and report them.
- **Inherit pins are definition-backed, not a hidden model enum.** Claude Code's Agent call accepts named model enums only; `inherit` means omit the model and use the selected definition. Accept shipped bare inherit when its installed file can be reconstructed, run the tier switch immediately, and report failure truthfully. Accept custom bare inherit only when its untouched definition already contains exactly one `model: inherit` line. Reject namespaced inherit and missing bare targets; explicit Opus/Sonnet/Haiku custom and namespaced pins remain runtime-only and never rewrite their definitions.
- **Stale `repo_path`.** If `cmd_show` reports `bundle: unknown`, the conf's `repo_path` doesn't point to a checkout with `VERSION`. Tell the user to re-run `install.sh` from the source repo so `repo_path` refreshes, then retry.
- **Conf file has hand-written comments.** `write_conf_atomic` only strips lines matching `^<key>=` for the keys being written. Unrelated lines (including `#` comments) are preserved.
- **AskUserQuestion unavailable.** Fall back to printing the options as a numbered list and asking the user to type a number. The skill is designed around the tool, so this is a degraded path — note it explicitly.
- **Non-interactive context (CI / automation).** This skill assumes interactive use. If the user is scripting, they should write to the conf directly with `printf` or use `omc-config.sh set/apply-preset` non-interactively.
