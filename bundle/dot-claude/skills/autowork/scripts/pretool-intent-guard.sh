#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_JSON="$(cat)"
. "${SCRIPT_DIR}/common.sh"

SESSION_ID="$(json_get '.session_id')"
if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

# Honour the customization kill-switch. Users who prefer the directive layer
# alone can set pretool_intent_guard=false in oh-my-claude.conf or
# OMC_PRETOOL_INTENT_GUARD=false in the environment.
if [[ "${OMC_PRETOOL_INTENT_GUARD:-true}" == "false" ]]; then
  exit 0
fi

# Only act under ULW. The directive layer in session-start-compact-handoff.sh
# covers the advisory-post-compact case for the main thread; this guard is
# the enforcement backstop when the model ignores the directive. Outside ULW
# we have no classifier state to consult, so bail.
if ! is_ultrawork_mode; then
  exit 0
fi

task_intent="$(read_state "task_intent")"

case "${task_intent}" in
  advisory|session_management|checkpoint)
    ;;
  *)
    # execution, continuation, or unset — allow.
    exit 0
    ;;
esac

tool_name="$(json_get '.tool_name')"
if [[ "${tool_name}" != "Bash" ]]; then
  exit 0
fi

command_str="$(json_get '.tool_input.command')"
if [[ -z "${command_str}" ]]; then
  exit 0
fi

