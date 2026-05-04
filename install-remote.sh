#!/usr/bin/env bash
# install-remote.sh — bootstrapper for `curl … | bash` installs of oh-my-claude.
#
# This is the thin wrapper that the public one-liner pulls. It clones (or
# updates) the source repo to a stable user-owned location, then hands off
# to the project's real install.sh. Hosting the bootstrapper separately
# means users can run a single command from a fresh terminal — no
# pre-cloned repo, no working directory expectation — and pass standard
# install.sh flags through.
#
# Public invocation (when this file is hosted at a known URL):
#
#   curl -fsSL <hosted-url>/install-remote.sh | bash
#   curl -fsSL <hosted-url>/install-remote.sh | bash -s -- --no-ios
#   curl -fsSL <hosted-url>/install-remote.sh | bash -s -- --bypass-permissions
#
# Local invocation (for testing this script):
#
#   bash install-remote.sh           # standard install
#   bash install-remote.sh --no-ios  # passes through to install.sh
#
# Environment overrides:
#   OMC_SRC_DIR  — where to clone the source repo (default: ~/.local/share/oh-my-claude)
#   OMC_REPO_URL — git URL to clone (default: https://github.com/X0x888/oh-my-claude.git)
#   OMC_REF      — git ref to checkout (default: main)
#
# Failure modes are loud, not silent: missing prereqs print actionable
# messages and exit non-zero before any clone is attempted.

set -euo pipefail

OMC_DEFAULT_REPO_URL="https://github.com/X0x888/oh-my-claude.git"
OMC_SRC_DIR="${OMC_SRC_DIR:-${HOME}/.local/share/oh-my-claude}"
OMC_REPO_URL="${OMC_REPO_URL:-${OMC_DEFAULT_REPO_URL}}"
OMC_REF="${OMC_REF:-main}"

bold()   { printf '\033[1m%s\033[0m' "$1"; }
red()    { printf '\033[31m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }

err() {
  printf '%s %s\n' "$(red 'error:')" "$1" >&2
  exit 1
}

# --- Prereq check -----------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || \
    err "missing required command: $1. Install it (e.g. via your package manager) and retry."
}

# v1.31.0 Wave 7 (growth-lens F-035): jq is the most common missing
# prereq for first-time installs (macOS ships without it; many Linux
# distros ship without it too). Pre-Wave-7 the script hard-failed,
# which is correct UX (fail loud, not silent) but produced an
# avoidable abandonment surface for users who would have happily
# said "yes" to a one-line install. The auto-install offer is
# explicitly opt-in: prints the platform-specific command and prompts
# Y/N before running. Skipped under OMC_BOOTSTRAP_NO_AUTOINSTALL=1
# (env override for sandboxed/regulated environments).
maybe_auto_install_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  if [[ -n "${OMC_BOOTSTRAP_NO_AUTOINSTALL:-}" ]]; then
    return 1
  fi

  local install_cmd=""
  case "$(uname 2>/dev/null || echo '')" in
    Darwin)
      command -v brew >/dev/null 2>&1 && install_cmd="brew install jq"
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        install_cmd="sudo apt-get update && sudo apt-get install -y jq"
      elif command -v dnf >/dev/null 2>&1; then
        install_cmd="sudo dnf install -y jq"
      elif command -v yum >/dev/null 2>&1; then
        install_cmd="sudo yum install -y jq"
      elif command -v apk >/dev/null 2>&1; then
        install_cmd="sudo apk add jq"
      elif command -v pacman >/dev/null 2>&1; then
        install_cmd="sudo pacman -S --noconfirm jq"
      fi
      ;;
  esac

  [[ -z "${install_cmd}" ]] && return 1

  printf '\n'
  printf '%s jq is required but not installed.\n' "$(yellow 'note:')"
  printf '         Detected install command: %s\n' "${install_cmd}"
  printf '         Run it now? '
  printf '%s' "$(bold 'y/N: ')"
  local response=""
  if [[ -t 0 ]]; then
    read -r response
  else
    printf '(skipped — non-interactive)\n'
    return 1
  fi
  case "${response}" in
    [yY]|[yY][eE][sS])
      printf '%s running: %s\n' "$(bold '==>')" "${install_cmd}"
      eval "${install_cmd}" || return 1
      command -v jq >/dev/null 2>&1
      ;;
    *)
      printf 'Skipped. Install jq manually and re-run install-remote.sh.\n'
      return 1
      ;;
  esac
}

need_cmd git
need_cmd bash
maybe_auto_install_jq || true
need_cmd jq
need_cmd rsync

# --- Clone or update --------------------------------------------------
printf '%s oh-my-claude bootstrapper\n' "$(bold '==>')"
printf '    source repo: %s (ref: %s)\n' "${OMC_REPO_URL}" "${OMC_REF}"
printf '    clone path:  %s\n' "${OMC_SRC_DIR}"

