# Contributing to oh-my-claude

Thank you for your interest in contributing. This document explains how to report issues, suggest features, and submit changes.

## Reporting Bugs

Open a [GitHub issue](../../issues/new?template=bug_report.md) with:

- A clear description of the problem.
- Steps to reproduce the issue.
- Expected vs. actual behavior.
- Your environment (OS, Claude Code version, shell).

## Suggesting Features

Open a [GitHub issue](../../issues/new?template=feature_request.md) with:

- A description of the feature.
- The use case it addresses.
- A proposed approach, if you have one.

## Submitting Changes

1. Fork the repository.
2. Create a branch from `main` for your change.
3. Make your changes following the code standards below.
4. Run the test suite.
5. Submit a pull request against `main`.

Keep PRs focused. One logical change per PR.

## Code Standards

### Bash Scripts

- All scripts must begin with `set -euo pipefail`.
- All scripts must pass `shellcheck` with no errors.
- All scripts must pass `bash -n` syntax validation.
- Never hardcode user paths. Use `$HOME` or relative paths.
- Hook scripts must source `common.sh` and exit 0 on missing `SESSION_ID`.

### State

- Use JSON for all state (`session_state.json`).
- Use `read_state` and `write_state` / `write_state_batch` from `common.sh`.

## Testing

Before submitting a pull request:

```bash
bash -n bundle/dot-claude/**/*.sh
shellcheck bundle/dot-claude/**/*.sh
bash verify.sh
```

All three must pass cleanly.

## Adding Agents

1. Create a new file in `bundle/dot-claude/agents/` with a descriptive, hyphen-separated name.
2. Define the agent's role, capabilities, and constraints.
3. Use `disallowedTools` to set permission boundaries appropriate to the agent's role.

## Adding Skills

1. Create a directory `bundle/dot-claude/skills/<skill-name>/`.
2. Add a `SKILL.md` file defining trigger conditions and instructions.
3. If the skill requires scripts, place them in a `scripts/` subdirectory.

## Adding Hook Scripts

1. Place the script in the appropriate directory:
   - Lifecycle hooks: `bundle/dot-claude/quality-pack/scripts/`
   - Autowork hooks: `bundle/dot-claude/skills/autowork/scripts/`
2. Source `common.sh` for shared utilities.
3. Exit 0 when `SESSION_ID` is missing or empty.
4. Register the hook in `config/settings.patch.json`.

## Code of Conduct

- Be respectful in all interactions.
- Provide constructive feedback with specific suggestions.
- Assume good intent from other contributors.
- Focus discussions on the technical merits of changes.
