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
#   bash tools/release.sh X.Y.Z          # full release flow
#   bash tools/release.sh X.Y.Z --dry-run # print steps without executing
#   bash tools/release.sh X.Y.Z --no-watch # skip post-flight CI watch (still tags+pushes)
#
# Pre-conditions (script verifies and exits early if missing):
#   - Argument is valid X.Y.Z semver
#   - Working tree is clean (no uncommitted changes)
#   - On `main` branch
#   - VERSION currently below requested version
#   - tools/hotfix-sweep.sh exits 0 (call it first as Pre-flight Step 6)
#
# Steps executed:
#   7. Update VERSION
#   8. Update README badge
#   9. Promote [Unreleased] in CHANGELOG to [X.Y.Z]
#   9b. Re-run CHANGELOG-coupled tests (v1.32.7/8 process fix)
#   10. Commit
#   11. Tag vX.Y.Z
#   12. Push commits + tags
#   13. Create GitHub release
#   14. Watch CI on the tagged commit (skipped under --no-watch)

set -euo pipefail

VERSION_ARG="${1:-}"
DRY_RUN=0
NO_WATCH=0
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-watch) NO_WATCH=1; shift ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

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
# ----------------------------------------------------------------------
say "Step 10-12: commit + tag + push"
COMMIT_MSG="Release v${VERSION_ARG}"
run git add VERSION README.md CHANGELOG.md
run git commit -m "${COMMIT_MSG}"
run git tag "v${VERSION_ARG}"
run git push origin main
run git push --tags
ok "tagged v${VERSION_ARG} and pushed"

# ----------------------------------------------------------------------
# Step 13 — GitHub release
# ----------------------------------------------------------------------
say "Step 13: GitHub release"
if ! command -v gh >/dev/null 2>&1; then
  printf '  warn: gh CLI not found — skipping release create. Run manually:\n' >&2
  printf '    awk "/^## \\\\[%s\\\\]/{found=1;next} /^## \\\\[/{if(found)exit} found" CHANGELOG.md \\\n' "${VERSION_ARG}"
  printf '      | gh release create v%s --title v%s --notes-file -\n' "${VERSION_ARG}" "${VERSION_ARG}"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '  [dry-run] gh release create v%s --title v%s --notes-file <(awk extract)\n' "${VERSION_ARG}" "${VERSION_ARG}"
else
  release_notes="$(awk "/^## \\[${VERSION_ARG}\\]/{found=1;next} /^## \\[/{if(found)exit} found" CHANGELOG.md)"
  if [[ -z "${release_notes}" ]]; then
    printf '  warn: no CHANGELOG section found for v%s — release will have empty notes\n' "${VERSION_ARG}" >&2
  fi
  printf '%s' "${release_notes}" | gh release create "v${VERSION_ARG}" --title "v${VERSION_ARG}" --notes-file - 2>&1 | head -3
  ok "GitHub release created"
fi

# ----------------------------------------------------------------------
# Step 14 — watch CI
# ----------------------------------------------------------------------
if [[ "${NO_WATCH}" -eq 1 ]]; then
  say "Step 14: skipped (--no-watch)"
  printf '  Re-watch later: gh run watch --exit-status \\\n'
  printf '    "$(gh run list --commit "$(git rev-parse v%s)" --limit 1 --json databaseId -q ".[0].databaseId")"\n' "${VERSION_ARG}"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  say "Step 14: watch CI (dry-run)"
  printf '  [dry-run] gh run watch --exit-status <run-id-for-v%s>\n' "${VERSION_ARG}"
elif command -v gh >/dev/null 2>&1; then
  say "Step 14: watch CI"
  RUN_ID="$(gh run list --commit "$(git rev-parse "v${VERSION_ARG}")" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
  if [[ -z "${RUN_ID}" ]]; then
    printf '  warn: no CI run found for v%s yet — re-watch later\n' "${VERSION_ARG}" >&2
  else
    printf '  watching run %s (Ctrl-C to detach; tag is already pushed regardless)\n' "${RUN_ID}"
    if gh run watch --exit-status "${RUN_ID}" >/dev/null 2>&1; then
      ok "CI green on v${VERSION_ARG}"
    else
      err "CI failed on v${VERSION_ARG} — see gh run view ${RUN_ID}"
    fi
  fi
fi

# ----------------------------------------------------------------------
say "Release v${VERSION_ARG} complete"
[[ "${DRY_RUN}" -eq 1 ]] && printf 'Dry-run: no changes were made.\n'
exit 0