# Custom-URL warning. The bootstrapper is the documented curl-pipe-bash
# entry point — if a user copy-pasted a hostile snippet that overrode
# OMC_REPO_URL, the override should be visually loud rather than just
# part of the normal banner. We print but do not abort: maintainers
# legitimately set this to test forks.
if [[ "${OMC_REPO_URL}" != "${OMC_DEFAULT_REPO_URL}" ]]; then
  printf '    %s OMC_REPO_URL is OVERRIDDEN from default %s\n' \
    "$(yellow 'warning:')" "${OMC_DEFAULT_REPO_URL}"
  printf '             If you did not set this yourself, abort with Ctrl-C now.\n'
fi

# v1.31.0 Wave 3 (security-lens supply-chain hardening): when OMC_REF
# is the rolling default ("main"), probe the remote for the latest
# semver-shaped tag and surface it as a pin recommendation. Rolling
# main has the standard curl-pipe-bash supply-chain risk: a compromised
# maintainer account, branch reset, or hostile commit lands on all
# new installs immediately. Users who explicitly set OMC_REF (to a tag,
# SHA, or even back to "main") opt-out of this prompt — no extra
# noise on intentional rolling installs. Best-effort: skips silently
# when the network is down or git ls-remote fails.
if [[ "${OMC_REF}" == "main" ]] && [[ -z "${OMC_REF_PIN_HINT_SUPPRESS:-}" ]]; then
  _latest_tag="$(git ls-remote --tags --refs "${OMC_REPO_URL}" 2>/dev/null \
    | awk '{print $2}' \
    | sed -E 's|refs/tags/||' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1 \
    || true)"
  if [[ -n "${_latest_tag}" ]]; then
    printf '    %s OMC_REF=main is rolling. To pin to the latest released tag:\n' "$(yellow 'tip:')"
    printf '             OMC_REF=%s bash install-remote.sh\n' "${_latest_tag}"
    printf '             (Set OMC_REF_PIN_HINT_SUPPRESS=1 to silence this hint.)\n'
  fi
  unset _latest_tag
fi
printf '\n'

# Parallel-run guard. A user who double-pastes the curl one-liner (or a
# script that invokes the bootstrapper twice) would otherwise race two
# clone/fetch/reset sequences against the same OMC_SRC_DIR with
# unpredictable results (corrupt working tree, half-fetched install.sh).
# Use mkdir-based lock — portable across macOS/Linux without depending
# on `flock`, mirroring the pattern in common.sh.
LOCKDIR="${OMC_SRC_DIR}.bootstrap.lock"
mkdir -p "$(dirname "${OMC_SRC_DIR}")"
if ! mkdir "${LOCKDIR}" 2>/dev/null; then
  err "another bootstrapper run holds ${LOCKDIR}. Wait for it to finish, or remove the directory manually if the prior run died."
fi
trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT INT TERM

if [[ -d "${OMC_SRC_DIR}/.git" ]]; then
  printf '%s updating existing clone...\n' "$(bold '==>')"
  git -C "${OMC_SRC_DIR}" fetch --quiet origin "${OMC_REF}" \
    || err "git fetch failed. Check network and repo URL."
  # Reset only when on the target ref AND tree is clean — otherwise leave
  # the user's worktree alone so a maintainer's local changes aren't lost.
  current_ref="$(git -C "${OMC_SRC_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [[ "${current_ref}" == "${OMC_REF}" ]] \
      && [[ -z "$(git -C "${OMC_SRC_DIR}" status --porcelain)" ]]; then
    git -C "${OMC_SRC_DIR}" reset --quiet --hard "origin/${OMC_REF}" \
      || err "git reset failed."
  else
    printf '    %s tree is on %q or has local changes — skipping reset, using current state.\n' \
      "$(yellow 'note:')" "${current_ref}"
  fi
else
  printf '%s cloning into %s ...\n' "$(bold '==>')" "${OMC_SRC_DIR}"
  # Default to a shallow clone for first-time installs — meaningful first-
  # impression win on slow links. Maintainers who want full history can
  # set OMC_REF to a non-default ref (e.g., a tag or commit SHA) which
  # falls through to the deep-clone branch below.
  if [[ "${OMC_REF}" == "main" ]]; then
    git clone --quiet --depth=1 --branch "${OMC_REF}" "${OMC_REPO_URL}" "${OMC_SRC_DIR}" \
      || err "git clone failed. Check network and repo URL."
  else
    git clone --quiet --branch "${OMC_REF}" "${OMC_REPO_URL}" "${OMC_SRC_DIR}" \
      || err "git clone failed. Check network and repo URL."
  fi
fi

# --- Hand off to install.sh ------------------------------------------
INSTALLER="${OMC_SRC_DIR}/install.sh"
[[ -f "${INSTALLER}" ]] || err "install.sh not found at ${INSTALLER}. Wrong ref?"

printf '\n%s running %s ...\n' "$(bold '==>')" "${INSTALLER}"
printf '    pass-through args: %s\n\n' "${*:-(none)}"
bash "${INSTALLER}" "$@"

printf '\n%s done. Source repo lives at %s — re-run this bootstrapper to update.\n' \
  "$(green '==>')" "${OMC_SRC_DIR}"
