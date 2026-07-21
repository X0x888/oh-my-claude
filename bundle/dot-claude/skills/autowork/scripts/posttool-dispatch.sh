#!/usr/bin/env bash
#
# posttool-dispatch.sh — single-process PostToolUse dispatcher (v1.48 W3.1).
#
# Before: a single Bash tool call spawned four independent hook processes
# (posttool-timing + record-verification + record-delivery-action +
# circuit-breaker), each re-sourcing common.sh at a self-documented
# ~25-30ms cold-start tax on bash 3.2 macOS — ~100ms of pure process/parse
# overhead per Bash call before any hook logic ran. This dispatcher is
# wired on the universal matcher, sources common.sh ONCE, and runs each
# handler script in a pipeline subshell fed the same hook payload:
#
#   - handler scripts stay byte-identical and still work standalone (the
#     mcp__.* matcher keeps invoking record-verification.sh directly);
#   - their `. common.sh` lines short-circuit via the idempotent re-source
#     guard at the top of common.sh (which tops up any lib the handler did
#     not lazy-opt-out of);
#   - their `exit` statements terminate only their own subshell;
#   - $0 inside a sourced handler resolves to THIS script's path, so each
#     handler's own SCRIPT_DIR still points at the scripts directory.
#
# Output contract: every handler except circuit-breaker is silent;
# circuit-breaker is the only handler that emits hook JSON, and it runs last with its stdout
# passing through unmerged. If a future handler starts emitting, it must
# either stay last-and-alone or grow a real merge step here (pinned by
# tests/test-posttool-dispatch.sh).
#
# Routing: Bash tool calls run the edit-clock writer plus the four folded
# handlers; every other tool runs
# timing only — exactly the surface the four separate matchers covered.

set -euo pipefail

# Timing is needed on every dispatch (posttool-timing is the universal
# handler), so let it load eagerly; the classifier is needed by none of
# the four.
export OMC_LAZY_CLASSIFIER=1

_OMC_HOOK_CALLER_PATH="${PATH:-}"
_omc_hook_source="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_omc_hook_source%/*}"
[[ "${SCRIPT_DIR}" == "${_omc_hook_source}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd -P)"
unset _omc_hook_source
_OMC_PIN_OBSERVER_PATH_ON_SOURCE=1
. "${SCRIPT_DIR}/common.sh"
unset _OMC_PIN_OBSERVER_PATH_ON_SOURCE

HOOK_JSON="$(_omc_read_hook_stdin)"
[[ -n "${HOOK_JSON}" ]] || exit 0
if ! _posttool_dispatch_sid="$(jq -er '
    def valid_sid:
      type == "string" and length >= 1 and length <= 128
      and test("^[A-Za-z0-9_.-]+$")
      and . != "." and . != ".."
      and (contains("..") | not) and (test("^\\.+$") | not);
    select(type == "object" and (.session_id | valid_sid))
    | .session_id
  ' <<<"${HOOK_JSON}" 2>/dev/null)"; then
  # Invalid lifecycle identity may not be normalized into another session by
  # Bash (which discards decoded NUL bytes) and then forwarded to every child.
  exit 0
fi
if omc_interrupted_dispatch_transaction_present \
      "${_posttool_dispatch_sid}"; then
  # A tool result already in flight when Agent admission became interrupted
  # must not advance timing/edit/verification/delivery/closeout state around
  # the retained journal. Exact reset is the only convergence owner.
  exit 0
fi

_dispatch_one() {
  # Feed the captured payload to a handler sourced in a pipeline subshell.
  # `|| true`: one handler's failure must not starve the others — the same
  # isolation four separate processes gave us.
  local handler="$1"
  # shellcheck disable=SC1090
  ( printf '%s' "${HOOK_JSON}" | . "${SCRIPT_DIR}/${handler}" ) || true
}

_dispatch_one "posttool-timing.sh"

# Cheap substring pre-filter before the jq fork: non-Bash tools (the common
# case across a session) skip the Bash-only chain without paying for jq.
if [[ "${HOOK_JSON}" == *'"tool_name":"Bash"'* || "${HOOK_JSON}" == *'"tool_name": "Bash"'* ]]; then
  tool_name="$(json_get '.tool_name')"
  if [[ "${tool_name}" == "Bash" ]]; then
    # Must precede verification: if this Bash call is recorded as edit-bearing,
    # mark-edit leaves a per-tool marker and record-verification rejects the
    # same call entirely. A separate post-edit verification call is required.
    _dispatch_one "mark-edit.sh"
    _dispatch_one "record-verification.sh"
    _dispatch_one "record-delivery-action.sh"
    _dispatch_one "circuit-breaker.sh"
  fi
fi

exit 0
