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
  local key="${1:-}" line="" value="" result=""
  [[ -n "${key}" ]] || return 0
  [[ -f "${CONF_PATH}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "${key}="* ]] || continue
    value="${line#*=}"
    # Config syntax owns edge whitespace only. Preserve literal interior
    # spaces, apostrophes, backslashes, and additional '=' bytes in paths.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    result="${value}"
  done < "${CONF_PATH}"
  printf '%s' "${result}"
}

terminal_safe_text() {
  local value="${1:-}"
  # Text modes may be emitted directly to an interactive terminal. Preserve
  # ordinary spacing while neutralizing control bytes from config/report data.
  # JSON mode remains lossless and relies on jq's standard escaping.
  value="${value//[[:cntrl:]]/?}"
  printf '%s' "${value}"
}

file_identity_size_tuple() {
  local path="${1:-}" value=""
  [[ -n "${path}" ]] || return 1
  value="$(stat -L -f '%d:%i:%z' "${path}" 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
    printf '%s' "${value}"
    return 0
  fi
  value="$(stat -L -c '%d:%i:%s' "${path}" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

read_valid_last_install_report() {
  local report_path="${1:-}"
  local expected_install_stamp_epoch="${2:-}"
  local report_before="" report_open_before="" report_open_after=""
  local report_path_after="" report_size="" report_snapshot_path=""
  local report_snapshot_tuple="" report_snapshot_open_tuple=""
  local report_snapshot_raw_open_tuple=""
  local report_snapshot_size="" report_jq_rc=0
  local LC_ALL=C
  [[ -f "${report_path}" && ! -L "${report_path}" ]] || return 1
  [[ "${expected_install_stamp_epoch}" =~ ^[0-9]{1,15}$ ]] || return 1
  [[ "${expected_install_stamp_epoch}" == "0" \
      || "${expected_install_stamp_epoch}" != 0* ]] || return 1
  report_before="$(file_identity_size_tuple "${report_path}")" || return 1
  report_size="${report_before##*:}"
  [[ "${report_size}" =~ ^[0-9]{1,7}$ ]] \
    && [[ "${report_size}" -le 1048576 ]] || return 1

  # Bind the check and read to one open descriptor. A pathname can be replaced
  # after lstat/stat but before a parser opens it; comparing the descriptor's
  # identity on both sides of a bounded read prevents that substituted inode
  # from inheriting the checked file's 1 MiB/restart authority. A private
  # byte-preserving snapshot is capped one byte past the ceiling and is the
  # only data jq sees; do not route JSON through a Bash variable, because Bash
  # strips raw NUL bytes and could normalize an invalid document into authority.
  if ! exec 9<"${report_path}"; then
    return 1
  fi
  report_open_before="$(file_identity_size_tuple /dev/fd/9 2>/dev/null || true)"
  if [[ -z "${report_open_before}" \
      || "${report_open_before}" != "${report_before}" ]]; then
    exec 9<&-
    return 1
  fi
  report_snapshot_path="$(mktemp \
    "${TMPDIR:-/tmp}/omc-last-install-report.XXXXXX")" || {
    exec 9<&-
    return 1
  }
  if ! chmod 600 "${report_snapshot_path}" \
      || ! head -c 1048577 <&9 >"${report_snapshot_path}"; then
    exec 9<&-
    rm -f -- "${report_snapshot_path}" 2>/dev/null || true
    return 1
  fi
  report_open_after="$(file_identity_size_tuple /dev/fd/9 2>/dev/null || true)"
  report_path_after="$(file_identity_size_tuple "${report_path}" \
    2>/dev/null || true)"
  exec 9<&-
  report_snapshot_tuple="$(file_identity_size_tuple \
    "${report_snapshot_path}" 2>/dev/null || true)"
  report_snapshot_size="${report_snapshot_tuple##*:}"
  if [[ "${report_open_after}" != "${report_before}" \
      || "${report_path_after}" != "${report_before}" \
      || ! "${report_snapshot_size}" =~ ^[0-9]{1,7}$ \
      || "${report_snapshot_size}" -gt 1048576 ]]; then
    rm -f -- "${report_snapshot_path}" 2>/dev/null || true
    return 1
  fi
  if ! exec 8<"${report_snapshot_path}" \
      || ! exec 7<"${report_snapshot_path}"; then
    exec 8<&- 2>/dev/null || true
    exec 7<&- 2>/dev/null || true
    rm -f -- "${report_snapshot_path}" 2>/dev/null || true
    return 1
  fi
  report_snapshot_open_tuple="$(file_identity_size_tuple /dev/fd/8 \
    2>/dev/null || true)"
  report_snapshot_raw_open_tuple="$(file_identity_size_tuple /dev/fd/7 \
    2>/dev/null || true)"
  if [[ -z "${report_snapshot_tuple}" \
      || "${report_snapshot_open_tuple}" != "${report_snapshot_tuple}" \
      || "${report_snapshot_raw_open_tuple}" != "${report_snapshot_tuple}" ]] \
      || ! rm -f -- "${report_snapshot_path}"; then
    exec 8<&-
    exec 7<&-
    rm -f -- "${report_snapshot_path}" 2>/dev/null || true
    return 1
  fi

  # Emit the validated captured generation as one compact document. Every
  # caller field is subsequently projected from these bytes, so later atomic
  # replacements cannot mix report generations or suppress restart guidance.
  jq -cse --rawfile captured_report_bytes /dev/fd/7 \
    --argjson expected_install_stamp_epoch \
    "${expected_install_stamp_epoch}" '
    # jq accepts a literal NUL byte as numeric zero outside a JSON string and
    # decodes both literal and escaped NULs inside strings. Reject the captured
    # bytes before granting the parsed document any authority; then reject
    # decoded shell-framing bytes recursively before any caller uses jq -r.
    def shell_projectable_string:
      type == "string"
      and (contains("\u0000") | not)
      and (contains("\r") | not)
      and (contains("\n") | not);
    def all_strings_shell_projectable:
      all(..;
        if type == "string" then shell_projectable_string
        elif type == "object" then
          all(keys[]; shell_projectable_string)
        else true end);
    def opt_string: . == null or shell_projectable_string;
    # Current installers emit strict X.Y.Z. Preserve the documented legacy
    # pre-release spelling and the historical VERSION fallback `unknown`, but
    # keep every component bounded and exclude shell/path punctuation.
    def install_version:
      type == "string"
      and (
        . == "unknown"
        or test("^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}(-[A-Za-z0-9.]{1,64})?$")
      );
    def opt_install_version: . == null or install_version;
    # Older conf files legitimately recorded abbreviated git object IDs.
    def install_sha:
      type == "string" and test("^[0-9A-Fa-f]{7,40}$");
    def opt_install_sha: . == null or install_sha;
    def commit_sha:
      type == "string" and test("^[0-9A-Fa-f]{40}$");
    # Keep report numbers inside the jq exact-integer range and every later
    # shell arithmetic boundary. A syntactically numeric but oversized report
    # must not become restart or summary authority.
    def nonnegative_integer:
      type == "number" and isfinite and . >= 0
      and . <= 999999999999999 and floor == .;
    def valid:
      type == "object"
      and ($captured_report_bytes | contains("\u0000") | not)
      and all_strings_shell_projectable
      and .schema_version == 1
      and (.install_kind | (
        . == "fresh-install" or . == "update"
        or . == "reinstall" or . == "reinstall-noop"))
      and (.restart_required | type == "boolean")
      and (.restart_reason | opt_string)
      and (.managed_changes | type == "object")
      and (.managed_changes.total | nonnegative_integer)
      and (.settings_changed | type == "boolean")
      and (.install_stamp_epoch | nonnegative_integer)
      and (.install_stamp_epoch == $expected_install_stamp_epoch)
      and (.previous_install | type == "object")
      and (.previous_install.installed_version | opt_install_version)
      and (.previous_install.installed_sha | opt_install_sha)
      and (.current_install | type == "object")
      and (.current_install.installed_version | install_version)
      and (.current_install.installed_sha | opt_install_sha)
      and (.change_summary | type == "object")
      and (.change_summary.available | type == "boolean")
      and (.change_summary.reason | opt_string)
      and (.change_summary.commit_count | nonnegative_integer)
      and (.change_summary.truncated_count | nonnegative_integer)
      and (.change_summary.commits | type == "array")
      and (.change_summary.commits | length <= 12)
      and all(.change_summary.commits[];
        type == "object"
        and (.sha | commit_sha)
        and (.subject | shell_projectable_string));
    if length == 1 and (.[0] | valid) then .[0]
    else error("invalid last-install report authority") end
  ' <&8 2>/dev/null || report_jq_rc=$?
  exec 8<&-
  exec 7<&-
  return "${report_jq_rc}"
}

repo_is_git_checkout() {
  local repo_path="${1:-}"
  [[ -n "${repo_path}" ]] || return 1
  [[ -d "${repo_path}" ]] || return 1
  git -C "${repo_path}" rev-parse --show-toplevel >/dev/null 2>&1
}

file_mtime_epoch() {
  local path="${1:-}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
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
  local left="${1:-}" right="${2:-}" index=0 left_part=""
  local right_part="" LC_ALL=C
  local -a left_parts=() right_parts=()
  [[ "${left}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
      && "${right}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a left_parts <<< "${left}"
  IFS='.' read -r -a right_parts <<< "${right}"
  for index in 0 1 2; do
    left_part="${left_parts[index]}"
    right_part="${right_parts[index]}"
    while [[ "${#left_part}" -gt 1 && "${left_part}" == 0* ]]; do
      left_part="${left_part#0}"
    done
    while [[ "${#right_part}" -gt 1 && "${right_part}" == 0* ]]; do
      right_part="${right_part#0}"
    done
    if [[ "${#left_part}" -gt "${#right_part}" ]]; then
      return 0
    elif [[ "${#left_part}" -lt "${#right_part}" ]]; then
      return 1
    elif [[ "${left_part}" > "${right_part}" ]]; then
      return 0
    elif [[ "${left_part}" < "${right_part}" ]]; then
      return 1
    fi
  done
  return 1
}

latest_origin_semver_tag() {
  local repo_path="${1:-}" origin_default_sha="${2:-}"
  local remote_tags="" object_sha="" tag_ref="" tag_commit=""
  local tag="" version="" latest=""
  [[ -n "${repo_path}" && "${origin_default_sha}" =~ ^[0-9A-Fa-f]{40}$ ]] \
    || return 1

  # Local tags are not remote-release authority: they may be unpublished,
  # left behind after a remote deletion, or point outside the default branch.
  # Start from the refs origin currently advertises, then admit only tag
  # targets reachable from the freshly-fetched default-branch tip.
  remote_tags="$(git -C "${repo_path}" ls-remote --tags --refs origin \
    'refs/tags/v*' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r object_sha tag_ref || [[ -n "${object_sha}${tag_ref}" ]]; do
    [[ "${object_sha}" =~ ^[0-9A-Fa-f]{40}$ ]] || continue
    [[ "${tag_ref}" == refs/tags/v* ]] || continue
    tag="${tag_ref#refs/tags/}"
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    tag_commit="$(git -C "${repo_path}" rev-parse --verify \
      "${object_sha}^{commit}" 2>/dev/null || true)"
    [[ "${tag_commit}" =~ ^[0-9A-Fa-f]{40}$ ]] || continue
    git -C "${repo_path}" merge-base --is-ancestor \
      "${tag_commit}" "${origin_default_sha}" >/dev/null 2>&1 || continue
    version="${tag#v}"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z "${latest}" ]] || version_gt "${version}" "${latest}"; then
      latest="${version}"
    fi
  done <<< "${remote_tags}"
  printf '%s' "${latest}"
}

detect_origin_default_head() {
  local repo_path="${1:-}"
  local advertised="" left="" right="" extra=""
  local head_ref="" head_sha="" branch="" ref_rows=0 sha_rows=0
  advertised="$(git -C "${repo_path}" ls-remote --symref origin HEAD \
    2>/dev/null)" || return 1
  [[ -n "${advertised}" && "${#advertised}" -le 8192 ]] || return 1
  while IFS=$'\t' read -r left right extra \
      || [[ -n "${left}${right}${extra}" ]]; do
    [[ -z "${extra}" && "${right}" == "HEAD" ]] || return 1
    if [[ "${left}" == "ref: "* ]]; then
      head_ref="${left#ref: }"
      ref_rows=$((ref_rows + 1))
    elif [[ "${left}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      head_sha="${left}"
      sha_rows=$((sha_rows + 1))
    else
      return 1
    fi
  done <<< "${advertised}"
  [[ "${ref_rows}" -eq 1 && "${sha_rows}" -eq 1 \
      && "${head_ref}" == refs/heads/* \
      && "${head_sha}" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
  git -C "${repo_path}" check-ref-format "${head_ref}" >/dev/null 2>&1 \
    || return 1
  branch="${head_ref#refs/heads/}"
  [[ -n "${branch}" && "${branch}" != "${head_ref}" ]] || return 1
  printf 'origin/%s\t%s\t%s' "${branch}" "${head_sha}" "${head_ref}"
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
    printf 'Installed version: %s\n' \
      "$(terminal_safe_text "${installed_version}")"
  fi
  if [[ -n "${installed_sha}" ]]; then
    printf 'Installed SHA:     %s\n' \
      "$(terminal_safe_text "${installed_sha}")"
  fi
  if [[ -n "${repo_path}" ]]; then
    printf 'Repo path:         %s\n' "$(terminal_safe_text "${repo_path}")"
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
    printf 'Last install kind: %s\n' \
      "$(terminal_safe_text "${last_install_kind}")"
    printf 'Last restart:      %s\n' "${last_install_restart_text}"
    printf 'Managed changes:   %s\n' \
      "$(terminal_safe_text "${last_install_managed_changes_total_json}")"
    printf 'Settings changed:  %s\n' "${last_install_settings_changed_text}"
    if [[ -n "${last_install_previous_ref}" ]]; then
      printf 'Last install from: %s\n' \
        "$(terminal_safe_text "${last_install_previous_ref}")"
    fi
    if [[ -n "${last_install_current_ref}" ]]; then
      printf 'Last install to:   %s\n' \
        "$(terminal_safe_text "${last_install_current_ref}")"
    fi
    if [[ "${last_install_change_summary_available_json}" == "true" ]]; then
      printf 'Last install log:  %s commit(s)' \
        "$(terminal_safe_text \
          "${last_install_change_summary_commit_count_json}")"
      if [[ "${last_install_change_summary_truncated_count_json}" =~ ^[0-9]+$ ]] \
        && [[ "${last_install_change_summary_truncated_count_json}" -gt 0 ]]; then
        printf ' (%s more omitted)' "${last_install_change_summary_truncated_count_json}"
      fi
      printf '\n'
    elif [[ -n "${last_install_change_summary_reason}" ]]; then
      printf 'Last install log:  %s\n' \
        "$(terminal_safe_text "${last_install_change_summary_reason}")"
    fi
  fi
  printf 'Reason:            %s\n' "$(terminal_safe_text "${reason}")"
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
    --argjson last_install_report_stamp_epoch "${last_install_report_stamp_epoch_json}" \
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
            install_stamp_epoch: $last_install_report_stamp_epoch,
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
  local previous_ref="" current_ref="" commit_json=""
  local commit_sha="" commit_subject=""

  [[ "${last_install_kind}" == "update" ]] || return 0

  previous_ref="$(format_install_ref "${last_install_previous_version}" "${last_install_previous_sha}")"
  current_ref="$(format_install_ref "${last_install_current_version}" "${last_install_current_sha}")"

  printf '  Update summary:\n'
  [[ -n "${previous_ref}" ]] && printf '    Previous install: %s\n' \
    "$(terminal_safe_text "${previous_ref}")"
  [[ -n "${current_ref}" ]] && printf '    Current install:  %s\n' \
    "$(terminal_safe_text "${current_ref}")"
  if [[ "${last_install_restart_required_json}" == "true" ]]; then
    printf '    Restart needed:  yes\n'
  elif [[ "${last_install_restart_required_json}" == "false" ]]; then
    printf '    Restart needed:  no\n'
  fi
  [[ -n "${last_install_reason}" ]] && printf '    Reason:          %s\n' \
    "$(terminal_safe_text "${last_install_reason}")"

  if [[ "${last_install_change_summary_available_json}" == "true" ]]; then
    printf '    Commits since prior install (%s):\n' \
      "$(terminal_safe_text \
        "${last_install_change_summary_commit_count_json}")"
    # Keep row delimiters structural. Sanitizing the fully-rendered block
    # would turn its own LFs into '?' and collapse every multi-commit update
    # onto one line. Parse one compact object per row, then neutralize control
    # bytes inside each untrusted field independently.
    while IFS= read -r commit_json || [[ -n "${commit_json}" ]]; do
      [[ -n "${commit_json}" ]] || continue
      commit_sha="$(printf '%s' "${commit_json}" \
        | jq -r '.sha[0:12] // ""' 2>/dev/null || true)"
      commit_subject="$(printf '%s' "${commit_json}" \
        | jq -r '.subject // ""' 2>/dev/null || true)"
      printf '      %s %s\n' \
        "$(terminal_safe_text "${commit_sha}")" \
        "$(terminal_safe_text "${commit_subject}")"
    done < <(printf '%s' "${last_install_change_summary_commits_json}" \
      | jq -c '.[]?' 2>/dev/null || true)
    if [[ "${last_install_change_summary_truncated_count_json}" =~ ^[0-9]+$ ]] \
      && [[ "${last_install_change_summary_truncated_count_json}" -gt 0 ]]; then
      printf '      ... (%s more)\n' "${last_install_change_summary_truncated_count_json}"
    fi
  elif [[ -n "${last_install_change_summary_reason}" ]]; then
    printf '    Commits since prior install: %s\n' \
      "$(terminal_safe_text "${last_install_change_summary_reason}")"
  fi
}

print_restart_guidance() {
  if [[ "${last_install_report_present_json}" == "true" ]] \
    && [[ "${last_install_restart_required_json}" == "false" ]]; then
    printf 'No Claude Code restart is required. The managed bundle files and settings.json already matched what was on disk, so already-running sessions keep the same wiring.\n'
  else
    # The backticks are literal Markdown command styling in user guidance.
    # shellcheck disable=SC2016
    printf 'Restart Claude Code (or open a new session) before testing. Already-running sessions keep the previous hook wiring, so `/ulw` will silently no-op until you restart.\n'
  fi
}

print_already_current_summary() {
  [[ "${currentness}" == "already-current" ]] || return 0

  printf 'Already current'
  if [[ -n "${installed_version}" ]]; then
    printf ': v%s' "$(terminal_safe_text "${installed_version}")"
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
origin_default_remote_ref=""
origin_default_advertised_sha=""
origin_default_head_tuple=""
local_repo_version=""
last_install_at=""
last_install_epoch_json="null"
repo_checkout_json="false"
fetched_json="false"
LAST_INSTALL_REPORT_PATH="${TARGET_HOME}/.claude/quality-pack/state/last-install-report.json"
last_install_report_present_json="false"
last_install_report_json=""
last_install_report_stamp_epoch_json="null"
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

installed_version="$(read_conf_value installed_version)"
installed_sha="$(read_conf_value installed_sha)"
repo_path="$(read_conf_value repo_path)"

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
  if [[ "${last_install_epoch_json}" != "null" ]] \
      && last_install_report_json="$(read_valid_last_install_report \
        "${LAST_INSTALL_REPORT_PATH}" "${last_install_epoch_json}")"; then
    last_install_report_present_json="true"
    last_install_report_stamp_epoch_json="$(jq -r '.install_stamp_epoch' \
      <<<"${last_install_report_json}" 2>/dev/null || printf 'null')"
    last_install_kind="$(jq -r '.install_kind // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_reason="$(jq -r '.restart_reason // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_restart_required_json="$(jq -r '.restart_required' \
      <<<"${last_install_report_json}" 2>/dev/null || printf 'true')"
    last_install_managed_changes_total_json="$(jq -r '.managed_changes.total' \
      <<<"${last_install_report_json}" 2>/dev/null || printf '0')"
    last_install_settings_changed_json="$(jq -r '.settings_changed' \
      <<<"${last_install_report_json}" 2>/dev/null || printf 'false')"
    last_install_previous_version="$(jq -r '.previous_install.installed_version // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_previous_sha="$(jq -r '.previous_install.installed_sha // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_current_version="$(jq -r '.current_install.installed_version // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_current_sha="$(jq -r '.current_install.installed_sha // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_change_summary_available_json="$(jq -r '.change_summary.available' \
      <<<"${last_install_report_json}" 2>/dev/null || printf 'false')"
    last_install_change_summary_reason="$(jq -r '.change_summary.reason // empty' \
      <<<"${last_install_report_json}" 2>/dev/null || true)"
    last_install_change_summary_commit_count_json="$(jq -r '.change_summary.commit_count' \
      <<<"${last_install_report_json}" 2>/dev/null || printf '0')"
    last_install_change_summary_truncated_count_json="$(jq -r '.change_summary.truncated_count' \
      <<<"${last_install_report_json}" 2>/dev/null || printf '0')"
    last_install_change_summary_commits_json="$(jq -c '.change_summary.commits' \
      <<<"${last_install_report_json}" 2>/dev/null || printf '[]')"
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

    origin_default_head_tuple="$(detect_origin_default_head \
      "${repo_path}" 2>/dev/null || true)"
    if [[ -n "${origin_default_head_tuple}" ]]; then
      IFS=$'\t' read -r origin_default_ref \
        origin_default_advertised_sha origin_default_remote_ref \
        <<< "${origin_default_head_tuple}"
    fi

    # Fetch the branch origin advertises NOW, not the clone's cached
    # refs/remotes/origin/HEAD symref. The latter is not refreshed by an
    # ordinary fetch and can keep pointing at a former default branch.
    if [[ -n "${origin_default_ref}" \
        && -n "${origin_default_remote_ref}" \
        && "${origin_default_advertised_sha}" =~ ^[0-9A-Fa-f]{40}$ ]] \
        && git -C "${repo_path}" fetch --quiet --tags origin \
          "+${origin_default_remote_ref}:refs/remotes/${origin_default_ref}" \
          >/dev/null 2>&1; then
      fetched_json="true"
      origin_default_sha="$(git -C "${repo_path}" rev-parse --verify \
        "${origin_default_ref}^{commit}" 2>/dev/null || true)"
      if [[ "${origin_default_sha}" != \
          "${origin_default_advertised_sha}" ]]; then
        origin_default_sha=""
      fi
      if [[ -n "${origin_default_sha}" ]]; then
        latest_tag="$(latest_origin_semver_tag \
          "${repo_path}" "${origin_default_sha}" || true)"
      fi

      # A recorded source commit is the authoritative currentness coordinate.
      # VERSION/tag comparison is only the fallback for tarball/archive installs
      # that have no installed_sha: a locally-ahead or divergent installed
      # commit must not be overwritten by a superficially newer tag verdict.
      if [[ -n "${installed_sha}" ]]; then
        if [[ ! "${installed_sha}" =~ ^[0-9A-Fa-f]{7,40}$ ]]; then
          reason="installed_sha is malformed; commit-level currentness is unavailable."
        elif [[ -z "${origin_default_ref}" \
            || -z "${origin_default_sha}" ]]; then
          reason="origin's default branch ref could not be resolved."
        else
          resolved_installed_sha="$(git -C "${repo_path}" rev-parse \
            --verify "${installed_sha}^{commit}" 2>/dev/null || true)"
          if [[ ! "${resolved_installed_sha}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
            reason="installed_sha is not available in the local checkout."
          elif [[ "${origin_default_sha}" \
              == "${resolved_installed_sha}" ]]; then
            currentness="already-current"
            reason="installed_sha matches ${origin_default_ref}; no remote update is pending."
          elif git -C "${repo_path}" merge-base --is-ancestor \
              "${resolved_installed_sha}" "${origin_default_sha}" \
              >/dev/null 2>&1; then
            currentness="update-available"
            reason="${origin_default_ref} is ahead of installed_sha."
          elif git -C "${repo_path}" merge-base --is-ancestor \
              "${origin_default_sha}" "${resolved_installed_sha}" \
              >/dev/null 2>&1; then
            currentness="already-current"
            reason="installed_sha is ahead of ${origin_default_ref}; no remote update is pending."
          else
            reason="installed_sha and ${origin_default_ref} have diverged; currentness requires manual reconciliation."
          fi
        fi
      elif [[ -n "${latest_tag}" ]] \
          && version_gt "${latest_tag}" "${installed_version}"; then
        currentness="update-available"
        reason="latest tag v${latest_tag} is newer than installed_version=${installed_version}; installed_sha is absent so version-only fallback applies."
      elif [[ "${latest_tag}" == "${installed_version}" \
          && -n "${latest_tag}" ]]; then
        currentness="already-current"
        reason="installed_version matches latest tag v${latest_tag}; installed_sha is absent so version-only fallback applies."
      elif [[ -n "${latest_tag}" ]]; then
        reason="installed_version=${installed_version} differs from latest tag v${latest_tag}, and installed_sha is absent; commit-level currentness is unavailable."
      else
        reason="No origin-advertised semver release tag reachable from origin's default branch could be determined after fetch."
      fi
    elif [[ -z "${origin_default_head_tuple}" ]]; then
      reason="origin's live default-branch HEAD could not be resolved; remote currentness is unavailable."
    else
      reason="git fetch of origin's live default branch and tags failed for ${repo_path}; remote currentness is unavailable."
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
