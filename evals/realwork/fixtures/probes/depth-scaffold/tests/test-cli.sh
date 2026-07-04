#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

out="$("${SCRIPT_DIR}/bin/statsum" 1 2 3)"
if [[ "${out}" == "total=6" ]]; then
  printf 'test-cli: 1 passed, 0 failed\n'
  exit 0
fi
printf 'FAIL cli total: expected=total=6 actual=%s\n' "${out}"
printf 'test-cli: 0 passed, 1 failed\n'
exit 1
