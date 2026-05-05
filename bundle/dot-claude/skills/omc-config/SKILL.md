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

The skill writes ONLY to `oh-my-claude.conf`. It does not edit `settings.json` (that's the harness's job at install time) or session state. It can trigger two side effects when the user opts in: rewriting agent model assignments via `switch-tier.sh`, and registering the watchdog scheduler via `install-resume-watchdog.sh`.

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

- **setup** — "First-time configuration. Pick a profile or fine-tune individual flags. The recommended profile applies oh-my-claude's intended posture: maximum quality + automation."
- **update** — "Welcome back. The bundle is newer than your installed version (table above). Your current values are starred against defaults — review them, then either keep them, switch to a profile, or fine-tune individual flags. (Note: update mode does not auto-detect which flags are new in this release; it surfaces the *current state* against *current defaults*. To see what changed in this release, read `CHANGELOG.md`.)"
- **change** — "Pick a profile to overwrite settings, or 'Fine-tune' to change individual flags."

---

## Step 3 — Profile + scope (one `AskUserQuestion` call, two questions)

Call `AskUserQuestion` once with both questions in the same tool invocation. The user answers both before any work happens.

**Question 1 — header `Profile`** (single-select, 4 options + auto-Other for cancel/minimal)

```
question: "Which profile should I apply? (To make no changes, pick Other and type 'cancel'.)"
options:
  - label: "Maximum Quality + Automation (Recommended)"
    description: "Most rigorous gates, all bias-defense directives on, opus model. Best for solo devs on important work."
  - label: "Balanced"
    description: "Standard gates + low-friction bias-defense, sonnet model, watchdog off. Good for daily use."
  - label: "Minimal"
    description: "Basic gates, no telemetry, watchdog off, economy model. For shared/regulated machines."
  - label: "Review my defaults & fine-tune"
    description: "Walk individual flag clusters. Inspect what changed since your last config, or mix-and-match."
```

The auto-injected "Other" option lets the user type `cancel` to bail without writes. If the user types `cancel` (case-insensitive) or any non-matching synonym, treat it as a cancel: print "No changes made." and stop. Do NOT call `mark-completed`. Do NOT proceed to Step 4. The skill should leave the conf untouched.

**Question 2 — header `Scope`** (single-select, 2 options)

```
question: "Where should I write the config?"
options:
  - label: "User-wide (Recommended)"
    description: "~/.claude/oh-my-claude.conf — applies to every project on this machine."
  - label: "This project only"
    description: "./.claude/oh-my-claude.conf — overrides the user-wide settings only for the current project."
```

Map the user's answers back to short tokens:

- "Maximum Quality + Automation (Recommended)" → `maximum`
- "Balanced" → `balanced`
- "Minimal" → `minimal`
- "Review my defaults & fine-tune" → `custom`
- "User-wide (Recommended)" → `user`
- "This project only" → `project`

If the user typed something via the auto-injected "Other" option:
- Text matching `cancel` / `quit` / `exit` / `stop` / `no` (case-insensitive) → bail. Print "No changes made." and stop. Do NOT call `mark-completed`.
- Anything else → treat as `custom` and walk Step 4's fine-tune path. (If the typed text matches a profile name like `maximum`/`balanced`/`minimal`, treat it as that profile.)

---

## Step 4 — Apply

### Path A — preset

If `$PROFILE` is `maximum`, `balanced`, or `minimal`:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh apply-preset "$SCOPE" "$PROFILE"
```

This writes all preset keys atomically. Validation runs first, so a bad value never half-writes the conf.

Capture the previous `model_tier` value (from `cmd_show` in Step 1) so Step 5 can decide whether to invoke `apply-tier`.

### Path B — fine-tune

Walk the five cluster questions below. Use one `AskUserQuestion` call per cluster — clusters are conceptually distinct, and batching all of them at once would overload the user.

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

**Cluster 2 — Advisory routing** (multi-select)

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

**Cluster 3 — Memory & telemetry** (multi-select)

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

**Cluster 4 — Cost ceiling** (single-select)

```
question: "Which model tier?"
header: "Cost"
options:
  - label: "Quality (all Opus)"
    description: "Highest quality, highest cost. model_tier=quality."
  - label: "Balanced (Recommended)"
    description: "Opus for planning/review, Sonnet for execution. model_tier=balanced."
  - label: "Economy (all Sonnet)"
    description: "Lowest cost, still capable. model_tier=economy."
