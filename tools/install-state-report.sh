#!/usr/bin/env bash
#
# tools/install-state-report.sh — machine-readable install-state probe.
#
# Consolidates the AI-assisted install/update preflight into one helper:
#   - reads ~/.claude/oh-my-claude.conf metadata
#   - reads ~/.claude/.install-stamp
#   - refreshes origin tags/default-branch refs
#   - reports whether the local install is already current
#
# Primary audience: AI agents following AGENTS.md's Agent Install Protocol.
# Humans can run it too; default output is readable text, `--json` is for
# automation.

set -euo pipefail

TARGET_HOME="${TARGET_HOME:-$HOME}"
CONF_PATH="${TARGET_HOME}/.claude/oh-my-claude.conf"
INSTALL_STAMP="${TARGET_HOME}/.claude/.install-stamp"
JSON_MODE=0
LAST_UPDATE_SUMMARY_MODE=0
RESTART_GUIDANCE_MODE=0
ALREADY_CURRENT_SUMMARY_MODE=0

usage() {
  cat <<'EOF'
Usage: bash tools/install-state-report.sh [--json] [--last-update-summary] [--restart-guidance] [--already-current-summary]

Reports install metadata and currentness for the oh-my-claude harness.

Output fields:
  - install_status: not-installed | installed
  - currentness: not-applicable | already-current | update-available | unknown
  - installed_version, installed_sha, repo_path
  - latest_tag, origin_default_ref, origin_default_sha
  - last_install_at, last_install_epoch
  - last_install.restart_required, kind, managed_changes_total, settings_changed
  - last_install.previous, current, change_summary
  - reason

Modes:
  --json                 Emit the full machine-readable report
  --last-update-summary  Emit the standardized text summary for the last
                         update install (silent when the last install was
                         not an update)
  --restart-guidance     Emit the standardized restart/no-restart guidance
                         for the last install (safe-fallback: restart)
  --already-current-summary
                         Emit the standardized already-current summary
                         (silent unless currentness=already-current)
EOF
}

read_conf_value() {
  local key="${1:-}"
  [[ -n "${key}" ]] || return 0
  [[ -f "${CONF_PATH}" ]] || return 0
  grep -E "^${key}=" "${CONF_PATH}" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/\r$//' || true
}

compact_value() {
  printf '%s' "${1:-}" | tr -d '[:space:]'
}

repo_is_git_checkout() {
  local repo_path="${1:-}"
  [[ -n "${repo_path}" ]] || return 1
  [[ -d "${repo_path}" ]] || return 1
  git -C "${repo_path}" rev-parse --show-toplevel >/dev/null 2>&1
}

file_mtime_epoch() {
  local path="${1:-}"
  [[ -f "${path}" ]] || return 1
  if stat -f '%m' "${path}" >/dev/null 2>&1; then
    stat -f '%m' "${path}" 2>/dev/null
  elif stat -c '%Y' "${path}" >/dev/null 2>&1; then
    stat -c '%Y' "${path}" 2>/dev/null
  else
    return 1
  fi
}

format_epoch() {
  local epoch="${1:-}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  if date -r "${epoch}" '+%Y-%m-%d %H:%M:%S %z' >/dev/null 2>&1; then
    date -r "${epoch}" '+%Y-%m-%d %H:%M:%S %z'
  elif date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S %z' >/dev/null 2>&1; then
    date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S %z'
  else
    return 1
  fi
}

version_gt() {
  local left="${1:-}"
  local right="${2:-}"
  [[ -n "${left}" ]] || return 1
  [[ -n "${right}" ]] || return 1
  local newer=""
  newer="$(printf '%s\n%s\n' "${left}" "${right}" | sort -V 2>/dev/null | tail -n1)"
  [[ "${newer}" == "${left}" ]] && [[ "${left}" != "${right}" ]]
}

latest_semver_tag() {
  local repo_path="${1:-}"
  git -C "${repo_path}" tag --list 'v*' 2>/dev/null \
    | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1 \
    || true
}

detect_origin_default_ref() {
  local repo_path="${1:-}"
  local ref=""

  ref="$(git -C "${repo_path}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "${ref}" ]]; then
    printf '%s' "${ref}"
    return 0
  fi

  for candidate in origin/main origin/master origin/trunk; do
    if git -C "${repo_path}" rev-parse "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

