#!/usr/bin/env bash
#
# oh-my-claude verifier
#
# Validates that the oh-my-claude harness is correctly installed:
#   - Required files and directories exist
#   - settings.json is valid JSON
#   - All hook scripts pass bash syntax checking
#   - Required hooks are registered in settings.json
#   - Ghostty theme is present (if applicable)
#
# Usage:
#   bash verify.sh

set -euo pipefail

# Disable BASH_ENV-enabled aliases before function bodies are parsed. POSIX
# special-builtin lookup makes this boundary independent of same-named shell
# functions; readonly hostile shims fail verification closed.
_OMC_SHA_ALIAS_POSIX_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VALUE=""
if [[ -o posix ]]; then
  _OMC_SHA_ALIAS_POSIX_WAS_SET=1
fi
if [[ "${POSIXLY_CORRECT+x}" == "x" ]]; then
  _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=1
  _OMC_SHA_ALIAS_POSIX_VALUE="${POSIXLY_CORRECT}"
fi
POSIXLY_CORRECT=1 || \exit 1
\unset -f shopt unset set || \exit 1
\shopt -u expand_aliases || \exit 1
if [[ "${_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET}" == "1" ]]; then
  POSIXLY_CORRECT="${_OMC_SHA_ALIAS_POSIX_VALUE}" || \exit 1
else
  \unset POSIXLY_CORRECT || \exit 1
fi
if [[ "${_OMC_SHA_ALIAS_POSIX_WAS_SET}" == "1" ]]; then
  \set -o posix || \exit 1
else
  \set +o posix || \exit 1
fi
\unset _OMC_SHA_ALIAS_POSIX_WAS_SET _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET \
  _OMC_SHA_ALIAS_POSIX_VALUE || \exit 1

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
CLAUDE_HOME="${TARGET_HOME}/.claude"

# v1.32.16 (4-attacker security review): --strict escalates Step 8
# (foreign hook detection) and Step 9 (SHA-256 drift) from `warn` to
# `fail`. Default `warn` preserves the existing UX for users with
# legitimate custom hook entries (CI integrations, personal automation
# layered on top of the harness). --strict is the security-conscious
# default for users who want their `verify.sh` exit code to fail on
# any foreign content; this is the right setting for incident-response
# audits and for shared/regulated machines.
STRICT_MODE="false"
HEALTH_MODE="false"
for arg in "$@"; do
  case "${arg}" in
    --strict)
      STRICT_MODE="true"
      ;;
    --health)
      # v1.42.x-newer (sre-lens F-005): one-line healthcheck mode for
      # `watch grep OK` and external monitor wrap. Reads heartbeat age
      # (resume-watchdog last tick), active-session count, anomaly tail.
      # Thresholds: heartbeat ≤600s OK, 600-1800s WARN, >1800s FAIL.
      # Single-line output; exit 0 if healthy, 1 if WARN, 2 if FAIL.
      HEALTH_MODE="true"
      ;;
  esac
done

# jq is a runtime dependency of the installed harness, so verification cannot
# report healthy when the executable is absent. Admit this dependency before
# the --health fast path; otherwise a host with no jq can return `OK` merely
# because no anomaly file happened to require parsing.
JQ_RUNTIME_AVAILABLE="true"
if ! command -v jq >/dev/null 2>&1; then
  JQ_RUNTIME_AVAILABLE="false"
  if [[ "${HEALTH_MODE}" == "true" ]]; then
    printf 'FAIL: jq runtime dependency is missing\n'
    exit 2
  fi
fi

# --- Health mode: one-line SLO output ---
# Converts "is the harness healthy?" from a 200-line full-verify into a
# greppable line. Designed for `watch -n 60 'bash verify.sh --health'`
# or for external monitors that just need a heartbeat. Intentionally
# does NOT check installation integrity (that's full verify's job).
if [[ "${HEALTH_MODE}" == "true" ]]; then
  _state_root="${TARGET_HOME}/.claude/quality-pack/state"
  _hb_dir="${_state_root}/_watchdog"
  _hb_file="${_hb_dir}/last_tick_completed_ts"
  _health_epoch_is_valid() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,14}$ ]]
  }

  # Read an epoch without ever passing unvalidated file bytes through a Bash
  # variable. Bash command substitution drops NUL bytes, which can normalize
  # `<valid epoch>\0` into apparent authority. The hex envelope proves the
  # complete bounded file is canonical ASCII decimal with at most one newline
  # before `tr` imports it for arithmetic.
  _health_read_epoch_file() {
    local path="${1:-}" output_var="${2:-}" size="" hex="" value=""
    [[ -n "${path}" && -n "${output_var}" \
        && -f "${path}" && ! -L "${path}" ]] || return 1
    size="$(wc -c <"${path}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${size}" =~ ^([1-9]|1[0-6])$ ]] || return 1
    hex="$(LC_ALL=C od -An -v -tx1 "${path}" 2>/dev/null \
      | tr -d '[:space:]')" || return 1
    [[ "${hex}" =~ ^3[1-9](3[0-9]){0,14}(0a)?$ ]] || return 1
    value="$(tr -d '\n' <"${path}")" || return 1
    _health_epoch_is_valid "${value}" || return 1
    printf -v "${output_var}" '%s' "${value}"
  }

  _clock_capture="$(mktemp "${TMPDIR:-/tmp}/omc-health-clock.XXXXXX" \
    2>/dev/null || true)"
  now_ts=""
  if [[ -z "${_clock_capture}" ]] \
      || ! date +%s >"${_clock_capture}" 2>/dev/null \
      || ! _health_read_epoch_file "${_clock_capture}" now_ts; then
    [[ -n "${_clock_capture}" ]] \
      && rm -f -- "${_clock_capture}" 2>/dev/null || true
    printf 'FAIL: watchdog=clock-unreadable sessions=0 anomalies_1h=0\n'
    exit 2
  fi
  rm -f -- "${_clock_capture}" 2>/dev/null || true

  # Heartbeat age. Missing heartbeat is acceptable when the watchdog
  # opt-in is off (most users) — reported as `no-watchdog`, not FAIL.
  hb_status="no-watchdog"
  hb_age_secs=""
  # Any node at the heartbeat path is an attempted heartbeat. Let the bounded
  # reader reject symlinks and non-regular nodes so an unsafe/dangling artifact
  # cannot be misreported as the benign, genuinely absent `no-watchdog` case.
  if [[ -e "${_hb_file}" || -L "${_hb_file}" ]]; then
    _hb_ts=""
    if _health_read_epoch_file "${_hb_file}" _hb_ts \
        && (( _hb_ts <= now_ts )); then
      hb_age_secs=$(( now_ts - _hb_ts ))
      # Watchdog ticks every 60s by default; ≤600s OK, 600-1800s WARN,
      # >1800s FAIL. Tolerant window accommodates the 5-min cooldown
      # buffer + occasional load spikes on a busy host.
      if (( hb_age_secs <= 600 )); then
        hb_status="ok-${hb_age_secs}s"
      elif (( hb_age_secs <= 1800 )); then
        hb_status="warn-stale-${hb_age_secs}s"
      else
        hb_status="fail-stale-${hb_age_secs}s"
      fi
    else
      hb_status="warn-unreadable"
    fi
  fi

  # Active-session count (sessions with state files modified in last 24h).
  active_sessions=0
  session_scan_failed=0
  if [[ -d "${_state_root}" ]]; then
    # 1440 min = 24h. Counts UUID-shaped session dirs (hex-prefixed)
    # touched in the last 24h.
    if ! active_sessions="$(find "${_state_root}" -mindepth 1 -maxdepth 1 \
        -type d -name '[a-f0-9]*' -mmin -1440 2>/dev/null \
        | wc -l | tr -d '[:space:]')" \
        || [[ ! "${active_sessions}" =~ ^[0-9]{1,6}$ ]]; then
      active_sessions=0
      session_scan_failed=1
    fi
  fi

  # Anomaly count in last hour — high counts signal something is
  # repeatedly going wrong (lock contention, corrupt state, etc.).
  anomaly_count=0
  anomaly_scan_failed=0
  _anomaly_file="${_state_root}/hooks.log"
  if [[ -e "${_anomaly_file}" || -L "${_anomaly_file}" ]]; then
    if [[ ! -f "${_anomaly_file}" || -L "${_anomaly_file}" ]]; then
      anomaly_scan_failed=1
    else
      if (( now_ts > 3600 )); then
        _cutoff=$(( now_ts - 3600 ))
      else
        _cutoff=0
      fi
      _cutoff_text="$(date -r "${_cutoff}" '+%Y-%m-%d %H:%M:%S' \
        2>/dev/null || date -d "@${_cutoff}" '+%Y-%m-%d %H:%M:%S' \
        2>/dev/null || true)"
      if [[ ! "${_cutoff_text}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        anomaly_scan_failed=1
      # `log_anomaly` writes bounded `[anomaly]` rows to hooks.log and rotates
      # it at 2,000 lines. Keep an independent byte ceiling here so health
      # remains cheap even if an out-of-band writer corrupts that invariant.
      elif ! anomaly_count="$(tail -c 8388608 "${_anomaly_file}" 2>/dev/null \
          | LC_ALL=C awk -F'  ' -v cut="${_cutoff_text}" '
              $2 == "[anomaly]" && $1 >= cut { count += 1 }
              END { print count + 0 }
            ' 2>/dev/null)" \
          || [[ ! "${anomaly_count}" =~ ^[0-9]{1,6}$ ]]; then
        anomaly_count=0
        anomaly_scan_failed=1
      fi
    fi
  fi

  # Overall status: FAIL if heartbeat is stale-fail OR anomaly count > 10.
  # WARN if heartbeat stale-warn OR anomaly count 4-10.
  # OK otherwise.
  overall="OK"
  rc=0
  case "${hb_status}" in
    fail-*) overall="FAIL"; rc=2 ;;
    warn-*) overall="WARN"; rc=1 ;;
  esac
  if (( session_scan_failed == 1 || anomaly_scan_failed == 1 )) \
      && [[ "${overall}" == "OK" ]]; then
    overall="WARN"; rc=1
  fi
  if (( anomaly_count > 10 )) && [[ "${overall}" != "FAIL" ]]; then
    overall="FAIL"; rc=2
  elif (( anomaly_count >= 4 )) && [[ "${overall}" == "OK" ]]; then
    overall="WARN"; rc=1
  fi

  printf '%s: watchdog=%s sessions=%s anomalies_1h=%s\n' \
    "${overall}" "${hb_status}" "${active_sessions}" "${anomaly_count}"
  exit "${rc}"
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

