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
# Before matching, `_normalize_git_flags` strips top-level options like
# `-c foo=bar`, `-C /path`, `--no-pager`, and `--git-dir=/x` from between
# `git` (or `gh`) and the verb, so `git -c user.email=x commit` is matched
# as `git commit`. Without this, the configured-override bypass was real:
# `git -c commit.gpgsign=false commit` slipped through because the regex
# required the verb adjacent to `git`.
#
# Compound commands are split on `&&`/`||`/`;`/`|` and each segment is
# evaluated independently, so a recovery invocation chained with a
# destructive one (`git rebase --abort && git push --force`) still blocks
# on the destructive segment.
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
# Allowed variants (read-only / recovery modes of the above verbs):
#   git (rebase|merge|cherry-pick|revert|am) --abort|--continue|--skip|--quit
#   git (push|commit) --dry-run|-n
#   git tag -l|--list
#
# NOT covered (read-only or local-only reversible):
#   git status / log / diff / show / branch (list form) / remote (without -v)
#   git stash push|pop|apply (local, reversible)
#   git merge-base / commit-tree / diff-tree (plumbing reads)
#   git fetch without --prune

# Anchor: start-of-string or [space ; & | ( ] followed by optional path prefix.
# ([^[:space:]]*/)? matches zero-or-more non-space chars ending in `/`, so:
#   - bare `git`                   → matches (zero-length path)
#   - `/usr/bin/git`               → matches (path = `/usr/bin/`)
#   - `./git`                      → matches (path = `./`)
#   - `my-git`                     → does NOT match (no trailing `/` after `my-`)
readonly _GUARD_PRE='(^|[[:space:];&|(])([^[:space:]]*/)?'

# Strip git/gh top-level flags between the binary and the verb, so the
# destructive/allow-list regexes see a canonical `git <verb>` form.
#
# Two flag shapes are handled:
#   (a) Flags that accept a space-separated argument: `-c name=value`,
#       `-C path`, `--git-dir <path>`, `--work-tree <path>`, `--exec-path
#       <path>`, `--namespace <name>`, `--super-prefix <path>`,
#       `--config-env <name>=<envvar>`, `--attr-source <tree-ish>`. This is
#       the complete set of git(1) top-level options that take a separate-
#       token argument per the `git --help` usage line. Without the explicit
#       list here, the single-token branch would consume the flag but leave
#       the separate-token argument in place — that argument would then sit
#       between `git` and the verb, defeating the destructive regex (e.g.
#       `git --git-dir /tmp/repo commit` normalizes to `git /tmp/repo
#       commit`, which the guard's `git commit` pattern no longer matches).
#   (b) Single-token flags: `--foo`, `--foo=bar`, bare `-X`, `--no-pager`.
#       These are consumed in one unit by the `-[^[:space:]]+` branch, so
#       `--git-dir=/tmp/repo` (the `=` form of the same flag) is handled
#       here without needing the explicit list.
#
# Anchored by the same `_GUARD_PRE` prefix so absolute-path and wrapper-
# prefix forms (`/usr/bin/git`, `sudo git`, `env git`) normalize correctly.
_normalize_git_flags() {
  sed -E 's/(^|[[:space:];&|(])(([^[:space:]]*\/)?(git|gh))(([[:space:]]+(-c|-C|--git-dir|--work-tree|--exec-path|--namespace|--super-prefix|--config-env|--attr-source)[[:space:]]+[^[:space:]]+)|([[:space:]]+-[^[:space:]]+))+/\1\2/g' <<<"$1"
}

# Recovery and read-only variants of verbs that are otherwise destructive.
# Runs on already-normalized input so `git -c foo=bar rebase --abort` (which
# normalizes to `git rebase --abort`) is recognized as a recovery op.
_cmd_is_allowed_variant() {
  local cmd="$1"
  # `--abort|--continue|--skip|--quit` on a mid-operation verb.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+(rebase|merge|cherry-pick|revert|am)[[:space:]]+.*(--abort|--continue|--skip|--quit)([[:space:]]|$)" <<<"${cmd}"; then return 0; fi
  # `--dry-run|-n` on push/commit reports intent without mutation.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+(push|commit)[[:space:]]+.*(--dry-run|-n)([[:space:]]|$)" <<<"${cmd}"; then return 0; fi
  # List-only tag invocation.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+tag[[:space:]]+(-l|--list)([[:space:]]|$)" <<<"${cmd}"; then return 0; fi
  return 1
}

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

  # Porcelain: direct local/remote state mutation.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+commit([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+push([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+revert([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+reset[[:space:]]+--hard" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+rebase([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+cherry-pick([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+tag([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+merge([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+am([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+apply([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  # Branch/ref rewriting — only destructive flag forms, so `git branch` (list)
  # and `git branch newfeature` (create only) are allowed. Catches `-D`, `-M`,
  # `-C`, `--delete`, `--force`. False positive only if a branch literally
  # named `-D` or `--force` is passed as an argument — both are impossible
  # because git rejects them.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+branch[[:space:]]+.*(-D|-M|-C|--delete|--force)" <<<"${lc}"; then return 0; fi
  # `git switch -C` or `--force` moves/overwrites; `-c` alone is safe.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+switch[[:space:]]+.*(-C|--force)" <<<"${lc}"; then return 0; fi
  # `git checkout -B` or `--force` moves/overwrites; `-b` alone is safe.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+checkout[[:space:]]+.*(-B|--force)" <<<"${lc}"; then return 0; fi
  # `git clean -f` removes untracked files (destructive).
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+clean[[:space:]]+.*(-f|--force)" <<<"${lc}"; then return 0; fi

  # Plumbing: directly rewrites refs/objects. These are the "work around
  # by using plumbing" escape hatches the directive warns against.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+(update-ref|symbolic-ref|fast-import|filter-branch|replace)([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  # gh CLI: publishes state to GitHub.
  if grep -Eq "${_GUARD_PRE}gh[[:space:]]+(pr|release)[[:space:]]+(create|merge|edit|close|comment|delete|reopen)([[:space:]]|$)" <<<"${lc}"; then return 0; fi
  if grep -Eq "${_GUARD_PRE}gh[[:space:]]+issue[[:space:]]+(create|edit|close|comment|delete|reopen)([[:space:]]|$)" <<<"${lc}"; then return 0; fi

  return 1
}

