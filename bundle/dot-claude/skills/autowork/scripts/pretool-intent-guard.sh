#!/usr/bin/env bash

set -euo pipefail

# Fast-path: skip if ULW was never activated in this environment.
[[ -f "${HOME}/.claude/quality-pack/state/.ulw_active" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
HOOK_JSON="$(_omc_read_hook_stdin)"

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

tool_name="$(json_get '.tool_name')"
command_str=""
if [[ "${tool_name}" == "Bash" ]]; then
  command_str="$(json_get '.tool_input.command')"
fi
task_intent=""
commit_contract_mode=""
push_contract_mode=""
agent_first_specialist_ts=""

# v1.34.1+ (sre-lens S-003): bulk-read the always-together state keys
# in one jq fork instead of sequential read_state calls. Hot-path —
# fires on every guarded PreToolUse call inside ULW. Same RS-
# delimited pattern as stop-guard.sh:135-149 and prompt-intent-router's
# v1.27.0 F-018/F-019 bulk-reads. Invariant: argv length === case
# branches.
#
# v1.34.0 (Bug C): push_mode is independent of commit_mode so a
# compound directive like "commit X. don't push Y." can allow the
# commit while blocking the push.
_pig_idx=0
while IFS= read -r -d $'\x1e' _pig_line; do
  case "${_pig_idx}" in
    0) task_intent="${_pig_line}" ;;
    1) commit_contract_mode="${_pig_line}" ;;
    2) push_contract_mode="${_pig_line}" ;;
    3) agent_first_specialist_ts="${_pig_line}" ;;
  esac
  _pig_idx=$((_pig_idx + 1))
done < <(read_state_keys \
  "task_intent" \
  "done_contract_commit_mode" \
  "done_contract_push_mode" \
  "agent_first_specialist_ts")
intent_guard_active=0

case "${task_intent}" in
  advisory|session_management|checkpoint) intent_guard_active=1 ;;
esac

# Agent-first invariant for /ulw execution. The main thread may inspect first,
# but it must not mutate the workspace before at least one fresh-context
# specialist (planner, domain specialist, challenge agent, lens, researcher,
# writer, etc.) has returned. Post-hoc reviewers do not stamp
# agent_first_specialist_ts; see record-subagent-summary.sh.
_agent_first_gate_active() {
  case "${task_intent}" in
    execution|continuation) return 0 ;;
    *) return 1 ;;
  esac
}

