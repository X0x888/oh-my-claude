---
name: omc-doctor
description: One-shot oh-my-claude install health check — verifies the installed tree at ~/.claude (core files, CLAUDE.md @-includes, hook wiring in settings.json, state-root writability) from any directory, no source clone needed. Use when the harness feels off, gates stopped firing, or after an update.
---
# OMC Doctor

Run the installed-tree diagnostic:

```
bash ~/.claude/skills/autowork/scripts/omc-doctor.sh
```

Display the output as-is, then:

- **All ok** — say so in one line; no further action.
- **warn lines** — explain each warning in one plain-language sentence
  (e.g. a non-executable hook script means that one enforcement surface
  is silently skipped) and give the one-command fix where obvious
  (`chmod +x <path>`).
- **FAIL lines** — the install is broken in a way that makes the harness
  silently inert (Claude Code fails open on hook errors). Recommend the
  recovery path the script prints: re-run `install.sh` from the source
  clone, or the `install-remote.sh` curl one-liner. If the user has the
  repo checked out, `bash verify.sh` there gives the deeper
  fresh-install audit.

The name is `omc-doctor` (not `doctor`) deliberately — Claude Code ships
a native `/doctor` for the CLI itself; this skill checks the
oh-my-claude overlay, not Claude Code.
