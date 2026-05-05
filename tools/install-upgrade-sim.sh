#!/usr/bin/env bash
#
# tools/install-upgrade-sim.sh — black-box install.sh upgrade simulation.
#
# v1.32.0 R8 (release post-mortem remediation): the v1.31.1-hotfix-round-2
# bug (install.sh "What's new" cap was 6 but 7 versions were needed for
# a real upgrade span) shipped because there was no end-to-end check
# that ran install.sh against representative `PRIOR_INSTALLED_VERSION`
# values and inspected the user-visible output. The unit test
# (test-install-whats-new.sh) covers `extract_whats_new` directly; T8
# (added in same release) asserts no truncation against representative
# spans. This script is the integration-level complement: actually run
# install.sh and capture the install-summary block a real user sees.
#
# Developer-only tool — NOT installed by install.sh, lives under
# tools/ alongside other devs aids.
#
# Usage:
#   bash tools/install-upgrade-sim.sh           # run the 4-case matrix
#   bash tools/install-upgrade-sim.sh --strict  # exit non-zero on any cap-truncation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mode="advisory"
[[ "${1:-}" == "--strict" ]] && mode="strict"

cd "${REPO_ROOT}"
current_version="$(cat VERSION)"

# Build representative PRIOR_INSTALLED_VERSION matrix (per metis stress-test
# R8-undefined-priors finding — concrete enumeration, not "representative"
# hand-wave):
#   case A: empty                — first install (block guarded out)
#   case B: N-1                  — common case, single-version upgrade
#   case C: oldest in CHANGELOG  — long-span upgrade (the v1.31.1 bug shape)
#   case D: current              — no-op same-version reinstall
declare -a cases
cases=()

# A — first install
cases+=("first_install|")

# B — N-1: previous tag (highest tag below current). Sort -V is on coreutils.
prev_tag="$(git tag --list 'v*' 2>/dev/null \
  | sed 's/^v//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V \
  | tail -2 | head -1)"
[[ -n "${prev_tag}" && "${prev_tag}" != "${current_version}" ]] && \
  cases+=("n_minus_1|${prev_tag}")

# C — oldest CHANGELOG entry (long span). Parse `## [X.Y.Z]` headings.
oldest_changelog="$(awk '/^## \[/ { gsub(/^## \[|\].*/, ""); if ($0 != "Unreleased") print $0 }' \
    "${REPO_ROOT}/CHANGELOG.md" 2>/dev/null \
  | sort -V \
  | head -1)"
[[ -n "${oldest_changelog}" && "${oldest_changelog}" != "${current_version}" ]] && \
  cases+=("long_span_oldest|${oldest_changelog}")

# D — current (no-op)
cases+=("noop_same|${current_version}")

printf '── install-upgrade-sim — current=%s ───\n' "${current_version}"
printf 'Cases: %d\n\n' "${#cases[@]}"

failures=0
for case_entry in "${cases[@]}"; do
  case_name="${case_entry%%|*}"
  prior="${case_entry#*|}"

  test_home="$(mktemp -d)"
  # Pre-stage a conf with the prior installed_version, mimicking how
  # a real user's machine looks before re-running install.sh.
  if [[ -n "${prior}" ]]; then
    mkdir -p "${test_home}/.claude"
    printf 'installed_version=%s\n' "${prior}" > "${test_home}/.claude/oh-my-claude.conf"
  fi

  # Run install.sh in dry-mode-like fashion: capture the install
  # banner + "What's new" block by setting CLAUDE_HOME and parsing
  # the printed output. We don't actually want to mutate the user's
  # ~/.claude — wrap with a sandboxed CLAUDE_HOME.
  install_out="$(
    CLAUDE_HOME="${test_home}/.claude" \
    HOME="${test_home}" \
    BACKUP_DIR="${test_home}/.claude/backups" \
    bash "${REPO_ROOT}/install.sh" 2>&1 \
    | sed -n '/^## /,/Output style:/ p; /What.s new/,/CHANGELOG.md for details/ p' \
    || true
  )"

  printf '── case: %s (prior=%s) ───\n' "${case_name}" "${prior:-<empty>}"
  if [[ -z "${install_out}" ]]; then
    printf '  (no What.s new block emitted)\n'
  else
    printf '%s\n' "${install_out}"
  fi

  # Pass/fail logic:
  truncated=0
  if printf '%s' "${install_out}" | grep -q "older entries"; then
    truncated=1
  fi

  if [[ "${case_name}" == "long_span_oldest" && "${truncated}" -eq 1 ]]; then
    printf '  WARNING: cap-truncation marker present for long-span upgrade.\n' >&2
    printf '           This is the v1.31.1-cap-was-6 class. Bump cap or accept.\n' >&2
    failures=$((failures + 1))
  fi

  rm -rf "${test_home}" 2>/dev/null || true
  printf '\n'
done

printf '── Summary ───\n'
printf '  Cases:    %d\n' "${#cases[@]}"
printf '  Warnings: %d\n' "${failures}"

if [[ "${mode}" == "strict" && "${failures}" -gt 0 ]]; then
  printf '\n[strict] %d cap-truncation warning(s) — release blocked.\n' "${failures}" >&2
  exit 1
fi
exit 0
