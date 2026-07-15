# Security & Trust

oh-my-claude hooks every Claude Code prompt and runs bash on your machine. That demands a plain answer to four questions. (Assembled from the FAQ, the conf reference, and the source — every claim below is auditable in this repo.)

## 1. What runs on my machine?

Pure bash lifecycle hooks (plus `jq`), installed as a merge-safe overlay into `~/.claude/`. Hooks execute **with your own user privileges** on Claude Code events (prompt submit, tool use, stop). There is no server, no daemon by default, no compiled code, and **zero third-party runtime dependencies** — no npm, no pip, nothing to supply-chain-poison downstream. The optional resume watchdog (`resume_watchdog=off` by default) is the only persistent agent, registered via launchd/systemd only when you opt in.

You can audit everything before installing: the manual-clone path (`git clone` + read + `bash install.sh`) is documented in the README as the strongest posture, and `verify.sh` checks the installed tree's integrity (SHA-256 manifest, hook wiring, JSON validity), the user-level hook kill switch, and the effective project/local kill switch for its invocation directory.

## 2. What data leaves my machine?

**Nothing.** The harness is 100% local — it reads and writes files only under your home directory (`~/.claude/`). There is no network egress, no telemetry endpoint, no analytics beacon. The only network activity the project ever performs is what *you* invoke: `git clone`/`pull` during install and `gh` calls if you use the release-verification tooling.

## 3. What does it persist locally, and how do I turn that off?

Telemetry exists to answer "is this harness helping me?" (`/ulw-report`) and lives in `~/.claude/quality-pack/` (created `chmod 700`):

| Artifact | Contents | Opt-out |
|---|---|---|
| Session state | counters, clocks, objective (redacted) | core to operation |
| `gate_events.jsonl` | gate/event rows; free-text fields are secret-redacted at write time | — |
| Classifier telemetry | intent/domain + 200-char redacted prompt previews | `classifier_telemetry=off` |
| Timing/token cards | wall-clock + token counts (no message text) | `time_tracking=off` |
| Auto-memory | cross-session project notes | `auto_memory=off` |
| Resume capture | objective + last prompt (redacted) on a rate-limit kill | `stop_failure_capture=off` |
| Closeout evidence | up to 3 redacted 6K provisional candidates + 20 redacted verification receipts; cleared on fresh execution, and candidates clear after a finalized clean close | core to cumulative closeout |
| Closeout presentation state | message IDs and timestamps only; no response text is buffered across MessageDisplay batches | core to quiet closeout presentation |
| Transcript archive | full transcript copies | **off by default** (`transcript_archive=on` to enable) |

One move disables optional telemetry: `/omc-config` → **Minimal** preset (optional telemetry off, basic gates). Operational closeout state remains while a material task is active. Secret redaction (`omc_redact_secrets`) scrubs provider-key shapes (`sk-ant-…`, `ghp_…`, `AKIA…`, bearer tokens) before durable prompt-derived values are persisted. MessageDisplay stores only operational message IDs/timestamps; accepted response text is never copied into a cross-batch display buffer.

## 4. Why is it safe to let this gate my sessions?

- **Inspection/judgment agents deny the direct editor tools; builders retain them under your permission model.** All 26 inspection/judgment specialists carry `disallowedTools: Write, Edit, MultiEdit, NotebookEdit` plus `permissionMode: plan`. Bash remains available for inspection/tests, so this is a direct-tool boundary rather than an OS-level no-write sandbox; Bash follows the active parent permission mode, and Claude Code documents that parent `acceptEdits`, `auto`, or bypass modes can take precedence over a subagent's plan mode. The 11 domain builders (`frontend-developer`, `backend-api-developer`, the `ios-*` family, `fullstack-feature-builder`, `devops-infrastructure-engineer`, `test-automation-engineer`, `research-data-analyst`, `atlas`) retain editor tools by design.
- **Permission prompts stay on.** Installation does not touch Claude Code's permission model; `--bypass-permissions` is a separate, explicit opt-in documented in the README.
- **Repo-conf defense, with an explicit platform boundary.** A cloned repo's `.claude/oh-my-claude.conf` cannot disable security-load-bearing gates: `pretool_intent_guard`, `bg_spawn_gate`, `agent_first_gate`, `no_defer_mode`, and `quality_policy` are deny-listed at the conf parser (project-level lines for them are ignored; see `docs/customization.md` → *Project-conf security restriction*). Claude Code's own `.claude/settings.json` / `settings.local.json` may intentionally set `disableAllHooks`; `verify.sh` checks the effective value for the current project, but cannot audit every repository on disk. Administrator policy such as `allowManagedHooksOnly=true` can also disable user hooks outside this harness's control. Treat those as platform policy, not an oh-my-claude conf bypass.
- **Destructive-op gating.** The PreToolUse guard blocks destructive git/gh operations (`push`, `reset --hard`, `rebase`, releases…) unless your prompt's classified intent authorizes them.
- **Fail-open by design, observably.** A crashing hook never blocks your session (it fails open); since v1.47 every enforcement hook records an anomaly trace when that happens, surfaced in `/ulw-report`, so silent enforcement loss is visible.
- **Supply chain.** Releases ship source bundles + `SHA256SUMS` + GitHub artifact attestations (`gh attestation verify`); the remote installer supports tag pinning + `OMC_EXPECTED_SHA` commit verification, and is `main()`-wrapped so a truncated `curl | bash` download executes nothing mutating.

## Reporting a vulnerability

Open a GitHub issue at <https://github.com/X0x888/oh-my-claude/issues> with the `security` label, or — if the issue is sensitive — use GitHub's private vulnerability reporting on the repository (*Security → Report a vulnerability*). Please include the installed version (`cat ~/.claude/oh-my-claude.conf | grep installed_version`) and, if possible, a redacted repro bundle (`bash ~/.claude/omc-repro.sh` — it truncates prompt fields before bundling).