# Walk compound-shell segments independently. The canonical example is
# `git rebase --abort && git push --force`: the first segment is an allowed
# recovery op, the second is destructive. A whole-line check would either
# miss the push or over-block the rebase; splitting keeps both decisions honest.
normalized_cmd="$(_normalize_git_flags "${command_str}")"
denied_segment=""
while IFS= read -r _seg; do
  [[ -z "${_seg// }" ]] && continue
  if _cmd_matches_destructive "${_seg}" && ! _cmd_is_allowed_variant "${_seg}"; then
    denied_segment="${_seg}"
    break
  fi
done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"${normalized_cmd}")

if [[ -z "${denied_segment}" ]]; then
  exit 0
fi

intent_label="${task_intent//_/-}"

# Record the block for show-status visibility AND return the post-
# increment value so the verbose-vs-terse decision below can use a
# value observed *inside* the lock. Uses a new state key
# (pretool_intent_blocks) so it does not collide with advisory_guard_blocks,
# which tracks the separate advisory-inspection gate in stop-guard.
# A prior revision read the counter a second time *outside* the lock to
# pick the reason tone, which allowed a parallel tool_use block to
# observe another hook's increment and silently downgrade the first-
# ever verbose coaching block to terse. Emitting the new value from
# inside the locked function and capturing it via `$(...)` closes that
# race — the caller sees exactly the counter value that this hook wrote.
_increment_pretool_blocks() {
  local _c
  _c="$(read_state "pretool_intent_blocks")"
  _c="${_c:-0}"
  _c=$((_c + 1))
  write_state "pretool_intent_blocks" "${_c}"
  printf '%s' "${_c}"
}
block_count="$(with_state_lock _increment_pretool_blocks)" || block_count=""
# Safety net: an exhausted lock returns empty/rc=1. Treat as first
# block so the user still gets the verbose coaching text rather than a
# silently-degraded terse message attributed to a phantom earlier block.
block_count="${block_count:-1}"

log_hook "pretool-intent-guard" "blocked: intent=${task_intent} block=${block_count} cmd=$(truncate_chars 80 "${command_str}")"

if [[ "${block_count}" -le 1 ]]; then
  reason="[PreTool gate · ${intent_label} · block 1] The active prompt was classified as '${intent_label}', not execution. Destructive git/gh operations (commit, push, revert, reset --hard, rebase, cherry-pick, tag, merge, branch -D, switch -C, checkout -B, clean -f, update-ref, filter-branch, gh pr/release/issue create/merge/edit/close) require explicit execution authorization.

What to do instead:
  (a) Deliver the ${intent_label} response the user asked for — assessment, recommendation, or checkpoint.
  (b) If changes are warranted, list them as recommendations and wait for the user to reply with explicit authorization framing (an imperative prompt like 'implement X' or 'fix Y' — a fresh UserPromptSubmit that the classifier will reclassify as execution).
  (c) If you believe this is a misclassification, say so in your response and ask the user to confirm execution intent before retrying.

Do not attempt to work around this guard by using alternative commands (plumbing git verbs, absolute paths, filesystem edits to .git/, or invoking git through another language runtime) — the spirit of the rule is 'no unauthorized modifications to any repo', not 'only the surface forms listed'.

Attempted command: $(truncate_chars 200 "${command_str}")"
else
  reason="[PreTool gate · ${intent_label} · block ${block_count}] Destructive git/gh operations still require explicit execution authorization. Deliver the assessment/recommendation the user asked for. A fresh imperative prompt ('implement X', 'fix Y') will reclassify intent and unblock edits.
Attempted: $(truncate_chars 200 "${command_str}")"
fi

record_gate_event "pretool-intent" "block" \
  "block_count=${block_count}" \
  "intent=${task_intent}" \
  "denied_segment=$(truncate_chars 120 "${denied_segment}")"

jq -nc --arg reason "${reason}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
