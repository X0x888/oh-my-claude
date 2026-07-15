#!/usr/bin/env bash
#
# tools/list-ci-pinned-tests.sh — single source of truth for extracting
# CI-pinned bash test paths from .github/workflows/validate.yml.
#
# Emits unique `tests/test-*.sh` paths, one per line. Supports:
#   - bare `run: bash tests/test-foo.sh`
#   - env-prefixed `run: OMC_X=y bash tests/test-foo.sh`
#   - compound lines with multiple tests
#   - block forms (`run: |` / `run: >`) whose indented body contains
#     one or more bash test invocations
#   - `bash tools/run-tests.sh --full ...`, which dynamically represents every
#     current `tests/test-*.sh` file without maintaining a second CI list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATE_YML="${1:-${REPO_ROOT}/.github/workflows/validate.yml}"

if [[ ! -f "${VALIDATE_YML}" ]]; then
  printf 'validate workflow not found: %s\n' "${VALIDATE_YML}" >&2
  exit 1
fi

scan_tmp="$(mktemp "${TMPDIR:-/tmp}/omc-ci-pins.XXXXXX")"
trap 'rm -f "${scan_tmp}"' EXIT

awk '
function leading_spaces(line, pos) {
  if (match(line, /[^ ]/)) {
    return RSTART - 1
  }
  return length(line)
}

function emit_tests(text, remaining) {
  remaining = text
  while (match(remaining, /tests\/test-[A-Za-z0-9._-]+\.sh/)) {
    print substr(remaining, RSTART, RLENGTH)
    remaining = substr(remaining, RSTART + RLENGTH)
  }
  if (text ~ /(^|[[:space:]])(bash[[:space:]]+)?tools\/run-tests\.sh([[:space:]]|$)/ &&
      text ~ /(^|[[:space:]])--full([[:space:]]|$)/) {
    print "__OMC_FULL_BASH_SUITE__"
  }
}

BEGIN {
  in_block = 0
  block_indent = -1
}

{
  if (in_block) {
    if ($0 ~ /^[[:space:]]*$/) {
      next
    }

    current_indent = leading_spaces($0)
    if (current_indent <= block_indent) {
      in_block = 0
    } else {
      emit_tests($0)
      next
    }
  }

  if ($0 ~ /^[[:space:]]+(-[[:space:]]+)?run:[[:space:]]*/) {
    run_text = $0
    sub(/^[[:space:]]+(-[[:space:]]+)?run:[[:space:]]*/, "", run_text)
    if (run_text ~ /^(\||>)[-+]?$/) {
      in_block = 1
      block_indent = leading_spaces($0)
      next
    }
    emit_tests(run_text)
  }
}
' "${VALIDATE_YML}" > "${scan_tmp}"

{
  awk '/^tests\/test-[A-Za-z0-9._-]*\.sh$/{print}' "${scan_tmp}"
  if grep -qx '__OMC_FULL_BASH_SUITE__' "${scan_tmp}"; then
    for test_path in "${REPO_ROOT}"/tests/test-*.sh; do
      [[ -f "${test_path}" ]] || continue
      printf '%s\n' "${test_path#"${REPO_ROOT}/"}"
    done
  fi
} | LC_ALL=C sort -u
