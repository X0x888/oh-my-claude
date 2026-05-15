# shellcheck shell=bash
#
# tests/lib/sterile-env.sh — sterile-env wrapper for CI-parity local runs.
#
# v1.32.0 R3 (release post-mortem remediation): the v1.31.0 → v1.31.1
# cascade had T7 in test-show-status.sh pass on macOS dev (where the
# user's STATE_ROOT had real sessions populating the matched substring)
# but fail on Ubuntu CI (empty STATE_ROOT, different output text).
# Pre-tag CI parity is supposed to catch this; in practice the dev
# shell inherits STATE_ROOT, HOME, OMC_*, GIT_*, and 50 other vars
# the test author may not have anticipated, so "ran tests locally,
# they passed" is a weak signal compared to "ran tests under env
# scrubbed to look like CI".
#
# This helper provides build_sterile_env() — emits an env-prefix
# command that, when used as `env $(build_sterile_env) bash test.sh`,
# strips inherited state and provides a known-clean baseline.
#
# Critical correctness note (metis stress-test finding):
# The naive choice `env -i HOME=tmp PATH=/usr/bin:/bin` BREAKS jq
# discovery on macOS dev where jq lives at /opt/homebrew/bin/jq. The
# helper detects jq's actual install dir at runtime and prefixes it
# to PATH so sterile-PATH still finds the same jq the dev shell
# does. CI's Ubuntu runner has jq in /usr/bin, so the same logic
# resolves to /usr/bin:/bin there.

