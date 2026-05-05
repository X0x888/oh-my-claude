#!/usr/bin/env bash
#
# tools/local-ci.sh — run the CI parity suite inside an Ubuntu
# container so macOS-only env divergence (BSD vs GNU coreutils,
# `mktemp -d` returning `/var/folders/...` vs `/tmp/tmp.XXX`,
# locale defaults, `stat -f` vs `stat -c`, `sed -i` arg shape) is
# caught BEFORE the GitHub Actions round-trip.
#
# v1.33.x (post-mortem of the v1.33.0/.1/.2 cascade): three release
# cycles + ~20 minutes of wall time were burned on a Wave-4
# `claude_bin` denylist firing on Linux's `/tmp/tmp.XXX` mktemp
# output that never reproduced under macOS dev or sterile-env. A
# local Ubuntu container catches that class of bug in ~30s of
# image-cached run time instead of ~3 min of GitHub Actions
# round-trip per cycle. Pairs with the sterile-env TMPDIR fix
# (tests/lib/sterile-env.sh) — sterile-env handles env-shape
# divergence on macOS hosts; this script handles BSD-vs-GNU
# coreutils divergence that sterile-env can't fully simulate.
#
# Usage:
#   bash tools/local-ci.sh                    # run sterile suite + shellcheck
#   bash tools/local-ci.sh --image ubuntu:24.04
#   bash tools/local-ci.sh --shell            # interactive shell in the container (debug)
#   bash tools/local-ci.sh --skip-sterile     # only run shellcheck + JSON validate
#   bash tools/local-ci.sh --skip-shellcheck  # only run sterile suite
#   bash tools/local-ci.sh --help
#
# Env:
#   OMC_LOCAL_CI_IMAGE   override default image (default: ubuntu:24.04)
#   OMC_LOCAL_CI_RUNTIME override docker (default: docker; e.g., podman)
#
# Exit codes:
#   0 — all selected checks pass
#   1 — at least one check failed
#   2 — runtime not available, image unreachable, or arg parse error
#
# Skip via release.sh: `bash tools/release.sh X.Y.Z --skip-local-ci`
# (this script is not yet wired into release.sh's pre-flight; run it
# manually as Pre-flight Step 6.5 between hotfix-sweep and release.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${OMC_LOCAL_CI_IMAGE:-ubuntu:24.04}"
RUNTIME="${OMC_LOCAL_CI_RUNTIME:-docker}"
SHELL_MODE=0
SKIP_STERILE=0
SKIP_SHELLCHECK=0

err() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$1"; }
say() { printf '── %s ───\n' "$1"; }

usage() {
  sed -n '/^#/p' "$0" | sed 's/^#//' | sed 's/^!\/usr.*//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --shell) SHELL_MODE=1; shift ;;
    --skip-sterile) SKIP_STERILE=1; shift ;;
    --skip-shellcheck) SKIP_SHELLCHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1" 2 ;;
  esac
done

# ----------------------------------------------------------------------
# Verify runtime
# ----------------------------------------------------------------------
say "local-ci preflight"

if ! command -v "${RUNTIME}" >/dev/null 2>&1; then
  printf '%s not found in PATH.\n' "${RUNTIME}" >&2
  printf 'Install Docker Desktop (https://docker.com), or set\n' >&2
  printf '  OMC_LOCAL_CI_RUNTIME=podman bash tools/local-ci.sh\n' >&2
  printf 'if you have podman. To skip local CI entirely:\n' >&2
  printf '  bash tools/release.sh X.Y.Z --skip-local-ci  (when wired)\n' >&2
  err "runtime ${RUNTIME} not available" 2
fi

# Verify daemon is responsive. `docker info` returns non-zero when the
# daemon isn't running (Docker Desktop not started); podman is daemonless
# but `info` still works as a smoke check.
if ! "${RUNTIME}" info >/dev/null 2>&1; then
  printf '%s daemon not responding. ' "${RUNTIME}" >&2
  if [[ "${RUNTIME}" == "docker" ]]; then
    printf 'Start Docker Desktop and retry.\n' >&2
  else
    printf 'Check `%s info` output for hints.\n' "${RUNTIME}" >&2
  fi
  err "${RUNTIME} not responsive" 2
fi

ok "${RUNTIME} available"

# ----------------------------------------------------------------------
# In-container script generators. Two layers:
#
#   build_prepare_script   — apt-install deps + extract repo tarball
#                            into /work. Runs in BOTH the normal CI run
#                            and the --shell debug path so the
#                            interactive shell has the same toolchain
#                            (jq/shellcheck/python3/perl) the non-shell
#                            run gets. v1.33.x reviewer-driven fix:
#                            pre-fix `--shell` only did mkdir+tar+exec
#                            so a fresh ubuntu:24.04 dropped the user
#                            into a shell with no shellcheck, no jq,
#                            no python3 — useless for reproducing a
#                            failure that needs the toolchain.
#
#   build_run_checks_script — execute validate.yml's check list
#                            (`shellcheck` on `bundle/`, JSON validate,
#                            sterile-env, python tests). Composed with
#                            build_prepare_script in normal mode.
#
# Stays in sync with .github/workflows/validate.yml: same entry points,
# not a subset. Skip toggles (SKIP_STERILE, SKIP_SHELLCHECK) plumbed
# through env vars to the container.
# ----------------------------------------------------------------------
build_prepare_script() {
  cat <<'PREPARE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Idempotent dep install — `command -v` checks before invoking apt so
# repeat runs against an already-prepared image are network-free.
need_install=""
for pkg in jq rsync shellcheck git perl python3; do
  if ! command -v "${pkg}" >/dev/null 2>&1; then
    need_install="${need_install} ${pkg}"
  fi
done
if [[ -n "${need_install}" ]]; then
  apt-get update -qq >/dev/null
  # shellcheck disable=SC2086
  apt-get install -qq -y ${need_install} >/dev/null
fi

mkdir -p /work
tar -xf /work.tar -C /work
cd /work
PREPARE
}

