# oh-my-claude

**Ship better real work with Claude Code — with less steering.**

*Quality gates that block Claude from claiming "done" until tests pass, review lands, and the work is verified. So you stop babysitting every session.*

[![Version](https://img.shields.io/badge/Version-1.49.0-blue.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-bash-green.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-jq%20%2B%20rsync-brightgreen.svg)]()
[![Tests](https://img.shields.io/badge/Tests-2200%2B-brightgreen.svg)](tests/)

**Jump to:** [What changes after install](#what-changes-after-you-install) · [vs vanilla Claude Code](#how-is-this-different-from-vanilla-claude-code) · [Install](#quick-start) · [Skills](#available-skills) · [FAQ](docs/faq.md) · [ohmyclaude.dev](https://ohmyclaude.dev)

> **Activate with `/ulw <task>` (ultrawork mode).** The harness classifies your prompt, routes specialists (different chain per domain — coding, writing, research, ops), runs reviewers, verifies the work, and refuses to stop early. You don't need to learn agent names.

![oh-my-claude /ulw-demo — quality gates in action](docs/ulw-demo.gif)

*Two minutes of `/ulw-demo` showing the quality gates fire on a real edit — see [Quick start](#quick-start) below to install and try it yourself. Visit [ohmyclaude.dev](https://ohmyclaude.dev) for the visual walkthrough.*

## What changes after you install

Three outcomes you'll feel in your first week:

- **Claude can't claim "done" with broken code.** Quality gates intercept the Stop event until tests, review, and verification land. No more "I've made the changes" on work that doesn't compile.
- **Your prompts get classified before Claude acts.** Execution vs advisory, coding vs writing — and routed to the right specialists automatically. Less steering per turn; more useful first responses.
- **When Claude is uncertain, it tells you instead of guessing.** Declare-and-proceed openers surface the model's interpretation in one sentence so you can redirect cheaply if it's wrong — instead of finding out 3 commits later.

The harness is bash hooks + skills + agents installed as an overlay into `~/.claude/`. It sits alongside Claude Code; Claude Code's own surface is unchanged.

### What this is NOT

- **Not a plugin framework or SDK** — no API, no extension model. Just hooks, skills, and agents.
- **Not Anthropic-affiliated** — community-built. Not the same project as `oh-my-claudecode` (separate Node-based tool).

## How is this different from vanilla Claude Code?

| | Vanilla Claude Code | oh-my-claude |
|---|---|---|
| **Quality enforcement** | None | Hard stop gates |
| **Intent classification** | None | 5-category state machine |
| **Domain coverage** | Code-focused | Coding, writing, research, ops |
| **Dependencies** | — | bash + jq |
| **Agent safety** | Unrestricted | `disallowedTools` enforced |
| **Session continuity** | Lost on compaction | Pre/post-compact hooks |
| **Architecture** | Monolithic | Harness hooks |

See real catches in [`docs/showcase.md`](docs/showcase.md) — sessions where the gates intercepted defects before ship.

---

## Quick start

Requires `jq` and `rsync`. macOS: `brew install jq` (`rsync` is preinstalled). Debian/Ubuntu: `apt install jq rsync`. `install.sh` hard-fails if `jq` is missing.

```bash
# Pinned install (recommended — install-remote.sh prints the current tag tip):
OMC_REF=v1.49.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh)"

# Rolling install (tracks main HEAD — fine for trying things; pin a tag for prod):
curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh | bash

# Verified remote install (tag pin + expected commit prefix before install.sh runs):
OMC_REF=v1.49.0 \
OMC_EXPECTED_SHA=<release-commit-sha-or-prefix> \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/X0x888/oh-my-claude/main/install-remote.sh)"

# OR manual clone (audit before installing — strongest supply-chain posture):
git clone --branch v1.49.0 https://github.com/X0x888/oh-my-claude.git ~/.local/share/oh-my-claude
bash ~/.local/share/oh-my-claude/install.sh
```

The remote bootstrap path runs `verify.sh` automatically before it exits; a successful run should print `Errors: 0`.

<details>
<summary><b>Verified / hardened install</b> — supply-chain posture for the cautious (click to expand)</summary>

Re-running the same one-liner against an already-current canonical install verifies and exits without a reinstall when nothing changed; set `OMC_FORCE_REINSTALL=1` if you explicitly want to force `install.sh`. If you use the verified remote path, `OMC_EXPECTED_SHA` accepts any 7-40 char commit prefix and `install-remote.sh` refuses to run `install.sh` unless the cloned tree matches it. If you use the manual clone path above, run `bash ~/.local/share/oh-my-claude/verify.sh` yourself before restarting Claude Code.

Use the manual clone path when you want the strongest supply-chain posture. Use the verified remote path when you still want a one-liner but do not want to trust a tag name alone; copy the SHA from the GitHub release's `Verified bootstrap install` / `Trusted release commit` block and pass it via `OMC_EXPECTED_SHA`. That release body is the authoritative user-facing source for the trusted SHA. GitHub releases also ship attached source bundles (`oh-my-claude-vX.Y.Z.tar.gz`, `oh-my-claude-vX.Y.Z.zip`) plus `oh-my-claude-vX.Y.Z.SHA256SUMS` for checksum-based download verification, and the repo publishes GitHub artifact attestations for those assets so professional consumers can verify provenance with `gh attestation verify` or the bundled `tools/verify-published-release.sh` helper (full published-release audit, including optional attestation wait) after the release-attestation workflow completes. _Maintainers:_ release + distribution automation tooling (`tools/verify-*-readiness.sh`, surface staging, deployment-candidate prep, `--json` audit modes) lives in [Release & distribution tooling](#release--distribution-tooling-maintainers) below and [`CONTRIBUTING.md` § Release Process](CONTRIBUTING.md#release-process) — not part of the install path.

</details>

### Is this safe?

Fair question for a tool that hooks every prompt and runs bash on your machine. Short answers: **100% local** (no network egress, no telemetry endpoint — the only network activity is the `git clone` you invoke); **inspection/judgment agents cannot use Claude Code's direct editor tools** (all 26 deny `Write`, `Edit`, `MultiEdit`, and `NotebookEdit` and request plan mode; Bash remains available for inspection/tests and follows the active permission mode); **permission prompts stay on** (bypass is a separate explicit opt-in); **repo-owned oh-my-claude conf cannot flip protected flags** (the parser deny-lists them, while `verify.sh` separately checks Claude Code's user and current-project `disableAllHooks` settings); **everything it persists is local, redacted, and opt-out** (`/omc-config` → Minimal turns all telemetry off). Claude Code project settings and administrator-managed policy can intentionally disable user hooks; that platform boundary is stated in [SECURITY.md](SECURITY.md), alongside the full four-question trust answer.

After install, two mandatory steps:

1. **Restart Claude Code.** Hooks load at session start — `/ulw` silently no-ops in your current session until you restart.
2. **Try it**: `/ulw-demo` (about 90 seconds, fires the gates on a real edit), then `/ulw <your task>` for real work in any domain.

That's enough to feel the harness work. When you want more:
- **Configure** with `/omc-config` *inside Claude Code* — the default install is the **Balanced** profile (low-friction defaults; planning/review agents inherit the session's main model, Sonnet for execution). For the strongest opinionated posture, run `/omc-config` and pick **Zero Steering** (quality model tier, all bias-defense directives, watchdog on, adaptive strict gates for high-risk work). Auto-detects first-time setup vs upgrade.
- **Verify on-disk install** with `bash ~/.local/share/oh-my-claude/verify.sh` from your terminal — useful when something feels off.

### When stuck — which deferral verb?

Three skills, three different "I can't keep going" cases. NOT interchangeable:

| Symptom | Verb |
|---|---|
| Gate fired but the work is genuinely complete (false positive) | `/ulw-skip <reason>` |
| Discovered-scope flagged real findings *(under ULW with default `no_defer_mode=on`: agent ships inline; opt out via `no_defer_mode=off` for legacy soft-defer)* | `/mark-deferred <named-WHY>` |
| Blocked on a real operational input — credentials, login, infra down, rate limit hit | `/ulw-pause <reason>` |

Escalation order before any of these fires (v1.40.0): ship inline → wave-append → reject-as-not-a-defect → pause-for-operational-block. Taste/policy/credible-approach calls are the agent's under ULW (`no_defer_mode=on`). The full decision tree (symptoms, when-NOT-to-use, validator-acceptable WHY shapes) is the single source of truth in `~/.claude/quality-pack/memory/skills.md` — loaded into every session, so the model already has it; also surfaced via [`/skills`](#available-skills).

Both install paths keep Claude Code's permission prompts on; once you trust the harness, [`--bypass-permissions`](#power-user-setup) removes them. Quality gates apply either way.

Reversible: `bash ~/.local/share/oh-my-claude/uninstall.sh` removes everything cleanly (timestamped backups stay under `~/.claude/backups/`).

Already in Claude Code and want to skip the manual steps? See [AI-assisted install](#ai-assisted-install) below.

## AI-assisted install

Already in Claude Code? Paste one of these prompts directly. Each is self-contained, but the canonical step-by-step lives in the cloned repo's [`AGENTS.md` § "Agent Install Protocol"](AGENTS.md#agent-install-protocol--installing-or-updating-oh-my-claude) — the prompts point there so the README and the protocol don't drift.

**First-time install:**

> Install oh-my-claude. Do these in order:
> 1. Clone `https://github.com/X0x888/oh-my-claude.git` into `~/.local/share/oh-my-claude` (canonical path — matches the curl-pipe-bash bootstrapper).
> 2. Read `~/.local/share/oh-my-claude/AGENTS.md` § "Agent Install Protocol" and follow it end-to-end.
> 3. Use `--model-tier=balanced` (don't ask me).
> 4. After `verify.sh` passes, quote its "What next?" footer back to me verbatim — do not paraphrase.
> 5. Tell me explicitly to restart Claude Code and run `/ulw-demo` in the new session. Hooks won't fire in this current session.
> 6. If the protocol finds an existing install, ask whether I mean reinstall or update. If the canonical clone path belongs to another repo, or if `install.sh` / `verify.sh` fails, stop and show me the issue instead of forcing ahead.
> 7. If I explicitly ask for the curl-pipe-bash route instead of a manual clone, use the tag-pinned `install-remote.sh` path with `OMC_EXPECTED_SHA=<trusted release commit sha/prefix>` rather than rolling `main`, and source that SHA from the GitHub release's `Verified bootstrap install` / `Trusted release commit` block.

**Update an existing install:**

> Update oh-my-claude. Read `repo_path=` from `~/.claude/oh-my-claude.conf`, then follow `<repo_path>/AGENTS.md` § "Agent Install Protocol" → Step 2 (Update). After running `install.sh` and `verify.sh`, use the helper-backed update summary from the protocol and tell me whether to restart Claude Code only if the helper says it is required. If `verify.sh` fails, stop and show me the output; do not give restart advice or the `What next?` footer.

## Updating an existing install

```bash
cd ~/.local/share/oh-my-claude     # or your repo_path from ~/.claude/oh-my-claude.conf
git pull && bash install.sh
bash verify.sh
```

Restart Claude Code only when the install outcome says it is required; the `install.sh` post-install summary now tells you directly, still lists orphans if files were removed, and for real updates prints a standardized summary with prior/current install refs plus commits since the previous installed SHA.

Prefer the one-liner update path? Re-running `install-remote.sh` against the canonical clone now fast-paths the already-current case: it verifies the live install and exits without reinstalling when the repo and installed bundle are already in sync. When it does perform a real update, it now prints an update summary with the prior/current install refs, restart decision, and commits since the prior installed SHA. Set `OMC_FORCE_REINSTALL=1` to bypass the already-current guard.

Need a machine-readable preflight or post-update summary? `bash ~/.local/share/oh-my-claude/tools/install-state-report.sh --json` refreshes `origin` and reports `installed_version`, `latest_tag`, `last_install_at`, whether the clone is already current, the last install's `restart_required` decision, and the installer-recorded previous/current refs plus commit summary for the last update. For standardized human-facing text, the same helper exposes `--already-current-summary`, `--last-update-summary`, and `--restart-guidance`; those are the canonical lines consumed by `install-remote.sh`, `install.sh`, and `verify.sh`.

Your `--model-tier` preference persists in `~/.claude/oh-my-claude.conf` and re-applies automatically. The statusline shows a yellow `↑v<version>` arrow when the source repo is ahead of the installed bundle — re-run `install.sh` to sync.

`install.sh` overwrites bundled files but preserves `settings.json` merges, `omc-user/overrides.md`, and custom agents or skills whose names are outside the bundle. Hand-edited files in `quality-pack/memory/` get a pre-rsync warning so you can migrate edits to `omc-user/overrides.md` before they're overwritten. See FAQ: [*How do I update?*](docs/faq.md#how-do-i-update-oh-my-claude) and [*Will updating overwrite my changes?*](docs/faq.md#will-updating-overwrite-my-changes) for the full safety matrix.

**Install flags (v1.36.0+):**
- `--no-ghostty` / `--with-ghostty` — skip or force-install Ghostty theme/config. Default auto-detects: only seeds `~/.config/ghostty/` when that directory already exists.
- `--keep-backups=N` (default `10`) — prune older `oh-my-claude-*` backup directories after install. `--keep-backups=all` disables pruning. Closes the unbounded-accumulation surface during patch cascades.

Reversible: `bash ~/.local/share/oh-my-claude/uninstall.sh` removes everything cleanly. Backups of pre-install settings live at `~/.claude/backups/oh-my-claude-<timestamp>/` (auto-pruned per `--keep-backups`; the most recent always survives).

## Troubleshooting

The first 60 seconds of common failure modes:

| Symptom | First check |
|---|---|
| `install.sh` exits with `jq: command not found` | Install `jq` first (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu) and re-run `install.sh`. |
| `install-remote.sh` exits with `missing required command: ...` | Install the named prerequisite and re-run the bootstrapper. For `jq`, the bootstrapper may offer an auto-install on supported systems; otherwise use your package manager. |
| `install-remote.sh` says `Refusing to run the wrong installer` | The target clone path already points at a different repo. Move/remove that checkout, or re-run with `OMC_SRC_DIR=<different path>` if you intentionally want to keep both. |
| `install-remote.sh` says `post-install verification failed` | The source repo is still on disk. Fix the verifier errors shown above, then re-run the printed `verify.sh` path (or `install.sh` if you changed bundled files) instead of recloning. |
| `verify.sh` reports errors | Re-run `bash install.sh`, then `verify.sh` again. Most failures are stale install or missing `jq`/`rsync`. |
| `/ulw` does nothing in your current session | You skipped the **restart Claude Code** step. Already-running sessions keep the previous hook wiring — open a new session. |
| `/ulw-demo` doesn't block at Step 3 | Install is stale (re-run `bash install.sh`) or `/ulw-off` was called earlier in the session. |
| Hooks fire but no behavior changes | Same root cause as the "current session" row above — restart needed. |
| Yellow `↑v<version>` arrow in the statusline | Source repo is ahead of the installed bundle. Run `git pull && bash install.sh` from the source repo to sync. |

For deeper issues, see [FAQ](docs/faq.md) — anomaly logs, config recovery, and per-gate disabling are documented there.

---

## The problem

Claude Code is powerful, but out of the box it cuts corners in predictable ways:

- **It writes code but doesn't test it.** You get a diff that looks right, breaks in practice, and you're the one who finds out.
- **It stops before work is actually done.** "I've made the changes" -- but there's no review, no verification, no evidence it works.
- **It defers unfinished work to "a future session."** Wave 1 done, Wave 2 is next. Except Wave 2 never happens.
- **It gives surface-level advice without reading actual code.** Generic patterns instead of grounded analysis of what's in front of it.
- **It chains tool calls without thinking between them.** Mechanical sequences that look productive but skip the reasoning that catches mistakes.
- **It only works well for coding.** Ask it to write a proposal, research a decision, or plan an initiative and it falls back to code-shaped workflows.

These aren't edge cases. They're the daily experience of anyone using Claude Code for real work.

## What oh-my-claude does

oh-my-claude enforces cognitive quality through structure, not prompt engineering. Instead of asking Claude to please think harder, it installs bash hooks that intercept Claude Code's lifecycle events -- prompt submission, session compaction, stop attempts -- and injects domain-aware context, quality requirements, and hard gates that Claude cannot bypass.

The result: Claude classifies your intent before acting, routes work to specialist agents, can require a fresh-context specialist before implementation when the opt-in agent-first gate is enabled, thinks between tool calls, and blocks initial completion attempts while active review or verification gates are unresolved. If a safety cap is exhausted, the unresolved gap is surfaced instead of trapping the session indefinitely.

## Feature highlights

### Hard quality gates

**Missing verification or review blocks completion attempts.** Skip tests, skip the generic reviewer for an edited code/prose surface, defer work to a "future session" without a checkpoint, miss prompt-stated commit/push obligations, or leave a semantically required specialist review uncovered — each initially hard-stops completion. Caps prevent infinite loops: if Claude cannot satisfy a gate, it eventually surfaces the unresolved gap instead of spinning.

### Agent-first execution

**Opt-in (v1.43+).** When `agent_first_gate=on`, `/ulw` execution requires Claude to dispatch and wait for a fresh-context shaping specialist before the first workspace mutation — read-only inspection still works, but `Edit`/`Write`/`MultiEdit`/`NotebookEdit` and common mutating Bash commands block until a planner, domain specialist, challenge agent, researcher, writer, or lens has returned. Post-hoc reviewers do not satisfy this floor.

**Default is `off`** because the mandate was firing ~2.2x/session under `model_tier=quality` (where execution agents are at least Opus and deliberators inherit the main model, so the gate no longer buys a reliable smartness gap) and the depth-on-every-prompt rule + sub-dispatch-as-tool guidance in `~/.claude/quality-pack/memory/model-robustness.md` now carry the actual concern. Turn it on via `/omc-config` when training a new workflow habit, running on `model_tier=economy`, or when the active session is drift-prone on a single surface. First-mutation telemetry remains available in both modes: exact editor attempts are stamped PreTool, while default-off Bash is stamped after an actual mutation is observed; the block counter increments only when the enabled gate blocks.

### Adaptive review coverage

**Review follows the current objective's edited surfaces and semantic risk, not a standing file-count chain.** Generic code quality and prose review remain universal for their respective surfaces. The stop-hook adds specialist dimensions only when they apply:

- `quality-reviewer` — bug hunt, code quality
- `design-reviewer` — design quality when a current-objective UI-shaped edit is paired with UI/visual intent or broader complex/active-wave scope (web plus high-confidence Apple and Android UI paths)
- `excellence-reviewer` — completeness for broad/open, cross-surface-at-threshold, current-complex-plan, active Phase 8 wave-plan, or unknown-scope work
- `editor-critic` — doc clarity and accuracy
- `briefing-analyst` — traceability for sufficiently broad cross-surface or active-wave changes

Metis stays where its competence belongs: plan-phase pressure testing, optionally enforced by `metis_on_plan_gate`, rather than being forced after an arbitrary number of edited files. Each gate block message names the missing coverage and its best reviewer. A `VERDICT: CLEAN|SHIP|FINDINGS (N)` line tells the hook whether that reviewer's own dimension was ticked; specialist clocks cannot satisfy or erase the generic review. Reviewer dispatches and Bash/MCP verification calls snapshot the relevant code/plan generation at start; an edit that lands while either is in flight makes that result stale instead of letting completion time relabel old evidence as current. A fresh-objective edit-log boundary prevents earlier work from inflating the current review, and each dimension follows its relevant code, document, UI, aggregate edit, or plan revision. UI-looking files do not create a design tax on a new logic-only objective: visual/UI semantics, explicit breadth, a current complex plan, or an active Phase 8 wave must also make design judgment material. Source-form writing and research files (`.tex`, `.bib`, `.typ`, `.qmd`, `.rmd`) route with prose. Doc-only edits route straight to `editor-critic` and skip the code-verification gate, so fixing a typo in CHANGELOG doesn't re-trigger `npm test`.

### Intent classification

**Every prompt is classified by intent and domain before Claude acts.** Five intent categories (execution, continuation, advisory, checkpoint, session-management) crossed with six domains (coding, writing, research, operations, mixed, general). Advisory questions get answered directly; execution prompts get the full specialist pipeline. A **prompt-text trust override** in the PreTool guard re-reads the user's prompt when the classifier disagrees, so destructive ops the prompt clearly authorized aren't blocked by mis-routing.

Five **bias-defense directive layers** (conf-gated) defend against under- and over-interpretation: `prometheus_suggest` and `intent_verify_directive` (declare-and-proceed on short unanchored prompts); `exemplifying_directive` (treat example-marked items as one of a class, enumerate siblings); `intent_broadening` (project-surface inventory reference so a prompt that names some surfaces doesn't silently miss the rest); `divergence_directive` (enumerate 2-3 paradigm framings inline before committing on shape-decisions). All compose under `directive_budget` (`balanced` default — trims lower-priority directives when prompt tax gets dense). `quality_policy=zero_steering` adds adaptive strictness for users who want minimal-prompt autonomous shipping: high-risk work keeps blocking until proof is green, while small work stays compact. ULW's default `no_defer_mode=on` also keeps serious missing work blocking after gate caps, so complex tasks cannot end by scorecard-release, narrowed scope, or future-session handoff. Hard backstops: `exemplifying_scope_gate` blocks Stop until each enumerated sibling is marked shipped or consciously declined. Per-flag detail and tuning lives in [`docs/customization.md`](docs/customization.md).

Reviewer findings are machine-readable (single-line `FINDINGS_JSON` block before each VERDICT). Hot-path hook latency is budgeted in `check-latency-budgets.sh` so speed regressions surface before merge.

### Multi-domain routing

**Each domain has its own specialist chain — not a coding tool that happens to accept prose.**

- **Coding** -- quality-planner for scoping, quality-researcher for context, specialist developers (frontend, backend, fullstack, iOS, DevOps, test), universal quality-reviewer plus surface/semantic reviewers when applicable
- **Writing** -- writing-architect for structure, draft-writer for content, editor-critic for polish
- **Research** -- librarian for source gathering, briefing-analyst for synthesis, metis for stress-testing conclusions
- **Operations** -- chief-of-staff turns vague asks into structured deliverables, action plans, and decision memos

### Session continuity

**Objectives, decisions, review state, and the done-contract survive context compaction — you don't lose the plot mid-task.** Pre- and post-compact hooks snapshot the working state. Domain classification, accepted decisions, specialist conclusions, in-flight dispatches, pending review obligations, and the remaining contract obligations all carry over. When the session resumes, context is rehydrated — not reconstructed from scratch.

### Permissioned agents

**37 specialist agents — 26 are configured for inspection/judgment; the 11 that build retain editor tools.** The 26 inspection/judgment specialists carry `disallowedTools: Write, Edit, MultiEdit, NotebookEdit` plus `permissionMode: plan`: they cannot invoke Claude Code's direct file/notebook editors. Bash remains available because inspection and verification need `git diff`, targeted tests, and build checks; it is not an OS-level no-write sandbox and remains governed by the active Claude Code permission mode (parent `acceptEdits`, `auto`, or bypass modes can take precedence). The 11 domain builders (frontend-developer, backend-api-developer, the ios-* family, fullstack-feature-builder, devops-infrastructure-engineer, test-automation-engineer, research-data-analyst, atlas) retain editor tools by design, under that same permission model.

### Walk-away goals (`omc` CLI)

**Fire an ambitious goal from a bare shell prompt and come back to finished, verified work — no Claude Code session left open.** `omc "make the error handling in this module actually robust"` derives the acceptance criteria a senior would insist on, runs `/ulw`-armed headless work passes (the full ambient harness — routing, gates, reviewer chain — rides along inside every pass), verifies each criterion on ground truth (mechanical checks run for real; judgment criteria get a fresh read-only critic), and only declares done after a skeptical final diff review comes back clean. Cost- and iteration-capped, git-required by default, honest ✅/❌ close with evidence per criterion, and every run records to `omc runs` for later inspection. Installed at `~/.claude/bin/omc` (symlinked into `~/.local/bin` when present).

### Project Council

**Solo developers get the right cross-functional perspective without paying for a standing panel.** `/council` first maps the coverage the question actually needs, considers the full specialist roster, and records why relevant perspectives were included or skipped. It dispatches the smallest sufficient primary team concurrently — normally one to four agents, with one valid for a narrow specialist audit; a larger team is allowed only when the ledger records the cost and every independent high-impact competence need. The locked coverage lifecycle starts primary-only, records exact-objective returns, requires row-by-row reconciliation before it can add up to two gap-fill specialists, and refuses to mark the assessment ready until every selected round has returned and final reconciliation exists. Namespaced identities match exactly; unnamespaced installed names bind once, preventing same-short-name plugins from borrowing each other's mandate. The `[council:primary]`, `[council:gap-fill]`, and `[council:verification]` prefixes are phase/provenance tags, not agent-name templates or a fixed cast. Up to three load-bearing findings are checked by independent, competence-matched verifiers. `--polish` and `--self-audit` bias the coverage map rather than forcing named rosters; `--deep` escalates selected Sonnet-backed agents without downgrading agents that inherit a stronger main model. Broad prompts such as "evaluate my project" still auto-trigger under `/ulw`; a focused feature, capability, surface, or subsystem does not automatically inflate into a whole-project council.

Assessment and implementation are separate decisions. Only a successfully completed, fully reconciled advisory Council arms a handoff, and only the immediately following matching prompt—such as “implement the recommendations”—can consume it; an intervening prompt expires it. Bare `implement` or `ship` authorizes execution of the assessed scope. Full-scope expansion follows the canonical `is_exhaustive_authorization_request()` predicate: explicit all/every/everything forms, exhaustive implementation wording, a high-bar target, or binary-quality framing can authorize it; thorough assessment wording alone cannot. Otherwise the normal scope-expansion pause applies.

### Distinctive UI by default

**Ask for a landing page or semantically visual/UI work and you get a 9-section Design Contract — palette with hex values, typography rules, component states, layout, depth, do's & don'ts — before UI code is written.** Concrete commitments instead of generic shadcn-default aesthetics. Scope-aware: a "build a page" prompt gets the full contract; a "fix the button padding" prompt preserves existing tokens; a logic-only edit in a UI-shaped file does not automatically turn into a redesign. Skip with `no design polish` for backend/internal work.

15 brand archetypes (Linear, Stripe, Vercel, Notion, Apple, Airbnb, Spotify, Tesla, Figma, Discord, Raycast, Anthropic, Webflow, Mintlify, Supabase) are framed as *anti-anchors* — the agent picks a coherent starting point and commits to what it will do *differently*. Cross-session archetype memory prevents the same anchor from being picked twice on the same project. Inline contract emission lets `design-reviewer` and `visual-craft-lens` grade drift even when no `DESIGN.md` exists at the project root. Inspired by [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md).

### Zero dependencies

**No npm. No TypeScript. No Node.js runtime. No plugin framework.** The entire harness is bash scripts and `jq`. It works anywhere Claude Code runs, installs in seconds, and leaves no footprint beyond the `~/.claude/` directory.

## Usage examples

**Coding**
```
/ulw debug why settings saves but shows stale data until refresh
```

**Writing**
```
ulw draft a project proposal for an AI-assisted research workflow
```

**Research**
```
/ulw compare server-session auth vs JWT and recommend one
```

**Operations**
```
ulw turn these meeting notes into an action plan and follow-up email
```

**Project evaluation**
```
/council
/ulw evaluate my project and plan for improvements
```

---

## How it works

When you submit a prompt, the intent router (`prompt-intent-router.sh`) classifies it by intent category and domain, then injects the appropriate context and specialist instructions into Claude's working memory. Claude processes the task using the routed specialist agents -- each scoped to its domain and constrained by permission boundaries. When Claude attempts to stop, the stop guard (`stop-guard.sh`) checks whether review, verification, and final-closeout obligations are met. If they aren't, the stop is blocked and Claude is told exactly what's missing.

The core state machine (`common.sh`) handles intent classification, domain scoring, session state tracking, and the quality gate logic. All state is managed in bash -- no external services, no databases, no background processes.

For the full architecture, see [docs/architecture.md](docs/architecture.md).

## Repository structure

```
oh-my-claude/
├── install.sh / uninstall.sh / verify.sh   # Install, remove, and verify
├── bundle/dot-claude/                       # Installs to ~/.claude/
│   ├── agents/          (37 agents)         # Specialist agent definitions
│   ├── skills/          (34 skills)         # Skill definitions + autowork hooks
│   ├── quality-pack/                        # Lifecycle hooks + memory files
│   ├── output-styles/                       # Two bundled styles: oh-my-claude (default) + executive-brief (see docs/customization.md#output-style)
│   └── statusline.py                        # Custom statusline widget
├── config/settings.patch.json               # Merged into user settings on install
├── evals/realwork/                           # Outcome eval scenarios for minimal-prompt shipping across code + design/UI + native artifacts + mixed + quantitative/data-analysis + regulated/high-stakes + writing + research + scholarly + ops + advisory
├── tests/               (147 bash + 1 py)   # See CLAUDE.md for canonical commands
├── tools/                                    # Developer-only tools (not installed)
└── docs/                                    # Architecture, customization, FAQ, prompts
```

For repo-internal architecture and contribution conventions, see [AGENTS.md](AGENTS.md) (architecture, state I/O, agent VERDICT contract) and [CONTRIBUTING.md](CONTRIBUTING.md) (testing, release process).

> **Why `dot-claude` instead of `.claude`?** Claude Code's permission system treats paths containing `.claude/` as sensitive, triggering prompts on every edit during development. The installer copies `bundle/dot-claude/` into `~/.claude/` on your machine. Same pattern as oh-my-zsh, chezmoi, etc.

### Available skills

Skills are invoked as slash commands or routed automatically by the intent classifier.

| Skill (mnemonic) | Command | Purpose |
|---|---|---|
| **Run a task** | | |
| ulw | `/ulw <task>` | Maximum-autonomy professional workflow |
| goal *(relentless drive)* | `/goal <objective>` | Persistent goal driven relentlessly across turns until verifiably achieved or a no-progress stuck-wall (Codex `/goal` port). Activates the full ULW harness itself (single entrance, v1.47) — and you usually don't need it: a `/ulw` prompt with an explicit goal declaration ("don't stop until tests pass") auto-arms the same driver (`goal_auto_arm`). Lifecycle: pause/resume/clear/done. |
| **Think before acting** | | |
| plan-hard *(plan)* | `/plan-hard <task>` | Decision-complete planning without edits |
| prometheus *(interview)* | `/prometheus <goal>` | Interview-first planning for ambiguous work |
| metis *(stress-test)* | `/metis <plan>` | Pressure-test a plan for hidden risks |
| oracle *(second opinion)* | `/oracle <issue>` | Deep debugging or architecture second opinion |
| diverge *(expand option space)* | `/diverge <task>` | Generate 3-5 alternative framings BEFORE commit (v1.31.0; upstream of convergent critics). v1.32.0: also auto-suggested under `/ulw` on paradigm-shape prompts via the `divergence_directive` (X-vs-Y, "how should we", "best way to model X", etc.) — inline 2-3 framings is the default; explicit `/diverge` is the escalation. |
| librarian *(docs lookup)* | `/librarian <topic>` | Official docs and reference research |
| **Review & evaluate** | | |
| review-hard *(review)* | `/review-hard [focus]` | Findings-first code review |
| research-hard *(research)* | `/research-hard <topic>` | Targeted context gathering |
| council *(adaptive evaluation)* | `/council [focus] [--deep]` | Coverage-map-driven evaluation from the full agent roster: normally 1–4 concurrent primary specialists (larger only for evidenced independent needs), optional 0–2 gap-fill, and competence-matched verification of up to 3 findings. A same-turn request or the immediate follow-up to a completed assessment can enter **Phase 8**; exhaustive scope still requires explicit authorization. `--deep` escalates selected Sonnet-backed agents only. |
| **Build** | | |
| frontend-design *(visual craft)* | `/frontend-design <task>` | Distinctive design-first frontend work |
| **Research & science** | | |
| data-analysis *(scientific analysis)* | `/data-analysis <task>` | Experimental data analysis to peer-review standard — fitting with honest uncertainties, provenance run-manifests, publication figures checked against journal specs (backed by the `research-data-analyst` agent + `research-craft/` doctrine) |
| lit-review *(verified literature)* | `/lit-review <topic>` | Academic literature review where every source is registry-verified (Crossref/OpenAlex/Semantic Scholar/arXiv) before it is returned — the `literature-scout` agent never cites from model memory |
| manuscript *(papers & theses)* | `/manuscript <task>` | Academic writing workflow: structure (writing-architect) → verified citations (literature-scout) → draft (draft-writer) → prose + rigor critique (editor-critic, rigor-reviewer). Includes referee-response mode |
| swiftui-pro *(SwiftUI review, model-invoked)* | *(no slash command — auto-fires on SwiftUI work)* | Comprehensive SwiftUI review: modern API usage (`foregroundStyle` not `foregroundColor`, `Tab` not `tabItem()`, etc.), accessibility, data flow, navigation, design, performance, Swift idioms, hygiene. Partial-load via topic-scoped requests. Vendored from [`twostraws/SwiftUI-Agent-Skill`](https://github.com/twostraws/SwiftUI-Agent-Skill) v1.1 (MIT, Paul Hudson). |
| gamedev *(game-dev review, model-invoked)* | *(no slash command — auto-fires on Unity/Godot/web game work)* | Engine-idiomatic review + guidance for Unity (C#), Godot (GDScript/C#), and web engines (Phaser/Babylon/PixiJS/Three.js): frame-budget perf, update-loop hygiene, object pooling, and the frame-grounded run→capture→evaluate→fix loop. Per-engine partial-load references; recommends Unity MCP / Godot MCP / [godogen](https://github.com/htdt/godogen). Original (not vendored). |
| atlas *(repo bootstrap)* | `/atlas [focus]` | Bootstrap or refresh repo instruction files |
| **Configure** | | |
| omc-config *(setup walkthrough)* | `/omc-config [setup\|update\|change]` | Multi-choice walkthrough for `oh-my-claude.conf` flags. Auto-detects first-time setup vs upgrade vs ad-hoc change. Picks a profile (Zero Steering / Balanced / Minimal) or fine-tunes individual flags — no typing required. Triggered by phrases like "help me install", "configure oh-my-claude", "update my settings". |
| **Workflow control** (mid-session) | | |
| ulw-demo *(onboarding)* | `/ulw-demo` | Guided walkthrough with real quality gates |
| ulw-status *(diagnostics)* | `/ulw-status` | Show current session state, the persisted done-contract and remaining obligations, Council Phase 8 wave-plan progress, and live timing/directive-surface totals. `summary` / `classifier` arguments swap modes. |
| ulw-time *(time distribution)* | `/ulw-time [current\|last\|last-prompt\|week\|month\|all]` | Polished end-of-turn time card — stacked top bar (`█` agents · `▒` tools · `░` idle), per-bucket ASCII chart, and a one-line insight (anomaly / dominance / reassurance / fun fact). The same card auto-emits as Stop `systemMessage` above the 5s noise floor; manual invocations slice a different window or bypass the floor. |
| ulw-report *(retrospective)* | `/ulw-report [last\|week\|month\|all]` | Markdown digest of cross-session activity — sessions, gate fires, bias-defense fires, router directive footprint, top reviewers, classifier misfires, Serendipity catches, finding/wave outcomes |
| memory-audit *(memory hygiene)* | `/memory-audit [--memory-dir <path>]` | Classify MEMORY.md entries (load-bearing, archival, superseded, drifted) and propose rollup moves. Read-only. |
| whats-new *(changelog delta)* | `/whats-new` | Show CHANGELOG entries between your installed version and the source repo HEAD. Surfaces post-install features without `cat CHANGELOG.md`. (v1.36.x) |
| omc-doctor *(install health)* | `/omc-doctor` | One-shot install health check against the installed `~/.claude` tree — core files, CLAUDE.md @-includes, hook wiring, state-root writability — from any directory, no source clone needed. Claude Code fails open on hook errors, so a broken install is silently inert; this makes it visible. (v1.48) |
| ulw-skip *(skip a gate)* | `/ulw-skip <reason>` | Skip current quality gate block once |
| ulw-correct *(fix a misclassification)* | `/ulw-correct <correction>` | Tell the harness "the last turn was misclassified" — records the misfire and updates intent/domain when parseable. (v1.40.x) |
| mark-deferred *(triage findings)* | `/mark-deferred <reason>` | Bulk-defer pending discovered-scope findings with a one-line reason — legacy soft-defer path. **Refused under ULW execution with default `no_defer_mode=on`** (v1.40.0); the agent ships inline, wave-appends, or rejects as not-a-defect instead. Opt out via `no_defer_mode=off` for the v1.39 behavior |
| ulw-pause *(operational-block pause)* | `/ulw-pause <reason>` | Declare an operational block — credentials/login, hard external blocker, destructive shared-state action, unfamiliar in-progress state. NOT for taste/policy/credible-approach (v1.40.0: agent owns those under ULW). Cap 2/session |
| ulw-resume *(post-rate-limit recovery)* | `/ulw-resume [--peek \| --list \| --session-id <sid> \| --dismiss]` | Atomically claim and replay the most relevant unclaimed `resume_request.json` — picks up a /ulw task that a Claude Code rate-limit kill interrupted. `--dismiss` suppresses the SessionStart hint without resuming. Pairs with the SessionStart resume-hint hook (Wave 1) and the headless watchdog (Wave 3). |
| ulw-off *(deactivate)* | `/ulw-off` | Deactivate ultrawork mode mid-session |
| skills *(this list)* | `/skills` | List all available skills with usage guide |

> The mythology-named skills (atlas, metis, oracle, prometheus, librarian) carry one-word mnemonics — see [`docs/glossary.md`](docs/glossary.md) for the rationale behind each name.
>
> `/ulw` is the canonical user-facing name. The legacy aliases `/autowork`, `/ultrawork`, and `sisyphus` remain wired in the classifier for muscle-memory continuity but new prompts and docs should lead with `/ulw`. (v1.31.0 — naming consolidation.)

### Auto-routed vs. manual escape hatches

**You don't have to learn the slash commands.** Here's what runs without you typing anything:

| Tier | Mechanism | What you get |
|---|---|---|
| **Hook-fired (mandatory)** | Fires automatically — you can't bypass it | `quality-reviewer` before code stop; `editor-critic` for prose/source-doc edits; `design-reviewer` when UI-shaped changes are semantically design-relevant (including native UI); `excellence-reviewer` for broad/open, cross-surface-at-threshold, current-complex-plan, active Phase 8 wave-plan, or unknown-scope work |
| **Model-invoked (Claude Code native auto-load)** | Auto-loaded by Claude Code when the open files or prompt match a skill's frontmatter description; no router, no hook | `swiftui-pro` on SwiftUI work (vendored from `twostraws/SwiftUI-Agent-Skill`); `gamedev` on Unity/Godot/web game work |
| **Router-suggested (reasoning)** under `/ulw` | Injected as a directive when prompt signals match | `prometheus`, `quality-planner`, `quality-researcher`, `librarian`, `metis`, `oracle` |
| **Router-suggested (engineering)** under `/ulw` | Same mechanism — extended to engineering specialists in this release | `backend-api-developer`, `devops-infrastructure-engineer`, `test-automation-engineer`, `fullstack-feature-builder`, `ios-ui-developer`, `ios-core-engineer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`, `abstraction-critic` |
| **Auto-dispatched on prompt pattern** | An entire workflow (multi-agent + gates) fires when the router detects the pattern | `/council` for broad project-evaluation prompts, the 9-section Design Contract on UI work |
| **Manual control/diagnostic** *(by design)* | You declare intent — auto-firing would be wrong | `/ulw-skip`, `/ulw-pause`, `/mark-deferred`, `/ulw-status`, `/ulw-time`, `/ulw-report`, `/ulw-off`, `/skills` |
| **Manual setup/audit** | One-time or occasional | `/atlas`, `/memory-audit`, `/ulw-demo`, `/omc-config` |

Most quality-boosting specialists are auto-suggested by the prompt-intent-router under `/ulw` based on prompt signals — `/ulw fix the auth bug` automatically nudges toward `oracle` for hard debugging, `librarian` for unfamiliar APIs, `quality-reviewer` before stop, and so on. You don't have to type `/oracle` to get Oracle — the slash command is the standalone escape hatch, not the only path in.

## Power-user setup

Once you've run `/ulw-demo`, watched the quality gates fire, and decided you trust the harness, you can remove Claude Code's per-tool approval prompts:

```bash
bash install.sh --bypass-permissions
```

This is opt-in. It skips Claude Code's built-in "allow this tool?" prompts so `/ulw` runs without interruption. The harness's quality gates (verification, reviewer dispatch, stop-guard) keep working — those are independent of Claude Code's confirmation layer. Switch back at any time by re-running `bash install.sh` without the flag.

Other install options:

```bash
bash install.sh --no-ios                # Skip iOS-specific agents
bash install.sh --model-tier=economy    # All agents use Sonnet (cheaper)
bash install.sh --model-tier=quality    # Execution agents on Opus; deliberators ride the session model (max quality)
bash install.sh --git-hooks             # Install post-merge auto-sync hook
bash ~/.claude/switch-tier.sh economy   # Switch tier post-install (from anywhere)
bash uninstall.sh                       # Cleanly remove the harness
```

`--git-hooks` installs a `post-merge` hook into this checkout's Git hooks
path (normally `.git/hooks/`; linked worktrees resolve to the shared hooks
directory) so `git pull` can detect bundle drift and remind you to re-run
`install.sh`. Set `OMC_AUTO_INSTALL=1` when merging to run the installer
automatically. The hook never overwrites a pre-existing non-oh-my-claude
`post-merge` hook.

### Recommended companion tools

These are independent, MIT-licensed tools that pair well with oh-my-claude. They are not bundled — install separately when relevant.

**[`ccusage`](https://github.com/ryoppippi/ccusage)** *(token + cost tracking, 14.7k stars)* — Parses Claude Code's local conversation logs and aggregates token usage and cost against a locked LiteLLM pricing snapshot. The 5-hour-block aggregation (`ccusage blocks`) matches Anthropic's actual rate-limit window. `ccusage statusline` is a Beta hook that renders compactly in Claude Code's statusline if you want cost visibility there.

```bash
bunx ccusage                      # one-shot: tokens + cost across recent sessions
bunx ccusage blocks               # 5-hour rate-limit-window aggregation
bunx ccusage statusline           # Claude Code statusline integration (beta)
```

Distributed as a native Rust binary via npm — `bunx`/`npx`/`pnpm dlx`/`pnpx`/Nix paths all work; no global install required. The 5-hour window matches Anthropic's rate-limit cap, so `ccusage blocks` is the most useful single command for "how close am I to the cap?". oh-my-claude already surfaces rate-limit headroom in the statusline and, as of v1.46-pre, **native token-count tracking** in `/ulw-time`, `/ulw-status`, and `/ulw-report` (per-prompt input/output/cache, split main-thread vs sub-agent — `token_tracking=on` by default); ccusage owns **dollar cost** aggregation. The division is deliberate: oh-my-claude tracks token *counts* (no pricing table to drift), ccusage tracks *cost* — complementary, not redundant.

**[`XcodeBuildMCP`](https://github.com/getsentry/XcodeBuildMCP)** *(iOS Xcode automation MCP, 5.7k stars, getsentry-maintained)* — MCP server exposing 82 manifest-driven tools grouped by workflow phase (build, test, simulator, device, debug, SwiftPM, scaffold, UI-automation). Recommended in the iOS agents (`ios-ui-developer`, `ios-core-engineer`, `ios-deployment-specialist`, `ios-ecosystem-integrator`) when executable Xcode operations beat shelling out via Bash.

```bash
npx -y xcodebuildmcp@latest mcp   # on-demand, no global install
npm install -g xcodebuildmcp      # global
```

Then add to Claude Code's MCP config per `https://xcodebuildmcp.com/docs/clients`. Requires macOS 14.5+, Xcode 16.x+, Node 18+. Sentry telemetry is on by default — opt out per `https://xcodebuildmcp.com/docs/privacy` if needed.

## Testing

The harness includes both a post-install verifier and dedicated test scripts:

```bash
bash verify.sh                              # Installation integrity check
bash tests/test-intent-classification.sh    # Intent routing logic
bash tests/test-quality-gates.sh            # Stop guard enforcement
bash tests/test-stall-detection.sh          # Loop detection
bash tests/test-e2e-hook-sequence.sh        # End-to-end hook sequence
bash tests/test-settings-merge.sh           # Install settings merge logic
bash tests/test-uninstall-merge.sh          # Uninstall settings cleanup logic
bash tests/test-common-utilities.sh         # Shared utility functions
bash tests/test-session-resume.sh           # Session resume cycle
bash tests/test-concurrency.sh              # Lock primitive stress test
bash tests/test-install-artifacts.sh        # Installed-file artifact assertions
bash tests/test-post-merge-hook.sh          # --git-hooks post-merge drift detection
bash tests/test-repro-redaction.sh          # omc-repro.sh privacy contract regression
bash tests/test-discovered-scope.sh         # Discovered-scope capture + wave-aware gate
bash tests/test-exemplifying-scope-gate.sh  # Example-marker scope checklist + stop gate
bash tests/test-finding-list.sh             # Council Phase 8 findings.json artifact
bash tests/test-state-io.sh                 # Extracted lib/state-io.sh module
bash tests/test-classifier.sh               # Extracted lib/classifier.sh module (symbol presence + smoke)
bash tests/test-classifier-replay.sh        # Classifier regression replay against curated fixtures
bash tests/test-serendipity-log.sh          # Serendipity Rule analytics logging
bash tests/test-cross-session-rotation.sh   # Cross-session JSONL aggregate cap helper
bash tests/test-show-report.sh              # /ulw-report skill backend (cross-session digest)
bash tests/test-install-remote.sh           # curl-pipe-bash bootstrapper (install-remote.sh)
bash tests/test-install-handoff.sh          # Fresh-install handoff contract (manual + bootstrap + AI-assisted docs)
bash tests/test-install-recovery.sh         # First-run recovery contract (missing prereqs + collision + verify failure)
bash tests/test-install-readiness.sh        # Top-level install/onboarding readiness audit wrapper
bash tests/test-phase8-integration.sh       # Council Phase 8 wave-cap wiring (record-finding-list ↔ stop-guard)
bash tests/test-verification-lib.sh         # Extracted lib/verification.sh module (symbol presence + smoke)
bash tests/test-agent-verdict-contract.sh   # Universal VERDICT contract regression net (all 37 agents)
bash tests/test-bias-defense-classifier.sh  # Bias-defense prompt-shape classifiers + plan-complexity extraction
bash tests/test-bias-defense-directives.sh  # prometheus-suggest + intent-verify directive injection
bash tests/test-ulw-benchmark-suite.sh      # Canonical ULW user-outcome scenarios across core intents + all six routing domains + native spreadsheet/deck/docx contracts
bash tests/test-zero-steering-policy.sh     # Adaptive zero-steering Stop/advisory/metis policy
bash tests/test-realwork-eval-suite.sh      # Outcome-oriented real-work eval schema + scorer across code + design/UI + native spreadsheet/presentation/docx artifacts + mixed + quantitative/data-analysis + regulated/high-stakes + writing + research + scholarly + ops + advisory
bash tests/test-professional-readiness.sh   # Top-level professional-readiness audit wrapper (classification + routing + UI design contracts + benchmark + realwork)
bash tools/verify-install-readiness.sh      # Canonical install/onboarding audit across bootstrapper + handoff + recovery + onboarding
bash tests/test-project-readiness.sh        # Top-level maintainer readiness audit wrapper (professional + install + distribution)
bash tools/verify-professional-readiness.sh # Canonical product-readiness audit across professional user classes
bash tools/verify-project-readiness.sh      # Canonical maintainer release-candidate audit across product + install + distribution readiness
bash tests/test-metis-on-plan-gate.sh       # Metis-on-plan stop-guard gate (Check 6, opt-in)
bash tests/test-gate-events.sh              # Per-event outcome attribution (gate_events.jsonl helper + wiring)
bash tests/test-discover-session.sh         # Cross-project session-discovery cwd filter (record-finding-list / show-status)
bash tests/test-design-contract.sh          # 9-section Design Contract regression net (UI agents + skill + router)
bash tests/test-specialist-routing.sh       # Cross-domain specialist routing contract (coding + writing + research + operations + mixed + general)
bash tests/test-stop-failure-handler.sh     # StopFailure hook captures rate_limit / auth / billing fatal-stop signals into resume_request.json
bash tests/test-omc-config.sh               # /omc-config skill backend (mode detection, atomic conf writes, presets, validation)
bash tests/test-output-style-coherence.sh   # All bundled styles: frontmatter parity, hook-injected opener coherence, label regression net, enum coverage
bash tests/test-timing.sh                   # Per-prompt time-distribution capture, aggregator, format helpers, /ulw-time empty-states
python3 -m unittest tests.test_statusline   # Statusline widget
```

## Customization

The harness is designed to be extended. Agent definitions, quality gate thresholds, domain routing rules, and specialist chains can all be modified to match your workflow.

- [Architecture](docs/architecture.md) -- system design and component interaction
- [Customization](docs/customization.md) -- what's configurable and how to change it safely
- [FAQ](docs/faq.md) -- common questions and troubleshooting
- [Prompts](docs/prompts.md) -- prompt reference and routing details
- [Glossary](docs/glossary.md) -- decoder ring for the mythology-named skills and internal terms
- [Bypass-surface taxonomy](docs/bypass-taxonomy.md) -- four-category field guide for how LLM agents escape work contracts (state-predicate / prose-pattern / single-call-flip / classifier-misroute); project-independent reference
- [Showcase](docs/showcase.md) -- real-world transcripts where the gates caught a bug or stalled completion (community-contributed)

## Auto-resume after a Claude Code rate-limit kill

When Claude Code's 5-hour or 7-day rate-limit window expires mid-task, the session terminates with a `StopFailure`. By default the harness now captures the moment via three layers, so the work picks up "as if it were not interrupted" once the cap clears:

1. **Substrate (always on, privacy-aware)**. The `StopFailure` hook persists `~/.claude/quality-pack/state/<session>/resume_request.json` carrying the original objective, last user prompt, matcher, reset epoch, and project key. Set `stop_failure_capture=off` in `~/.claude/oh-my-claude.conf` to opt out of the capture (shared machines / regulated codebases).
2. **SessionStart hint (always on)**. The next time you open Claude Code in that project, a SessionStart hook surfaces the unclaimed artifact's objective and reset timing as `additionalContext`. Either invoke `/ulw-resume` to atomically claim and replay the original prompt, or `/ulw-resume --dismiss` to silence the hint without resuming.
3. **Headless watchdog (opt-in)**. A LaunchAgent (macOS), systemd user-timer (Linux), or managed crontab entry (fallback) runs every ~2 minutes. When a rate-limit window clears it atomically claims the artifact, then launches `claude --resume <session_id> '<original prompt>'` in a detached `tmux` session named `omc-resume-<sid>` rooted at the original cwd. Attach with `tmux attach -t omc-resume-<sid>`.

Activate the watchdog:

```bash
bash ~/.claude/install-resume-watchdog.sh
```

The installer detects your platform, registers the scheduler, sets `resume_watchdog=on`, and runs a dry-tick to confirm health. On launchd/systemd hosts it installs the native scheduler; on fallback hosts it writes a managed crontab entry when `crontab` is available and otherwise prints the exact line to add manually. Tail the log at `~/.claude/quality-pack/state/.watchdog-logs/resume-watchdog.log` (macOS) or `journalctl --user -u oh-my-claude-resume-watchdog.service -f` (Linux).

When `tmux` is not available the watchdog falls back to an OS notification — you click the alert, open Claude Code, and run `/ulw-resume` manually. For cron fallback hosts, inspect the managed entry with `crontab -l`. To uninstall the watchdog: `bash ~/.claude/install-resume-watchdog.sh --uninstall [--reset-conf]`.

## Release & distribution tooling (maintainers)

> Skip this section unless you cut releases. Nothing here is needed to install or use the harness — it is moved out of Quick Start on purpose.

Maintainers changing release/distribution automation can also prove that the remote default branch actually has the required workflow/tooling deployed with `tools/verify-release-automation-deployment.sh`, stage the exact audited deployment surface with `tools/stage-release-automation-surfaces.sh`, prepare a coherent pre-push deployment candidate with `tools/prepare-release-automation-deployment.sh --dry-run` and `tools/prepare-release-automation-deployment.sh --fetch`, inspect the raw staged diff with `tools/verify-release-automation-deployment.sh --local-ref INDEX`, and get the full top-level maintainer picture with `tools/verify-distribution-readiness.sh`. That distribution wrapper now separates the live remote deployment proof from the local deployment-candidate proof, so maintainers can see “candidate ready locally” even while `origin/main` is still behind. For first-run distribution quality, `tools/verify-install-readiness.sh` proves the bootstrapper/update path, fresh-install handoff, recovery-path transcript, and AI-assisted onboarding contract together. For the full release-candidate view, `tools/verify-project-readiness.sh` composes that distribution proof with the cross-domain product proof from `tools/verify-professional-readiness.sh` plus the install/onboarding proof from `tools/verify-install-readiness.sh`, so maintainers can see in one command whether the repo is actually ready for professional users, installable by first-time users, and ready to ship. That wrapper covers classification + routing + UI design contracts + benchmark + realwork + install/onboarding before it even reaches the remote release/distribution audit. The staging helper supports a dry-run preview, fails closed when unrelated files are already staged, and supports `--allow-extra-staged` when that wider staged set is intentional; when you narrow it with `--path`, it also fails closed if other manifest entries are still dirty unless you explicitly pass `--allow-partial-manifest`. The new deployment-candidate helper succeeds when that pending staged candidate is coherent even though the remote is still behind, which closes the old ambiguity where `--local-ref INDEX` necessarily failed before push. The staged-index deployment verifier now applies the same fail-closed posture to unrelated non-manifest staged paths unless you explicitly pass `--allow-extra-staged`, and `tools/verify-distribution-readiness.sh` passes that same override through when you audit the staged index via `--local-ref INDEX`. All three release/distribution audit helpers support `--json` when you need the same proof as a machine-readable artifact.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting changes, the review process, and how to test modifications to the harness locally.

## License

[MIT](LICENSE)