errors=0
warnings=0
# v1.36.0 (item #7): split warning total into informational vs actionable.
# Optional tool/config skips (for example Ghostty config not present) and
# misses (Ghostty config not present) are info-only and don't gate ship-
# readiness. Foreign hooks, agent-list mismatches, drift detection
# fires, and statusline hijacks are actionable — saved to
# ~/.claude/last-verify-warnings.txt for follow-up.
info_warnings=0
actionable_warnings=0
ACTIONABLE_LOG="${TARGET_HOME:-$HOME}/.claude/last-verify-warnings.txt"
# Truncate the actionable log up-front so each verify.sh run starts
# fresh. If the directory does not exist (running against a wholly
# empty ~/.claude/ on a tmpdir target), the rm is a no-op.
rm -f "${ACTIONABLE_LOG}" 2>/dev/null || true

pass() {
  printf '  [ok]   %s\n' "$1"
}

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  errors=$(( errors + 1 ))
}

warn() {
  printf '  [warn] %s\n' "$1"
  warnings=$(( warnings + 1 ))
  actionable_warnings=$(( actionable_warnings + 1 ))
  # Append to the actionable log lazily — the file is created on first
  # actionable warn so a clean install with zero actionable warnings
  # leaves no stale file. Errors here are non-fatal (the warn itself
  # already printed).
  printf '%s\n' "$1" >> "${ACTIONABLE_LOG}" 2>/dev/null || true
}

# v1.36.0 (item #7): info_warn for tool-absence skips and optional
# checks that produce a warning but don't gate ship-readiness. Same
# `[info]` prefix used by the post-install footer in install.sh so
# the visual hierarchy is consistent across surfaces.
info_warn() {
  printf '  [info] %s\n' "$1"
  warnings=$(( warnings + 1 ))
  info_warnings=$(( info_warnings + 1 ))
}

function sanitize_sha256_authority_shell () {
  POSIXLY_CORRECT=1 || \return 1
  \unset -f builtin command printf read local type declare unset cd pwd export \
    return shasum sha256sum readlink || \return 1
}

function resolve_trusted_sha256_executable () (
  \sanitize_sha256_authority_shell || \return 1
  \local search_path="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  \local old_ifs="${IFS}" directory="" canonical="" name="" candidate=""
  \local reader="" resolved=""
  [[ "${search_path}" != *$'\n'* && "${search_path}" != *$'\r'* ]] \
    || \return 1
  for name in shasum sha256sum; do
    IFS=':'
    for directory in ${search_path}; do
      IFS="${old_ifs}"
      [[ -n "${directory}" && "${directory}" == /* \
          && "${directory}" != *[[:cntrl:]]* ]] || continue
      canonical="$(\builtin cd -- "${directory}" 2>/dev/null \
        && \builtin pwd -P)" || continue
      case "${canonical}" in
        /usr/bin|/bin|/usr/sbin|/sbin|/nix/store/*/bin) ;;
        *) continue ;;
      esac
      candidate="${canonical%/}/${name}"
      [[ -f "${candidate}" && -x "${candidate}" ]] || continue
      if [[ -L "${candidate}" ]]; then
        case "${candidate}" in /nix/store/*/bin/*) ;; *) continue ;; esac
        resolved=""
        for reader in /usr/bin/readlink /bin/readlink \
            "${canonical%/}/readlink"; do
          [[ -x "${reader}" ]] || continue
          resolved="$(\builtin command -- "${reader}" -f -- \
            "${candidate}" 2>/dev/null)" || resolved=""
          case "${resolved}" in /nix/store/*) ;; *) resolved="" ;; esac
          [[ -n "${resolved}" && -f "${resolved}" \
              && -x "${resolved}" && ! -L "${resolved}" ]] && break
          resolved=""
        done
        [[ -n "${resolved}" ]] || continue
        \builtin printf '%s' "${candidate}"
        IFS="${old_ifs}"
        \return 0
      fi
      [[ ! -L "${candidate}" ]] || continue
      \builtin printf '%s' "${candidate}"
      IFS="${old_ifs}"
      \return 0
    done
    IFS="${old_ifs}"
  done
  IFS="${old_ifs}"
  \return 1
)

function run_trusted_sha256_manifest_check () (
  \sanitize_sha256_authority_shell || \return 1
  \local hasher="${1:-}" root="${2:-}" manifest="${3:-}"
  [[ -n "${hasher}" && -d "${root}" && -f "${manifest}" ]] || \return 1
  \builtin cd -- "${root}" || \return 1
  \export LC_ALL=C
  case "${hasher##*/}" in
    shasum)
      \builtin command -- "${hasher}" -a 256 -c "${manifest}"
      ;;
    sha256sum)
      \builtin command -- "${hasher}" -c "${manifest}"
      ;;
    *) \return 1 ;;
  esac
)

managed_path_components_are_safe() {
  local path="${1:-}" allow_leaf_symlink="${2:-0}"
  local relative="" component="${CLAUDE_HOME}" segment=""
  local index=0 count=0
  local -a segments=()
  case "${path}" in
    "${CLAUDE_HOME}"/*) relative="${path#"${CLAUDE_HOME}"/}" ;;
    *) return 1 ;;
  esac
  [[ -n "${relative}" && "${relative}" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a segments <<< "${relative}"
  count="${#segments[@]}"
  for segment in "${segments[@]}"; do
    index=$((index + 1))
    [[ -n "${segment}" && "${segment}" != "." \
        && "${segment}" != ".." ]] || return 1
    component="${component}/${segment}"
    if [[ -L "${component}" ]]; then
      [[ "${allow_leaf_symlink}" -eq 1 && "${index}" -eq "${count}" ]] \
        || return 1
    elif [[ "${index}" -lt "${count}" && -e "${component}" \
        && ! -d "${component}" ]]; then
      return 1
    fi
  done
}

read_conf_value() {
  local key="${1:-}"
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local line="" value="" result="" last_seen="" saw_row=0
  [[ -n "${key}" ]] || return 0
  [[ -f "${conf_path}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    last_seen="${value}"
    saw_row=1
    case "${key}:${value}" in
      resume_watchdog:on|resume_watchdog:off|\
      model_tier:quality|model_tier:balanced|model_tier:economy)
        result="${value}"
        ;;
    esac
  done < "${conf_path}"
  if [[ -n "${result}" ]]; then
    printf '%s' "${result}"
  elif [[ "${saw_row}" -eq 1 && -n "${last_seen}" ]]; then
    # Keep diagnostics useful when the file contains no valid authority at
    # all; callers still map this noncanonical value to the runtime default.
    printf '%s' "${last_seen}"
  fi
}

verify_platform() {
  case "$(uname 2>/dev/null || echo '')" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *) printf 'other' ;;
  esac
}

watchdog_resolved_path() {
  local from_shell=""
  if [[ -n "${SHELL:-}" ]] && [[ -x "${SHELL}" ]]; then
    if command -v timeout >/dev/null 2>&1; then
      from_shell="$(timeout 5 "${SHELL}" -ilc 'printf %s "${PATH}"' 2>/dev/null || true)"
    else
      from_shell="$("${SHELL}" -ilc 'printf %s "${PATH}"' 2>/dev/null || true)"
    fi
  fi
  if [[ -n "${from_shell}" ]]; then
    from_shell="${from_shell//$'\n'/}"
    from_shell="${from_shell//$'\r'/}"
    printf '%s' "${from_shell}"
    return 0
  fi
  if [[ -n "${PATH:-}" ]]; then
    from_shell="${PATH//$'\n'/}"
    from_shell="${from_shell//$'\r'/}"
    printf '%s' "${from_shell}"
    return 0
  fi
  printf '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
}

watchdog_xml_escape() {
  local value="${1:-}" index=0 character=""
  while [[ "${index}" -lt "${#value}" ]]; do
    character="${value:index:1}"
    case "${character}" in
      '&') printf '&amp;' ;;
      '<') printf '&lt;' ;;
      '>') printf '&gt;' ;;
      '"') printf '&quot;' ;;
      "'") printf '&apos;' ;;
      *) printf '%s' "${character}" ;;
    esac
    index=$((index + 1))
  done
}

watchdog_systemd_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '%s' "${value}"
}

render_watchdog_template() {
  local template_path="${1:-}"
  local target_home="${2:-${TARGET_HOME}}"
  local claude_home="${target_home}/.claude"
  local log_dir="${claude_home}/quality-pack/state/.watchdog-logs"
  local user_path="" kind="" home_value="" claude_value=""
  local log_value="" path_value="" line=""

  [[ -f "${template_path}" ]] || return 1

  user_path="$(watchdog_resolved_path)"
  case "${template_path}" in
    *.plist)
      kind="plist"
      home_value="$(watchdog_xml_escape "${target_home}")"
      claude_value="$(watchdog_xml_escape "${claude_home}")"
      log_value="$(watchdog_xml_escape "${log_dir}")"
      path_value="$(watchdog_xml_escape "${user_path}")"
      ;;
    *.service|*.timer)
      kind="systemd"
      home_value="$(watchdog_systemd_escape "${target_home}")"
      claude_value="$(watchdog_systemd_escape "${claude_home}")"
      log_value="$(watchdog_systemd_escape "${log_dir}")"
      path_value="$(watchdog_systemd_escape "${user_path}")"
      ;;
    *) return 1 ;;
  esac
  [[ -n "${kind}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//__OMC_HOME__/${claude_value}}"
    line="${line//__OMC_USER_HOME__/${home_value}}"
    line="${line//__OMC_LOG_DIR__/${log_value}}"
    line="${line//__OMC_PATH__/${path_value}}"
    printf '%s\n' "${line}"
  done < "${template_path}"
}

render_watchdog_cron_line() {
  local script_path="${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  local quoted_script=""
  printf -v quoted_script '%q' "${script_path}"
  quoted_script="${quoted_script//%/\\%}"
  printf '*/2 * * * * bash %s >/dev/null 2>&1' "${quoted_script}"
}

