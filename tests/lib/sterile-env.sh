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

  sterile_home="$(mktemp -d)" || return 1
  sterile_tmp="${sterile_home}/tmp"
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

# cleanup_sterile_env DIR — best-effort recursive delete. Tests should
# call this in a trap when they want the sterile HOME removed; the
# default mktemp -d under TMPDIR/$TMPDIR is auto-swept by the OS
# eventually, so this is hygiene, not correctness.
cleanup_sterile_env() {
  local sterile_home="$1"
  if [[ -n "${sterile_home}" && -d "${sterile_home}" && "${sterile_home}" == */tmp* ]]; then
    rm -rf "${sterile_home}" 2>/dev/null || true
  fi
}
