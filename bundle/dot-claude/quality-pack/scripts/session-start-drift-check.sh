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


# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

# v1.41 W3: lazy-init defer (see session-start-whats-new.sh for shape).
# Defer to first UserPromptSubmit so throwaway sessions skip the drift
# check entirely; the dispatcher re-invokes us with OMC_DEFERRED_DISPATCH=1.
if [[ "${OMC_LAZY_SESSION_START:-off}" == "on" ]] && [[ "${OMC_DEFERRED_DISPATCH:-0}" != "1" ]]; then
  ensure_session_dir
  printf '%s\n' "session-start-drift-check.sh" >> "${STATE_ROOT}/${SESSION_ID}/.deferred_session_start_hooks" 2>/dev/null || true
  exit 0
fi

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

# v1.37.x W2 F-002: CWD-aware downgrade — when the current working
# directory is at or under repo_path (the user is editing the source
# repo), drift is expected during dev (the user just made the change
# they haven't installed yet). The full warning stays for OTHER
# projects so you don't lose drift safety repo-wide. The pre-fix
# global escape (installation_drift_check=false) costs you the safety
# in every project; this lets you keep it on globally and still get a
# calm message in the source repo itself.
in_source_repo=0
conf="${HOME}/.claude/oh-my-claude.conf"
if [[ -f "${conf}" ]]; then
  conf_repo_path="$(grep -E '^repo_path=' "${conf}" 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)"
  if [[ -n "${conf_repo_path}" ]] && [[ -d "${conf_repo_path}" ]]; then
    # Resolve both to canonical absolute paths so symlinks / relative
    # PWD don't produce spurious mismatches. PWD must be at OR under
    # repo_path — exact match alone is too narrow (subdirs are still
    # the source tree).
    cwd_resolved="$(cd "${PWD}" && pwd -P 2>/dev/null || true)"
    repo_resolved="$(cd "${conf_repo_path}" && pwd -P 2>/dev/null || true)"
    if [[ -n "${cwd_resolved}" ]] && [[ -n "${repo_resolved}" ]]; then
      if [[ "${cwd_resolved}" == "${repo_resolved}" ]] \
        || [[ "${cwd_resolved}" == "${repo_resolved}/"* ]]; then
        in_source_repo=1
      fi
    fi
  fi
fi

# Compose the additionalContext payload. The notice is intentionally
# concise — one bold lead, one fix line, one why line. Model behavior
# we want: when /ulw runs, the model surfaces the drift in its opener
# rather than silently relying on stale gates. Downgraded copy when
# in_source_repo=1 trades the urgent-fix framing for a "this is
# expected during dev" framing the model relays calmly.
case "${drift}" in
  tag:*)
    drift_version="${drift#tag:}"
    if [[ "${in_source_repo}" -eq 1 ]]; then
      drift_msg="**Bundle drift (working in source repo).** The source repo VERSION (\`${drift_version}\`) is ahead of the installed bundle — drift is expected during dev. Run \`bash install.sh\` once the changes are ready to use the new behavior."
    else
      drift_msg="**Bundle drift detected.** The source repo at \`${drift_version}\` is ahead of your installed bundle. Run \`bash install.sh\` from the source tree before relying on new gate behavior — your hooks are still running the old version."
    fi
    ;;
  commits:*)
    drift_rest="${drift#commits:}"
    drift_version="${drift_rest%%:*}"
    drift_commits="${drift_rest##*:}"
    if [[ "${in_source_repo}" -eq 1 ]]; then
      drift_msg="**Bundle drift (working in source repo).** The source repo HEAD is ${drift_commits} commit(s) ahead of the installed bundle (\`${drift_version}\`) — drift is expected during dev. Run \`bash install.sh\` once the changes are ready."
    else
      drift_msg="**Bundle drift detected.** Your installed bundle (\`${drift_version}\`) is ${drift_commits} commit(s) behind the source repo HEAD. Run \`bash install.sh\` from the source tree to pick up the new commits — your hooks are running the older snapshot."
    fi
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
  "commits=${drift_commits:-0}" \
  "in_source_repo=${in_source_repo:-0}"

log_hook "session-start-drift-check" "drift detected: ${drift} in_source_repo=${in_source_repo:-0}"
