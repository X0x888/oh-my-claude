#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/render.sh"

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

check "plain passthrough" "hello" "$(render_line plain hello)"
check "boxed framing" "[hello]" "$(render_line boxed hello)"

printf 'test-render: %d passed, %d failed\n' "${pass}" "${fail}"
exit "$(( fail > 0 ? 1 : 0 ))"
