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

Before submitting a pull request, run the full CI-parity suite. The canonical command list lives in `CLAUDE.md` "Testing" — keep this section pointing at that single source of truth so the lists cannot drift.

```bash
# Syntax + lint (CI parity — shellcheck warnings ARE fatal)
find bundle/ -name '*.sh' -print0 | xargs -0 shellcheck -x --severity=warning
find . -name '*.json' -not -path './.git/*' -print0 | xargs -0 -n1 python3 -m json.tool --no-ensure-ascii > /dev/null

# Installation verification
bash verify.sh

# Run every CI-pinned bash test (extracts the canonical list from validate.yml — never drifts)
for t in $(grep -E '^\s+run:\s+bash tests/test-' .github/workflows/validate.yml | awk '{print $NF}'); do
  bash "${t}" || { printf 'FAIL: %s\n' "${t}"; exit 1; }
done

# Statusline widget (Python)
python3 -m unittest tests.test_statusline -v
```

All checks must pass cleanly. The pin-discipline contract (`tests/test-coordination-rules.sh:C2`) blocks adding a new `tests/test-*.sh` without either CI-pinning it in `validate.yml` or marking it `# UNPINNED: <reason>` — this keeps the list exhaustive without manual upkeep here.

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

### Reviewer-agent additions

Adding a new reviewer-style agent has two layers. Do both in the same commit — missing the test-plumbing layer produces a broken install that `verify.sh` cannot catch.

**Procedural wiring (all reviewer-style agents):**

1. Wire the agent in `config/settings.patch.json` under `SubagentStop` with a reviewer-type argument: `$HOME/.claude/skills/autowork/scripts/record-reviewer.sh <type>` where `<type>` is `standard`, `excellence`, `prose`, `stress_test`, `traceability`, or `design_quality`.
2. Add the `VERDICT:` contract line to its output-format section in `bundle/dot-claude/agents/<name>.md` (see "Reviewer VERDICT contract" in `AGENTS.md`).
3. Update the dimension mapping table in `AGENTS.md` "Dimension mapping".
4. Add a matcher-name assertion in `tests/test-settings-merge.sh`.
5. Add a simulator function and at least one sequence test in `tests/test-e2e-hook-sequence.sh`.
6. Update the `SubagentStop` count assertions in `tests/test-settings-merge.sh`.

**FINDINGS_JSON contract (finding-emitting reviewers only — those that surface defects/gaps with severity):**

1. Add the contract instruction to the agent's `.md` file (model emits a single-line `FINDINGS_JSON: [...]` block immediately before the `VERDICT:` line).
2. Add the agent to the contract-presence regression net in `tests/test-findings-json.sh`.
3. If the agent's findings should feed the discovered-scope gate, add it to `discovered_scope_capture_targets` in `bundle/dot-claude/skills/autowork/scripts/common.sh`.
4. Document the agent in AGENTS.md under "Structured FINDINGS_JSON contract (v1.28.0)".

`editor-critic` is intentionally excluded from FINDINGS_JSON — prose-quality observations are not severity-anchored.

## Release Process

When bumping the version (changing `VERSION`), follow these steps in order. Replace `X.Y.Z` with the actual version number in all commands.

### Pre-flight