format_install_ref() {
  local version="${1:-}"
  local sha="${2:-}"
  local rendered=""

  if [[ -n "${version}" ]]; then
    rendered="v${version}"
  fi
  if [[ -n "${sha}" ]]; then
    if [[ -n "${rendered}" ]]; then
      rendered+=" @ ${sha:0:12}"
    else
      rendered="${sha:0:12}"
    fi
  fi

  printf '%s' "${rendered}"
}

print_text() {
  printf 'Install status:    %s\n' "${install_status}"
  printf 'Currentness:       %s\n' "${currentness}"
  if [[ -n "${installed_version}" ]]; then
    printf 'Installed version: %s\n' "${installed_version}"
  fi
  if [[ -n "${installed_sha}" ]]; then
    printf 'Installed SHA:     %s\n' "${installed_sha}"
  fi
  if [[ -n "${repo_path}" ]]; then
    printf 'Repo path:         %s\n' "${repo_path}"
  fi
  if [[ -n "${latest_tag}" ]]; then
    printf 'Latest tag:        %s\n' "${latest_tag}"
  fi
  if [[ -n "${origin_default_ref}" ]]; then
    printf 'Origin default:    %s\n' "${origin_default_ref}"
  fi
  if [[ -n "${origin_default_sha}" ]]; then
    printf 'Origin SHA:        %s\n' "${origin_default_sha}"
  fi
  if [[ -n "${last_install_at}" ]]; then
    printf 'Last install:      %s\n' "${last_install_at}"
  fi
  if [[ "${last_install_report_present_json}" == "true" ]]; then
    printf 'Last install kind: %s\n' "${last_install_kind}"
    printf 'Last restart:      %s\n' "${last_install_restart_text}"
    printf 'Managed changes:   %s\n' "${last_install_managed_changes_total_json}"
    printf 'Settings changed:  %s\n' "${last_install_settings_changed_text}"
    if [[ -n "${last_install_previous_ref}" ]]; then
      printf 'Last install from: %s\n' "${last_install_previous_ref}"
    fi
    if [[ -n "${last_install_current_ref}" ]]; then
      printf 'Last install to:   %s\n' "${last_install_current_ref}"
    fi
    if [[ "${last_install_change_summary_available_json}" == "true" ]]; then
      printf 'Last install log:  %s commit(s)' "${last_install_change_summary_commit_count_json}"
      if [[ "${last_install_change_summary_truncated_count_json}" =~ ^[0-9]+$ ]] \
        && [[ "${last_install_change_summary_truncated_count_json}" -gt 0 ]]; then
        printf ' (%s more omitted)' "${last_install_change_summary_truncated_count_json}"
      fi
      printf '\n'
    elif [[ -n "${last_install_change_summary_reason}" ]]; then
      printf 'Last install log:  %s\n' "${last_install_change_summary_reason}"
    fi
  fi
  printf 'Reason:            %s\n' "${reason}"
}

