# Auto-Memory on Session Wrap-Up

**Project opt-out.** If `~/.claude/oh-my-claude.conf` (user-level) or `.claude/oh-my-claude.conf` (project-level, walked up from CWD) sets `auto_memory=off`, skip both this rule AND the compact-time memory sweep in `compact.md` for the session. Quick check before applying the rule:

```bash
bash -c '. "${HOME}/.claude/skills/autowork/scripts/common.sh"; is_auto_memory_enabled' || echo "auto_memory=off — skip"
```

Use the opt-out for shared machines, regulated codebases, or projects where session memory should not accrue across runs. Explicit user requests ("remember that...", "save this as a memory") still apply regardless of the flag.

After any substantial implementation session (multi-step coding, council/lens evaluations, debugging campaigns, anything that moves the project's state in a way the next session would benefit from knowing), proactively update auto-memory before stopping. Do this without being asked.

**Applies to:** turns where work moved forward — execution, continuation, and checkpoint turns. Advisory and session-management turns produce evaluation, not durable cross-session signal, and should be treated as memory-quiet by default. The prompt-intent-router injects an `AUTO-MEMORY SKIP` directive into those turns so the model knows to skip both this session-stop pass and the compact-time pass in `compact.md`.

What "substantial" looks like in practice:
- Shipped one or more commits
- Resolved a critical/P0 finding from a reviewer or council
- Completed a feature or migration that other sessions might re-discover
- Made or revisited an architectural decision
- Deferred items deliberately (so future sessions know they're known, not forgotten)

What to write — choose the memory type that fits the signal, not a default:
- **`project_*.md`** for what shipped, what was decided, what was deferred and why, and what to watch next. This is the common wrap-up case.
- **`feedback_*.md`** for approaches the user confirmed (explicit approval, accepted-without-pushback on a non-obvious call) or corrected mid-session — especially if the reason is load-bearing for future edge cases.
- **`user_*.md`** for role, tooling, workflow preferences revealed during the session that will shape future collaboration.
- **`reference_*.md`** for external systems mentioned (Linear projects, Grafana boards, Slack channels, docs URLs) where future sessions should look for authoritative info.

Multiple types can come out of one session — write each to its own file.

Ordering and duplicate prevention:
- Run the memory pass **after** quality gates pass (review, verify, excellence) and **before** the final stop.
- Before writing, grep `MEMORY.md` for entries covering the same surface. If one exists:
    - **Update in place** for corrections or additive context on the same subject.
    - **Supersede** (write the new file, delete or archive the old) when the prior framing is now wrong, not just incomplete.
- Never create a second file describing the same thing.
- Add exactly one one-line index entry in `MEMORY.md` per memory file written.

What NOT to write:
- File paths or line numbers that will rot.
- Code patterns derivable from the current source.
- Commit-by-commit blow-by-blow (the git log is authoritative).
- Anything already captured in CLAUDE.md, AGENTS.md, or the project's own docs.

## Reject these patterns (project_*.md)

Do NOT write a `project_*.md` memory in any of these shapes — they duplicate sources of truth that already exist and become rot the moment the next release lands:

- **Per-release "shipped" snapshots** (`project_v1_2_3_shipped.md`, `project_release_X_done.md`, etc.). Version, commit SHA, tag status, "what shipped" lists, test counts — duplicates `CHANGELOG.md`, `git tag`, and `git log`. The CHANGELOG is the authoritative release record.
- **"What I just did" recaps.** "Implemented X / fixed Y / refactored Z" — duplicates `git log`. The diff is the source of truth for what changed.
- **Test counts, file counts, line counts.** "30 bash tests, 2,288 assertions" rots the moment another wave lands.
- **Architecture inventories.** "X lives in `path/to/file.sh`, Y is in `lib/...`" — read the directory tree.

Write a `project_*.md` only when the signal is **non-derivable** from `git log`, `CHANGELOG.md`, or the source tree:

- **Decision rationale** the codebase doesn't show ("why we chose A over B", "why this constraint exists").
- **Deferred risks** with a deadline that future sessions need to surface ("must remove flag by 2026-06-01 or experiment expires").
- **Stakeholder reasons** for a constraint (legal, compliance, partner-facing, contractual).
- **Post-mortem insight** that won't appear in commits ("we tried X first, it broke Y under load, ended up with Z because…").

If the answer to "could a future session derive this from `git log`, `CHANGELOG.md`, or the source?" is yes, do not write it. Quality of memory comes from non-derivability, not coverage.

This rule overrides any "stop early" pressure: a wrap-up memory update is part of completing the session, not a separate task to defer.

Session wrap-up is one of two memory-sweep moments. The other is mid-session compaction — see `compact.md` → "Memory Sweep Before Compact" for that trigger. The compact sweep captures what is about to be lost from the current turn; this session-stop sweep captures the whole session. Both can fire in a long session; that is intended, not redundant.
