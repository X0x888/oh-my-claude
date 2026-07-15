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
#   - **Never blocks Stop.** Any error path exits 0; the archive is
#     advisory, not load-bearing.

set -euo pipefail

# Archiving a transcript is a privacy-sensitive terminal side effect. The
# process-wide activation latch is intentionally sticky and cannot authorize a
# particular Stop; only the deterministic dispatcher invokes this script with
# an explicit accepted disposition after certification.
[[ "${OMC_STOP_ACCEPTED:-0}" == "1" ]] || exit 0

# v1.27.0 lazy-load gates: archive hook does not need classifier/timing.
export OMC_LAZY_CLASSIFIER=1
export OMC_LAZY_TIMING=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

SESSION_ID="$(json_get '.session_id')"
[[ -z "${SESSION_ID}" ]] && exit 0

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
    record_gate_event "transcript-archive" "skip-fatal-stop" \
      "matcher=${matcher}" 2>/dev/null || true
    exit 0
    ;;
esac

ensure_session_dir

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
if [[ -e "${dest}" || -e "${dest_fallback}" ]]; then
  exit 0
fi

mkdir -p "${dest_dir}"
chmod 700 "${dest_dir}" 2>/dev/null || true

if command -v jq >/dev/null 2>&1; then
  # jq -s slurps each non-empty JSONL line into a single JSON array.
  # 2>/dev/null suppresses jq's parse errors on the last (possibly
  # incomplete) line — better to ship a partial archive than nothing
  # when a session ends mid-flush.
  if jq -s '.' "${transcript_path}" >"${dest}.tmp" 2>/dev/null; then
    mv "${dest}.tmp" "${dest}"
    record_gate_event "transcript-archive" "captured" \
      "dest=${dest}" "format=json" 2>/dev/null || true
  else
    rm -f "${dest}.tmp"
    # jq failed — fall back to cp so the user still has something to grep.
    if cp "${transcript_path}" "${dest_fallback}" 2>/dev/null; then
      record_gate_event "transcript-archive" "captured" \
        "dest=${dest_fallback}" "format=jsonl-fallback" 2>/dev/null || true
    fi
  fi
else
  # jq missing — copy the raw JSONL.
  if cp "${transcript_path}" "${dest_fallback}" 2>/dev/null; then
    record_gate_event "transcript-archive" "captured" \
      "dest=${dest_fallback}" "format=jsonl-no-jq" 2>/dev/null || true
  fi
fi

exit 0
