#!/usr/bin/env bash
#
# stop-transcript-archive.sh — Stop hook (v1.44-pre Port 5, opt-in).
#
# When `transcript_archive=on`, reads Claude Code's session JSONL
# transcript from the hook input's `transcript_path` field and writes a
# normalized JSON array to:
#
#   ~/.claude/quality-pack/state/<project_key>/<session_id>/transcript.json
#
# Closes the debugging gap where replaying complex turns after stop-guard
# fires requires manual JSONL plumbing of Claude Code's session directory.
# After this lands, the archive is a stable per-session artifact callers
# can grep/pipe/inspect without hunting through `~/.claude/projects/`.
#
# Constraints honored:
#   - **Idempotent.** Existing destination → no-op (don't re-archive,
#     don't bump mtime). The first Stop in a session captures; subsequent
#     Stops within the same session are silent.
#   - **Default OFF.** Disk cost is non-trivial (50-500 KB/session). Users
#     opt in via `transcript_archive=on` in oh-my-claude.conf or env
#     `OMC_TRANSCRIPT_ARCHIVE=on`.
#   - **Defensive fatal-stop guard (metis F-5).** The hook is wired to
#     Stop, not StopFailure. Per `docs/architecture.md` the `matcher`
#     field is currently emitted only on StopFailure, not on Stop — so
#     the case-statement skip below is dead code in production today.
#     The guard ships anyway as defensive future-proofing: if a future
#     Claude Code release ever forwards a fatal `matcher` on the Stop
#     event (e.g., a unified stop-class refactor), the JSONL would be
#     mid-flush at exactly the moment `stop-failure-handler.sh` owns the
#     window, and a racing archive read would see a partial last line.
#     The skip preserves the producer/consumer split that exists on the
#     StopFailure path today. **If a maintainer ever observes the case
#     statement matching in production**, that signals Claude Code's
#     hook surface changed and the rest of `stop-failure-handler.sh`'s
#     fatal-window logic should be re-audited.
#   - **Privacy parity with stop_failure_capture (metis F-5).** The
#     transcript carries the same secrecy surface as `resume_request.json`
#     (prompt + assistant turns + secrets the user may have pasted). If
#     `stop_failure_capture=off` opted out of the resume_request artifact
#     on privacy grounds, this archive must opt out too — it would carry
#     equivalent or richer content.
#   - **Pure bash, zero deps.** jq is preferred for the JSONL → JSON
#     normalization; falls back to `cp` (preserving .jsonl) when jq is
#     unavailable.
#   - **Fail-open standalone.** Direct hook errors exit 0. An accepted-Stop
#     child propagates publication failure so its finalizer lease is retried.

set -euo pipefail