read_watchdog_crontab() {
  if ! command -v crontab >/dev/null 2>&1; then
    return 127
  fi

  local current=""
  local rc=0
  set +e
  current="$(crontab -l 2>/dev/null)"
  rc=$?
  set -e

  case "${rc}" in
    0)
      printf '%s' "${current}"
      return 0
      ;;
    1)
      return 0
      ;;
    *)
      return "${rc}"
      ;;
  esac
}

verify_resume_watchdog_scheduler() {
  local resume_watchdog=""
  local scheduler_issues=0
  local platform_name=""
  local expected_tmp=""
  local dest=""
  local template=""
  local remediation_hint=""
  local cron_line=""
  local cron_contents=""
  local cron_rc=0

  resume_watchdog="$(read_conf_value "resume_watchdog")"

  platform_name="$(verify_platform)"

  compare_scheduler_file() {
    local label="${1:-}"
    local template_path="${2:-}"
    local dest_path="${3:-}"

    if [[ ! -f "${dest_path}" ]]; then
      foreign_report "resume_watchdog=on but ${label} is missing at ${dest_path}"
      scheduler_issues=$((scheduler_issues + 1))
      return 0
    fi

    expected_tmp="$(mktemp)"
    if ! render_watchdog_template "${template_path}" > "${expected_tmp}"; then
      rm -f "${expected_tmp}" 2>/dev/null || true
      fail "Could not render expected ${label} from ${template_path}"
      return 0
    fi

    if cmp -s "${expected_tmp}" "${dest_path}"; then
      pass "${label} matches installed render"
    else
      foreign_report "${label} differs from expected render (${dest_path})"
      scheduler_issues=$((scheduler_issues + 1))
    fi
    rm -f "${expected_tmp}" 2>/dev/null || true
  }

  report_stale_scheduler_file() {
    local label="${1:-}"
    local dest_path="${2:-}"

    if [[ -f "${dest_path}" ]]; then
      foreign_report "resume_watchdog is not enabled but installed ${label} is still present at ${dest_path}"
      scheduler_issues=$((scheduler_issues + 1))
    fi
  }

  verify_cron_scheduler() {
    local expectation="${1:-forbidden}"
    local managed_cron_count=0 managed_marker_count=0
    cron_line="$(render_watchdog_cron_line)"
    set +e
    cron_contents="$(read_watchdog_crontab)"
    cron_rc=$?
    set -e

    if [[ "${cron_rc}" -eq 127 ]]; then
      if [[ "${expectation}" == "required" ]]; then
        info_warn "resume_watchdog=on but crontab is unavailable; cron fallback cannot be verified automatically"
      fi
      return 0
    fi
    if [[ "${cron_rc}" -ne 0 ]]; then
      foreign_report "could not read current crontab to audit the resume-watchdog scheduler"
      scheduler_issues=$((scheduler_issues + 1))
      return 0
    fi

    if [[ "${expectation}" == "required" ]]; then
      managed_cron_count="$(printf '%s\n' "${cron_contents}" \
        | grep -Fxc -- "${cron_line}" || true)"
      managed_marker_count="$(printf '%s\n' "${cron_contents}" \
        | grep -Fxc -- '# oh-my-claude resume-watchdog' || true)"
      if [[ "${managed_cron_count}" -ge 1 ]]; then
        pass "resume-watchdog cron entry matches installed render"
      else
        if [[ "${managed_marker_count}" -ge 1 ]]; then
          foreign_report "resume_watchdog=on but cron contains a stale or mismatched resume-watchdog entry"
        else
          foreign_report "resume_watchdog=on but resume-watchdog cron entry is missing"
        fi
        scheduler_issues=$((scheduler_issues + 1))
      fi

      if [[ "${managed_cron_count}" -gt 1 \
          || "${managed_marker_count}" -gt 1 ]]; then
        foreign_report "multiple resume-watchdog cron entries are present; expected exactly one managed entry"
        scheduler_issues=$((scheduler_issues + 1))
      fi
    else
      managed_cron_count="$(printf '%s\n' "${cron_contents}" \
        | grep -Fxc -- "${cron_line}" || true)"
      managed_marker_count="$(printf '%s\n' "${cron_contents}" \
        | grep -Fxc -- '# oh-my-claude resume-watchdog' || true)"
      if [[ "${managed_cron_count}" -ge 1 \
          || "${managed_marker_count}" -ge 1 ]]; then
        if [[ "${resume_watchdog}" == "on" ]]; then
          foreign_report "resume_watchdog=on but unexpected resume-watchdog cron entry is present alongside the primary scheduler"
        else
          foreign_report "resume_watchdog is not enabled but installed resume-watchdog cron entry is still present"
        fi
        scheduler_issues=$((scheduler_issues + 1))
      fi
    fi
  }

  if [[ "${resume_watchdog}" == "on" ]]; then
    case "${platform_name}" in
      macos)
        template="${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
        dest="${TARGET_HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
        compare_scheduler_file "resume-watchdog LaunchAgent" "${template}" "${dest}"
        verify_cron_scheduler "forbidden"
        ;;
      linux)
        if command -v systemctl >/dev/null 2>&1; then
          compare_scheduler_file \
            "resume-watchdog systemd service" \
            "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service" \
            "${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
          compare_scheduler_file \
            "resume-watchdog systemd timer" \
            "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer" \
            "${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
          verify_cron_scheduler "forbidden"
        else
          verify_cron_scheduler "required"
        fi
        ;;
      *)
        verify_cron_scheduler "required"
        ;;
    esac
    remediation_hint="refresh"
  else
    case "${platform_name}" in
      macos)
        report_stale_scheduler_file \
          "resume-watchdog LaunchAgent" \
          "${TARGET_HOME}/Library/LaunchAgents/dev.ohmyclaude.resume-watchdog.plist"
        ;;
      linux)
        report_stale_scheduler_file \
          "resume-watchdog systemd service" \
          "${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.service"
        report_stale_scheduler_file \
          "resume-watchdog systemd timer" \
          "${TARGET_HOME}/.config/systemd/user/oh-my-claude-resume-watchdog.timer"
        ;;
    esac
    verify_cron_scheduler "forbidden"
    remediation_hint="remove"
  fi

  if [[ "${scheduler_issues}" -gt 0 ]] && [[ "${STRICT_MODE}" != "true" ]]; then
    case "${remediation_hint}" in
      refresh)
        printf '  [info] Re-run bash %s/install-resume-watchdog.sh to refresh the installed scheduler files.\n' "${CLAUDE_HOME}"
        ;;
      remove)
        printf '  [info] Re-run bash %s/install-resume-watchdog.sh --uninstall --reset-conf to remove the installed scheduler artifacts.\n' "${CLAUDE_HOME}"
        ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

omc_version="unknown"

# Try VERSION file first (canonical), then CHANGELOG.md as fallback.
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  omc_version="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
elif [[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]]; then
  ver_line="$(grep -m1 -E '^##\s+\[?v?[0-9]' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  if [[ -n "${ver_line}" ]]; then
    omc_version="$(printf '%s' "${ver_line}" | sed 's/^##[[:space:]]*//' | sed 's/^\[//' | sed 's/].*//' | sed 's/^v//' | sed 's/[[:space:]].*//')"
  fi
fi

# ===========================================================================
# Checks
# ===========================================================================

printf 'oh-my-claude verification (%s)\n' "${omc_version}"
printf 'Checking installation under %s\n\n' "${CLAUDE_HOME}"

# ---------------------------------------------------------------------------
# 1. Required files and directories
# ---------------------------------------------------------------------------

printf '1. Required paths\n'

if [[ "${JQ_RUNTIME_AVAILABLE}" != "true" ]]; then
  fail "jq runtime dependency is missing; hooks and verifier JSON checks cannot run"
else
  pass "jq runtime dependency"
fi

TRUSTED_SHA256_TOOL=""
TRUSTED_SHA256_TOOL="$(\resolve_trusted_sha256_executable 2>/dev/null)" \
  || TRUSTED_SHA256_TOOL=""
if [[ -n "${TRUSTED_SHA256_TOOL}" ]]; then
  pass "Trusted SHA-256 authority executable (${TRUSTED_SHA256_TOOL})"
else
  fail "No trusted shasum/sha256sum executable; Definition and verification authority cannot be sealed"
fi

if command -v claude >/dev/null 2>&1; then
  claude_version_raw="$(claude --version 2>/dev/null || true)"
  claude_version="$(printf '%s' "${claude_version_raw}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ "${claude_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    claude_major="${BASH_REMATCH[1]}"
    claude_minor="${BASH_REMATCH[2]}"
    claude_patch="${BASH_REMATCH[3]}"
    if (( claude_major > 2 || (claude_major == 2 && claude_minor > 1) || (claude_major == 2 && claude_minor == 1 && claude_patch >= 163) )); then
      pass "Claude Code supports the complete closeout hook stack (${claude_version})"
    else
      fail "Claude Code ${claude_version} is too old; 2.1.163+ is required for complete closeout hook handling"
    fi
  else
    info_warn "Could not parse Claude Code version; 2.1.163+ is required"
  fi
else
  info_warn "Claude Code binary not found on PATH; runtime version check skipped (2.1.163+ required)"
fi

