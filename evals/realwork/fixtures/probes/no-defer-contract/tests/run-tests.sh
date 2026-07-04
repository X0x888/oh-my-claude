#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

overall=0
for t in "${SCRIPT_DIR}"/test-*.sh; do
  bash "${t}" || overall=1
done

if [[ "${overall}" -eq 0 ]]; then
  printf 'ALL GREEN\n'
else
  printf 'SUITE FAILED\n'
fi
exit "${overall}"
