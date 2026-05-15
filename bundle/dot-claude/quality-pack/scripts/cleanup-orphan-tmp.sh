#!/usr/bin/env bash
#
# Orphan-tmp cleanup.
#
# Sweeps stale `omc-*` directories left in `/tmp/` by the harness's test
# helpers and ad-hoc fixtures. The smoking-gun observation: 56
# `omc-sterile-tmp-*` directories had accumulated on the development
# host (oldest 4 days, created by `tests/lib/sterile-env.sh` via
# `mktemp -d /tmp/omc-sterile-tmp-XXXXXX`). The helper exposes a
# `cleanup_sterile_env` function but ~10 tests never registered an
# EXIT trap that calls it, so every aborted run leaks a temp dir. This
# sweep is the safety net; the source-side fix lives in
# `tests/lib/sterile-env.sh` (auto-register trap on `setup_sterile_env`).
#
# Strategy:
#   1. List `/tmp/omc-*` paths (directories AND stray files — the
#      sterile-env helper creates dirs but other test scratch artifacts
#      that happen to share the prefix should also go).
#   2. Skip if age (now − mtime) below threshold (default 24h;
#      configurable via `orphan_tmp_max_age_hours` conf flag or
#      `OMC_ORPHAN_TMP_MAX_AGE_HOURS` env). Conservative because the
#      user may have an active test run that's < 24h old.
#   3. Remove with `rm -rf` for dirs, `rm -f` for files. Log each.
#
# Safety rails:
#   - Pattern is hard-coded to `/tmp/omc-*` (glob, not regex). Nothing
#     outside that prefix can be touched.
#   - Each path is re-checked to live under `/tmp/` before removal —
#     defends against an attacker who symlinks the glob match elsewhere
#     (TOCTOU defense; we resolve and verify the parent dir).
#   - Exits 0 on any error (fail-safe in SessionStart context).
#   - Hard cap of 100 removals per invocation as a runaway guard.
#   - `cleanup_orphan_tmp=off` → clean no-op.
#
# Invocation:
#   - SessionStart hook (`config/settings.patch.json` after
#     `cleanup-orphan-resume.sh`).
#   - Standalone: `bash cleanup-orphan-tmp.sh` for one-off cleanup.

set -euo pipefail

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

# Allow standalone invocation; tolerate missing hook stdin.
if [[ -t 0 ]]; then
  HOOK_JSON=""
else
  HOOK_JSON="$(_omc_read_hook_stdin 2>/dev/null || printf '')"
fi
if [[ -n "${HOOK_JSON}" ]]; then
  SESSION_ID="$(printf '%s' "${HOOK_JSON}" | jq -r '.session_id // empty' 2>/dev/null || printf '')"
fi
SESSION_ID="${SESSION_ID:-}"

# Opt-out.
if ! is_cleanup_orphan_tmp_enabled; then
  exit 0
fi

_orphan_tmp_max_age_hours="$(orphan_tmp_max_age_hours)"
_orphan_tmp_max_age_seconds=$(( _orphan_tmp_max_age_hours * 3600 ))
_max_removals=100
_removed=0
_skipped_recent=0
_skipped_outside=0

_now_epoch="$(date +%s)"

# Resolve the configured tmp root. Hardcoded `/tmp/`. The harness's
# sterile-env helper writes directly there; no env override is honored
# at the SWEEP layer (the helper's own TMPDIR resolution is its own
# concern). Hardcoding the sweep root caps blast radius.
_tmp_root="/tmp"
[[ -d "${_tmp_root}" ]] || exit 0

# Glob `/tmp/omc-*`. The `for` loop with a literal glob does not match
# anything when the glob is empty (the literal pattern stays as-is); we
# guard against that explicitly. The `${arr[@]+"${arr[@]}"}` form
# handles bash 3.2 (macOS default) where `"${arr[@]}"` on an empty
# array under `set -u` raises "unbound variable".
shopt -s nullglob
_candidates=( "${_tmp_root}/omc-"* )
shopt -u nullglob

for _path in ${_candidates[@]+"${_candidates[@]}"}; do
  [[ -e "${_path}" ]] || continue

  # TOCTOU defense: re-resolve parent and confirm it's still /tmp.
  # If a symlink got swapped between glob and removal, we bail.
  _parent="$(dirname -- "${_path}")"
  if [[ "${_parent}" != "${_tmp_root}" ]]; then
    _skipped_outside=$((_skipped_outside + 1))
    continue
  fi

  # mtime → age. macOS BSD stat: -f '%m'; GNU stat: -c '%Y'. Both
  # supported (autowork runs on both).
  if _mtime="$(stat -f '%m' "${_path}" 2>/dev/null)"; then :;
  elif _mtime="$(stat -c '%Y' "${_path}" 2>/dev/null)"; then :;
  else
    # Stat failed — skip rather than risk a removal under unknown
    # filesystem state.
    continue
  fi

  if [[ ! "${_mtime}" =~ ^[0-9]+$ ]]; then
    continue
  fi

  _age=$(( _now_epoch - _mtime ))
  if [[ "${_age}" -lt "${_orphan_tmp_max_age_seconds}" ]]; then
    _skipped_recent=$((_skipped_recent + 1))
    continue
  fi

  if [[ "${_removed}" -ge "${_max_removals}" ]]; then
    record_gate_event "cleanup-orphan-tmp" "removal-cap-reached" \
      "removed=${_removed}" "cap=${_max_removals}" 2>/dev/null || true
    break
  fi

  # Remove. `rm -rf` is the tool — defended by the glob-prefix +
  # TOCTOU re-check above. Failures are silent (race: another
  # process may have removed the path between the stat and the rm).
  if [[ -d "${_path}" && ! -L "${_path}" ]]; then
    rm -rf -- "${_path}" 2>/dev/null && _removed=$((_removed + 1))
  elif [[ -f "${_path}" || -L "${_path}" ]]; then
    rm -f -- "${_path}" 2>/dev/null && _removed=$((_removed + 1))
  fi

  if [[ "${_removed}" -gt 0 ]]; then
    record_gate_event "cleanup-orphan-tmp" "removed" \
      "path=${_path}" "age_seconds=${_age}" 2>/dev/null || true
  fi
done

if [[ "${_removed}" -gt 0 || "${_skipped_recent}" -gt 0 ]]; then
  record_gate_event "cleanup-orphan-tmp" "summary" \
    "removed=${_removed}" \
    "skipped_recent=${_skipped_recent}" \
    "skipped_outside_root=${_skipped_outside}" \
    "threshold_hours=${_orphan_tmp_max_age_hours}" 2>/dev/null || true
fi

if [[ "${_removed}" -gt 0 ]]; then
  _msg="oh-my-claude cleanup: removed ${_removed} orphan /tmp/omc-* path(s) older than ${_orphan_tmp_max_age_hours}h."
  if [[ -n "${HOOK_JSON}" ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
      "$(printf '%s' "${_msg}" | jq -Rs .)" 2>/dev/null || true
  else
    printf '%s\n' "${_msg}" >&2
  fi
fi

exit 0