1. **CHANGELOG audit.** Run `git log --oneline vPREV..HEAD` and confirm every commit has a matching `[Unreleased]` bullet in `CHANGELOG.md`. Silent drop (a large commit's changes missing from the changelog) is the common failure mode. Also skim `docs/architecture.md` "State keys" table for new keys introduced in the window.

2. **CI parity check.** Run locally exactly what `.github/workflows/validate.yml` will run — shellcheck warnings are CI-fatal, so any local warning is a CI red. Do not proceed if any of these exit non-zero or emit any warning:
   - `find bundle/ -name '*.sh' -print0 | xargs -0 shellcheck -x --severity=warning`
   - `find . -name '*.json' -not -path './.git/*' -print0 | xargs -0 -n1 python3 -m json.tool --no-ensure-ascii > /dev/null`
   - Every test the CI workflow runs. Extract the current list live so this checklist cannot drift: `grep -E '^\s+run:\s+bash tests/test-' .github/workflows/validate.yml | awk '{print $NF}'`. Plus `python3 -m unittest tests.test_statusline -v`.

   *v1.32.0 expanded the CI-pinned set from 33 → 61 tests (release post-mortem R1). Coordination-rules lockstep test (`tests/test-coordination-rules.sh`) now enforces "every test is CI-pinned OR carries a `# UNPINNED: <reason>` token" — adding a new test without explicit pin-or-justify blocks merge.*

3. **Sterile-env CI-parity run** *(MANDATORY since v1.32.2 R9 closure).* `bash tests/run-sterile.sh` runs the CI-pinned tests under env scrubbed to look like Ubuntu CI's tmpfs (`env -i` + fresh `HOME` + jq-aware PATH including `/sbin` for macOS `md5`). Catches the "passes locally because dev has state X, fails in CI because tmpfs has empty X" class of bug that produced the v1.31.0 → v1.31.0-hotfix cascade (T7 sterile-CI miss). v1.32.0 shipped this advisory; v1.32.2 closed the 7 env-leak susceptibilities (`STATE_ROOT`/`SESSION_ID` collision with the harness's HOME-derived state path, plus `/sbin` PATH miss for macOS md5) and promoted to **strict by default**. The runner is now wired into `.github/workflows/validate.yml` as a CI step — any future env-coupling regression fails CI on push. Override to advisory mode (`--advisory` or `OMC_STERILE_ADVISORY=1`) only when explicitly debugging an env-leak suspect.

4. **Cumulative-diff `release-reviewer` run** *(advisory, v1.32.0 R2 → forked in v1.32.1).* For releases that span more than one wave commit, dispatch the `release-reviewer` agent against `git diff "$(git describe --tags --abbrev=0)..HEAD"`. Per-wave `quality-reviewer` passes catch per-wave defects; the cumulative `release-reviewer` catches **cross-wave interaction defects** (the v1.31.3 F-1/F-2/F-3/F-5 class). The forked agent is sized for cumulative scope: no top-N finding cap, 3000-4000 word budget, 60 maxTurns, surface-sliced dispatch when the diff exceeds 30 files (one pass per modified script directory: `lib/`, `autowork/scripts/`, `quality-pack/scripts/`, `agents/`, `skills/`, `tests/`, `install*.sh`, `config/`, `.github/`, `docs/`, `tools/`). The pre-1.32.1 fallback was the in-session `quality-reviewer` which was structurally too small (1000-word/top-8 cap) and truncated 3× during the v1.32.0 release-prep cumulative review. Block bump until findings are addressed in new commits OR explicitly deferred with named WHY via `/mark-deferred`.

5. **Install upgrade simulation** *(advisory, v1.32.0 R8).* `bash tools/install-upgrade-sim.sh` runs `install.sh` end-to-end against a 4-case `PRIOR_INSTALLED_VERSION` matrix (empty/first-install, N-1, oldest-CHANGELOG/long-span, no-op-same-version) and inspects the user-visible "What's new" block. Catches the install-summary class of bug that produced the v1.31.1 → v1.31.1-hotfix-round-2 cascade (cap=6 too low for span-7-versions case). The unit-level complement is `tests/test-install-whats-new.sh` T8.