# Detect destructive git/gh operations. Patterns are word-boundary anchored
# so they match the real invocation forms (`git commit`, `sudo git commit`,
# `cd foo && git push`, `/usr/bin/git push`) without false-positives on
# substrings (e.g. `git merge-base`, `git commit-tree`, `my-git-tool commit`).
#
# The prefix `_pre` allows an optional path (e.g. `/usr/bin/`) between the
# start-of-command anchor and the `git` / `gh` token. This catches absolute-
# path invocations that would otherwise bypass the guard. `my-git-tool` still
# fails because the character preceding `m` in `my-git-tool` is whitespace
# and `my-` is not a path segment (has no trailing `/`).
#
# Note: this guard is best-effort. A determined bypass (Python subprocess
# invoking git, editing `.git/` directly) cannot be caught by command-line
# pattern matching. The directive injected at the compact handoff and the
# stop-guard's advisory-inspection gate are the other layers that make
# circumvention obvious rather than stealthy.
#
# Race: `task_intent` is written by UserPromptSubmit and read here. A
# concurrent router write could let the guard make a stale decision, but
# Claude Code serializes UserPromptSubmit → PreToolUse within a turn, so
# the window is negligible. Fail-closed (deny on stale non-execution) is
# the correct default.
#
# Covered (destructive or publishing):
#   git commit / push / revert / reset --hard / rebase / cherry-pick / tag
#   git merge / am / apply
#   git branch with -D|-M|-C|--delete|--force
#   git switch with -C or --force
#   git checkout with -B or --force
#   git update-ref / symbolic-ref / fast-import / filter-branch / replace
#   git clean -f|-fd
#   gh pr|release|issue create|merge|edit|close|delete|reopen|comment
#
# NOT covered (read-only or local-only reversible):
#   git status / log / diff / show / branch (list form) / remote (without -v)
#   git stash push|pop|apply (local, reversible)
#   git merge-base / commit-tree / diff-tree (plumbing reads)
#   git fetch without --prune
_cmd_matches_destructive() {
  local cmd="$1"
  # Case-sensitive matching is intentional: git CLI flags like `-D` (force-delete
  # branch), `-C` (force-create branch), `-B` (force-reuse branch) differ from
  # their lowercase counterparts in destructive semantics, so a prior lowercase
  # transform would collapse the distinction and miss `branch -D`. Git verbs
  # themselves are always lowercase in real invocations — we accept that a
  # `GIT COMMIT` would bypass the guard; that's a theoretical path not worth
  # the flag-case regression.
  local lc="${cmd}"

  # Anchor: start-of-string or [space ; & | ( ] followed by optional path prefix.
  # ([^[:space:]]*/)? matches zero-or-more non-space chars ending in `/`, so:
  #   - bare `git`                   → matches (zero-length path)
  #   - `/usr/bin/git`               → matches (path = `/usr/bin/`)
  #   - `./git`                      → matches (path = `./`)
  #   - `my-git`                     → does NOT match (no trailing `/` after `my-`)
  local _pre='(^|[[:space:];&|(])([^[:space:]]*/)?'

  # Porcelain: direct local/remote state mutation.
  if grep -Eq "${_pre}git[[:space:]]+commit([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+push([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+revert([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+reset[[:space:]]+--hard" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+rebase([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+cherry-pick([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+tag([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+merge([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+am([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}git[[:space:]]+apply([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  # Branch/ref rewriting — only destructive flag forms, so `git branch` (list)
  # and `git branch newfeature` (create only) are allowed. Catches `-D`, `-M`,
  # `-C`, `--delete`, `--force`. False positive only if a branch literally
  # named `-D` or `--force` is passed as an argument — both are impossible
  # because git rejects them.
  if grep -Eq "${_pre}git[[:space:]]+branch[[:space:]]+.*(-D|-M|-C|--delete|--force)" <<<"${lc}"; then return 0; fi
  # `git switch -C` or `--force` moves/overwrites; `-c` alone is safe.
  if grep -Eq "${_pre}git[[:space:]]+switch[[:space:]]+.*(-C|--force)" <<<"${lc}"; then return 0; fi
  # `git checkout -B` or `--force` moves/overwrites; `-b` alone is safe.
  if grep -Eq "${_pre}git[[:space:]]+checkout[[:space:]]+.*(-B|--force)" <<<"${lc}"; then return 0; fi
  # `git clean -f` removes untracked files (destructive).
  if grep -Eq "${_pre}git[[:space:]]+clean[[:space:]]+.*(-f|--force)" <<<"${lc}"; then return 0; fi

  # Plumbing: directly rewrites refs/objects. These are the "work around
  # by using plumbing" escape hatches the directive warns against.
  if grep -Eq "${_pre}git[[:space:]]+(update-ref|symbolic-ref|fast-import|filter-branch|replace)([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  # gh CLI: publishes state to GitHub.
  if grep -Eq "${_pre}gh[[:space:]]+(pr|release)[[:space:]]+(create|merge|edit|close|comment|delete|reopen)([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_pre}gh[[:space:]]+issue[[:space:]]+(create|edit|close|comment|delete|reopen)([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  return 1
}

if ! _cmd_matches_destructive "${command_str}"; then
  exit 0
fi

intent_label="${task_intent//_/-}"

# Record the block for show-status visibility. Uses a new state key
# (pretool_intent_blocks) so it does not collide with advisory_guard_blocks,
# which tracks the separate advisory-inspection-gate in stop-guard.
# Wrapped in with_state_lock to prevent lost increments when the model
# issues multiple tool_use blocks in one assistant turn (parallel Bash).
_increment_pretool_blocks() {
  local _c
  _c="$(read_state "pretool_intent_blocks")"
  _c="${_c:-0}"
  write_state "pretool_intent_blocks" "$((_c + 1))"
}
with_state_lock _increment_pretool_blocks || true

log_hook "pretool-intent-guard" "blocked: intent=${task_intent} cmd=$(truncate_chars 80 "${command_str}")"

reason="Blocked: the active prompt was classified as '${intent_label}' (not execution). Destructive git/gh operations (commit, push, revert, reset --hard, rebase, cherry-pick, tag, merge, branch -D, switch -C, checkout -B, clean -f, update-ref, filter-branch, gh pr/release/issue create/merge/edit/close) require explicit execution authorization.

What to do instead:
  (a) Deliver the ${intent_label} response the user asked for — assessment, recommendation, or checkpoint.
  (b) If changes are warranted, list them as recommendations and wait for the user to reply with explicit authorization framing (an imperative prompt like 'implement X' or 'fix Y' — a fresh UserPromptSubmit that the classifier will reclassify as execution).
  (c) If you believe this is a misclassification, say so in your response and ask the user to confirm execution intent before retrying.

Do not attempt to work around this guard by using alternative commands (plumbing git verbs, absolute paths, filesystem edits to .git/, or invoking git through another language runtime) — the spirit of the rule is 'no unauthorized modifications to any repo', not 'only the surface forms listed'.

Attempted command: $(truncate_chars 200 "${command_str}")"

jq -nc --arg reason "${reason}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