print_json() {
  command -v jq >/dev/null 2>&1 || {
    printf 'install-state-report: jq is required for --json\n' >&2
    exit 1
  }

  jq -n \
    --arg install_status "${install_status}" \
    --arg currentness "${currentness}" \
    --arg reason "${reason}" \
    --arg conf_path "${CONF_PATH}" \
    --arg install_stamp "${INSTALL_STAMP}" \
    --arg installed_version "${installed_version}" \
    --arg installed_sha "${installed_sha}" \
    --arg repo_path "${repo_path}" \
    --arg latest_tag "${latest_tag}" \
    --arg origin_default_ref "${origin_default_ref}" \
    --arg origin_default_sha "${origin_default_sha}" \
    --arg local_repo_version "${local_repo_version}" \
    --arg last_install_at "${last_install_at}" \
    --arg last_install_report_path "${LAST_INSTALL_REPORT_PATH}" \
    --arg last_install_kind "${last_install_kind}" \
    --arg last_install_reason "${last_install_reason}" \
    --arg last_install_previous_version "${last_install_previous_version}" \
    --arg last_install_previous_sha "${last_install_previous_sha}" \
    --arg last_install_current_version "${last_install_current_version}" \
    --arg last_install_current_sha "${last_install_current_sha}" \
    --arg last_install_change_summary_reason "${last_install_change_summary_reason}" \
    --argjson last_install_epoch "${last_install_epoch_json}" \
    --argjson repo_checkout "${repo_checkout_json}" \
    --argjson fetched "${fetched_json}" \
    --argjson last_install_report_present "${last_install_report_present_json}" \
    --argjson last_install_restart_required "${last_install_restart_required_json}" \
    --argjson last_install_managed_changes_total "${last_install_managed_changes_total_json}" \
    --argjson last_install_settings_changed "${last_install_settings_changed_json}" \
    --argjson last_install_change_summary_available "${last_install_change_summary_available_json}" \
    --argjson last_install_change_summary_commit_count "${last_install_change_summary_commit_count_json}" \
    --argjson last_install_change_summary_truncated_count "${last_install_change_summary_truncated_count_json}" \
    --argjson last_install_change_summary_commits "${last_install_change_summary_commits_json}" '
    {
      install_status: $install_status,
      currentness: $currentness,
      reason: $reason,
      conf_path: $conf_path,
      install_stamp: $install_stamp,
      installed_version: (if $installed_version == "" then null else $installed_version end),
      installed_sha: (if $installed_sha == "" then null else $installed_sha end),
      repo_path: (if $repo_path == "" then null else $repo_path end),
      repo_checkout: $repo_checkout,
      fetched: $fetched,
      latest_tag: (if $latest_tag == "" then null else $latest_tag end),
      origin_default_ref: (if $origin_default_ref == "" then null else $origin_default_ref end),
      origin_default_sha: (if $origin_default_sha == "" then null else $origin_default_sha end),
      local_repo_version: (if $local_repo_version == "" then null else $local_repo_version end),
      last_install_at: (if $last_install_at == "" then null else $last_install_at end),
      last_install_epoch: $last_install_epoch,
      last_install: (
        if $last_install_report_present then
          {
            report_path: $last_install_report_path,
            kind: (if $last_install_kind == "" then null else $last_install_kind end),
            restart_required: $last_install_restart_required,
            managed_changes_total: $last_install_managed_changes_total,
            settings_changed: $last_install_settings_changed,
            reason: (if $last_install_reason == "" then null else $last_install_reason end),
            previous: {
              installed_version: (if $last_install_previous_version == "" then null else $last_install_previous_version end),
              installed_sha: (if $last_install_previous_sha == "" then null else $last_install_previous_sha end)
            },
            current: {
              installed_version: (if $last_install_current_version == "" then null else $last_install_current_version end),
              installed_sha: (if $last_install_current_sha == "" then null else $last_install_current_sha end)
            },
            change_summary: {
              available: $last_install_change_summary_available,
              reason: (if $last_install_change_summary_reason == "" then null else $last_install_change_summary_reason end),
              commit_count: $last_install_change_summary_commit_count,
              truncated_count: $last_install_change_summary_truncated_count,
              commits: $last_install_change_summary_commits
            }
          }
        else
          null
        end
      )
    }'
}

print_last_update_summary() {
  local previous_ref="" current_ref="" summary_lines=""

  [[ "${last_install_kind}" == "update" ]] || return 0

  previous_ref="$(format_install_ref "${last_install_previous_version}" "${last_install_previous_sha}")"
  current_ref="$(format_install_ref "${last_install_current_version}" "${last_install_current_sha}")"

  printf '  Update summary:\n'
  [[ -n "${previous_ref}" ]] && printf '    Previous install: %s\n' "${previous_ref}"
  [[ -n "${current_ref}" ]] && printf '    Current install:  %s\n' "${current_ref}"
  if [[ "${last_install_restart_required_json}" == "true" ]]; then
    printf '    Restart needed:  yes\n'
  elif [[ "${last_install_restart_required_json}" == "false" ]]; then
    printf '    Restart needed:  no\n'
  fi
  [[ -n "${last_install_reason}" ]] && printf '    Reason:          %s\n' "${last_install_reason}"

  if [[ "${last_install_change_summary_available_json}" == "true" ]]; then
    printf '    Commits since prior install (%s):\n' "${last_install_change_summary_commit_count_json}"
    summary_lines="$(printf '%s' "${last_install_change_summary_commits_json}" \
      | jq -r '.[]? | "      \(.sha[0:12]) \(.subject)"' 2>/dev/null || true)"
    if [[ -n "${summary_lines}" ]]; then
      printf '%s\n' "${summary_lines}"
    fi
    if [[ "${last_install_change_summary_truncated_count_json}" =~ ^[0-9]+$ ]] \
      && [[ "${last_install_change_summary_truncated_count_json}" -gt 0 ]]; then
      printf '      ... (%s more)\n' "${last_install_change_summary_truncated_count_json}"
    fi
  elif [[ -n "${last_install_change_summary_reason}" ]]; then
    printf '    Commits since prior install: %s\n' "${last_install_change_summary_reason}"
  fi
}