```

Always emit `model_tier=<value>` (single-select — user has explicitly chosen).

**Cluster 5 — Output style** (single-select)

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

Always emit `output_style=<value>` (single-select — user has explicitly chosen).

After all five clusters:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh set "$SCOPE" <each k=v collected above>
```

Validation runs before write. If any validation fails, the script exits 2 — surface the error to the user and either re-ask the offending cluster or hand off.

---

## Step 5 — Conditional side effects

Several flags need action beyond writing the conf. Run these after Step 4 commits.

### 5a — Tier change

`apply-preset` already invokes `apply-tier` automatically when the preset's `model_tier` differs from the current value (defense-in-depth — agent files stay in sync with the conf even if this step is skipped). You do NOT need to call `apply-tier` explicitly after `apply-preset`.

For the **fine-tune** path, you DO need to call it explicitly when the user chose a different tier in Cluster 4:

```bash
bash ~/.claude/skills/autowork/scripts/omc-config.sh apply-tier <new-tier>
```

This rewrites `~/.claude/agents/*.md` so the tier takes effect on the next session. Skip if the tier was unchanged.

### 5b — Watchdog scheduler

Read the new `resume_watchdog` value. If it's `on` AND the user has not previously run the watchdog installer (heuristic: `~/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist` on macOS, `~/.config/systemd/user/oh-my-claude-resume-watchdog.timer` on Linux — check existence), ask:

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
  Profile:   <maximum|balanced|minimal|custom>
  Scope:     <user|project>
  Watchdog:  <installed|flag set|off>
  Tier:      <tier> (agents <rewritten|unchanged>)
  Conf:      <path>
```

Add a one-line restart hint when needed:

- If `gate_level`, `guard_exhaustion_mode`, or any `*_file_count` changed → "Restart Claude Code to pick up the new gate level."
- If `model_tier` changed → "Tier change applied to agent files; new sessions use the new tier automatically."
- If only watchdog/memory/telemetry flags changed → no restart needed.

Then offer one follow-up:

- "Run `/ulw-status` to confirm the active flags."

---

## When NOT to run

- The user hasn't installed oh-my-claude yet — Step 1 surfaces this via `not-installed`.
- The user wants to inspect ONLY (no changes) — `bash ~/.claude/skills/autowork/scripts/omc-config.sh show` gives them that without the question flow.
- The user wants to change agent model assignments only with no flag work — `bash ~/.claude/switch-tier.sh <tier>` is the direct command.
- The user wants to manage `settings.json` (hooks, permissions, env vars) — that's the `update-config` skill's domain. This skill is `oh-my-claude.conf` only.

---

## Edge cases

- **Project scope without `.claude/` dir.** `set`/`apply-preset` create the directory. Note this in the summary so the user knows.
- **Stale `repo_path`.** If `cmd_show` reports `bundle: unknown`, the conf's `repo_path` doesn't point to a checkout with `VERSION`. Tell the user to re-run `install.sh` from the source repo so `repo_path` refreshes, then retry.
- **Conf file has hand-written comments.** `write_conf_atomic` only strips lines matching `^<key>=` for the keys being written. Unrelated lines (including `#` comments) are preserved.
- **AskUserQuestion unavailable.** Fall back to printing the options as a numbered list and asking the user to type a number. The skill is designed around the tool, so this is a degraded path — note it explicitly.
- **Non-interactive context (CI / automation).** This skill assumes interactive use. If the user is scripting, they should write to the conf directly with `printf` or use `omc-config.sh set/apply-preset` non-interactively.
