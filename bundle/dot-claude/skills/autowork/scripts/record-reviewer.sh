#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

REVIEWER_TYPE="${1:-standard}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

if ! is_ultrawork_mode; then
  exit 0
fi

# Detect whether the reviewer reported actionable findings.
# Conservative: assume findings unless the summary explicitly says clean.
review_message="$(json_get '.last_assistant_message')"
has_findings="true"
if [[ -n "${review_message}" ]]; then
  if printf '%s' "${review_message}" \
    | grep -Eiq '\b(no (significant |major |critical |high.severity )?issues|looks (good|clean|solid)|well[- ]implemented|no findings|no defects|passes review|code is correct)\b'; then
    # Tentatively clean, but override if qualifiers point to actual findings
    if printf '%s' "${review_message}" \
      | grep -Eiq '\b(but|however|though|although)\b.*\b(issue|concern|finding|problem|bug|regression|defect|risk)\b'; then
      has_findings="true"
    else
      has_findings="false"
    fi
  fi
fi

write_state_batch \
  "last_review_ts" "$(now_epoch)" \
  "review_had_findings" "${has_findings}" \
  "stop_guard_blocks" "0" \
  "session_handoff_blocks" "0"

if [[ "${REVIEWER_TYPE}" == "excellence" ]]; then
  write_state "last_excellence_review_ts" "$(now_epoch)"
fi