print_restart_guidance() {
  if [[ "${last_install_report_present_json}" == "true" ]] \
    && [[ "${last_install_restart_required_json}" == "false" ]]; then
    printf 'No Claude Code restart is required. The managed bundle files and settings.json already matched what was on disk, so already-running sessions keep the same wiring.\n'
  else
    printf 'Restart Claude Code (or open a new session) before testing. Already-running sessions keep the previous hook wiring, so `/ulw` will silently no-op until you restart.\n'
  fi
}

print_already_current_summary() {
  [[ "${currentness}" == "already-current" ]] || return 0

  printf 'Already current'
  if [[ -n "${installed_version}" ]]; then
    printf ': v%s' "${installed_version}"
  fi
  if [[ -n "${last_install_at}" ]]; then
    printf ' (last install: %s)' "${last_install_at}"
  fi
  printf '\n'
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --last-update-summary)
      LAST_UPDATE_SUMMARY_MODE=1
      shift
      ;;
    --restart-guidance)
      RESTART_GUIDANCE_MODE=1
      shift
      ;;
    --already-current-summary)
      ALREADY_CURRENT_SUMMARY_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'install-state-report: unknown argument: %s\n' "${1}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

install_status="not-installed"
currentness="not-applicable"
reason="No installed_version recorded in ${CONF_PATH}."
installed_version=""
installed_sha=""
repo_path=""
latest_tag=""
origin_default_ref=""
origin_default_sha=""
local_repo_version=""
last_install_at=""
last_install_epoch_json="null"
repo_checkout_json="false"
fetched_json="false"
LAST_INSTALL_REPORT_PATH="${TARGET_HOME}/.claude/quality-pack/state/last-install-report.json"
last_install_report_present_json="false"
last_install_kind=""
last_install_reason=""
last_install_restart_required_json="false"
last_install_managed_changes_total_json="0"
last_install_settings_changed_json="false"
last_install_previous_version=""
last_install_previous_sha=""
last_install_current_version=""
last_install_current_sha=""
last_install_previous_ref=""
last_install_current_ref=""
last_install_change_summary_available_json="false"
last_install_change_summary_reason=""
last_install_change_summary_commit_count_json="0"
last_install_change_summary_truncated_count_json="0"
last_install_change_summary_commits_json='[]'
last_install_restart_text="unknown"
last_install_settings_changed_text="unknown"

installed_version="$(compact_value "$(read_conf_value installed_version)")"
installed_sha="$(compact_value "$(read_conf_value installed_sha)")"
repo_path="$(read_conf_value repo_path)"
repo_path="${repo_path%$'\r'}"

if [[ -n "${installed_version}" ]]; then
  install_status="installed"
  currentness="unknown"
  reason="Install metadata present, but currentness has not been established yet."
fi

if last_install_epoch="$(file_mtime_epoch "${INSTALL_STAMP}" 2>/dev/null || true)"; then
  if [[ "${last_install_epoch}" =~ ^[0-9]+$ ]]; then
    last_install_epoch_json="${last_install_epoch}"
    last_install_at="$(format_epoch "${last_install_epoch}" 2>/dev/null || true)"
  fi
fi

