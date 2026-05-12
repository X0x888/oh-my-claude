#!/usr/bin/env bash
#
# tools/release.sh — release automation that wraps CONTRIBUTING.md
# bump-and-tag steps 7-14 into a single command.
#
# v1.32.14 (R4 closure from the v1.32.0 release post-mortem). The
# original R4 said "stage-then-promote release flow"; the metis
# stress-test of that proposal flagged the muscle-memory risk: a
# 14-step manual process gets skipped under time pressure (user
# tagged v1.32.6 and pushed before noticing v1.32.6's CI was red,
# producing the v1.32.7 hotfix). Automation closes that — the
# script either runs every step in order or fails early with a
# named blocker, never partway-through.
#
# This script does NOT replace tools/hotfix-sweep.sh — sweep is
# Pre-flight Step 6 (run before this script). Sweep validates
# correctness; this script automates ceremony.
#
# Usage:
#   bash tools/release.sh X.Y.Z                 # full release flow (default: --tag-on-green + watch)
#   bash tools/release.sh X.Y.Z --ci-preflight  # run local-ci as gate, tag immediately, no watch
#   bash tools/release.sh X.Y.Z --tag-on-green  # explicit: push first, watch CI, tag only on green
#   bash tools/release.sh X.Y.Z --legacy-eager-tag # opt back into pre-v1.40 default (eager-tag + watch)
#   bash tools/release.sh X.Y.Z --dry-run       # print steps without executing
#   bash tools/release.sh X.Y.Z --no-watch      # skip CI watch; with no other flags this falls back to legacy eager-tag for compatibility
#
# v1.40.x (SRE-3 F-009): tag-on-green is now the default. Pre-fix
# default was eager-tag, which on a red CI left a published tag +
# GitHub release pointing at broken code with no automatic rollback
# (the v1.33.0/.1/.2 hotfix-cascade pattern). The new default is
# safe-by-default: commit pushed first, CI watched, tag created only
# on green. Opt back into eager-tag via --legacy-eager-tag.
#
# v1.34.1 — `--ci-preflight` is the recommended default. It runs
# tools/local-ci.sh BEFORE the version bump (Ubuntu-container parity
# of validate.yml). If local-ci passes, the commit is known-CI-green
# before we tag, and the post-flight `gh run watch` is skipped — the
# 6-13 minutes of remote-CI wall-clock per release that --tag-on-green
# spent watching is reclaimed. CI still runs in parallel as a no-op
# second opinion (observable via `gh run list`), but does not block.
# Use --tag-on-green as the fallback for environments without Docker
# or when you suspect local-ci fidelity issues.
#
# Pre-conditions (script verifies and exits early if missing):
#   - Argument is valid X.Y.Z semver
#   - Working tree is clean (no uncommitted changes)
#   - On `main` branch
#   - VERSION currently below requested version
#   - tools/hotfix-sweep.sh exits 0 (call it first as Pre-flight Step 6)
#
# Steps executed:
#   6.5. Local-ci pre-flight (v1.34.1; only under --ci-preflight)
#   7. Update VERSION
#   8. Update README badge
#   9. Promote [Unreleased] in CHANGELOG to [X.Y.Z]
#   9b. Re-run CHANGELOG-coupled tests (v1.32.7/8 process fix)
#   10. Commit
#   11. Tag vX.Y.Z
#   12. Push commits + tags
#   13. Create GitHub release
#   14. Watch CI on the tagged commit (skipped under --no-watch / --ci-preflight)

set -euo pipefail

VERSION_ARG="${1:-}"
DRY_RUN=0
NO_WATCH=0
# v1.40.x SRE-3 F-009: TAG_ON_GREEN defaults to 1 (safe-by-default).
# Pre-fix: default was eager-tag — commit + tag + push + GitHub release
# BEFORE the CI watch. A red CI on the tagged commit left a published
# tag + GH release pointing at broken code with no automatic rollback,
# requiring a hotfix-version-bump cascade (the v1.33.0/.1/.2 pattern).
# Now: tag-on-green is the default; commit pushed first, CI watched,
# tag created only on green. Opt back into eager-tag via
# --legacy-eager-tag for environments where the post-push delay before
# tag is unacceptable (or as a temporary escape if tag-on-green has a
# bug — surface the bug; don't silently regress to eager-tag).
TAG_ON_GREEN=1
TAG_ON_GREEN_EXPLICIT=0
LEGACY_EAGER_TAG=0
CI_PREFLIGHT=0
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-watch) NO_WATCH=1; shift ;;
    --tag-on-green) TAG_ON_GREEN=1; TAG_ON_GREEN_EXPLICIT=1; LEGACY_EAGER_TAG=0; shift ;;
    --legacy-eager-tag) LEGACY_EAGER_TAG=1; TAG_ON_GREEN=0; shift ;;
    --ci-preflight) CI_PREFLIGHT=1; TAG_ON_GREEN=0; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# v1.40.x F-009: graceful default-fallback for --no-watch. Pre-fix,
