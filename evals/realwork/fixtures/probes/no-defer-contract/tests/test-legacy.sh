#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/parse.sh"

pass=0 fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: expected=%q actual=%q\n' "${label}" "${expected}" "${actual}"
    fail=$((fail + 1))
  fi
}

# Deprecated flag still parses until its scheduled 1.0 removal.
parse_args --legacy-mode "old line"
check "legacy flag sets marker" "1" "${PARSED_LEGACY}"

printf 'test-legacy: %d passed, %d failed\n' "${pass}" "${fail}"
exit "$(( fail > 0 ? 1 : 0 ))"