_bash_command_may_mutate_workspace() {
  local cmd="$1"
  [[ -z "${cmd}" ]] && return 1

  local cleaned
  cleaned="$(sed -E \
    -e 's/[0-9]*>>?[[:space:]]*\/dev\/null//g' \
    -e 's/[0-9]*>[&][0-9]+//g' \
    <<<"${cmd}")"

  # Shell redirects to real files are writes. This intentionally ignores
  # input redirects (`<`) and stderr/stdout redirects to /dev/null handled
  # above, so read-only inspection commands like `git status 2>/dev/null`
  # stay allowed before the specialist floor is satisfied.
  if grep -Eq '(^|[^0-9])>>?[[:space:]]*[^[:space:]&|;]+' <<<"${cleaned}"; then return 0; fi

  # Common workspace mutation forms. This is deliberately a floor, not a
  # sandbox: obscure write paths are still caught by edit tracking and stop
  # gates, while the common direct-edit and package-manager paths are denied
  # before they run.
  if grep -Eiq '(^|[[:space:];&|(])(rm|rmdir|mv|cp|mkdir|touch|chmod|chown|ln|truncate|install|rsync|dd|tee)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])sed[[:space:]][^;&|]*[[:space:]]-i([^[:alnum:]_-]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])perl[[:space:]][^;&|]*-(p?i|i?p)([^[:alnum:]_-]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])(prettier|eslint|ruff)[[:space:]][^;&|]*(--write|--fix)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])(black|isort|rustfmt|swiftformat)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])gofmt[[:space:]][^;&|]*-w([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])(npm|pnpm|yarn)[[:space:]]+(install|i|add|remove|rm|uninstall|update|upgrade|dedupe)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])npm[[:space:]]+audit[[:space:]]+fix([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])(pip|pip3|poetry|uv|bundle|cargo|gem|brew)[[:space:]]+(install|add|remove|rm|uninstall|update|upgrade|lock|fix)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])go[[:space:]]+(mod[[:space:]]+tidy|get|install)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])swift[[:space:]]+package[[:space:]]+(update|resolve)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi

  # Destructive git/gh operations are also mutations. The full advisory-intent
  # matcher below is stricter; these common forms are enough for the agent-first
  # floor before that matcher is defined.
  if grep -Eiq '(^|[[:space:];&|(])([^[:space:]]*/)?git[[:space:]]+(commit|push|revert|reset[[:space:]]+--hard|rebase|cherry-pick|merge|am|apply|clean|update-ref|symbolic-ref|fast-import|filter-branch|replace|stash[[:space:]]+(push|pop|apply))([[:space:]]|$)' <<<"${cmd}"; then return 0; fi
  if grep -Eiq '(^|[[:space:];&|(])([^[:space:]]*/)?gh[[:space:]]+(pr|release|issue)[[:space:]]+(create|merge|edit|close|comment|delete|reopen)([[:space:]]|$)' <<<"${cmd}"; then return 0; fi

  # `git tag` is the one verb above that has a frequently-used list mode
  # (`git tag` alone, `git tag --list`, `git tag --sort=-creatordate`,
  # `git tag --contains HEAD`, `git tag --points-at v1.13.0`, `git tag -n5`,
  # `git tag -v <name>` for signature verification). The advisory matcher's
  # `_cmd_is_allowed_variant` at :311 already encodes this discrimination;
  # the floor matcher needs the same nuance so read-only inspection of tags
  # is allowed before the specialist floor is satisfied — matching the
  # v1.41.0 "Read-only inspection still passes" contract.
  #
  # The narrowing was triggered by a real false-positive: the agent-first
  # gate blocked `git tag --sort=-creatordate | head -5 && git status
  # --short` on a session-start inspection burst, which is exactly the
  # kind of read-only audit the gate is supposed to allow.
  #
  # Allow-list: any `git tag` whose immediate next token is one of the
  # documented list-mode flags (including `-v|--verify` for signature
  # checking, which is read-only per git-tag(1)), or which has no further
  # token at all (`git tag` alone = list). Anything else (positional name
  # = create, `-a/-s/-d/-f`, `--annotate/--sign/--delete/--force`,
  # `-m/--message`, `-F/--file`, `--cleanup`, `-u/--local-user`,
  # `--no-sign`) falls through to the mutation branch below.
  #
  # Known limitation (shared with the advisory matcher at :311):
  # `git tag --format='<fmt>' newtag` — the create form with a custom
  # format flag — falsely matches list-mode because the regex stops at
  # the first list-mode flag without checking for a trailing positional
  # tag name. Deferred; the pattern is uncommon enough that the v1.14
  # advisory pass shipped without catching it. The mitigation: the Stop
  # hook's mark-edit tracker and quality-reviewer pass still catch the
  # mutation downstream.
  #
  # Case-sensitivity: `-Ei` (case-insensitive) is intentionally different
  # from the advisory matcher's case-sensitive choice at :320. The advisory
  # matcher uses case-sensitivity to distinguish `git branch -D` (force-
  # delete) from `-d` (safe-delete). `git tag` has no such case-distinct
  # flag pair — `-d` is the only delete form — so case-insensitive matching
  # is safe here and slightly more permissive against `Git Tag` / `GIT TAG`
  # corner cases. Document this divergence so a future maintainer adding
  # a case-distinct flag doesn't introduce a silent regression.
  if grep -Eiq '(^|[[:space:];&|(])([^[:space:]]*/)?git[[:space:]]+tag([[:space:]]|$)' <<<"${cmd}"; then
    if ! grep -Eiq '(^|[[:space:];&|(])([^[:space:]]*/)?git[[:space:]]+tag([[:space:]]*$|[[:space:]]*[|;&]|[[:space:]]+(-l|--list|--sort|--contains|--no-contains|--points-at|--merged|--no-merged|-n[0-9]*|--column|--no-column|--format|-i|--ignore-case|-v|--verify)([[:space:]=]|$))' <<<"${cmd}"; then
      return 0
    fi
  fi

  return 1
}