required_paths=(
  "${CLAUDE_HOME}/settings.json"
  "${CLAUDE_HOME}/CLAUDE.md"
  "${CLAUDE_HOME}/statusline.py"
  "${CLAUDE_HOME}/omc-repro.sh"
  "${CLAUDE_HOME}/output-styles/oh-my-claude.md"
  "${CLAUDE_HOME}/output-styles/executive-brief.md"
  "${CLAUDE_HOME}/quality-pack/scripts/prompt-intent-router.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-compact-handoff.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-resume-hint.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-watchdog-health.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-drift-check.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-welcome.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-self-audit-nudge.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/session-start-auto-tune.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/record-self-audit.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/first-prompt-session-init.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/pre-compact-snapshot.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/post-compact-summary.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/stop-failure-handler.sh"
  "${CLAUDE_HOME}/quality-pack/scripts/resume-watchdog.sh"
  "${CLAUDE_HOME}/install-resume-watchdog.sh"
  "${CLAUDE_HOME}/launchd/dev.ohmyclaude.resume-watchdog.plist"
  "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.service"
  "${CLAUDE_HOME}/systemd/oh-my-claude-resume-watchdog.timer"
  "${CLAUDE_HOME}/quality-pack/memory/core.md"
  "${CLAUDE_HOME}/quality-pack/memory/skills.md"
  "${CLAUDE_HOME}/quality-pack/memory/model-robustness.md"
  "${CLAUDE_HOME}/quality-pack/memory/intellectual-craft.md"
  "${CLAUDE_HOME}/quality-pack/memory/compact.md"
  "${CLAUDE_HOME}/quality-pack/memory/auto-memory.md"
  "${CLAUDE_HOME}/quality-pack/design-craft/art-taste-doctrine.md"
  "${CLAUDE_HOME}/quality-pack/design-craft/taste-skill-doctrine.md"
  "${CLAUDE_HOME}/quality-pack/design-craft/design-for-hackers.md"
  "${CLAUDE_HOME}/quality-pack/design-craft/a11y-doctrine.md"
  "${CLAUDE_HOME}/quality-pack/research-craft/scientific-rigor.md"
  "${CLAUDE_HOME}/quality-pack/research-craft/citation-integrity.md"
  "${CLAUDE_HOME}/quality-pack/research-craft/figure-craft.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/closeout-preflight.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/closeout-display.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-dispatch.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/reflect-after-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-advisory-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-tool-start-revision.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-delivery-action.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/circuit-breaker.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/posttool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/posttool-dispatch.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-edit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/dispatch-recovery-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-intent-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/quality-constitution-authority-guard.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/common.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/state-io.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/plan-publication-transaction.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/classifier.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/verification.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/quality-contract.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/quality-constitution-authority.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/lib/canary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/pretool-timing.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-time-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/canary-claim-audit.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/stop-transcript-archive.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-time.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/blindspot-inventory.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/check-latency-budgets.sh"
  "${CLAUDE_HOME}/skills/ulw-time/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-serendipity.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-reviewer.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-subagent-summary.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-pending-agent.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/resolve-agent-model.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-plan.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-council-coverage.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-scope-checklist.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-discovered-scope.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-deactivate.sh"
  "${CLAUDE_HOME}/skills/autowork/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-status/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-status.sh"
  "${CLAUDE_HOME}/skills/ulw-report/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-report.sh"
  "${CLAUDE_HOME}/agents/quality-planner.md"
  "${CLAUDE_HOME}/agents/quality-reviewer.md"
  "${CLAUDE_HOME}/agents/excellence-reviewer.md"
  "${CLAUDE_HOME}/agents/release-reviewer.md"
  "${CLAUDE_HOME}/agents/writing-architect.md"
  "${CLAUDE_HOME}/agents/prometheus.md"
  "${CLAUDE_HOME}/agents/abstraction-critic.md"
  "${CLAUDE_HOME}/agents/divergent-framer.md"
  "${CLAUDE_HOME}/agents/research-data-analyst.md"
  "${CLAUDE_HOME}/agents/literature-scout.md"
  "${CLAUDE_HOME}/agents/rigor-reviewer.md"
  "${CLAUDE_HOME}/skills/council/SKILL.md"
  "${CLAUDE_HOME}/skills/data-analysis/SKILL.md"
  "${CLAUDE_HOME}/skills/lit-review/SKILL.md"
  "${CLAUDE_HOME}/skills/manuscript/SKILL.md"
  "${CLAUDE_HOME}/skills/diverge/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-demo/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-skip/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-correct/SKILL.md"
  "${CLAUDE_HOME}/skills/mark-deferred/SKILL.md"
  "${CLAUDE_HOME}/skills/ulw-pause/SKILL.md"
  "${CLAUDE_HOME}/skills/goal/SKILL.md"
  "${CLAUDE_HOME}/skills/memory-audit/SKILL.md"
  "${CLAUDE_HOME}/skills/test-audit/SKILL.md"
  "${CLAUDE_HOME}/skills/frontend-design/SKILL.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/SKILL.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/LICENSE"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/api.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/views.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/data.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/navigation.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/design.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/accessibility.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/performance.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/swift.md"
  "${CLAUDE_HOME}/skills/swiftui-pro/references/hygiene.md"
  "${CLAUDE_HOME}/skills/gamedev/SKILL.md"
  "${CLAUDE_HOME}/skills/gamedev/references/unity.md"
  "${CLAUDE_HOME}/skills/gamedev/references/godot.md"
  "${CLAUDE_HOME}/skills/gamedev/references/web.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-skip-register.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-correct-record.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-finding-list.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/find-design-contract.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-archetype.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/mark-deferred.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/ulw-pause.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/audit-memory.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/claim-resume-request.sh"
  "${CLAUDE_HOME}/skills/ulw-resume/SKILL.md"
  "${CLAUDE_HOME}/skills/omc-config/SKILL.md"
  "${CLAUDE_HOME}/skills/quality-constitution/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/omc-config.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/quality-constitution.sh"
  "${CLAUDE_HOME}/skills/whats-new/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/show-whats-new.sh"
  "${CLAUDE_HOME}/skills/omc-doctor/SKILL.md"
  "${CLAUDE_HOME}/skills/autowork/scripts/omc-doctor.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/posttool-dispatch.sh"
  "${CLAUDE_HOME}/skills/autowork/scripts/record-repo-lesson.sh"
  "${CLAUDE_HOME}/bin/omc"
  "${CLAUDE_HOME}/oh-my-claude.conf.example"
)

for path in "${required_paths[@]}"; do
  allow_required_leaf_symlink=0
  [[ "${path}" == "${CLAUDE_HOME}/settings.json" ]] \
    && allow_required_leaf_symlink=1
  if ! managed_path_components_are_safe "${path}" \
      "${allow_required_leaf_symlink}"; then
    fail "Unsafe symlinked or non-directory managed path: ${path}"
  elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
    fail "Missing: ${path}"
  elif [[ "${path}" == "${CLAUDE_HOME}/settings.json" \
      && -f "${path}" ]]; then
    pass "${path}"
  elif [[ -f "${path}" && ! -L "${path}" ]]; then
    pass "${path}"
  else
    fail "Non-regular managed file: ${path}"
  fi
done

# Output-style frontmatter integrity. The paths were already verified
# above; here we additionally confirm the frontmatter `name:` field
# matches the expected literal for each bundled style file. Drift between
# the file and the literal would let a corrupted or renamed file pass
# existence-only verification while silently failing at session start
# when Claude Code tries to resolve outputStyle. The active patch style
# (config/settings.patch.json's outputStyle) is `oh-my-claude` —
# `executive-brief.md` is shipped as an opt-in alternative selected via
# the `output_style=executive` conf flag.
#
# Robust to CRLF line endings, multi-space-after-colon, and embedded
# colons in the name itself. The naive `awk -F': ' '{print $2}'` form
# would carry a trailing \r on Windows-edited files and break the
# equality check below — silently identical to the F-010 leak path
# this verifier is supposed to catch.
for bundled_style in "oh-my-claude:oh-my-claude" "executive-brief:executive-brief"; do
  style_basename="${bundled_style%%:*}"
  expected_name="${bundled_style##*:}"
  style_path="${CLAUDE_HOME}/output-styles/${style_basename}.md"
  if [[ -f "${style_path}" ]]; then
    style_name="$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${style_path}" 2>/dev/null || true)"
    if [[ "${style_name}" == "${expected_name}" ]]; then
      pass "output-style frontmatter name: ${style_name}"
    else
      fail "output-style frontmatter name '${style_name}' in ${style_path} does not match expected '${expected_name}' (file may be corrupted)"
    fi
  fi
done

printf '\n'

# ---------------------------------------------------------------------------
# 2. JSON syntax of settings.json
# ---------------------------------------------------------------------------

printf '2. Settings JSON syntax\n'

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json does not exist; cannot validate"
else
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "${CLAUDE_HOME}/settings.json" >/dev/null 2>&1; then
      pass "settings.json is valid JSON"
    else
      fail "settings.json has invalid JSON syntax"
    fi
  elif command -v jq >/dev/null 2>&1; then
    if jq empty "${CLAUDE_HOME}/settings.json" 2>/dev/null; then
      pass "settings.json is valid JSON"
    else
      fail "settings.json has invalid JSON syntax"
    fi
  else
    info_warn "Skipping JSON validation (neither python3 nor jq available)"
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 3. Bash syntax check on all hook scripts
# ---------------------------------------------------------------------------

printf '3. Hook script syntax (bash -n)\n'