# --no-watch was compatible with the eager-tag default. Now that
# tag-on-green is the default, --no-watch alone would conflict
# (tag-on-green requires the watch to know whether to tag). Treat
# `bash tools/release.sh X.Y.Z --no-watch` as a request for the
# legacy eager-tag flow — preserves the old muscle memory.
if [[ "${NO_WATCH}" -eq 1 ]] && [[ "${TAG_ON_GREEN_EXPLICIT}" -eq 0 ]] && [[ "${LEGACY_EAGER_TAG}" -eq 0 ]] && [[ "${CI_PREFLIGHT}" -eq 0 ]]; then
  LEGACY_EAGER_TAG=1
  TAG_ON_GREEN=0
  printf '\033[33mnotice:\033[0m --no-watch with no --tag-on-green: falling back to --legacy-eager-tag (matches pre-v1.40 behavior)\n' >&2
fi

# --tag-on-green and --no-watch are mutually exclusive: tag-on-green
# REQUIRES the watch to know whether to tag, so --no-watch makes the
# whole flag a no-op. Reject the combo loudly so the user doesn't
# silently get the legacy eager-tag flow.
if [[ "${TAG_ON_GREEN}" -eq 1 ]] && [[ "${NO_WATCH}" -eq 1 ]]; then
  printf 'error: --tag-on-green and --no-watch are mutually exclusive\n' >&2
  exit 2
fi

