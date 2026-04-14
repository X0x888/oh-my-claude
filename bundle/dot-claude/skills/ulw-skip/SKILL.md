---
name: ulw-skip
description: Skip the current quality gate block once with a logged reason. Use when a gate is blocking but you're confident the work is complete. The skip is recorded for threshold tuning.
argument-hint: <reason>
---
# Skip Current Gate

Skip the active quality gate block once. The reason is logged to cross-session data for future threshold tuning.

## Usage

The user provides a reason: `/ulw-skip trivial doc fix, no test needed`

## Steps

1. Take the user's reason text (everything after `/ulw-skip`). If no reason provided, use "user override".
2. Run this command to register the skip (replace REASON with the actual reason):

```bash
bash -c '
set -euo pipefail
STATE_ROOT="${HOME}/.claude/quality-pack/state"
latest="$(ls -t "${STATE_ROOT}" 2>/dev/null | grep -v "^\." | head -1 || true)"
[ -z "${latest}" ] && { echo "No active ULW session found."; exit 0; }
state_file="${STATE_ROOT}/${latest}/session_state.json"
[ -f "${state_file}" ] || { echo "No session state file."; exit 0; }
tmp="$(mktemp "${state_file}.XXXXXX")"
if jq --arg r "'"${REASON}"'" --arg ts "$(date +%s)" \
  ".gate_skip_reason = \$r | .gate_skip_ts = \$ts" \
  "${state_file}" > "${tmp}"; then
  mv "${tmp}" "${state_file}"
  echo "Gate skip registered. The next stop attempt will pass."
  echo "Reason: '"${REASON}"'"
else
  rm -f "${tmp}"
  echo "Failed to register skip."
fi
'
```

3. Confirm to the user that the skip is registered and their next stop attempt will pass through.
4. Remind them that the skip reason is logged for cross-session analysis.
5. Continue working or attempt to stop.