# build_sterile_env — emit `KEY=VALUE` pairs for `env -i ${OUTPUT}`.
# Returns 0 on success. Caller responsibility: pass result to env -i
# (or eval it after `export`-ing each line).
#
# Scrubs: STATE_ROOT, SESSION_ID, OMC_*, XDG_*, GIT_AUTHOR_*,
#         GIT_COMMITTER_*, CLAUDE_HOME, COMMON_SH (test-runner internal)
# Preserves (positive allowlist): TERM, USER, LANG, LC_ALL, LOGNAME, SHELL
# Sets fresh: HOME=$(mktemp -d), TMPDIR=$HOME/tmp, STATE_ROOT=$HOME/state,
#             PATH=<jq-dir>:<system-paths>
build_sterile_env() {
  local sterile_home sterile_tmp jq_path jq_dir path

  # HOME — anchor under the OUTER ${HOME}/.cache so sterile-env stays
  # outside any /tmp/-rooted path-prefix denylist on every host. The
  # bare `mktemp -d` default (macOS: `/var/folders/.../tmp.XXX`;
  # Linux: `/tmp/tmp.XXX`) was the wrong default on Linux — it
  # landed sterile HOME under /tmp/ which is MORE hostile than real
  # CI (where HOME=/home/runner) and contradicts the explicit
  # "sterile is not supposed to be more hostile than CI" goal of
  # T6 in test-sterile-env.sh.
  #
  # v1.34.0: anchor at ${HOME}/.cache/omc-sterile-home-XXXXXX so the
  # parent is always under the user's HOME dir (which is NEVER under
  # /tmp on macOS, Linux dev, or GitHub Actions runners — `/Users/x`,
  # `/home/x`, or `/home/runner` respectively). This is the same
  # ORIG_HOME-anchored pattern the v1.33.1/.2 hotfix used for the
  # T24 pin-location escape.
  # Defensive: HOME is normally always set, but Docker containers and
  # `env -i ...` invocations may strip it. Fall back to the directory
  # of the test runner's user (POSIX `getent` lookup) or — last resort —
  # `mktemp -d` under TMPDIR (which on Linux CI lands under /tmp/, so
  # T6's HOME-shape assertion would fail; that is the worst case but
  # still better than mkdir against an empty path).
  local _sterile_parent
  if [[ -n "${HOME:-}" ]]; then
    _sterile_parent="${HOME}/.cache"
  else
    _sterile_parent="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)/.cache"
    [[ "${_sterile_parent}" == "/.cache" ]] && _sterile_parent=""
  fi
  if [[ -z "${_sterile_parent}" ]]; then
    sterile_home="$(mktemp -d)" || return 1
  else
    mkdir -p "${_sterile_parent}" 2>/dev/null
    sterile_home="$(mktemp -d "${_sterile_parent}/omc-sterile-home-XXXXXX")" || return 1
  fi
  # TMPDIR — force under `/tmp/` on every host so subsequent
  # `mktemp -d` calls inside tests mimic Linux CI's `/tmp/tmp.XXX`
  # shape regardless of macOS dev's `/var/folders/...` default.
  # v1.33.x post-mortem: the v1.33.0/.1/.2 cascade was driven by
  # Wave-4's `claude_bin` denylist (rejects pins under /tmp/,
  # /private/tmp/, /var/tmp/, /Users/Shared/, /dev/shm/) firing on
  # Ubuntu CI's `/tmp/tmp.XXX` mktemp output but never on the
  # sterile-env local proxy because TMPDIR was previously pointed
  # inside sterile_home (so mktemp output landed under
  # /var/folders/.../tmp on macOS). Forcing TMPDIR under `/tmp/`
  # captures the path-prefix denylist class without dragging HOME
  # itself under /tmp (which would over-fire on tests that derive
  # paths from ${HOME} or ORIG_HOME — those would never trigger on
  # real CI's /home/runner).
  sterile_tmp="$(mktemp -d /tmp/omc-sterile-tmp-XXXXXX)" || return 1
  mkdir -p "${sterile_tmp}" 2>/dev/null

  # PATH discovery: find jq from the live PATH, prefix its directory.
  # Falls back to system paths only when jq isn't in PATH at all
  # (CI runner without jq installed — different problem, fail fast).
  # The /opt/homebrew/bin entry handles the macOS-dev case where
  # build_sterile_env runs from a shell with /opt/homebrew/bin in PATH.
  jq_path="$(command -v jq 2>/dev/null || true)"
  if [[ -n "${jq_path}" ]]; then
    jq_dir="$(dirname "${jq_path}")"
    # /sbin and /usr/sbin needed for macOS `md5` (at /sbin/md5).
    # Linux md5sum is in /usr/bin which is already covered.
    if [[ "${jq_dir}" == "/opt/homebrew/bin" ]]; then
      path="${jq_dir}:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
    else
      path="${jq_dir}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
    fi
  else
    # No jq found — sterile run will fail loudly (correct: most
    # tests need jq). Still return a non-broken PATH so the failure
    # is the test's, not env-init's.
    path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"
  fi

  # Preserve a minimal positive allowlist. TERM keeps colored output
  # readable; LANG/LC_ALL pin the locale (avoids the wc -m
  # byte-vs-char divergence that motivated lib/test-env-isolate.sh).
  #
  # v1.32.2 (R9 cleanup): do NOT pre-set STATE_ROOT or SESSION_ID.
  # The harness's common.sh derives STATE_ROOT from
  # `${HOME}/.claude/quality-pack/state` when unset; tests that need
  # an explicit STATE_ROOT set it themselves via TEST_STATE_ROOT.
  # Pre-setting STATE_ROOT to ${HOME}/state in pre-1.32.2 broke 7
  # tests (test-e2e-hook-sequence, test-phase8-integration,
  # test-gate-events, test-stop-failure-handler,
  # test-session-start-resume-hint, test-claim-resume-request,
  # test-resume-watchdog) whose handlers compute state paths from
  # HOME and got steered to a path with no .claude/quality-pack/state
  # parent. Same logic for SESSION_ID — the harness treats unset and
  # empty differently in some paths, and `SESSION_ID=` with an empty
  # value forced the empty-but-set branch when tests expected the
  # unset branch.
  printf 'HOME=%s\n' "${sterile_home}"
  printf 'TMPDIR=%s\n' "${sterile_tmp}"
  printf 'PATH=%s\n' "${path}"
  printf 'TERM=%s\n' "${TERM:-xterm-256color}"
  printf 'LANG=%s\n' "${LANG:-en_US.UTF-8}"
  printf 'LC_ALL=%s\n' "${LC_ALL:-en_US.UTF-8}"
  printf 'USER=%s\n' "${USER:-tester}"
  printf 'LOGNAME=%s\n' "${LOGNAME:-tester}"
  printf 'SHELL=%s\n' "${SHELL:-/bin/bash}"
  # Git identity — required by `git commit` calls in fixture-repo
  # tests. Without this, env -i strips the author identity from
  # the user's global git config and `git commit` fails. The test
  # author's identity isn't load-bearing for assertions; "Sterile
  # Tester" is fine.
  printf 'GIT_AUTHOR_NAME=Sterile Tester\n'
  printf 'GIT_AUTHOR_EMAIL=sterile@oh-my-claude.test\n'
  printf 'GIT_COMMITTER_NAME=Sterile Tester\n'
  printf 'GIT_COMMITTER_EMAIL=sterile@oh-my-claude.test\n'
}