_tool_attempts_mutation() {
  case "${tool_name}" in
    Edit|Write|MultiEdit|NotebookEdit)
      return 0
      ;;
    Bash)
      _bash_command_may_mutate_workspace "${command_str}"
      return
      ;;
    *)
      return 1
      ;;
  esac
}

_record_first_mutation_attempt() {
  local existing
  existing="$(read_state "first_mutation_ts")"
  if [[ -z "${existing}" ]]; then
    write_state_batch \
      "first_mutation_ts" "$(now_epoch)" \
      "first_mutation_tool" "${tool_name}"
  fi
}

if _agent_first_gate_active && _tool_attempts_mutation; then
  if [[ -z "${agent_first_specialist_ts}" ]]; then
    # shellcheck disable=SC2329  # invoked indirectly via with_state_lock
    _increment_agent_first_blocks() {
      local _c
      _c="$(read_state "agent_first_gate_blocks")"
      _c="${_c:-0}"
      _c=$((_c + 1))
      write_state "agent_first_gate_blocks" "${_c}"
      printf '%s' "${_c}"
    }
    agent_first_block_count="$(with_state_lock _increment_agent_first_blocks)" || agent_first_block_count=""
    agent_first_block_count="${agent_first_block_count:-1}"
    attempted_mutation="${tool_name}"
    if [[ "${tool_name}" == "Bash" ]]; then
      attempted_mutation="Bash: $(truncate_chars 160 "${command_str}")"
    fi
    record_gate_event "agent-first" "block" \
      "block_count=${agent_first_block_count}" \
      "tool=${tool_name}" \
      "attempted=$(truncate_chars 180 "${attempted_mutation}")"
    jq -nc --arg reason "[Agent-first gate · block ${agent_first_block_count}] /ulw execution is orchestrated multi-agent work, not main-thread implementation followed by reviewer cleanup. Read-only inspection is allowed, but before the first workspace mutation you must dispatch and wait for a fresh-context specialist that can shape the work (quality-planner, prometheus, metis, oracle, abstraction-critic, a domain specialist, librarian/quality-researcher, writing-architect, or a relevant lens). Post-hoc reviewers such as quality-reviewer do not satisfy this gate. Attempted mutation: ${attempted_mutation}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
  with_state_lock _record_first_mutation_attempt || true
fi

if [[ "${tool_name}" != "Bash" ]]; then
  exit 0
fi

if [[ -z "${command_str}" ]]; then
  exit 0
fi

if [[ "${intent_guard_active}" -eq 0 ]] && [[ "${commit_contract_mode}" != "forbidden" ]] && [[ "${push_contract_mode}" != "forbidden" ]]; then
  # execution, continuation, or unset with no explicit "do not commit"
  # contract — allow.
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
#   git apply --check|--stat|--numstat|--summary
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
  # Read-only `git apply` inspection forms. `git apply` itself mutates
  # the worktree/index, but these flags only validate or summarize a patch.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+apply[[:space:]]+.*(--check|--stat|--numstat|--summary)([[:space:]]|$)" <<<"${cmd}"; then return 0; fi
  # Read-only `git tag` invocations. The CLI is positional: presence of
  # `<tagname>` without flags is the create form; presence of any of
  # these flags is a list/inspect form. We accept the broader set so
  # advisory-mode prompts can audit tags (e.g., `git tag --sort=-creatordate`,
  # `git tag --contains HEAD`, `git tag --points-at v1.13.0`, `git tag -n5`)
  # without bouncing off the destructive-verb gate. The narrower
  # original (`-l|--list` only) caused real friction during the v1.14
  # advisory pass — the inspection commands had to be replaced with
  # `ls .git/refs/tags/` plumbing as a workaround.
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+tag([[:space:]]+[^[:space:]]+)*[[:space:]]+(-l|--list|--sort|--contains|--no-contains|--points-at|--merged|--no-merged|-n[0-9]*|--column|--no-column|--format|-i|--ignore-case)([[:space:]=]|$)" <<<"${cmd}"; then return 0; fi
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