# v1.34.1: --ci-preflight makes local-ci the gating artifact instead
# of remote CI. tools/local-ci.sh runs the validate.yml suite inside
# an Ubuntu container, catching the BSD-vs-GNU / mktemp-shape /
# locale / sed-flag / stat-flag class of macOS-vs-Linux divergence
# that v1.33.x's --tag-on-green was added to defend against. With
# local-ci as pre-flight, the post-flight `gh run watch` becomes
# duplicate work and only adds wall-clock latency — so --ci-preflight
# implies --no-watch (CI still runs in parallel, observable via the
# GH UI, but does not block the tag).
#
# --ci-preflight is mutually exclusive with --tag-on-green (both gate
# the tag, but on different artifacts — let the maintainer pick one).
# Compatible with --no-watch (redundant but harmless — the post-flight
# watch is already implicit-skipped).
if [[ "${CI_PREFLIGHT}" -eq 1 ]] && [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
  printf 'error: --ci-preflight and --tag-on-green are mutually exclusive (both gate the tag — pick one)\n' >&2
  exit 2
fi
if [[ "${CI_PREFLIGHT}" -eq 1 ]]; then
  NO_WATCH=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
err() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
say() { printf '── %s ───\n' "$1"; }
run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ----------------------------------------------------------------------
# Validate input + state
# ----------------------------------------------------------------------
say "Validate"

[[ -z "${VERSION_ARG}" ]] && err "missing version argument. Usage: bash tools/release.sh X.Y.Z [--dry-run] [--no-watch]"

if [[ ! "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err "version must be X.Y.Z (semver), got: ${VERSION_ARG}"
fi

if ! command -v git >/dev/null 2>&1; then err "git not found in PATH"; fi
if ! command -v jq >/dev/null 2>&1; then err "jq not found in PATH"; fi

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  err "working tree is not clean — commit or stash first"
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
  err "must be on main, got: ${CURRENT_BRANCH}"
fi

CURRENT_VERSION="$(cat VERSION 2>/dev/null | tr -d '[:space:]')"
[[ -z "${CURRENT_VERSION}" ]] && err "VERSION file is empty or missing"

# Refuse to release a version that's not strictly above the current.
# Compare via sort -V (handles 1.10 > 1.9 correctly).
SORTED="$(printf '%s\n%s\n' "${CURRENT_VERSION}" "${VERSION_ARG}" | sort -V)"
LOWER="$(printf '%s' "${SORTED}" | head -1)"
if [[ "${LOWER}" != "${CURRENT_VERSION}" ]] || [[ "${VERSION_ARG}" == "${CURRENT_VERSION}" ]]; then
  err "version ${VERSION_ARG} is not above current ${CURRENT_VERSION}"
fi

if git rev-parse "v${VERSION_ARG}" >/dev/null 2>&1; then
  err "tag v${VERSION_ARG} already exists locally"
fi

ok "validate: ${CURRENT_VERSION} → ${VERSION_ARG} on ${CURRENT_BRANCH}, working tree clean"

# ----------------------------------------------------------------------
# Step 6 reminder — hotfix-sweep is the user's responsibility, not
# this script's. Surface it loudly so the user can't auto-pilot
# past it.
# ----------------------------------------------------------------------
say "Hotfix-sweep reminder"
if [[ -f "${REPO_ROOT}/.hotfix-sweep-quick" ]]; then
  err "last sweep was --quick — re-run 'bash tools/hotfix-sweep.sh' (no --quick) before tagging"
fi
# v1.32.15 (G4 fix): the marker is ONLY present when --quick was
# used. A maintainer who never ran sweep at all also sees "marker
# absent". Wording reflects that this is a guard against a known
# anti-pattern, not a positive verification.
ok "no --quick marker found (ensure tools/hotfix-sweep.sh was run as Pre-flight Step 6)"

# ----------------------------------------------------------------------
# Step 6.5 (v1.34.1) — local-ci pre-flight
#
# When --ci-preflight is set, run tools/local-ci.sh (validate.yml
# suite inside an Ubuntu container) BEFORE the version bump. If
# local-ci passes, the commit is known-CI-green BEFORE we tag — the
# post-flight `gh run watch` becomes redundant and is skipped.
#
# Local-ci is the gating artifact, not remote CI. This shifts trust
# from "wait for GitHub Actions" → "Ubuntu container locally is
# faithful to GitHub Actions". If a CI failure ever occurs that
# local-ci didn't catch, that's a local-ci fidelity bug to fix —
# not a reason to wait through CI runs on every release.
#
# Skipped under --dry-run (the dry-run preview should not actually
# spin up Docker). Aborts on local-ci failure — no commit, no tag.
# ----------------------------------------------------------------------
if [[ "${CI_PREFLIGHT}" -eq 1 ]]; then
  say "Step 6.5 (v1.34.1): local-ci pre-flight"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '  [dry-run] bash tools/local-ci.sh\n'
  else
    if ! bash "${REPO_ROOT}/tools/local-ci.sh"; then
      err "local-ci pre-flight failed — fix the failures before tagging. (Or fall back to --tag-on-green if local-ci has fidelity issues with your CI environment.)"
    fi
    ok "local-ci pre-flight green — post-flight CI watch will be skipped"
  fi
fi

# ----------------------------------------------------------------------
# Step 7-9 — VERSION, badge, CHANGELOG promotion
# ----------------------------------------------------------------------
say "Step 7: bump VERSION"
run sh -c "printf '%s\n' '${VERSION_ARG}' > VERSION"
ok "VERSION → ${VERSION_ARG}"

say "Step 8: update README badge"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  # v1.32.15 (G5 fix): match the actual implementation (perl -i -pe
  # not sed -i — perl is portable across macOS BSD-sed and Linux
  # GNU-sed; sed -i differs incompatibly between the two).
  printf '  [dry-run] perl -i -pe "s/Version-%s-blue/Version-%s-blue/" README.md\n' "${CURRENT_VERSION}" "${VERSION_ARG}"
  printf '  [dry-run] ✓ README badge → %s (would-emit on real run)\n' "${VERSION_ARG}"
else
  if grep -q "Version-${CURRENT_VERSION}-blue" README.md; then
    perl -i -pe "s/Version-${CURRENT_VERSION}-blue/Version-${VERSION_ARG}-blue/" README.md
    ok "README badge → ${VERSION_ARG}"
  else
    err "README.md does not contain Version-${CURRENT_VERSION}-blue badge — manual update required"
  fi
fi

say "Step 9: promote [Unreleased] in CHANGELOG"
TODAY="$(date +%Y-%m-%d)"

# v1.32.15 (G1 fix from v1.32.14 reviewer): pre-validate the
# [Unreleased] heading is exactly `## [Unreleased]` with no trailing
# whitespace and LF line endings before the perl substitution. Pre-
# 1.32.15 the perl regex `^(## \[Unreleased\])$` silent-no-op'd on
# trailing-space or CRLF — perl exited 0, the script emitted "✓
# CHANGELOG promoted", but no substitution happened. Then VERSION
# was bumped, README updated, commit + tag + push proceeded with
# a stale CHANGELOG.
if ! grep -nE '^## \[Unreleased\]$' CHANGELOG.md >/dev/null 2>&1; then
  # Diagnose the specific failure shape so the maintainer can fix.
  # CRLF check FIRST (before generic trailing-whitespace) — \r is
  # whitespace under [[:space:]], so the wider check would otherwise
  # mask the CRLF-specific diagnosis.
  if grep -nE $'^## \\[Unreleased\\]\r$' CHANGELOG.md >/dev/null 2>&1; then
    err "[Unreleased] heading has CRLF line endings — convert to LF before re-running"
  elif grep -nE '^## \[Unreleased\][[:space:]]+$' CHANGELOG.md >/dev/null 2>&1; then
    err "[Unreleased] heading has trailing whitespace — fix CHANGELOG.md before re-running"
  elif ! grep -E '^## \[Unreleased\]' CHANGELOG.md >/dev/null 2>&1; then
    err "[Unreleased] heading not found in CHANGELOG.md — release.sh requires it"
  else
    err "[Unreleased] heading is malformed (does not match \`^## \\[Unreleased\\]\$\`)"
  fi
fi

# v1.32.15 (G2 fix): refuse to ship an empty [Unreleased] section.
# Count non-blank lines between [Unreleased] and the next ## heading.
unrel_content_lines="$(awk '
  /^## \[Unreleased\]$/ { in_unrel = 1; next }
  /^## / && in_unrel    { exit }
  in_unrel && NF > 0    { count++ }
  END { print count + 0 }
' CHANGELOG.md)"
if [[ "${unrel_content_lines}" -eq 0 ]]; then
  err "[Unreleased] section is empty — add release notes before tagging v${VERSION_ARG}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '  [dry-run] insert "## [%s] - %s" below "## [Unreleased]"\n' "${VERSION_ARG}" "${TODAY}"
else
  # Insert "## [X.Y.Z] - YYYY-MM-DD" below the [Unreleased] line.
  # Keep [Unreleased] as an empty placeholder for the next cycle.
  perl -i -pe "s|^(## \\[Unreleased\\])\$|\$1\n\n## [${VERSION_ARG}] - ${TODAY}|" CHANGELOG.md
  # v1.32.15 (G1 fix): verify the substitution actually happened.
  # Pre-validation above should prevent the silent-no-op case, but
  # belt-and-suspenders: confirm the new heading is now in the file.
  if ! grep -qE "^## \\[${VERSION_ARG}\\] - ${TODAY}\$" CHANGELOG.md; then
    err "Step 9 promotion did not produce the expected heading — CHANGELOG.md not modified. Check the [Unreleased] heading manually."
  fi
  ok "CHANGELOG promoted → [${VERSION_ARG}] - ${TODAY}"
fi

# ----------------------------------------------------------------------
# Step 9b — re-run CHANGELOG-coupled tests after promotion
# (v1.32.7/8 process fix; 5 prior releases shipped CI-red because
# step 2 ran against pre-promotion CHANGELOG).
#
# v1.32.15 (G3 contract clarification): the grep matches tests that
# either reference `CHANGELOG.md` literally OR call `extract_whats_new`.
# A future test that reads CHANGELOG via other paths (e.g.,
# `git show v1.32.13:CHANGELOG.md`) without these strings would slip
# past this filter — add one of the strings to the test's prose to
# make it discoverable. Mirrors the discovered_scope_capture_targets
# precedent in common.sh.
# ----------------------------------------------------------------------
say "Step 9b: re-run CHANGELOG-coupled tests"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '  [dry-run] for t in $(grep -lE CHANGELOG.md tests/test-*.sh); do bash $t; done\n'
else
  coupled_failures=0
  while IFS= read -r t; do
    if ! bash "${t}" >/dev/null 2>&1; then
      printf '  ✗ %s\n' "$(basename "${t}")" >&2
      coupled_failures=$((coupled_failures + 1))
    fi
  done < <(grep -lE 'CHANGELOG\.md|extract_whats_new' "${REPO_ROOT}"/tests/test-*.sh 2>/dev/null)
  if [[ "${coupled_failures}" -gt 0 ]]; then
    err "${coupled_failures} CHANGELOG-coupled test(s) failed after promotion — fix before tagging"
  fi
  ok "CHANGELOG-coupled tests pass"
fi

# ----------------------------------------------------------------------
# Step 10-12 — commit, tag, push
#
# v1.33.x added `--tag-on-green` (opt-in): commit + push BEFORE creating
# the tag, watch CI on the just-pushed commit, then tag (+ push tag +
# GH release) only on green. Recovery if CI red: the commit is on main,
# no tag exists, no GH release exists. Push fixup commit(s), then run
# `git tag v${VERSION_ARG} && git push --tags && gh release create
# v${VERSION_ARG} --notes-file <(awk '/^## \\[${VERSION_ARG}\\]/{...}'
# CHANGELOG.md)` manually. Eliminates the v1.33.0/.1/.2-style version-
# bump cascade when the failure is a test bug, not a user-facing defect.
#
# Default (legacy eager-tag) flow stays identical so muscle-memory
# `bash tools/release.sh X.Y.Z` is unchanged.
# ----------------------------------------------------------------------
say "Step 10-12: commit + tag + push"
COMMIT_MSG="Release v${VERSION_ARG}"
run git add VERSION README.md CHANGELOG.md
run git commit -m "${COMMIT_MSG}"

if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
  # Push commit only (no tag yet). The tag is conditional on CI green.
  run git push origin main
  ok "commit pushed (tag deferred until CI green — --tag-on-green)"
else
  run git tag "v${VERSION_ARG}"
  run git push origin main
  run git push --tags
  ok "tagged v${VERSION_ARG} and pushed"
fi

# ----------------------------------------------------------------------
# Step 13 — GitHub release
#
# Under --tag-on-green, this step is deferred to AFTER step 14's CI watch
# (a green CI is the precondition for tagging, and the GH release needs
# the tag to exist). The legacy eager-tag flow runs it inline here.
# ----------------------------------------------------------------------
emit_github_release() {
  if ! command -v gh >/dev/null 2>&1; then
    printf '  warn: gh CLI not found — skipping release create. Run manually:\n' >&2
    printf '    awk "/^## \\\\[%s\\\\]/{found=1;next} /^## \\\\[/{if(found)exit} found" CHANGELOG.md \\\n' "${VERSION_ARG}"
    printf '      | gh release create v%s --title v%s --notes-file -\n' "${VERSION_ARG}" "${VERSION_ARG}"
    return 0
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '  [dry-run] gh release create v%s --title v%s --notes-file <(awk extract)\n' "${VERSION_ARG}" "${VERSION_ARG}"
    return 0
  fi
  local release_notes
  release_notes="$(awk "/^## \\[${VERSION_ARG}\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md)"
  if [[ -z "${release_notes}" ]]; then
    printf '  warn: no CHANGELOG section found for v%s — release will have empty notes\n' "${VERSION_ARG}" >&2
  fi
  printf '%s' "${release_notes}" | gh release create "v${VERSION_ARG}" --title "v${VERSION_ARG}" --notes-file - 2>&1 | head -3
  ok "GitHub release created"
}

if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
  say "Step 13: GitHub release (deferred — runs after CI green under --tag-on-green)"
else
  say "Step 13: GitHub release"
  emit_github_release
fi

# ----------------------------------------------------------------------
# Step 14 — watch CI
# ----------------------------------------------------------------------
if [[ "${NO_WATCH}" -eq 1 ]]; then
  if [[ "${CI_PREFLIGHT}" -eq 1 ]]; then
    say "Step 14: skipped (--ci-preflight already validated; CI runs in parallel)"
    printf '  Local-ci was the release gate. Remote CI will run in parallel —\n'
    printf '  observe via: gh run list --branch main --limit 3\n'
    printf '  A remote-CI failure on this commit implies local-ci fidelity drift —\n'
    printf '  reproduce locally with: bash tools/local-ci.sh\n'
  else
    say "Step 14: skipped (--no-watch)"
    printf '  Re-watch later: gh run watch --exit-status \\\n'
    printf '    "$(gh run list --commit "$(git rev-parse v%s)" --limit 1 --json databaseId -q ".[0].databaseId")"\n' "${VERSION_ARG}"
  fi
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  say "Step 14: watch CI (dry-run)"
  printf '  [dry-run] gh run watch --exit-status <run-id-for-v%s>\n' "${VERSION_ARG}"
elif command -v gh >/dev/null 2>&1; then
  say "Step 14: watch CI"
  # Under --tag-on-green, the tag doesn't exist yet — query the run by
  # the just-pushed commit SHA. Under eager-tag, the tag exists and we
  # query by tag SHA (same SHA, different lookup path; either works).
  if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
    WATCH_REF="$(git rev-parse HEAD)"
  else
    WATCH_REF="$(git rev-parse "v${VERSION_ARG}")"
  fi
  # GitHub Actions can take a few seconds to register the run after the
  # push. Poll for up to ~30s before giving up. Without this the immediate
  # `gh run list` returns empty even though a run is about to start.
  RUN_ID=""
  for poll in 1 2 3 4 5 6; do
    RUN_ID="$(gh run list --commit "${WATCH_REF}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
    [[ -n "${RUN_ID}" ]] && break
    sleep 5
  done
  if [[ -z "${RUN_ID}" ]]; then
    if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
      printf '\n[warn] no CI run registered after ~30s — under --tag-on-green this means\n' >&2
      printf '  the tag CANNOT be created automatically. The commit IS on main.\n' >&2
      printf '  Recovery: wait for the run, then `gh run watch --exit-status <id>`\n' >&2
      printf '  and on green: `git tag v%s && git push --tags`\n' "${VERSION_ARG}" >&2
      err "tag-on-green: no CI run found"
    else
      printf '  warn: no CI run found for v%s yet — re-watch later\n' "${VERSION_ARG}" >&2
    fi
  else
    if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
      printf '  watching run %s (Ctrl-C to detach; tag will be created ONLY on green)\n' "${RUN_ID}"
    else
      printf '  watching run %s (Ctrl-C to detach; tag is already pushed regardless)\n' "${RUN_ID}"
    fi
    if gh run watch --exit-status "${RUN_ID}" >/dev/null 2>&1; then
      ok "CI green on v${VERSION_ARG}"
      if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
        say "Step 11+13: tag + GH release (CI green)"
        run git tag "v${VERSION_ARG}"
        run git push --tags
        ok "tagged v${VERSION_ARG} after green CI"
        emit_github_release
      fi
    else
      # v1.33.x diagnostic hint (post-mortem of v1.33.0/.1/.2 cascade).
      # The most expensive class of "passes locally / fails in CI" miss
      # was: test setup re-exports HOME/TMPDIR, and the patch used the
      # already-overridden ${HOME} instead of ORIG_HOME (or another
      # outside-denylist path). Print the canonical first-look grep
      # before the err so the maintainer doesn't repeat that miss.
      printf '\n[hint] CI red on the %s. Common diagnostic miss:\n' \
        "$( [[ "${TAG_ON_GREEN}" -eq 1 ]] && printf 'pushed commit (tag NOT created)' || printf 'tagged commit' )" >&2
      printf '  - test setup may re-export HOME/TMPDIR/PATH — `${HOME}` in the\n' >&2
      printf '    test body may NOT be the real home. Before patching, run:\n' >&2
      printf '      grep -nE "HOME=|TMPDIR=|PATH=|export HOME|mktemp" tests/<failing-test>.sh\n' >&2
      printf '    If `setup_test`/equivalent re-exports HOME, use `ORIG_HOME`\n' >&2
      printf '    (saved before any test override) for paths that must escape\n' >&2
      printf '    the active denylist.\n' >&2
      if [[ "${TAG_ON_GREEN}" -eq 1 ]]; then
        printf '\n[recovery] The Release v%s commit is on main without a tag.\n' "${VERSION_ARG}" >&2
        printf '  Push fixup commit(s), watch CI green, then manually:\n' >&2
        printf '    git tag v%s && git push --tags && \\\n' "${VERSION_ARG}" >&2
        printf '    awk "/^## \\\\[%s\\\\]/{f=1;next} /^## \\\\[/{if(f)exit} f" CHANGELOG.md | \\\n' "${VERSION_ARG}" >&2
        printf '      gh release create v%s --title v%s --notes-file -\n' "${VERSION_ARG}" "${VERSION_ARG}" >&2
      fi
      err "CI failed on v${VERSION_ARG} — see gh run view ${RUN_ID}"
    fi
  fi
fi

# ----------------------------------------------------------------------
say "Release v${VERSION_ARG} complete"
[[ "${DRY_RUN}" -eq 1 ]] && printf 'Dry-run: no changes were made.\n'
exit 0
