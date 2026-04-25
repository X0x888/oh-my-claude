#!/usr/bin/env bash
#
# find-design-contract.sh
#
# Locate the active session's inline-emitted design contract, if one
# exists. Used by `design-reviewer` and `visual-craft-lens` to read the
# 9-section contract that `frontend-developer` / `ios-ui-developer`
# emitted earlier in the same session, so the drift lens can fire even
# when no project-root `DESIGN.md` exists.
#
# Output: prints the absolute path on stdout when the file exists,
# otherwise empty. Always exits 0 (non-fatal — caller should treat
# empty stdout as "no contract available, fall back to inline criteria").
#
# Session matching uses `discover_latest_session`, which prefers a
# session whose stored cwd matches $PWD (closes the cross-project
# session leak from v1.14.0 Serendipity).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

session_id="$(discover_latest_session 2>/dev/null || true)"
[[ -z "${session_id}" ]] && exit 0

candidate="${STATE_ROOT}/${session_id}/design_contract.md"
[[ -f "${candidate}" ]] || exit 0

printf '%s\n' "${candidate}"