6. **Hotfix-sweep gate** *(MANDATORY since v1.32.11 — R5 closure from the v1.31.x post-mortem).* `bash tools/hotfix-sweep.sh` runs after every fix commit during release prep, before the next bump. Closes the **Compound-Fix Tag-Race** anti-pattern (each hotfix is an opportunity for a new hotfix unless the post-fix regression net is enforced — the v1.31.0→v1.31.3 cascade was 4 patches in one day where F-3's fix introduced its own regression). Four checks, ~2 min budget:

   - **Sterile-env CI-parity** (delegates to `tests/run-sterile.sh`) — catches v1.31.0-class T7 sterile-fail.
   - **CHANGELOG-coupled tests** (grep-based, generalizes step 8 above) — catches install-whats-new cap drift.
   - **shellcheck on changed `bundle/*.sh`** — catches CI-fatal warnings before tag.
   - **lib-reachability** — every modified `bundle/.../lib/*.sh` since the last tag must have a CI-pinned `tests/test-${name}.sh` (mirrors `tests/test-coordination-rules.sh:C3` as a pre-tag check).

   Fast-path: when only docs/CHANGELOG/VERSION changed since the last tag, the heavy checks skip with a "no fix-shaped changes" message. `--quick` mode skips sterile-env (saves ~1 min) but warns; re-run without `--quick` before tagging. Regression net: `tests/test-hotfix-sweep.sh` (12 assertions, CI-pinned).

### Bump and tag

**Automated path (preferred since v1.32.14):**

```bash
bash tools/release.sh X.Y.Z
```

This runs steps 7-14 below in order, validating preconditions (clean tree, on `main`, X.Y.Z is above current, tag doesn't exist, no leftover `.hotfix-sweep-quick` marker) before any mutation. `--dry-run` previews; `--no-watch` skips the post-flight CI watch (still tags + pushes). Regression net: `tests/test-release.sh` (22 assertions, CI-pinned).

**Manual path (kept for reference and for environments where the script can't run):**

7. Update `VERSION` with the new version number (e.g. `1.4.1`).
8. Update the README.md badge: `[![Version](https://img.shields.io/badge/Version-X.Y.Z-blue.svg)]`.
9. Promote the `[Unreleased]` heading in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD` (keep `[Unreleased]` above it as an empty placeholder for the next cycle if desired).

   **Re-run all CHANGELOG-coupled tests after promotion** (v1.32.7 process fix, v1.32.8 generalization). Step 2's CI-parity check ran BEFORE step 9 promoted the CHANGELOG, so any test whose assertions depend on `CHANGELOG.md` content evaluates the OLD content. v1.31.1 / v1.32.1 / v1.32.3 / v1.32.5 / v1.32.6 all shipped with this gap. Pre-1.32.8 step 9 named two specific tests (`test-install-whats-new.sh`, `test-install-artifacts.sh`) — but new CHANGELOG-reading tests added later would silently slip through. v1.32.8 generalizes:

   ```bash
   for t in $(grep -lE 'CHANGELOG\.md|extract_whats_new' tests/test-*.sh); do
     bash "${t}" || { printf 'FAIL: %s\n' "${t}"; exit 1; }
   done
   ```

   Run this after the CHANGELOG promotion in step 9. If anything fails, fix before tagging — usually a cap-bump in `install.sh` and the test mirror.

10. Commit with a descriptive message summarizing the release.
11. **Tag the release commit**: `git tag vX.Y.Z` — this is mandatory, not optional.
12. Push commits and tags: `git push && git push --tags`.
13. Create a GitHub release from the tag:
    ```bash
    VER=$(cat VERSION)
    awk "/^## \\[$VER\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md \
      | gh release create "v$VER" --title "v$VER" --notes-file -
    ```
    If `gh` is unavailable, create the release manually via GitHub's web UI.

### Post-flight

14. **CI verification.** Watch the just-tagged commit's CI run, pinned to the tag SHA so a teammate's concurrent push cannot resolve the wrong run:
    ```bash
    gh run watch --exit-status \
      "$(gh run list --commit "$(git rev-parse vX.Y.Z)" --limit 1 --json databaseId -q '.[0].databaseId')"
    ```
    The command blocks until completion and exits non-zero on `failure`, `cancelled`, `timed_out`, or `action_required` — only `success` counts as green. If it does not return `success`, the release is **incomplete**: fix the issue and either `gh run rerun <id>` or push a hotfix commit. Do not declare the release shipped while CI on the tagged commit is anything other than green.

   `tools/release.sh` runs this watch automatically as Step 14 unless `--no-watch` was passed.

A version bump without a corresponding git tag breaks the release history. Every `VERSION` change must have a matching `vX.Y.Z` tag on the commit that introduced it. Never skip tagging.

## Code of Conduct

- Be respectful in all interactions.
- Provide constructive feedback with specific suggestions.
- Assume good intent from other contributors.
- Focus discussions on the technical merits of changes.