# cleanup_sterile_env HOME [TMP] — best-effort recursive delete of the
# sterile-env scratch paths. Tests should call this in a trap. Two
# args: the sterile HOME dir (created under ${HOME}/.cache/
# omc-sterile-home-XXX) and OPTIONALLY the sterile TMPDIR (created
# under /tmp/omc-sterile-tmp-XXX). The TMP arg was added in v1.40.x
# after the harness shipped with 56 orphan `/tmp/omc-sterile-tmp-*`
# dirs on a dev host — `build_sterile_env` creates that dir but its
# subshell-capture output pattern (`sterile_env="$(build_sterile_env)"`)
# means the parent shell only saw the PRINTED env lines, not the
# created paths as variables. The caller could parse HOME and TMPDIR
# out of the printed lines but had no documented way to clean both.
# Callers that pass only one arg get the v1.34+ HOME-only behavior;
# callers that pass both get the full cleanup.
#
# The path-prefix guard prevents a typo'd argument from blast-radius
# extending into a real directory. Matches paths that look like
# something `build_sterile_env` itself would have created:
#   v1.34.0+ — `*/omc-sterile-home-*` under `${HOME}/.cache`
#   pre-v1.34.0 legacy — `*/tmp*` (kept for forward-compat with any
#                        test that still passes the older shape)
#   v1.40.x+ — `*/omc-sterile-tmp-*` under `/tmp/` (the second arg)
# Anything else is silently rejected — never recursive-delete a path
# that doesn't match a sterile-* name on its own.
#
# Safety net: the harness ALSO ships a SessionStart hook
# (`bundle/dot-claude/quality-pack/scripts/cleanup-orphan-tmp.sh`)
# that sweeps `/tmp/omc-*` paths older than `orphan_tmp_max_age_hours`
# (default 24h). Callers that forget to pass TMP, or that abort
# before the trap fires, still get eventual cleanup on the next
# session start.
cleanup_sterile_env() {
  local sterile_home="$1"
  local sterile_tmp="${2:-}"

  # v1.34.2 (sterile-CI failure on v1.34.1): anchor the guard at the
  # BASENAME, not anywhere in the path. The pre-fix `*/omc-sterile-
  # home-*` glob matched any path containing that segment — under
  # sterile env where HOME ITSELF is `${OUTER_HOME}/.cache/omc-sterile-
  # home-XXX`, EVERY nested path inherits the sterile-home prefix
  # (e.g., `${HOME}/.cache/omc-cleanup-safety-XXX/something-unrelated`
  # matched and got deleted). The basename check confines the match
  # to the path's last component, where the sterile-home directory
  # actually lives. Both the v1.34.0+ shape (`omc-sterile-home-XXX`)
  # and the test's synthetic legacy (`omc-sterile-legacy-XXX`) match
  # the unified `omc-sterile-*` prefix; the original `*/tmp*` shape
  # is no longer produced by build_sterile_env (v1.34.0 anchor moved
  # sterile_home under ${HOME}/.cache).
  if [[ -n "${sterile_home}" && -d "${sterile_home}" ]]; then
    local _basename="${sterile_home##*/}"
    case "${_basename}" in
      omc-sterile-*)
        rm -rf "${sterile_home}" 2>/dev/null || true
        ;;
    esac
  fi

  # v1.40.x: also clean the /tmp/omc-sterile-tmp-* dir if the caller
  # passed it. Path guard mirrors the HOME guard — basename must
  # match `omc-sterile-*`, parent must be `/tmp/` (re-checked to
  # defend against TOCTOU symlink swaps).
  if [[ -n "${sterile_tmp}" && -d "${sterile_tmp}" ]]; then
    local _tmp_parent _tmp_basename
    _tmp_parent="$(dirname -- "${sterile_tmp}")"
    _tmp_basename="${sterile_tmp##*/}"
    if [[ "${_tmp_parent}" == "/tmp" ]]; then
      case "${_tmp_basename}" in
        omc-sterile-*)
          rm -rf "${sterile_tmp}" 2>/dev/null || true
          ;;
      esac
    fi
  fi
}

# extract_sterile_path KEY ENV_LINES — parse a single env-line key
# out of build_sterile_env's printed output. Used by callers that
# captured `env_lines="$(build_sterile_env)"` and need to recover the
# HOME and TMPDIR paths for an EXIT trap. Example:
#   env_lines="$(build_sterile_env)"
#   sterile_home="$(extract_sterile_path HOME "${env_lines}")"
#   sterile_tmp="$(extract_sterile_path TMPDIR "${env_lines}")"
#   trap 'cleanup_sterile_env "'"${sterile_home}"'" "'"${sterile_tmp}"'"' EXIT
# Output empty string when the key isn't found; never errors.
extract_sterile_path() {
  local key="$1"
  local env_lines="$2"
  printf '%s\n' "${env_lines}" | grep -E "^${key}=" | head -1 | cut -d= -f2-
}