hook_scripts=()
MANIFEST_PATH="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
if managed_path_components_are_safe "${MANIFEST_PATH}" 0 \
    && [[ -f "${MANIFEST_PATH}" && ! -L "${MANIFEST_PATH}" ]]; then
  while IFS= read -r relative_path || [[ -n "${relative_path}" ]]; do
    [[ "${relative_path}" == *.sh ]] || continue
    case "${relative_path}" in
      /*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*$'\n'*|*$'\r'*)
        fail "Unsafe shell-script path in installed manifest: ${relative_path}"
        continue
        ;;
    esac
    script_path="${CLAUDE_HOME}/${relative_path}"
    if ! managed_path_components_are_safe "${script_path}" 0 \
        || [[ ! -f "${script_path}" || -L "${script_path}" ]]; then
      fail "Cannot check (missing, nonregular, or symlinked): ${script_path}"
      continue
    fi
    hook_scripts+=("${script_path}")
  done < "${MANIFEST_PATH}"
else
  fail "installed-manifest.txt missing or unsafe; cannot prove complete shell syntax coverage"
fi

if [[ "${#hook_scripts[@]}" -eq 0 ]]; then
  fail "No manifest-owned shell scripts found for syntax checking"
fi

for script in "${hook_scripts[@]}"; do
  if [[ ! -f "${script}" || -L "${script}" ]]; then
    fail "Cannot check (missing, nonregular, or symlinked): ${script}"
    continue
  fi
  if bash -n "${script}" 2>/dev/null; then
    pass "${script##*/}"
  else
    fail "Syntax error in: ${script}"
  fi
done

printf '\n'

# ---------------------------------------------------------------------------
# 4. Required hooks present in settings.json
# ---------------------------------------------------------------------------

printf '4. Required hooks in settings.json\n'

