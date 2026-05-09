#!/usr/bin/env bash
#
# SessionStart drift-check hook.
#
# v1.36.x W1 F-005. Surfaces installed-vs-source drift to the model at
# session start. Pre-1.36 the drift detector lived only in statusline.py,
# producing the `↑v<version>` indicator humans see in the status bar —
# but the model running /ulw never saw it. A user who `git pull`s the
# repo without re-running `bash install.sh` would have hooks loaded from
# the OLD bundle while their source tree carries the NEW version, and
# the model had no way to know.
#
# This hook fires on every SessionStart (no matcher), invokes
# omc_check_install_drift (in common.sh), and emits an additionalContext
# line when drift is detected. The model then knows to nudge the user
# toward `bash install.sh` before relying on any new gate behavior.
#
# Idempotency: emits a single line per session. Per-session
# `drift_check_emitted` state key prevents re-emission across SessionStart
# matchers (e.g., a `compact`-matcher and the catchall both fire).
#
# Disable via `installation_drift_check=false` in the conf or
# `OMC_INSTALLATION_DRIFT_CHECK=false` env. Same flag the statusline
# already honors.

set -euo pipefail

HOOK_JSON="$(cat 2>/dev/null || true)"

# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# Bail early if this hook already emitted for this session — the matcher
# fan-out (resume / compact / catchall) can otherwise produce three
# drift notices on a single SessionStart.
ensure_session_dir
existing_emitted="$(read_state "drift_check_emitted" 2>/dev/null || true)"
if [[ "${existing_emitted}" == "1" ]]; then
  exit 0
fi

drift="$(omc_check_install_drift 2>/dev/null || true)"
if [[ -z "${drift}" ]]; then
  exit 0
fi

# Compose the additionalContext payload. The notice is intentionally
# concise — one bold lead, one fix line, one why line. Model behavior
# we want: when /ulw runs, the model surfaces the drift in its opener
# rather than silently relying on stale gates.
case "${drift}" in
  tag:*)
    drift_version="${drift#tag:}"
    drift_msg="**Bundle drift detected.** The source repo at \`${drift_version}\` is ahead of your installed bundle. Run \`bash install.sh\` from the source tree before relying on new gate behavior — your hooks are still running the old version."
    ;;
  commits:*)
    drift_rest="${drift#commits:}"
    drift_version="${drift_rest%%:*}"
    drift_commits="${drift_rest##*:}"
    drift_msg="**Bundle drift detected.** Your installed bundle (\`${drift_version}\`) is ${drift_commits} commit(s) behind the source repo HEAD. Run \`bash install.sh\` from the source tree to pick up the new commits — your hooks are running the older snapshot."
    ;;
  *)
    exit 0
    ;;
esac

payload="$(jq -nc --arg context "${drift_msg}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${payload}" ]]; then
  log_anomaly "session-start-drift-check" "failed to compose payload"
  exit 0
fi

# Emit the payload BEFORE writing the dedupe state so a failed printf
# (broken pipe to Claude Code, full disk, etc.) leaves the dedupe key
# unset — the next SessionStart fire will retry the notice rather than
# silently silencing it. record_gate_event is idempotent across retries
# (it's append-only) so re-emitting the row on retry is safe.
if ! printf '%s\n' "${payload}"; then
  log_anomaly "session-start-drift-check" "failed to emit payload to stdout"
  exit 0
fi

write_state "drift_check_emitted" "1"

# Emit a gate event so /ulw-report can surface drift-detection rate.
record_gate_event "installation-drift" "drift-detected" \
  "drift_kind=${drift%%:*}" \
  "version=${drift_version:-unknown}" \
  "commits=${drift_commits:-0}"

log_hook "session-start-drift-check" "drift detected: ${drift}"
