#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

# Find the most recent session directory
latest_session=""
if [[ -d "${STATE_ROOT}" ]]; then
  # shellcheck disable=SC2010
  latest_session="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v '^\.' | head -1 || true)"
fi

# Clear the sentinel
rm -f "${STATE_ROOT}/.ulw_active"

if [[ -z "${latest_session}" ]]; then
  printf 'No active ULW session found. Sentinel cleared.\n'
  exit 0
fi

# Clear workflow_mode in the latest session state
SESSION_ID="${latest_session}"
ensure_session_dir
write_state "workflow_mode" ""

printf 'Ultrawork mode deactivated for session %s.\n' "${latest_session}"
