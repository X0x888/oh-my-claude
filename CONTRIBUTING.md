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

## ULW Workflow Changes

For any change that affects `/ulw` behavior for end users — routing, directives, gates, reviewer sequencing, auto-dispatch, stop behavior, status/report surfaces, or prompt shaping — evaluate it primarily as a user-workflow change, not an internal refactor.

Before calling the change an improvement, write down all four:

1. **User failure mode fixed.** What real bad outcome does this prevent? Example: silent scope drop, wrong specialist choice, avoidable pause, weak verification, misleading report output.
2. **Automation effect.** Does this reduce or increase the amount of steering/babysitting the user must do?
3. **Latency/token cost.** What hot-path time or prompt/tool overhead does it add or remove?
4. **Verification.** What test, measurement, or repro shows the tradeoff is worth it?

If a change improves internal elegance but cannot answer those four items, describe it as internal maintenance rather than a ULW workflow improvement.

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

## Quarterly self-audit cadence

The Bug B post-mortem identified two structural failure modes that
self-improve only when run as scheduled, not on-demand:

1. **`/council --self-audit`** — every quarter, run a self-audit
   council against the harness's own state-I/O, prompt-routing, and
   gate-event surfaces. The fixed lens roster (`abstraction-critic`,
   `oracle`, `sre-lens`, `quality-researcher`) is sized for
   contract-shape and lifecycle review of the harness itself, not
   user projects. Phase 8 is opt-in: surface findings; defer
   implementation to a separate session unless a finding is
   critical.

2. **`tools/cluster-unknown-defects.sh`** — every quarter, run a
   clustering pass against the `unknown` bucket of
   `~/.claude/quality-pack/defect-patterns.json`. The script samples
   stored examples, surfaces top tokens / bigrams / path mentions,
   and produces a markdown candidate-cluster report. If a cluster
   emerges (multiple defects sharing a token/path/bigram), codify
   it as a new classifier category in
   `bundle/dot-claude/skills/autowork/scripts/lib/classifier.sh`
   with a regression net in `tests/test-classifier.sh`. Without
   this pass, defects the auto-classifier can't categorize accumulate
   into the unknown bucket and silently fall out of review — the
   "unbinned-signal-loss" anti-pattern from the Bug B post-mortem.

Both passes are intentionally cheap to run (a council dispatch + a
shell-tool invocation) so the quarterly cost is bounded. `/ulw-report`
nudges to run #2 when the unknown bucket exceeds 50 entries; #1 has
no auto-trigger today and relies on calendar discipline.

## Fixture realism rule

**Bug B post-mortem rule (v1.34.x).** Any new test that exercises a
**positional-decode helper, bulk-read API, or any code path that
round-trips arbitrary user-controlled strings through `session_state.json`
or another harness-managed value store** MUST exercise the helper
against the adversarial value set defined in `tests/lib/value-shapes.sh`.

The 12 adversarial classes cover the failure modes that have actually
bitten oh-my-claude — multi-line values (Bug B), embedded ASCII RS
(Bug B-class for the bulk-read delimiter), control bytes (ANSI
injection adjacent), Unicode multi-byte, CRLF paste, very long values,
and the empty/space/quote-heavy edges. Identifier-shaped fixtures
(`"alpha"`, `"value-1"`) test the implementation the author imagined,
not the inputs real consumers pass.

### How to apply it

```bash
# In a positional-API test file:
source "${REPO_ROOT}/tests/lib/value-shapes.sh"
# ...
assert_value_shape_invariants "round_trip"     write_state       read_state
assert_bulk_value_shape_invariants "bulk_align" write_state_batch read_state_keys
```

The helpers iterate every adversarial class, increment the parent-scope
`pass`/`fail` counters per shape, and print a diagnosable failure
showing the offending shape label, position, and `%q`-quoted byte
content. See `tests/test-state-io.sh:T19/T20` for the canonical use.

### What violates the rule

- Adding a new bulk-read or positional-decode test that uses only
  identifier-shaped fixtures.
- Documenting a "Consumer contract" on a helper without a regression
  net that exercises the contract's edges (multi-line, embedded RS,
  control bytes, very long values).

`quality-reviewer` and `excellence-reviewer` are instructed to flag
violations of this rule on any new positional-API test surface.

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

## Telemetry / Report Additions

For any new telemetry field, timing counter, scorecard metric, report slice, or statusline aggregate, treat the feature as incomplete until all of the following land in the same change:

1. A **write path** that records the data.
2. A **read path** that consumes it.
3. At least one **user-visible surface** (`/ulw-report`, `/ulw-status`, `/ulw-time`, statusline, install/update summary, or equivalent).
4. A **regression test** that proves the data flows end to end.
5. When historical rows matter, a **compatibility or backfill rule** so old sessions do not silently disappear from the new view.

Do not count telemetry as "shipped" when only the state write exists. This partial-landing pattern caused repeated drift in earlier versions and is now considered a release-quality bug.