if [[ -f "${LAST_INSTALL_REPORT_PATH}" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e '.' "${LAST_INSTALL_REPORT_PATH}" >/dev/null 2>&1; then
    last_install_report_present_json="true"
    last_install_kind="$(jq -r '.install_kind // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_reason="$(jq -r '.restart_reason // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_restart_required_json="$(jq -r '.restart_required // false' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf 'false')"
    last_install_managed_changes_total_json="$(jq -r '.managed_changes.total // 0' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf '0')"
    last_install_settings_changed_json="$(jq -r '.settings_changed // false' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf 'false')"
    last_install_previous_version="$(jq -r '.previous_install.installed_version // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_previous_sha="$(jq -r '.previous_install.installed_sha // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_current_version="$(jq -r '.current_install.installed_version // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_current_sha="$(jq -r '.current_install.installed_sha // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_change_summary_available_json="$(jq -r '.change_summary.available // false' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf 'false')"
    last_install_change_summary_reason="$(jq -r '.change_summary.reason // empty' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || true)"
    last_install_change_summary_commit_count_json="$(jq -r '.change_summary.commit_count // 0' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf '0')"
    last_install_change_summary_truncated_count_json="$(jq -r '.change_summary.truncated_count // 0' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf '0')"
    last_install_change_summary_commits_json="$(jq -c '.change_summary.commits // []' "${LAST_INSTALL_REPORT_PATH}" 2>/dev/null || printf '[]')"
  fi
fi

last_install_previous_ref="$(format_install_ref "${last_install_previous_version}" "${last_install_previous_sha}")"
last_install_current_ref="$(format_install_ref "${last_install_current_version}" "${last_install_current_sha}")"

if [[ "${LAST_UPDATE_SUMMARY_MODE}" -eq 1 ]]; then
  print_last_update_summary
  exit 0
fi

if [[ "${RESTART_GUIDANCE_MODE}" -eq 1 ]]; then
  print_restart_guidance
  exit 0
fi

case "${last_install_restart_required_json}" in
  true)  last_install_restart_text="required" ;;
  false) last_install_restart_text="not required" ;;
  *)     last_install_restart_text="unknown" ;;
esac

case "${last_install_settings_changed_json}" in
  true)  last_install_settings_changed_text="yes" ;;
  false) last_install_settings_changed_text="no" ;;
  *)     last_install_settings_changed_text="unknown" ;;
esac

if [[ "${install_status}" == "installed" ]]; then
  if [[ -z "${repo_path}" ]]; then
    reason="repo_path is missing from ${CONF_PATH}; remote currentness is unavailable."
  elif [[ ! -d "${repo_path}" ]]; then
    reason="repo_path (${repo_path}) does not exist on disk."
  elif ! repo_is_git_checkout "${repo_path}"; then
    reason="repo_path (${repo_path}) is not a git checkout; remote currentness is unavailable."
  else
    repo_checkout_json="true"
    local_repo_version="$(head -1 "${repo_path}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

    if git -C "${repo_path}" fetch --quiet --tags origin >/dev/null 2>&1; then
      fetched_json="true"
      latest_tag="$(latest_semver_tag "${repo_path}")"
      origin_default_ref="$(detect_origin_default_ref "${repo_path}" || true)"
      if [[ -n "${origin_default_ref}" ]]; then
        origin_default_sha="$(git -C "${repo_path}" rev-parse "${origin_default_ref}" 2>/dev/null || true)"
      fi

      if [[ -n "${latest_tag}" ]] && version_gt "${latest_tag}" "${installed_version}"; then
        currentness="update-available"
        reason="latest tag v${latest_tag} is newer than installed_version=${installed_version}."
      elif [[ "${latest_tag}" == "${installed_version}" ]]; then
        if [[ -z "${installed_sha}" ]]; then
          currentness="already-current"
          reason="installed_version matches latest tag v${latest_tag}; installed_sha is absent so version-only fallback applies."
        elif [[ -z "${origin_default_ref}" || -z "${origin_default_sha}" ]]; then
          reason="latest tag matches installed_version, but origin's default branch ref could not be resolved."
        elif [[ "${origin_default_sha}" == "${installed_sha}" ]]; then
          currentness="already-current"
          reason="installed_version matches latest tag v${latest_tag} and installed_sha matches ${origin_default_ref}."
        else
          currentness="update-available"
          reason="${origin_default_ref} is ahead of installed_sha even though installed_version already matches latest tag v${latest_tag}."
        fi
      elif [[ -n "${latest_tag}" ]]; then
        reason="installed_version=${installed_version} differs from latest tag v${latest_tag}, but the latest tag is not newer."
      else
        reason="No semver release tag could be determined from origin after fetch."
      fi
    else
      reason="git fetch --tags origin failed for ${repo_path}; remote currentness is unavailable."
    fi
  fi
fi

if [[ "${ALREADY_CURRENT_SUMMARY_MODE}" -eq 1 ]]; then
  print_already_current_summary
  exit 0
fi

if [[ "${JSON_MODE}" -eq 1 ]]; then
  print_json
else
  print_text
fi
