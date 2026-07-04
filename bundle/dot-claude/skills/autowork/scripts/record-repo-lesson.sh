#!/usr/bin/env bash
# record-repo-lesson.sh — append a capped, git-shareable bullet to a
# repo-committed lessons/backlog file (v1.48-pre `repo_lessons` flag).
#
# oh-my-claude's other memory surfaces (auto-memory.md's project_*.md /
# feedback_*.md / user_*.md / reference_*.md) all live under ~/.claude —
# machine-local, never committed. This script is the deliberate
# exception: when the user has explicitly opted in (repo_lessons=on),
# it writes team-shareable, git-committable memory INSIDE the target
# repo itself, so lessons and a follow-up backlog survive across
# machines and teammates via normal git history, not just this one
# machine's ~/.claude tree.
#
# Because it persists session-derived text into files the user may
# later `git add` / commit / push, the flag is OFF by default and is
# deny-listed at project-conf scope (see common.sh `_parse_conf_file`'s
# `level == "project"` branch) — only user-level
# `~/.claude/oh-my-claude.conf` or `OMC_REPO_LESSONS=on` can turn it on.
# A hostile or merely unfamiliar repo's own committed
# `.claude/oh-my-claude.conf` cannot flip this on for itself.
#
# Usage:
#   record-repo-lesson.sh add lesson  "<text>"
#   record-repo-lesson.sh add backlog "<text>"
#
# Writes (resolved via `git rev-parse --show-toplevel`):
#   <repo root>/.claude/lessons.md   — durable project lessons
#   <repo root>/.claude/backlog.md   — durable follow-up items
#
# Each file is capped at 7 bullets, newest first — adding an 8th drops
# the oldest. No-op (exit 0, no output) when repo_lessons is off, the
# cwd is not inside a git work tree, or SESSION_ID is unset — so this
# is always safe to call speculatively from the auto-memory wrap-up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# Hook-style guard: exit 0 on missing SESSION_ID so test / non-session
# invocations don't fail loudly (mirrors record-serendipity.sh).
if [[ -z "${SESSION_ID:-}" ]]; then
  exit 0
fi

# Opt-in, off by default — see the file header for the WHY.
is_repo_lessons_enabled || exit 0

# Must be inside a git WORK TREE (not merely inside a `.git` dir or a
# bare repo — `git rev-parse --is-inside-work-tree` exits 0 in both of
# those cases too, printing "false", so the output must be checked, not
# just the exit code). Silent no-op elsewhere (scratch dirs, /tmp, etc).
if ! command -v git >/dev/null 2>&1; then
  exit 0
fi
_in_worktree="$(git rev-parse --is-inside-work-tree 2>/dev/null || true)"
if [[ "${_in_worktree}" != "true" ]]; then
  exit 0
fi

cap=7

usage() {
  cat <<'USAGE' >&2
record-repo-lesson.sh — append a capped, git-shareable bullet to
.claude/lessons.md or .claude/backlog.md at the repo root.

usage:
  record-repo-lesson.sh add lesson  "<text>"
  record-repo-lesson.sh add backlog "<text>"

No-op (exit 0) unless repo_lessons=on (user-level oh-my-claude.conf or
OMC_REPO_LESSONS=on) and cwd is inside a git work tree.
USAGE
}

if [[ "${1:-}" != "add" ]]; then
  usage
  exit 2
fi

list_name="${2:-}"
text="${3:-}"

file_name=""
title=""
case "${list_name}" in
  lesson)  file_name="lessons.md" ; title="Lessons" ;;
  backlog) file_name="backlog.md" ; title="Backlog" ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ -z "${text}" ]]; then
  usage
  exit 2
fi

# A bullet is one line. A smuggled newline/CR could inject a second
# fake bullet or header line into a file the user may commit and push
# — the repo-file equivalent of omc-config.sh's str-value CRLF guard.
if [[ "${text}" == *$'\n'* || "${text}" == *$'\r'* ]]; then
  printf 'record-repo-lesson: text cannot contain newlines or carriage returns\n' >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || exit 0

target_dir="${repo_root}/.claude"
target="${target_dir}/${file_name}"
mkdir -p "${target_dir}" 2>/dev/null || exit 0

# Header = every leading line that is not a bullet ("- ..."). Preserves
# a pre-existing file's header verbatim; synthesizes a fresh 2-line one
# on first write.
header=""
old_bullets=""
if [[ -f "${target}" ]]; then
  header="$(awk '/^- /{exit} {print}' "${target}")"
  old_bullets="$(grep '^- ' "${target}" 2>/dev/null || true)"
fi
if [[ -z "${header}" ]]; then
  header="$(printf '# %s\n<!-- Repo-shared, git-committable memory written by oh-my-claude (repo_lessons=on). Newest bullet first; capped at %d — see docs/customization.md. -->' "${title}" "${cap}")"
fi

new_bullet="- ${text}"

tmp="$(mktemp "${target}.XXXXXX")" || exit 0
{
  printf '%s\n' "${header}"
  {
    printf '%s\n' "${new_bullet}"
    if [[ -n "${old_bullets}" ]]; then
      printf '%s\n' "${old_bullets}"
    fi
  } | head -n "${cap}"
} > "${tmp}"
mv "${tmp}" "${target}"
chmod 644 "${target}" 2>/dev/null || true

exit 0