# Archiving a transcript is a privacy-sensitive terminal side effect. The
# process-wide activation latch is intentionally sticky and cannot authorize a
# particular Stop; only the deterministic dispatcher invokes this script with
# an explicit accepted disposition after certification.
[[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] || exit 0
finalizer_claim_id="${OMC_CLOSEOUT_FINALIZATION_CLAIM_ID:-}"
[[ "${finalizer_claim_id}" =~ ^finalizer-[a-f0-9]{48}$ ]] || exit 1

# v1.27.0 lazy-load gates: archive hook does not need classifier/timing.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

_transcript_archive_required_failure() {
  [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && exit 1
  exit 0
}

_transcript_archive_record_skip_locked() {
  local matcher="$1" claim_id="$2"
  _closeout_finalization_claim_is_current_unlocked "${claim_id}" || return 1
  record_gate_event "transcript-archive" "skip-fatal-stop" \
    "matcher=${matcher}" 2>/dev/null || true
}

# Publish a fully-staged archive while holding the session mutex. Checking the
# captured generation before either the first-writer test or mkdir/mv is the
# linearization point: a stale G1 callback cannot create the first archive and
# thereby make the current G2 callback incorrectly treat the session as done.
_transcript_archive_publish_locked() {
  local stage="$1" dest="$2" alternate_dest="$3" dest_dir="$4" format="$5"
  local claim_id="$6"
  _closeout_finalization_claim_is_current_unlocked "${claim_id}" || return 1
  [[ "${OMC_TEST_TRANSCRIPT_ARCHIVE_PUBLISH_FAIL:-0}" != "1" ]] \
    || return 1
  [[ -f "${stage}" && ! -L "${stage}" ]] || return 1
  [[ ! -e "${dest}" && ! -L "${dest}" \
      && ! -e "${alternate_dest}" && ! -L "${alternate_dest}" ]] \
    || return 1
  [[ ! -e "${dest_dir}" || ( -d "${dest_dir}" && ! -L "${dest_dir}" ) ]] \
    || return 1

  _closeout_finalization_claim_is_current_unlocked "${claim_id}" || return 1
  mkdir -p "${dest_dir}" || return 1
  chmod 700 "${dest_dir}" 2>/dev/null || return 1
  _closeout_finalization_claim_is_current_unlocked "${claim_id}" || return 1
  mv -f -- "${stage}" "${dest}" || return 1
  _closeout_finalization_claim_is_current_unlocked "${claim_id}" || return 1
  record_gate_event "transcript-archive" "captured" \
    "dest=${dest}" "format=${format}" 2>/dev/null || true
}

HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0
validate_session_id "${SESSION_ID}" 2>/dev/null || exit 0
omc_enforcement_generation_matches_capture || exit 0

# Honor opt-in conf flag.
if [[ "${OMC_TRANSCRIPT_ARCHIVE:-off}" != "on" ]]; then
  exit 0
fi

# Privacy parity with stop_failure_capture — the transcript carries the
# same secrecy surface as resume_request.json. If a user opted out of
# resume_request artifacts, do not archive the equivalent here.
if ! is_stop_failure_capture_enabled; then
  exit 0
fi

# Fatal-stop guard: skip when the matcher names a condition where the
# JSONL is mid-flush. stop-failure-handler.sh owns the fatal-stop window.
matcher="$(json_get '.matcher')"
case "${matcher}" in
  rate_limit|authentication_failed|billing_error|max_output_tokens)
    with_state_lock _transcript_archive_record_skip_locked "${matcher}" \
      "${finalizer_claim_id}" \
      2>/dev/null || _transcript_archive_required_failure
    exit 0
    ;;
esac

transcript_path="$(json_get '.transcript_path')"
if [[ -z "${transcript_path}" || ! -r "${transcript_path}" ]]; then
  # No transcript to archive — quiet exit, not an error.
  exit 0
fi

project_key="$(_omc_project_key 2>/dev/null || true)"
if [[ -z "${project_key}" ]]; then
  # Fall back to a stable cwd hash if the project-key helper isn't
  # available (shouldn't happen post common.sh source, but defensive).
  project_key="$(printf '%s' "${PWD:-unknown}" | shasum -a 1 2>/dev/null | awk '{print $1}' | cut -c1-12)"
  project_key="${project_key:-unknown}"
fi

dest_dir="${HOME}/.claude/quality-pack/state/${project_key}/${SESSION_ID}"
dest="${dest_dir}/transcript.json"
dest_fallback="${dest_dir}/transcript.jsonl"

# Idempotent — if either form already exists, the first Stop already
# captured. Don't re-archive (preserves mtime; avoids churn on session-
# stop loops).
if [[ -e "${dest}" || -L "${dest}" \
    || -e "${dest_fallback}" || -L "${dest_fallback}" ]]; then
  if { [[ -f "${dest}" && ! -L "${dest}" \
          && ! -e "${dest_fallback}" && ! -L "${dest_fallback}" ]]; } \
      || { [[ -f "${dest_fallback}" && ! -L "${dest_fallback}" \
          && ! -e "${dest}" && ! -L "${dest}" ]]; }; then
    exit 0
  fi
  [[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] && exit 1
  exit 0
fi

# Conversion/copy can be large, so stage it before taking the session lock.
# The staging root shares the archive filesystem, making the locked mv an
# atomic publication instead of a second large copy inside the critical
# section.
archive_root="${HOME}/.claude/quality-pack/state"
stage_root="${archive_root}/.transcript-archive-staging"
if [[ -L "${stage_root}" \
    || ( -e "${stage_root}" && ! -d "${stage_root}" ) ]]; then
  _transcript_archive_required_failure
fi
if ! mkdir -p "${stage_root}" 2>/dev/null; then
  _transcript_archive_required_failure
fi
if ! chmod 700 "${stage_root}" 2>/dev/null; then
  _transcript_archive_required_failure
fi
stage="$(mktemp "${stage_root}/.${SESSION_ID}.XXXXXX" 2>/dev/null || true)"
if [[ -z "${stage}" ]]; then
  _transcript_archive_required_failure
fi
_transcript_archive_cleanup() {
  [[ -n "${stage:-}" ]] && rm -f -- "${stage}" 2>/dev/null || true
}
trap _transcript_archive_cleanup EXIT
if [[ "${OMC_TEST_TRANSCRIPT_ARCHIVE_CHMOD_FAIL:-0}" == "1" ]] \
    || ! chmod 600 "${stage}" 2>/dev/null; then
  _transcript_archive_required_failure
fi

if command -v jq >/dev/null 2>&1; then
  # jq -s slurps each non-empty JSONL line into a single JSON array.
  if jq -s '.' "${transcript_path}" >"${stage}" 2>/dev/null; then
    publish_dest="${dest}"
    alternate_dest="${dest_fallback}"
    archive_format="json"
  else
    # jq failed — fall back to cp so the user still has something to grep.
    if ! : >"${stage}" \
        || ! cp "${transcript_path}" "${stage}" 2>/dev/null; then
      _transcript_archive_required_failure
    fi
    publish_dest="${dest_fallback}"
    alternate_dest="${dest}"
    archive_format="jsonl-fallback"
  fi
else
  # jq missing — copy the raw JSONL.
  if ! cp "${transcript_path}" "${stage}" 2>/dev/null; then
    _transcript_archive_required_failure
  fi
  publish_dest="${dest_fallback}"
  alternate_dest="${dest}"
  archive_format="jsonl-no-jq"
fi

archive_publish_rc=0
with_state_lock _transcript_archive_publish_locked \
  "${stage}" "${publish_dest}" "${alternate_dest}" "${dest_dir}" \
  "${archive_format}" "${finalizer_claim_id}" \
  2>/dev/null || archive_publish_rc=$?

if [[ "${archive_publish_rc}" -ne 0 \
    && "${OMC_STOP_ACCEPTED:-0}" == "1" ]]; then
  exit "${archive_publish_rc}"
fi

exit 0
