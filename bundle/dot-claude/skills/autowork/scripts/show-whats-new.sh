#!/usr/bin/env bash
# show-whats-new.sh — render CHANGELOG delta between installed and source.
#
# v1.36.x W5 F-021 (growth-lens): surface release-note deltas in
# Claude Code instead of forcing the user to grep CHANGELOG.md by
# hand or rely on the statusline `↑v<version>` arrow alone. Reads
# `installed_version` from ~/.claude/oh-my-claude.conf, walks
# `${repo_path}/CHANGELOG.md`, and prints every `## [X.Y.Z]` section
# strictly newer than the installed version (plus `[Unreleased]` if
# present).
#
# Local-only — no network. Falls through cleanly with a status
# message if `repo_path` is unset, the CHANGELOG is missing, or
# the user is already at HEAD.

set -euo pipefail

CONF="${HOME}/.claude/oh-my-claude.conf"

read_conf_value() {
  local key="$1"
  [[ -f "${CONF}" ]] || return 0
  grep -E "^${key}=" "${CONF}" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' || true
}

installed_version="$(read_conf_value installed_version)"
repo_path="$(read_conf_value repo_path)"

if [[ -z "${installed_version}" ]]; then
  printf 'No installed_version recorded in %s — was install.sh ever run?\n' "${CONF}"
  exit 0
fi

if [[ -z "${repo_path}" ]]; then
  printf 'No repo_path recorded in %s. /whats-new needs the source repo path\n' "${CONF}"
  printf 'to read CHANGELOG.md. Run `bash <repo>/install.sh` to populate it.\n'
  exit 0
fi

changelog="${repo_path}/CHANGELOG.md"
if [[ ! -f "${changelog}" ]]; then
  printf 'CHANGELOG.md not found at %s. The source repo may have moved or\n' "${changelog}"
  printf 'the repo_path is stale. Re-run install.sh from the current source.\n'
  exit 0
fi

source_version="$(head -1 "${repo_path}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"

# Compose the report. We walk CHANGELOG.md line by line, collecting
# sections under `## [X.Y.Z]` headings strictly newer than the
# installed version. The `[Unreleased]` section is surfaced separately
# at the top — it represents post-release work in the source tree
# that hasn't been promoted yet (so `git pull` brought it in, but no
# new `## [X.Y.Z]` heading has been cut for it yet).

# Use sort -V to compare versions; fall back to string equality.
# A line is "newer than installed" when:
#   sort -V <(echo installed) <(echo candidate) | tail -n1 == candidate
#   AND candidate != installed.
is_version_newer() {
  local cand="$1"
  local inst="${installed_version}"
  [[ "${cand}" == "${inst}" ]] && return 1
  local newer
  newer="$(printf '%s\n%s\n' "${inst}" "${cand}" | sort -V 2>/dev/null | tail -n1)"
  [[ "${newer}" == "${cand}" ]]
}

# Header
printf '# /whats-new — changelog delta\n\n'
if [[ -n "${source_version}" ]] && [[ "${source_version}" != "${installed_version}" ]]; then
  printf '_Installed: **v%s** · Source HEAD: **v%s**_\n\n' "${installed_version}" "${source_version}"
else
  printf '_Installed: **v%s**_\n\n' "${installed_version}"
fi

# Walk the changelog. State machine:
#   in_section=1 means we are currently capturing lines (section is newer).
#   in_section=0 means skip until next ## heading.
in_section=0
collected=""
collected_count=0
unreleased_section=""

while IFS= read -r line; do
  # Match `## [Unreleased]` heading.
  if [[ "${line}" =~ ^##[[:space:]]+\[Unreleased\] ]]; then
    in_section=2  # special marker
    continue
  fi

  # Match `## [X.Y.Z] - YYYY-MM-DD` heading.
  if [[ "${line}" =~ ^##[[:space:]]+\[([0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
    # Extract version. BSD bash 3.2 doesn't support BASH_REMATCH well
    # in all forms; safer to parse via sed.
    cand_version="$(printf '%s' "${line}" | sed -E 's/^##[[:space:]]+\[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')"
    if is_version_newer "${cand_version}"; then
      in_section=1
      collected_count=$((collected_count + 1))
      collected+="${line}"$'\n'
    else
      in_section=0
    fi
    continue
  fi

  if [[ "${in_section}" -eq 1 ]]; then
    collected+="${line}"$'\n'
  elif [[ "${in_section}" -eq 2 ]]; then
    unreleased_section+="${line}"$'\n'
  fi
done < "${changelog}"

if [[ "${collected_count}" -eq 0 ]] && [[ -z "${unreleased_section//[[:space:]]/}" ]]; then
  printf '_You are at HEAD — no newer entries in CHANGELOG.md._\n\n'
  printf 'Run `bash %s/install.sh` after a `git pull` to refresh hooks if the source repo advances.\n' "${repo_path}"
  exit 0
fi

if [[ -n "${unreleased_section//[[:space:]]/}" ]]; then
  printf '## [Unreleased] — post-release work in source tree\n\n'
  # Cap at 200 lines so a sprawling [Unreleased] block doesn't fill the
  # whole context. The user can read the rest of CHANGELOG.md directly.
  printf '%s' "${unreleased_section}" | head -200
  printf '\n_To install Unreleased: `git -C %s pull && bash install.sh`_\n\n' "${repo_path}"
fi

if [[ -n "${collected}" ]]; then
  printf '%s' "${collected}"
fi

# Footer
printf '\n---\n_Read CHANGELOG.md directly at %s for the full history._\n' "${changelog}"
