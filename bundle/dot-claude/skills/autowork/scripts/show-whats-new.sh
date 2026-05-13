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

# Walk the changelog with awk — one pass, single subprocess, no bash
# string concatenation in a loop.
#
# Prior implementation (replaced as a Serendipity catch in the v1.40.x
# harness-improvement wave): bash `read -r` line-by-line with `+=` to
# accumulate `collected` and `unreleased_section`. On CHANGELOG.md
# files past ~2K lines, bash string append in a loop is O(n²) — the
# 3000+ line current file pushed wall time past the test-w5-discovery
# F-021 timeout (single-run wall time observed at >15 minutes locally
# under bash 3.2). The awk rewrite is single-pass linear; same file
# completes in well under a second.
#
# First-draft of the rewrite tried a two-phase pipeline (awk emits
# NUL-separated sections, bash filters by is_version_newer). That
# inherited the same O(n²) cost because bash's regex-on-large-string
# and `+=` on big bodies still scaled badly. Final shape: awk does
# the filtering inline via a precomputed "newer-than-installed"
# version set passed in with -v, and emits the kept sections
# directly to stdout. Bash only handles the top/bottom framing.

# Compute the set of CHANGELOG versions strictly newer than installed.
# Strategy: grep all version headings, sort -V them together with the
# installed version, then take every line AFTER the installed line.
# `sort -V` puts versions in strict numeric order; everything past the
# installed-line marker is "newer than installed."
newer_versions="$( {
    grep -oE '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\]' "${changelog}" \
      | sed -E 's/^##[[:space:]]+\[([0-9]+\.[0-9]+\.[0-9]+)\]$/\1/'
    printf '%s\n' "${installed_version}__OMC_INSTALLED_MARKER__"
  } | sort -V \
    | awk '
      /__OMC_INSTALLED_MARKER__$/ { take = 1; next }
      take { print }
    ' \
    | awk -v inst="${installed_version}" '$0 != inst { print }')"

# Build an OR-regex matching any newer-version heading. Empty when
# installed is at or above the highest CHANGELOG version. Wrap the
# pipeline in `|| true` because `grep -v '^$'` on empty input exits
# non-zero (no matches), which under `set -e` would kill the script
# before the [Unreleased] section gets a chance to emit.
newer_re="$( { printf '%s\n' "${newer_versions}" | grep -v '^$' \
  | sed -e 's/\./\\./g' \
  | awk 'BEGIN{ORS="|"} {print "\\[" $0 "\\]"}' \
  | sed 's/|$//'; } || true)"

# Phase 1: awk extracts ONLY [Unreleased] + sections whose heading
# matches one of the newer-version patterns. Output goes straight
# to a temp file (bypasses bash string append). Marker lines between
# sections let the framing code below add the right banners.
sections_tmp="$(mktemp -t omc-whats-new-sections-XXXXXX)"
trap 'rm -f "${sections_tmp}"' EXIT

awk -v newer_re="${newer_re}" '
  BEGIN { keep = 0 }
  /^##[[:space:]]+\[Unreleased\]/ {
    if (keep) print "__OMC_SEC_END__"
    print "__OMC_SEC_UNRELEASED__"
    print
    keep = 2
    next
  }
  /^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\]/ {
    if (keep) print "__OMC_SEC_END__"
    if (newer_re != "" && match($0, newer_re)) {
      print "__OMC_SEC_RELEASE__"
      print
      keep = 1
    } else {
      keep = 0
    }
    next
  }
  /^##[[:space:]]+\[/ {
    # Other ## heading — close current section.
    if (keep) print "__OMC_SEC_END__"
    keep = 0
    next
  }
  keep > 0 { print }
  END { if (keep) print "__OMC_SEC_END__" }
' "${changelog}" > "${sections_tmp}"

# Phase 2: render the sections file with the right banners. Use awk
# again rather than bash so we never read large bodies into bash
# variables. The state-machine here is trivial: replace the
# __OMC_SEC_*__ markers with the appropriate banner text, drop the
# __OMC_SEC_END__ separators.
if [[ ! -s "${sections_tmp}" ]]; then
  printf '_You are at HEAD — no newer entries in CHANGELOG.md._\n\n'
  printf 'Run `bash %s/install.sh` after a `git pull` to refresh hooks if the source repo advances.\n' "${repo_path}"
  exit 0
fi

awk -v repo_path="${repo_path}" '
  /^__OMC_SEC_UNRELEASED__$/ {
    print "## [Unreleased] — post-release work in source tree"
    print ""
    in_unreleased = 1; unreleased_lines = 0
    next
  }
  /^__OMC_SEC_RELEASE__$/ {
    if (in_unreleased) {
      printf "_To install Unreleased: `git -C %s pull && bash install.sh`_\n\n", repo_path
      in_unreleased = 0
    }
    next
  }
  /^__OMC_SEC_END__$/ {
    if (in_unreleased) {
      printf "_To install Unreleased: `git -C %s pull && bash install.sh`_\n\n", repo_path
      in_unreleased = 0
    }
    next
  }
  in_unreleased {
    # Cap [Unreleased] section at 200 lines so a sprawling block does
    # not fill the whole context. The user can read the rest of
    # CHANGELOG.md directly.
    if (unreleased_lines < 200) { print; unreleased_lines++ }
    next
  }
  { print }
' "${sections_tmp}"

# Footer
printf '\n---\n_Read CHANGELOG.md directly at %s for the full history._\n' "${changelog}"