build_run_checks_script() {
  cat <<'CHECKS'

# v1.33.x: keep the in-container check list in lockstep with
# .github/workflows/validate.yml. The script intentionally calls the
# same entry points CI calls, not a subset.

if [[ "${SKIP_SHELLCHECK:-0}" != "1" ]]; then
  printf '── shellcheck ───\n'
  find bundle/ -name '*.sh' -print0 | xargs -0 shellcheck -x --severity=warning
  printf '\033[32m✓\033[0m shellcheck clean\n'

  printf '── JSON validate ───\n'
  find . -name '*.json' -not -path './.git/*' -print0 | xargs -0 -n1 python3 -m json.tool --no-ensure-ascii > /dev/null
  printf '\033[32m✓\033[0m JSON valid\n'
fi

if [[ "${SKIP_STERILE:-0}" != "1" ]]; then
  printf '── sterile-env CI parity ───\n'
  bash tests/run-sterile.sh
fi

printf '── python tests ───\n'
python3 -m unittest tests.test_statusline 2>&1 | tail -3
CHECKS
}

# ----------------------------------------------------------------------
# Materialize the in-container scripts.
#
# Volumes: the tarball is bind-mounted READ-ONLY into the container at
# `/work.tar`; the container extracts content into a container-local
# `/work` dir. Net effect: the host repo isn't mutated even though the
# tarball file IS bind-mounted (read-only). This keeps the host clean
# without paying the cost of `docker cp` per-run.
# ----------------------------------------------------------------------
prepare_script="$(build_prepare_script)"
checks_script="$(build_run_checks_script)"

say "Packing repo for container"

repo_tarball="$(mktemp -t omc-localci-tar.XXXXXX)"
trap 'rm -f "${repo_tarball}"' EXIT
# v1.33.x reviewer-driven fix: feed paths to tar via `-T` (path file)
# instead of `xargs -0 tar -cf`. xargs splits its argv on very large
# input — each split invocation of `tar -cf` would TRUNCATE rather
# than append to the same archive, silently dropping files past the
# first invocation. -T reads the path list directly without splitting.
# Today's repo (~237 files) fits in one xargs invocation, so the bug
# is latent — switching to -T is a defensive correctness fix, not a
# regression repair. Path list materialized via process substitution
# from `git ls-files -z` (so untracked-but-cached and tracked-modified
# files all flow through). `tr '\0' '\n'` because GNU tar's `-T` reads
# newline-separated by default; --null variants exist but vary across
# BSD tar / GNU tar / busybox tar.
if ! ( cd "${REPO_ROOT}" && \
  tar -cf "${repo_tarball}" \
    -T <(git ls-files -z --cached --others --exclude-standard 2>/dev/null | tr '\0' '\n') \
    2>/dev/null ); then
  err "failed to tar repo (is REPO_ROOT a git repo?)"
fi

# Portable byte-count: `wc -c <` strips the filename so awk sees only
# the count even on macOS BSD wc (which prepends whitespace).
ok "repo packed ($(wc -c < "${repo_tarball}" | awk '{print int($1/1024)}') KB)"

if [[ "${SHELL_MODE}" -eq 1 ]]; then
  say "Interactive shell in ${IMAGE}"
  printf 'Repo is at /work inside the container with full toolchain.\n'
  printf 'Exit shell to clean up.\n'
  # v1.33.x reviewer-driven fix: include the prepare_script (apt-install
  # + tar extract) so the debug shell has the same toolchain as the
  # non-shell run. Pre-fix the user landed in `bash` with no jq,
  # no python3, and no `shellcheck`, defeating the purpose of the
  # debug path — they couldn't reproduce the failure they were
  # trying to inspect. The `exec bash` at the end keeps the shell
  # interactive after prepare completes.
  "${RUNTIME}" run --rm -it \
    -v "${repo_tarball}:/work.tar:ro" \
    -e "OMC_LOCAL_CI=1" \
    "${IMAGE}" \
    bash -c "${prepare_script}
exec bash"
  exit 0
fi

say "Running CI parity suite in ${IMAGE}"

# Pass the toggles into the container as env vars.
if "${RUNTIME}" run --rm \
  -v "${repo_tarball}:/work.tar:ro" \
  -e "OMC_LOCAL_CI=1" \
  -e "SKIP_STERILE=${SKIP_STERILE}" \
  -e "SKIP_SHELLCHECK=${SKIP_SHELLCHECK}" \
  "${IMAGE}" \
  bash -c "${prepare_script}
${checks_script}"; then
  ok "local-ci passed in ${IMAGE}"
  exit 0
else
  rc=$?
  printf '\n\033[31m✗\033[0m local-ci failed in %s (exit %d)\n' "${IMAGE}" "${rc}" >&2
  printf '  Reproduce interactively: bash tools/local-ci.sh --shell --image %s\n' "${IMAGE}" >&2
  exit 1
fi
