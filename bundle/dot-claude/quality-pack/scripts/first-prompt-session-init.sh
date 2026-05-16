#!/usr/bin/env bash
#
# v1.41 W3: first-prompt session-init dispatcher.
#
# When `lazy_session_start=on`, the SessionStart hooks `whats-new`,
# `drift-check`, and `welcome` defer their work — they write their
# script basename into `${SESSION_DIR}/.deferred_session_start_hooks`
# and exit clean instead of doing the conf parse / version compare /
# dedupe-stamp write. This dispatcher runs on the FIRST UserPromptSubmit
# of the session, drains the deferred list by re-invoking each hook
# with `OMC_DEFERRED_DISPATCH=1` (the bypass env), captures their
# `additionalContext` payloads, and emits the combined text as a
# UserPromptSubmit additionalContext so the user still sees the
# welcome / version / drift banner before the model's first response.
#
# Throwaway sessions (the user closes claude before typing anything)
# never call this hook — the deferred work is skipped entirely AND
# the per-version / per-install dedupe stamps remain untouched, so
# the NEXT real session sees the banner the user actually deserved
# to see.
#
# Idempotency: gated on per-session `first_prompt_seen` state key.
# On the first prompt the dispatcher drains the list and stamps the
# key; subsequent prompts no-op.
#
# Failure mode: never blocks. Missing common.sh / jq / SESSION_DIR /
# the deferred list itself → exit 0 silently.
#
# Coordination: when this script's path or name changes, update
#   - `verify.sh` (required_paths)
#   - `uninstall.sh` (parallel SessionStart-hook list)
#   - `config/settings.patch.json` (hook wiring)
#   - `tests/test-lazy-session-start.sh` (regression net)

set -euo pipefail

# shellcheck source=../../skills/autowork/scripts/common.sh
. "${HOME}/.claude/skills/autowork/scripts/common.sh"

HOOK_JSON="$(_omc_read_hook_stdin)"
SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

ensure_session_dir 2>/dev/null || exit 0

DEFERRED_LIST="${STATE_ROOT}/${SESSION_ID}/.deferred_session_start_hooks"

# Drain whenever the marker file exists, regardless of the CURRENT value
# of OMC_LAZY_SESSION_START. The flag governs whether NEW markers get
# written at SessionStart time (gated on the SessionStart side); the
# dispatcher's contract is "if there is pending deferred work, run it".
# Otherwise a mid-session flag flip — user turns lazy_session_start off
# after a session has already deferred some hooks — would silently drop
# the welcome / drift / whats-new banner the user expected to see.
[[ -f "${DEFERRED_LIST}" ]] || exit 0

# Per-session idempotency. The dispatcher should run AT MOST ONCE per
# session (on the first UserPromptSubmit). If we've drained before
# but the list still exists (someone wrote to it after we drained),
# treat it as orphaned and remove.
existing_drained="$(read_state "first_prompt_dispatch_drained" 2>/dev/null || true)"
if [[ "${existing_drained}" == "1" ]]; then
  rm -f "${DEFERRED_LIST}" 2>/dev/null || true
  exit 0
fi

# Read the deferred list, deduped (a hook could be listed twice if
# multiple SessionStart matchers fired before the user's first prompt).
HOOKS_DIR="${HOME}/.claude/quality-pack/scripts"
combined_context=""

# Use awk to dedupe while preserving order — bash 3.2 lacks
# associative arrays in a portable way that survives `set -u`.
deduped="$(awk '!seen[$0]++' "${DEFERRED_LIST}" 2>/dev/null || true)"

# Defensive: if the marker had non-blank content but dedupe returned
# nothing, awk failed (exotic libc, missing binary, broken locale).
# Log so the catch is auditable; downstream loop will then no-op and
# the marker still gets cleaned at the bottom of the script.
if [[ -z "${deduped}" ]]; then
  raw_size=0
  [[ -s "${DEFERRED_LIST}" ]] && raw_size="$(wc -c < "${DEFERRED_LIST}" 2>/dev/null | tr -d '[:space:]')"
  if [[ "${raw_size:-0}" != "0" ]]; then
    log_anomaly "first-prompt-session-init" "marker non-empty (${raw_size} bytes) but dedupe produced no rows; deferred hooks dropped"
  fi
fi

while IFS= read -r hook_name; do
  [[ -z "${hook_name}" ]] && continue

  # Defensive: only allow known basenames. Prevents an attacker who
  # somehow writes into the deferred list from running arbitrary
  # scripts via this dispatcher. The allowlist matches the hooks
  # that are actually wired to defer (whats-new, drift-check, welcome).
  case "${hook_name}" in
    session-start-whats-new.sh|session-start-drift-check.sh|session-start-welcome.sh) ;;
    *)
      log_anomaly "first-prompt-session-init" "unknown deferred hook ${hook_name}"
      continue
      ;;
  esac

  hook_path="${HOOKS_DIR}/${hook_name}"
  if [[ ! -x "${hook_path}" ]] && [[ ! -f "${hook_path}" ]]; then
    log_anomaly "first-prompt-session-init" "missing hook script ${hook_path}"
    continue
  fi

  # Re-invoke the hook with the bypass env. We pass the SAME hook JSON
  # we received — the deferred hooks parse only session_id from it
  # (the source/transcript/cwd fields don't affect their behavior),
  # so the UserPromptSubmit shape is acceptable. Soft-fail: if the
  # hook crashes, log and continue draining the rest.
  hook_output="$(OMC_DEFERRED_DISPATCH=1 bash "${hook_path}" <<<"${HOOK_JSON}" 2>/dev/null || true)"
  if [[ -z "${hook_output}" ]]; then
    continue
  fi

  # Each hook emits a SessionStart-shaped payload on stdout. Extract
  # the additionalContext text and append. jq returns empty (not "null")
  # when the path is absent so a hook that exited without emitting
  # silently contributes nothing.
  ctx="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${hook_output}" 2>/dev/null || true)"
  if [[ -n "${ctx}" ]]; then
    if [[ -n "${combined_context}" ]]; then
      combined_context="${combined_context}"$'\n\n'"${ctx}"
    else
      combined_context="${ctx}"
    fi
  fi
done <<<"${deduped}"

# Cleanup BEFORE the emission so even if the printf fails we don't
# re-run the dispatcher on the next prompt. Writing the state key
# also fires the idempotency guard.
rm -f "${DEFERRED_LIST}" 2>/dev/null || true
write_state "first_prompt_dispatch_drained" "1" 2>/dev/null || true

if [[ -z "${combined_context}" ]]; then
  exit 0
fi

# Emit as UserPromptSubmit additionalContext. The model sees the
# combined welcome / drift / whats-new banner as part of the first
# prompt context — same place it would have shown up at SessionStart
# under non-lazy mode.
payload="$(jq -nc --arg ctx "${combined_context}" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}' 2>/dev/null || true)"

if [[ -n "${payload}" ]]; then
  printf '%s\n' "${payload}"
fi
