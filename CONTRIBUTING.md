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
# Syntax + lint
bash -n bundle/dot-claude/**/*.sh
shellcheck bundle/dot-claude/**/*.sh

# Installation verification
bash verify.sh

# Unit / integration tests
bash tests/test-intent-classification.sh
bash tests/test-quality-gates.sh
bash tests/test-stall-detection.sh
bash tests/test-e2e-hook-sequence.sh
bash tests/test-settings-merge.sh
bash tests/test-uninstall-merge.sh
bash tests/test-common-utilities.sh
bash tests/test-session-resume.sh
bash tests/test-concurrency.sh
bash tests/test-install-artifacts.sh
bash tests/test-post-merge-hook.sh
bash tests/test-repro-redaction.sh
bash tests/test-discovered-scope.sh
bash tests/test-finding-list.sh
bash tests/test-state-io.sh
bash tests/test-classifier-replay.sh
bash tests/test-serendipity-log.sh
bash tests/test-cross-session-rotation.sh
bash tests/test-classifier.sh
bash tests/test-show-report.sh
python3 -m unittest tests.test_statusline -v
```

All checks must pass cleanly.

## Adding Agents

1. Create a new file in `bundle/dot-claude/agents/` with a descriptive, hyphen-separated name.
2. Define the agent's role, capabilities, and constraints.
3. Use `disallowedTools` to set permission boundaries appropriate to the agent's role.
4. Set `model: opus` for complex reasoning tasks or `model: sonnet` for faster execution. The `--model-tier` install flag can override these defaults (see [customization.md](docs/customization.md#model-tiers)).
5. If the agent handles a specific domain, ensure `infer_domain()` in `common.sh` can route to it.

## Adding Skills

1. Create a directory `bundle/dot-claude/skills/<skill-name>/`.
2. Add a `SKILL.md` file defining trigger conditions and instructions.
3. If the skill requires scripts, place them in a `scripts/` subdirectory.

## Adding Hook Scripts

1. Place the script in the appropriate directory:
   - Lifecycle hooks: `bundle/dot-claude/quality-pack/scripts/`
   - Autowork hooks: `bundle/dot-claude/skills/autowork/scripts/`
2. Begin with `set -euo pipefail`.
3. Source `common.sh` for shared utilities.
4. Exit 0 when `SESSION_ID` is missing or empty.
5. Register the hook in `config/settings.patch.json` under the appropriate event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `SubagentStop`, or `Stop`).

## Documentation Maintenance

When you add, remove, or rename agents, skills, scripts, or directories, update these files:

- **CLAUDE.md** -- key directories, key files, testing
- **AGENTS.md** -- architecture diagram, component descriptions
- **README.md** -- repository structure, features, counts
- **CONTRIBUTING.md** -- testing and component-addition sections

Keeping counts and directory listings accurate prevents drift between code and docs.

## Release Process

When bumping the version (changing `VERSION`), follow these steps in order. Replace `X.Y.Z` with the actual version number in all commands.

1. Update `VERSION` with the new version number (e.g. `1.4.1`).
2. Update the README.md badge: `[![Version](https://img.shields.io/badge/Version-X.Y.Z-blue.svg)]`.
3. Add a CHANGELOG.md entry under `## [X.Y.Z] - YYYY-MM-DD` with Added/Fixed/Changed sections.
4. Commit with a descriptive message summarizing the release.
5. **Tag the release commit**: `git tag vX.Y.Z` — this is mandatory, not optional.
6. Push commits and tags: `git push && git push --tags`.
7. Create a GitHub release from the tag:
   ```bash
   VER=$(cat VERSION)
   awk "/^## \\[$VER\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md \
     | gh release create "v$VER" --title "v$VER" --notes-file -
   ```
   If `gh` is unavailable, create the release manually via GitHub's web UI.

A version bump without a corresponding git tag breaks the release history. Every `VERSION` change must have a matching `vX.Y.Z` tag on the commit that introduced it.

## Code of Conduct

- Be respectful in all interactions.
- Provide constructive feedback with specific suggestions.
- Assume good intent from other contributors.
- Focus discussions on the technical merits of changes.
