---
name: memory-audit
description: Audit the user-scope auto-memory directory for the current project — classify each MEMORY.md entry as load-bearing, archival, superseded, or drifted, and propose rollup moves. Use when MEMORY.md feels noisy, when version-snapshot files have accumulated (e.g. multiple `project_v*_shipped.md`), or when the auto-memory drift hint has fired at session start. Read-only — never deletes or moves files.
argument-hint: [--memory-dir <path>]
---
# Memory Audit

Walk the project's auto-memory directory and classify every entry indexed in `MEMORY.md`. The audit is read-only: it never moves, modifies, or deletes any file. Output is a markdown table plus a list of suggested `mv` commands the user can copy if they want to act on the recommendations.

## When to use

- `MEMORY.md` has grown past ~25 entries and you suspect bloat.
- A session-start drift hint named some entries as >30 days old.
- Multiple `project_v*_shipped.md` files have accumulated (the v1.20.0 rule rewrite forbids these going forward, but old ones remain on disk).
- A reviewer or oracle flagged a memory entry that no longer matches the source.

## When NOT to use

- The directory is small and recently curated — the audit will produce a near-empty report.
- You want to *make* the moves, not just see suggestions. The skill prints `mv` commands; review and run them yourself.
- You want to audit a different project's memory than the one you are in. Pass `--memory-dir <path>` explicitly to point at another project's memory directory.

## Steps

1. Take any optional argument:
   - `--memory-dir <path>` — explicit memory directory to audit. Defaults to `${HOME}/.claude/projects/<dashed-cwd>/memory/` derived from the current working directory (matches Claude Code's project-memory convention).
2. Run the helper script:

   ```bash
   bash ~/.claude/skills/autowork/scripts/audit-memory.sh
   ```

   Or with an explicit dir:

   ```bash
   bash ~/.claude/skills/autowork/scripts/audit-memory.sh --memory-dir /absolute/path/to/memory
   ```

3. The script prints:
   - The **resolved memory directory** as line 1 (so the user can confirm it audited the right project).
   - A summary count: total / load-bearing / archival / superseded / drifted.
   - A **markdown table** with status, file, title, and suggested action per entry.
   - A **suggested moves** section with concrete `mv` commands the user can copy. The script never executes these.

4. Relay the table to the user. If the table is large, summarize the top recommendations (e.g. "13 archival entries cluster as `project_v*_shipped.md` files — consolidate into one `project_release_history.md`").

5. Wait for user direction before any cleanup. The skill is diagnostic, not curative.

## Classification rules

| Status        | Meaning                                                                                  |
|---------------|------------------------------------------------------------------------------------------|
| **load-bearing** | Recent (mtime ≤ 30 days), not strikethrough, not a version-snapshot pattern. Keep.     |
| **archival**     | mtime > 30 days OR matches `project_v*_shipped.md` pattern. Candidate for release-history rollup. |
| **superseded**   | Strikethrough in MEMORY.md (`~~...~~`) or index description contains "closed", "superseded by", "replaced by". Safe to remove. |
| **drifted**      | The MEMORY.md index references a file that does not exist in the directory.               |

The script prints the file mtime alongside each row so the user can spot-check the classification.

## Safety

- Read-only. Never executes `mv`, `rm`, or any destructive command. The user runs the suggested moves themselves.
- Suggested commands are emitted with `printf %q` shell-quoting so paths containing spaces or shell metacharacters stay safe to copy-paste. **Sanity-check the resolved memory directory printed at the top of the audit before running any suggested move** — if the path looks wrong, do not run the commands.
- If the resolved memory directory does not exist, the script prints a one-line note and exits 0 (nothing to audit).
- If `MEMORY.md` is missing, the script lists files in the directory and exits 0 — partial audit, no index.