read_disable_all_hooks_value() {
  local settings_file="${1:-}"
  [[ -f "${settings_file}" ]] || { printf 'unset'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      if has("disableAllHooks") and (.disableAllHooks | type) == "boolean"
      then (.disableAllHooks | tostring)
      else "unset"
      end
    ' "${settings_file}" 2>/dev/null || printf 'unset'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    value = data.get("disableAllHooks", None)
    sys.stdout.write("true" if value is True else "false" if value is False else "unset")
except Exception:
    sys.stdout.write("unset")
' "${settings_file}" 2>/dev/null || printf 'unset'
  else
    printf 'unset'
  fi
}

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json missing; cannot check hooks"
else
  # Claude Code's hook kill switch overrides every correctly installed
  # event/matcher entry. Check both the user setting (global install health)
  # and the effective project/local setting for the directory where verify was
  # invoked. settings.local.json has precedence over settings.json.
  hooks_user_setting="$(read_disable_all_hooks_value "${CLAUDE_HOME}/settings.json")"
  if [[ "${hooks_user_setting}" == "true" ]]; then
    fail "User-level hooks disabled: settings.json has disableAllHooks=true"
  else
    pass "User-level hook kill switch is not enabled"
  fi

  verify_project_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${PWD}")"
  hooks_project_setting="$(read_disable_all_hooks_value "${verify_project_root}/.claude/settings.json")"
  hooks_local_setting="$(read_disable_all_hooks_value "${verify_project_root}/.claude/settings.local.json")"
  hooks_project_effective="${hooks_project_setting}"
  [[ "${hooks_local_setting}" != "unset" ]] && hooks_project_effective="${hooks_local_setting}"
  if [[ "${hooks_project_effective}" == "true" ]]; then
    fail "Hooks disabled for current project: ${verify_project_root}/.claude settings resolve disableAllHooks=true"
  else
    pass "Current project hook kill switch is not enabled"
  fi

  # settings.patch.json is the single wiring authority. Verify the complete
  # contract — event, exact entry envelope (all keys except sibling hooks),
  # and exact hook object — exactly once. Foreign sibling hooks may share the
  # entry, but modifiers such as timeout/async cannot silently change a
  # managed hook's behavior. Also reject an allowed managed command observed
  # under any non-canonical contract. Basename or path-fragment presence cannot
  # prove that required role arguments and lifecycle selectors are intact.
  hook_patch_path="${SCRIPT_DIR}/config/settings.patch.json"
  exact_tuple_report=""
  exact_tuple_rc=0
  if [[ ! -f "${hook_patch_path}" ]]; then
    fail "settings patch missing; cannot verify exact managed hook tuples"
  elif command -v jq >/dev/null 2>&1; then
    exact_tuple_report="$(jq -nr \
      --slurpfile expected "${hook_patch_path}" \
      --slurpfile actual "${CLAUDE_HOME}/settings.json" '
      def projected_entries($managed_commands):
        [(.hooks // {}) | to_entries[] as $event
          | ($event.value // [])[]? as $entry
          | select(($entry | type) == "object")
          | {event: $event.key,
             entry_contract: ($entry | del(.hooks)),
             managed_hooks:
               [($entry.hooks // [])[]?
                | select(type == "object")
                | . as $hook
                | select($managed_commands | index($hook.command) != null)]}
          | select((.managed_hooks | length) > 0)];
      def field_text:
        if type == "string" then . else tojson end;
      ([($expected[0].hooks // {}) | to_entries[] | .value[]?
        | (.hooks // [])[]? | select(type == "object") | .command]
        | unique) as $managed_commands
      | ($expected[0] | projected_entries($managed_commands)) as $wanted
      | ($actual[0] | projected_entries($managed_commands)) as $observed
      | (
          ($wanted | group_by(.)[] | select(length > 1)) as $duplicates
          | $duplicates[0] as $entry
          | $entry.managed_hooks[]
          | ["AUTHORITY_DUP", ($duplicates | length | tostring), $entry.event,
             (($entry.entry_contract.matcher // "") | field_text),
             ((.type // "") | field_text),
             ((.command // "") | field_text)]
          | join("\u001f")
        ),
        (
          $wanted[] as $entry
          | ([$observed[] | select(. == $entry)] | length) as $count
          | $entry.managed_hooks[]
          | ["EXPECTED", ($count | tostring), $entry.event,
             (($entry.entry_contract.matcher // "") | field_text),
             ((.type // "") | field_text),
             ((.command // "") | field_text)]
          | join("\u001f")
        ),
        (
          $observed[] as $entry
          | select(([$wanted[] | select(. == $entry)] | length) == 0)
          | $entry.managed_hooks[]
          | ["EXTRA", "1", $entry.event,
             (($entry.entry_contract.matcher // "") | field_text),
             ((.type // "") | field_text),
             ((.command // "") | field_text)]
          | join("\u001f")
        )
    ' 2>/dev/null)" || exact_tuple_rc=$?
  elif command -v python3 >/dev/null 2>&1; then
    exact_tuple_report="$(python3 - "${hook_patch_path}" "${CLAUDE_HOME}/settings.json" <<'PY'
import json
import sys

def projected_entries(document, managed_commands):
    result = []
    for event, entries in (document.get("hooks") or {}).items():
        for entry in entries or []:
            if not isinstance(entry, dict):
                continue
            managed_hooks = []
            for hook in entry.get("hooks") or []:
                if isinstance(hook, dict) and hook.get("command") in managed_commands:
                    managed_hooks.append(hook)
            if managed_hooks:
                result.append({
                    "event": event,
                    "entry_contract": {
                        key: value for key, value in entry.items()
                        if key != "hooks"
                    },
                    "managed_hooks": managed_hooks,
                })
    return result

with open(sys.argv[1]) as source:
    expected_document = json.load(source)
managed_commands = {
    hook.get("command")
    for entries in (expected_document.get("hooks") or {}).values()
    for entry in entries or [] if isinstance(entry, dict)
    for hook in entry.get("hooks") or [] if isinstance(hook, dict)
}
wanted = projected_entries(expected_document, managed_commands)
with open(sys.argv[2]) as source:
    observed = projected_entries(json.load(source), managed_commands)
separator = "\x1f"
def field_text(value):
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"))

expected_groups = {}
for item in wanted:
    key = json.dumps(item, sort_keys=True, separators=(",", ":"))
    expected_groups.setdefault(key, [item, 0])[1] += 1
for item, count in expected_groups.values():
    if count <= 1:
        continue
    matcher = item["entry_contract"].get("matcher") or ""
    for hook in item["managed_hooks"]:
        print(separator.join(("AUTHORITY_DUP", str(count), item["event"],
                              field_text(matcher),
                              field_text(hook.get("type") or ""),
                              field_text(hook.get("command") or ""))))
for item in wanted:
    count = observed.count(item)
    matcher = item["entry_contract"].get("matcher") or ""
    for hook in item["managed_hooks"]:
        print(separator.join(("EXPECTED", str(count), item["event"],
                              field_text(matcher),
                              field_text(hook.get("type") or ""),
                              field_text(hook.get("command") or ""))))
for item in observed:
    if item not in wanted:
        matcher = item["entry_contract"].get("matcher") or ""
        for hook in item["managed_hooks"]:
            print(separator.join(("EXTRA", "1", item["event"],
                                  field_text(matcher),
                                  field_text(hook.get("type") or ""),
                                  field_text(hook.get("command") or ""))))
PY
    )" || exact_tuple_rc=$?
  else
    exact_tuple_rc=1
  fi

  if [[ "${exact_tuple_rc}" -ne 0 ]]; then
    fail "Could not compare settings.json with the exact managed hook tuple authority"
  elif [[ -n "${exact_tuple_report}" ]]; then
    while IFS=$'\x1f' read -r tuple_kind tuple_count tuple_event tuple_matcher tuple_type tuple_command; do
      if [[ "${tuple_kind}" == "AUTHORITY_DUP" ]]; then
        fail "Managed hook authority contains ${tuple_count} identical expected entries: ${tuple_event} matcher=${tuple_matcher:-<empty>} type=${tuple_type} command=${tuple_command}"
      elif [[ "${tuple_kind}" == "EXPECTED" && "${tuple_count}" == "1" ]]; then
        pass "Hook tuple: ${tuple_event} [${tuple_matcher:-universal}] -> ${tuple_command}"
      elif [[ "${tuple_kind}" == "EXPECTED" ]]; then
        fail "Managed hook tuple count is ${tuple_count}, expected 1: ${tuple_event} matcher=${tuple_matcher:-<empty>} type=${tuple_type} command=${tuple_command}"
      else
        fail "Managed hook command has non-canonical tuple/object contract: ${tuple_event} matcher=${tuple_matcher:-<empty>} type=${tuple_type} command=${tuple_command}"
      fi
    done <<< "${exact_tuple_report}"
  else
    fail "Exact managed hook tuple authority is empty"
  fi

  # The exact patch-derived comparison above is the sole managed-wiring
  # authority. Foreign hooks are audited separately in Step 8.
fi

printf '\n'

# ---------------------------------------------------------------------------
# 5. Ghostty theme (optional)
# ---------------------------------------------------------------------------

printf '5. Ghostty theme (optional)\n'

ghostty_theme="${TARGET_HOME}/.config/ghostty/themes/Claude OpenCode"
ghostty_config="${TARGET_HOME}/.config/ghostty/config"

if [[ -f "${ghostty_theme}" ]]; then
  pass "Ghostty theme file exists"
  if [[ -f "${ghostty_config}" ]]; then
    if grep -Fqx 'theme = Claude OpenCode' "${ghostty_config}" 2>/dev/null; then
      pass "Ghostty config references theme"
    else
      fail "Ghostty config is missing: theme = Claude OpenCode"
    fi
  else
    info_warn "Ghostty config file not found at ${ghostty_config}"
  fi
else
  info_warn "Ghostty theme not installed (this is optional)"
fi

printf '\n'

# ---------------------------------------------------------------------------
# 6. Agent availability (optional, requires claude CLI)
# ---------------------------------------------------------------------------

printf '6. Agent availability\n'

if command -v claude >/dev/null 2>&1; then
  # Non-interactive verify runs cannot rely on the TTY-oriented `claude
  # agents` surface; current Claude CLIs direct users to `--json` in that
  # case. Probe the machine-readable path and treat probe failure as an
  # informational skip, not an actionable install warning. Some builds
  # currently return an ACTIVE-SESSION listing here rather than an agent
  # catalog; detect that payload shape and skip instead of warning on
  # every missing bundled agent.
  set +e
  agents_output="$(claude agents --json 2>/dev/null)"
  agents_rc=$?
  set -e
  if [[ "${agents_rc}" -eq 0 ]] && [[ -n "${agents_output}" ]]; then
    agent_names="$(printf '%s' "${agents_output}" | jq -r '
      if type == "array" then
        [
          .[]? |
          (.name // .id // .slug // .agentName // empty) |
          tostring
        ] | map(select(length > 0)) | .[]
      else
        empty
      end
    ' 2>/dev/null || true)"
    if [[ -n "${agent_names}" ]]; then
      for agent_name in quality-planner quality-reviewer prometheus writing-architect; do
        if printf '%s\n' "${agent_names}" | grep -qx "${agent_name}"; then
          pass "Agent: ${agent_name}"
        else
          warn "Agent not listed by claude CLI: ${agent_name}"
        fi
      done
    elif printf '%s' "${agents_output}" | jq -e '
      type == "array" and any(.[]?; has("sessionId") and has("cwd") and has("status"))
    ' >/dev/null 2>&1; then
      info_warn "claude agents --json returned active sessions, not an agent catalog; skipping agent availability check"
    else
      info_warn "claude agents --json returned an unrecognized payload; skipping agent availability check"
    fi
  elif [[ "${agents_rc}" -eq 0 ]]; then
    info_warn "claude agents --json returned no output; skipping agent availability check"
  else
    info_warn "claude agents --json unavailable; skipping agent availability check"
  fi
else
  info_warn "claude CLI not found; skipping agent availability check"
fi

printf '\n'

# ---------------------------------------------------------------------------
# 7. Model tier configuration (informational)
# ---------------------------------------------------------------------------

printf '7. Model tier\n'

conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
saved_tier=""
[[ -f "${conf_path}" ]] && saved_tier="$(read_conf_value model_tier)"
active_tier="${saved_tier}"
tier_source="saved"
if [[ -n "${OMC_MODEL_TIER:-}" ]]; then
  case "${OMC_MODEL_TIER}" in
    quality|balanced|economy)
      active_tier="${OMC_MODEL_TIER}"
      tier_source="environment"
      ;;
    *)
      info_warn "Invalid OMC_MODEL_TIER='${OMC_MODEL_TIER}' ignored; falling back to saved/default tier"
      ;;
  esac
fi
case "${active_tier:-}" in
  quality|balanced|economy)
    pass "Active model tier: ${active_tier} (${tier_source})"
    ;;
  "")
    if [[ -f "${conf_path}" ]]; then
      pass "No model tier set (using default: balanced)"
    else
      pass "No config file (using default: balanced)"
    fi
    ;;
  *)
    info_warn "Invalid saved model tier '${saved_tier}' ignored; using default: balanced"
    pass "Active model tier: balanced (default)"
    ;;
esac

# Count current agent model assignments.
opus_count=0
sonnet_count=0
inherit_count=0
haiku_count=0
invalid_model_count=0
model_agent_count=0
for agent_file in "${CLAUDE_HOME}/agents/"*.md; do
  [[ -f "${agent_file}" ]] || continue
  model_agent_count=$((model_agent_count + 1))
  model_line_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  if [[ "${model_line_count}" != "1" ]]; then
    invalid_model_count=$((invalid_model_count + 1))
    continue
  fi
  agent_model="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  case "${agent_model}" in
    opus) opus_count=$((opus_count + 1)) ;;
    sonnet) sonnet_count=$((sonnet_count + 1)) ;;
    inherit) inherit_count=$((inherit_count + 1)) ;;
    haiku) haiku_count=$((haiku_count + 1)) ;;
    *) invalid_model_count=$((invalid_model_count + 1)) ;;
  esac
done
printf '  [info] Agent models: %d inherit (session model), %d opus, %d sonnet, %d haiku, %d invalid/other (total %d)\n' \
  "${inherit_count}" "${opus_count}" "${sonnet_count}" "${haiku_count}" \
  "${invalid_model_count}" "${model_agent_count}"

# C8: bundle agent completeness — required_paths only spot-checks a few
# sentinel agents, so a partial install missing the other agents would
# pass. Compare the installed agent set against the source bundle
# (SCRIPT_DIR is the repo root); a missing agent is a broken install.
# Guarded so a standalone run without the source tree degrades cleanly.
bundle_agents_dir="${SCRIPT_DIR}/bundle/dot-claude/agents"
if [[ -d "${bundle_agents_dir}" ]]; then
  missing_agents=""
  bundle_agent_count=0
  for bundle_agent in "${bundle_agents_dir}"/*.md; do
    [[ -f "${bundle_agent}" ]] || continue
    bundle_agent_count=$(( bundle_agent_count + 1 ))
    agent_base="$(basename "${bundle_agent}")"
    if [[ ! -f "${CLAUDE_HOME}/agents/${agent_base}" ]]; then
      missing_agents="${missing_agents} ${agent_base}"
    fi
  done
  if [[ -z "${missing_agents# }" ]]; then
    pass "All ${bundle_agent_count} bundle agents present in install"
  elif [[ "${STRICT_MODE}" == "true" ]]; then
    fail "Install missing agents present in source bundle:${missing_agents}"
  else
    # Warn (not fail) by default: a source tree ahead of the installed
    # version (active dev before re-install) legitimately has extra agents.
    # --strict escalates to fail for incident-response / CI integrity audits.
    warn "Install missing agents from source bundle (stale install? run install.sh):${missing_agents}"
  fi
fi

# C8: bundle skill completeness — mirror of the agent check above for skill
# dirs. required_paths spot-checks only some skills, so a partial install
# missing a skill dir (e.g. gamedev/) would otherwise pass verify.
bundle_skills_dir="${SCRIPT_DIR}/bundle/dot-claude/skills"
if [[ -d "${bundle_skills_dir}" ]]; then
  missing_skills=""
  bundle_skill_count=0
  for skill_dir in "${bundle_skills_dir}"/*/; do
    [[ -d "${skill_dir}" ]] || continue
    bundle_skill_count=$(( bundle_skill_count + 1 ))
    skill_base="$(basename "${skill_dir}")"
    if [[ ! -d "${CLAUDE_HOME}/skills/${skill_base}" ]]; then
      missing_skills="${missing_skills} ${skill_base}"
    fi
  done
  if [[ -z "${missing_skills# }" ]]; then
    pass "All ${bundle_skill_count} bundle skill dirs present in install"
  elif [[ "${STRICT_MODE}" == "true" ]]; then
    fail "Install missing skill dirs present in source bundle:${missing_skills}"
  else
    warn "Install missing skill dirs from source bundle (stale install? run install.sh):${missing_skills}"
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 8. Foreign hook detection (A2-HIGH-2 from 4-attacker security review)
# ---------------------------------------------------------------------------
#
# Step 4 above checks "are the bundled hooks present?" — but never asks
# the inverse "is anything ELSE wired into settings.json?". An A2
# attacker (write-inside-`~/.claude/`) who appends a non-bundled hook
# entry (e.g. {matcher: "*", command: "bash /tmp/persistence.sh"})
# survives every install.sh run silently because the merge is additive.
# Step 8 enumerates every hook command in settings.json and FAILs on
# any path not under the bundled allowlist. This turns verify.sh into
# the recovery boundary the user expects: "no foreign content has been
# injected since install" rather than just "the install ran".

printf '8. Foreign hook detection\n'

# Default UX: warn on detect (preserves the verify.sh flow for users
# with legitimate custom hooks layered on top of the harness — CI
# integrations, personal automation, dev-loop hooks). --strict
# escalates to fail for security-conscious audits where any foreign
# content should break the verify exit code.
foreign_report() {
  if [[ "${STRICT_MODE}" == "true" ]]; then
    fail "$1"
  else
    warn "$1"
  fi
}

if [[ ! -f "${CLAUDE_HOME}/settings.json" ]]; then
  fail "settings.json missing; cannot check for foreign hooks"
elif ! command -v jq >/dev/null 2>&1; then
  info_warn "jq not available; foreign-hook check skipped"
else
  # Distinguish jq parse failure from "no foreign entries". A
  # malformed settings.json is itself an A2 indicator that warrants a
  # loud signal — not a silent skip.
  jq_rc=0
  jq_err="$(jq -r --slurpfile patch "${SCRIPT_DIR}/config/settings.patch.json" '
    . as $settings
    |
    def hook_command:
      if type == "object" and has("command") and .command != null
      then .command else "" end;
    def command_text:
      if type == "string" then . else tojson end;
    [($patch[0].hooks // {}) | to_entries[] | .value[]?
      | (.hooks // [])[]? | select(type == "object")
      | hook_command] | unique as $allowed
    | [($settings.hooks // {}) | to_entries[] | .value[]?
       | (.hooks // [])[]? | select(type == "object")
       | hook_command] | unique
    | .[] as $command
    | select(($allowed | index($command)) == null)
    | $command | command_text
  ' "${CLAUDE_HOME}/settings.json" 2>&1)" || jq_rc=$?

  if [[ ${jq_rc} -ne 0 ]]; then
    fail "settings.json failed jq parse: ${jq_err}"
  else
    # The exact patch command set is the allowlist. A new file under a
    # managed directory, an omitted role/phase argument, or a command with
    # altered whitespace is still foreign until the patch explicitly owns it.
    foreign_count=0
    while IFS= read -r cmd; do
      [[ -z "${cmd}" ]] && continue
      foreign_report "Foreign hook command: ${cmd}"
      foreign_count=$((foreign_count + 1))
    done <<< "${jq_err}"

    if [[ "${foreign_count}" -eq 0 ]]; then
      pass "No foreign hook commands"
    elif [[ "${STRICT_MODE}" != "true" ]]; then
      printf '  [info] Re-run with --strict to fail verify on foreign hooks.\n'
    fi
  fi
fi

# v1.32.16 Wave 6 (release-reviewer follow-up): .statusLine.command
# is a code-execution surface Claude Code execs every status-bar
# refresh — between installs the user's settings.json could carry an
# attacker-replaced value. The bundled patch ships a single fixed
# value (`~/.claude/statusline.py`); equality check covers it. Same
# default-warn / --strict-fail pattern as Step 8.
if [[ -f "${CLAUDE_HOME}/settings.json" ]] && command -v jq >/dev/null 2>&1; then
  status_cmd="$(jq -r '.statusLine.command // empty' \
    "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
  status_object_matches="$(jq -r --slurpfile patch \
    "${SCRIPT_DIR}/config/settings.patch.json" \
    '.statusLine == $patch[0].statusLine' \
    "${CLAUDE_HOME}/settings.json" 2>/dev/null || printf 'false')"
  # shellcheck disable=SC2088 # comparing unexpanded `~` literal — bundled patch ships the unexpanded form, Claude Code expands at exec time
  if [[ "${status_cmd}" != "~/.claude/statusline.py" ]]; then
    foreign_report ".statusLine.command differs from bundled (got: ${status_cmd}; expected: ~/.claude/statusline.py)"
    if [[ "${STRICT_MODE}" != "true" ]]; then
      printf '  [info] Re-run install.sh to restore the bundled value, or --strict to fail verify on this divergence.\n'
    fi
  elif [[ "${status_object_matches}" != "true" ]]; then
    foreign_report ".statusLine object differs from bundled type/command/padding contract"
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 9. Drift detection via SHA-256 manifest (A2-MED-4 from 4-attacker review)
# ---------------------------------------------------------------------------
#
# Step 3 above checks "do hook scripts pass bash -n syntax?" — but
# `bash -n` accepts any syntactically-valid script, including a hostile
# replacement (e.g. stop-guard.sh swapped for an exfiltration shim).
# install.sh writes ${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt
# with one `<sha256>  <relative-path>` line per bundled file. Step 9
# re-hashes each tracked path and FAILs on mismatch. The path-only manifest,
# checksum manifest, and available source bundle are compared as independent
# coverage sets, so deleting the same row from both mutable installed ledgers
# no longer hides a managed file. This still is not OS immutability — a
# same-user process can rewrite installed files and both ledgers — but verify
# now detects incomplete ledgers as well as byte drift.

printf '9. Drift detection (SHA-256 manifest)\n'

HASHES_PATH="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
if [[ ! -e "${HASHES_PATH}" && ! -L "${HASHES_PATH}" ]]; then
  fail "installed-hashes.txt missing; complete managed-file coverage cannot be proved (reinstall to generate)"
elif ! managed_path_components_are_safe "${HASHES_PATH}" 0 \
    || [[ ! -f "${HASHES_PATH}" || -L "${HASHES_PATH}" ]]; then
  fail "installed-hashes.txt is not a safe regular file; reinstall to restore integrity checking"
else
  hash_manifest_valid="true"
  installed_manifest_set_valid="true"
  hash_manifest_count=0
  hash_paths_tmp="$(mktemp)"
  manifest_paths_tmp="$(mktemp)"

  # The path-only and checksum manifests are one coverage authority. Validate
  # every installed-manifest row (not only *.sh rows consumed by Step 3), then
  # compare exact sorted sets below. A mutable attacker must not be able to
  # remove the same file from both ledgers and keep `Errors: 0`.
  if ! managed_path_components_are_safe "${MANIFEST_PATH}" 0 \
      || [[ ! -f "${MANIFEST_PATH}" || -L "${MANIFEST_PATH}" ]]; then
    fail "installed-manifest.txt missing or unsafe; managed-file coverage cannot be proved"
    installed_manifest_set_valid="false"
  else
    while IFS= read -r manifest_relative_path \
        || [[ -n "${manifest_relative_path}" ]]; do
      case "${manifest_relative_path}" in
        ""|/*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*)
          fail "Unsafe installed manifest path: ${manifest_relative_path:-<empty>}"
          installed_manifest_set_valid="false"
          continue
          ;;
      esac
      manifest_installed_path="${CLAUDE_HOME}/${manifest_relative_path}"
      if ! managed_path_components_are_safe "${manifest_installed_path}" 0 \
          || [[ ! -f "${manifest_installed_path}" \
            || -L "${manifest_installed_path}" ]]; then
        fail "Installed manifest references unsafe, missing, or non-regular managed file: ${manifest_relative_path}"
        installed_manifest_set_valid="false"
        continue
      fi
      printf '%s\n' "${manifest_relative_path}" >> "${manifest_paths_tmp}"
    done < "${MANIFEST_PATH}"
  fi

  installed_manifest_count="$(wc -l < "${manifest_paths_tmp}" 2>/dev/null \
    | tr -d '[:space:]' || printf '0')"
  [[ "${installed_manifest_count}" =~ ^[0-9]+$ ]] \
    || installed_manifest_count=0
  if [[ "${installed_manifest_count}" -eq 0 ]]; then
    fail "Installed manifest is empty"
    installed_manifest_set_valid="false"
  fi
  duplicate_manifest_path="$(LC_ALL=C sort "${manifest_paths_tmp}" \
    | uniq -d | head -n 1 || true)"
  if [[ -n "${duplicate_manifest_path}" ]]; then
    fail "Installed manifest contains duplicate path: ${duplicate_manifest_path}"
    installed_manifest_set_valid="false"
  fi
  LC_ALL=C sort -u -o "${manifest_paths_tmp}" "${manifest_paths_tmp}"

  while IFS= read -r hash_line || [[ -n "${hash_line}" ]]; do
    if [[ ! "${hash_line}" =~ ^[0-9A-Fa-f]{64}[[:space:]][[:space:]](.+)$ ]]; then
      fail "Malformed checksum manifest line: ${hash_line:-<empty>}"
      hash_manifest_valid="false"
      continue
    fi
    hash_relative_path="${BASH_REMATCH[1]}"
    case "${hash_relative_path}" in
      /*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*)
        fail "Unsafe checksum manifest path: ${hash_relative_path}"
        hash_manifest_valid="false"
        continue
        ;;
    esac
    hash_installed_path="${CLAUDE_HOME}/${hash_relative_path}"
    if ! managed_path_components_are_safe "${hash_installed_path}" 0 \
        || [[ ! -f "${hash_installed_path}" \
          || -L "${hash_installed_path}" ]]; then
      fail "Checksum manifest references unsafe, missing, or non-regular managed file: ${hash_relative_path}"
      hash_manifest_valid="false"
      continue
    fi
    hash_manifest_count=$((hash_manifest_count + 1))
    printf '%s\n' "${hash_relative_path}" >> "${hash_paths_tmp}"
  done < "${HASHES_PATH}"

  if [[ "${hash_manifest_count}" -eq 0 ]]; then
    fail "Checksum manifest is empty"
    hash_manifest_valid="false"
  fi
  duplicate_hash_path="$(LC_ALL=C sort "${hash_paths_tmp}" | uniq -d | head -n 1 || true)"
  if [[ -n "${duplicate_hash_path}" ]]; then
    fail "Checksum manifest contains duplicate path: ${duplicate_hash_path}"
    hash_manifest_valid="false"
  fi
  LC_ALL=C sort -u -o "${hash_paths_tmp}" "${hash_paths_tmp}"

  if [[ "${installed_manifest_set_valid}" == "true" \
      && "${hash_manifest_valid}" == "true" ]]; then
    manifest_only_count="$(LC_ALL=C comm -23 "${manifest_paths_tmp}" \
      "${hash_paths_tmp}" | wc -l | tr -d '[:space:]')"
    hashes_only_count="$(LC_ALL=C comm -13 "${manifest_paths_tmp}" \
      "${hash_paths_tmp}" | wc -l | tr -d '[:space:]')"
    if [[ "${manifest_only_count}" -ne 0 || "${hashes_only_count}" -ne 0 ]]; then
      first_manifest_only="$(LC_ALL=C comm -23 "${manifest_paths_tmp}" \
        "${hash_paths_tmp}" | head -n 1 || true)"
      first_hashes_only="$(LC_ALL=C comm -13 "${manifest_paths_tmp}" \
        "${hash_paths_tmp}" | head -n 1 || true)"
      fail "Installed manifest/checksum path sets differ (manifest-only=${manifest_only_count}${first_manifest_only:+ first=${first_manifest_only}}; hashes-only=${hashes_only_count}${first_hashes_only:+ first=${first_hashes_only}})"
      hash_manifest_valid="false"
    else
      pass "Installed manifest and checksum coverage sets match exactly"
    fi
  fi

  # When verify.sh is run from a source checkout, that checkout supplies the
  # third independent path authority. `exclude_ios=on` is persisted by the
  # current installer and removes only the four explicitly optional iOS agent
  # definitions from admission; every other bundled regular file must appear.
  source_bundle_root="${SCRIPT_DIR}/bundle/dot-claude"
  if [[ ! -d "${source_bundle_root}" || -L "${source_bundle_root}" ]]; then
    fail "Source bundle is missing or unsafe; independent managed-file coverage cannot be proved: ${source_bundle_root}"
    hash_manifest_valid="false"
  elif [[ "${installed_manifest_set_valid}" == "true" ]]; then
    source_paths_tmp="$(mktemp)"
    source_nodes_tmp="$(mktemp)"
    source_paths_valid="true"
    exclude_ios_value="$(awk '
      index($0, "=") > 0 && substr($0, 1, index($0, "=") - 1) == "exclude_ios" {
        candidate=substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
        if (candidate == "on" || candidate == "off") value=candidate
      }
      END { print value }
    ' "${CLAUDE_HOME}/oh-my-claude.conf" 2>/dev/null || true)"
    if ! find "${source_bundle_root}" -mindepth 1 -print0 \
        > "${source_nodes_tmp}" 2>/dev/null; then
      fail "Could not enumerate source bundle coverage"
      source_paths_valid="false"
    fi
    while IFS= read -r -d '' source_path; do
      source_relative_path="${source_path#"${source_bundle_root}"/}"
      [[ "${source_relative_path}" != "${source_path}" ]] || {
        source_paths_valid="false"
        continue
      }
      case "${source_relative_path}" in
        ""|/*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*)
          fail "Unsafe source bundle path: ${source_relative_path:-<empty>}"
          source_paths_valid="false"
          continue
          ;;
      esac
      if [[ -L "${source_path}" ]]; then
        fail "Source bundle contains a symlink: ${source_relative_path}"
        source_paths_valid="false"
        continue
      elif [[ -d "${source_path}" ]]; then
        continue
      elif [[ ! -f "${source_path}" ]]; then
        fail "Source bundle contains a special filesystem node: ${source_relative_path}"
        source_paths_valid="false"
        continue
      fi
      [[ "${source_relative_path##*/}" != ".DS_Store" ]] || continue
      if [[ "${exclude_ios_value}" == "on" ]]; then
        case "${source_relative_path}" in
          agents/ios-*.md)
            continue
            ;;
        esac
      fi
      printf '%s\n' "${source_relative_path}" >> "${source_paths_tmp}"
    done < "${source_nodes_tmp}"
    LC_ALL=C sort -u -o "${source_paths_tmp}" "${source_paths_tmp}"
    if [[ "${source_paths_valid}" == "true" ]]; then
      source_only_count="$(LC_ALL=C comm -23 "${source_paths_tmp}" \
        "${manifest_paths_tmp}" | wc -l | tr -d '[:space:]')"
      installed_only_count="$(LC_ALL=C comm -13 "${source_paths_tmp}" \
        "${manifest_paths_tmp}" | wc -l | tr -d '[:space:]')"
      if [[ "${source_only_count}" -ne 0 || "${installed_only_count}" -ne 0 ]]; then
        first_source_only="$(LC_ALL=C comm -23 "${source_paths_tmp}" \
          "${manifest_paths_tmp}" | head -n 1 || true)"
        first_installed_only="$(LC_ALL=C comm -13 "${source_paths_tmp}" \
          "${manifest_paths_tmp}" | head -n 1 || true)"
        fail "Source bundle/installed manifest path sets differ (source-only=${source_only_count}${first_source_only:+ first=${first_source_only}}; installed-only=${installed_only_count}${first_installed_only:+ first=${first_installed_only}})"
        hash_manifest_valid="false"
      else
        pass "Source bundle and installed manifest coverage sets match exactly"
      fi
    fi
    rm -f "${source_paths_tmp}" "${source_nodes_tmp}"
  fi

  rm -f "${manifest_paths_tmp}" "${hash_paths_tmp}"

  hash_check_tool_available="false"
  case "${TRUSTED_SHA256_TOOL##*/}" in
    shasum|sha256sum) hash_check_tool_available="true" ;;
  esac

  if [[ "${hash_manifest_valid}" != "true" ]]; then
    : # Validation already emitted one or more hard failures.
  elif [[ "${hash_check_tool_available}" != "true" ]]; then
    fail "Neither shasum nor sha256sum is available; Definition and verification authority cannot be sealed"
  else
    # Run from CLAUDE_HOME so relative manifest paths resolve correctly. The
    # checker status and complete output are authoritative: parse failures,
    # unreadable files, and incomplete success output all fail closed.
    hash_check_rc=0
    drift_output="$(\run_trusted_sha256_manifest_check \
      "${TRUSTED_SHA256_TOOL}" "${CLAUDE_HOME}" "${HASHES_PATH}" 2>&1)" \
      || hash_check_rc=$?
    drift_lines=0
    hash_ok_lines=0
    hash_unexpected_lines=0
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      case "${line}" in
        *': FAILED'|*': FAILED open or read')
          fail "Drift: ${line}"
          drift_lines=$((drift_lines + 1))
          ;;
        *': OK')
          hash_ok_lines=$((hash_ok_lines + 1))
          ;;
        *)
          info_warn "Checksum checker output: ${line}"
          hash_unexpected_lines=$((hash_unexpected_lines + 1))
          ;;
      esac
    done <<< "${drift_output}"

    if [[ "${hash_check_rc}" -ne 0 && "${drift_lines}" -eq 0 ]]; then
      fail "Checksum verification command failed (exit ${hash_check_rc})"
    elif [[ "${hash_check_rc}" -eq 0 \
      && ( "${hash_unexpected_lines}" -ne 0 \
        || "${hash_ok_lines}" -ne "${hash_manifest_count}" ) ]]; then
      fail "Checksum verification produced incomplete or malformed output (${hash_ok_lines}/${hash_manifest_count} OK rows)"
    elif [[ "${hash_check_rc}" -eq 0 && "${drift_lines}" -eq 0 ]]; then
      pass "No drift detected on installed bundle files"
    fi
  fi
fi

printf '\n'

# ---------------------------------------------------------------------------
# 10. Installed resume-watchdog scheduler integrity
# ---------------------------------------------------------------------------
#
# The required-path and hash checks above cover the bundled templates in
# `~/.claude/launchd/` and `~/.claude/systemd/`, but when the optional
# resume watchdog is enabled the live scheduler artifacts run from
# `~/Library/LaunchAgents/` (macOS) or `~/.config/systemd/user/`
# (Linux). Those installed files are rendered with user-specific
# substitutions at install time; if they drift later, the watchdog can
# silently stop or run with stale PATH/HOME values while verify still
# reports the bundle as healthy. Also catch the inverse mismatch: the
# conf says the feature is not enabled, but a previously-installed live
# scheduler artifact is still present. Linux hosts without launchd/systemd
# can now be audited mechanically too via the managed cron fallback.

printf '10. Resume-watchdog scheduler install\n'
verify_resume_watchdog_scheduler

printf '\n'

# ===========================================================================
# Result
# ===========================================================================

printf '=== Verification complete ===\n'
printf '  Version:       %s\n' "${omc_version}"
printf '  Errors:        %d\n' "${errors}"
# v1.36.0 (item #7): split warnings into informational vs actionable so
# the user can tell at a glance whether the warnings need follow-up. The
# legacy "Warnings: N" line is preserved as a sub-line for backwards
# compatibility with any tooling that grepped it.
printf '  Warnings:      %d  (informational: %d, actionable: %d)\n' \
  "${warnings}" "${info_warnings}" "${actionable_warnings}"
if [[ "${actionable_warnings}" -gt 0 ]] && [[ -f "${ACTIONABLE_LOG}" ]]; then
  printf '  Actionable log: %s\n' "${ACTIONABLE_LOG}"
fi
printf '\n'

if [[ "${errors}" -gt 0 ]]; then
  printf 'Verification FAILED. Re-run the installer and check the errors above.\n' >&2
  exit 1
fi

printf 'oh-my-claude verification passed.\n'
printf '\n'
_restart_guidance="$(TARGET_HOME="${TARGET_HOME}" bash "${SCRIPT_DIR}/tools/install-state-report.sh" --restart-guidance 2>/dev/null || true)"
if [[ -n "${_restart_guidance}" ]]; then
  printf '%s\n' "${_restart_guidance}"
fi
printf '\n'
printf 'Upgrading from a prior release?\n'
printf '  The live hooks in ~/.claude/ do not auto-upgrade. After git pull, re-run bash install.sh\n'
printf '  to sync agents, skills, and memory files. settings.json merges and omc-user/ are preserved;\n'
printf '  unedited memory files are refreshed in place. (v1.36.0+) hand-edited memory files trigger a\n'
printf '  pre-rsync warning so you can migrate edits to %s/omc-user/overrides.md.\n' "${CLAUDE_HOME}"
printf '  Run /omc-config afterwards to review your current settings — see CHANGELOG.md for the new-flag list.\n'
printf '\n'
# Agent-install contract: AGENTS.md Step 4 and the README's AI-assisted
# install prompt both tell agents to quote this footer verbatim after
# verify.sh passes. Keep the wording and spacing in lockstep with
# AGENTS.md so install assistants have a stable, exact handoff block.
cat <<'EOF'
What next?
  /omc-config                             -- inspect/change settings (auto-detects mode)
  /ulw-demo                               -- see quality gates in action (recommended first step)
  /ulw fix the failing test and add regression coverage
                                          -- start real work with full quality enforcement
EOF
