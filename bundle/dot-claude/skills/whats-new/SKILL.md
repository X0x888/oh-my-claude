---
name: whats-new
description: Show CHANGELOG entries between your installed version and the source repo's HEAD. Use after `git pull` (or to see what's new in an unreleased install) to discover features that landed since your last install. Runs the bundled `show-whats-new.sh` script which reads `installed_version` from `~/.claude/oh-my-claude.conf`, walks `${repo_path}/CHANGELOG.md`, and renders the delta in a readable format.
---

# /whats-new

Surface the CHANGELOG delta between your installed bundle and the source repo. Solves the "I installed at v1.20 — does v1.31's `/diverge` exist?" question without forcing the user to grep CHANGELOG.md by hand.

## What it does

1. Reads `installed_version` from `~/.claude/oh-my-claude.conf` (written by `install.sh`).
2. Reads `repo_path` from the same conf and opens `${repo_path}/CHANGELOG.md`.
3. Walks every `## [X.Y.Z]` heading; collects the entries strictly newer than your installed version.
4. Prints them in chronological order (oldest first), one section per release.

If you are at HEAD (no drift), prints a single line confirming you are current.

If the source repo has an `[Unreleased]` section, that's surfaced too — useful when you've `git pull`-ed but not yet re-run `bash install.sh`.

## When to use

- Right after `git pull` on the source repo, before re-running `install.sh`.
- When the statusline shows `↑v<version>` (drift indicator) and you want to know what's behind the arrow.
- After a long pause from the project, to discover features added in your absence.

## How to invoke

Run the bundled script directly via Skill — no arguments:

```
$ bash $HOME/.claude/skills/autowork/scripts/show-whats-new.sh
```

## Privacy

100% local — reads files only under your home directory. No network egress.