# Wave-execution exception. When a council Phase 8 wave plan is active
# (findings.json has at least one wave with status `pending` or
# `in_progress`), the user has already authorized exhaustive wave
# execution. A subsequent system-injected UserPromptSubmit frame
# (scheduled wakeup, /loop tick, post-compact handoff, SessionStart
# resume) can flip task_intent to advisory because the frame text isn't
# imperative — but the persisted wave plan IS the user's standing
# authorization, and per-wave confirmation is the exact "Should I
# proceed?" anti-pattern core.md forbids. Short-circuit to allow and
# record the override for audit; if the user actually wants to abort,
# they mark waves rejected/completed via record-finding-list, not by
# leaving stale advisory intent in place.
#
# Scope: the override applies ONLY to `git commit` — the canonical per-
# wave operation in Phase 8 (commits titled `Wave N/M: <surface>`).
# Other destructive ops (push, tag, rebase, reset --hard, branch -D,
# force-push, plumbing rewrites) still require fresh execution intent
# — the wave plan authorizes per-wave commits, not arbitrary repo
# manipulation. This keeps the gate's real purpose intact while
# removing the disturbing UX where the model invents a "single yes
# reauthorizes commit" gate to break out of the misclassification.
_wave_execution_active() {
  local findings_file
  findings_file="$(session_file "findings.json")"
  [[ -f "${findings_file}" ]] || return 1

  # Freshness gate. If the wave plan has not been touched in
  # OMC_WAVE_OVERRIDE_TTL_SECONDS (default 7200 = 2 hours), the user
  # has likely moved on or abandoned the plan without explicitly marking
  # waves completed/rejected. Without this gate, a stale findings.json
  # in the same session dir would leak the override across unrelated
  # later work — the exact "broad authorization that lingers past
  # intent" risk the gate is supposed to prevent. 7200s is wider than
  # the 900s post-compact-bias / classifier-misfire staleness windows
  # because per-wave cycles (plan + impl + review + verify + commit)
  # legitimately span well over 30 minutes on complex work; tighter
  # defaults nudge the model toward artificial smaller scopes. Read
  # the timestamp before the waves[] inspection so a malformed/zero ts
  # disqualifies the override
  # — fail-closed when the plan's freshness cannot be established.
  local updated_ts now_ts age max_age
  updated_ts="$(jq -r '.updated_ts // 0' "${findings_file}" 2>/dev/null || printf '0')"
  [[ "${updated_ts}" =~ ^[0-9]+$ ]] || return 1
  now_ts="$(date +%s)"
  age=$((now_ts - updated_ts))
  max_age="${OMC_WAVE_OVERRIDE_TTL_SECONDS:-7200}"
  # TTL=0 is a documented kill-switch: the override never fires regardless
  # of age. Without this special-case, the natural `age > 0` comparison
  # leaves a one-second window where a same-second wave-status write
  # (age=0) would still trigger the override — strictly contradicting the
  # CHANGELOG's "set wave_override_ttl_seconds=0 to disable entirely"
  # claim.
  if [[ "${max_age}" -eq 0 ]] || [[ "${age}" -gt "${max_age}" ]]; then
    return 1
  fi

  jq -e '
    [(.waves // [])[] | select(.status == "in_progress" or .status == "pending")]
    | length > 0
  ' "${findings_file}" >/dev/null 2>&1
}

_is_git_commit_segment() {
  # Reuses the same _GUARD_PRE prefix as the destructive matcher so
  # absolute-path forms (`/usr/bin/git commit`) and wrapper invocations
  # (`sudo git commit`) are recognized identically. Operates on the
  # already-normalized denied_segment so flag-injection bypass forms
  # (`git -c foo=bar commit`) also normalize to `git commit`.
  grep -Eq "${_GUARD_PRE}git[[:space:]]+commit([[:space:]]|$)" <<<"$1"
}

# Override eligibility check. The destructive-matcher loop above stops
# at the first destructive segment, so `denied_segment` alone cannot
# tell us about subsequent segments — and a compound like `git commit
# && git push --force` would otherwise pass the override on the commit
# segment while smuggling a force-push past the gate. Re-walk all
# segments and confirm that EVERY destructive non-allowed segment is a
# `git commit`. Any other destructive op disqualifies the override.
#
# Load-bearing invariant: this function operates on input that has
# already been processed by `_normalize_git_flags` (the call site passes
# `${normalized_cmd}`). Per-segment normalization is NOT redone here,
# because the original loop at line 218 normalizes the whole string
# once before splitting. Future refactors that change the normalize-
# then-split order MUST normalize each segment individually before
# calling `_is_git_commit_segment`, or flag-injection forms like
# `git -c foo=bar commit && git -c bar=baz push --force` will leak.
_wave_override_command_safe() {
  local cmd_normalized="$1"
  local _seg
  while IFS= read -r _seg; do
    [[ -z "${_seg// }" ]] && continue
    if _cmd_matches_destructive "${_seg}" && ! _cmd_is_allowed_variant "${_seg}"; then
      if ! _is_git_commit_segment "${_seg}"; then
        return 1
      fi
    fi
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"${cmd_normalized}")
  return 0
}

# Prompt-text trust override (v1.23.0). When the classifier mis-routes
# a prompt as advisory but the raw user prompt unambiguously authorizes
# the destructive verb being attempted, the prompt itself IS the
# authorization — Wave 1's classifier widening should catch most cases,
# this layer is the defense-in-depth that closes the long-tail of
# imperative-tail prompt shapes the regex doesn't yet recognize.
#
# Safety rails:
#   (a) The prompt must pass `is_imperative_request` — noun-only
#       mentions like "review the commit hooks" don't fire the override
#       because that prompt isn't imperative.
#   (b) Every destructive non-allowed segment must have its verb
#       mentioned in the prompt with an imperative-tail object marker
#       (article/preposition/temporal/sentence-terminator) or at
#       end-of-prompt. A compound `git commit && git push --force` only
#       passes when BOTH `commit` AND `push` are authorized in the
#       prompt — the all-segments-authorized rule mirrors
#       _wave_override_command_safe.
#   (c) The override reads `recent_prompts.jsonl` (the same source the
#       router uses) and considers only the most recent user prompt.
#       Prior prompts in the session log are NOT consulted — a stale
#       authorization from an earlier prompt cannot leak into a later
#       advisory turn.
#
# Maps the executed git/gh verb back to the imperative verb the prompt
# would say. Same table the destructive matcher uses, in the same
# order, so a future verb addition only needs one site update.
_extract_destructive_verb_from_segment() {
  local seg="$1"
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+commit([[:space:]]|$)"      <<<"${seg}"; then printf 'commit';      return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+push([[:space:]]|$)"        <<<"${seg}"; then printf 'push';        return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+revert([[:space:]]|$)"      <<<"${seg}"; then printf 'revert';      return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+reset[[:space:]]+--hard"    <<<"${seg}"; then printf 'reset';       return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+rebase([[:space:]]|$)"      <<<"${seg}"; then printf 'rebase';      return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+cherry-pick([[:space:]]|$)" <<<"${seg}"; then printf 'cherry-pick'; return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+tag([[:space:]]|$)"         <<<"${seg}"; then printf 'tag';         return; fi
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+merge([[:space:]]|$)"       <<<"${seg}"; then printf 'merge';       return; fi
  if grep -Eq "${_GUARD_PRE}gh[[:space:]]+(pr|release|issue)[[:space:]]+(create|merge|edit|close|comment|delete|reopen)" <<<"${seg}"; then
    # gh ops authorize via "open"/"create"/"publish"/"release"/"ship" — return
    # a sentinel that _verb_appears_in_imperative_position checks against
    # this verb-class instead of a single literal.
    printf 'gh-publish'
    return
  fi
  printf ''
}

# Read the most recent user prompt text from recent_prompts.jsonl.
# Returns empty string when the file is absent or unreadable, OR when
# prompt persistence is disabled via `prompt_persist=off` (the producer
# in prompt-intent-router.sh skips the append in that mode, so the file
# absence already covers the disabled path — the explicit guard is
# defensive against pre-existing files from a prior `prompt_persist=on`
# session and against tests that pre-seed the JSONL).
_read_most_recent_prompt() {
  is_prompt_persist_enabled || return 0
  local file
  file="$(session_file "recent_prompts.jsonl")"
  [[ -f "${file}" ]] || return 0
  tail -n 1 "${file}" 2>/dev/null | jq -r '.text // ""' 2>/dev/null || true
}

# Verify the destructive verb appears in an imperative-tail position
# within the prompt — followed by an object marker (article|preposition|
# temporal|conjunction) OR at end-of-prompt with optional sentence-
# terminating punctuation. Rejects noun usages like "the commit message"
# (followed by `message`, not in the marker list) and "commit-message
# style" (the `-` in front of `commit` fails the prefix anchor).
_verb_appears_in_imperative_position() {
  local text="$1"
  local verb="$2"
  [[ -z "${text}" || -z "${verb}" ]] && return 1

  local nocase_was_set=0
  if shopt -q nocasematch; then nocase_was_set=1; else shopt -s nocasematch; fi
  local result=1

  if [[ "${verb}" == "gh-publish" ]]; then
    # gh publish-class verbs: any of open|create|publish|release|ship in
    # the prompt with an object marker authorizes any destructive gh
    # pr/release/issue create-class op. Narrower than "any imperative"
    # because those verbs can be advisory in product-shaped prompts.
    if [[ "${text}" =~ (^|[^a-z-])(open|create|publish|release|ship|merge|close|edit)[[:space:]]+(a|an|the|this|these|that|those|new|pr|prs|pull[[:space:]]+request|release|issue|issues|tag|comment|it|them) ]]; then
      result=0
    fi
  else
    # Object-marker tail OR end-of-prompt match. The `(^|[^a-z-])` prefix
    # anchors so `commit` matches at word boundary but NOT inside
    # `commit-message` or `precommit`. The trailing alternation accepts
    # imperative-tail object markers, end-of-prompt, or sentence-end
    # punctuation. Also accepts the standalone bare verb (e.g., a
    # follow-up imperative immediately after a misclassified initial
    # prompt — the canonical recovery path when the classifier misroutes).
    local pat="(^|[^a-z-])${verb}([[:space:]]+(the|a|an|all|these|this|that|those|to|origin|upstream|v[0-9]|it|them|changes?|and|when|if|as|onto|main|master)|[[:space:]]*[.,;!?]?[[:space:]]*$)"
    if [[ "${text}" =~ ${pat} ]]; then
      result=0
    fi
  fi

  if [[ "${nocase_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

# Re-run the (post-Wave-1) classifier against the raw prompt and verify
# every destructive non-allowed segment in the command is authorized by
# the prompt text. Returns 0 (authorize) only when both halves agree.
_prompt_text_authorizes_command() {
  local cmd_normalized="$1"
  local prompt
  prompt="$(_read_most_recent_prompt)"
  [[ -n "${prompt}" ]] || return 1

  # The prompt must register as imperative — noun-only mentions of a
  # destructive verb (e.g., "explain commit hooks", "review the merge
  # request") never trigger the override.
  is_imperative_request "${prompt}" || return 1

  local _seg verb
  while IFS= read -r _seg; do
    [[ -z "${_seg// }" ]] && continue
    if _cmd_matches_destructive "${_seg}" && ! _cmd_is_allowed_variant "${_seg}"; then
      verb="$(_extract_destructive_verb_from_segment "${_seg}")"
      [[ -n "${verb}" ]] || return 1
      if ! _verb_appears_in_imperative_position "${prompt}" "${verb}"; then
        return 1
      fi
    fi
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"${cmd_normalized}")
  return 0
}

# v1.34.0 (Bug C split): commit_segment matcher narrows to git
# commit-class only. push_segment matcher covers git push|tag and
# gh pr/release/issue ops. Each is checked against its own contract
# mode so a "commit X. don't push Y." prompt allows the commit.
_commit_segment_forbidden() {
  local seg="$1"
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+commit([[:space:]]|$)" <<<"${seg}"; then
    return 0
  fi
  return 1
}

_push_segment_forbidden() {
  local seg="$1"
  if grep -Eq "${_GUARD_PRE}git[[:space:]]+(push|tag)([[:space:]]|$)" <<<"${seg}"; then
    return 0
  fi
  if grep -Eq "${_GUARD_PRE}gh[[:space:]]+(pr|release|issue)[[:space:]]+(create|merge|edit|close|comment|delete|reopen)([[:space:]]|$)" <<<"${seg}"; then
    return 0
  fi
  return 1
}

if [[ "${commit_contract_mode}" == "forbidden" ]]; then
  _commit_denied_segment=""
  while IFS= read -r _seg; do
    [[ -z "${_seg// }" ]] && continue
    if _cmd_matches_destructive "${_seg}" && ! _cmd_is_allowed_variant "${_seg}" && _commit_segment_forbidden "${_seg}"; then
      _commit_denied_segment="${_seg}"
      break
    fi
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"${normalized_cmd}")

  if [[ -n "${_commit_denied_segment}" ]]; then
    log_hook "pretool-intent-guard" "blocked by commit contract: cmd=$(truncate_chars 80 "${command_str}")"
    record_gate_event "commit-contract" "block" \
      "mode=forbidden" \
      "intent=${task_intent:-unset}" \
      "denied_segment=$(truncate_chars 120 "${_commit_denied_segment}")"
    jq -nc --arg reason "[Commit-contract gate] the active ULW contract says not to commit from this run. Do the work, verify it, and stop without creating commits. If the user wants a commit after all, they need to say so explicitly in a new prompt. Attempted command: $(truncate_chars 200 "${command_str}")" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

if [[ "${push_contract_mode}" == "forbidden" ]]; then
  _push_denied_segment=""
  while IFS= read -r _seg; do
    [[ -z "${_seg// }" ]] && continue
    if _cmd_matches_destructive "${_seg}" && ! _cmd_is_allowed_variant "${_seg}" && _push_segment_forbidden "${_seg}"; then
      _push_denied_segment="${_seg}"
      break
    fi
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"${normalized_cmd}")

  if [[ -n "${_push_denied_segment}" ]]; then
    log_hook "pretool-intent-guard" "blocked by push contract: cmd=$(truncate_chars 80 "${command_str}")"
    record_gate_event "push-contract" "block" \
      "mode=forbidden" \
      "intent=${task_intent:-unset}" \
      "denied_segment=$(truncate_chars 120 "${_push_denied_segment}")"
    jq -nc --arg reason "[Push-contract gate] the active ULW contract says not to push, tag, or publish from this run (commit is allowed if the contract permits). Stop the destructive segment; if the user wants a publish action after all, they need to say so explicitly in a new prompt. Attempted command: $(truncate_chars 200 "${command_str}")" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
fi

# v1.34.0 (Bug C wave-2 fix): under execution intent, the only reason
# the script reached this point is that a contract mode is forbidden
# but the segment didn't match the contract's verb. The destructive-op
# gate below this comment is meant for advisory / session-management /
# checkpoint intents where every destructive op needs explicit
# authorization. Under execution intent the user has already authorized
# work; the contract checks above are the precise enforcement.
if [[ "${intent_guard_active}" -eq 0 ]]; then
  exit 0
fi

if _wave_execution_active && _wave_override_command_safe "${normalized_cmd}"; then
  # Extract the active wave's metadata for the gate-event details so
  # /ulw-report can attribute each override to a specific wave (which
  # surface it authorized, position in the plan). Without this, the
  # event records only intent + denied_segment and the cross-session
  # report shows aggregate counts with no link back to the wave that
  # justified the override. Pull the *first* in_progress-or-pending
  # wave; that's the wave the per-wave commit is most likely targeting.
  # Defaults are empty strings (jq `// ""`) so a missing/legacy plan
  # shape never crashes the override path.
  _wave_meta_file="$(session_file "findings.json")"
  _wave_index="$(jq -r '
    [(.waves // [])[] | select(.status == "in_progress" or .status == "pending")][0].index // ""
  ' "${_wave_meta_file}" 2>/dev/null || printf '')"
  _wave_total="$(jq -r '
    [(.waves // [])[] | select(.status == "in_progress" or .status == "pending")][0].total // ""
  ' "${_wave_meta_file}" 2>/dev/null || printf '')"
  _wave_surface="$(jq -r '
    [(.waves // [])[] | select(.status == "in_progress" or .status == "pending")][0].surface // ""
  ' "${_wave_meta_file}" 2>/dev/null || printf '')"
  log_hook "pretool-intent-guard" \
    "wave-active override: intent=${task_intent} wave=${_wave_index}/${_wave_total} cmd=$(truncate_chars 80 "${command_str}")"
  record_gate_event "pretool-intent" "wave_override" \
    "intent=${task_intent}" \
    "wave_index=${_wave_index}" \
    "wave_total=${_wave_total}" \
    "wave_surface=$(truncate_chars 60 "${_wave_surface}")" \
    "denied_segment=$(truncate_chars 120 "${denied_segment}")"
  exit 0
fi

# Prompt-text trust override (v1.23.0). Evaluated after the wave-active
# override so the wave-specific path still takes precedence when both
# would apply (the wave override has tighter audit metadata). When the
# wave path doesn't fire, the prompt-text path is the next line of
# defense — it converts the user's explicit imperative into authorization
# even if the classifier said advisory.
if [[ "${OMC_PROMPT_TEXT_OVERRIDE:-on}" == "on" ]] \
    && _prompt_text_authorizes_command "${normalized_cmd}"; then
  log_hook "pretool-intent-guard" \
    "prompt-text override: intent=${task_intent} cmd=$(truncate_chars 80 "${command_str}")"
  # When prompt_persist is on, capture a 120-char preview into the
  # gate-event row for live debugging. When off, the field is omitted
  # entirely — keeps the cross-session gate_events.jsonl free of prompt
  # text after the TTL sweep lifts rows. The denied_segment is always
  # captured (truncated to 120) because it is the command string the
  # user typed at the model, not the user's verbatim prompt.
  if is_prompt_persist_enabled; then
    _pt_prompt_preview="$(_read_most_recent_prompt | tr '\n' ' ')"
    record_gate_event "pretool-intent" "prompt_text_override" \
      "intent=${task_intent}" \
      "denied_segment=$(truncate_chars 120 "${denied_segment}")" \
      "prompt_preview=$(truncate_chars 120 "${_pt_prompt_preview}")"
  else
    record_gate_event "pretool-intent" "prompt_text_override" \
      "intent=${task_intent}" \
      "denied_segment=$(truncate_chars 120 "${denied_segment}")"
  fi
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
  # v1.34.1+ (X-008): collaborative tone, recovery-first ordering. The
  # full "do not phrase the next message as a permission prompt" rationale
  # belongs in core.md (Claude-facing instructions), not in user-visible
  # block reasons — users seeing this gate fire are most likely already
  # frustrated by a misclassification, so we lead with the recovery path
  # instead of a list of forbidden behaviors. The two canonical FORBIDDEN
  # snippets ('Should I proceed', 'Would you like me to') are still
  # cited inline so the cross-script drift net in
  # tests/test-pretool-intent-guard.sh T19 stays intact (the same drift
  # net guards session-start-compact-handoff.sh).
  reason="[PreTool gate · ${intent_label} · block 1] The active prompt is classified as '${intent_label}', not execution. Destructive git/gh ops (commit/push/reset --hard/rebase/cherry-pick/tag/merge/branch -D/clean -f/update-ref/filter-branch + gh pr|release|issue create/merge/edit/close) need explicit execution authorization.
Recovery options:
  → If you intended this op: re-state the concrete imperative ('commit X', 'push to origin', etc.); the prompt-text override should pick it up. If you believe the classifier got it wrong, ask the user to clarify in their own words — never manufacture text for them to repeat back (that's the puppeteering anti-pattern).
  → If misclassified: deliver the ${intent_label} response the user asked for — assessment/recommendation/checkpoint — and let them request execution next. Do not invent a manual permission gate (core.md FORBIDDEN: 'Should I proceed?' / 'Would you like me to ...?' loops — the user's words ARE the authorization).
  → Bypass the gate once: /ulw-skip <reason>.
Attempted: $(truncate_chars 200 "${command_str}")"
else
  # Block-N: the user has already seen block-1; just name the gate, the
  # attempted command, and the recovery path. Keep "in their own words"
  # so the puppeteering rule isn't lost on repeat blocks (T12).
  reason="[PreTool gate · ${intent_label} · block ${block_count}] Still classified '${intent_label}' — deliver that response, OR re-state the imperative, OR ask the user to clarify in their own words, OR /ulw-skip <reason>.
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