### Cross-session JSONL schema versioning (v1.36.x W2 F-010)

Every cross-session JSONL emitter MUST stamp a `_v` schema-version field as the first key on each row. Convention:

- `_v: 1` is the current schema for all the cross-session ledgers under `~/.claude/quality-pack/`: `gate_events.jsonl`, `serendipity-log.jsonl`, `classifier_misfires.jsonl` (and the per-session `classifier_telemetry.jsonl`), `used-archetypes.jsonl`, `session_summary.jsonl` (already at v1 since v1.31.0).
- `agent-metrics.json` uses `_schema_version: 2` (object, not row-stream — historical reasons).
- When a row's shape changes (field rename, type change, removal), bump `_v` to `2` AND keep the v1 emitter on a deprecated path until consumers migrate. Use the new value in `_v` and document the diff in `CHANGELOG.md`.

**Why:** without per-row versioning, every consumer that joins ledgers (e.g. show-report's gate × session × directive joins) breaks silently the moment one schema evolves. The `_v` discriminator lets `tools/migrate-schema.sh` (when introduced for a future migration) walk every ledger and apply per-version transforms without ambiguity.

**When adding a new cross-session JSONL emitter:**

1. Stamp `_v: 1` as the first key in the JSON row literal.
2. Document the row schema in a doc-comment above the emitter function.
3. The reader side should use `(.{_v} // 0)` or equivalent to detect missing `_v` (legacy rows from before this convention) and fall through gracefully — never crash on a missing field.

### Worked example: bumping a row schema from `_v:1` to `_v:2`

Document the playbook **before** the first migration is needed, not during it. The worked example below assumes a hypothetical bump to `serendipity-log.jsonl` where the `conditions` field changes from a `|`-delimited string ("verified|same-path|bounded") into a structured object (`{"verified":true,"same_path":true,"bounded":true}`). The same pattern applies to any field rename, type change, or removal.

**Step 1 — Add the v2 writer alongside v1.** Do NOT replace the v1 emit immediately. Both emitters land in the same commit so old code paths still produce valid rows during the rollout window.

```bash
# OLD writer (record-serendipity.sh, _v:1):
jq -nc --arg fix "${fix}" --arg cond "${conditions}" \
  '{_v:1, ts:now|floor, fix:$fix, conditions:$cond, ...}' \
  >> "${log_file}"

# NEW writer (replaces above, emits _v:2 only):
jq -nc --arg fix "${fix}" \
       --argjson v "${verified:-false}" \
       --argjson sp "${same_path:-false}" \
       --argjson bn "${bounded:-false}" \
  '{_v:2, ts:now|floor, fix:$fix,
    conditions:{verified:$v, same_path:$sp, bounded:$bn},
    ...}' \
  >> "${log_file}"
```

**Step 2 — Make the reader version-aware.** Every consumer of the ledger (in `show-report.sh`, `tools/telemetry-replay.py`, etc.) must branch on `_v` and handle BOTH shapes for the deprecation window. Never assume the latest schema is the only one on disk.

```bash
# In show-report.sh — joining serendipity rows:
jq -r '
  .conditions
  | if (.[0:1] == "v") or (type == "object") then
      # _v:2 shape — structured object.
      [.verified, .same_path, .bounded] | map(if . then "T" else "F" end) | join("/")
    else
      # _v:1 shape — pipe-delimited string. Map "verified|same-path|bounded"
      # → "T/T/T" for parity with the v2 path.
      split("|") | map(if . == "verified" or . == "same-path" or . == "bounded" then "T" else "F" end) | join("/")
    end
' "${SERENDIPITY_LOG}"
```

The reader's version branch lives **for at least one full release cycle** after the writer migration. Don't drop v1 support in the same release that adds v2; that breaks resumed sessions and rate-limit-paused work that left rows on disk under v1.

**Step 3 — Sweep job OR strict cutoff.** Pick one based on the data's value:

- **Sweep job** (`tools/migrate-schema.sh`) — for ledgers where historical rows matter (e.g., `serendipity-log.jsonl` powers cross-session catch-rate analytics). Walk every row, apply the v1→v2 transform, write a new file, atomic-rename. Add a regression test that the rewriter is idempotent (running twice produces identical output).

  ```bash
  # tools/migrate-schema.sh (sketched):
  while IFS= read -r row; do
    v="$(printf '%s' "${row}" | jq -r '._v // 0')"
    if [[ "${v}" == "2" ]]; then
      printf '%s\n' "${row}" >> "${tmp}"  # already v2; passthrough
    elif [[ "${v}" == "1" ]] || [[ "${v}" == "0" ]]; then
      # v0 = legacy, before the _v convention landed (treat as v1 shape).
      printf '%s' "${row}" | jq -c '
        ._v = 2 | .conditions = (
          .conditions | split("|")
          | {verified: contains(["verified"]),
             same_path: contains(["same-path"]),
             bounded: contains(["bounded"])}
        )
      ' >> "${tmp}"
    fi
  done < "${log_file}"
  mv "${tmp}" "${log_file}"
  ```

- **Strict cutoff** — for telemetry where pre-cutoff history is noise (e.g., a counter that resets per release). Document the cutoff version in `CHANGELOG.md` and have the reader treat any `_v:1` row older than the cutoff date as deprecated/skipped. No sweep needed; the data ages out naturally as TTL sweeps run.

**Step 4 — Document in CHANGELOG.md.** The migration entry must name (a) which writer changed, (b) what the field shape change is, (c) which release drops v1 reader support, (d) whether a sweep job ran or a strict cutoff applies. Without this audit trail the next migration can't tell which `_v:N` rows are legitimately on disk.

**Common pitfalls:**
- **Adding `_v:2` rows without bumping the reader first.** A reader that hits an unknown `_v` should fall through gracefully (not crash); the version-aware branch must be in place BEFORE the new writer ships.
- **Treating `_v:0` (missing field) as invalid.** Legacy rows from before the v1.36.x F-010 convention have no `_v` key. Readers should treat missing `_v` as v1-equivalent (the original schema), not as a corrupt row.
- **Mixing v1 and v2 writers in the same emit path.** A single emitter must produce a single `_v` per row. If you need both shapes during a transition, run two emitters writing to two files and merge at read time.

## Release Process

When bumping the version (changing `VERSION`), follow these steps in order. Replace `X.Y.Z` with the actual version number in all commands.

### Pre-flight

1. **CHANGELOG audit.** Run `git log --oneline vPREV..HEAD` and confirm every commit has a matching `[Unreleased]` bullet in `CHANGELOG.md`. Silent drop (a large commit's changes missing from the changelog) is the common failure mode. Also skim `docs/architecture.md` "State keys" table for new keys introduced in the window. Release history is now lockstepped too: every semver git tag must have a matching `## [X.Y.Z]` heading in `CHANGELOG.md`. `tests/test-coordination-rules.sh` enforces this contract, so fetch tags before running it locally from a shallow clone.

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

7. **Local Linux CI parity** *(advisory, v1.33.x post-mortem of v1.33.0/.1/.2 cascade).* `bash tools/local-ci.sh` runs the validate.yml CI parity suite inside an Ubuntu container so BSD-vs-GNU coreutils, `mktemp -d` shape (`/var/folders/...` vs `/tmp/tmp.XXX`), and locale defaults are caught BEFORE the GitHub Actions round-trip. Pairs with the sterile-env TMPDIR fix in `tests/lib/sterile-env.sh` — sterile-env handles env-shape divergence on macOS hosts; local-ci handles BSD-vs-GNU coreutils divergence sterile-env can't fully simulate. Requires Docker or podman; gracefully reports the missing runtime if absent. ~30s after first image pull, ~3+ min on cold pull. Regression net: `tests/test-local-ci.sh` (14 assertions, CI-pinned). Skip when working on docs-only changes.

### Bump and tag

**Automated path (preferred since v1.32.14):**

```bash
bash tools/release.sh X.Y.Z
```

This runs steps 7-14 below in order, validating preconditions (clean tree, on `main`, X.Y.Z is above current, tag doesn't exist, no leftover `.hotfix-sweep-quick` marker) before any mutation. `--dry-run` previews; `--no-watch` skips the post-flight CI watch (still tags + pushes). Regression net: `tests/test-release.sh` (53 assertions, CI-pinned).

`--ci-preflight` *(recommended since v1.34.1)* makes `tools/local-ci.sh` (Pre-flight Step 7) the gating artifact for the release. The script runs local-ci as Step 6.5 BEFORE the version bump; on green, the post-flight `gh run watch` is skipped — reclaiming the 6–13 minutes of remote-CI wall-clock per release that `--tag-on-green` spent watching. Remote CI still runs in parallel as a no-op second opinion. **Requires Docker** (or podman via `OMC_LOCAL_CI_RUNTIME=podman`); on a runtime-missing host the script aborts cleanly at Step 6.5 before any state change. Mutually exclusive with `--tag-on-green` (both gate the tag — pick one). Use `--tag-on-green` as the no-Docker fallback.

`--tag-on-green` *(opt-in, v1.33.x; superseded by `--ci-preflight` for hosts with Docker)* reorders the flow so the commit is pushed BEFORE the tag is created, CI is watched on the unverified commit, and the tag (+ push tag + GH release) only happens when CI returns green. Eliminates the v1.33.x-style version-bump cascade when the failure is a test bug, not a user-facing defect — a CI failure under `--tag-on-green` leaves the commit on `main` with no tag, and the user pushes fixup commits on the same VERSION instead of bumping. Mutually exclusive with `--no-watch` (the watch is what gates the tag) and `--ci-preflight` (both gate the tag — pick one). Default behavior unchanged.

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
