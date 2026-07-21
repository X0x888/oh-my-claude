#!/usr/bin/env bash
#
# oh-my-claude installer
#
# Installs the oh-my-claude cognitive quality harness into ~/.claude/.
# Backs up existing files before overwriting, merges settings.json safely,
# and optionally installs Ghostty theme/config.
#
# Usage:
#   bash install.sh                    # standard install
#   bash install.sh --bypass-permissions  # also enable bypass-permissions mode
#   bash install.sh --model-tier=economy  # inherit deliberators; Sonnet specialists; live risk escalation
#   bash install.sh --no-ghostty         # skip Ghostty theme/config (v1.36.0)
#   bash install.sh --with-ghostty       # force-install Ghostty even if not detected (v1.36.0)
#   bash install.sh --keep-backups=N     # prune backups, keep canonical decimal N=0..10000 (default 10)
#   bash install.sh --uninstall          # remove oh-my-claude (delegates to uninstall.sh)
#
# Requires: rsync, jq. Uses python3 for JSON merging when available, falls back to jq.

set -euo pipefail

# Disable BASH_ENV-enabled alias expansion before this script's function
# bodies are parsed. POSIX special-builtin lookup lets the real unset/set
# outrank same-named functions; readonly hostile shims fail installation
# closed before any destination mutation.
_OMC_SHA_ALIAS_POSIX_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VALUE=""
if [[ -o posix ]]; then
  _OMC_SHA_ALIAS_POSIX_WAS_SET=1
fi
if [[ "${POSIXLY_CORRECT+x}" == "x" ]]; then
  _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=1
  _OMC_SHA_ALIAS_POSIX_VALUE="${POSIXLY_CORRECT}"
fi
POSIXLY_CORRECT=1 || \exit 1
\unset -f shopt unset set || \exit 1
\shopt -u expand_aliases || \exit 1
if [[ "${_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET}" == "1" ]]; then
  POSIXLY_CORRECT="${_OMC_SHA_ALIAS_POSIX_VALUE}" || \exit 1
else
  \unset POSIXLY_CORRECT || \exit 1
fi
if [[ "${_OMC_SHA_ALIAS_POSIX_WAS_SET}" == "1" ]]; then
  \set -o posix || \exit 1
else
  \set +o posix || \exit 1
fi
\unset _OMC_SHA_ALIAS_POSIX_WAS_SET _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET \
  _OMC_SHA_ALIAS_POSIX_VALUE || \exit 1

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
# macOS exposes ordinary writable roots such as /tmp and /var through system
# symlinks. Keep rejecting a symlink supplied as TARGET_HOME itself, but bind
# an existing real home directory to its physical path once at startup so the
# later ancestor-generation seals do not mistake those platform aliases for a
# destination race.
while [[ "${TARGET_HOME}" != "/" && "${TARGET_HOME}" == */ ]]; do
  TARGET_HOME="${TARGET_HOME%/}"
done
_TARGET_HOME_COMPONENTS="${TARGET_HOME}/"
if [[ "${TARGET_HOME}" == "/" || "${TARGET_HOME}" != /* \
    || "${TARGET_HOME}" == *[[:cntrl:]]* \
    || "${_TARGET_HOME_COMPONENTS}" == */./* \
    || "${_TARGET_HOME_COMPONENTS}" == */../* \
    || ! -d "${TARGET_HOME}" || -L "${TARGET_HOME}" ]]; then
  builtin printf 'Refusing install: TARGET_HOME must be an existing, non-symlink absolute directory.\n' >&2
  exit 1
fi
unset _TARGET_HOME_COMPONENTS
TARGET_HOME="$(builtin cd -- "${TARGET_HOME}" 2>/dev/null \
  && builtin pwd -P)" || exit 1
[[ "${TARGET_HOME}" == /* && "${TARGET_HOME}" != *[[:cntrl:]]* ]] \
  || exit 1
CLAUDE_HOME="${TARGET_HOME}/.claude"
BUNDLE_CLAUDE="${SCRIPT_DIR}/bundle/dot-claude"
BUNDLE_GHOSTTY="${SCRIPT_DIR}/config/ghostty"
GHOSTTY_HOME="${TARGET_HOME}/.config/ghostty"
SETTINGS_PATCH="${SCRIPT_DIR}/config/settings.patch.json"
OMC_USER_TEMPLATE_SOURCE="${SCRIPT_DIR}/bundle/omc-user-template"
INSTALL_STATE_REPORT_SOURCE="${SCRIPT_DIR}/tools/install-state-report.sh"
CHANGELOG_SOURCE="${SCRIPT_DIR}/CHANGELOG.md"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR_BASE="${CLAUDE_HOME}/backups/oh-my-claude-${STAMP}"
BACKUP_DIR="${BACKUP_DIR_BASE}"
BACKUP_DIR_ALLOCATED=0
INSTALL_TRANSACTION_DIR=""
# Fixed, startup-discoverable transaction authority. The detailed rollback
# snapshot remains inside the timestamped backup, while this narrow receipt
# prevents a later installer from blessing a SIGKILL-interrupted generation as
# its new baseline. It is published only after every backup/snapshot succeeds
# and before the first managed destination mutation.
INSTALL_DURABLE_TRANSACTION_DIR="${CLAUDE_HOME}/.install-transaction"
INSTALL_DURABLE_TRANSACTION_RECEIPT="${INSTALL_DURABLE_TRANSACTION_DIR}/receipt.json"
INSTALL_DURABLE_TRANSACTION_DIR_ID=""
INSTALL_DURABLE_TRANSACTION_RECEIPT_ID=""
INSTALL_DURABLE_TRANSACTION_RECEIPT_HASH=""
INSTALL_DURABLE_TRANSACTION_OPERATION_ID=""
INSTALL_DURABLE_TRANSACTION_PHASE=""
INSTALL_DURABLE_TRANSACTION_BACKUP_ID=""
INSTALL_DURABLE_TRANSACTION_SNAPSHOT_ID=""
INSTALL_DURABLE_TRANSACTION_CREATED_AT=""
BUNDLE_ROLLBACK_PRESENT_FILE=""
BUNDLE_PUBLISHED_PATHS=""
BUNDLE_PUBLISHED_SEALS=""
BUNDLE_INITIAL_SEALS=""
BUNDLE_INITIAL_ANCESTOR_SEALS=""
INSTALL_ROLLBACK_ARMED=0
MANIFEST_STAGE_PATH=""
HASHES_STAGE_PATH=""
STAMP_STAGE_PATH=""
REPORT_STAGE_PATH=""
GIT_HOOK_TRANSACTION_PATH=""
BACKUP_PRUNE_SEAL_FILE=""
BACKUP_PRUNE_SEAL_FILE_ID=""
BACKUP_PRUNE_SEAL_FILE_HASH=""
BACKUP_PRUNE_ENUM_FILE=""
BACKUP_PRUNE_ENUM_FILE_ID=""

# ---------------------------------------------------------------------------
# Version (read from VERSION file, fallback to CHANGELOG.md)
# ---------------------------------------------------------------------------

OMC_VERSION="unknown"
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  OMC_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION")"
elif [[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]]; then
  ver_line="$(grep -m1 -E '^##\s+\[?v?[0-9]' "${SCRIPT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
  if [[ -n "${ver_line}" ]]; then
    OMC_VERSION="$(printf '%s' "${ver_line}" | sed 's/^##[[:space:]]*//' | sed 's/^\[//' | sed 's/].*//' | sed 's/^v//' | sed 's/[[:space:]].*//')"
  fi
fi

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

BYPASS_PERMISSIONS=false
EXCLUDE_IOS=false
MODEL_TIER=""
INSTALL_GIT_HOOKS=false
# v1.36.0: ghostty install is now auto-detect by default. "" = auto
# (install only when ${GHOSTTY_HOME} already exists), "yes" = force
# install, "no" = skip. Closes the silent ~/.config/ghostty/ side
# effect on hosts that don't run Ghostty terminal.
INSTALL_GHOSTTY_FLAG=""
# Track which ghostty flags appeared so we can detect the mutually-
# exclusive case. Pre-fix the arg loop accepted both flags and silently
# last-wins; the explicit pair-tracking lets us refuse the combination
# instead of guessing user intent.
_OMC_GHOSTTY_NO_SEEN=0
_OMC_GHOSTTY_YES_SEEN=0
# v1.36.0: backup retention. 10 newest oh-my-claude-* dirs in
# ${CLAUDE_HOME}/backups/ are kept; older ones pruned after install
# completes. Set to 0 to disable retention; set --keep-backups=all
# to skip pruning entirely.
KEEP_BACKUPS="10"

# Handle --uninstall early (mutually exclusive with install flags).
if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  exec bash "${SCRIPT_DIR}/uninstall.sh" "$@"
fi

for arg in "$@"; do
  case "${arg}" in
    --bypass-permissions)
      BYPASS_PERMISSIONS=true
      ;;
    --no-ios)
      EXCLUDE_IOS=true
      ;;
    --model-tier=*)
      MODEL_TIER="${arg#*=}"
      ;;
    --model-tier)
      printf 'Missing value for --model-tier. Usage: --model-tier=quality|balanced|economy\n' >&2
      exit 1
      ;;
    --git-hooks)
      INSTALL_GIT_HOOKS=true
      ;;
    --no-ghostty)
      INSTALL_GHOSTTY_FLAG="no"
      _OMC_GHOSTTY_NO_SEEN=1
      ;;
    --with-ghostty)
      INSTALL_GHOSTTY_FLAG="yes"
      _OMC_GHOSTTY_YES_SEEN=1
      ;;
    --keep-backups=*)
      KEEP_BACKUPS="${arg#*=}"
      ;;
    --keep-backups)
      printf 'Missing value for --keep-backups. Usage: --keep-backups=N (or --keep-backups=all to disable pruning)\n' >&2
      exit 1
      ;;
    *)
      printf 'Unknown argument: %s\n' "${arg}" >&2
      printf 'Usage: bash install.sh [--bypass-permissions] [--no-ios] [--model-tier=TIER] [--git-hooks] [--no-ghostty] [--with-ghostty] [--keep-backups=N] [--uninstall]\n' >&2
      exit 1
      ;;
  esac
done

# Validate --keep-backups before the value reaches Bash arithmetic. Leading
# zeroes are not cosmetic here: Bash treats arithmetic operands such as `08`
# as invalid octal, while machine-width evaluation can wrap an attacker-sized
# decimal. `all` is the explicit unbounded-retention spelling, so a finite
# numeric value has no reason to exceed this conservative operational ceiling.
if [[ "${KEEP_BACKUPS}" != "all" ]]; then
  case "${KEEP_BACKUPS}" in
    ''|*[!0-9]*|0?*)
      printf 'Invalid --keep-backups value: %s. Must be "all" or a canonical integer from 0 to 10000.\n' "${KEEP_BACKUPS}" >&2
      exit 1
      ;;
    0|[1-9]*) ;;
    *)
      printf 'Invalid --keep-backups value: %s. Must be "all" or a canonical integer from 0 to 10000.\n' "${KEEP_BACKUPS}" >&2
      exit 1
      ;;
  esac
  if [[ "${#KEEP_BACKUPS}" -gt 5 ]] \
      || { [[ "${#KEEP_BACKUPS}" -eq 5 ]] \
        && [[ "${KEEP_BACKUPS}" != "10000" ]]; }; then
    printf 'Invalid --keep-backups value: %s. Must be "all" or a canonical integer from 0 to 10000.\n' "${KEEP_BACKUPS}" >&2
    exit 1
  fi
fi

# Refuse --no-ghostty + --with-ghostty in the same invocation. The two
# flags express opposite intents and last-wins would silently ignore one;
# better to surface the conflict so the user picks deliberately. Use
# `%s\n` because the bash builtin printf treats a leading `--` in the
# format string as end-of-options and rejects it as an invalid flag.
if [[ "${_OMC_GHOSTTY_NO_SEEN}" -eq 1 ]] && [[ "${_OMC_GHOSTTY_YES_SEEN}" -eq 1 ]]; then
  printf '%s\n' '--no-ghostty and --with-ghostty are mutually exclusive — pick one.' >&2
  exit 1
fi

# Validate --model-tier value if provided.
if [[ -n "${MODEL_TIER}" ]] && [[ "${MODEL_TIER}" != "quality" && "${MODEL_TIER}" != "balanced" && "${MODEL_TIER}" != "economy" ]]; then
  printf 'Invalid model tier: %s. Must be quality, balanced, or economy.\n' "${MODEL_TIER}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

need_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${cmd}" >&2
    exit 1
  fi
}

# Deterministic race barrier used only by the installer regression suite.
# Production runs leave OMC_TEST_INSTALL_BARRIER_ENABLE unset, so this is a
# zero-cost no-op. The bounded wait prevents a malformed test invocation from
# wedging an install indefinitely.
install_test_barrier() {
  local ready="${1:-}" release="${2:-}" payload="${3:-ready}" attempt=0
  [[ "${OMC_TEST_INSTALL_BARRIER_ENABLE:-0}" == "1" ]] || return 0
  [[ -z "${ready}" && -z "${release}" ]] && return 0
  [[ "${ready}" == /* && "${release}" == /* ]] || return 1
  printf '%s\n' "${payload}" >"${ready}" || return 1
  while [[ ! -e "${release}" ]]; do
    attempt=$((attempt + 1))
    [[ "${attempt}" -le 6000 ]] || return 1
    sleep 0.01
  done
}

# Sanitize every ordinary builtin used by SHA authority before resolving or
# invoking the trusted executable. POSIX special-builtin lookup guarantees
# this `unset` is not a same-named imported function; readonly shims fail the
# authority operation closed. Callers use subshell-bodied helpers so a
# readonly POSIXLY_CORRECT cannot terminate the installer shell.
function sanitize_sha256_authority_shell () {
  POSIXLY_CORRECT=1 || \return 1
  \unset -f builtin command printf read local type declare unset cd pwd \
    return shasum sha256sum readlink || \return 1
}

# Resolve the same finite SHA authority surface used by the installed runtime:
# exact canonical OS binaries or immutable Nix-store binaries only. Shell
# functions/aliases and writable package-manager prefixes cannot satisfy
# install preflight or mint the installed drift manifest.
function resolve_trusted_sha256_executable () (
  \sanitize_sha256_authority_shell || \return 1
  \local search_path="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
  \local old_ifs="${IFS}" directory="" canonical="" name="" candidate=""
  \local reader="" resolved=""
  [[ "${search_path}" != *$'\n'* && "${search_path}" != *$'\r'* ]] \
    || \return 1
  for name in shasum sha256sum; do
    IFS=':'
    for directory in ${search_path}; do
      IFS="${old_ifs}"
      [[ -n "${directory}" && "${directory}" == /* \
          && "${directory}" != *[[:cntrl:]]* ]] || continue
      canonical="$(\builtin cd -- "${directory}" 2>/dev/null \
        && \builtin pwd -P)" || continue
      case "${canonical}" in
        /usr/bin|/bin|/usr/sbin|/sbin|/nix/store/*/bin) ;;
        *) continue ;;
      esac
      candidate="${canonical%/}/${name}"
      [[ -f "${candidate}" && -x "${candidate}" ]] || continue
      if [[ -L "${candidate}" ]]; then
        case "${candidate}" in /nix/store/*/bin/*) ;; *) continue ;; esac
        resolved=""
        for reader in /usr/bin/readlink /bin/readlink \
            "${canonical%/}/readlink"; do
          [[ -x "${reader}" ]] || continue
          resolved="$(\builtin command -- "${reader}" -f -- \
            "${candidate}" 2>/dev/null)" || resolved=""
          case "${resolved}" in /nix/store/*) ;; *) resolved="" ;; esac
          [[ -n "${resolved}" && -f "${resolved}" \
              && -x "${resolved}" && ! -L "${resolved}" ]] && break
          resolved=""
        done
        [[ -n "${resolved}" ]] || continue
        \builtin printf '%s' "${candidate}"
        IFS="${old_ifs}"
        \return 0
      fi
      [[ ! -L "${candidate}" ]] || continue
      \builtin printf '%s' "${candidate}"
      IFS="${old_ifs}"
      \return 0
    done
    IFS="${old_ifs}"
  done
  IFS="${old_ifs}"
  \return 1
)

function generate_trusted_sha256_manifest () (
  \sanitize_sha256_authority_shell || \return 1
  \local hasher="${1:-}" root="${2:-}" input="${3:-}" output="${4:-}"
  \local relative_path=""
  [[ -n "${hasher}" && -d "${root}" && -f "${input}" \
      && -n "${output}" ]] || \return 1
  \builtin cd -- "${root}" || \return 1
  while IFS= \read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    case "${hasher##*/}" in
      shasum)
        \builtin command -- "${hasher}" -a 256 -- "${relative_path}" \
          >>"${output}" 2>/dev/null || \return 1
        ;;
      sha256sum)
        \builtin command -- "${hasher}" -- "${relative_path}" \
          >>"${output}" 2>/dev/null || \return 1
        ;;
      *) \return 1 ;;
    esac
  done <"${input}"
)

# Hash one already-admitted regular file with the same finite executable
# authority used for the installed drift manifest. Settings transaction seals
# use this instead of PATH-resolved helpers so a concurrent replacement cannot
# be hidden by an imported function or writable package-manager shim.
function trusted_sha256_file () (
  \sanitize_sha256_authority_shell || \return 1
  \local hasher="${1:-}" path="${2:-}" output="" digest=""
  [[ -n "${hasher}" && -f "${path}" && ! -L "${path}" ]] || \return 1
  case "${hasher##*/}" in
    shasum)
      output="$(\builtin command -- "${hasher}" -a 256 -- "${path}" 2>/dev/null)" \
        || \return 1
      ;;
    sha256sum)
      output="$(\builtin command -- "${hasher}" -- "${path}" 2>/dev/null)" \
        || \return 1
      ;;
    *) \return 1 ;;
  esac
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || \return 1
  \builtin printf '%s\n' "${digest}"
)

# Hash an already-open regular-file descriptor without reopening its pathname.
# `/dev/fd/N` and `/proc/self/fd/N` are symlinks on Linux, so routing them
# through trusted_sha256_file would correctly reject the path but would also
# make every descriptor-backed settings render fail. Callers bind the
# descriptor to a sealed regular-file identity immediately before this read.
function trusted_sha256_descriptor () (
  \sanitize_sha256_authority_shell || \return 1
  \local hasher="${1:-}" fd="${2:-}" output="" digest=""
  [[ -n "${hasher}" && "${fd}" =~ ^[0-9]{1,3}$ ]] || \return 1
  ((10#${fd} <= 255)) || \return 1
  case "${hasher##*/}" in
    shasum)
      output="$(\builtin command -- "${hasher}" -a 256 \
        <&"${fd}" 2>/dev/null)" || \return 1
      ;;
    sha256sum)
      output="$(\builtin command -- "${hasher}" \
        <&"${fd}" 2>/dev/null)" || \return 1
      ;;
    *) \return 1 ;;
  esac
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || \return 1
  \builtin printf '%s\n' "${digest}"
)

claude_code_version_at_least() {
  local required_patch="$1" raw version major minor patch
  raw="$(claude --version 2>/dev/null || true)"
  version="$(printf '%s' "${raw}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -n "${version}" ]] || return 2
  IFS=. read -r major minor patch <<<"${version}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]] || return 2
  (( major > 2 )) && return 0
  (( major < 2 )) && return 1
  (( minor > 1 )) && return 0
  (( minor < 1 )) && return 1
  (( patch >= required_patch ))
}

# Two-hop stat helper (BSD then GNU) — same portability shape as
# session-start-welcome.sh:_lock_mtime / common.sh state-io. Returns
# the file's mtime epoch on stdout, empty string when unsupported.
# Note on busybox/Alpine consumers below: `date -r` interprets its
# argument as a FILENAME on busybox, not an epoch, so the formatted-
# date branch in warn_modified_memory_files falls back to `epoch=N`
# via the `||` operator there. This is a documented degradation,
# not a bug.
_install_file_mtime() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  if stat -f '%m' "${path}" >/dev/null 2>&1; then
    stat -f '%m' "${path}" 2>/dev/null
  elif stat -c '%Y' "${path}" >/dev/null 2>&1; then
    stat -c '%Y' "${path}" 2>/dev/null
  fi
}

# Stable file-content signature used for install-outcome reporting.
# `cksum` is POSIX and available on both macOS and Linux, making it a
# better portability fit than the SHA tools used by verify.sh's optional
# at-rest drift manifest.
file_cksum_signature() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  cksum "${path}" 2>/dev/null | awk '{print $1 ":" $2}'
}

# Build a sorted snapshot of managed installed files keyed by relative
# path. Each line is `<path><TAB><checksum:size>`. The manifest limits the
# snapshot to bundle-managed files only, so user-created content under
# ~/.claude/ does not affect restart decisions.
build_signature_snapshot() {
  local root_dir="$1"
  local manifest_path="$2"
  local out_path="$3"
  local rel_path=""
  local sig=""

  : > "${out_path}"
  [[ -f "${manifest_path}" ]] || return 0

  while IFS= read -r rel_path; do
    [[ -n "${rel_path}" ]] || continue
    [[ -f "${root_dir}/${rel_path}" ]] || continue
    sig="$(file_cksum_signature "${root_dir}/${rel_path}" || true)"
    [[ -n "${sig}" ]] || continue
    printf '%s\t%s\n' "${rel_path}" "${sig}" >> "${out_path}"
  done < "${manifest_path}"

  LC_ALL=C sort -o "${out_path}" "${out_path}"
}

# v1.36.0: warn before overwriting memory files the user has hand-edited.
# The end-of-install message used to advertise "settings.json merges and
# omc-user/ are preserved" without mentioning that quality-pack/memory/*.md
# is overwritten on every install. Users who hand-edited core.md or
# skills.md to adjust their workflow lost those edits silently. This
# helper compares each memory file's mtime against the previous
# install-stamp; files modified post-install are listed BEFORE rsync
# runs so the user can Ctrl-C and migrate edits to omc-user/overrides.md.
warn_modified_memory_files() {
  local install_stamp="${CLAUDE_HOME}/.install-stamp"
  local memory_dir="${CLAUDE_HOME}/quality-pack/memory"
  local stamp_ts=""

  [[ -d "${memory_dir}" ]] || return 0
  stamp_ts="$(_install_file_mtime "${install_stamp}" || true)"
  # First install (no stamp) or unsupported stat — silent skip.
  [[ -z "${stamp_ts}" ]] && return 0
  [[ "${stamp_ts}" =~ ^[0-9]+$ ]] || return 0
  [[ "${stamp_ts}" -le 0 ]] && return 0

  local warned=0
  local mem_file file_ts
  while IFS= read -r mem_file; do
    [[ -z "${mem_file}" ]] && continue
    [[ -f "${mem_file}" ]] || continue
    file_ts="$(_install_file_mtime "${mem_file}" || true)"
    [[ "${file_ts}" =~ ^[0-9]+$ ]] || continue
    if [[ "${file_ts}" -gt "${stamp_ts}" ]]; then
      if [[ "${warned}" -eq 0 ]]; then
        printf '\n  [warn] User edits detected in %s — these files will be overwritten.\n' "${memory_dir}"
        printf '         To preserve your customizations across installs, move them to:\n'
        printf '           %s/omc-user/overrides.md  (loaded after defaults; never overwritten)\n' "${CLAUDE_HOME}"
        printf '         A copy of each modified file IS saved in %s before rsync, so\n' "${BACKUP_DIR}"
        printf '         recovery is possible after-the-fact via:\n'
        printf '           cp %s/quality-pack/memory/<file>.md \\\n' "${BACKUP_DIR}"
        printf '              %s/omc-user/overrides.md   # then re-edit as additive overrides\n' "${CLAUDE_HOME}"
        printf '         Modified files:\n'
        warned=1
      fi
      printf '           - %s (modified %s)\n' \
        "$(basename "${mem_file}")" \
        "$(date -r "${file_ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'epoch=%s' "${file_ts}")"
    fi
  done < <(find "${memory_dir}" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

  if [[ "${warned}" -eq 1 ]]; then
    # F-2 fix (Wave 1 review): only sleep when interactive AND not in CI.
    # `bash install.sh < /dev/null` (curl-pipe-bash) and CI runs cannot
    # Ctrl-C, so a 5s wait there is pure dead time; same surface where
    # the bypass-permissions banner skips its prompt. Test runs (CI=1
    # in GitHub Actions) and stdin-redirected installs print the warning
    # and proceed immediately.
    if [[ -t 0 ]] && [[ -z "${CI:-}" ]]; then
      printf '         Continuing with install in 5 seconds — Ctrl-C to abort and migrate first.\n'
      sleep 5 2>/dev/null || true
    else
      printf '         Non-interactive install — proceeding immediately. Migrate edits before the next install run.\n'
    fi
  fi
}

# v1.36.0: prune oh-my-claude-${STAMP} backup directories after install.
# Keeps the most recent ${KEEP_BACKUPS} dirs (default 10); set
# --keep-backups=all to disable. At the project's release cadence
# (multiple installs per day during cascades) backups otherwise
# accumulate ~30/month with no surface to surface or rotate them.
#
# Conservative pruning (newest-first by name; the timestamp is
# embedded in the directory name so lexical sort == newest-first
# under normal clock conditions). F-1 (Wave 1 review) defense:
# even when prior dirs sort lexically AHEAD of ${BACKUP_DIR} (clock
# skew, hand-renamed dirs, future-dated stamps from rolled-back hosts),
# the just-created backup is ALWAYS preserved by an explicit
# `[[ "${dir}" == "${BACKUP_DIR}" ]] && continue` guard inside the
# prune loop. The guard is cheap and forecloses any ordering pathology.
prune_old_backups() {
  local keep="${KEEP_BACKUPS:-10}"
  [[ "${keep}" == "all" ]] && return 0
  [[ "${keep}" =~ ^[0-9]+$ ]] || return 0

  local backups_root="${CLAUDE_HOME}/backups"
  [[ -d "${backups_root}" ]] || return 0

  local -a backups=()
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] && backups+=("${dir}")
  done < <(find "${backups_root}" -maxdepth 1 -type d -name 'oh-my-claude-*' 2>/dev/null \
              | LC_ALL=C sort -r)

  if [[ "${#backups[@]}" -le "${keep}" ]]; then
    return 0
  fi

  # v1.37.x W4 (Item 10): pre-prune preview. Build the to-be-deleted
  # list FIRST, print it for the user, then (in interactive non-CI
  # mode) sleep 5 seconds with a Ctrl-C window — mirroring the
  # memory-overwrite warning shape at line 218-228 above. Pre-fix,
  # `--keep-backups=N` deleted older dirs without warning, which a
  # contributor with hand-edited backups (rare but real) had no chance
  # to abort. Same `[[ -t 0 ]] && [[ -z "${CI:-}" ]]` interactive-mode
  # gate as the memory warning so curl-pipe-bash and CI installs don't
  # eat dead time.
  local -a to_prune=()
  local -a to_prune_ids=()
  local i dir
  for ((i=keep; i<${#backups[@]}; i++)); do
    if [[ "${backups[i]}" == "${BACKUP_DIR}" ]]; then
      continue
    fi
    to_prune+=("${backups[i]}")
    to_prune_ids+=("$(install_directory_identity "${backups[i]}" 2>/dev/null || true)")
  done

  if [[ "${#to_prune[@]}" -eq 0 ]]; then
    return 0
  fi

  # The preview below deliberately creates an unbounded user-interaction
  # window. Seal every descendant before printing it so a same-path directory
  # replacement, a new descendant, or changed backup bytes cannot turn that
  # preview into authority to remove a different tree.
  if ! begin_backup_prune_seal; then
    printf '  [warn] Could not create a private backup-prune seal; preserving all older backups.\n' >&2
    cleanup_backup_prune_controls
    return 1
  fi
  for i in "${!to_prune[@]}"; do
    if ! capture_backup_prune_subtree "${to_prune[i]}" \
        "${to_prune_ids[i]:-}"; then
      printf '  [warn] Backup prune candidate could not be sealed; preserving all older backups: %s\n' \
        "${to_prune[i]}" >&2
      cleanup_backup_prune_controls
      return 1
    fi
  done
  if ! finalize_backup_prune_seal; then
    printf '  [warn] Backup-prune seal could not be finalized; preserving all older backups.\n' >&2
    cleanup_backup_prune_controls
    return 1
  fi

  printf '  Backup retention: keeping %d most recent oh-my-claude-* dir(s); will prune %d older:\n' \
    "${keep}" "${#to_prune[@]}"
  for dir in "${to_prune[@]}"; do
    local size=""
    size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"
    printf '    - %s%s\n' \
      "$(basename "${dir}")" \
      "${size:+ (${size})}"
  done

  if [[ -t 0 ]] && [[ -z "${CI:-}" ]]; then
    printf '  Continuing prune in 5 seconds — Ctrl-C to abort and run with --keep-backups=all to disable.\n'
    sleep 5 2>/dev/null || true
  else
    printf '  Non-interactive install — proceeding immediately with prune.\n'
  fi

  if ! install_test_barrier \
      "${OMC_TEST_INSTALL_BACKUP_PRUNE_READY_FILE:-}" \
      "${OMC_TEST_INSTALL_BACKUP_PRUNE_RELEASE_FILE:-}" \
      "${to_prune[0]}"; then
    printf '  [warn] Backup-prune race barrier failed; preserving all older backups.\n' >&2
    cleanup_backup_prune_controls
    return 1
  fi

  local pruned=0
  local prune_index=0
  for dir in "${to_prune[@]}"; do
    if backup_prune_subtree_seal_is_current "${dir}" \
        "${to_prune_ids[prune_index]:-}" \
        && rm -rf -- "${dir}" 2>/dev/null; then
      pruned=$((pruned + 1))
    else
      printf '  [warn] Backup prune target changed after preview; preserved: %s\n' \
        "${dir}" >&2
    fi
    prune_index=$((prune_index + 1))
  done

  cleanup_backup_prune_controls

  if [[ "${pruned}" -gt 0 ]]; then
    printf '  Backup retention: kept %d most recent oh-my-claude-* dir(s), pruned %d older.\n' \
      "${keep}" "${pruned}"
  fi
}

# ---------------------------------------------------------------------------
# Settings merge — Python implementation
# ---------------------------------------------------------------------------

# Allocate one invocation-owned backup directory. The timestamp is deliberately
# human-readable but has only one-second resolution; rapid reinstalls must not
# reuse an earlier directory because rsync's size/mtime quick check can leave a
# stale same-length backup in place. The install lock serializes cooperating
# installers, and plain mkdir is the final atomic collision check.
allocate_backup_dir() {
  local candidate="${BACKUP_DIR_BASE}" suffix="" attempt=0
  mkdir -p "${CLAUDE_HOME}/backups"
  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    attempt=$((attempt + 1))
    (( attempt <= 9999 )) \
      || { printf 'Unable to allocate a unique install backup directory.\n' >&2; return 1; }
    suffix="$(printf '%04d' "${attempt}")"
    candidate="${BACKUP_DIR_BASE}-${suffix}"
  done
  mkdir "${candidate}"
  BACKUP_DIR="${candidate}"
  BACKUP_DIR_ALLOCATED=1
  chmod 700 "${BACKUP_DIR}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------

merge_settings_python() {
  local settings_path="$1"
  local patch_path="$2"
  local bypass="$3"
  local output_path="${4:-}" legacy_in_place=0

  if [[ -z "${output_path}" ]]; then
    output_path="$(mktemp "${settings_path}.tmp.XXXXXX")" || return 1
    legacy_in_place=1
  fi

  if ! python3 - "${settings_path}" "${patch_path}" "${bypass}" \
    "${output_path}" <<'PY'
import json
import os
import pathlib
import re
import sys

settings_path = pathlib.Path(sys.argv[1])
patch_path = pathlib.Path(sys.argv[2])
bypass = sys.argv[3] == "true"
output_path = pathlib.Path(sys.argv[4])

if settings_path.exists():
    with settings_path.open() as f:
        settings = json.load(f)
else:
    settings = {}

with patch_path.open() as f:
    patch = json.load(f)

# Copy top-level keys from patch. outputStyle and effortLevel are
# preserved if the user has set them, but we explicitly guard against
# present-but-null values here rather than using setdefault, because
# setdefault only fills missing keys — it leaves an explicit `null`
# unchanged, diverging from jq's `// default` semantics. Without this
# guard, a user with `{"outputStyle": null}` in settings.json would
# end up with the null persisting under python but getting coerced
# to the patch value under jq.
#
# OMC_OUTPUT_STYLE_PREF (set by the parent shell from oh-my-claude.conf)
# selects which bundled style settings.outputStyle points at:
#   opencode   → "oh-my-claude"   (default, compact CLI presentation)
#   executive  → "executive-brief" (CEO-style status report)
#   preserve   → never touch settings.outputStyle (user has a custom style)
# A typed explicit env/conf preference is user authority and replaces a custom
# settings value. The implicit default preserves custom styles; `preserve` is
# the explicit no-touch choice. The legacy "OpenCode Compact" name is always
# migrated because its backing style was removed.
settings["statusLine"] = patch["statusLine"]
output_style_pref = os.environ.get("OMC_OUTPUT_STYLE_PREF", "opencode")
output_style_pref_explicit = os.environ.get(
    "OMC_OUTPUT_STYLE_PREF_EXPLICIT", "0"
) == "1"
_BUNDLED_STYLES_CURRENT = {"oh-my-claude", "executive-brief"}
_STYLE_FOR_PREF = {"opencode": "oh-my-claude", "executive": "executive-brief"}
if settings.get("outputStyle") == "OpenCode Compact":
    # Legacy migration: pre-v1.26.0 installs left "OpenCode Compact" in
    # settings, but the underlying style file was renamed to oh-my-claude
    # and the legacy file removed. Leaving the legacy name would orphan
    # the user (Claude Code cannot resolve it). Always migrate, even
    # under preserve — preserve protects user choices, not installer
    # artifacts pointing at a deleted style file. Honor the conf-resolved
    # target when one is available; fall back to oh-my-claude otherwise.
    settings["outputStyle"] = _STYLE_FOR_PREF.get(output_style_pref, patch["outputStyle"])
elif output_style_pref != "preserve":
    _target_style = _STYLE_FOR_PREF.get(output_style_pref, patch["outputStyle"])
    _current_style = settings.get("outputStyle")
    if (output_style_pref_explicit or _current_style is None
            or (isinstance(_current_style, str)
                and _current_style in _BUNDLED_STYLES_CURRENT)):
        settings["outputStyle"] = _target_style
if settings.get("effortLevel") is None:
    settings["effortLevel"] = patch["effortLevel"]
settings["spinnerTipsEnabled"] = patch["spinnerTipsEnabled"]
settings["spinnerVerbs"] = patch["spinnerVerbs"]

# Bypass-permissions mode (only when explicitly requested)
if bypass:
    permissions = settings.get("permissions")
    if permissions is None:
        permissions = {}
        settings["permissions"] = permissions
    permissions["defaultMode"] = "bypassPermissions"
    settings["skipDangerousModePermissionPrompt"] = True
else:
    # Do not set these keys when bypass is not requested.
    # If they already exist from a previous install, leave them alone --
    # the user may have set them independently.
    pass

# Merge hooks by signature (idempotent). Uses null-safe accessors so
# an explicit null at `hooks`, `<event>`, `matcher`, `command`, or
# `hooks[].hooks` in base settings never crashes Python — preserving
# parity with jq's `// default` coalesce behavior.
if settings.get("hooks") is None:
    settings["hooks"] = {}
hooks = settings["hooks"]

_PATCH_PATH_RE = re.compile(
    r'(?:\$HOME|\$\{HOME\}|~)/\.claude/'
    r'((?:skills/autowork|quality-pack)/scripts/[A-Za-z0-9_-]+\.(?:sh|py))'
)

def _patch_command_relative(command):
    match = _PATCH_PATH_RE.search(command or "")
    return match.group(1) if match else ""

# Ownership is a finite command map, not a shell parser. Current patch commands
# are owned byte-for-byte. Historical compatibility is limited to the exact
# commands proven below; extra argv, wrapper options, alternate roots, shell
# operators, decoy script arguments, and arbitrary `.../.claude/...` suffixes
# are foreign even when they mention or execute the same script path.
MANAGED_COMMAND_IDENTITIES = {
    hook.get("command") or "": _patch_command_relative(hook.get("command"))
    for event_entries in (patch.get("hooks") or {}).values()
    for entry in (event_entries or []) if isinstance(entry, dict)
    for hook in (entry.get("hooks") or []) if isinstance(hook, dict)
    if _patch_command_relative(hook.get("command"))
}
# Git history contains only literal `$HOME/.claude/...` launch commands.
# These are the exact commands removed from prior settings.patch.json
# revisions; synthetic sh/sudo/env/exec wrappers and alternate roots were
# never emitted by the installer and remain foreign.
for legacy_name in (
    "posttool-timing.sh", "record-delivery-action.sh", "circuit-breaker.sh",
    "stop-guard.sh", "stop-time-summary.sh", "canary-claim-audit.sh",
    "stop-transcript-archive.sh",
):
    relative = "skills/autowork/scripts/" + legacy_name
    MANAGED_COMMAND_IDENTITIES.setdefault(
        "$HOME/.claude/" + relative, relative
    )
for legacy_name in ("cleanup-orphan-resume.sh", "cleanup-orphan-tmp.sh"):
    relative = "quality-pack/scripts/" + legacy_name
    MANAGED_COMMAND_IDENTITIES.setdefault(
        "bash $HOME/.claude/" + relative, relative
    )

def managed_script_relative(command):
    if not isinstance(command, str):
        return ""
    return MANAGED_COMMAND_IDENTITIES.get(command, "")

def command_identity_text(command):
    if command is None:
        return ""
    if isinstance(command, str):
        return command
    def canonical_invalid_json(value):
        if isinstance(value, dict):
            return [
                "object",
                [
                    [key, canonical_invalid_json(value[key])]
                    for key in sorted(value)
                ],
            ]
        if isinstance(value, list):
            return ["array", [canonical_invalid_json(item) for item in value]]
        if isinstance(value, bool):
            return ["boolean", value]
        if value is None:
            return ["null"]
        if isinstance(value, str):
            return ["string", value]
        if isinstance(value, (int, float)):
            # A hook command must be a string, so numeric values are malformed.
            # Use a deliberately coarse type identity rather than attempting to
            # reproduce jq's platform-dependent double rendering (1, 1.0,
            # 1e20, overflow, and negative zero differ from Python spelling).
            return ["number"]
        return ["unknown"]
    try:
        return json.dumps(
            canonical_invalid_json(command),
            separators=(",", ":"),
        )
    except (TypeError, ValueError):
        return repr(command)

def script_basename(command):
    """Return a basename only for an exact owned command spelling."""
    relative = managed_script_relative(command)
    return relative.rsplit("/", 1)[-1] if relative else ""

def script_identity(command):
    """Return exact managed ownership or an exact foreign-command identity."""
    relative = managed_script_relative(command)
    if relative:
        return "omc-managed:" + relative
    return "foreign-command:" + command_identity_text(command)

def entry_hooks(entry):
    # Filter out non-dict hook entries (explicit `null`, arrays, scalars)
    # so malformed settings.json input never crashes identity extraction
    # or deduplication. Matches jq's `select(type == "object")` filter.
    return [h for h in (entry.get("hooks") or []) if isinstance(h, dict)]

def entry_basenames(entry):
    return [script_identity(hook.get("command")) for hook in entry_hooks(entry)]

def entry_matcher(entry):
    # Coalesce missing, explicit-None, and any falsy matcher to "". Matches
    # jq's `.matcher // ""` behavior so empty-matcher patch entries (the
    # record-subagent-summary.sh entry) can be identified identically.
    return entry.get("matcher") or ""

def dedupe_entry_hooks(entry):
    """Collapse hooks by exact managed/foreign command identity, later wins.

    Closes a parity divergence where Python's `frozenset` treated duplicate
    identities as one signature but
    jq's list-sort compare saw them as distinct, and a dedup hole in
    Phase 2's hook-level merge where stale duplicates survived a patch."""
    seen = {}
    for hook in entry_hooks(entry):
        seen[script_identity(hook.get("command"))] = hook
    new_entry = dict(entry)
    new_entry["hooks"] = list(seen.values())
    return new_entry

def normalize_base_entries(entries):
    """Pre-normalize base entries before the three-phase merge loop:

    1. Within each dict entry, dedupe hooks by owned command identity
       (later-wins). Preserves each distinct identity's first position.
    2. Collapse multiple same-matcher entries whose identity sets
       overlap into a single canonical entry. The first such entry
       becomes the canonical target; subsequent overlapping entries
       have their hooks merged in (replacing matching identities,
       appending new ones). Entries with disjoint identities remain
       separate to preserve intentional user customization (Test 8).

    Closes metis finding #1: a migration path where an older buggy
    installer left two `editor-critic` entries in base settings would,
    under the bare three-phase loop, have Phase 1 match only the first
    entry and leave the second with a stale record-reviewer.sh — still
    firing twice per SubagentStop. Normalizing the base first eliminates
    the pre-existing duplication so the three-phase loop always operates
    on a canonical base."""
    result = []
    for raw in entries:
        if not isinstance(raw, dict):
            result.append(raw)
            continue
        entry = dedupe_entry_hooks(raw)
        m = entry_matcher(entry)
        e_basenames = frozenset(entry_basenames(entry))
        merged_into = None
        for i, r in enumerate(result):
            if not isinstance(r, dict):
                continue
            if entry_matcher(r) != m:
                continue
            if frozenset(entry_basenames(r)) & e_basenames:
                merged_into = i
                break
        if merged_into is None:
            result.append(entry)
            continue
        # target is a reference into result; mutating target["hooks"]
        # below updates the result entry in place. Safe because
        # dedupe_entry_hooks returned a shallow copy of each base entry,
        # so the caller's original hooks[event] list is never mutated.
        target = result[merged_into]
        target_hooks = list(entry_hooks(target))
        basename_to_index = {}
        for j, h in enumerate(target_hooks):
            basename_to_index[script_identity(h.get("command"))] = j
        for hook in entry_hooks(entry):
            b = script_identity(hook.get("command"))
            if b in basename_to_index:
                target_hooks[basename_to_index[b]] = hook
            else:
                basename_to_index[b] = len(target_hooks)
                target_hooks.append(hook)
        target["hooks"] = target_hooks
    return result

# v1.48 W3.1 upgrade prune: hook wirings SUPERSEDED by a consolidation
# must be removed from the pre-existing base, or every upgrader keeps the
# old direct wiring alongside its replacement and each consolidated hook
# double-fires (duplicate timing rows; the circuit-breaker's consecutive-
# failure counter double-increments and trips at ~2 real failures). The
# merge is deliberately append/replace-only for FOREIGN entries, so
# supersessions are declared explicitly per (event, matcher,
# exact-owned-script-basename) tuple. Keep in lockstep with the jq twin below.
# NOTE: no line of this embedded python may START with "}" — the test
# harness extracts these bash functions with `sed '/^name()/,/^}/p'`,
# and a column-0 brace would truncate the extraction mid-function.
SUPERSEDED_HOOKS = frozenset([
    ("SessionStart", "", "cleanup-orphan-resume.sh"),
    ("SessionStart", "", "cleanup-orphan-tmp.sh"),
    ("PostToolUse", "", "posttool-timing.sh"),
    ("PostToolUse", "Bash", "record-verification.sh"),
    ("PostToolUse", "Bash", "record-delivery-action.sh"),
    ("PostToolUse", "Bash", "circuit-breaker.sh"),
    ("Stop", "", "stop-guard.sh"),
    ("Stop", "", "stop-time-summary.sh"),
    ("Stop", "", "canary-claim-audit.sh"),
    ("Stop", "", "stop-transcript-archive.sh"),
])
SUPERSEDED_STOP_BASENAMES = frozenset([
    "stop-guard.sh",
    "stop-time-summary.sh",
    "canary-claim-audit.sh",
    "stop-transcript-archive.sh",
])

def is_managed_legacy_stop_command(command):
    """Recognize only OMC's installed legacy Stop scripts.

    Basenames are not ownership. A user may legitimately wire an unrelated
    `/opt/acme/stop-guard.sh`; upgrade cleanup must preserve it.
    """
    basename = script_basename(command)
    return basename in SUPERSEDED_STOP_BASENAMES

def prune_superseded(event, entries):
    # Events with no supersessions pass through untouched, and an entry is
    # only dropped when the prune ITSELF emptied it — a pre-existing
    # null/empty-hooks entry must survive exactly as the merge always
    # treated it.
    if not any(t[0] == event for t in SUPERSEDED_HOOKS):
        return entries
    kept = []
    for e in entries:
        if not isinstance(e, dict):
            kept.append(e)
            continue
        matcher = entry_matcher(e)
        original = entry_hooks(e)
        remaining = []
        for h in original:
            basename = script_basename(h.get("command"))
            if event == "Stop" and basename in SUPERSEDED_STOP_BASENAMES:
                if is_managed_legacy_stop_command(h.get("command")):
                    continue
            elif basename and (event, matcher, basename) in SUPERSEDED_HOOKS:
                continue
            remaining.append(h)
        if len(remaining) == len(original):
            kept.append(e)
            continue
        if not remaining:
            continue  # entry fully superseded — drop it
        e = dict(e)
        e["hooks"] = remaining
        kept.append(e)
    return kept

def canonicalize_managed_entries(entries, patch_entries):
    """Remove stale matcher copies of uniquely-owned managed hooks, then
    collapse duplicates created by a matcher rename.

    A managed script identity used by multiple patch matchers
    (record-reviewer.sh) is left matcher-scoped. An identity with one patch
    owner (posttool-dispatch.sh,
    mark-edit.sh, etc.) may exist only under that canonical matcher. Foreign
    hooks sharing an entry are preserved."""
    owners = {}
    for entry in patch_entries or []:
        if not isinstance(entry, dict):
            continue
        matcher = entry_matcher(entry)
        for basename in entry_basenames(entry):
            owners.setdefault(basename, set()).add(matcher)
    unique_owner = {
        basename: next(iter(matchers))
        for basename, matchers in owners.items()
        if len(matchers) == 1
    }
    kept = []
    for entry in entries:
        if not isinstance(entry, dict):
            kept.append(entry)
            continue
        matcher = entry_matcher(entry)
        original = entry_hooks(entry)
        remaining = [
            hook for hook in original
            if unique_owner.get(script_identity(hook.get("command")), matcher) == matcher
        ]
        if len(remaining) == len(original):
            kept.append(entry)
        elif remaining:
            updated = dict(entry)
            updated["hooks"] = remaining
            kept.append(updated)
        # Drop an entry only when removing stale managed hooks emptied it.
    return normalize_base_entries(kept)

for event, patch_entries in (patch.get("hooks") or {}).items():
    if hooks.get(event) is None:
        hooks[event] = []
    # Normalize base first so the three-phase loop operates on a
    # canonical, dedup-free base; then prune wirings this patch version
    # supersedes (upgrade path — see SUPERSEDED_HOOKS above).
    existing_entries = normalize_base_entries(hooks[event])
    existing_entries = prune_superseded(event, existing_entries)
    hooks[event] = existing_entries

    # Snapshot pre-patch entry count and track which original indices have
    # been claimed by Phase 0 below. The patch loop appends new entries to
    # existing_entries, but Phase 0 must only consider entries from the
    # ORIGINAL pre-patch state — otherwise patches that legitimately share
    # a managed identity across different matchers (e.g. record-reviewer.sh wired
    # to quality-reviewer, editor-critic, excellence-reviewer, ...) would
    # cascade-rename each other and collapse to a single entry.
    original_count = len(existing_entries)
    claimed_by_rename = set()

    # Precompute the set of matcher values the patch installs. Phase 0
    # only fires when the existing entry's matcher is NOT present in this
    # set — i.e., the patch removed the old matcher value entirely (the
    # rename case). If the matcher is still in the patch, Phase 1 will
    # match it directly and Phase 0 must not preempt with a different
    # patch entry that happens to share the identity set. This keeps
    # idempotent re-merges and shared-identity patches (record-reviewer.sh
    # under many matchers) free of spurious renames.
    patch_matcher_set = {
        entry_matcher(e)
        for e in (patch_entries or [])
        if isinstance(e, dict)
    }

    for patch_entry in patch_entries or []:
        if not isinstance(patch_entry, dict):
            existing_entries.append(patch_entry)
            continue

        p_matcher = entry_matcher(patch_entry)
        p_basenames = entry_basenames(patch_entry)
        p_basename_set = frozenset(p_basenames)

        # Phase 0: matcher-rename detection. When the patch's managed identity
        # set exactly matches an unclaimed ORIGINAL existing entry's identity
        # set, the matcher value differs, and the existing matcher is NOT
        # still present elsewhere in the patch, treat as a matcher rename
        # (e.g. "Bash" widened to "Bash|Edit|Write|MultiEdit"). Replace the
        # existing entry in place and claim the index so subsequent patch
        # iterations cannot rename the same slot again. Skipped when the
        # patch entry has no identities (empty entries cannot disambiguate
        # ownership).
        if p_basename_set:
            rename_idx = None
            for i in range(original_count):
                if i in claimed_by_rename:
                    continue
                existing = existing_entries[i]
                if not isinstance(existing, dict):
                    continue
                e_matcher = entry_matcher(existing)
                if e_matcher == p_matcher:
                    continue
                if e_matcher in patch_matcher_set:
                    continue
                if frozenset(entry_basenames(existing)) == p_basename_set:
                    rename_idx = i
                    break
            if rename_idx is not None:
                existing_entries[rename_idx] = patch_entry
                claimed_by_rename.add(rename_idx)
                continue

        # Phase 1: exact match on (matcher, identity set) — fast path for
        # fresh installs and idempotent re-merges. Replaces whole entry.
        exact_idx = None
        for i, existing in enumerate(existing_entries):
            if not isinstance(existing, dict):
                continue
            if entry_matcher(existing) != p_matcher:
                continue
            if frozenset(entry_basenames(existing)) == p_basename_set:
                exact_idx = i
                break
        if exact_idx is not None:
            existing_entries[exact_idx] = patch_entry
            continue

        # Phase 2: same matcher + non-empty managed-identity intersection.
        # Merge at hook level: patch hooks replace base hooks that share an
        # identity; new identities are appended to the first overlapping
        # base entry. This closes the multi-hook matcher collision where
        # a base entry with two hooks and a patch entry with one hook
        # would otherwise signature-differ and both survive, causing
        # duplicate fires of the shared script.
        overlap_idx = None
        for i, existing in enumerate(existing_entries):
            if not isinstance(existing, dict):
                continue
            if entry_matcher(existing) != p_matcher:
                continue
            if frozenset(entry_basenames(existing)) & p_basename_set:
                overlap_idx = i
                break
        if overlap_idx is not None:
            target = existing_entries[overlap_idx]
            merged_hooks = list(entry_hooks(target))
            basename_to_index = {}
            for i, hook in enumerate(merged_hooks):
                basename_to_index[script_identity(hook.get("command"))] = i
            for patch_hook in entry_hooks(patch_entry):
                b = script_identity(patch_hook.get("command"))
                if b in basename_to_index:
                    merged_hooks[basename_to_index[b]] = patch_hook
                else:
                    basename_to_index[b] = len(merged_hooks)
                    merged_hooks.append(patch_hook)
            target["hooks"] = merged_hooks
            continue

        # Phase 3: disjoint matcher/identities — append as a new entry.
        existing_entries.append(patch_entry)

    # Phase 0 can rename a stale entry onto a matcher that already has the
    # canonical patch entry, creating duplicate fires. Coalesce after every
    # event merge and remove any remaining uniquely-owned managed identity
    # from stale matchers.
    hooks[event] = canonicalize_managed_entries(existing_entries, patch_entries)

with output_path.open("w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
  then
    [[ "${legacy_in_place}" -eq 0 ]] \
      || rm -f -- "${output_path}" 2>/dev/null || true
    return 1
  fi
  if [[ "${legacy_in_place}" -eq 1 ]]; then
    mv -f -- "${output_path}" "${settings_path}"
  fi
}

# ---------------------------------------------------------------------------
# Settings merge — jq implementation (fallback)
# ---------------------------------------------------------------------------

merge_settings_jq() {
  local settings_path="$1"
  local patch_path="$2"
  local bypass="$3"
  local output_path="${4:-}" legacy_in_place=0
  local render_patch_path="${5:-${patch_path}}"
  local base_path="${settings_path}"
  local managed_commands_json
  managed_commands_json="$(jq -c '
    ([ (.hooks // {}) | to_entries[] | .value[]? | (.hooks // [])[]?
       | (.command // "") as $command
       | ($command | capture(
           "(?:[$]HOME)/[.]claude/(?<relative>(?:skills/autowork|quality-pack)/scripts/[A-Za-z0-9_-]+[.](?:sh|py))"
         )) as $parts
       | {key: $command, value: $parts.relative} ]
     + (["posttool-timing.sh", "record-delivery-action.sh", "circuit-breaker.sh",
         "stop-guard.sh", "stop-time-summary.sh", "canary-claim-audit.sh",
         "stop-transcript-archive.sh"]
        | map(. as $name
          | {key: ("$HOME/.claude/skills/autowork/scripts/" + $name),
             value: ("skills/autowork/scripts/" + $name)}))
     + [
        {key: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-resume.sh",
         value: "quality-pack/scripts/cleanup-orphan-resume.sh"},
        {key: "bash $HOME/.claude/quality-pack/scripts/cleanup-orphan-tmp.sh",
         value: "quality-pack/scripts/cleanup-orphan-tmp.sh"}
       ])
    | from_entries
  ' "${patch_path}")"

  if [[ -z "${output_path}" ]]; then
    output_path="$(mktemp "${settings_path}.tmp.XXXXXX")" || return 1
    legacy_in_place=1
  fi
  [[ -f "${base_path}" && -f "${patch_path}" \
      && -f "${render_patch_path}" && -f "${output_path}" ]] || {
    [[ "${legacy_in_place}" -eq 0 ]] \
      || rm -f -- "${output_path}" 2>/dev/null || true
    return 1
  }

  local bypass_filter=""
  if [[ "${bypass}" == "true" ]]; then
    bypass_filter='
    | .permissions = ((.permissions // {}) + {"defaultMode": "bypassPermissions"})
    | .skipDangerousModePermissionPrompt = true'
  fi

  # OMC_OUTPUT_STYLE_PREF=preserve skips the outputStyle merge so a user
  # with their own style is never overwritten. Default "opencode" keeps
  # the historical "// default" behavior.
  local output_style_pref="${OMC_OUTPUT_STYLE_PREF:-opencode}"
  local output_style_pref_explicit="${OMC_OUTPUT_STYLE_PREF_EXPLICIT:-0}"
  [[ "${output_style_pref_explicit}" == "1" ]] \
    || output_style_pref_explicit="0"

  if ! jq -s \
    --arg output_style_pref "${output_style_pref}" \
    --argjson output_style_pref_explicit "${output_style_pref_explicit}" \
    --argjson managed_commands "${managed_commands_json}" '
    # Ownership is finite: exact patch commands plus the historical command
    # spellings assembled above. This intentionally does not parse arbitrary
    # wrappers or ignore trailing argv.
    def token_basename: split("/") | last;
    def canonical_invalid_json:
      if type == "object" then
        ["object", (to_entries | sort_by(.key)
          | map([.key, (.value | canonical_invalid_json)]))]
      elif type == "array" then ["array", map(canonical_invalid_json)]
      elif type == "boolean" then ["boolean", .]
      elif type == "null" then ["null"]
      elif type == "string" then ["string", .]
      elif type == "number" then ["number"]
      else ["unknown"]
      end;
    # Missing/null commands coalesce to the empty-string identity, matching
    # the Python `hook.get("command")` plus command_identity_text(None) path.
    # Every other JSON type remains distinct; in particular jq `//` must
    # not collapse boolean false into the missing-command identity.
    def hook_command:
      if type == "object" and has("command") and .command != null
      then .command else "" end;
    def managed_script_relative:
      if type == "string" then ($managed_commands[.] // "") else "" end;
    def command_identity_text:
      if . == null then ""
      elif type == "string" then .
      else canonical_invalid_json | tojson
      end;
    def script_basename:
      managed_script_relative | token_basename;
    def script_identity:
      . as $command
      | ($command | managed_script_relative) as $relative
      | if $relative != "" then "omc-managed:" + $relative
        else "foreign-command:" + ($command | command_identity_text)
        end;
    def entry_basenames:
      [(.hooks // [])[] | select(type == "object") | hook_command | script_identity];
    def entry_matcher:
      (.matcher // "");
    # Set equality via unique list compare (order- and dup-independent).
    def sets_equal($a; $b):
      ($a | unique) == ($b | unique);
    # Non-empty set intersection (any element of $a appears in $b).
    def sets_overlap($a; $b):
      any($a[]; . as $x | ($b | index($x)) != null);
    # Dedupe by exact managed/foreign command identity, later occurrence wins.
    # Preserve the first position allocated to each distinct identity.
    # Non-object hooks (explicit null, arrays, scalars) are filtered out
    # to match the Python `isinstance(h, dict)` guard.
    def dedupe_entry_hooks:
      .hooks = (
        reduce ((.hooks // [])[] | select(type == "object")) as $h ([];
          ($h | hook_command | script_identity) as $b
          | [range(0; length) as $i
             | select((.[$i] | hook_command | script_identity) == $b)
             | $i] as $matches
          | if ($matches | length) > 0 then
              .[$matches[0]] = $h
            else
              . + [$h]
            end
        )
      );
    # Hook-level merge: input is a base entry, $patch_hooks is an array
    # of patch hook objects. Returns the base entry with hooks updated —
    # patch hooks replace base hooks sharing an identity, new identities
    # are appended. Closes the multi-hook matcher collision bug. Non-
    # object patch hooks are filtered out for parity with Python.
    def merge_hook_level($patch_hooks):
      .hooks = (
        reduce ($patch_hooks[] | select(type == "object")) as $p_hook ((.hooks // []);
          ($p_hook | hook_command | script_identity) as $p_base
          | [range(0; length) as $i
             | select((.[$i] | hook_command | script_identity) == $p_base)
             | $i] as $matches
          | if ($matches | length) > 0 then
              .[$matches[0]] = $p_hook
            else
              . + [$p_hook]
            end
        )
      );
    # Normalize base entries before the three-phase merge loop:
    # 1. Dedupe within each entry by exact command identity (later wins).
    # 2. Collapse multiple same-matcher entries whose identity sets
    #    overlap into a single canonical entry. Disjoint same-matcher
    #    entries are left separate (preserves intentional user customization).
    # Closes metis finding #1 (migration path where an older buggy
    # installer left duplicate same-matcher entries in base settings).
    def normalize_base_entries:
      reduce .[] as $raw ([];
        if ($raw | type) != "object" then
          . + [$raw]
        else
          ($raw | dedupe_entry_hooks) as $entry
          | ($entry | entry_matcher) as $m
          | ($entry | entry_basenames) as $e_basenames
          | [range(0; length) as $i
             | select((.[$i] | type) == "object")
             | select((.[$i] | entry_matcher) == $m)
             | select(sets_overlap((.[$i] | entry_basenames); $e_basenames))
             | $i] as $matches
          | if ($matches | length) == 0 then
              . + [$entry]
            else
              .[$matches[0]] |= merge_hook_level($entry.hooks // [])
            end
        end
      );
    # v1.48 W3.1 upgrade prune (jq twin of SUPERSEDED_HOOKS in the python
    # implementation — keep in lockstep): wirings superseded by a
    # consolidation are removed from the pre-existing base before the
    # three-phase merge, or upgraders keep the old direct wiring alongside
    # its replacement and every consolidated hook double-fires.
    def superseded_tuples:
      {"SessionStart": {
         "": ["cleanup-orphan-resume.sh", "cleanup-orphan-tmp.sh"]},
       "PostToolUse": {
         "":     ["posttool-timing.sh"],
         "Bash": ["record-verification.sh",
                  "record-delivery-action.sh",
                  "circuit-breaker.sh"]},
       "Stop": {
         "": ["stop-guard.sh",
              "stop-time-summary.sh",
              "canary-claim-audit.sh",
              "stop-transcript-archive.sh"]}};
    def superseded_stop_basenames:
      ["stop-guard.sh",
       "stop-time-summary.sh",
       "canary-claim-audit.sh",
       "stop-transcript-archive.sh"];
    def is_managed_legacy_stop_command:
      . as $command
      | ($command | script_basename) as $basename
      | (superseded_stop_basenames | index($basename)) != null;
    def prune_superseded($event):
      ((superseded_tuples[$event]) // {}) as $by_matcher
      # Events with no supersessions pass through UNTOUCHED — the trailing
      # emptiness filter must never drop a pre-existing null/empty-hooks
      # entry in an unrelated event.
      | if ($by_matcher | length) == 0 then . else
        map(
          if type != "object" then .
          else
            # Bind through variables at each step: jq evaluates both
            # index-bracket and function-argument filters with the
            # CONTAINER as input, so inline $by_matcher[entry_matcher]
            # or index(.command|...) silently resolve against the wrong
            # value (that exact bug shipped twice in the first draft of
            # this def — keep the bindings).
            entry_matcher as $m
            | (($by_matcher[$m]) // []) as $gone
            | if (has("hooks") | not) then .
              else
                (.hooks // []) as $orig
                | [$orig[]
                   | select(
                       (type != "object")
                       or (
                         (hook_command | script_basename) as $b
                         | if $event == "Stop"
                              and ((superseded_stop_basenames | index($b)) != null)
                           then (hook_command | is_managed_legacy_stop_command | not)
                           else (($gone | index($b)) == null)
                           end
                       )
                   )] as $kept
                # Drop the entry ONLY when the prune itself emptied it —
                # a pre-existing empty/null-hooks entry must survive
                # exactly as the merge always treated it (python parity;
                # remediation re-review F-A). `empty` (not a null marker
                # + trailing filter): map(f) elides an element whose f
                # emits nothing, and a LITERAL null array element — which
                # python and pre-prune jq both keep — passes through the
                # type-guard branch untouched.
                | if ($kept | length) == ($orig | length) then .
                  elif ($kept | length) == 0 then empty
                  else .hooks = $kept
                  end
              end
          end)
        end;
    # Remove stale matcher copies of patch-managed identities that have one
    # canonical owner, then coalesce duplicates created by Phase 0 matcher
    # renames. Basenames intentionally installed under multiple matchers are
    # left matcher-scoped.
    def canonicalize_managed_entries($patch_entries):
      ([ $patch_entries[]
         | select(type == "object")
         | entry_matcher as $matcher
         | entry_basenames[]
         | {basename: ., matcher: $matcher}]
       | group_by(.basename)
       | map(select(([.[].matcher] | unique | length) == 1)
             | {key: .[0].basename, value: .[0].matcher})
       | from_entries) as $owners
      | map(
          if type != "object" then .
          else
            entry_matcher as $matcher
            | (.hooks // []) as $original
            | [$original[]
               | select(
                   (type != "object")
                   or ((hook_command | script_identity) as $basename
                       | (($owners[($basename // "")] // $matcher) == $matcher)))] as $remaining
            | if ($remaining | length) == ($original | length) then .
              elif ($remaining | length) == 0 then empty
              else .hooks = $remaining
              end
          end)
      | normalize_base_entries;
    # Merge a list of patch entries into a base entries array using the
    # three-phase algorithm: exact match → overlap → append.
    def merge_entries($patch_entries):
      # Snapshot the pre-patch entry count so Phase 0 only considers
      # ORIGINAL existing entries — not entries appended earlier in this
      # patch loop. Track which original indices Phase 0 has already
      # claimed so cascading renames are impossible when multiple patch
      # entries legitimately share a managed identity across matchers
      # (e.g. record-reviewer.sh wired to quality-reviewer, editor-critic,
      # excellence-reviewer, ...). The accumulator carries the live entries
      # array plus a claimed-index map; the closing `.entries` unwraps it
      # so merge_entries still returns a plain entries array.
      (length) as $original_count
      # Precompute the set of matcher values the patch installs. Phase 0
      # only fires when the existing entry''s matcher is NOT in this set:
      # if it still IS in the patch, Phase 1 will match it directly and
      # Phase 0 must not preempt. Encoded as an object for O(1) lookup.
      | ([$patch_entries[] | select(type == "object") | entry_matcher]
         | unique | map({(.): true}) | add // {}) as $patch_matcher_set
      | reduce $patch_entries[] as $p_entry ({entries: ., claimed: {}};
          ($p_entry | entry_matcher) as $p_matcher
          | ($p_entry | entry_basenames) as $p_basenames
          | .entries as $arr
          | .claimed as $cl
          # Phase 0: matcher-rename detection — original, unclaimed entries
          # only, and only when the existing matcher is no longer in the
          # patch. Skipped when the patch has no identities (empty entries
          # cannot disambiguate ownership).
          | [range(0; $original_count) as $i
             | select(($cl | has($i | tostring)) | not)
             | select(($arr[$i] | type) == "object")
             | select(($arr[$i] | entry_matcher) != $p_matcher)
             | select(($patch_matcher_set | has(($arr[$i] | entry_matcher))) | not)
             | select(($p_basenames | length) > 0)
             | select(sets_equal(($arr[$i] | entry_basenames); $p_basenames))
             | $i] as $rename
          | if ($rename | length) > 0 then
              {entries: ($arr | .[$rename[0]] = $p_entry),
               claimed: ($cl + {($rename[0] | tostring): true})}
            else
              # Phase 1: exact match on (matcher, identity set).
              [range(0; ($arr | length)) as $i
               | select(($arr[$i] | type) == "object")
               | select(($arr[$i] | entry_matcher) == $p_matcher)
               | select(sets_equal(($arr[$i] | entry_basenames); $p_basenames))
               | $i] as $exact
              | if ($exact | length) > 0 then
                  {entries: ($arr | .[$exact[0]] = $p_entry), claimed: $cl}
                else
                  # Phase 2: same matcher + non-empty identity intersection →
                  # hook-level merge on the first overlapping base entry.
                  [range(0; ($arr | length)) as $i
                   | select(($arr[$i] | type) == "object")
                   | select(($arr[$i] | entry_matcher) == $p_matcher)
                   | select(sets_overlap(($arr[$i] | entry_basenames); $p_basenames))
                   | $i] as $overlap
                  | if ($overlap | length) > 0 then
                      {entries: ($arr | .[$overlap[0]] |= merge_hook_level($p_entry.hooks // [])),
                       claimed: $cl}
                    else
                      # Phase 3: disjoint → append as a new entry.
                      {entries: ($arr + [$p_entry]), claimed: $cl}
                    end
                end
            end
        )
      | .entries;
    def merge_hooks($base; $patch):
      reduce ($patch | to_entries[]) as $item ($base;
        .[$item.key] = ((.[$item.key] // [])
          | normalize_base_entries
          | prune_superseded($item.key)
          | merge_entries($item.value // [])
          | canonicalize_managed_entries($item.value // []))
      );
    .[0] as $base
    | .[1] as $patch
    | $base
    | .statusLine = $patch.statusLine
    | (
        # Resolve OMC_OUTPUT_STYLE_PREF to a target bundled style name.
        # Used by both the legacy-migration path and the bundled-sync path
        # below.
        (if $output_style_pref == "executive" then "executive-brief"
         elif $output_style_pref == "opencode" then "oh-my-claude"
         else $patch.outputStyle
         end) as $target
        # Legacy migration: pre-v1.26.0 installs left "OpenCode Compact"
        # in settings, but the underlying style file was renamed to
        # oh-my-claude and the legacy file removed. Leaving the legacy
        # name would orphan the user (Claude Code cannot resolve it).
        # Always migrate, even under preserve — preserve protects user
        # choices, not installer artifacts pointing at a deleted style.
        | if .outputStyle == "OpenCode Compact" then
            .outputStyle = $target
          elif $output_style_pref == "preserve" then
            .
          else
            # A typed explicit env/conf preference is user authority and may
            # replace a custom style. The implicit default preserves custom
            # values; current bundled names still auto-sync.
            (.outputStyle) as $current
            | if $output_style_pref_explicit
                or ($current == null)
                or ($current == "oh-my-claude")
                or ($current == "executive-brief")
              then .outputStyle = $target
              else .
              end
          end
      )
    | .effortLevel = (.effortLevel // $patch.effortLevel)
    | .spinnerTipsEnabled = $patch.spinnerTipsEnabled
    | .spinnerVerbs = $patch.spinnerVerbs
    | .hooks = merge_hooks((.hooks // {}); ($patch.hooks // {}))
    '"${bypass_filter}"'
  ' "${base_path}" "${render_patch_path}" > "${output_path}"; then
    [[ "${legacy_in_place}" -eq 0 ]] \
      || rm -f -- "${output_path}" 2>/dev/null || true
    return 1
  fi
  if [[ "${legacy_in_place}" -eq 1 ]]; then
    mv -f -- "${output_path}" "${settings_path}"
  fi
}

# ---------------------------------------------------------------------------
# Settings merge transaction
# ---------------------------------------------------------------------------

SETTINGS_PATH="${CLAUDE_HOME}/settings.json"
SETTINGS_JSON_MAX_BYTES=16777216
SETTINGS_MERGE_ENGINE=""
SETTINGS_ORIGINAL_STATE=""
SETTINGS_PHYSICAL_TARGET=""
SETTINGS_BACKUP_SOURCE=""
SETTINGS_STAGE_PATH=""
SETTINGS_RENDER_BASE_PATH=""
SETTINGS_RENDER_PATCH_PATH=""
SETTINGS_RENDER_OUTPUT_PATH=""
SETTINGS_STAGE_COMMITTED=0
SETTINGS_SEAL_LEXICAL_KIND=""
SETTINGS_SEAL_LINK_TEXT=""
SETTINGS_SEAL_LEXICAL_PARENT_PATH=""
SETTINGS_SEAL_LEXICAL_PARENT_ID=""
SETTINGS_SEAL_LEXICAL_NODE_ID=""
SETTINGS_SEAL_PHYSICAL_PATH=""
SETTINGS_SEAL_PHYSICAL_PARENT_ID=""
SETTINGS_SEAL_TARGET_ID=""
SETTINGS_SEAL_HASH=""
SETTINGS_ORIGINAL_MODE=""
SETTINGS_SEAL_CONTENT_SNAPSHOT=""
SETTINGS_STAGE_SEAL_PATH=""
SETTINGS_STAGE_SEAL_PARENT_ID=""
SETTINGS_STAGE_SEAL_TARGET_ID=""
SETTINGS_STAGE_SEAL_NODE_ID=""
SETTINGS_STAGE_SEAL_HASH=""
SETTINGS_STAGE_SEAL_MODE=""
SETTINGS_STAGE_CONTENT_SNAPSHOT=""
SETTINGS_PUBLISHED_NODE_ID=""
SETTINGS_PUBLISHED_HASH=""
SETTINGS_PUBLISHED_MODE=""
SETTINGS_PUBLISHED_PARENT_ID=""

install_readlink_exact() {
  local path="${1:-}" reader="" resolved=""
  for reader in /usr/bin/readlink /bin/readlink; do
    [[ -x "${reader}" ]] || continue
    "${reader}" "${path}" 2>/dev/null
    return $?
  done
  resolved="$(command -v readlink 2>/dev/null || true)"
  case "${resolved}" in
    /nix/store/*/bin/readlink)
      [[ -f "${resolved}" && -x "${resolved}" ]] || return 1
      "${resolved}" "${path}" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

install_stat_value() {
  local path="${1:-}" bsd_format="${2:-}" gnu_format="${3:-}"
  local stat_tool="" resolved=""
  for stat_tool in /usr/bin/stat /bin/stat; do
    [[ -x "${stat_tool}" ]] || continue
    if "${stat_tool}" -c "${gnu_format}" "${path}" >/dev/null 2>&1; then
      "${stat_tool}" -c "${gnu_format}" "${path}" 2>/dev/null
      return $?
    fi
    if "${stat_tool}" -f "${bsd_format}" "${path}" >/dev/null 2>&1; then
      "${stat_tool}" -f "${bsd_format}" "${path}" 2>/dev/null
      return $?
    fi
  done
  resolved="$(command -v stat 2>/dev/null || true)"
  case "${resolved}" in
    /nix/store/*/bin/stat)
      [[ -f "${resolved}" && -x "${resolved}" ]] || return 1
      "${resolved}" -c "${gnu_format}" "${path}" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

install_file_identity() {
  install_stat_value "${1:-}" '%d:%i:%z:%c' '%d:%i:%s:%Z'
}

# Stable identity for a regular file whose bytes are attested separately.
# `install_capture_regular_file_snapshot` uses a private hard link to avoid a
# pathname-to-FIFO check/open race; creating and removing that link legitimately
# advances the inode ctime. External seals must therefore bind device, inode,
# and size plus their content hash/mode, not a ctime that the trusted reader
# itself changes. Keep `install_file_identity` for stages that are not read
# through the hard-link snapshot primitive.
install_snapshot_file_identity() {
  install_stat_value "${1:-}" '%d:%i:%z' '%d:%i:%s'
}

# fstat one inherited descriptor without comparing its /dev/fd pathname via
# `test -ef`. The latter is false on macOS because the descriptor is exposed
# through devfs even though stat(2) correctly reports the underlying file.
# Keep the same device/inode/size/ctime tuple as install_file_identity so a
# descriptor can be bound to the exact pathname generation captured before
# open. A regular-file suffix rejects FIFO/device substitutions.
install_descriptor_file_identity() {
  local fd="${1:-}" stat_tool="" value="" descriptor_path=""
  local identity="" resolved=""
  [[ "${fd}" =~ ^[0-9]{1,3}$ && $((10#${fd})) -le 255 ]] || return 1
  for stat_tool in /usr/bin/stat /bin/stat; do
    [[ -x "${stat_tool}" ]] || continue
    value="$("${stat_tool}" -f '%d:%i:%z:%c:%HT' \
      <&"${fd}" 2>/dev/null || true)"
    case "${value}" in
      *':Regular File') identity="${value%:Regular File}" ;;
      *) identity="" ;;
    esac
    if [[ "${identity}" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
      printf '%s\n' "${identity}"
      return 0
    fi
    for descriptor_path in "/proc/self/fd/${fd}" "/dev/fd/${fd}"; do
      value="$("${stat_tool}" -Lc '%d:%i:%s:%Z:%F' \
        "${descriptor_path}" 2>/dev/null || true)"
      case "${value}" in
        *':regular file') identity="${value%:regular file}" ;;
        *) identity="" ;;
      esac
      if [[ "${identity}" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
        printf '%s\n' "${identity}"
        return 0
      fi
    done
  done
  resolved="$(command -v stat 2>/dev/null || true)"
  case "${resolved}" in
    /nix/store/*/bin/stat)
      [[ -f "${resolved}" && -x "${resolved}" ]] || return 1
      for descriptor_path in "/proc/self/fd/${fd}" "/dev/fd/${fd}"; do
        value="$("${resolved}" -Lc '%d:%i:%s:%Z:%F' \
          "${descriptor_path}" 2>/dev/null || true)"
        case "${value}" in
          *':regular file') identity="${value%:regular file}" ;;
          *) identity="" ;;
        esac
        if [[ "${identity}" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
          printf '%s\n' "${identity}"
          return 0
        fi
      done
      ;;
  esac
  return 1
}

install_node_identity() {
  install_stat_value "${1:-}" '%d:%i' '%d:%i'
}

install_directory_identity() {
  install_stat_value "${1:-}" '%d:%i' '%d:%i'
}

install_file_mode() {
  install_stat_value "${1:-}" '%Lp' '%a'
}

# Copy one bounded regular generation through descriptors opened only after a
# private hard link proves the inode. This avoids the check/open FIFO race and
# corroborates in-place writes without relying on GNU/BSD stat behavior for
# descriptor paths. Callers parse only the returned snapshot and re-attest it
# immediately before using the result as install authority.
install_capture_regular_file_snapshot() (
  local source="${1:-}" snapshot="${2:-}" max_bytes="${3:-}"
  local pin_dir="" pin="" corroboration="" byte_limit="" size=""
  local pin_identity="" fd18_identity="" fd19_identity=""
  [[ -n "${source}" && -n "${snapshot}" && "${source}" != "${snapshot}" \
      && "${max_bytes}" =~ ^[1-9][0-9]{0,8}$ \
      && -f "${source}" && ! -L "${source}" \
      && -f "${snapshot}" && ! -L "${snapshot}" ]] || return 1
  byte_limit=$((10#${max_bytes} + 1))
  pin_dir="$(mktemp -d "${source}.install-read-pin.XXXXXX" 2>/dev/null)" \
    || return 1
  trap '[[ -z "${corroboration:-}" ]] || rm -f -- "${corroboration}" 2>/dev/null || true; [[ -z "${pin:-}" ]] || rm -f -- "${pin}" 2>/dev/null || true; [[ -z "${pin_dir:-}" ]] || rmdir "${pin_dir}" 2>/dev/null || true' EXIT
  chmod 700 "${pin_dir}" || return 1
  pin="${pin_dir}/source"
  corroboration="$(mktemp "${snapshot}.verify.XXXXXX")" || return 1
  command ln "${source}" "${pin}" 2>/dev/null || return 1
  [[ -f "${pin}" && ! -L "${pin}" && ! -L "${source}" \
      && "${pin}" -ef "${source}" ]] || return 1
  pin_identity="$(install_file_identity "${pin}")" || return 1
  exec 18<"${pin}" 19<"${pin}" || return 1
  fd18_identity="$(install_descriptor_file_identity 18)" || return 1
  fd19_identity="$(install_descriptor_file_identity 19)" || return 1
  [[ "${fd18_identity}" == "${pin_identity}" \
      && "${fd19_identity}" == "${pin_identity}" \
      && "$(install_file_identity "${pin}" 2>/dev/null || true)" \
        == "${pin_identity}" ]] || return 1
  LC_ALL=C head -c "${byte_limit}" <&18 >"${snapshot}" 2>/dev/null \
    || return 1
  LC_ALL=C head -c "${byte_limit}" <&19 >"${corroboration}" 2>/dev/null \
    || return 1
  [[ ! -L "${source}" && "${pin}" -ef "${source}" \
      && "$(install_descriptor_file_identity 18 2>/dev/null || true)" \
        == "${pin_identity}" \
      && "$(install_descriptor_file_identity 19 2>/dev/null || true)" \
        == "${pin_identity}" \
      && "$(install_file_identity "${pin}" 2>/dev/null || true)" \
        == "${pin_identity}" ]] \
    || return 1
  exec 18<&- 19<&-
  size="$(LC_ALL=C wc -c <"${snapshot}" 2>/dev/null)" || return 1
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ && $((10#${size})) -le $((10#${max_bytes})) ]] \
    || return 1
  LC_ALL=C tr -d '\000' <"${snapshot}" \
    | cmp -s - "${snapshot}" 2>/dev/null || return 1
  cmp -s "${snapshot}" "${corroboration}" 2>/dev/null
)

install_regular_file_snapshot_is_current() {
  local source="${1:-}" snapshot="${2:-}" max_bytes="${3:-}"
  local observed=""
  [[ -f "${source}" && ! -L "${source}" \
      && -f "${snapshot}" && ! -L "${snapshot}" ]] || return 1
  observed="$(mktemp "${snapshot}.current.XXXXXX")" || return 1
  if ! install_capture_regular_file_snapshot \
      "${source}" "${observed}" "${max_bytes}" \
      || ! cmp -s "${snapshot}" "${observed}" 2>/dev/null; then
    rm -f -- "${observed}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${observed}" 2>/dev/null
}

install_regular_snapshot_has_hash() {
  local snapshot="${1:-}" max_bytes="${2:-}" expected_hash="${3:-}"
  local observed="" digest=""
  [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  observed="$(mktemp "${snapshot}.hash.XXXXXX")" || return 1
  if ! install_capture_regular_file_snapshot \
      "${snapshot}" "${observed}" "${max_bytes}"; then
    rm -f -- "${observed}" 2>/dev/null || true
    return 1
  fi
  digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${observed}")" || {
      rm -f -- "${observed}" 2>/dev/null || true
      return 1
    }
  if [[ "${digest}" != "${expected_hash}" ]] \
      || ! install_regular_file_snapshot_is_current \
        "${snapshot}" "${observed}" "${max_bytes}"; then
    rm -f -- "${observed}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${observed}" 2>/dev/null
}

preflight_backup_prune_target() {
  local path="${1:-}" expected_id="${2:-}"
  local backups_root="${CLAUDE_HOME}/backups" parent_physical=""
  local target_physical=""
  [[ -n "${expected_id}" && "${path}" == "${backups_root}/oh-my-claude-"* \
      && "${path}" != *[[:cntrl:]]* && -d "${backups_root}" \
      && ! -L "${backups_root}" && -d "${path}" && ! -L "${path}" ]] \
    || return 1
  parent_physical="$(builtin cd -- "${backups_root}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  target_physical="$(builtin cd -- "${path}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  [[ "${target_physical}" == "${parent_physical%/}/${path##*/}" \
      && "$(install_directory_identity "${path}" 2>/dev/null || true)" \
        == "${expected_id}" ]]
}

backup_prune_control_paths_are_owned() {
  install_lock_generation_is_current \
    && [[ -n "${BACKUP_PRUNE_SEAL_FILE:-}" \
      && -f "${BACKUP_PRUNE_SEAL_FILE}" \
      && ! -L "${BACKUP_PRUNE_SEAL_FILE}" \
      && "$(install_node_identity "${BACKUP_PRUNE_SEAL_FILE}" \
        2>/dev/null || true)" == "${BACKUP_PRUNE_SEAL_FILE_ID:-}" \
      && -n "${BACKUP_PRUNE_ENUM_FILE:-}" \
      && -f "${BACKUP_PRUNE_ENUM_FILE}" \
      && ! -L "${BACKUP_PRUNE_ENUM_FILE}" \
      && "$(install_node_identity "${BACKUP_PRUNE_ENUM_FILE}" \
        2>/dev/null || true)" == "${BACKUP_PRUNE_ENUM_FILE_ID:-}" ]]
}

cleanup_backup_prune_controls() {
  if install_lock_generation_is_current; then
    if [[ -n "${BACKUP_PRUNE_ENUM_FILE:-}" \
        && -f "${BACKUP_PRUNE_ENUM_FILE}" \
        && ! -L "${BACKUP_PRUNE_ENUM_FILE}" \
        && "$(install_node_identity "${BACKUP_PRUNE_ENUM_FILE}" \
          2>/dev/null || true)" == "${BACKUP_PRUNE_ENUM_FILE_ID:-}" ]]; then
      rm -f -- "${BACKUP_PRUNE_ENUM_FILE}" 2>/dev/null || true
    fi
    if [[ -n "${BACKUP_PRUNE_SEAL_FILE:-}" \
        && -f "${BACKUP_PRUNE_SEAL_FILE}" \
        && ! -L "${BACKUP_PRUNE_SEAL_FILE}" \
        && "$(install_node_identity "${BACKUP_PRUNE_SEAL_FILE}" \
          2>/dev/null || true)" == "${BACKUP_PRUNE_SEAL_FILE_ID:-}" ]]; then
      rm -f -- "${BACKUP_PRUNE_SEAL_FILE}" 2>/dev/null || true
    fi
  fi
  BACKUP_PRUNE_SEAL_FILE=""
  BACKUP_PRUNE_SEAL_FILE_ID=""
  BACKUP_PRUNE_SEAL_FILE_HASH=""
  BACKUP_PRUNE_ENUM_FILE=""
  BACKUP_PRUNE_ENUM_FILE_ID=""
}

begin_backup_prune_seal() {
  install_lock_generation_is_current || return 1
  BACKUP_PRUNE_SEAL_FILE="$(mktemp \
    "${INSTALL_LOCK_DIR}/.backup-prune-seal.XXXXXX")" || return 1
  BACKUP_PRUNE_SEAL_FILE_ID="$(install_node_identity \
    "${BACKUP_PRUNE_SEAL_FILE}")" || return 1
  BACKUP_PRUNE_ENUM_FILE="$(mktemp \
    "${INSTALL_LOCK_DIR}/.backup-prune-enum.XXXXXX")" || return 1
  BACKUP_PRUNE_ENUM_FILE_ID="$(install_node_identity \
    "${BACKUP_PRUNE_ENUM_FILE}")" || return 1
  chmod 600 "${BACKUP_PRUNE_SEAL_FILE}" "${BACKUP_PRUNE_ENUM_FILE}" \
    2>/dev/null || return 1
  backup_prune_control_paths_are_owned
}

capture_backup_prune_subtree() {
  local root="${1:-}" expected_root_id="${2:-}" node="" state=""
  local node_id="" digest="" mode="" link_text="" root_mode=""
  local root_device=""
  backup_prune_control_paths_are_owned || return 1
  preflight_backup_prune_target "${root}" "${expected_root_id}" \
    || return 1
  [[ "${expected_root_id}" == *:* ]] || return 1
  root_device="${expected_root_id%%:*}"
  root_mode="$(install_file_mode "${root}")" || return 1
  printf '%s\t%s\troot\t%s\t-\t%s\t-\n' \
    "${root}" "${root}" "${expected_root_id}" "${root_mode}" \
    >> "${BACKUP_PRUNE_SEAL_FILE}" || return 1
  : > "${BACKUP_PRUNE_ENUM_FILE}" || return 1
  find -P "${root}" -mindepth 1 -print0 \
    > "${BACKUP_PRUNE_ENUM_FILE}" || return 1
  backup_prune_control_paths_are_owned || return 1
  while IFS= read -r -d '' node; do
    [[ "${node}" == "${root}/"* && "${node}" != *[[:cntrl:]]* ]] \
      || return 1
    state=""
    node_id=""
    digest="-"
    mode="-"
    link_text="-"
    if [[ -L "${node}" ]]; then
      state="symlink"
      node_id="$(install_node_identity "${node}")" || return 1
      link_text="$(readlink "${node}")" || return 1
      [[ -n "${link_text}" && "${link_text}" != *[[:cntrl:]]* ]] \
        || return 1
    elif [[ -f "${node}" ]]; then
      state="regular"
      node_id="$(install_node_identity "${node}")" || return 1
      digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${node}")" || return 1
      mode="$(install_file_mode "${node}")" || return 1
    elif [[ -d "${node}" ]]; then
      state="directory"
      node_id="$(install_node_identity "${node}")" || return 1
      mode="$(install_file_mode "${node}")" || return 1
    else
      # A backup generation is expected to contain ordinary filesystem nodes.
      # Never sweep a socket, FIFO, device, or other foreign special node.
      return 1
    fi
    # rm -rf traverses mount points. Never let backup retention become
    # authority to erase a separately mounted filesystem below the backup.
    [[ "${node_id}" == "${root_device}:"* ]] || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${root}" "${node}" "${state}" "${node_id}" "${digest}" \
      "${mode}" "${link_text}" >> "${BACKUP_PRUNE_SEAL_FILE}" \
      || return 1
  done < "${BACKUP_PRUNE_ENUM_FILE}"
  backup_prune_control_paths_are_owned || return 1
  preflight_backup_prune_target "${root}" "${expected_root_id}"
}

finalize_backup_prune_seal() {
  backup_prune_control_paths_are_owned || return 1
  chmod 400 "${BACKUP_PRUNE_SEAL_FILE}" 2>/dev/null || return 1
  BACKUP_PRUNE_SEAL_FILE_ID="$(install_node_identity \
    "${BACKUP_PRUNE_SEAL_FILE}")" || return 1
  BACKUP_PRUNE_SEAL_FILE_HASH="$(\trusted_sha256_file \
    "${TRUSTED_SHA256_TOOL}" "${BACKUP_PRUNE_SEAL_FILE}")" || return 1
  if [[ "$(install_node_identity "${BACKUP_PRUNE_ENUM_FILE}" \
      2>/dev/null || true)" != "${BACKUP_PRUNE_ENUM_FILE_ID}" ]]; then
    return 1
  fi
  rm -f -- "${BACKUP_PRUNE_ENUM_FILE}" || return 1
  BACKUP_PRUNE_ENUM_FILE=""
  BACKUP_PRUNE_ENUM_FILE_ID=""
  backup_prune_seal_is_current
}

backup_prune_seal_is_current() {
  install_lock_generation_is_current \
    && [[ -n "${BACKUP_PRUNE_SEAL_FILE:-}" \
      && -f "${BACKUP_PRUNE_SEAL_FILE}" \
      && ! -L "${BACKUP_PRUNE_SEAL_FILE}" \
      && "$(install_node_identity "${BACKUP_PRUNE_SEAL_FILE}" \
        2>/dev/null || true)" == "${BACKUP_PRUNE_SEAL_FILE_ID:-}" \
      && "$(install_file_mode "${BACKUP_PRUNE_SEAL_FILE}" \
        2>/dev/null || true)" == "400" \
      && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${BACKUP_PRUNE_SEAL_FILE}" 2>/dev/null || true)" \
        == "${BACKUP_PRUNE_SEAL_FILE_HASH:-}" ]]
}

backup_prune_subtree_seal_is_current() {
  local wanted="${1:-}" expected_root_id="${2:-}" row_root="" node=""
  local state="" node_id="" digest="" mode="" link_text=""
  local root_markers=0 sealed_count=0 current_count=0 enum_file=""
  local enum_id=""
  backup_prune_seal_is_current || return 1
  preflight_backup_prune_target "${wanted}" "${expected_root_id}" \
    || return 1
  while IFS=$'\t' read -r row_root node state node_id digest mode \
      link_text; do
    [[ "${row_root}" == "${wanted}" ]] || continue
    case "${state}" in
      root)
        [[ "${node}" == "${wanted}" \
            && "${node_id}" == "${expected_root_id}" \
            && "${digest}" == "-" && "${link_text}" == "-" \
            && "$(install_file_mode "${wanted}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        root_markers=$((root_markers + 1))
        ;;
      regular)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* \
            && -f "${node}" && ! -L "${node}" \
            && "$(install_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${node}" 2>/dev/null || true)" == "${digest}" \
            && "$(install_file_mode "${node}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        sealed_count=$((sealed_count + 1))
        ;;
      directory)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* \
            && -d "${node}" && ! -L "${node}" \
            && "$(install_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(install_file_mode "${node}" \
              2>/dev/null || true)" == "${mode}" ]] || return 1
        sealed_count=$((sealed_count + 1))
        ;;
      symlink)
        [[ "${node}" == "${wanted}/"* \
            && "${node}" != *[[:cntrl:]]* \
            && -L "${node}" \
            && "$(install_node_identity "${node}" \
              2>/dev/null || true)" == "${node_id}" \
            && "$(readlink "${node}" 2>/dev/null || true)" \
              == "${link_text}" ]] || return 1
        sealed_count=$((sealed_count + 1))
        ;;
      *) return 1 ;;
    esac
  done < "${BACKUP_PRUNE_SEAL_FILE}"
  [[ "${root_markers}" -eq 1 ]] || return 1

  enum_file="$(mktemp "${INSTALL_LOCK_DIR}/.backup-prune-check.XXXXXX")" \
    || return 1
  enum_id="$(install_node_identity "${enum_file}")" || return 1
  chmod 600 "${enum_file}" 2>/dev/null || return 1
  if ! find -P "${wanted}" -mindepth 1 -print0 > "${enum_file}" \
      || [[ "$(install_node_identity "${enum_file}" \
        2>/dev/null || true)" != "${enum_id}" ]]; then
    [[ -f "${enum_file}" && ! -L "${enum_file}" \
        && "$(install_node_identity "${enum_file}" \
          2>/dev/null || true)" == "${enum_id}" ]] \
      && rm -f -- "${enum_file}" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r -d '' node; do
    if [[ "${node}" != "${wanted}/"* \
        || "${node}" == *[[:cntrl:]]* ]]; then
      [[ "$(install_node_identity "${enum_file}" \
        2>/dev/null || true)" == "${enum_id}" ]] \
        && rm -f -- "${enum_file}" 2>/dev/null || true
      return 1
    fi
    current_count=$((current_count + 1))
  done < "${enum_file}"
  if [[ "$(install_node_identity "${enum_file}" \
      2>/dev/null || true)" != "${enum_id}" ]]; then
    return 1
  fi
  rm -f -- "${enum_file}" || return 1
  [[ "${current_count}" -eq "${sealed_count}" ]] || return 1
  preflight_backup_prune_target "${wanted}" "${expected_root_id}" \
    && backup_prune_seal_is_current
}

resolve_install_regular_file_physical_path() {
  local candidate="${1:-}" parent="" leaf="" physical_parent="" target=""
  local hops=0
  [[ "${candidate}" == /* && "${candidate}" != *[[:cntrl:]]* ]] || return 1
  while :; do
    parent="${candidate%/*}"
    leaf="${candidate##*/}"
    [[ -n "${parent}" ]] || parent="/"
    [[ -n "${leaf}" && "${leaf}" != "." && "${leaf}" != ".." ]] \
      || return 1
    physical_parent="$(builtin cd -- "${parent}" 2>/dev/null \
      && builtin pwd -P)" || return 1
    candidate="${physical_parent%/}/${leaf}"
    if [[ -L "${candidate}" ]]; then
      hops=$((hops + 1))
      [[ "${hops}" -le 40 ]] || return 1
      target="$(install_readlink_exact "${candidate}")" || return 1
      [[ -n "${target}" && "${target}" != *[[:cntrl:]]* ]] || return 1
      case "${target}" in
        /*) candidate="${target}" ;;
        *) candidate="${physical_parent%/}/${target}" ;;
      esac
      continue
    fi
    [[ -f "${candidate}" && ! -L "${candidate}" ]] || return 1
    printf '%s\n' "${candidate}"
    return 0
  done
}

validate_settings_merge_input() {
  local settings_file="${1:-}"
  local settings_size=""
  [[ -f "${settings_file}" && ! -L "${settings_file}" ]] || return 1
  settings_size="$(LC_ALL=C wc -c <"${settings_file}" 2>/dev/null)" \
    || return 1
  settings_size="${settings_size//[[:space:]]/}"
  [[ "${settings_size}" =~ ^[0-9]+$ \
      && $((10#${settings_size})) -le \
        $((10#${SETTINGS_JSON_MAX_BYTES:-16777216})) ]] || return 1
  LC_ALL=C tr -d '\000' <"${settings_file}" \
    | cmp -s - "${settings_file}" 2>/dev/null || return 1
  if [[ "${SETTINGS_MERGE_ENGINE}" == "python" ]]; then
    python3 - "${settings_file}" "${BYPASS_PERMISSIONS}" <<'PY'
import json
import pathlib
import sys

def reject_constant(value):
    raise ValueError(f"non-standard JSON constant: {value}")

def decoded_strings_are_nul_free(value):
    if isinstance(value, str):
        return "\x00" not in value
    if isinstance(value, list):
        return all(decoded_strings_are_nul_free(item) for item in value)
    if isinstance(value, dict):
        return all("\x00" not in key and decoded_strings_are_nul_free(item)
                   for key, item in value.items())
    return True

try:
    with pathlib.Path(sys.argv[1]).open() as handle:
        settings = json.load(handle, parse_constant=reject_constant)
except (OSError, ValueError) as exc:
    raise SystemExit(f"settings preflight failed: {exc}")

if not isinstance(settings, dict):
    raise SystemExit("settings preflight failed: settings root must be an object")
if not decoded_strings_are_nul_free(settings):
    raise SystemExit("settings preflight failed: decoded NUL is not allowed")
hooks = settings.get("hooks")
if hooks is not None and not isinstance(hooks, dict):
    raise SystemExit("settings preflight failed: hooks must be an object or null")
if isinstance(hooks, dict):
    for event, entries in hooks.items():
        if not isinstance(event, str) or (entries is not None and not isinstance(entries, list)):
            raise SystemExit("settings preflight failed: hook events must map to arrays or null")
        for entry in entries or []:
            if not isinstance(entry, dict):
                continue
            matcher = entry.get("matcher")
            if matcher is not None and not isinstance(matcher, str):
                raise SystemExit("settings preflight failed: hook matcher must be a string or null")
            entry_hooks = entry.get("hooks")
            if entry_hooks is not None and not isinstance(entry_hooks, list):
                raise SystemExit("settings preflight failed: entry hooks must be arrays or null")
if sys.argv[2] == "true":
    permissions = settings.get("permissions")
    if permissions is not None and not isinstance(permissions, dict):
        raise SystemExit("settings preflight failed: permissions must be an object or null in bypass mode")
PY
  else
    jq -e --argjson bypass "${BYPASS_PERMISSIONS}" '
      def decoded_strings_are_nul_free:
        if type == "string" then index("\u0000") == null
        elif type == "array" then all(.[]; decoded_strings_are_nul_free)
        elif type == "object" then
          all(to_entries[];
            (.key | index("\u0000") == null)
            and (.value | decoded_strings_are_nul_free))
        else true
        end;
      def valid_entry:
        if type != "object" then true
        else
          ((has("matcher") | not) or .matcher == null
            or (.matcher | type) == "string")
          and ((has("hooks") | not) or .hooks == null
            or (.hooks | type) == "array")
        end;
      type == "object"
      and decoded_strings_are_nul_free
      and ((has("hooks") | not) or .hooks == null
        or ((.hooks | type) == "object"
          and all(.hooks | to_entries[];
            (.key | type) == "string"
            and (.value == null or ((.value | type) == "array"
              and all(.value[]; valid_entry))))))
      and (($bypass | not)
        or (has("permissions") | not) or .permissions == null
        or (.permissions | type) == "object")
    ' "${settings_file}" >/dev/null
  fi
}

preflight_existing_settings_input() {
  local physical="" snapshot="" parent=""
  if command -v python3 >/dev/null 2>&1; then
    SETTINGS_MERGE_ENGINE="python"
  else
    SETTINGS_MERGE_ENGINE="jq"
  fi

  if [[ ! -e "${SETTINGS_PATH}" && ! -L "${SETTINGS_PATH}" ]]; then
    SETTINGS_ORIGINAL_STATE="absent"
    return 0
  fi
  if ! physical="$(resolve_install_regular_file_physical_path \
      "${SETTINGS_PATH}" 2>/dev/null)"; then
    printf 'Refusing install: settings.json is dangling or not a regular file: %s\n' \
      "${SETTINGS_PATH}" >&2
    return 1
  fi
  SETTINGS_PHYSICAL_TARGET="${physical}"
  SETTINGS_BACKUP_SOURCE="${physical}"
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  snapshot="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-preflight.XXXXXX")" \
    || return 1
  if ! install_capture_regular_file_snapshot \
      "${physical}" "${snapshot}" "${SETTINGS_JSON_MAX_BYTES}" \
      || ! validate_settings_merge_input "${snapshot}" \
      || ! install_regular_file_snapshot_is_current \
        "${physical}" "${snapshot}" "${SETTINGS_JSON_MAX_BYTES}"; then
    rm -f -- "${snapshot}" 2>/dev/null || true
    printf 'Refusing install: existing settings.json cannot be merged safely. Installed files were not changed.\n' >&2
    return 1
  fi
  rm -f -- "${snapshot}" 2>/dev/null || return 1
}

capture_settings_install_seal() {
  local lexical_parent="${SETTINGS_PATH%/*}" lexical_leaf="${SETTINGS_PATH##*/}"
  local lexical_parent_physical="" physical="" physical_parent=""

  [[ -n "${lexical_parent}" ]] || lexical_parent="/"
  lexical_parent_physical="$(builtin cd -- "${lexical_parent}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  SETTINGS_SEAL_LEXICAL_PARENT_PATH="${lexical_parent_physical}"
  SETTINGS_SEAL_LEXICAL_PARENT_ID="$(install_directory_identity \
    "${lexical_parent_physical}")" || return 1

  if [[ ! -e "${SETTINGS_PATH}" && ! -L "${SETTINGS_PATH}" ]]; then
    SETTINGS_SEAL_LEXICAL_KIND="absent"
    SETTINGS_SEAL_LINK_TEXT=""
    SETTINGS_SEAL_LEXICAL_NODE_ID=""
    SETTINGS_SEAL_PHYSICAL_PATH="${lexical_parent_physical%/}/${lexical_leaf}"
    SETTINGS_PHYSICAL_TARGET="${SETTINGS_SEAL_PHYSICAL_PATH}"
    SETTINGS_SEAL_PHYSICAL_PARENT_ID="${SETTINGS_SEAL_LEXICAL_PARENT_ID}"
    SETTINGS_SEAL_TARGET_ID=""
    SETTINGS_SEAL_HASH=""
    SETTINGS_ORIGINAL_MODE="600"
    SETTINGS_BACKUP_SOURCE=""
    return 0
  fi

  if [[ -L "${SETTINGS_PATH}" ]]; then
    SETTINGS_SEAL_LEXICAL_KIND="symlink"
    SETTINGS_SEAL_LINK_TEXT="$(install_readlink_exact "${SETTINGS_PATH}")" \
      || return 1
  elif [[ -f "${SETTINGS_PATH}" ]]; then
    SETTINGS_SEAL_LEXICAL_KIND="regular"
    SETTINGS_SEAL_LINK_TEXT=""
  else
    return 1
  fi
  SETTINGS_SEAL_LEXICAL_NODE_ID="$(install_node_identity \
    "${SETTINGS_PATH}")" || return 1
  physical="$(resolve_install_regular_file_physical_path \
    "${SETTINGS_PATH}" 2>/dev/null)" || return 1
  physical_parent="${physical%/*}"
  [[ -n "${physical_parent}" ]] || physical_parent="/"
  SETTINGS_PHYSICAL_TARGET="${physical}"
  SETTINGS_BACKUP_SOURCE="${physical}"
  SETTINGS_SEAL_PHYSICAL_PATH="${physical}"
  SETTINGS_SEAL_PHYSICAL_PARENT_ID="$(install_directory_identity \
    "${physical_parent}")" || return 1
  SETTINGS_SEAL_TARGET_ID="$(install_snapshot_file_identity \
    "${physical}")" || return 1
  SETTINGS_SEAL_CONTENT_SNAPSHOT="$(mktemp \
    "${physical_parent%/}/.settings.json.oh-my-claude-original.XXXXXX")" \
    || return 1
  if ! install_capture_regular_file_snapshot "${physical}" \
      "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}"; then
    return 1
  fi
  SETTINGS_SEAL_HASH="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${SETTINGS_SEAL_CONTENT_SNAPSHOT}")" || return 1
  SETTINGS_ORIGINAL_MODE="$(install_file_mode "${physical}")" || return 1
  chmod 400 "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" || return 1
  install_regular_file_snapshot_is_current "${physical}" \
    "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}" \
    || return 1
  [[ "${SETTINGS_SEAL_HASH}" =~ ^[0-9A-Fa-f]{64}$ \
      && "${SETTINGS_ORIGINAL_MODE}" =~ ^[0-7]{3,4}$ ]]
}

settings_install_seal_is_current() {
  local lexical_kind="" link_text="" lexical_node_id=""
  local lexical_parent="${SETTINGS_PATH%/*}"
  local lexical_parent_physical="" lexical_parent_id="" physical=""
  local physical_parent="" physical_parent_id="" target_id=""
  local mode=""

  [[ -n "${lexical_parent}" ]] || lexical_parent="/"
  lexical_parent_physical="$(builtin cd -- "${lexical_parent}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  lexical_parent_id="$(install_directory_identity \
    "${lexical_parent_physical}")" || return 1
  [[ "${lexical_parent_physical}" == "${SETTINGS_SEAL_LEXICAL_PARENT_PATH}" \
      && "${lexical_parent_id}" == "${SETTINGS_SEAL_LEXICAL_PARENT_ID}" ]] \
    || return 1

  if [[ "${SETTINGS_SEAL_LEXICAL_KIND}" == "absent" ]]; then
    [[ ! -e "${SETTINGS_PATH}" && ! -L "${SETTINGS_PATH}" \
        && "${SETTINGS_SEAL_PHYSICAL_PARENT_ID}" == "${lexical_parent_id}" ]]
    return $?
  fi

  if [[ -L "${SETTINGS_PATH}" ]]; then
    lexical_kind="symlink"
    link_text="$(install_readlink_exact "${SETTINGS_PATH}")" || return 1
  elif [[ -f "${SETTINGS_PATH}" ]]; then
    lexical_kind="regular"
  else
    return 1
  fi
  lexical_node_id="$(install_node_identity "${SETTINGS_PATH}")" || return 1
  [[ "${lexical_kind}" == "${SETTINGS_SEAL_LEXICAL_KIND}" \
      && "${link_text}" == "${SETTINGS_SEAL_LINK_TEXT}" \
      && "${lexical_node_id}" == "${SETTINGS_SEAL_LEXICAL_NODE_ID}" ]] \
    || return 1
  physical="$(resolve_install_regular_file_physical_path \
    "${SETTINGS_PATH}" 2>/dev/null)" || return 1
  [[ "${physical}" == "${SETTINGS_SEAL_PHYSICAL_PATH}" ]] || return 1
  physical_parent="${physical%/*}"
  [[ -n "${physical_parent}" ]] || physical_parent="/"
  physical_parent_id="$(install_directory_identity "${physical_parent}")" \
    || return 1
  target_id="$(install_snapshot_file_identity "${physical}")" || return 1
  mode="$(install_file_mode "${physical}")" || return 1
  [[ "${physical_parent_id}" == "${SETTINGS_SEAL_PHYSICAL_PARENT_ID}" \
      && "${target_id}" == "${SETTINGS_SEAL_TARGET_ID}" \
      && "${mode}" == "${SETTINGS_ORIGINAL_MODE}" ]] \
    && install_regular_snapshot_has_hash \
      "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}" \
      "${SETTINGS_SEAL_HASH}" \
    && install_regular_file_snapshot_is_current "${physical}" \
      "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}"
}

capture_settings_stage_seal() {
  local parent="${SETTINGS_STAGE_PATH%/*}"
  [[ -n "${SETTINGS_STAGE_PATH}" && -f "${SETTINGS_STAGE_PATH}" \
      && ! -L "${SETTINGS_STAGE_PATH}" ]] || return 1
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_STAGE_SEAL_PATH="${SETTINGS_STAGE_PATH}"
  SETTINGS_STAGE_SEAL_PARENT_ID="$(install_directory_identity "${parent}")" \
    || return 1
  SETTINGS_STAGE_SEAL_TARGET_ID="$(install_snapshot_file_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  SETTINGS_STAGE_SEAL_NODE_ID="$(install_node_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  SETTINGS_STAGE_CONTENT_SNAPSHOT="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-sealed.XXXXXX")" || return 1
  if ! install_capture_regular_file_snapshot "${SETTINGS_STAGE_PATH}" \
      "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}"; then
    return 1
  fi
  SETTINGS_STAGE_SEAL_HASH="$(\trusted_sha256_file \
    "${TRUSTED_SHA256_TOOL}" "${SETTINGS_STAGE_CONTENT_SNAPSHOT}")" \
    || return 1
  SETTINGS_STAGE_SEAL_MODE="$(install_file_mode "${SETTINGS_STAGE_PATH}")" \
    || return 1
  chmod 400 "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" || return 1
  install_regular_file_snapshot_is_current "${SETTINGS_STAGE_PATH}" \
    "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}" \
    || return 1
  [[ "${SETTINGS_STAGE_SEAL_HASH}" =~ ^[0-9A-Fa-f]{64}$ \
      && "${SETTINGS_STAGE_SEAL_MODE}" =~ ^[0-7]{3,4}$ ]]
}

settings_stage_seal_is_current() {
  local parent="${SETTINGS_STAGE_PATH%/*}" parent_id="" target_id=""
  local mode=""
  [[ -n "${SETTINGS_STAGE_PATH}" \
      && "${SETTINGS_STAGE_PATH}" == "${SETTINGS_STAGE_SEAL_PATH}" \
      && -f "${SETTINGS_STAGE_PATH}" && ! -L "${SETTINGS_STAGE_PATH}" ]] \
    || return 1
  [[ -n "${parent}" ]] || parent="/"
  parent_id="$(install_directory_identity "${parent}")" || return 1
  target_id="$(install_snapshot_file_identity \
    "${SETTINGS_STAGE_PATH}")" || return 1
  mode="$(install_file_mode "${SETTINGS_STAGE_PATH}")" || return 1
  [[ "${parent_id}" == "${SETTINGS_STAGE_SEAL_PARENT_ID}" \
      && "${target_id}" == "${SETTINGS_STAGE_SEAL_TARGET_ID}" \
      && "${mode}" == "${SETTINGS_STAGE_SEAL_MODE}" ]] \
    && install_regular_snapshot_has_hash \
      "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}" \
      "${SETTINGS_STAGE_SEAL_HASH}" \
    && install_regular_file_snapshot_is_current "${SETTINGS_STAGE_PATH}" \
      "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}"
}

published_settings_install_is_current() {
  local lexical_parent="${SETTINGS_PATH%/*}" lexical_parent_physical=""
  local physical=""
  if [[ "${SETTINGS_SEAL_LEXICAL_KIND}" == "symlink" ]]; then
    [[ -n "${lexical_parent}" ]] || lexical_parent="/"
    lexical_parent_physical="$(builtin cd -- "${lexical_parent}" \
      2>/dev/null && builtin pwd -P)" || return 1
    [[ "${lexical_parent_physical}" \
          == "${SETTINGS_SEAL_LEXICAL_PARENT_PATH}" \
        && "$(install_directory_identity "${lexical_parent_physical}" \
          2>/dev/null || true)" == "${SETTINGS_SEAL_LEXICAL_PARENT_ID}" \
        && -L "${SETTINGS_PATH}" \
        && "$(install_node_identity "${SETTINGS_PATH}" \
          2>/dev/null || true)" == "${SETTINGS_SEAL_LEXICAL_NODE_ID}" \
        && "$(install_readlink_exact "${SETTINGS_PATH}" \
          2>/dev/null || true)" == "${SETTINGS_SEAL_LINK_TEXT}" ]] \
      || return 1
    physical="$(resolve_install_regular_file_physical_path \
      "${SETTINGS_PATH}" 2>/dev/null)" || return 1
    [[ "${physical}" == "${SETTINGS_SEAL_PHYSICAL_PATH}" ]] || return 1
  fi
  [[ "${SETTINGS_STAGE_COMMITTED:-0}" -eq 1 \
      && -f "${SETTINGS_SEAL_PHYSICAL_PATH}" \
      && ! -L "${SETTINGS_SEAL_PHYSICAL_PATH}" \
      && "$(install_directory_identity \
          "${SETTINGS_SEAL_PHYSICAL_PATH%/*}" 2>/dev/null || true)" \
        == "${SETTINGS_PUBLISHED_PARENT_ID}" \
      && "$(install_node_identity "${SETTINGS_SEAL_PHYSICAL_PATH}" \
          2>/dev/null || true)" == "${SETTINGS_PUBLISHED_NODE_ID}" \
      && "$(install_file_mode "${SETTINGS_SEAL_PHYSICAL_PATH}" \
          2>/dev/null || true)" == "${SETTINGS_PUBLISHED_MODE}" ]] \
    && install_regular_snapshot_has_hash \
      "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}" \
      "${SETTINGS_PUBLISHED_HASH}" \
    && install_regular_file_snapshot_is_current \
      "${SETTINGS_SEAL_PHYSICAL_PATH}" \
      "${SETTINGS_STAGE_CONTENT_SNAPSHOT}" "${SETTINGS_JSON_MAX_BYTES}"
}

capture_pre_merge_statusline() {
  local source_file="${1:-}"
  PRE_MERGE_STATUSLINE_CMD=""
  [[ -n "${source_file}" && -f "${source_file}" ]] || return 0
  if [[ "${SETTINGS_MERGE_ENGINE}" == "python" ]]; then
    PRE_MERGE_STATUSLINE_CMD="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
    status_line = data.get("statusLine") or {}
    if isinstance(status_line, dict):
        command = status_line.get("command") or ""
        sys.stdout.write(command if isinstance(command, str) else "")
except Exception:
    pass
' "${source_file}" 2>/dev/null || true)"
  else
    PRE_MERGE_STATUSLINE_CMD="$(jq -r '.statusLine.command // empty' \
      "${source_file}" 2>/dev/null || true)"
  fi
}

stage_settings_install_merge() {
  local parent="" copied_hash="" base_hash="" patch_hash="" render_rc=0
  local render_base_hash="" render_patch_hash="" render_patch_hash_second=""
  local render_base_identity="" render_patch_identity=""
  if ! capture_settings_install_seal; then
    printf 'Refusing install: settings.json changed type or target after preflight. No bundle files were copied.\n' >&2
    return 1
  fi
  parent="${SETTINGS_SEAL_PHYSICAL_PATH%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_STAGE_PATH="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-install.XXXXXX")" || {
      printf 'Refusing install: cannot stage settings merge beside publication target: %s\n' \
        "${SETTINGS_SEAL_PHYSICAL_PATH}" >&2
      return 1
    }

  if [[ "${SETTINGS_SEAL_LEXICAL_KIND}" == "absent" ]]; then
    printf '{}\n' > "${SETTINGS_STAGE_PATH}"
  else
    if ! cp -p -- "${SETTINGS_SEAL_CONTENT_SNAPSHOT}" \
        "${SETTINGS_STAGE_PATH}"; then
      printf 'Refusing install: could not snapshot settings.json in its publication directory.\n' >&2
      return 1
    fi
    copied_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${SETTINGS_STAGE_PATH}")" || return 1
    if [[ "${copied_hash}" != "${SETTINGS_SEAL_HASH}" ]]; then
      printf 'Refusing install: settings.json changed while its staged snapshot was copied.\n' >&2
      return 1
    fi
  fi

  base_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${SETTINGS_STAGE_PATH}")" || return 1
  if ! validate_settings_merge_input "${SETTINGS_STAGE_PATH}"; then
    printf 'Refusing install: staged settings snapshot is no longer mergeable. No bundle files were copied.\n' >&2
    return 1
  fi
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Refusing install: source settings patch changed before merge rendering. No bundle files were copied.\n' >&2
    return 1
  fi

  # Render from inherited descriptors whose private backing names are removed
  # before either parser starts. Validation of a pathname followed by a fresh
  # Python/jq open otherwise lets an ABA replacement supply merge authority and
  # restore the sealed bytes before the post-render check.
  SETTINGS_RENDER_BASE_PATH="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-base.XXXXXX")" || return 1
  SETTINGS_RENDER_PATCH_PATH="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-patch.XXXXXX")" || return 1
  SETTINGS_RENDER_OUTPUT_PATH="$(mktemp \
    "${parent%/}/.settings.json.oh-my-claude-render.XXXXXX")" || return 1
  if ! cp -- "${SETTINGS_STAGE_PATH}" "${SETTINGS_RENDER_BASE_PATH}" \
      || ! cp -- "${SETTINGS_PATCH_SNAPSHOT}" \
        "${SETTINGS_RENDER_PATCH_PATH}" \
      || ! chmod 400 "${SETTINGS_RENDER_BASE_PATH}" \
        "${SETTINGS_RENDER_PATCH_PATH}" \
      || ! chmod 600 "${SETTINGS_RENDER_OUTPUT_PATH}" \
      || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${SETTINGS_RENDER_BASE_PATH}" 2>/dev/null || true)" \
        != "${base_hash}" ]] \
      || ! patch_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${SETTINGS_RENDER_PATCH_PATH}")" \
      || [[ "${patch_hash}" != "${SETTINGS_PATCH_SNAPSHOT_HASH}" ]] \
      || ! validate_settings_merge_input "${SETTINGS_RENDER_BASE_PATH}" \
      || ! settings_install_seal_is_current \
      || ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Refusing install: settings merge inputs changed while private render descriptors were prepared. No bundle files were copied.\n' >&2
    return 1
  fi
  install_test_barrier \
    "${OMC_TEST_INSTALL_SETTINGS_RENDER_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_SETTINGS_RENDER_RELEASE_FILE:-}" \
    "${SETTINGS_RENDER_BASE_PATH}" || return 1
  render_base_identity="$(install_file_identity \
    "${SETTINGS_RENDER_BASE_PATH}")" || return 1
  render_patch_identity="$(install_file_identity \
    "${SETTINGS_RENDER_PATCH_PATH}")" || return 1
  exec 8<"${SETTINGS_RENDER_BASE_PATH}" \
    9<"${SETTINGS_RENDER_PATCH_PATH}" \
    10<"${SETTINGS_RENDER_PATCH_PATH}" \
    11<"${SETTINGS_RENDER_BASE_PATH}" \
    12<"${SETTINGS_RENDER_PATCH_PATH}" \
    13<"${SETTINGS_RENDER_PATCH_PATH}" \
    14<"${SETTINGS_RENDER_BASE_PATH}" || return 1
  if [[ "$(install_descriptor_file_identity 8 2>/dev/null || true)" \
        != "${render_base_identity}" \
      || "$(install_descriptor_file_identity 11 2>/dev/null || true)" \
        != "${render_base_identity}" \
      || "$(install_descriptor_file_identity 14 2>/dev/null || true)" \
        != "${render_base_identity}" \
      || "$(install_file_identity "${SETTINGS_RENDER_BASE_PATH}" \
          2>/dev/null || true)" != "${render_base_identity}" \
      || "$(install_descriptor_file_identity 9 2>/dev/null || true)" \
        != "${render_patch_identity}" \
      || "$(install_descriptor_file_identity 10 2>/dev/null || true)" \
        != "${render_patch_identity}" \
      || "$(install_descriptor_file_identity 12 2>/dev/null || true)" \
        != "${render_patch_identity}" \
      || "$(install_descriptor_file_identity 13 2>/dev/null || true)" \
        != "${render_patch_identity}" \
      || "$(install_file_identity "${SETTINGS_RENDER_PATCH_PATH}" \
          2>/dev/null || true)" != "${render_patch_identity}" ]]; then
    exec 8<&- 9<&- 10<&- 11<&- 12<&- 13<&- 14<&-
    return 1
  fi
  rm -f -- "${SETTINGS_RENDER_BASE_PATH}" \
    "${SETTINGS_RENDER_PATCH_PATH}" || {
      exec 8<&- 9<&- 10<&- 11<&- 12<&- 13<&- 14<&-
      return 1
    }
  SETTINGS_RENDER_BASE_PATH=""
  SETTINGS_RENDER_PATCH_PATH=""
  # The inherited descriptors, rather than the now-absent private names, are
  # the renderer's complete authority. Hash them only after unlinking the
  # names so an ABA replacement between the earlier validation and `exec`
  # cannot become the input merely because all descriptors opened the same
  # replacement inode. jq receives two independent patch descriptors because
  # its ownership-map pass consumes one before the render pass begins.
  if ! render_base_hash="$(\trusted_sha256_descriptor \
        "${TRUSTED_SHA256_TOOL}" 11)" \
      || ! render_patch_hash="$(\trusted_sha256_descriptor \
        "${TRUSTED_SHA256_TOOL}" 12)" \
      || ! render_patch_hash_second="$(\trusted_sha256_descriptor \
        "${TRUSTED_SHA256_TOOL}" 13)" \
      || [[ "${render_base_hash}" != "${base_hash}" \
        || "${render_patch_hash}" != "${SETTINGS_PATCH_SNAPSHOT_HASH}" \
        || "${render_patch_hash_second}" != \
          "${SETTINGS_PATCH_SNAPSHOT_HASH}" ]]; then
    exec 8<&- 9<&- 10<&- 11<&- 12<&- 13<&- 14<&-
    printf 'Refusing install: private settings render descriptors did not match their sealed inputs. No bundle files were copied.\n' >&2
    return 1
  fi
  capture_pre_merge_statusline /dev/fd/14
  exec 11<&- 12<&- 13<&- 14<&-
  if [[ "${SETTINGS_MERGE_ENGINE}" == "python" ]]; then
    merge_settings_python /dev/fd/8 /dev/fd/9 \
      "${BYPASS_PERMISSIONS}" "${SETTINGS_RENDER_OUTPUT_PATH}" \
      || render_rc=$?
  else
    merge_settings_jq /dev/fd/8 /dev/fd/9 \
      "${BYPASS_PERMISSIONS}" "${SETTINGS_RENDER_OUTPUT_PATH}" \
      /dev/fd/10 || render_rc=$?
  fi
  exec 8<&- 9<&- 10<&-
  if [[ "${render_rc}" -ne 0 ]]; then
    printf 'Refusing install: could not render the complete settings merge. No bundle files were copied.\n' >&2
    return "${render_rc}"
  fi
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current \
      || ! settings_install_seal_is_current; then
    printf 'Refusing install: source settings patch changed during merge rendering. No bundle files were copied.\n' >&2
    return 1
  fi
  chmod "${SETTINGS_ORIGINAL_MODE}" "${SETTINGS_RENDER_OUTPUT_PATH}" \
    || return 1
  if [[ ! -f "${SETTINGS_RENDER_OUTPUT_PATH}" \
      || -L "${SETTINGS_RENDER_OUTPUT_PATH}" ]] \
      || ! validate_settings_merge_input "${SETTINGS_RENDER_OUTPUT_PATH}"; then
    printf 'Refusing install: rendered settings stage failed structural validation. No bundle files were copied.\n' >&2
    return 1
  fi
  mv -f -- "${SETTINGS_RENDER_OUTPUT_PATH}" "${SETTINGS_STAGE_PATH}" \
    || return 1
  SETTINGS_RENDER_OUTPUT_PATH=""
  if ! capture_settings_stage_seal; then
    printf 'Refusing install: could not seal the rendered settings stage. No bundle files were copied.\n' >&2
    return 1
  fi
  install_test_barrier \
    "${OMC_TEST_INSTALL_PATCH_RENDER_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_PATCH_RENDER_RELEASE_FILE:-}" \
    "${SETTINGS_STAGE_PATH}" || return 1
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current \
      || ! settings_stage_seal_is_current; then
    printf 'Refusing install: a settings merge authority changed after rendering. No bundle files were copied.\n' >&2
    return 1
  fi
  if ! settings_install_seal_is_current; then
    printf 'Refusing install: settings.json changed while the merge was staged. No bundle files were copied.\n' >&2
    return 1
  fi
}

publish_staged_settings_install() {
  [[ -n "${SETTINGS_STAGE_PATH}" ]] || return 1
  install_test_barrier \
    "${OMC_TEST_INSTALL_SETTINGS_STAGE_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_SETTINGS_STAGE_RELEASE_FILE:-}" \
    "${SETTINGS_STAGE_PATH}" || return 1
  if ! settings_patch_seal_is_current \
      || ! settings_patch_snapshot_is_current; then
    printf 'Install stopped before settings publication because the source settings patch authority changed.\n' >&2
    return 1
  fi
  if ! settings_install_seal_is_current; then
    printf 'Install stopped before settings publication because settings.json was edited or retargeted concurrently.\n' >&2
    printf 'The concurrent user version was preserved. Restore other prior managed files from %s if needed, then rerun install.sh.\n' \
      "${BACKUP_DIR}" >&2
    return 1
  fi
  if ! settings_stage_seal_is_current; then
    printf 'Install stopped before settings publication because the rendered settings stage was replaced or modified.\n' >&2
    return 1
  fi
  # Write-ahead rollback authority: the expected publication seal comes from
  # the immutable stage and is armed before the rename. If rename never lands,
  # rollback recognizes the unchanged initial settings seal as a no-op.
  SETTINGS_STAGE_COMMITTED=1
  SETTINGS_PUBLISHED_NODE_ID="${SETTINGS_STAGE_SEAL_NODE_ID}"
  SETTINGS_PUBLISHED_HASH="${SETTINGS_STAGE_SEAL_HASH}"
  SETTINGS_PUBLISHED_MODE="${SETTINGS_STAGE_SEAL_MODE}"
  SETTINGS_PUBLISHED_PARENT_ID="${SETTINGS_STAGE_SEAL_PARENT_ID}"
  if ! mv -f -- "${SETTINGS_STAGE_PATH}" "${SETTINGS_SEAL_PHYSICAL_PATH}"; then
    printf 'Failed to publish staged settings atomically to physical target: %s\n' \
      "${SETTINGS_SEAL_PHYSICAL_PATH}" >&2
    printf 'Restore prior state from %s and rerun install.sh after repairing the target directory.\n' \
      "${BACKUP_DIR}" >&2
    return 1
  fi
  SETTINGS_STAGE_PATH=""
  if ! published_settings_install_is_current; then
    printf 'Install stopped after settings publication because the published leaf no longer matches the sealed stage. The concurrent version will be preserved during rollback.\n' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Backup existing targets before overwriting
# ---------------------------------------------------------------------------

# Read authority metadata only after proving that the complete bounded file is
# canonical.  The raw-byte filters run before `read`, so Bash never gets a
# chance to normalize NUL bytes or trailing records into a usable credential.
# The reconstruction comparison also catches a concurrent/encoding-changing
# read.  Transaction histories use the companion whole-file validator before
# importing any row.
install_metadata_file_is_canonical() {
  local path="${1:-}" max_bytes="${2:-1048576}"
  local byte_count="" newline_count="" record=""
  [[ -f "${path}" && ! -L "${path}" \
      && "${max_bytes}" =~ ^[1-9][0-9]{0,7}$ ]] || return 1
  byte_count="$(LC_ALL=C wc -c < "${path}" 2>/dev/null)" || return 1
  byte_count="${byte_count//[[:space:]]/}"
  [[ "${byte_count}" =~ ^[0-9]{1,8}$ ]] || return 1
  (( 10#${byte_count} >= 2 && 10#${byte_count} <= 10#${max_bytes} )) \
    || return 1
  LC_ALL=C tr -d '\000\r' < "${path}" \
    | cmp -s - "${path}" 2>/dev/null || return 1
  newline_count="$(LC_ALL=C tr -cd '\n' < "${path}" \
    | LC_ALL=C wc -c 2>/dev/null)" || return 1
  newline_count="${newline_count//[[:space:]]/}"
  [[ "${newline_count}" =~ ^[1-9][0-9]{0,7}$ ]] || return 1
  LC_ALL=C tail -c 1 "${path}" 2>/dev/null \
    | cmp -s - <(printf '\n') 2>/dev/null || return 1
  {
    while IFS= read -r record; do
      [[ -n "${record}" ]] || exit 1
      printf '%s\n' "${record}"
    done < "${path}"
  } | cmp -s - "${path}" 2>/dev/null
}

install_read_canonical_metadata_snapshot() {
  local path="${1:-}" max_bytes="${2:-1048576}" snapshot=""
  install_metadata_file_is_canonical "${path}" "${max_bytes}" || return 1
  snapshot="$(< "${path}")" 2>/dev/null || return 1
  [[ -n "${snapshot}" ]] || return 1
  printf '%s\n' "${snapshot}" | cmp -s - "${path}" 2>/dev/null || return 1
  printf '%s' "${snapshot}"
}

install_read_canonical_metadata_line() {
  local path="${1:-}" max_bytes="${2:-4096}" record=""
  record="$(install_read_canonical_metadata_snapshot \
    "${path}" "${max_bytes}")" || return 1
  [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
  printf '%s' "${record}"
}

capture_install_transaction_ancestor_seal() {
  local target="${1:-}" key="${2:-}" parent="" current="/"
  local relative="" segment="" identity="" seal_path=""
  local -a segments=()
  [[ "${target}" == /* && "${target}" != *[[:cntrl:]]* \
      && "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  seal_path="${INSTALL_TRANSACTION_DIR}/${key}.initial-ancestor-seal"
  : > "${seal_path}" || return 1
  identity="$(install_directory_identity /)" || return 1
  printf '%s\t/\n' "${identity}" >> "${seal_path}" || return 1
  relative="${parent#/}"
  [[ -z "${relative}" ]] && { chmod 400 "${seal_path}"; return $?; }
  IFS='/' read -r -a segments <<< "${relative}"
  for segment in "${segments[@]}"; do
    [[ -n "${segment}" && "${segment}" != "." \
        && "${segment}" != ".." ]] || return 1
    current="${current%/}/${segment}"
    if [[ ! -e "${current}" && ! -L "${current}" ]]; then
      break
    fi
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    identity="$(install_directory_identity "${current}")" || return 1
    printf '%s\t%s\n' "${identity}" "${current}" \
      >> "${seal_path}" || return 1
  done
  chmod 400 "${seal_path}" 2>/dev/null || return 1
}

install_transaction_ancestor_seal_is_current() {
  local key="${1:-}" expected_id="" path="" row="" rows=0
  local seal_snapshot=""
  local seal_path="${INSTALL_TRANSACTION_DIR}/${key}.initial-ancestor-seal"
  [[ -f "${seal_path}" && ! -L "${seal_path}" ]] || return 1
  seal_snapshot="$(install_read_canonical_metadata_snapshot \
    "${seal_path}" 1048576)" || return 1
  while IFS= read -r row; do
    [[ "${row}" == *$'\t'* ]] || return 1
    expected_id="${row%%$'\t'*}"
    path="${row#*$'\t'}"
    [[ "${path}" != *$'\t'* \
        && "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
        && "${path}" == /* && "${path}" != *[[:cntrl:]]* \
        && -d "${path}" && ! -L "${path}" \
        && "$(install_directory_identity "${path}" \
          2>/dev/null || true)" == "${expected_id}" ]] || return 1
    rows=$((rows + 1))
  done <<< "${seal_snapshot}"
  [[ "${rows}" -gt 0 ]]
}

ensure_install_transaction_parent() {
  local target="${1:-}" key="${2:-}" parent="" relative=""
  local current="/" segment="" expected_parent_id="" created_id=""
  local shared_key="${3:-}" shared_expected_parent_id=""
  local shared_created_path="" shared_created_id=""
  local created_path="${INSTALL_TRANSACTION_DIR}/${key}.created-parent-id"
  local -a segments=()
  [[ "${target}" == /* && "${target}" != *[[:cntrl:]]* \
      && "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  expected_parent_id="$(install_read_canonical_metadata_line \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-parent-id" 128)" || return 1
  [[ "${expected_parent_id}" == "absent" \
      || "${expected_parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  install_transaction_ancestor_seal_is_current "${key}" || return 1
  if [[ "${expected_parent_id}" != "absent" ]]; then
    install_transaction_path_phase_is_current "${target}" "${key}" initial
    return $?
  fi
  if [[ -f "${created_path}" && ! -L "${created_path}" ]]; then
    created_id="$(install_read_canonical_metadata_line \
      "${created_path}" 128)" || return 1
    [[ "${created_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(install_directory_identity "${parent}" \
          2>/dev/null || true)" == "${created_id}" ]] || return 1
    return 0
  fi
  # Several installer-owned leaves share quality-pack/state. The first key
  # creates that parent; later keys may bind to the exact same transaction-
  # created directory, but only through an explicit sibling key whose sealed
  # initial parent was also absent. This keeps an arbitrary pre-existing or
  # concurrently substituted directory from becoming publication authority.
  if [[ -e "${parent}" || -L "${parent}" ]]; then
    [[ "${shared_key}" =~ ^[a-z0-9-]+$ \
        && "${shared_key}" != "${key}" ]] || return 1
    shared_expected_parent_id="$(install_read_canonical_metadata_line \
      "${INSTALL_TRANSACTION_DIR}/${shared_key}.initial-parent-id" \
      128)" || return 1
    [[ "${shared_expected_parent_id}" == "absent" ]] || return 1
    install_transaction_ancestor_seal_is_current "${shared_key}" || return 1
    shared_created_path="${INSTALL_TRANSACTION_DIR}/${shared_key}.created-parent-id"
    [[ -f "${shared_created_path}" && ! -L "${shared_created_path}" ]] \
      || return 1
    shared_created_id="$(install_read_canonical_metadata_line \
      "${shared_created_path}" 128)" || return 1
    [[ "${shared_created_id}" =~ ^[0-9]+:[0-9]+$ \
        && -d "${parent}" && ! -L "${parent}" \
        && "$(install_directory_identity "${parent}" \
          2>/dev/null || true)" == "${shared_created_id}" ]] || return 1
    printf '%s\n' "${shared_created_id}" > "${created_path}" || return 1
    chmod 400 "${created_path}" 2>/dev/null || return 1
    install_transaction_path_phase_is_current \
      "${target}" "${key}" initial 1
    return $?
  fi
  [[ ! -e "${parent}" && ! -L "${parent}" ]] || return 1
  relative="${parent#/}"
  IFS='/' read -r -a segments <<< "${relative}"
  for segment in "${segments[@]}"; do
    [[ -n "${segment}" && "${segment}" != "." \
        && "${segment}" != ".." ]] || return 1
    current="${current%/}/${segment}"
    if [[ ! -e "${current}" && ! -L "${current}" ]]; then
      install_transaction_ancestor_seal_is_current "${key}" || return 1
      mkdir -- "${current}" 2>/dev/null || return 1
    fi
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
  done
  created_id="$(install_directory_identity "${parent}")" || return 1
  printf '%s\n' "${created_id}" > "${created_path}" || return 1
  chmod 400 "${created_path}" 2>/dev/null || return 1
  install_transaction_ancestor_seal_is_current "${key}" \
    && [[ "$(install_directory_identity "${parent}" \
      2>/dev/null || true)" == "${created_id}" ]]
}

snapshot_install_transaction_path() {
  local target="${1:-}" key="${2:-}" state_path="" payload_path=""
  local parent="" parent_id="" node_id="" digest="" mode="" link_text=""
  [[ -n "${INSTALL_TRANSACTION_DIR}" && -d "${INSTALL_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_TRANSACTION_DIR}" \
      && "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  state_path="${INSTALL_TRANSACTION_DIR}/${key}.state"
  payload_path="${INSTALL_TRANSACTION_DIR}/${key}.payload"
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  rm -f -- "${state_path}" "${payload_path}" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-parent-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-hash" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-mode" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-link" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-state" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-parent-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-hash" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-mode" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-link" \
    "${INSTALL_TRANSACTION_DIR}/${key}.initial-ancestor-seal" \
    "${INSTALL_TRANSACTION_DIR}/${key}.created-parent-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-history" \
    2>/dev/null || return 1
  capture_install_transaction_ancestor_seal "${target}" "${key}" \
    || return 1
  if [[ -d "${parent}" && ! -L "${parent}" ]]; then
    parent_id="$(install_directory_identity "${parent}")" || return 1
  elif [[ ! -e "${parent}" && ! -L "${parent}" ]]; then
    parent_id="absent"
  else
    return 1
  fi
  printf '%s\n' "${parent_id}" \
    > "${INSTALL_TRANSACTION_DIR}/${key}.initial-parent-id" || return 1
  if [[ -L "${target}" ]]; then
    node_id="$(install_node_identity "${target}")" || return 1
    link_text="$(install_readlink_exact "${target}")" || return 1
    [[ -n "${link_text}" && "${link_text}" != *[[:cntrl:]]* ]] || return 1
    rsync -a -- "${target}" "${payload_path}" || return 1
    [[ -L "${payload_path}" \
        && "$(install_readlink_exact "${payload_path}" 2>/dev/null || true)" \
          == "${link_text}" ]] || return 1
    printf 'symlink\n' > "${state_path}" || return 1
    printf '%s\n' "${node_id}" \
      > "${INSTALL_TRANSACTION_DIR}/${key}.initial-id" || return 1
    printf '%s\n' "${link_text}" \
      > "${INSTALL_TRANSACTION_DIR}/${key}.initial-link" || return 1
  elif [[ -f "${target}" ]]; then
    node_id="$(install_node_identity "${target}")" || return 1
    digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${target}")" || return 1
    mode="$(install_file_mode "${target}")" || return 1
    rsync -a -- "${target}" "${payload_path}" || return 1
    [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${payload_path}" 2>/dev/null || true)" == "${digest}" \
        && "$(install_file_mode "${payload_path}" 2>/dev/null || true)" \
          == "${mode}" ]] || return 1
    printf 'regular\n' > "${state_path}" || return 1
    printf '%s\n' "${node_id}" \
      > "${INSTALL_TRANSACTION_DIR}/${key}.initial-id" || return 1
    printf '%s\n' "${digest}" \
      > "${INSTALL_TRANSACTION_DIR}/${key}.initial-hash" || return 1
    printf '%s\n' "${mode}" \
      > "${INSTALL_TRANSACTION_DIR}/${key}.initial-mode" || return 1
  elif [[ -e "${target}" ]]; then
    return 1
  else
    printf 'absent\n' > "${state_path}" || return 1
  fi
  chmod 400 "${state_path}" 2>/dev/null || return 1
  install_transaction_path_phase_is_current "${target}" "${key}" initial
}

install_transaction_path_phase_is_current() {
  local target="${1:-}" key="${2:-}" phase="${3:-}"
  local allow_created_parent="${4:-0}"
  local state_path="" state="" parent="" expected_parent_id=""
  local expected_id="" expected_hash="" expected_mode="" expected_link=""
  [[ "${key}" =~ ^[a-z0-9-]+$ \
      && "${phase}" =~ ^(initial|published)$ ]] || return 1
  state_path="${INSTALL_TRANSACTION_DIR}/${key}.${phase}-state"
  [[ "${phase}" == "initial" ]] \
    && state_path="${INSTALL_TRANSACTION_DIR}/${key}.state"
  [[ -f "${state_path}" && ! -L "${state_path}" ]] || return 1
  install_transaction_ancestor_seal_is_current "${key}" || return 1
  state="$(install_read_canonical_metadata_line "${state_path}" 32)" \
    || return 1
  [[ "${state}" =~ ^(absent|regular|symlink)$ ]] || return 1
  expected_parent_id="$(install_read_canonical_metadata_line \
    "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-parent-id" 128)" || return 1
  [[ "${expected_parent_id}" == "absent" \
      || "${expected_parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  if [[ "${expected_parent_id}" == "absent" ]]; then
    if [[ "${allow_created_parent}" -eq 1 && "${state}" == "absent" ]]; then
      if [[ -e "${parent}" || -L "${parent}" ]]; then
        [[ -d "${parent}" && ! -L "${parent}" \
            && -f "${INSTALL_TRANSACTION_DIR}/${key}.created-parent-id" \
            && ! -L "${INSTALL_TRANSACTION_DIR}/${key}.created-parent-id" \
            && "$(install_directory_identity "${parent}" \
              2>/dev/null || true)" \
              == "$(install_read_canonical_metadata_line \
                "${INSTALL_TRANSACTION_DIR}/${key}.created-parent-id" \
                128 2>/dev/null || true)" ]] || return 1
      fi
    else
      [[ ! -e "${parent}" && ! -L "${parent}" \
          && "${state}" == "absent" ]] || return 1
    fi
  else
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(install_directory_identity "${parent}" 2>/dev/null || true)" \
          == "${expected_parent_id}" ]] || return 1
  fi
  case "${state}" in
    absent)
      [[ ! -e "${target}" && ! -L "${target}" ]]
      ;;
    regular)
      expected_id="$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-id" 128)" || return 1
      expected_hash="$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-hash" 128)" || return 1
      expected_mode="$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-mode" 16)" || return 1
      [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
          && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
          && "${expected_mode}" =~ ^[0-7]{3,4}$ \
          && -f "${target}" && ! -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${expected_id}" \
          && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${target}" 2>/dev/null || true)" == "${expected_hash}" \
          && "$(install_file_mode "${target}" 2>/dev/null || true)" \
            == "${expected_mode}" ]]
      ;;
    symlink)
      expected_id="$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-id" 128)" || return 1
      expected_link="$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.${phase}-link" 4096)" || return 1
      [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
          && "${expected_link}" != *[[:cntrl:]]* \
          && -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${expected_id}" \
          && "$(install_readlink_exact "${target}" 2>/dev/null || true)" \
            == "${expected_link}" ]]
      ;;
    *) return 1 ;;
  esac
}

clear_install_transaction_publication() {
  local key="${1:-}"
  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  rm -f -- "${INSTALL_TRANSACTION_DIR}/${key}.published-state" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-parent-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-id" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-hash" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-mode" \
    "${INSTALL_TRANSACTION_DIR}/${key}.published-link" 2>/dev/null
}

arm_install_transaction_publication() {
  local target="${1:-}" key="${2:-}" parent="" parent_id=""
  local expected_state="${3:-}" expected_id="${4:-}"
  local expected_hash="${5:-}" expected_mode="${6:-}"
  local expected_link="${7:-}"
  [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 \
      && "${key}" =~ ^[a-z0-9-]+$ \
      && "${expected_state}" =~ ^(absent|regular|symlink)$ ]] || return 1
  clear_install_transaction_publication "${key}" || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  printf '%s\n' "${parent_id}" \
    > "${INSTALL_TRANSACTION_DIR}/${key}.published-parent-id" || return 1
  case "${expected_state}" in
    regular)
      [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
          && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
          && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
      printf '%s\n' "${expected_id}" \
        > "${INSTALL_TRANSACTION_DIR}/${key}.published-id" || return 1
      printf '%s\n' "${expected_hash}" \
        > "${INSTALL_TRANSACTION_DIR}/${key}.published-hash" || return 1
      printf '%s\n' "${expected_mode}" \
        > "${INSTALL_TRANSACTION_DIR}/${key}.published-mode" || return 1
      ;;
    symlink)
      [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
          && -n "${expected_link}" \
          && "${expected_link}" != *[[:cntrl:]]* ]] || return 1
      printf '%s\n' "${expected_id}" \
        > "${INSTALL_TRANSACTION_DIR}/${key}.published-id" || return 1
      printf '%s\n' "${expected_link}" \
        > "${INSTALL_TRANSACTION_DIR}/${key}.published-link" || return 1
      ;;
    absent) ;;
  esac
  printf '%s\n' "${expected_state}" \
    > "${INSTALL_TRANSACTION_DIR}/${key}.published-state" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${parent_id}" "${expected_state}" "${expected_id}" \
    "${expected_hash}" "${expected_mode}" "${expected_link}" \
    >> "${INSTALL_TRANSACTION_DIR}/${key}.published-history" || return 1
}

record_install_transaction_publication() {
  local target="${1:-}" key="${2:-}" expected_state="${3:-}"
  local expected_id="${4:-}" expected_hash="${5:-}"
  local expected_mode="${6:-}" expected_link="${7:-}"
  [[ "$(install_read_canonical_metadata_line \
        "${INSTALL_TRANSACTION_DIR}/${key}.published-state" 32 \
        2>/dev/null || true)" == "${expected_state}" ]] || return 1
  case "${expected_state}" in
    regular)
      [[ "$(install_read_canonical_metadata_line \
            "${INSTALL_TRANSACTION_DIR}/${key}.published-id" 128)" \
            == "${expected_id}" \
          && "$(install_read_canonical_metadata_line \
            "${INSTALL_TRANSACTION_DIR}/${key}.published-hash" 128)" \
            == "${expected_hash}" \
          && "$(install_read_canonical_metadata_line \
            "${INSTALL_TRANSACTION_DIR}/${key}.published-mode" 16)" \
            == "${expected_mode}" ]] || return 1
      ;;
    symlink)
      [[ "$(install_read_canonical_metadata_line \
            "${INSTALL_TRANSACTION_DIR}/${key}.published-id" 128)" \
            == "${expected_id}" \
          && "$(install_read_canonical_metadata_line \
            "${INSTALL_TRANSACTION_DIR}/${key}.published-link" 4096)" \
            == "${expected_link}" ]] || return 1
      ;;
    absent) ;;
    *) return 1 ;;
  esac
  install_transaction_path_phase_is_current "${target}" "${key}" published
}

install_transaction_any_published_generation_is_current() {
  local target="${1:-}" key="${2:-}" parent_id="" state="" expected_id=""
  local expected_hash="" expected_mode="" expected_link="" parent=""
  local row="" rest="" matched=0 history_snapshot=""
  local history="${INSTALL_TRANSACTION_DIR}/${key}.published-history"
  [[ -f "${history}" && ! -L "${history}" ]] || return 1
  history_snapshot="$(install_read_canonical_metadata_snapshot \
    "${history}" 1048576)" || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  while IFS= read -r row; do
    rest="${row}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    parent_id="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    state="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    expected_id="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    expected_hash="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    [[ "${rest}" == *$'\t'* ]] || return 1
    expected_mode="${rest%%$'\t'*}"
    expected_link="${rest#*$'\t'}"
    [[ "${expected_link}" != *$'\t'* \
        && "${parent_id}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    case "${state}" in
      absent)
        [[ -z "${expected_id}${expected_hash}${expected_mode}${expected_link}" ]] \
          || return 1
        ;;
      regular)
        [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
            && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
            && "${expected_mode}" =~ ^[0-7]{3,4}$ \
            && -z "${expected_link}" ]] || return 1
        ;;
      symlink)
        [[ "${expected_id}" =~ ^[0-9]+:[0-9]+$ \
            && -z "${expected_hash}${expected_mode}" \
            && -n "${expected_link}" \
            && "${expected_link}" != *[[:cntrl:]]* ]] || return 1
        ;;
      *) return 1 ;;
    esac
    [[ -d "${parent}" && ! -L "${parent}" \
        && "$(install_directory_identity "${parent}" 2>/dev/null || true)" \
          == "${parent_id}" ]] || continue
    case "${state}" in
      absent)
        [[ ! -e "${target}" && ! -L "${target}" ]] && matched=1
        ;;
      regular)
        [[ -f "${target}" && ! -L "${target}" \
            && "$(install_node_identity "${target}" 2>/dev/null || true)" \
              == "${expected_id}" \
            && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
                "${target}" 2>/dev/null || true)" == "${expected_hash}" \
            && "$(install_file_mode "${target}" 2>/dev/null || true)" \
              == "${expected_mode}" ]] && matched=1
        ;;
      symlink)
        [[ -L "${target}" \
            && "$(install_node_identity "${target}" 2>/dev/null || true)" \
              == "${expected_id}" \
            && "$(install_readlink_exact "${target}" 2>/dev/null || true)" \
              == "${expected_link}" ]] && matched=1
        ;;
    esac
  done <<< "${history_snapshot}"
  [[ "${matched}" -eq 1 ]]
}

verify_install_transaction_publication_if_armed() {
  local target="${1:-}" key="${2:-}"
  local history="${INSTALL_TRANSACTION_DIR}/${key}.published-history"
  if [[ ! -e "${history}" && ! -L "${history}" ]]; then
    return 0
  fi
  [[ -f "${history}" && ! -L "${history}" ]] || return 1
  install_transaction_path_phase_is_current "${target}" "${key}" published
}

verify_all_install_transaction_publications() {
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/oh-my-claude.conf" config || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt" manifest \
    || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt" hashes \
    || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/quality-pack/state/last-install-report.json" report \
    || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/.install-stamp" stamp || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
    legacy-output-style || return 1
  verify_install_transaction_publication_if_armed \
    "${TARGET_HOME}/.local/bin/omc" omc-cli || return 1
  verify_install_transaction_publication_if_armed \
    "${CLAUDE_HOME}/omc-user/overrides.md" user-overrides || return 1
  verify_install_transaction_publication_if_armed \
    "${GHOSTTY_HOME}/themes/Claude OpenCode" ghostty-theme || return 1
  verify_install_transaction_publication_if_armed \
    "${GHOSTTY_HOME}/config" ghostty-config || return 1
  if [[ -n "${GIT_HOOK_TRANSACTION_PATH:-}" ]]; then
    verify_install_transaction_publication_if_armed \
      "${GIT_HOOK_TRANSACTION_PATH}" git-hook || return 1
  fi
}

restore_install_transaction_path() {
  local target="${1:-}" key="${2:-}" state_path="" payload_path="" state=""
  state_path="${INSTALL_TRANSACTION_DIR}/${key}.state"
  payload_path="${INSTALL_TRANSACTION_DIR}/${key}.payload"
  [[ -f "${state_path}" && ! -L "${state_path}" ]] || return 1
  # A snapshot is not mutation authority. Restore only a generation this run
  # actually published, and only while its exact identity/hash/mode or link
  # target is still current.
  [[ -f "${INSTALL_TRANSACTION_DIR}/${key}.published-history" ]] || return 0
  # The publication record is armed before rename/removal. If execution died
  # before that mutation, the exact initial generation is already restored.
  # A parent created by this transaction is harmless for an initially absent
  # leaf, so allow that narrow case while still binding pre-existing parents.
  if install_transaction_path_phase_is_current \
      "${target}" "${key}" initial 1; then
    return 0
  fi
  if ! install_transaction_any_published_generation_is_current \
      "${target}" "${key}"; then
    printf '  [error] %s changed after installer publication; preserving the concurrent version during rollback.\n' \
      "${target}" >&2
    return 1
  fi
  state="$(install_read_canonical_metadata_line "${state_path}" 32)" \
    || return 1
  case "${state}" in
    regular|symlink)
      [[ -f "${payload_path}" || -L "${payload_path}" ]] || return 1
      [[ -d "${target%/*}" && ! -L "${target%/*}" ]] || return 1
      restore_backup_path_exact "${payload_path}" "${target}"
      ;;
    absent)
      [[ ! -d "${target}" || -L "${target}" ]] || return 1
      rm -f -- "${target}"
      ;;
    *) return 1 ;;
  esac
}

# Publish one installer-owned regular file through a same-directory sealed
# stage. `allow_created_parent=1` is only for a leaf whose parent was absent in
# the transaction snapshot and has since been created by this invocation.
publish_install_regular_stage() {
  local stage="${1:-}" target="${2:-}" key="${3:-}"
  local allow_created_parent="${4:-0}" parent="" parent_id=""
  local stage_id="" stage_hash="" stage_mode=""
  [[ "${key}" =~ ^[a-z0-9-]+$ \
      && "${allow_created_parent}" =~ ^[01]$ \
      && -f "${stage}" && ! -L "${stage}" ]] || return 1
  parent="${target%/*}"
  [[ -n "${parent}" ]] || parent="/"
  [[ -d "${parent}" && ! -L "${parent}" \
      && "${stage%/*}" == "${parent}" ]] || return 1
  install_transaction_path_phase_is_current \
    "${target}" "${key}" initial "${allow_created_parent}" || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  stage_id="$(install_node_identity "${stage}")" || return 1
  stage_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${stage}")" || return 1
  stage_mode="$(install_file_mode "${stage}")" || return 1
  if [[ -n "${OMC_TEST_INSTALL_GENERIC_STAGE_MATCH:-}" \
      && "${target}" == "${OMC_TEST_INSTALL_GENERIC_STAGE_MATCH}" ]]; then
    install_test_barrier \
      "${OMC_TEST_INSTALL_GENERIC_STAGE_READY_FILE:-}" \
      "${OMC_TEST_INSTALL_GENERIC_STAGE_RELEASE_FILE:-}" \
      "${target}" || return 1
  fi
  if ! install_transaction_path_phase_is_current \
      "${target}" "${key}" initial "${allow_created_parent}" \
      || [[ "$(install_directory_identity "${parent}" \
          2>/dev/null || true)" != "${parent_id}" \
        || ! -f "${stage}" || -L "${stage}" \
        || "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          != "${stage_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${stage}" 2>/dev/null || true)" != "${stage_hash}" \
        || "$(install_file_mode "${stage}" 2>/dev/null || true)" \
          != "${stage_mode}" ]]; then
    return 1
  fi
  arm_install_transaction_publication "${target}" "${key}" regular \
    "${stage_id}" "${stage_hash}" "${stage_mode}" || return 1
  mv -f -- "${stage}" "${target}" || return 1
  record_install_transaction_publication "${target}" "${key}" regular \
    "${stage_id}" "${stage_hash}" "${stage_mode}"
}

publish_install_regular_source() {
  local source="${1:-}" target="${2:-}" key="${3:-}"
  local intended_mode="${4:-}" allow_created_parent="${5:-0}"
  local parent="" leaf="" parent_id="" source_id="" source_hash=""
  local source_mode="" stage="" stage_id=""
  [[ -f "${source}" && ! -L "${source}" ]] || return 1
  parent="${target%/*}"
  leaf="${target##*/}"
  [[ -n "${parent}" ]] || parent="/"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  source_id="$(install_file_identity "${source}")" || return 1
  source_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${source}")" || return 1
  source_mode="$(install_file_mode "${source}")" || return 1
  [[ -z "${intended_mode}" || "${intended_mode}" =~ ^[0-7]{3,4}$ ]] \
    || return 1
  stage="$(mktemp "${parent}/.${leaf}.oh-my-claude.XXXXXX")" || return 1
  stage_id="$(install_node_identity "${stage}")" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  if ! cp -p -- "${source}" "${stage}"; then
    [[ "$(install_node_identity "${stage}" 2>/dev/null || true)" \
        == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  # cp may replace the mktemp inode; refresh ownership after successful copy.
  stage_id="$(install_node_identity "${stage}")" || return 1
  if [[ -n "${intended_mode}" ]] \
      && ! chmod "${intended_mode}" "${stage}"; then
    [[ "$(install_node_identity "${stage}" 2>/dev/null || true)" \
        == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  if [[ "$(install_directory_identity "${parent}" \
        2>/dev/null || true)" != "${parent_id}" \
      || ! -f "${source}" || -L "${source}" \
      || "$(install_file_identity "${source}" 2>/dev/null || true)" \
        != "${source_id}" \
      || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${source}" 2>/dev/null || true)" != "${source_hash}" \
      || "$(install_file_mode "${source}" 2>/dev/null || true)" \
        != "${source_mode}" ]] \
      || ! publish_install_regular_stage "${stage}" "${target}" "${key}" \
        "${allow_created_parent}"; then
    [[ "$(install_node_identity "${stage}" 2>/dev/null || true)" \
        == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

publish_install_symlink() {
  local target="${1:-}" link_text="${2:-}" key="${3:-}"
  local parent="" leaf="" parent_id="" stage="" stage_id=""
  [[ "${key}" =~ ^[a-z0-9-]+$ && -n "${link_text}" ]] || return 1
  parent="${target%/*}"
  leaf="${target##*/}"
  [[ -n "${parent}" ]] || parent="/"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  install_transaction_path_phase_is_current "${target}" "${key}" initial \
    || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  stage="$(mktemp "${parent}/.${leaf}.oh-my-claude-link.XXXXXX")" \
    || return 1
  rm -f -- "${stage}" || return 1
  ln -s -- "${link_text}" "${stage}" || return 1
  stage_id="$(install_node_identity "${stage}")" || return 1
  if ! install_transaction_path_phase_is_current \
      "${target}" "${key}" initial \
      || [[ "$(install_directory_identity "${parent}" \
          2>/dev/null || true)" != "${parent_id}" \
        || ! -L "${stage}" \
        || "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          != "${stage_id}" \
        || "$(install_readlink_exact "${stage}" 2>/dev/null || true)" \
          != "${link_text}" ]]; then
    [[ -L "${stage}" \
        && "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  arm_install_transaction_publication "${target}" "${key}" symlink \
    "${stage_id}" "" "" "${link_text}" || return 1
  if ! mv -f -- "${stage}" "${target}" \
      || ! record_install_transaction_publication "${target}" "${key}" \
        symlink "${stage_id}" "" "" "${link_text}"; then
    [[ -L "${stage}" \
        && "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          == "${stage_id}" ]] && rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

backup_existing_targets() {
  local rel_path="" target_path="" backup_path=""
  local relative_parent="" initial_ancestor_seal=""
  INSTALL_TRANSACTION_DIR="${BACKUP_DIR}/.install-transaction"
  BUNDLE_ROLLBACK_PRESENT_FILE="${INSTALL_TRANSACTION_DIR}/bundle-present-before.txt"
  mkdir -p "${INSTALL_TRANSACTION_DIR}"
  chmod 700 "${INSTALL_TRANSACTION_DIR}" 2>/dev/null || true
  : > "${BUNDLE_ROLLBACK_PRESENT_FILE}"
  validate_admitted_file_list "${SOURCE_BUNDLE_FILE_LIST}" \
    "${SOURCE_BUNDLE_SNAPSHOT}" || return 1
  # Back up bundle files that already exist at the destination.
  while IFS= read -r rel_path; do
    [[ -n "${rel_path}" ]] || continue
    case "${rel_path}" in
      /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*)
        return 1 ;;
    esac
    target_path="${CLAUDE_HOME}/${rel_path}"
    backup_path="${BACKUP_DIR}/${rel_path}"
    relative_parent="${rel_path%/*}"
    [[ "${relative_parent}" == "${rel_path}" ]] && relative_parent=""
    capture_destination_ancestor_seal "${CLAUDE_HOME}" \
      "${relative_parent}" initial_ancestor_seal || return 1
    record_bundle_initial_ancestor_seal \
      "${rel_path}" "${initial_ancestor_seal}" || return 1
    record_bundle_initial_seal "${rel_path}" "${target_path}" || return 1

    if [[ -f "${target_path}" || -L "${target_path}" ]]; then
      mkdir -p "$(dirname "${backup_path}")"
      rsync -a "${target_path}" "${backup_path}" || return 1
      bundle_initial_seal_is_current "${rel_path}" "${target_path}" \
        || return 1
      if [[ -L "${target_path}" ]]; then
        [[ -L "${backup_path}" \
            && "$(install_readlink_exact "${backup_path}" \
              2>/dev/null || true)" \
              == "$(install_readlink_exact "${target_path}" \
                2>/dev/null || true)" ]] || return 1
      else
        [[ -f "${backup_path}" && ! -L "${backup_path}" \
            && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
                "${backup_path}" 2>/dev/null || true)" \
              == "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
                "${target_path}" 2>/dev/null || true)" \
            && "$(install_file_mode "${backup_path}" \
                2>/dev/null || true)" \
              == "$(install_file_mode "${target_path}" \
                2>/dev/null || true)" ]] || return 1
      fi
      printf '%s\n' "${rel_path}" >> "${BUNDLE_ROLLBACK_PRESENT_FILE}"
    elif [[ -e "${target_path}" ]]; then
      printf 'Refusing install: unsupported pre-install managed path type: %s\n' \
        "${target_path}" >&2
      return 1
    fi
  done < "${SOURCE_BUNDLE_FILE_LIST}"
  chmod 400 "${BUNDLE_ROLLBACK_PRESENT_FILE}" 2>/dev/null || return 1

  # Back up the physical settings bytes separately. For a dotfiles-managed
  # symlink this intentionally records the referent as a regular recovery
  # file while publication later preserves the lexical symlink itself.
  if [[ -n "${SETTINGS_BACKUP_SOURCE}" ]]; then
    if ! settings_install_seal_is_current; then
      printf 'Refusing install: settings.json changed before backup; no bundle files were copied.\n' >&2
      return 1
    fi
    mkdir -p "${BACKUP_DIR}"
    rsync -a "${SETTINGS_BACKUP_SOURCE}" "${BACKUP_DIR}/settings.json"
    if [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${BACKUP_DIR}/settings.json" 2>/dev/null || true)" \
          != "${SETTINGS_SEAL_HASH}" \
        || "$(install_file_mode "${BACKUP_DIR}/settings.json" \
          2>/dev/null || true)" != "${SETTINGS_ORIGINAL_MODE}" ]] \
        || ! settings_install_seal_is_current; then
      printf 'Refusing install: settings backup does not match the sealed original; no bundle files were copied.\n' >&2
      return 1
    fi
  fi

  # Back up the live config separately too. It is not a bundle file, but the
  # model transaction writes model_tier plus install provenance into it. The
  # emergency recovery text has always named this backup path; keeping the
  # bytes here makes that recovery command truthful and lets the automatic
  # model/config rollback restore an exact pre-install configuration.
  if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" \
      || -L "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
    mkdir -p "${BACKUP_DIR}"
    rsync -a "${CLAUDE_HOME}/oh-my-claude.conf" \
      "${BACKUP_DIR}/oh-my-claude.conf"
  fi

  # Back up any Ghostty files that will be touched. v1.36.0: respect
  # the --no-ghostty / auto-detect gate so backups don't pull in
  # ghostty paths the install will not touch.
  if [[ -d "${BUNDLE_GHOSTTY}" ]] && should_install_ghostty; then
    while IFS= read -r rel_path; do
      [[ -n "${rel_path}" ]] || continue
      target_path="${GHOSTTY_HOME}/${rel_path}"
      backup_path="${BACKUP_DIR}/ghostty/${rel_path}"

      if [[ -f "${target_path}" ]]; then
        mkdir -p "$(dirname "${backup_path}")"
        rsync -a "${target_path}" "${backup_path}"
      fi
    done < "${SOURCE_GHOSTTY_FILE_LIST}"
    # config.snippet.ini is appended into ~/.config/ghostty/config rather
    # than copied under its source filename, so back up that real mutation
    # target explicitly.
    if [[ -f "${GHOSTTY_HOME}/config" || -L "${GHOSTTY_HOME}/config" ]]; then
      mkdir -p "${BACKUP_DIR}/ghostty"
      rsync -a "${GHOSTTY_HOME}/config" "${BACKUP_DIR}/ghostty/config"
    fi
  fi

  # Snapshot every installer-owned path outside the copied bundle. Presence is
  # explicit so an absent path is restored by removal rather than confused with
  # a missing backup after a crash.
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt" manifest || return 1
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt" hashes || return 1
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/last-install-report.json" report || return 1
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/.install-stamp" stamp || return 1
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
    legacy-output-style || return 1
  snapshot_install_transaction_path \
    "${TARGET_HOME}/.local/bin/omc" omc-cli || return 1
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/omc-user/overrides.md" user-overrides || return 1
  if [[ -d "${BUNDLE_GHOSTTY}" ]] && should_install_ghostty; then
    snapshot_install_transaction_path \
      "${GHOSTTY_HOME}/themes/Claude OpenCode" ghostty-theme || return 1
    snapshot_install_transaction_path \
      "${GHOSTTY_HOME}/config" ghostty-config || return 1
  fi
  snapshot_install_transaction_path \
    "${CLAUDE_HOME}/oh-my-claude.conf" config || return 1
}

# ---------------------------------------------------------------------------
# Ensure scripts are executable
# ---------------------------------------------------------------------------

ensure_executable_bits() {
  local relative="" target="" node_id="" digest="" mode=""
  local expected_mode=""
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    case "${relative}" in
      statusline.py|switch-tier.sh|install-resume-watchdog.sh|\
      quality-pack/scripts/*.sh|skills/autowork/scripts/*.sh)
        target="${CLAUDE_HOME}/${relative}"
        [[ -f "${target}" && ! -L "${target}" ]] || return 1
        bundle_published_path_seal_is_current "${relative}" "${target}" \
          || return 1
        node_id="$(install_node_identity "${target}")" || return 1
        digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${target}")" || return 1
        mode="$(install_file_mode "${target}")" || return 1
        printf -v expected_mode '%03o' "$((8#${mode} | 8#111))"
        [[ "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
        [[ "${expected_mode}" == "${mode}" ]] && continue
        # Write-ahead ownership must be durable before chmod. Otherwise a
        # signal between chmod and seal publication would leave rollback with
        # no authority over a mutation this invocation performed.
        arm_published_bundle_path "${CLAUDE_HOME}" "${relative}" \
          regular "${node_id}" "${digest}" "${expected_mode}" \
          || return 1
        bundle_published_path_seal_is_current "${relative}" "${target}" \
          || return 1
        chmod +x "${target}" || return 1
        record_published_bundle_path "${CLAUDE_HOME}" "${relative}" \
          regular "${node_id}" "${digest}" "${expected_mode}" \
          || return 1
        ;;
    esac
  done <<< "${BUNDLE_PUBLISHED_PATHS}"
}

# ---------------------------------------------------------------------------
# Git checkout helpers
# ---------------------------------------------------------------------------

is_git_checkout() {
  local repo_root="${1:-}"
  [[ -n "${repo_root}" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git -C "${repo_root}" rev-parse --show-toplevel >/dev/null 2>&1
}

git_hooks_dir_for_checkout() {
  local repo_root="${1:-}"
  local hooks_dir=""

  is_git_checkout "${repo_root}" || return 1
  hooks_dir="$(git -C "${repo_root}" rev-parse --git-path hooks 2>/dev/null || true)"
  [[ -n "${hooks_dir}" ]] || return 1
  if [[ "${hooks_dir}" != /* ]]; then
    hooks_dir="${repo_root}/${hooks_dir}"
  fi
  printf '%s\n' "${hooks_dir}"
}

# ---------------------------------------------------------------------------
# Install the opt-in post-merge git hook
# ---------------------------------------------------------------------------
#
# A git pull on the oh-my-claude source repo updates the bundle but doesn't
# sync the changes to `~/.claude/`. Users who forget to re-run `install.sh`
# end up running a stale installed harness against a newer source, which
# defeats the stale-install indicator and produces subtle drift.
#
# Enabling `--git-hooks` writes `post-merge` into the checkout's resolved
# hooks directory (`git rev-parse --git-path hooks`). In a normal clone this
# is `.git/hooks`; in a linked worktree Git resolves it to the common hooks
# directory under the main checkout. After every merge (which includes
# `git pull`), the hook compares `installed-manifest.txt` against the current
# bundle and prompts the user to re-install if any files differ. The prompt
# is non-blocking and honored via `OMC_AUTO_INSTALL=1` for CI or confident
# users.
MANAGED_GIT_HOOK_TEMPLATE="${SCRIPT_DIR}/config/post-merge.hook"
# Exact digest of the fixed hook body emitted by the pre-template installer
# generation at HEAD before provenance receipts existed. This is deliberately
# byte-specific migration authority; the old marker text alone owns nothing.
LEGACY_GIT_HOOK_SHA256_V1="bdd46902aa5fe24d08a101cc9dbf0683e951109901faf33a657606c78b87d545"

managed_git_hook_path_is_safe() {
  local hook_path="${1:-}" parent="" physical_parent=""
  [[ "${hook_path}" == /* && "${hook_path}" != *[[:cntrl:]]* ]] || return 1
  parent="${hook_path%/*}"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  physical_parent="$(builtin cd -- "${parent}" 2>/dev/null \
    && builtin pwd -P)" || return 1
  [[ "${physical_parent}" == "${parent%/}" ]] || return 1
  [[ ! -L "${hook_path}" ]] || return 1
  [[ ! -e "${hook_path}" || -f "${hook_path}" ]]
}

read_last_valid_conf_sha256() {
  local conf_path="${1:-}" key="${2:-}" line="" value="" result=""
  [[ "${key}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  if [[ -f "${conf_path}" && ! -L "${conf_path}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "${key}="* ]] || continue
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ "${value}" =~ ^[0-9A-Fa-f]{64}$ ]] && result="${value}"
    done < "${conf_path}"
  fi
  printf '%s' "${result}"
}

# Read install identity metadata with the same last-valid duplicate semantics
# used by the runtime/config surfaces. Edge whitespace belongs to the config
# syntax; interior whitespace never does. In particular, do not normalize a
# hand-edited `1. 50.0` or `abc def` into version/SHA authority by deleting all
# whitespace before comparison.
read_last_valid_install_metadata() {
  local conf_path="${1:-}" key="${2:-}" line="" value="" result=""
  case "${key}" in
    installed_version|installed_sha) ;;
    *) return 1 ;;
  esac
  if [[ -f "${conf_path}" && ! -L "${conf_path}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "${key}="* ]] || continue
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      case "${key}" in
        installed_version)
          [[ "${value}" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] \
            && result="${value}"
          ;;
        installed_sha)
          [[ "${value}" =~ ^[0-9A-Fa-f]{7,40}$ ]] && result="${value}"
          ;;
      esac
    done < "${conf_path}"
  fi
  printf '%s' "${result}"
}

install_git_hooks() {
  local source_repo="${SCRIPT_DIR}"
  local hooks_dir=""
  local hook_path="" hook_source_snapshot="" source_parent=""
  local source_parent_id="" source_id="" source_hash="" source_mode=""
  local prior_hash="" current_hash="" current_mode="" legacy_owned=0

  if ! hooks_dir="$(git_hooks_dir_for_checkout "${source_repo}")"; then
    printf '  Git hooks:     skipped (%s is not a git checkout)\n' "${source_repo}"
    return
  fi

  hook_path="${hooks_dir}/post-merge"

  if [[ ! -f "${MANAGED_GIT_HOOK_TEMPLATE}" \
      || -L "${MANAGED_GIT_HOOK_TEMPLATE}" ]]; then
    printf '  Git hooks:     skipped (managed hook template is missing or unsafe)\n'
    return
  fi
  if ! managed_git_hook_path_is_safe "${hook_path}"; then
    printf '  Git hooks:     skipped (unsafe/symlinked hook path: %s)\n' \
      "${hook_path}"
    return
  fi

  source_parent="${MANAGED_GIT_HOOK_TEMPLATE%/*}"
  source_parent_id="$(install_directory_identity "${source_parent}")" \
    || return 1
  source_id="$(install_file_identity "${MANAGED_GIT_HOOK_TEMPLATE}")" \
    || return 1
  source_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${MANAGED_GIT_HOOK_TEMPLATE}")" || return 1
  source_mode="$(install_file_mode "${MANAGED_GIT_HOOK_TEMPLATE}")" \
    || return 1
  hook_source_snapshot="${INSTALL_TRANSACTION_DIR}/git-hook.source"
  if ! cp -p -- "${MANAGED_GIT_HOOK_TEMPLATE}" \
      "${hook_source_snapshot}" \
      || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${hook_source_snapshot}" \
          2>/dev/null || true)" != "${source_hash}" ]] \
      || ! chmod 400 "${hook_source_snapshot}" \
      || [[ "$(install_directory_identity "${source_parent}" \
          2>/dev/null || true)" != "${source_parent_id}" \
        || "$(install_file_identity "${MANAGED_GIT_HOOK_TEMPLATE}" \
          2>/dev/null || true)" != "${source_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${MANAGED_GIT_HOOK_TEMPLATE}" 2>/dev/null || true)" \
          != "${source_hash}" \
        || "$(install_file_mode "${MANAGED_GIT_HOOK_TEMPLATE}" \
          2>/dev/null || true)" != "${source_mode}" ]]; then
    printf '  Git hooks:     failed (managed template changed while it was sealed)\n' >&2
    return 1
  fi

  # A persisted digest owns older legitimate templates across upgrades. The
  # exact current snapshot is the compatibility proof for pre-provenance
  # installs. Marker substrings never confer ownership.
  prior_hash="$(read_last_valid_conf_sha256 \
    "${CLAUDE_HOME}/oh-my-claude.conf" git_post_merge_hook_sha256)"
  if [[ -e "${hook_path}" ]]; then
    current_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${hook_path}" 2>/dev/null || true)"
    current_mode="$(install_file_mode "${hook_path}" \
      2>/dev/null || true)"
    if [[ -z "${prior_hash}" \
        && "${current_hash}" == "${LEGACY_GIT_HOOK_SHA256_V1}" \
        && "${current_mode}" =~ ^[0-7]{3,4}$ \
        && $((8#${current_mode} & 8#100)) -ne 0 ]]; then
      legacy_owned=1
    fi
    if { [[ "${legacy_owned}" -ne 1 ]] \
          && [[ "${current_mode}" != "700" ]]; } \
        || { [[ -n "${prior_hash}" ]] \
          && [[ "${current_hash}" != "${prior_hash}" ]]; } \
        || { [[ -z "${prior_hash}" && "${legacy_owned}" -ne 1 ]] \
          && ! cmp -s "${hook_source_snapshot}" "${hook_path}"; }; then
      printf '  Git hooks:     skipped (existing %s is not an owned oh-my-claude hook)\n' \
        "${hook_path}"
      printf '                 Move or delete it, then re-run with --git-hooks to install.\n'
      return 0
    fi
  fi

  snapshot_install_transaction_path "${hook_path}" git-hook || return 1
  GIT_HOOK_TRANSACTION_PATH="${hook_path}"
  if [[ ! -f "${hook_source_snapshot}" \
        || -L "${hook_source_snapshot}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${hook_source_snapshot}" 2>/dev/null || true)" \
          != "${source_hash}" \
        || "$(install_file_mode "${hook_source_snapshot}" \
            2>/dev/null || true)" != "400" \
        || "$(install_directory_identity "${source_parent}" \
            2>/dev/null || true)" != "${source_parent_id}" \
        || "$(install_file_identity "${MANAGED_GIT_HOOK_TEMPLATE}" \
            2>/dev/null || true)" != "${source_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${MANAGED_GIT_HOOK_TEMPLATE}" 2>/dev/null || true)" \
          != "${source_hash}" \
        || "$(install_file_mode "${MANAGED_GIT_HOOK_TEMPLATE}" \
            2>/dev/null || true)" != "${source_mode}" ]] \
      || ! publish_install_regular_source "${hook_source_snapshot}" \
        "${hook_path}" git-hook 700 \
      || ! managed_git_hook_path_is_safe "${hook_path}" \
      || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${hook_path}" 2>/dev/null || true)" != "${source_hash}" ]] \
      || ! set_conf git_post_merge_hook_sha256 "${source_hash}"; then
    printf '  Git hooks:     failed (could not publish exact managed hook safely)\n' >&2
    return 1
  fi
  printf '  Git hooks:     installed post-merge auto-sync at %s\n' "${hook_path}"
}

installed_git_hook_needs_refresh() {
  local hooks_dir="" hook_path="" prior_hash="" current_hash=""
  local current_mode="" desired_hash="" legacy_owned=0
  hooks_dir="$(git_hooks_dir_for_checkout "${SCRIPT_DIR}" 2>/dev/null)" \
    || return 1
  hook_path="${hooks_dir}/post-merge"
  managed_git_hook_path_is_safe "${hook_path}" || return 1
  [[ -f "${hook_path}" && ! -L "${hook_path}" \
      && -f "${MANAGED_GIT_HOOK_TEMPLATE}" \
      && ! -L "${MANAGED_GIT_HOOK_TEMPLATE}" ]] || return 1
  current_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${hook_path}" 2>/dev/null)" || return 1
  current_mode="$(install_file_mode "${hook_path}" 2>/dev/null)" \
    || return 1
  desired_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${MANAGED_GIT_HOOK_TEMPLATE}" 2>/dev/null)" || return 1
  [[ "${current_hash}" != "${desired_hash}" \
      || "${current_mode}" != "700" ]] || return 1
  prior_hash="$(read_last_valid_conf_sha256 \
    "${CLAUDE_HOME}/oh-my-claude.conf" git_post_merge_hook_sha256)"
  if [[ -n "${prior_hash}" ]]; then
    [[ "${current_hash}" == "${prior_hash}" \
        && "${current_mode}" == "700" ]]
    return $?
  fi
  if [[ "${current_hash}" == "${LEGACY_GIT_HOOK_SHA256_V1}" \
      && "${current_mode}" =~ ^[0-7]{3,4}$ \
      && $((8#${current_mode} & 8#100)) -ne 0 ]]; then
    legacy_owned=1
  fi
  [[ "${legacy_owned}" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Remove the post-merge hook (called when --git-hooks is NOT set and a
# stale oh-my-claude-authored hook already exists, so users can opt out
# by re-running install without the flag).
# ---------------------------------------------------------------------------
remove_git_hooks_if_ours() {
  local hooks_dir=""
  local hook_path=""

  hooks_dir="$(git_hooks_dir_for_checkout "${SCRIPT_DIR}")" || return
  hook_path="${hooks_dir}/post-merge"
  [[ -f "${hook_path}" ]] || return
  if grep -q '# oh-my-claude post-merge auto-sync' "${hook_path}" 2>/dev/null; then
    # Leave it in place silently — users who explicitly installed it once
    # would be surprised if a subsequent install removed it. Toggling off
    # is a manual step (delete the hook file).
    :
  fi
}

# ---------------------------------------------------------------------------
# Append a line to a file if not already present
# ---------------------------------------------------------------------------

append_if_missing() {
  local file_path="$1"
  local line="$2"

  mkdir -p "$(dirname "${file_path}")"
  touch "${file_path}"
  if ! grep -Fqx "${line}" "${file_path}" 2>/dev/null; then
    printf '%s\n' "${line}" >> "${file_path}"
  fi
}

# ---------------------------------------------------------------------------
# Configuration file helpers
# ---------------------------------------------------------------------------

# Set or remove one key in oh-my-claude.conf through a same-directory staged
# compare-and-swap. The transaction snapshot is read-only recovery material;
# every successful write publishes a fresh exact rollback seal.
mutate_conf_key() {
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local key="${1:-}" operation="${2:-}" value="${3:-}"
  local phase="initial" state_path="${INSTALL_TRANSACTION_DIR}/config.state"
  local state="" parent="${conf_path%/*}" source_snapshot="" tmp=""
  local source_hash="" tmp_id="" tmp_hash="" tmp_mode=""
  [[ "${key}" =~ ^[A-Za-z0-9_]+$ \
      && "${operation}" =~ ^(set|remove)$ ]] || return 1
  if [[ -f "${INSTALL_TRANSACTION_DIR}/config.published-state" ]]; then
    phase="published"
    state_path="${INSTALL_TRANSACTION_DIR}/config.published-state"
  fi
  install_transaction_path_phase_is_current \
    "${conf_path}" config "${phase}" || return 1
  state="$(install_read_canonical_metadata_line "${state_path}" 32)" \
    || return 1
  source_snapshot="$(mktemp "${INSTALL_TRANSACTION_DIR}/config-source.XXXXXX")" \
    || return 1
  if [[ "${state}" == "regular" || "${state}" == "symlink" ]]; then
    [[ -f "${conf_path}" ]] || { rm -f -- "${source_snapshot}"; return 1; }
    source_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${conf_path}")" || { rm -f -- "${source_snapshot}"; return 1; }
    if ! cp -p -- "${conf_path}" "${source_snapshot}" \
        || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${source_snapshot}" 2>/dev/null || true)" != "${source_hash}" ]] \
        || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${conf_path}" 2>/dev/null || true)" != "${source_hash}" ]] \
        || ! install_transaction_path_phase_is_current \
          "${conf_path}" config "${phase}"; then
      rm -f -- "${source_snapshot}"
      return 1
    fi
  elif [[ "${state}" != "absent" ]]; then
    rm -f -- "${source_snapshot}"
    return 1
  fi
  tmp="$(mktemp "${parent}/.oh-my-claude.conf.install.XXXXXX")" \
    || { rm -f -- "${source_snapshot}"; return 1; }
  local grep_rc=0
  grep -v -E "^${key}=" "${source_snapshot}" > "${tmp}" 2>/dev/null \
    || grep_rc=$?
  if [[ "${grep_rc}" -gt 1 ]]; then
    rm -f -- "${source_snapshot}" "${tmp}"
    return 1
  fi
  if [[ "${operation}" == "set" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}" || {
      rm -f -- "${source_snapshot}" "${tmp}"
      return 1
    }
  fi
  if [[ "${state}" == "regular" || "${state}" == "symlink" ]]; then
    chmod "$(install_file_mode "${source_snapshot}")" "${tmp}" || {
      rm -f -- "${source_snapshot}" "${tmp}"
      return 1
    }
  else
    chmod 600 "${tmp}" || { rm -f -- "${source_snapshot}" "${tmp}"; return 1; }
  fi
  rm -f -- "${source_snapshot}"
  tmp_id="$(install_node_identity "${tmp}")" || return 1
  tmp_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" "${tmp}")" \
    || return 1
  tmp_mode="$(install_file_mode "${tmp}")" || return 1
  if ! install_transaction_path_phase_is_current \
      "${conf_path}" config "${phase}" \
      || [[ ! -f "${tmp}" || -L "${tmp}" \
        || "$(install_node_identity "${tmp}" 2>/dev/null || true)" \
          != "${tmp_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${tmp}" 2>/dev/null || true)" != "${tmp_hash}" \
        || "$(install_file_mode "${tmp}" 2>/dev/null || true)" \
          != "${tmp_mode}" ]]; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  arm_install_transaction_publication "${conf_path}" config regular \
    "${tmp_id}" "${tmp_hash}" "${tmp_mode}" || {
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    }
  if ! mv -f -- "${tmp}" "${conf_path}" \
      || ! record_install_transaction_publication "${conf_path}" config \
        regular "${tmp_id}" "${tmp_hash}" "${tmp_mode}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
}

set_conf() {
  mutate_conf_key "${1:-}" set "${2:-}"
}

unset_conf() {
  mutate_conf_key "${1:-}" remove
}

# ---------------------------------------------------------------------------
# Apply model tier to installed agent definitions
# ---------------------------------------------------------------------------

# Canonical shipped declaration classes. Keep these embedded rosters in
# lockstep with bundle frontmatter, common.sh:omc_agent_declared_model, and the
# installed switcher. Exact reconstruction is important even for Economy:
# runtime routing represents an inherited deliberator by omitting the Agent
# model parameter, so its installed definition must still say `inherit`.
SHIPPED_INHERIT_AGENTS='abstraction-critic chief-of-staff divergent-framer draft-writer editor-critic excellence-reviewer metis oracle prometheus quality-planner quality-reviewer release-reviewer rigor-reviewer writing-architect'
SHIPPED_FIXED_AGENTS='atlas backend-api-developer briefing-analyst data-lens design-lens design-reviewer devops-infrastructure-engineer frontend-developer fullstack-feature-builder growth-lens ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer librarian literature-scout product-lens quality-researcher research-data-analyst security-lens sre-lens test-automation-engineer visual-craft-lens'
SHIPPED_OPTIONAL_IOS_AGENTS='ios-core-engineer ios-deployment-specialist ios-ecosystem-integrator ios-ui-developer'

installed_shipped_agent_is_known() {
  local wanted="$1" agent
  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    [[ "${wanted}" == "${agent}" ]] && return 0
  done
  return 1
}

installed_agent_has_exact_valid_model() {
  local agent_file="${CLAUDE_HOME}/agents/$1.md" model_count model_value
  [[ -f "${agent_file}" ]] || return 1
  model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
  model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
  [[ "${model_count}" == "1" \
      && "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]
}

installed_agent_has_exact_inherit_model() {
  local agent_file="${CLAUDE_HOME}/agents/$1.md"
  [[ -f "${agent_file}" ]] || return 1
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" \
      && "$(grep -cE '^model: inherit$' "${agent_file}" 2>/dev/null || true)" == "1" ]]
}

# Parse the two roster-owned frontmatter fields without spawning awk/grep/sed
# for every file. Install tests exercise this proof many times, so a single
# Bash pass per definition keeps fail-fast integrity from becoming a steady
# reinstall tax. Results are returned through the AGENT_FRONTMATTER_* globals.
parse_agent_frontmatter() {
  local agent_file="$1"
  local line line_number=0 closed=0
  AGENT_FRONTMATTER_NAME_COUNT=0
  AGENT_FRONTMATTER_NAME_VALUE=""
  AGENT_FRONTMATTER_MODEL_COUNT=0
  AGENT_FRONTMATTER_MODEL_VALUE=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    if [[ "${line_number}" -eq 1 ]]; then
      [[ "${line}" == "---" ]] || return 1
      continue
    fi
    if [[ "${line}" == "---" ]]; then
      closed=1
      break
    fi
    case "${line}" in
      'name: '*)
        AGENT_FRONTMATTER_NAME_COUNT=$((AGENT_FRONTMATTER_NAME_COUNT + 1))
        [[ "${AGENT_FRONTMATTER_NAME_COUNT}" -eq 1 ]] \
          && AGENT_FRONTMATTER_NAME_VALUE="${line#name: }"
        ;;
      'model: '*)
        AGENT_FRONTMATTER_MODEL_COUNT=$((AGENT_FRONTMATTER_MODEL_COUNT + 1))
        [[ "${AGENT_FRONTMATTER_MODEL_COUNT}" -eq 1 ]] \
          && AGENT_FRONTMATTER_MODEL_VALUE="${line#model: }"
        ;;
    esac
  done < "${agent_file}"
  [[ "${closed}" -eq 1 ]]
}

# Enumerate every node in each source tree before any destination path or
# install lock is created. rsync preserves symlinks and special nodes under
# `-a`; admitting only real directories and regular files prevents an
# untracked source node from being copied while the path-only manifest quietly
# omits it. The dot-claude regular-file list is reused by backup, copy, and
# manifest publication so those three ownership surfaces cannot diverge.
SOURCE_BUNDLE_FILE_LIST=""
SOURCE_GHOSTTY_FILE_LIST=""
SOURCE_USER_TEMPLATE_FILE_LIST=""
SOURCE_TREE_NODE_LIST=""
SOURCE_BUNDLE_FILE_LIST_HASH=""
SOURCE_GHOSTTY_FILE_LIST_HASH=""
SOURCE_USER_TEMPLATE_FILE_LIST_HASH=""
SOURCE_BUNDLE_FILE_LIST_ID=""
SOURCE_GHOSTTY_FILE_LIST_ID=""
SOURCE_USER_TEMPLATE_FILE_LIST_ID=""
SOURCE_BUNDLE_FILE_LIST_PARENT_ID=""
SOURCE_GHOSTTY_FILE_LIST_PARENT_ID=""
SOURCE_USER_TEMPLATE_FILE_LIST_PARENT_ID=""
SOURCE_BUNDLE_CONTENT_MANIFEST=""
SOURCE_GHOSTTY_CONTENT_MANIFEST=""
SOURCE_USER_TEMPLATE_CONTENT_MANIFEST=""
SOURCE_BUNDLE_MODE_MANIFEST=""
SOURCE_GHOSTTY_MODE_MANIFEST=""
SOURCE_USER_TEMPLATE_MODE_MANIFEST=""
SOURCE_BUNDLE_CONTENT_MANIFEST_HASH=""
SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH=""
SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH=""
SOURCE_BUNDLE_CONTENT_MANIFEST_ID=""
SOURCE_GHOSTTY_CONTENT_MANIFEST_ID=""
SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_ID=""
SOURCE_BUNDLE_CONTENT_MANIFEST_PARENT_ID=""
SOURCE_GHOSTTY_CONTENT_MANIFEST_PARENT_ID=""
SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_PARENT_ID=""
SOURCE_BUNDLE_MODE_MANIFEST_HASH=""
SOURCE_GHOSTTY_MODE_MANIFEST_HASH=""
SOURCE_USER_TEMPLATE_MODE_MANIFEST_HASH=""
SOURCE_BUNDLE_MODE_MANIFEST_ID=""
SOURCE_GHOSTTY_MODE_MANIFEST_ID=""
SOURCE_USER_TEMPLATE_MODE_MANIFEST_ID=""
SOURCE_BUNDLE_MODE_MANIFEST_PARENT_ID=""
SOURCE_GHOSTTY_MODE_MANIFEST_PARENT_ID=""
SOURCE_USER_TEMPLATE_MODE_MANIFEST_PARENT_ID=""
SOURCE_GHOSTTY_THEME_HASH=""
SOURCE_GHOSTTY_SNIPPET_HASH=""
SOURCE_USER_TEMPLATE_OVERRIDES_HASH=""
GHOSTTY_SNIPPET_SNAPSHOT=""
INSTALL_STATE_REPORT_SOURCE_ID=""
INSTALL_STATE_REPORT_SOURCE_PARENT_ID=""
INSTALL_STATE_REPORT_SOURCE_HASH=""
INSTALL_STATE_REPORT_SOURCE_MODE=""
CHANGELOG_SOURCE_ID=""
CHANGELOG_SOURCE_PARENT_ID=""
CHANGELOG_SOURCE_HASH=""
CHANGELOG_SOURCE_MODE=""
INSTALL_STATE_REPORT_SNAPSHOT=""
INSTALL_STATE_REPORT_SNAPSHOT_ID=""
INSTALL_STATE_REPORT_SNAPSHOT_PARENT_ID=""
INSTALL_STATE_REPORT_SNAPSHOT_HASH=""
INSTALL_STATE_REPORT_SNAPSHOT_MODE=""
CHANGELOG_SNAPSHOT=""
CHANGELOG_SNAPSHOT_ID=""
CHANGELOG_SNAPSHOT_PARENT_ID=""
CHANGELOG_SNAPSHOT_HASH=""
CHANGELOG_SNAPSHOT_MODE=""
SOURCE_SNAPSHOT_ROOT=""
SOURCE_SNAPSHOT_ROOT_ID=""
SOURCE_BUNDLE_SNAPSHOT=""
SOURCE_GHOSTTY_SNAPSHOT=""
SOURCE_USER_TEMPLATE_SNAPSHOT=""

cleanup_source_preflight_tmpfiles() {
  rm -f -- "${SOURCE_BUNDLE_FILE_LIST:-}" \
    "${SOURCE_GHOSTTY_FILE_LIST:-}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST:-}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST:-}" \
    "${SOURCE_GHOSTTY_CONTENT_MANIFEST:-}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST:-}" \
    "${SOURCE_BUNDLE_MODE_MANIFEST:-}" \
    "${SOURCE_GHOSTTY_MODE_MANIFEST:-}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST:-}" \
    "${SETTINGS_PATCH_SNAPSHOT:-}" \
    "${GHOSTTY_SNIPPET_SNAPSHOT:-}" \
    "${SOURCE_TREE_NODE_LIST:-}" 2>/dev/null || true
  if [[ -n "${SOURCE_SNAPSHOT_ROOT:-}" \
      && -d "${SOURCE_SNAPSHOT_ROOT}" \
      && ! -L "${SOURCE_SNAPSHOT_ROOT}" \
      && -n "${SOURCE_SNAPSHOT_ROOT_ID:-}" \
      && "$(install_directory_identity "${SOURCE_SNAPSHOT_ROOT}" \
        2>/dev/null || true)" == "${SOURCE_SNAPSHOT_ROOT_ID}" ]]; then
    chmod -R u+w "${SOURCE_SNAPSHOT_ROOT}" 2>/dev/null || true
    rm -rf -- "${SOURCE_SNAPSHOT_ROOT}" 2>/dev/null || true
  fi
}

capture_auxiliary_source_seal() {
  local source="${1:-}" prefix="${2:-}" parent="" node_id=""
  local parent_id="" digest="" mode=""
  [[ -f "${source}" && ! -L "${source}" \
      && "${prefix}" =~ ^[A-Z0-9_]+$ ]] || return 1
  parent="${source%/*}"
  [[ -d "${parent}" && ! -L "${parent}" ]] || return 1
  node_id="$(install_file_identity "${source}")" || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${source}")" || return 1
  mode="$(install_file_mode "${source}")" || return 1
  printf -v "${prefix}_ID" '%s' "${node_id}"
  printf -v "${prefix}_PARENT_ID" '%s' "${parent_id}"
  printf -v "${prefix}_HASH" '%s' "${digest}"
  printf -v "${prefix}_MODE" '%s' "${mode}"
}

auxiliary_source_seal_is_current() {
  local source="${1:-}" expected_id="${2:-}"
  local expected_parent_id="${3:-}" expected_hash="${4:-}"
  local expected_mode="${5:-}" parent=""
  parent="${source%/*}"
  [[ -f "${source}" && ! -L "${source}" \
      && -d "${parent}" && ! -L "${parent}" \
      && "$(install_file_identity "${source}" 2>/dev/null || true)" \
        == "${expected_id}" \
      && "$(install_directory_identity "${parent}" \
        2>/dev/null || true)" == "${expected_parent_id}" \
      && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${source}" 2>/dev/null || true)" == "${expected_hash}" \
      && "$(install_file_mode "${source}" 2>/dev/null || true)" \
        == "${expected_mode}" ]]
}

snapshot_auxiliary_source() {
  local source="${1:-}" destination="${2:-}" source_prefix="${3:-}"
  local snapshot_prefix="${4:-}" parent="" node_id="" parent_id=""
  local digest="" mode="" source_id_var="${source_prefix}_ID"
  local source_parent_var="${source_prefix}_PARENT_ID"
  local source_hash_var="${source_prefix}_HASH"
  local source_mode_var="${source_prefix}_MODE"
  [[ "${source_prefix}" =~ ^[A-Z0-9_]+$ \
      && "${snapshot_prefix}" =~ ^[A-Z0-9_]+$ \
      && -d "${destination%/*}" && ! -L "${destination%/*}" ]] \
    || return 1
  auxiliary_source_seal_is_current "${source}" \
    "${!source_id_var}" "${!source_parent_var}" \
    "${!source_hash_var}" "${!source_mode_var}" || return 1
  cp -p -- "${source}" "${destination}" || return 1
  chmod 400 "${destination}" || return 1
  [[ -f "${destination}" && ! -L "${destination}" ]] || return 1
  parent="${destination%/*}"
  node_id="$(install_file_identity "${destination}")" || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${destination}")" || return 1
  mode="$(install_file_mode "${destination}")" || return 1
  [[ "${digest}" == "${!source_hash_var}" \
      && "${mode}" =~ ^0?400$ ]] || return 1
  printf -v "${snapshot_prefix}_ID" '%s' "${node_id}"
  printf -v "${snapshot_prefix}_PARENT_ID" '%s' "${parent_id}"
  printf -v "${snapshot_prefix}_HASH" '%s' "${digest}"
  printf -v "${snapshot_prefix}_MODE" '%s' "${mode}"
  auxiliary_source_seal_is_current "${source}" \
    "${!source_id_var}" "${!source_parent_var}" \
    "${!source_hash_var}" "${!source_mode_var}"
}

auxiliary_distribution_seals_are_current() {
  auxiliary_source_seal_is_current "${INSTALL_STATE_REPORT_SOURCE}" \
    "${INSTALL_STATE_REPORT_SOURCE_ID}" \
    "${INSTALL_STATE_REPORT_SOURCE_PARENT_ID}" \
    "${INSTALL_STATE_REPORT_SOURCE_HASH}" \
    "${INSTALL_STATE_REPORT_SOURCE_MODE}" || return 1
  auxiliary_source_seal_is_current "${CHANGELOG_SOURCE}" \
    "${CHANGELOG_SOURCE_ID}" "${CHANGELOG_SOURCE_PARENT_ID}" \
    "${CHANGELOG_SOURCE_HASH}" "${CHANGELOG_SOURCE_MODE}" || return 1
  auxiliary_source_seal_is_current "${INSTALL_STATE_REPORT_SNAPSHOT}" \
    "${INSTALL_STATE_REPORT_SNAPSHOT_ID}" \
    "${INSTALL_STATE_REPORT_SNAPSHOT_PARENT_ID}" \
    "${INSTALL_STATE_REPORT_SNAPSHOT_HASH}" \
    "${INSTALL_STATE_REPORT_SNAPSHOT_MODE}" || return 1
  auxiliary_source_seal_is_current "${CHANGELOG_SNAPSHOT}" \
    "${CHANGELOG_SNAPSHOT_ID}" "${CHANGELOG_SNAPSHOT_PARENT_ID}" \
    "${CHANGELOG_SNAPSHOT_HASH}" "${CHANGELOG_SNAPSHOT_MODE}"
}

source_content_manifest_seal_is_current() {
  local manifest="${1:-}" expected_id="${2:-}"
  local expected_parent_id="${3:-}" expected_hash="${4:-}"
  local parent="" current_id="" current_parent_id="" current_hash=""
  local current_mode=""
  [[ -n "${manifest}" && -f "${manifest}" && ! -L "${manifest}" \
      && -n "${expected_id}" && -n "${expected_parent_id}" \
      && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  parent="${manifest%/*}"
  [[ -n "${parent}" ]] || parent="/"
  current_id="$(install_file_identity "${manifest}")" || return 1
  current_parent_id="$(install_directory_identity "${parent}")" || return 1
  current_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${manifest}")" || return 1
  current_mode="$(install_file_mode "${manifest}")" || return 1
  [[ "${current_id}" == "${expected_id}" \
      && "${current_parent_id}" == "${expected_parent_id}" \
      && "${current_hash}" == "${expected_hash}" \
      && "${current_mode}" =~ ^0?400$ ]]
}

seal_source_content_manifest() {
  local manifest="${1:-}" id_var="${2:-}" parent_var="${3:-}"
  local hash_var="${4:-}" parent="" identity="" parent_id="" digest=""
  [[ -f "${manifest}" && ! -L "${manifest}" \
      && -n "${id_var}" && -n "${parent_var}" && -n "${hash_var}" ]] \
    || return 1
  chmod 400 "${manifest}" 2>/dev/null || return 1
  parent="${manifest%/*}"
  [[ -n "${parent}" ]] || parent="/"
  identity="$(install_file_identity "${manifest}")" || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${manifest}")" || return 1
  [[ "${digest}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf -v "${id_var}" '%s' "${identity}"
  printf -v "${parent_var}" '%s' "${parent_id}"
  printf -v "${hash_var}" '%s' "${digest}"
}

verify_copied_tree_content() {
  local destination_root="${1:-}" file_list="${2:-}"
  local expected_manifest_hash="${3:-}" label="${4:-}"
  local destination_manifest="" destination_hash="" rc=0
  [[ -d "${destination_root}" && -f "${file_list}" \
      && "${expected_manifest_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  destination_manifest="$(mktemp)" || return 1
  if ! \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
      "${destination_root}" "${file_list}" "${destination_manifest}"; then
    rc=1
  else
    destination_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${destination_manifest}" 2>/dev/null || true)"
    [[ "${destination_hash}" == "${expected_manifest_hash}" ]] || rc=1
  fi
  rm -f -- "${destination_manifest}"
  if [[ "${rc}" -ne 0 ]]; then
    printf '  [error] Copied %s bytes do not match the preflight source manifest.\n' \
      "${label:-source tree}" >&2
    return 1
  fi
}

validate_admitted_file_list() {
  local file_list="${1:-}" root="${2:-}" relative="" previous=""
  [[ -f "${file_list}" && ! -L "${file_list}" && -d "${root}" \
      && ! -L "${root}" ]] || return 1
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    [[ -n "${relative}" && "${relative}" != *[[:cntrl:]]* \
        && "${relative}" != /* && "${relative}" != "." \
        && "${relative}" != ".." && "${relative}" != ./* \
        && "${relative}" != ../* && "${relative}" != */./* \
        && "${relative}" != */../* && "${relative}" != */. \
        && "${relative}" != */.. && "${relative}" != *//* \
        && "${relative}" != *\\* \
        && -f "${root}/${relative}" && ! -L "${root}/${relative}" ]] \
      || return 1
    [[ -z "${previous}" || "${previous}" < "${relative}" ]] || return 1
    previous="${relative}"
  done < "${file_list}"
}

generate_source_mode_manifest() {
  local root="${1:-}" file_list="${2:-}" output="${3:-}"
  local relative="" mode=""
  validate_admitted_file_list "${file_list}" "${root}" || return 1
  [[ -n "${output}" ]] || return 1
  : > "${output}" || return 1
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    [[ -n "${relative}" ]] || continue
    mode="$(install_file_mode "${root}/${relative}")" || return 1
    mode="${mode#0}"
    # Setuid/setgid/sticky and group/other-writable release files are not part
    # of the portable distribution authority. Owner read/write/execute bits
    # are preserved exactly, including intentionally read-only leaves.
    [[ "${mode}" =~ ^[0-7][0145][0145]$ ]] || return 1
    printf '%s\t%s\n' "${mode}" "${relative}" >> "${output}" || return 1
  done < "${file_list}"
}

verify_tree_mode_manifest() {
  local root="${1:-}" file_list="${2:-}" expected_hash="${3:-}"
  local actual="" actual_hash=""
  [[ "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  actual="$(mktemp)" || return 1
  if ! generate_source_mode_manifest "${root}" "${file_list}" "${actual}"; then
    rm -f -- "${actual}"
    return 1
  fi
  actual_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${actual}" 2>/dev/null || true)"
  rm -f -- "${actual}"
  [[ "${actual_hash}" == "${expected_hash}" ]]
}

verify_protected_tree_modes() {
  local root="${1:-}" mode_manifest="${2:-}"
  local intended="" relative="" owner="" rest="" expected="" actual=""
  [[ -d "${root}" && ! -L "${root}" \
      && -f "${mode_manifest}" && ! -L "${mode_manifest}" ]] || return 1
  while IFS=$'\t' read -r intended relative; do
    [[ "${intended}" =~ ^[0-7][0145][0145]$ \
        && -n "${relative}" && "${relative}" != *[[:cntrl:]]* \
        && "${relative}" != *\\* ]] || return 1
    owner="${intended:0:1}"
    rest="${intended:1}"
    case "${owner}" in
      0|1) owner="${owner}" ;;
      2|3) owner="$((owner - 2))" ;;
      4|5) owner="${owner}" ;;
      6|7) owner="$((owner - 2))" ;;
      *) return 1 ;;
    esac
    expected="${owner}${rest}"
    actual="$(install_file_mode "${root}/${relative}")" || return 1
    actual="${actual#0}"
    [[ "${actual}" == "${expected}" ]] || return 1
  done < "${mode_manifest}"
}

capture_destination_ancestor_seal() {
  local root="${1:-}" relative_parent="${2:-}" output_var="${3:-}"
  local current="" segment="" identity="" seal=""
  local -a segments=()
  [[ -n "${output_var}" && "${root}" == /* \
      && "${root}" != *[[:cntrl:]]* && -d "${root}" \
      && ! -L "${root}" ]] || return 1
  current="${root}"
  identity="$(install_directory_identity "${current}")" || return 1
  seal="${identity}"$'\t'"${current}"$'\n'
  if [[ -n "${relative_parent}" && "${relative_parent}" != "." ]]; then
    [[ "${relative_parent}" != *[[:cntrl:]]* \
        && "${relative_parent}" != *\\* ]] || return 1
    IFS='/' read -r -a segments <<< "${relative_parent}"
    for segment in "${segments[@]}"; do
      [[ -n "${segment}" && "${segment}" != "." \
          && "${segment}" != ".." ]] || return 1
      current="${current}/${segment}"
      if [[ ! -e "${current}" && ! -L "${current}" ]]; then
        mkdir -- "${current}" 2>/dev/null || {
          [[ -d "${current}" && ! -L "${current}" ]] || return 1
        }
      fi
      [[ -d "${current}" && ! -L "${current}" ]] || return 1
      identity="$(install_directory_identity "${current}")" || return 1
      seal+="${identity}"$'\t'"${current}"$'\n'
    done
  fi
  printf -v "${output_var}" '%s' "${seal}"
}

destination_ancestor_seal_is_current() {
  local seal="${1:-}" expected_id="" path=""
  [[ -n "${seal}" ]] || return 1
  while IFS=$'\t' read -r expected_id path; do
    [[ -n "${expected_id}" && -n "${path}" \
        && -d "${path}" && ! -L "${path}" \
        && "$(install_directory_identity "${path}" 2>/dev/null || true)" \
          == "${expected_id}" ]] || return 1
  # `seal` is already newline-terminated. A here-string appends another
  # newline and fabricates an empty authority row, making every valid seal
  # fail after its final real ancestor. Feed the exact generated bytes.
  done < <(builtin printf '%s' "${seal}")
}

cleanup_destination_copy_stage() {
  local stage="${1:-}" parent="${2:-}" expected_parent_id="${3:-}"
  local expected_stage_node_id="${4:-}"
  [[ -n "${stage}" && -n "${parent}" && -n "${expected_parent_id}" \
      && -n "${expected_stage_node_id}" && -d "${parent}" \
      && ! -L "${parent}" \
      && "$(install_directory_identity "${parent}" 2>/dev/null || true)" \
        == "${expected_parent_id}" \
      && -f "${stage}" && ! -L "${stage}" \
      && "$(install_node_identity "${stage}" 2>/dev/null || true)" \
        == "${expected_stage_node_id}" ]] || return 1
  rm -f -- "${stage}"
}

record_bundle_initial_seal() {
  local relative="${1:-}" target="${2:-}" state="" node_id=""
  local digest="" mode="" link_text=""
  [[ -n "${relative}" && -n "${target}" ]] || return 1
  if [[ -L "${target}" ]]; then
    state="symlink"
    node_id="$(install_node_identity "${target}")" || return 1
    link_text="$(install_readlink_exact "${target}")" || return 1
  elif [[ -f "${target}" ]]; then
    state="regular"
    node_id="$(install_node_identity "${target}")" || return 1
    digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${target}")" || return 1
    mode="$(install_file_mode "${target}")" || return 1
  elif [[ ! -e "${target}" ]]; then
    state="absent"
  else
    return 1
  fi
  BUNDLE_INITIAL_SEALS+="${relative}"$'\t'"${state}"$'\t'\
"${node_id}"$'\t'"${digest}"$'\t'"${mode}"$'\t'"${link_text}"$'\n'
}

bundle_initial_seal_is_current() {
  local wanted="${1:-}" target="${2:-}" row_relative="" state=""
  local expected_id="" expected_hash="" expected_mode="" expected_link=""
  local matched_state="" matched_id="" matched_hash=""
  local matched_mode="" matched_link=""
  local found=0
  while IFS=$'\t' read -r row_relative state expected_id expected_hash \
      expected_mode expected_link; do
    [[ "${row_relative}" == "${wanted}" ]] || continue
    found=$((found + 1))
    matched_state="${state}"
    matched_id="${expected_id}"
    matched_hash="${expected_hash}"
    matched_mode="${expected_mode}"
    matched_link="${expected_link}"
  done <<< "${BUNDLE_INITIAL_SEALS}"
  [[ "${found}" -eq 1 ]] || return 1
  case "${matched_state}" in
    absent)
      [[ ! -e "${target}" && ! -L "${target}" ]]
      ;;
    regular)
      [[ -f "${target}" && ! -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${matched_id}" \
          && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${target}" 2>/dev/null || true)" == "${matched_hash}" \
          && "$(install_file_mode "${target}" 2>/dev/null || true)" \
            == "${matched_mode}" ]]
      ;;
    symlink)
      [[ -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${matched_id}" \
          && "$(install_readlink_exact "${target}" 2>/dev/null || true)" \
            == "${matched_link}" ]]
      ;;
    *) return 1 ;;
  esac
}

record_bundle_initial_ancestor_seal() {
  local relative="${1:-}" seal="${2:-}" expected_id="" path=""
  local rows=0
  [[ -n "${relative}" && -n "${seal}" ]] || return 1
  while IFS=$'\t' read -r expected_id path; do
    [[ -n "${expected_id}" && -n "${path}" ]] || return 1
    BUNDLE_INITIAL_ANCESTOR_SEALS+="${relative}"$'\t'\
"${expected_id}"$'\t'"${path}"$'\n'
    rows=$((rows + 1))
  done < <(builtin printf '%s' "${seal}")
  [[ "${rows}" -gt 0 ]]
}

bundle_initial_ancestor_seal_is_current() {
  local wanted="${1:-}" row_relative="" expected_id="" path="" rows=0
  while IFS=$'\t' read -r row_relative expected_id path; do
    [[ "${row_relative}" == "${wanted}" ]] || continue
    rows=$((rows + 1))
    [[ -d "${path}" && ! -L "${path}" \
        && "$(install_directory_identity "${path}" 2>/dev/null || true)" \
          == "${expected_id}" ]] || return 1
  done <<< "${BUNDLE_INITIAL_ANCESTOR_SEALS}"
  [[ "${rows}" -gt 0 ]]
}

arm_published_bundle_path() {
  local destination_root="${1:-}" relative="${2:-}"
  local expected_state="${3:-}" expected_id="${4:-}"
  local expected_hash="${5:-}" expected_mode="${6:-}"
  if [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 \
      && "${destination_root}" == "${CLAUDE_HOME}" ]]; then
    # Leaf identity alone is insufficient: a concurrent actor can move an
    # admitted directory and replace it with a symlink back to the same tree,
    # preserving every leaf inode while redirecting later chmod/rewrites.
    # Bind every publication generation to the exact lexical ancestor chain
    # captured before the first managed mutation.
    bundle_initial_ancestor_seal_is_current "${relative}" || return 1
    [[ "${expected_state}" =~ ^(absent|regular)$ ]] || return 1
    if [[ "${expected_state}" == "regular" ]]; then
      [[ -n "${expected_id}" \
          && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ \
          && "${expected_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    fi
    # Register rollback interest before the expected generation. A signal in
    # between is safe: rollback recognizes the exact initial seal as a no-op.
    bundle_path_was_published "${relative}" \
      || BUNDLE_PUBLISHED_PATHS+="${relative}"$'\n'
    BUNDLE_PUBLISHED_SEALS+="${relative}"$'\t'"${expected_state}"$'\t'\
"${expected_id}"$'\t'"${expected_hash}"$'\t'"${expected_mode}"$'\n'
  fi
}

record_published_bundle_path() {
  local destination_root="${1:-}" relative="${2:-}"
  local expected_state="${3:-}" expected_id="${4:-}"
  local expected_hash="${5:-}" expected_mode="${6:-}"
  local row_relative="" state="" row_id="" row_hash="" row_mode=""
  local armed=0 target=""
  [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 \
      && "${destination_root}" == "${CLAUDE_HOME}" ]] || return 0
  bundle_initial_ancestor_seal_is_current "${relative}" || return 1
  while IFS=$'\t' read -r row_relative state row_id row_hash row_mode; do
    [[ "${row_relative}" == "${relative}" \
        && "${state}" == "${expected_state}" \
        && "${row_id}" == "${expected_id}" \
        && "${row_hash}" == "${expected_hash}" \
        && "${row_mode}" == "${expected_mode}" ]] || continue
    armed=1
  done <<< "${BUNDLE_PUBLISHED_SEALS}"
  [[ "${armed}" -eq 1 ]] || return 1
  target="${destination_root}/${relative}"
  case "${expected_state}" in
    absent)
      [[ ! -e "${target}" && ! -L "${target}" ]]
      ;;
    regular)
      [[ -f "${target}" && ! -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${expected_id}" \
          && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${target}" 2>/dev/null || true)" == "${expected_hash}" \
          && "$(install_file_mode "${target}" 2>/dev/null || true)" \
            == "${expected_mode}" ]]
      ;;
    *) return 1 ;;
  esac
}

bundle_path_was_published() {
  local wanted="${1:-}" published=""
  [[ -n "${wanted}" ]] || return 1
  while IFS= read -r published || [[ -n "${published}" ]]; do
    [[ "${published}" == "${wanted}" ]] && return 0
  done <<< "${BUNDLE_PUBLISHED_PATHS}"
  return 1
}

bundle_published_path_seal_is_current() {
  local wanted="${1:-}" target="${2:-}" row_relative="" state=""
  local expected_id="" expected_hash="" expected_mode=""
  [[ -n "${wanted}" && -n "${target}" ]] || return 1
  bundle_initial_ancestor_seal_is_current "${wanted}" || return 1
  while IFS=$'\t' read -r row_relative state expected_id expected_hash \
      expected_mode; do
    [[ "${row_relative}" == "${wanted}" ]] || continue
    case "${state}" in
      absent)
        [[ ! -e "${target}" && ! -L "${target}" ]] && return 0
        ;;
      regular)
        [[ -f "${target}" && ! -L "${target}" \
            && "$(install_node_identity "${target}" 2>/dev/null || true)" \
              == "${expected_id}" \
            && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
                "${target}" 2>/dev/null || true)" == "${expected_hash}" \
            && "$(install_file_mode "${target}" 2>/dev/null || true)" \
              == "${expected_mode}" ]] && return 0
        ;;
    esac
  done <<< "${BUNDLE_PUBLISHED_SEALS}"
  return 1
}

bundle_latest_published_path_seal_is_current() {
  local wanted="${1:-}" target="${2:-}" row_relative="" state=""
  local expected_id="" expected_hash="" expected_mode="" found=0
  local matched_state="" matched_id="" matched_hash="" matched_mode=""
  bundle_initial_ancestor_seal_is_current "${wanted}" || return 1
  while IFS=$'\t' read -r row_relative state expected_id expected_hash \
      expected_mode; do
    [[ "${row_relative}" == "${wanted}" ]] || continue
    found=1
    matched_state="${state}"
    matched_id="${expected_id}"
    matched_hash="${expected_hash}"
    matched_mode="${expected_mode}"
  done <<< "${BUNDLE_PUBLISHED_SEALS}"
  [[ "${found}" -eq 1 ]] || return 1
  case "${matched_state}" in
    absent)
      [[ ! -e "${target}" && ! -L "${target}" ]]
      ;;
    regular)
      [[ -f "${target}" && ! -L "${target}" \
          && "$(install_node_identity "${target}" 2>/dev/null || true)" \
            == "${matched_id}" \
          && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${target}" 2>/dev/null || true)" == "${matched_hash}" \
          && "$(install_file_mode "${target}" 2>/dev/null || true)" \
            == "${matched_mode}" ]]
      ;;
    *) return 1 ;;
  esac
}

verify_all_published_bundle_seals() {
  local relative="" target=""
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    [[ -n "${relative}" ]] || continue
    target="${CLAUDE_HOME}/${relative}"
    if ! bundle_latest_published_path_seal_is_current \
        "${relative}" "${target}"; then
      printf '  [error] Managed bundle leaf changed after publication: %s\n' \
        "${target}" >&2
      return 1
    fi
  done <<< "${BUNDLE_PUBLISHED_PATHS}"
}

copy_admitted_source_snapshot() {
  local source_root="${1:-}" file_list="${2:-}" destination_root="${3:-}"
  local mode_manifest="${4:-}"
  local relative="" destination="" relative_parent="" parent="" leaf=""
  local ancestor_seal="" parent_id="" stage="" stage_id=""
  local stage_initial_node_id="" stage_node_id="" stage_hash="" stage_mode=""
  local leaf_state="" leaf_id=""
  local leaf_hash="" leaf_mode="" barrier_match="" intended_mode=""
  validate_admitted_file_list "${file_list}" "${source_root}" || return 1
  [[ -z "${mode_manifest}" \
      || ( -f "${mode_manifest}" && ! -L "${mode_manifest}" ) ]] || return 1
  [[ "${destination_root}" == /* \
      && "${destination_root}" != *[[:cntrl:]]* \
      && -d "${destination_root}" && ! -L "${destination_root}" ]] \
    || return 1
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    # Revalidate every row immediately before it can influence mkdir/cp. A
    # transient private-list traversal therefore cannot escape the snapshot.
    case "${relative}" in
      ''|/*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*)
        return 1 ;;
    esac
    [[ -f "${source_root}/${relative}" \
        && ! -L "${source_root}/${relative}" ]] || return 1
    destination="${destination_root}/${relative}"
    if [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 \
        && "${destination_root}" == "${CLAUDE_HOME}" ]] \
        && { ! bundle_initial_ancestor_seal_is_current "${relative}" \
          || ! bundle_initial_seal_is_current "${relative}" "${destination}"; }; then
      printf '  [error] Managed destination changed after backup; preserving it instead of publishing: %s\n' \
        "${destination}" >&2
      return 1
    fi
    relative_parent="${relative%/*}"
    [[ "${relative_parent}" == "${relative}" ]] && relative_parent=""
    capture_destination_ancestor_seal "${destination_root}" \
      "${relative_parent}" ancestor_seal || return 1
    parent="${destination%/*}"
    leaf="${destination##*/}"
    parent_id="$(install_directory_identity "${parent}")" || return 1
    if [[ -L "${destination}" ]]; then
      return 1
    elif [[ -e "${destination}" ]]; then
      [[ -f "${destination}" ]] || return 1
      leaf_state="present"
      leaf_id="$(install_file_identity "${destination}")" || return 1
      leaf_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${destination}")" || return 1
      leaf_mode="$(install_file_mode "${destination}")" || return 1
    else
      leaf_state="absent"
      leaf_id=""
    fi
    stage="$(mktemp "${parent}/.${leaf}.oh-my-claude-copy.XXXXXX")" \
      || return 1
    stage_id="$(install_file_identity "${stage}")" || {
      rm -f -- "${stage}" 2>/dev/null || true
      return 1
    }
    stage_initial_node_id="$(install_node_identity "${stage}")" || return 1
    stage_node_id="${stage_initial_node_id}"
    if ! cp -p -- "${source_root}/${relative}" "${stage}"; then
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    fi
    # cp implementations may replace the destination inode rather than write
    # through the mktemp fd. The successful copy is trusted, so refresh the
    # node identity before chmod or any later cleanup treats the stage as
    # transaction-owned. A failed copy above still cleans up only the original
    # mktemp inode.
    stage_node_id="$(install_node_identity "${stage}")" || {
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_initial_node_id}" 2>/dev/null || true
      return 1
    }
    if [[ -n "${mode_manifest}" ]]; then
      if ! intended_mode="$(awk -F $'\t' -v wanted="${relative}" \
        '$2 == wanted { print $1; found++ } END { if (found != 1) exit 1 }' \
        "${mode_manifest}")" \
          || [[ ! "${intended_mode}" =~ ^[0-7][0145][0145]$ ]] \
          || ! chmod "${intended_mode}" "${stage}"; then
        cleanup_destination_copy_stage "${stage}" "${parent}" \
          "${parent_id}" "${stage_node_id}" 2>/dev/null || true
        return 1
      fi
    fi
    # Seal the fully rendered stage before it becomes publication authority.
    stage_id="$(install_file_identity "${stage}")" || {
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    }
    stage_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${stage}")" || {
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    }
    stage_mode="$(install_file_mode "${stage}")" || {
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    }
    barrier_match="${OMC_TEST_INSTALL_DESTINATION_STAGE_MATCH:-}"
    if [[ -n "${barrier_match}" ]] \
        && [[ "${barrier_match}" == "${relative}" \
          || "${barrier_match}" == "${destination}" ]]; then
      install_test_barrier \
        "${OMC_TEST_INSTALL_DESTINATION_STAGE_READY_FILE:-}" \
        "${OMC_TEST_INSTALL_DESTINATION_STAGE_RELEASE_FILE:-}" \
        "${destination}" || {
          cleanup_destination_copy_stage "${stage}" "${parent}" \
            "${parent_id}" "${stage_node_id}" 2>/dev/null || true
          return 1
        }
    fi
    if [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 \
        && "${destination_root}" == "${CLAUDE_HOME}" ]] \
        && { ! bundle_initial_ancestor_seal_is_current "${relative}" \
          || ! bundle_initial_seal_is_current "${relative}" "${destination}"; }; then
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    fi
    if ! destination_ancestor_seal_is_current "${ancestor_seal}" \
        || [[ "$(install_directory_identity "${parent}" 2>/dev/null || true)" \
          != "${parent_id}" ]] \
        || [[ ! -f "${stage}" || -L "${stage}" \
          || "$(install_file_identity "${stage}" 2>/dev/null || true)" \
            != "${stage_id}" \
          || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${stage}" 2>/dev/null || true)" != "${stage_hash}" \
          || "$(install_file_mode "${stage}" 2>/dev/null || true)" \
            != "${stage_mode}" ]]; then
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    fi
    if [[ "${leaf_state}" == "absent" ]]; then
      if [[ -e "${destination}" || -L "${destination}" ]]; then
        cleanup_destination_copy_stage "${stage}" "${parent}" \
          "${parent_id}" "${stage_node_id}" 2>/dev/null || true
        return 1
      fi
    elif [[ ! -f "${destination}" || -L "${destination}" \
        || "$(install_file_identity "${destination}" 2>/dev/null || true)" \
          != "${leaf_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${destination}" 2>/dev/null || true)" != "${leaf_hash}" \
        || "$(install_file_mode "${destination}" 2>/dev/null || true)" \
          != "${leaf_mode}" ]]; then
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    fi
    # Arm the exact sealed stage before the rename. If the process stops at
    # the rename boundary, rollback can distinguish both the untouched
    # initial generation and every generation this invocation published.
    arm_published_bundle_path "${destination_root}" "${relative}" \
      regular "${stage_node_id}" "${stage_hash}" "${stage_mode}" || {
        cleanup_destination_copy_stage "${stage}" "${parent}" \
          "${parent_id}" "${stage_node_id}" 2>/dev/null || true
        return 1
      }
    if ! mv -f -- "${stage}" "${destination}" \
        || ! destination_ancestor_seal_is_current "${ancestor_seal}" \
        || [[ ! -f "${destination}" || -L "${destination}" \
          || "$(install_node_identity "${destination}" 2>/dev/null || true)" \
            != "${stage_node_id}" \
          || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${destination}" 2>/dev/null || true)" != "${stage_hash}" \
          || "$(install_file_mode "${destination}" 2>/dev/null || true)" \
            != "${stage_mode}" ]]; then
      cleanup_destination_copy_stage "${stage}" "${parent}" \
        "${parent_id}" "${stage_node_id}" 2>/dev/null || true
      return 1
    fi
    record_published_bundle_path "${destination_root}" "${relative}" \
      regular "${stage_node_id}" "${stage_hash}" "${stage_mode}" \
      || return 1
    barrier_match="${OMC_TEST_INSTALL_DESTINATION_PUBLISHED_MATCH:-}"
    if [[ -n "${barrier_match}" ]] \
        && [[ "${barrier_match}" == "${relative}" \
          || "${barrier_match}" == "${destination}" ]]; then
      install_test_barrier \
        "${OMC_TEST_INSTALL_DESTINATION_PUBLISHED_READY_FILE:-}" \
        "${OMC_TEST_INSTALL_DESTINATION_PUBLISHED_RELEASE_FILE:-}" \
        "${destination}" || return 1
    fi
  done < "${file_list}"
}

verify_exact_snapshot_tree() {
  local snapshot_root="${1:-}" file_list="${2:-}"
  local expected_manifest_hash="${3:-}" label="${4:-source snapshot}"
  local actual_list=""
  actual_list="$(mktemp)" || return 1
  if ! build_admitted_source_file_list "${snapshot_root}" "${actual_list}" \
      "${label}" 1 \
      || ! command cmp -s "${file_list}" "${actual_list}" \
      || ! verify_copied_tree_content "${snapshot_root}" "${actual_list}" \
        "${expected_manifest_hash}" "${label}"; then
    rm -f -- "${actual_list}"
    return 1
  fi
  rm -f -- "${actual_list}"
}

verify_copied_file_hash() {
  local destination="${1:-}" expected_hash="${2:-}" label="${3:-file}"
  local actual_hash=""
  [[ -f "${destination}" && ! -L "${destination}" \
      && "${expected_hash}" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  actual_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${destination}" 2>/dev/null || true)"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    printf '  [error] Copied %s does not match its preflight source hash: %s\n' \
      "${label}" "${destination}" >&2
    return 1
  fi
}

build_admitted_source_file_list() {
  local root="${1:-}" output="${2:-}" label="${3:-source tree}"
  local required="${4:-1}" node="" relative="" failures=0

  if [[ ! -e "${root}" && ! -L "${root}" ]]; then
    if [[ "${required}" -eq 1 ]]; then
      printf '  [error] Missing %s: %s\n' "${label}" "${root}" >&2
      return 1
    fi
    : > "${output}"
    return 0
  fi
  if [[ ! -d "${root}" || -L "${root}" ]]; then
    printf '  [error] %s root is not a real directory: %s\n' \
      "${label}" "${root}" >&2
    return 1
  fi

  SOURCE_TREE_NODE_LIST="$(mktemp)"
  if ! find "${root}" -mindepth 1 -print0 > "${SOURCE_TREE_NODE_LIST}"; then
    printf '  [error] Could not enumerate %s: %s\n' "${label}" "${root}" >&2
    return 1
  fi
  : > "${output}"
  while IFS= read -r -d '' node; do
    case "${node}" in
      "${root}"/*) relative="${node#"${root}"/}" ;;
      *)
        printf '  [error] %s enumeration escaped its root: %s\n' \
          "${label}" "${node}" >&2
        failures=$((failures + 1))
        continue
        ;;
    esac
    if [[ -z "${relative}" || "${relative}" == *[[:cntrl:]]* \
        || "${relative}" == *\\* || "${relative}" == /* \
        || "${relative}" == ../* \
        || "${relative}" == */../* ]]; then
      printf '  [error] %s contains an unsafe path: %s\n' \
        "${label}" "${node}" >&2
      failures=$((failures + 1))
    elif [[ -L "${node}" ]]; then
      printf '  [error] %s contains a symlink: %s\n' \
        "${label}" "${node}" >&2
      failures=$((failures + 1))
    elif [[ -d "${node}" ]]; then
      :
    elif [[ -f "${node}" ]]; then
      [[ "${node##*/}" == ".DS_Store" ]] \
        || printf '%s\n' "${relative}" >> "${output}"
    else
      printf '  [error] %s contains a special filesystem node: %s\n' \
        "${label}" "${node}" >&2
      failures=$((failures + 1))
    fi
  done < "${SOURCE_TREE_NODE_LIST}"
  rm -f -- "${SOURCE_TREE_NODE_LIST}"
  SOURCE_TREE_NODE_LIST=""
  LC_ALL=C sort -u -o "${output}" "${output}"
  [[ "${failures}" -eq 0 ]]
}

preflight_source_distribution_trees() {
  local ghostty_required=0 failures=0
  capture_auxiliary_source_seal "${INSTALL_STATE_REPORT_SOURCE}" \
    INSTALL_STATE_REPORT_SOURCE || return 1
  capture_auxiliary_source_seal "${CHANGELOG_SOURCE}" \
    CHANGELOG_SOURCE || return 1
  SOURCE_BUNDLE_FILE_LIST="$(mktemp)"
  SOURCE_GHOSTTY_FILE_LIST="$(mktemp)"
  SOURCE_USER_TEMPLATE_FILE_LIST="$(mktemp)"
  SOURCE_BUNDLE_CONTENT_MANIFEST="$(mktemp)"
  SOURCE_GHOSTTY_CONTENT_MANIFEST="$(mktemp)"
  SOURCE_USER_TEMPLATE_CONTENT_MANIFEST="$(mktemp)"
  SOURCE_BUNDLE_MODE_MANIFEST="$(mktemp)"
  SOURCE_GHOSTTY_MODE_MANIFEST="$(mktemp)"
  SOURCE_USER_TEMPLATE_MODE_MANIFEST="$(mktemp)"
  should_install_ghostty && ghostty_required=1

  build_admitted_source_file_list "${BUNDLE_CLAUDE}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "bundle/dot-claude" 1 \
    || failures=$((failures + 1))
  build_admitted_source_file_list "${OMC_USER_TEMPLATE_SOURCE}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" "bundle/omc-user-template" 1 \
    || failures=$((failures + 1))
  # Validate an optional Ghostty tree whenever it is present; require it when
  # this invocation would actually install Ghostty.
  build_admitted_source_file_list "${BUNDLE_GHOSTTY}" \
    "${SOURCE_GHOSTTY_FILE_LIST}" "config/ghostty" \
    "${ghostty_required}" || failures=$((failures + 1))

  if [[ "${failures}" -ne 0 ]]; then
    printf '  [error] Source distribution tree preflight failed; installed files were not changed.\n' >&2
    return 1
  fi
  generate_source_mode_manifest "${BUNDLE_CLAUDE}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_MODE_MANIFEST}" 0 \
    || return 1
  generate_source_mode_manifest "${OMC_USER_TEMPLATE_SOURCE}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}" 0 || return 1
  if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
    generate_source_mode_manifest "${BUNDLE_GHOSTTY}" \
      "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_MODE_MANIFEST}" 0 \
      || return 1
  fi
  seal_source_content_manifest "${SOURCE_BUNDLE_MODE_MANIFEST}" \
    SOURCE_BUNDLE_MODE_MANIFEST_ID SOURCE_BUNDLE_MODE_MANIFEST_PARENT_ID \
    SOURCE_BUNDLE_MODE_MANIFEST_HASH || return 1
  seal_source_content_manifest "${SOURCE_GHOSTTY_MODE_MANIFEST}" \
    SOURCE_GHOSTTY_MODE_MANIFEST_ID SOURCE_GHOSTTY_MODE_MANIFEST_PARENT_ID \
    SOURCE_GHOSTTY_MODE_MANIFEST_HASH || return 1
  seal_source_content_manifest "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}" \
    SOURCE_USER_TEMPLATE_MODE_MANIFEST_ID \
    SOURCE_USER_TEMPLATE_MODE_MANIFEST_PARENT_ID \
    SOURCE_USER_TEMPLATE_MODE_MANIFEST_HASH || return 1
  # Freeze source bytes, not only admitted paths. A same-path A -> B -> A
  # swap can leave every path-list seal current while rsync reads transient B
  # bytes. These trusted manifests are the immutable copy authority used by
  # live re-attestation and immediate destination verification.
  \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
    "${BUNDLE_CLAUDE}" "${SOURCE_BUNDLE_FILE_LIST}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST}" || return 1
  if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
    \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
      "${BUNDLE_GHOSTTY}" "${SOURCE_GHOSTTY_FILE_LIST}" \
      "${SOURCE_GHOSTTY_CONTENT_MANIFEST}" || return 1
  fi
  \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
    "${OMC_USER_TEMPLATE_SOURCE}" "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST}" || return 1
  seal_source_content_manifest "${SOURCE_BUNDLE_CONTENT_MANIFEST}" \
    SOURCE_BUNDLE_CONTENT_MANIFEST_ID \
    SOURCE_BUNDLE_CONTENT_MANIFEST_PARENT_ID \
    SOURCE_BUNDLE_CONTENT_MANIFEST_HASH || return 1
  seal_source_content_manifest "${SOURCE_GHOSTTY_CONTENT_MANIFEST}" \
    SOURCE_GHOSTTY_CONTENT_MANIFEST_ID \
    SOURCE_GHOSTTY_CONTENT_MANIFEST_PARENT_ID \
    SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH || return 1
  seal_source_content_manifest "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST}" \
    SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_ID \
    SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_PARENT_ID \
    SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH || return 1

  chmod 400 "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_GHOSTTY_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" 2>/dev/null || return 1
  seal_source_content_manifest "${SOURCE_BUNDLE_FILE_LIST}" \
    SOURCE_BUNDLE_FILE_LIST_ID SOURCE_BUNDLE_FILE_LIST_PARENT_ID \
    SOURCE_BUNDLE_FILE_LIST_HASH || return 1
  seal_source_content_manifest "${SOURCE_GHOSTTY_FILE_LIST}" \
    SOURCE_GHOSTTY_FILE_LIST_ID SOURCE_GHOSTTY_FILE_LIST_PARENT_ID \
    SOURCE_GHOSTTY_FILE_LIST_HASH || return 1
  seal_source_content_manifest "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    SOURCE_USER_TEMPLATE_FILE_LIST_ID SOURCE_USER_TEMPLATE_FILE_LIST_PARENT_ID \
    SOURCE_USER_TEMPLATE_FILE_LIST_HASH || return 1
  install_test_barrier \
    "${OMC_TEST_INSTALL_SOURCE_LIST_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_SOURCE_LIST_RELEASE_FILE:-}" \
    "${SOURCE_BUNDLE_FILE_LIST}" || return 1

  # Copy each admitted release tree into an invocation-private generation.
  # All later distribution copies consume this generation rather than reopening
  # mutable repository leaves. Exact node-set + content-manifest comparison
  # rejects transient file-list A->B->A injection and transient source bytes.
  SOURCE_SNAPSHOT_ROOT="$(mktemp -d)" || return 1
  SOURCE_SNAPSHOT_ROOT_ID="$(install_directory_identity \
    "${SOURCE_SNAPSHOT_ROOT}")" || return 1
  chmod 700 "${SOURCE_SNAPSHOT_ROOT}" 2>/dev/null || true
  SOURCE_BUNDLE_SNAPSHOT="${SOURCE_SNAPSHOT_ROOT}/bundle"
  SOURCE_GHOSTTY_SNAPSHOT="${SOURCE_SNAPSHOT_ROOT}/ghostty"
  SOURCE_USER_TEMPLATE_SNAPSHOT="${SOURCE_SNAPSHOT_ROOT}/user-template"
  INSTALL_STATE_REPORT_SNAPSHOT="${SOURCE_SNAPSHOT_ROOT}/install-state-report.sh"
  CHANGELOG_SNAPSHOT="${SOURCE_SNAPSHOT_ROOT}/CHANGELOG.md"
  mkdir -- "${SOURCE_BUNDLE_SNAPSHOT}" "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_SNAPSHOT}" || return 1
  snapshot_auxiliary_source "${INSTALL_STATE_REPORT_SOURCE}" \
    "${INSTALL_STATE_REPORT_SNAPSHOT}" INSTALL_STATE_REPORT_SOURCE \
    INSTALL_STATE_REPORT_SNAPSHOT || return 1
  snapshot_auxiliary_source "${CHANGELOG_SOURCE}" "${CHANGELOG_SNAPSHOT}" \
    CHANGELOG_SOURCE CHANGELOG_SNAPSHOT || return 1
  copy_admitted_source_snapshot "${BUNDLE_CLAUDE}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_SNAPSHOT}" || return 1
  if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
    copy_admitted_source_snapshot "${BUNDLE_GHOSTTY}" \
      "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_SNAPSHOT}" || return 1
  fi
  copy_admitted_source_snapshot "${OMC_USER_TEMPLATE_SOURCE}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    || return 1
  install_test_barrier \
    "${OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_SOURCE_SNAPSHOT_COPIED_RELEASE_FILE:-}" \
    "${SOURCE_BUNDLE_SNAPSHOT}" || return 1
  verify_tree_mode_manifest "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_MODE_MANIFEST_HASH}" 0 \
    || return 1
  verify_tree_mode_manifest "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_MODE_MANIFEST_HASH}" 0 \
    || return 1
  verify_tree_mode_manifest "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST_HASH}" 0 || return 1
  verify_exact_snapshot_tree "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" \
    "private bundle snapshot" || return 1
  verify_exact_snapshot_tree "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH}" \
    "private Ghostty snapshot" || return 1
  verify_exact_snapshot_tree "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH}" \
    "private user-template snapshot" || return 1
  # The auxiliary snapshots above are already sealed at mode 0400 and their
  # identity includes ctime. GNU chmod updates ctime even when re-applying the
  # same mode, so recursively chmodding the root invalidates our own seals on
  # slower preflights. Protect the copied trees recursively, then protect only
  # the root directory; leave the already-protected auxiliary leaves untouched.
  chmod -R a-w "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_SNAPSHOT}" 2>/dev/null || return 1
  chmod a-w "${SOURCE_SNAPSHOT_ROOT}" 2>/dev/null || return 1
  verify_protected_tree_modes "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_MODE_MANIFEST}" || return 1
  verify_protected_tree_modes "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_MODE_MANIFEST}" || return 1
  verify_protected_tree_modes "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}" || return 1

  if [[ -f "${SOURCE_GHOSTTY_SNAPSHOT}/themes/Claude OpenCode" ]]; then
    SOURCE_GHOSTTY_THEME_HASH="$(\trusted_sha256_file \
      "${TRUSTED_SHA256_TOOL}" \
      "${SOURCE_GHOSTTY_SNAPSHOT}/themes/Claude OpenCode")" || return 1
  fi
  if [[ -f "${SOURCE_GHOSTTY_SNAPSHOT}/config.snippet.ini" ]]; then
    SOURCE_GHOSTTY_SNIPPET_HASH="$(\trusted_sha256_file \
      "${TRUSTED_SHA256_TOOL}" \
      "${SOURCE_GHOSTTY_SNAPSHOT}/config.snippet.ini")" || return 1
  fi
  if [[ -f "${SOURCE_USER_TEMPLATE_SNAPSHOT}/overrides.md" ]]; then
    SOURCE_USER_TEMPLATE_OVERRIDES_HASH="$(\trusted_sha256_file \
      "${TRUSTED_SHA256_TOOL}" \
      "${SOURCE_USER_TEMPLATE_SNAPSHOT}/overrides.md")" || return 1
  fi
}

source_distribution_seal_is_current() {
  local bundle_now="" ghostty_now="" template_now="" ghostty_required=0
  local bundle_content_now="" ghostty_content_now="" template_content_now=""
  local bundle_content_hash="" ghostty_content_hash="" template_content_hash=""
  local failures=0
  auxiliary_distribution_seals_are_current || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_FILE_LIST_ID}" \
    "${SOURCE_BUNDLE_FILE_LIST_PARENT_ID}" \
    "${SOURCE_BUNDLE_FILE_LIST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_FILE_LIST_ID}" \
    "${SOURCE_GHOSTTY_FILE_LIST_PARENT_ID}" \
    "${SOURCE_GHOSTTY_FILE_LIST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST_ID}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST_PARENT_ID}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST_ID}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST_PARENT_ID}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_GHOSTTY_CONTENT_MANIFEST}" \
    "${SOURCE_GHOSTTY_CONTENT_MANIFEST_ID}" \
    "${SOURCE_GHOSTTY_CONTENT_MANIFEST_PARENT_ID}" \
    "${SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_ID}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_PARENT_ID}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_BUNDLE_MODE_MANIFEST}" "${SOURCE_BUNDLE_MODE_MANIFEST_ID}" \
    "${SOURCE_BUNDLE_MODE_MANIFEST_PARENT_ID}" \
    "${SOURCE_BUNDLE_MODE_MANIFEST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_GHOSTTY_MODE_MANIFEST}" "${SOURCE_GHOSTTY_MODE_MANIFEST_ID}" \
    "${SOURCE_GHOSTTY_MODE_MANIFEST_PARENT_ID}" \
    "${SOURCE_GHOSTTY_MODE_MANIFEST_HASH}" || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST_ID}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST_PARENT_ID}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST_HASH}" || return 1
  verify_tree_mode_manifest "${BUNDLE_CLAUDE}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_MODE_MANIFEST_HASH}" 0 \
    || return 1
  if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
    verify_tree_mode_manifest "${BUNDLE_GHOSTTY}" \
      "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_MODE_MANIFEST_HASH}" 0 \
      || return 1
  elif [[ -s "${SOURCE_GHOSTTY_FILE_LIST}" ]]; then
    return 1
  fi
  verify_tree_mode_manifest "${OMC_USER_TEMPLATE_SOURCE}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST_HASH}" 0 || return 1
  verify_protected_tree_modes "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_MODE_MANIFEST}" || return 1
  verify_protected_tree_modes "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_MODE_MANIFEST}" || return 1
  verify_protected_tree_modes "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}" || return 1
  verify_exact_snapshot_tree "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" \
    "private bundle snapshot" || return 1
  verify_exact_snapshot_tree "${SOURCE_GHOSTTY_SNAPSHOT}" \
    "${SOURCE_GHOSTTY_FILE_LIST}" "${SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH}" \
    "private Ghostty snapshot" || return 1
  verify_exact_snapshot_tree "${SOURCE_USER_TEMPLATE_SNAPSHOT}" \
    "${SOURCE_USER_TEMPLATE_FILE_LIST}" \
    "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH}" \
    "private user-template snapshot" || return 1

  bundle_now="$(mktemp)"
  ghostty_now="$(mktemp)"
  template_now="$(mktemp)"
  bundle_content_now="$(mktemp)"
  ghostty_content_now="$(mktemp)"
  template_content_now="$(mktemp)"
  should_install_ghostty && ghostty_required=1
  build_admitted_source_file_list "${BUNDLE_CLAUDE}" "${bundle_now}" \
    "bundle/dot-claude" 1 || failures=$((failures + 1))
  build_admitted_source_file_list "${BUNDLE_GHOSTTY}" "${ghostty_now}" \
    "config/ghostty" "${ghostty_required}" || failures=$((failures + 1))
  build_admitted_source_file_list "${OMC_USER_TEMPLATE_SOURCE}" \
    "${template_now}" "bundle/omc-user-template" 1 \
    || failures=$((failures + 1))
  if [[ "${failures}" -eq 0 ]]; then
    command cmp -s "${SOURCE_BUNDLE_FILE_LIST}" "${bundle_now}" \
      || failures=$((failures + 1))
    command cmp -s "${SOURCE_GHOSTTY_FILE_LIST}" "${ghostty_now}" \
      || failures=$((failures + 1))
    command cmp -s "${SOURCE_USER_TEMPLATE_FILE_LIST}" "${template_now}" \
      || failures=$((failures + 1))
  fi
  if [[ "${failures}" -eq 0 ]]; then
    \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
      "${BUNDLE_CLAUDE}" "${bundle_now}" "${bundle_content_now}" \
      || failures=$((failures + 1))
    if [[ -d "${BUNDLE_GHOSTTY}" ]]; then
      \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
        "${BUNDLE_GHOSTTY}" "${ghostty_now}" "${ghostty_content_now}" \
        || failures=$((failures + 1))
    fi
    \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
      "${OMC_USER_TEMPLATE_SOURCE}" "${template_now}" \
      "${template_content_now}" || failures=$((failures + 1))
  fi
  if [[ "${failures}" -eq 0 ]]; then
    bundle_content_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${bundle_content_now}" 2>/dev/null || true)"
    ghostty_content_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${ghostty_content_now}" 2>/dev/null || true)"
    template_content_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
      "${template_content_now}" 2>/dev/null || true)"
    [[ "${bundle_content_hash}" == "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" ]] \
      || failures=$((failures + 1))
    [[ "${ghostty_content_hash}" == "${SOURCE_GHOSTTY_CONTENT_MANIFEST_HASH}" ]] \
      || failures=$((failures + 1))
    [[ "${template_content_hash}" == "${SOURCE_USER_TEMPLATE_CONTENT_MANIFEST_HASH}" ]] \
      || failures=$((failures + 1))
  fi
  rm -f -- "${bundle_now}" "${ghostty_now}" "${template_now}" \
    "${bundle_content_now}" "${ghostty_content_now}" \
    "${template_content_now}"
  [[ "${failures}" -eq 0 ]]
}

preflight_destination_file_list() {
  local root="${1:-}" file_list="${2:-}" label="${3:-destination}"
  local require_leaf="${4:-0}"
  local relative="" segment="" current="" index=0 count=0
  local -a segments=()
  [[ -d "${root}" ]] || return 1
  while IFS= read -r relative; do
    [[ -n "${relative}" && "${relative}" != *[[:cntrl:]]* ]] || continue
    IFS='/' read -r -a segments <<< "${relative}"
    count="${#segments[@]}"
    current="${root}"
    index=0
    for segment in "${segments[@]}"; do
      index=$((index + 1))
      [[ -n "${segment}" && "${segment}" != "." \
          && "${segment}" != ".." ]] || return 1
      current="${current}/${segment}"
      if [[ -L "${current}" ]]; then
        printf '  [error] Refusing %s through symlinked path: %s\n' \
          "${label}" "${current}" >&2
        return 1
      fi
      if [[ "${index}" -lt "${count}" && -e "${current}" \
          && ! -d "${current}" ]]; then
        printf '  [error] Refusing %s through non-directory path: %s\n' \
          "${label}" "${current}" >&2
        return 1
      fi
      if [[ "${index}" -eq "${count}" && -e "${current}" \
          && ! -f "${current}" ]]; then
        printf '  [error] Refusing %s over non-regular leaf: %s\n' \
          "${label}" "${current}" >&2
        return 1
      fi
      if [[ "${index}" -eq "${count}" && "${require_leaf}" -eq 1 \
          && ! -f "${current}" ]]; then
        printf '  [error] %s did not materialize regular leaf: %s\n' \
          "${label}" "${current}" >&2
        return 1
      fi
    done
  done < "${file_list}"
}

preflight_destination_directory_path() {
  local root="${1:-}" relative="${2:-}" label="${3:-destination directory}"
  local component="${root}" segment=""
  local -a segments=()
  [[ -d "${root}" && -n "${relative}" \
      && "${relative}" != *[[:cntrl:]]* ]] || return 1
  IFS='/' read -r -a segments <<< "${relative}"
  for segment in "${segments[@]}"; do
    [[ -n "${segment}" && "${segment}" != "." \
        && "${segment}" != ".." ]] || return 1
    component="${component}/${segment}"
    if [[ -L "${component}" ]]; then
      printf '  [error] Refusing %s through symlinked path: %s\n' \
        "${label}" "${component}" >&2
      return 1
    fi
    if [[ -e "${component}" && ! -d "${component}" ]]; then
      printf '  [error] Refusing %s through non-directory path: %s\n' \
        "${label}" "${component}" >&2
      return 1
    fi
  done
}

preflight_managed_destination_paths() {
  local require_leaf="${1:-0}"
  preflight_destination_file_list "${CLAUDE_HOME}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "bundle install" "${require_leaf}" || return 1
  preflight_destination_directory_path "${CLAUDE_HOME}" "backups" \
    "backup allocation" || return 1
  preflight_destination_directory_path "${CLAUDE_HOME}" \
    "quality-pack/state" "manifest publication" || return 1
}

install_control_target_is_safe() {
  local target="${1:-}" relative="" parent_relative="" parent=""
  [[ "${target}" == "${CLAUDE_HOME}/"* \
      && "${target}" != *[[:cntrl:]]* ]] || return 1
  relative="${target#"${CLAUDE_HOME}/"}"
  [[ -n "${relative}" && "${relative}" != *\\* \
      && "${relative}" != */../* \
      && "${relative}" != ../* && "${relative}" != */.. \
      && "${relative}" != *//* ]] || return 1
  parent_relative="${relative%/*}"
  if [[ "${parent_relative}" != "${relative}" ]]; then
    preflight_destination_directory_path "${CLAUDE_HOME}" \
      "${parent_relative}" "control publication" || return 1
  fi
  parent="${target%/*}"
  [[ -d "${parent}" && ! -L "${parent}" \
      && ! -L "${target}" ]] || return 1
  [[ ! -e "${target}" || -f "${target}" ]]
}

create_install_control_stage() {
  local target="${1:-}" output_var="${2:-}" parent="" leaf="" stage=""
  [[ -n "${output_var}" ]] || return 1
  install_control_target_is_safe "${target}" || return 1
  parent="${target%/*}"
  leaf="${target##*/}"
  stage="$(mktemp "${parent}/.${leaf}.oh-my-claude.XXXXXX")" || return 1
  [[ -f "${stage}" && ! -L "${stage}" ]] || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  chmod 600 "${stage}" 2>/dev/null || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  printf -v "${output_var}" '%s' "${stage}"
}

publish_install_control_stage() {
  local stage="${1:-}" target="${2:-}" key="${3:-}" parent="" leaf=""
  local stage_node_id="" stage_hash="" stage_mode=""
  [[ "${key}" =~ ^[a-z0-9-]+$ ]] || return 1
  [[ -f "${stage}" && ! -L "${stage}" ]] || return 1
  parent="${target%/*}"
  leaf="${target##*/}"
  [[ "${stage}" == "${parent}/.${leaf}.oh-my-claude."* ]] || return 1
  install_control_target_is_safe "${target}" \
    && install_transaction_path_phase_is_current \
      "${target}" "${key}" initial 1 \
    || return 1
  stage_node_id="$(install_node_identity "${stage}")" || return 1
  stage_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" "${stage}")" \
    || return 1
  stage_mode="$(install_file_mode "${stage}")" || return 1
  if ! install_control_target_is_safe "${target}" \
      || ! install_transaction_path_phase_is_current \
        "${target}" "${key}" initial 1 \
      || [[ ! -f "${stage}" || -L "${stage}" \
        || "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          != "${stage_node_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${stage}" 2>/dev/null || true)" != "${stage_hash}" \
        || "$(install_file_mode "${stage}" 2>/dev/null || true)" \
          != "${stage_mode}" ]]; then
    return 1
  fi
  arm_install_transaction_publication "${target}" "${key}" regular \
    "${stage_node_id}" "${stage_hash}" "${stage_mode}" || return 1
  if ! mv -f -- "${stage}" "${target}" \
      || [[ ! -f "${target}" || -L "${target}" \
        || "$(install_node_identity "${target}" 2>/dev/null || true)" \
          != "${stage_node_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${target}" 2>/dev/null || true)" != "${stage_hash}" \
        || "$(install_file_mode "${target}" 2>/dev/null || true)" \
          != "${stage_mode}" ]] \
      || ! record_install_transaction_publication "${target}" "${key}" \
        regular "${stage_node_id}" "${stage_hash}" "${stage_mode}"; then
    return 1
  fi
}

build_active_managed_file_list() {
  local output="${1:-}" relative="" target="" expected=0 actual=0
  [[ -f "${output}" && ! -L "${output}" ]] || return 1
  source_distribution_seal_is_current || return 1
  : > "${output}" || return 1
  while IFS= read -r relative || [[ -n "${relative}" ]]; do
    [[ -n "${relative}" ]] || continue
    case "${relative}" in
      /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*)
        return 1 ;;
    esac
    if [[ "${EXCLUDE_IOS}" == "true" \
        && "${relative}" == agents/ios-*.md ]]; then
      continue
    fi
    expected=$((expected + 1))
    target="${CLAUDE_HOME}/${relative}"
    [[ -f "${target}" && ! -L "${target}" ]] || return 1
    printf '%s\n' "${relative}" >> "${output}" || return 1
  done < "${SOURCE_BUNDLE_FILE_LIST}"
  LC_ALL=C sort -u -o "${output}" "${output}" || return 1
  actual="$(wc -l < "${output}" | tr -d '[:space:]')"
  [[ "${actual}" == "${expected}" && "${actual}" -gt 0 ]] || return 1
  source_distribution_seal_is_current
}

# Validate the immutable source bundle before acquiring the install lock or
# creating anything below CLAUDE_HOME. A post-copy check cannot distinguish a
# missing source file from a stale installed orphan when rsync runs without
# --delete, and it reports malformed source only after unrelated installed
# files have already been overwritten. The source distribution must always
# contain the complete 37-agent roster, including iOS definitions when the
# caller selected --no-ios; that flag changes the destination shape, not what
# constitutes a coherent release artifact.
preflight_source_shipped_model_roster() {
  local agents_dir="${BUNDLE_CLAUDE}/agents"
  local agent agent_file expected_model
  local name_count name_value model_count model_value source_file source_agent
  local failures=0

  if [[ ! -d "${agents_dir}" ]]; then
    printf '  [error] Missing bundled agent directory: %s\n' "${agents_dir}" >&2
    return 1
  fi

  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    agent_file="${agents_dir}/${agent}.md"
    if [[ ! -f "${agent_file}" || -L "${agent_file}" ]]; then
      printf '  [error] Missing bundled shipped agent definition: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi

    if ! parse_agent_frontmatter "${agent_file}"; then
      printf '  [error] Malformed bundled agent frontmatter fences: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi

    name_count="${AGENT_FRONTMATTER_NAME_COUNT}"
    name_value="${AGENT_FRONTMATTER_NAME_VALUE}"
    model_count="${AGENT_FRONTMATTER_MODEL_COUNT}"
    model_value="${AGENT_FRONTMATTER_MODEL_VALUE}"
    expected_model="sonnet"
    case " ${SHIPPED_INHERIT_AGENTS} " in
      *" ${agent} "*) expected_model="inherit" ;;
    esac

    if [[ "${name_count}" != "1" || "${name_value}" != "${agent}" ]]; then
      printf '  [error] Malformed bundled agent name frontmatter: %s (expected exactly one name: %s line).\n' \
        "${agent_file}" "${agent}" >&2
      failures=$((failures + 1))
    fi
    if [[ "${model_count}" != "1" || "${model_value}" != "${expected_model}" ]]; then
      printf '  [error] Malformed bundled agent model frontmatter: %s (expected exactly one model: %s line).\n' \
        "${agent_file}" "${expected_model}" >&2
      failures=$((failures + 1))
    fi
  done

  # Fail closed on a new bundled definition whose filename was not added to
  # the declaration rosters. Otherwise model-tier reconstruction would copy
  # the file but silently leave it outside the quality/economy policy.
  while IFS= read -r source_file; do
    [[ -n "${source_file}" ]] || continue
    source_agent="${source_file#"${agents_dir}"/}"
    source_agent="${source_agent%.md}"
    if [[ "${source_agent}" == */* ]] \
        || ! installed_shipped_agent_is_known "${source_agent}"; then
      printf '  [error] Unexpected bundled agent definition outside the shipped roster: %s\n' \
        "${source_file}" >&2
      failures=$((failures + 1))
    fi
  done < <(find "${agents_dir}" \( -type f -o -type l \) -name '*.md' -print 2>/dev/null | LC_ALL=C sort)

  if [[ "${failures}" -ne 0 ]]; then
    printf '  [error] Source bundle agent preflight failed; installed files were not changed.\n' >&2
    return 1
  fi
}

# Prove the settings ownership authority and every referenced hook script
# before acquiring the install lock or copying any bundle file. The merge runs
# late in the install transaction; without this preflight, malformed JSON or a
# dangling command is discovered only after the prior install was overwritten.
SETTINGS_PATCH_SEAL_PATH=""
SETTINGS_PATCH_SEAL_TARGET_ID=""
SETTINGS_PATCH_SEAL_PARENT_ID=""
SETTINGS_PATCH_SEAL_HASH=""
SETTINGS_PATCH_SNAPSHOT=""
SETTINGS_PATCH_SNAPSHOT_TARGET_ID=""
SETTINGS_PATCH_SNAPSHOT_PARENT_ID=""
SETTINGS_PATCH_SNAPSHOT_HASH=""
SETTINGS_PATCH_SNAPSHOT_MODE=""
SETTINGS_PATCH_MAX_BYTES=4194304

capture_source_settings_patch_seal() {
  local physical="" parent=""
  [[ -f "${SETTINGS_PATCH}" && ! -L "${SETTINGS_PATCH}" ]] || return 1
  physical="$(resolve_install_regular_file_physical_path \
    "${SETTINGS_PATCH}" 2>/dev/null)" || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_PATCH_SEAL_PATH="${physical}"
  SETTINGS_PATCH_SEAL_TARGET_ID="$(install_snapshot_file_identity \
    "${physical}")" \
    || return 1
  SETTINGS_PATCH_SEAL_PARENT_ID="$(install_directory_identity "${parent}")" \
    || return 1
  SETTINGS_PATCH_SEAL_HASH=""
}

settings_patch_seal_is_current() {
  local physical="" parent="" target_id="" parent_id=""
  [[ -f "${SETTINGS_PATCH}" && ! -L "${SETTINGS_PATCH}" ]] || return 1
  physical="$(resolve_install_regular_file_physical_path \
    "${SETTINGS_PATCH}" 2>/dev/null)" || return 1
  [[ "${physical}" == "${SETTINGS_PATCH_SEAL_PATH}" ]] || return 1
  parent="${physical%/*}"
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(install_snapshot_file_identity "${physical}")" || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  [[ -n "${SETTINGS_PATCH_SEAL_HASH}" \
      && "${target_id}" == "${SETTINGS_PATCH_SEAL_TARGET_ID}" \
      && "${parent_id}" == "${SETTINGS_PATCH_SEAL_PARENT_ID}" ]] \
    && install_regular_file_snapshot_is_current "${physical}" \
      "${SETTINGS_PATCH_SNAPSHOT}" "${SETTINGS_PATCH_MAX_BYTES}"
}

capture_settings_patch_snapshot() {
  local parent=""
  SETTINGS_PATCH_SNAPSHOT="$(mktemp)" || return 1
  [[ -f "${SETTINGS_PATCH_SNAPSHOT}" && ! -L "${SETTINGS_PATCH_SNAPSHOT}" ]] \
    || return 1
  if ! install_capture_regular_file_snapshot "${SETTINGS_PATCH_SEAL_PATH}" \
      "${SETTINGS_PATCH_SNAPSHOT}" "${SETTINGS_PATCH_MAX_BYTES}"; then
    return 1
  fi
  chmod 400 "${SETTINGS_PATCH_SNAPSHOT}" 2>/dev/null || return 1
  parent="${SETTINGS_PATCH_SNAPSHOT%/*}"
  [[ -n "${parent}" ]] || parent="/"
  SETTINGS_PATCH_SNAPSHOT_TARGET_ID="$(install_snapshot_file_identity \
    "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  SETTINGS_PATCH_SNAPSHOT_PARENT_ID="$(install_directory_identity \
    "${parent}")" || return 1
  SETTINGS_PATCH_SNAPSHOT_HASH="$(\trusted_sha256_file \
    "${TRUSTED_SHA256_TOOL}" "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  SETTINGS_PATCH_SEAL_HASH="${SETTINGS_PATCH_SNAPSHOT_HASH}"
  SETTINGS_PATCH_SNAPSHOT_MODE="$(install_file_mode \
    "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  [[ "${SETTINGS_PATCH_SNAPSHOT_MODE}" =~ ^0?400$ ]] \
    && settings_patch_seal_is_current
}

settings_patch_snapshot_is_current() {
  local parent="" target_id="" parent_id="" digest="" mode="" observed=""
  [[ -n "${SETTINGS_PATCH_SNAPSHOT}" \
      && -f "${SETTINGS_PATCH_SNAPSHOT}" \
      && ! -L "${SETTINGS_PATCH_SNAPSHOT}" ]] || return 1
  parent="${SETTINGS_PATCH_SNAPSHOT%/*}"
  [[ -n "${parent}" ]] || parent="/"
  target_id="$(install_snapshot_file_identity \
    "${SETTINGS_PATCH_SNAPSHOT}")" \
    || return 1
  parent_id="$(install_directory_identity "${parent}")" || return 1
  mode="$(install_file_mode "${SETTINGS_PATCH_SNAPSHOT}")" || return 1
  observed="$(mktemp "${SETTINGS_PATCH_SNAPSHOT}.current.XXXXXX")" \
    || return 1
  if ! install_capture_regular_file_snapshot "${SETTINGS_PATCH_SNAPSHOT}" \
      "${observed}" "${SETTINGS_PATCH_MAX_BYTES}"; then
    rm -f -- "${observed}" 2>/dev/null || true
    return 1
  fi
  digest="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${observed}")" || {
      rm -f -- "${observed}" 2>/dev/null || true
      return 1
    }
  if [[ "${target_id}" != "${SETTINGS_PATCH_SNAPSHOT_TARGET_ID}" \
      || "${parent_id}" != "${SETTINGS_PATCH_SNAPSHOT_PARENT_ID}" \
      || "${digest}" != "${SETTINGS_PATCH_SNAPSHOT_HASH}" \
      || "${mode}" != "${SETTINGS_PATCH_SNAPSHOT_MODE}" ]] \
      || ! install_regular_file_snapshot_is_current \
        "${SETTINGS_PATCH_SNAPSHOT}" "${observed}" \
        "${SETTINGS_PATCH_MAX_BYTES}"; then
    rm -f -- "${observed}" 2>/dev/null || true
    return 1
  fi
  rm -f -- "${observed}" 2>/dev/null
}

preflight_source_settings_patch() {
  local command="" relative="" failures=0

  if [[ ! -f "${SETTINGS_PATCH}" || -L "${SETTINGS_PATCH}" ]]; then
    printf '  [error] Missing or non-regular settings patch: %s\n' \
      "${SETTINGS_PATCH}" >&2
    return 1
  fi
  if ! capture_source_settings_patch_seal; then
    printf '  [error] Could not seal source settings patch before validation.\n' >&2
    return 1
  fi
  if ! capture_settings_patch_snapshot; then
    printf '  [error] Could not take a verified private settings patch snapshot.\n' >&2
    return 1
  fi
  install_test_barrier \
    "${OMC_TEST_INSTALL_PATCH_SNAPSHOT_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_PATCH_SNAPSHOT_RELEASE_FILE:-}" \
    "${SETTINGS_PATCH_SNAPSHOT}" || return 1

  # jq may normalize a literal NUL next to a JSON scalar.  The private
  # snapshot is installer authority, so reject the raw byte stream before
  # decoding any hook command or setting value from it.
  if ! LC_ALL=C tr -d '\000' <"${SETTINGS_PATCH_SNAPSHOT}" \
      | cmp -s - "${SETTINGS_PATCH_SNAPSHOT}" 2>/dev/null; then
    printf '  [error] Malformed settings patch: %s\n' "${SETTINGS_PATCH}" >&2
    printf '  [error] Source settings preflight failed; installed files were not changed.\n' >&2
    return 1
  fi

  if ! jq -e '
      def decoded_strings_are_nul_free:
        if type == "string" then index("\u0000") == null
        elif type == "array" then all(.[]; decoded_strings_are_nul_free)
        elif type == "object" then
          all(to_entries[];
            (.key | index("\u0000") == null)
            and (.value | decoded_strings_are_nul_free))
        else true
        end;
      type == "object"
      and decoded_strings_are_nul_free
      and (.statusLine | type == "object")
      and ((.statusLine | keys | sort) == ["command","padding","type"])
      and (.statusLine.type == "command")
      and (.statusLine.command
           | type == "string"
             and length > 0
             and index("\u0000") == null
             and index("\r") == null
             and index("\n") == null)
      and (.statusLine.padding == 0)
      and (.outputStyle | type == "string" and length > 0)
      and (.effortLevel | type == "string" and length > 0)
      and (.spinnerTipsEnabled | type == "boolean")
      and (.spinnerVerbs | type == "object")
      and (.spinnerVerbs.mode | type == "string")
      and (.spinnerVerbs.verbs | type == "array"
           and all(.[]; type == "string" and length > 0))
      and (.hooks | type == "object" and length > 0)
      and all(.hooks | to_entries[];
        (.key | type == "string" and length > 0)
        and (.value | type == "array" and length > 0)
        and all(.value[];
          type == "object"
          and ((has("matcher") | not)
               or (.matcher | type == "string"))
          and (.hooks | type == "array" and length > 0)
          and all(.hooks[];
            type == "object"
            and ((keys | sort) == ["command","type"])
            and .type == "command"
            and (.command
                 | type == "string"
                   and length > 0
                   and index("\u0000") == null
                   and index("\r") == null
                   and index("\n") == null))))
    ' "${SETTINGS_PATCH_SNAPSHOT}" >/dev/null 2>&1; then
    printf '  [error] Malformed settings patch: %s\n' "${SETTINGS_PATCH}" >&2
    printf '  [error] Source settings preflight failed; installed files were not changed.\n' >&2
    return 1
  fi

  # shellcheck disable=SC2088 # Compare the shipped JSON's literal tilde path.
  if [[ "$(jq -r '.statusLine.command' "${SETTINGS_PATCH_SNAPSHOT}")" \
        != '~/.claude/statusline.py' \
      || ! -f "${BUNDLE_CLAUDE}/statusline.py" \
      || -L "${BUNDLE_CLAUDE}/statusline.py" \
      || ! -x "${BUNDLE_CLAUDE}/statusline.py" ]]; then
    printf '  [error] Settings patch statusLine authority does not resolve to the bundled executable.\n' >&2
    printf '  [error] Source settings preflight failed; installed files were not changed.\n' >&2
    return 1
  fi

  while IFS= read -r command; do
    [[ -n "${command}" ]] || continue
    relative="$(printf '%s\n' "${command}" | sed -nE \
      's#^(bash )?[$]HOME/[.]claude/((quality-pack|skills/autowork)/scripts/[A-Za-z0-9_-]+[.](sh|py))([[:space:]][A-Za-z0-9_-]+)*$#\2#p')"
    if [[ -z "${relative}" ]]; then
      printf '  [error] Unsupported bundled hook command in settings patch: %s\n' \
        "${command}" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ ! -f "${BUNDLE_CLAUDE}/${relative}" \
        || -L "${BUNDLE_CLAUDE}/${relative}" ]]; then
      printf '  [error] Settings patch references a missing or non-regular bundled hook: %s\n' \
        "${BUNDLE_CLAUDE}/${relative}" >&2
      failures=$((failures + 1))
    elif [[ "${command}" != "bash "* \
        && ! -x "${BUNDLE_CLAUDE}/${relative}" ]]; then
      printf '  [error] Direct bundled hook command is not executable: %s\n' \
        "${BUNDLE_CLAUDE}/${relative}" >&2
      failures=$((failures + 1))
    fi
  done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' \
    "${SETTINGS_PATCH_SNAPSHOT}")

  if [[ "${failures}" -ne 0 ]]; then
    printf '  [error] Source settings preflight failed; installed files were not changed.\n' >&2
    return 1
  fi
  install_test_barrier \
    "${OMC_TEST_INSTALL_PATCH_VALIDATED_READY_FILE:-}" \
    "${OMC_TEST_INSTALL_PATCH_VALIDATED_RELEASE_FILE:-}" \
    "${SETTINGS_PATCH_SNAPSHOT}" || return 1
  if ! settings_patch_seal_is_current; then
    printf '  [error] Source settings patch changed during validation.\n' >&2
    return 1
  fi
  if ! settings_patch_snapshot_is_current; then
    printf '  [error] Private settings patch snapshot changed during validation.\n' >&2
    return 1
  fi
}

preflight_installed_shipped_model_roster() {
  local agent optional agent_file name_count name_value model_count model_value
  local ios_present=0 expected_ios=4 failures=0 is_optional
  [[ "${EXCLUDE_IOS}" == "true" ]] && expected_ios=0
  for optional in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
    [[ -f "${CLAUDE_HOME}/agents/${optional}.md" ]] \
      && ios_present=$((ios_present + 1))
  done
  if [[ "${ios_present}" -ne "${expected_ios}" ]]; then
    printf '  [error] Installed iOS agent pack does not match this install mode (%d present, expected %d); refusing model rewrites.\n' \
      "${ios_present}" "${expected_ios}" >&2
    failures=$((failures + 1))
  fi

  for agent in ${SHIPPED_INHERIT_AGENTS} ${SHIPPED_FIXED_AGENTS}; do
    is_optional=0
    for optional in ${SHIPPED_OPTIONAL_IOS_AGENTS}; do
      [[ "${agent}" == "${optional}" ]] && is_optional=1
    done
    [[ "${EXCLUDE_IOS}" == "true" && "${is_optional}" -eq 1 ]] && continue
    agent_file="${CLAUDE_HOME}/agents/${agent}.md"
    if [[ ! -f "${agent_file}" ]]; then
      printf '  [error] Missing shipped agent definition: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! parse_agent_frontmatter "${agent_file}"; then
      printf '  [error] Malformed installed shipped agent frontmatter fences: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
      continue
    fi
    name_count="${AGENT_FRONTMATTER_NAME_COUNT}"
    name_value="${AGENT_FRONTMATTER_NAME_VALUE}"
    model_count="${AGENT_FRONTMATTER_MODEL_COUNT}"
    model_value="${AGENT_FRONTMATTER_MODEL_VALUE}"
    if [[ "${name_count}" != "1" || "${name_value}" != "${agent}" ]]; then
      printf '  [error] Malformed installed shipped agent name frontmatter: %s\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
    fi
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf '  [error] Malformed shipped agent model frontmatter: %s (expected exactly one valid model: line).\n' \
        "${agent_file}" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

# Capture which transaction-owned paths existed before the backup/copy. A
# same-second backup-directory collision must not make a stale backup look like
# a path that existed at the start of this invocation, so rollback authority
# comes from this in-memory snapshot rather than backup-file existence alone.
snapshot_prior_model_configuration() {
  if [[ -e "${CLAUDE_HOME}/oh-my-claude.conf" \
      || -L "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
    # Unlike settings.json, the harness config has no physical-target
    # publication contract. Replacing a dotfiles symlink would silently sever
    # it, while following it would require sealing a second ownership path.
    # Fail closed until that explicit contract exists.
    if [[ -L "${CLAUDE_HOME}/oh-my-claude.conf" \
        || ! -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
      printf '  [error] Unsupported symlink/non-regular config path: %s\n' \
        "${CLAUDE_HOME}/oh-my-claude.conf" >&2
      return 1
    fi
  fi
}

# Restore through a fresh path and rename it into place. A direct `rsync -a`
# can quick-check two files as identical when a same-second mutation preserves
# byte length (for example `model_tier=economy` -> `model_tier=quality`) even
# though their contents differ. Copying to a nonexistent path forces a byte
# transfer; the rename then makes the replacement atomic for readers. This
# also preserves a backed-up symlink as a symlink rather than following it.
restore_backup_path_exact() {
  local backup_path="$1" target_path="$2"
  local restore_path="${target_path}.rollback.$$"
  local backup_is_symlink=0 backup_link=""
  if [[ -L "${backup_path}" ]]; then
    backup_is_symlink=1
    backup_link="$(readlink "${backup_path}")" || return 1
  fi
  rm -f "${restore_path}" 2>/dev/null || return 1
  if ! rsync -a "${backup_path}" "${restore_path}"; then
    rm -f "${restore_path}" 2>/dev/null || true
    return 1
  fi
  # BSD/macOS mv follows a destination symlink-to-directory. Unlink any
  # destination symlink first so replacement applies to the path itself, not
  # its referent. A real directory remains an explicit rollback failure.
  if [[ -L "${target_path}" ]] && ! rm -f "${target_path}"; then
    rm -f "${restore_path}" 2>/dev/null || true
    return 1
  fi
  if [[ -d "${target_path}" ]]; then
    rm -f "${restore_path}" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "${restore_path}" "${target_path}"; then
    rm -f "${restore_path}" 2>/dev/null || true
    return 1
  fi
  # Defensive postcondition for a non-cooperating filesystem race between the
  # directory check and rename. Remove only our nested temp file if `mv`
  # followed a newly-created directory; never remove the unexpected directory.
  if [[ -d "${target_path}" && ! -L "${target_path}" ]]; then
    rm -f "${target_path}/${restore_path##*/}" 2>/dev/null || true
    return 1
  fi
  if [[ "${backup_is_symlink}" -eq 1 ]]; then
    [[ -L "${target_path}" \
        && "$(readlink "${target_path}" 2>/dev/null || true)" == "${backup_link}" ]] \
      || return 1
  else
    [[ -f "${target_path}" && ! -L "${target_path}" ]] || return 1
  fi
}

rollback_model_configuration_transaction() {
  local rollback_failures=0
  if ! restore_install_transaction_path \
      "${CLAUDE_HOME}/oh-my-claude.conf" config; then
    rollback_failures=$((rollback_failures + 1))
  fi

  [[ "${rollback_failures}" -eq 0 ]]
}

rollback_installed_bundle_generation() {
  local rel_path="" target_path="" backup_path="" rollback_failures=0
  [[ -f "${BUNDLE_ROLLBACK_PRESENT_FILE}" \
      && ! -L "${BUNDLE_ROLLBACK_PRESENT_FILE}" ]] || return 1
  source_content_manifest_seal_is_current \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_FILE_LIST_ID}" \
    "${SOURCE_BUNDLE_FILE_LIST_PARENT_ID}" \
    "${SOURCE_BUNDLE_FILE_LIST_HASH}" || return 1
  verify_exact_snapshot_tree "${SOURCE_BUNDLE_SNAPSHOT}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" \
    "private bundle rollback snapshot" || return 1

  while IFS= read -r rel_path || [[ -n "${rel_path}" ]]; do
    [[ -n "${rel_path}" ]] || continue
    case "${rel_path}" in
      /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*)
        rollback_failures=$((rollback_failures + 1))
        continue ;;
    esac
    # A staged copy that lost its destination CAS never owned that leaf. Do
    # not let transaction rollback erase or overwrite the concurrent winner.
    bundle_path_was_published "${rel_path}" || continue
    target_path="${CLAUDE_HOME}/${rel_path}"
    backup_path="${BACKUP_DIR}/${rel_path}"
    # Publication ownership is armed before mutation. If the exact
    # backup-bound generation is still present, the mutation never landed and
    # this path already satisfies rollback without rewriting it.
    if bundle_initial_ancestor_seal_is_current "${rel_path}" \
        && bundle_initial_seal_is_current "${rel_path}" "${target_path}"; then
      continue
    fi
    if ! bundle_published_path_seal_is_current \
        "${rel_path}" "${target_path}"; then
      printf '  [error] %s changed after bundle publication; preserving the concurrent version during rollback.\n' \
        "${target_path}" >&2
      rollback_failures=$((rollback_failures + 1))
      continue
    fi
    # The pre-install ancestor generation is part of rollback authority. A
    # fresh seal here would bless a directory tree replaced after publication
    # and could restore old bytes into a concurrent owner's new tree.
    if ! bundle_initial_ancestor_seal_is_current "${rel_path}" \
        || [[ -L "${target_path}" \
          || ( -e "${target_path}" && ! -f "${target_path}" ) ]]; then
      printf '  [error] Refusing bundle rollback through changed destination ancestry: %s\n' \
        "${target_path}" >&2
      rollback_failures=$((rollback_failures + 1))
      continue
    fi
    if grep -Fqx -- "${rel_path}" "${BUNDLE_ROLLBACK_PRESENT_FILE}"; then
      if [[ ! -f "${backup_path}" && ! -L "${backup_path}" ]]; then
        printf '  [error] Missing pre-install bundle backup: %s\n' \
          "${backup_path}" >&2
        rollback_failures=$((rollback_failures + 1))
      else
        bundle_initial_ancestor_seal_is_current "${rel_path}" \
          && restore_backup_path_exact "${backup_path}" "${target_path}" \
          || rollback_failures=$((rollback_failures + 1))
      fi
    else
      if [[ -d "${target_path}" && ! -L "${target_path}" ]]; then
        rollback_failures=$((rollback_failures + 1))
      else
        bundle_initial_ancestor_seal_is_current "${rel_path}" \
          && rm -f -- "${target_path}" 2>/dev/null \
          || rollback_failures=$((rollback_failures + 1))
      fi
    fi
  done < "${SOURCE_BUNDLE_FILE_LIST}"
  [[ "${rollback_failures}" -eq 0 ]]
}

rollback_published_settings() {
  [[ "${SETTINGS_STAGE_COMMITTED:-0}" -eq 1 ]] || return 0
  if settings_install_seal_is_current; then
    return 0
  fi
  if ! published_settings_install_is_current; then
    printf '  [error] settings.json changed after installer publication; preserving the concurrent version instead of overwriting it during rollback.\n' >&2
    return 1
  fi
  if [[ "${SETTINGS_SEAL_LEXICAL_KIND}" == "absent" ]]; then
    rm -f -- "${SETTINGS_SEAL_PHYSICAL_PATH}"
  else
    [[ -f "${BACKUP_DIR}/settings.json" \
        && ! -L "${BACKUP_DIR}/settings.json" ]] || return 1
    restore_backup_path_exact "${BACKUP_DIR}/settings.json" \
      "${SETTINGS_SEAL_PHYSICAL_PATH}"
  fi
}

rollback_install_transaction() {
  local rollback_failures=0
  rollback_installed_bundle_generation \
    || rollback_failures=$((rollback_failures + 1))
  rollback_published_settings \
    || rollback_failures=$((rollback_failures + 1))
  rollback_model_configuration_transaction \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt" manifest \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt" hashes \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/quality-pack/state/last-install-report.json" report \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/.install-stamp" stamp \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
    legacy-output-style || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${TARGET_HOME}/.local/bin/omc" omc-cli \
    || rollback_failures=$((rollback_failures + 1))
  restore_install_transaction_path \
    "${CLAUDE_HOME}/omc-user/overrides.md" user-overrides \
    || rollback_failures=$((rollback_failures + 1))
  if [[ -f "${INSTALL_TRANSACTION_DIR}/ghostty-theme.state" ]]; then
    restore_install_transaction_path \
      "${GHOSTTY_HOME}/themes/Claude OpenCode" ghostty-theme \
      || rollback_failures=$((rollback_failures + 1))
  fi
  if [[ -f "${INSTALL_TRANSACTION_DIR}/ghostty-config.state" ]]; then
    restore_install_transaction_path \
      "${GHOSTTY_HOME}/config" ghostty-config \
      || rollback_failures=$((rollback_failures + 1))
  fi

  if [[ -n "${GIT_HOOK_TRANSACTION_PATH:-}" ]]; then
    restore_install_transaction_path \
      "${GIT_HOOK_TRANSACTION_PATH}" git-hook \
      || rollback_failures=$((rollback_failures + 1))
  fi
  [[ "${rollback_failures}" -eq 0 ]]
}

set_installed_shipped_agent_model() {
  local agent="$1" model="$2" agent_file tmp relative=""
  local tmp_id="" tmp_hash="" tmp_mode=""
  agent_file="${CLAUDE_HOME}/agents/${agent}.md"
  relative="agents/${agent}.md"
  [[ -f "${agent_file}" ]] || return 0
  [[ "$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)" == "1" ]] \
    || return 1
  grep -qE "^model: ${model}$" "${agent_file}" && return 0
  bundle_published_path_seal_is_current "${relative}" "${agent_file}" \
    || return 1
  tmp="$(mktemp "${agent_file%/*}/.${agent_file##*/}.model.XXXXXX")" \
    || return 1
  if ! sed "s/^model: .*$/model: ${model}/" "${agent_file}" > "${tmp}" \
      || ! chmod "$(install_file_mode "${agent_file}")" "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  tmp_id="$(install_node_identity "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }
  tmp_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" "${tmp}")" \
    || {
      rm -f -- "${tmp}" 2>/dev/null || true
      return 1
    }
  tmp_mode="$(install_file_mode "${tmp}")" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  }
  if ! bundle_published_path_seal_is_current "${relative}" "${agent_file}" \
      || [[ ! -f "${tmp}" || -L "${tmp}" \
        || "$(install_node_identity "${tmp}" 2>/dev/null || true)" \
          != "${tmp_id}" \
        || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
            "${tmp}" 2>/dev/null || true)" != "${tmp_hash}" \
        || "$(install_file_mode "${tmp}" 2>/dev/null || true)" \
          != "${tmp_mode}" ]] \
      || ! arm_published_bundle_path "${CLAUDE_HOME}" "${relative}" \
        regular "${tmp_id}" "${tmp_hash}" "${tmp_mode}" \
      || ! mv -f -- "${tmp}" "${agent_file}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
  fi
  [[ "$(grep -cE "^model: ${model}$" "${agent_file}" 2>/dev/null || true)" == "1" ]] \
    && record_published_bundle_path "${CLAUDE_HOME}" "${relative}" \
      regular "${tmp_id}" "${tmp_hash}" "${tmp_mode}"
}

read_last_valid_model_tier() {
  local conf_path="${1:-}" output_var="${2:-}" seen_var="${3:-}"
  local line="" value="" result="" rows_seen=0
  [[ "${output_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
      && "${seen_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if [[ -f "${conf_path}" && ! -L "${conf_path}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "model_tier="* ]] || continue
      rows_seen=1
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      case "${value}" in
        quality|balanced|economy) result="${value}" ;;
      esac
    done < "${conf_path}"
  fi
  printf -v "${output_var}" '%s' "${result}"
  printf -v "${seen_var}" '%s' "${rows_seen}"
}

apply_model_tier() {
  local conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  local tier="${MODEL_TIER}"
  local saved_value="" saved_row_seen=0

  # If no flag was passed, use the last valid saved row. A malformed later
  # hand edit is not authority to erase an earlier valid quality posture.
  if [[ -z "${tier}" && -f "${conf_path}" ]]; then
    read_last_valid_model_tier "${conf_path}" saved_value saved_row_seen \
      || return 1
    tier="${saved_value}"
  fi

  # If still empty, the user never opted in — use bundle defaults silently.
  # When malformed saved rows exist but no valid row does, normalize them to
  # Balanced through the normal single-key writer below.
  if [[ -z "${tier}" ]]; then
    [[ "${saved_row_seen}" -eq 0 ]] && return
    printf '  [info] Invalid saved model tier; using balanced and repairing oh-my-claude.conf.\n' >&2
    tier="balanced"
  fi

  # The CLI path is validated before installation starts, but a hand-edited
  # or older saved config can still contain an unknown value. Never let an
  # unknown value fall through to the economy rewrite below: that would turn
  # a typo into a silent quality demotion. Repair the saved value to the safe
  # balanced default so runtime routing, future installs, and status surfaces
  # all agree on the effective tier.
  case "${tier}" in
    quality|balanced|economy)
      ;;
    *)
      printf '  [info] Invalid saved model tier "%s"; using balanced and repairing oh-my-claude.conf.\n' "${tier}" >&2
      tier="balanced"
      ;;
  esac

  # Persist the tier for future installs.
  set_conf "model_tier" "${tier}"

  # Reconstruct every shipped filename from its declaration class instead of
  # performing a one-way regex rewrite. This clears stale pins and old
  # flattened Economy installs on every reinstall while never touching a
  # custom/plugin definition. Economy and Balanced intentionally share the
  # same installed composition; their cost/quality difference is live routing.
  local inherit_model="inherit" fixed_model="sonnet" agent before after
  if [[ "${tier}" == "quality" ]]; then
    fixed_model="opus"
  fi

  local changed=0
  for agent in ${SHIPPED_INHERIT_AGENTS}; do
    before="$(grep -E '^model: ' "${CLAUDE_HOME}/agents/${agent}.md" 2>/dev/null | head -1 | sed 's/^model: //' || true)"
    set_installed_shipped_agent_model "${agent}" "${inherit_model}"
    after="$(grep -E '^model: ' "${CLAUDE_HOME}/agents/${agent}.md" 2>/dev/null | head -1 | sed 's/^model: //' || true)"
    [[ "${after}" != "${before}" ]] && changed=$((changed + 1))
  done
  for agent in ${SHIPPED_FIXED_AGENTS}; do
    before="$(grep -E '^model: ' "${CLAUDE_HOME}/agents/${agent}.md" 2>/dev/null | head -1 | sed 's/^model: //' || true)"
    set_installed_shipped_agent_model "${agent}" "${fixed_model}"
    after="$(grep -E '^model: ' "${CLAUDE_HOME}/agents/${agent}.md" 2>/dev/null | head -1 | sed 's/^model: //' || true)"
    [[ "${after}" != "${before}" ]] && changed=$((changed + 1))
  done

  if [[ "${tier}" == "quality" ]]; then
    printf '  Model tier:    quality (execution agents → opus; inherit deliberators unchanged, %d changed)\n' "${changed}"
  elif [[ "${tier}" == "balanced" ]]; then
    printf '  Model tier:    balanced (default — inherit deliberators, sonnet specialists, %d repaired)\n' "${changed}"
  else
    printf '  Model tier:    economy (inherit deliberators, sonnet specialists; adaptive live escalation, %d changed)\n' "${changed}"
  fi
}

# ---------------------------------------------------------------------------
# Apply per-agent model overrides (after the bulk tier rewrite)
# ---------------------------------------------------------------------------
#
# `model_overrides` lets a user pin a specific model on a specific agent,
# overriding whatever the tier assigned. This is the per-agent matrix the
# `--model-tier` flag (all-or-nothing) cannot express, e.g. opus for the
# reviewer/planner, sonnet for the researcher, haiku for the librarian.
#
#   model_overrides=oracle:opus,librarian:haiku,quality-researcher:sonnet
#
# Read from OMC_MODEL_OVERRIDES (env) first, then the conf file. Runs AFTER
# apply_model_tier so a specific override always wins over the bulk tier
# rewrite. A bad pair (unknown model, missing agent file) is skipped with a
# warning, never fatal — one typo must not abort an install. Idempotent:
# every install re-applies from conf after rsync restores bundle defaults.
filter_model_overrides_row() {
  local raw="${1:-}" pair="" agent="" model="" summary=""
  local -a pairs=()
  [[ -n "${raw}" ]] || return 0
  IFS=',' read -ra pairs <<< "${raw}"
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ "${pair}" == *:* ]] || continue
    agent="${pair%:*}"
    model="${pair##*:}"
    [[ "${agent}" =~ ^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$ ]] || continue
    case "${model}" in
      opus|sonnet|haiku) ;;
      inherit)
        [[ "${agent}" != *:* ]] || continue
        if installed_shipped_agent_is_known "${agent}"; then
          installed_agent_has_exact_valid_model "${agent}" || continue
        else
          installed_agent_has_exact_inherit_model "${agent}" || continue
        fi
        ;;
      *) continue ;;
    esac
    summary="${summary}${summary:+,}${agent}:${model}"
  done
  printf '%s' "${summary}"
}

read_last_valid_model_overrides() {
  local conf="${1:-}" line="" value="" normalized="" result=""
  [[ -f "${conf}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == "model_overrides="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "${value}" ]]; then
      result=""
      continue
    fi
    normalized="$(filter_model_overrides_row "${value}")"
    [[ -n "${normalized}" ]] && result="${value}"
  done < "${conf}"
  printf '%s' "${result}"
}

apply_model_overrides() {
  local agents_dir="$1"
  local conf_path="$2"
  local env_raw="${OMC_MODEL_OVERRIDES:-}" raw="${OMC_MODEL_OVERRIDES:-}"

  # Environment precedence is earned by at least one resolver-valid pin. A
  # wholly malformed environment value must not shadow valid saved pins. A
  # valid explicit-model namespaced pin still establishes environment
  # precedence, but remains runtime-only because there is no safe one-file
  # materialization for plugin identities in ~/.claude/agents. Namespaced
  # inherit is not valid authority: omission cannot change a plugin definition.
  if [[ -n "${env_raw}" ]]; then
    if [[ -z "$(filter_model_overrides_row "${env_raw}")" ]]; then
      printf '  model_overrides: OMC_MODEL_OVERRIDES has no valid pins; falling back to saved overrides\n' >&2
      raw=""
    fi
  fi
  if [[ -z "${raw}" && -f "${conf_path}" ]]; then
    raw="$(read_last_valid_model_overrides "${conf_path}")"
  fi
  [[ -z "${raw}" ]] && return 0

  local -a pairs=()
  IFS=',' read -ra pairs <<< "${raw}"
  [[ "${#pairs[@]}" -eq 0 ]] && return 0

  local applied=0 runtime_only=0 definition_backed=0 skipped=0
  local pair agent model agent_file model_count model_value
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ -z "${pair}" ]] && continue
    agent="${pair%:*}"
    model="${pair##*:}"
    if [[ -z "${agent}" || -z "${model}" || "${agent}" == "${pair}" ]]; then
      printf '  model_overrides: skipping %q — expected agent:model\n' "${pair}" >&2
      skipped=$((skipped + 1)); continue
    fi
    case "${model}" in
      opus|sonnet|haiku|inherit) ;;
      *)
        printf '  model_overrides: skipping %s — invalid model %q (use opus|sonnet|haiku|inherit)\n' "${agent}" "${model}" >&2
        skipped=$((skipped + 1)); continue ;;
    esac
    if [[ ! "${agent}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      if [[ "${agent}" =~ ^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$ ]]; then
        if [[ "${model}" == "inherit" ]]; then
          printf '  model_overrides: skipping %s — namespaced inherit is unenforceable because Agent model omission uses the plugin definition\n' "${agent}" >&2
          skipped=$((skipped + 1))
        else
          printf '  model_overrides: runtime-only %s — namespaced pin is enforced at dispatch; plugin definitions are never rewritten\n' "${agent}" >&2
          runtime_only=$((runtime_only + 1))
        fi
      else
        printf '  model_overrides: skipping %q — invalid bare agent id\n' "${agent}" >&2
        skipped=$((skipped + 1))
      fi
      continue
    fi
    if ! installed_shipped_agent_is_known "${agent}"; then
      if [[ "${model}" == "inherit" ]]; then
        if installed_agent_has_exact_inherit_model "${agent}"; then
          printf '  model_overrides: definition-backed %s — custom file already declares inherit and remains untouched\n' \
            "${agent}" >&2
          definition_backed=$((definition_backed + 1))
        else
          printf '  model_overrides: skipping %s — custom inherit is definition-backed only; the custom file must already contain exactly one model: inherit line\n' \
            "${agent}" >&2
          skipped=$((skipped + 1))
        fi
      else
        printf '  model_overrides: runtime-only %s — custom bare pin is enforced at dispatch; custom definitions are never rewritten\n' \
          "${agent}" >&2
        runtime_only=$((runtime_only + 1))
      fi
      continue
    fi
    agent_file="${agents_dir}/${agent}.md"
    if [[ ! -f "${agent_file}" ]]; then
      printf '  model_overrides: skipping %s — no agent file at %s\n' "${agent}" "${agent_file}" >&2
      skipped=$((skipped + 1)); continue
    fi
    model_count="$(grep -cE '^model: ' "${agent_file}" 2>/dev/null || true)"
    model_value="$(sed -n 's/^model: //p' "${agent_file}" | head -1)"
    if [[ "${model_count}" != "1" ]] \
        || [[ ! "${model_value}" =~ ^(inherit|opus|sonnet|haiku)$ ]]; then
      printf '  model_overrides: skipping %s — agent definition must contain exactly one valid model: line\n' \
        "${agent}" >&2
      skipped=$((skipped + 1)); continue
    fi
    # Reuse the checked tier writer so a short/failed write cannot be counted
    # as a materialized override and then escape to later config stages.
    set_installed_shipped_agent_model "${agent}" "${model}"
    applied=$((applied + 1))
  done

  if [[ "${applied}" -gt 0 || "${runtime_only}" -gt 0 \
      || "${definition_backed}" -gt 0 || "${skipped}" -gt 0 ]]; then
    printf '  Model overrides: %d materialized, %d runtime-only, %d definition-backed, %d skipped\n' \
      "${applied}" "${runtime_only}" "${definition_backed}" "${skipped}"
  fi
}

# ---------------------------------------------------------------------------
# Install Ghostty theme and config snippet
# ---------------------------------------------------------------------------

should_install_ghostty() {
  case "${INSTALL_GHOSTTY_FLAG}" in
    yes) return 0 ;;
    no)  return 1 ;;
    *)
      # Auto-detect (default): install only when the user already has
      # a ~/.config/ghostty/ directory. Closes the silent side-effect
      # on hosts that don't run Ghostty terminal — pre-v1.36.0 every
      # install seeded the dir even on iTerm/Terminal/Alacritty hosts.
      #
      # Limitation: this checks for the dir, not the binary. A user
      # who removed Ghostty.app but left ~/.config/ghostty/ behind
      # will still get the seed. The benign cost is an orphan config
      # update; the alternative (binary probe) hits portability traps
      # (path differences across Linux distros, App Store sandbox vs
      # cask installs on macOS, etc.). Power users who want strict
      # control pass --no-ghostty / --with-ghostty explicitly.
      [[ -d "${GHOSTTY_HOME}" ]]
      ;;
  esac
}

install_ghostty() {
  local snippet_path="${SOURCE_GHOSTTY_SNAPSHOT}/config.snippet.ini"
  local theme_source="${SOURCE_GHOSTTY_SNAPSHOT}/themes/Claude OpenCode"
  local theme_target_dir="${GHOSTTY_HOME}/themes"
  local config_target="${GHOSTTY_HOME}/config"
  local line="" theme_target="" config_stage="" config_stage_id=""
  local config_initial_hash="" config_mode="600"

  if [[ ! -d "${SOURCE_GHOSTTY_SNAPSHOT}" ]]; then
    return
  fi

  if [[ -f "${theme_source}" ]]; then
    theme_target="${theme_target_dir}/Claude OpenCode"
    ensure_install_transaction_parent \
      "${theme_target}" ghostty-theme || return 1
    [[ ! -L "${theme_target}" ]] || return 1
    if ! publish_install_regular_source "${theme_source}" "${theme_target}" \
          ghostty-theme 644 1 \
        || ! source_distribution_seal_is_current \
        || ! verify_copied_file_hash \
          "${theme_target}" \
          "${SOURCE_GHOSTTY_THEME_HASH}" \
          "config/ghostty/themes/Claude OpenCode"; then
      return 1
    fi
  fi

  if [[ -f "${snippet_path}" ]]; then
    [[ ! -L "${config_target}" \
        && ( ! -e "${config_target}" || -f "${config_target}" ) ]] \
      || return 1
    ensure_install_transaction_parent \
      "${config_target}" ghostty-config || return 1
    install_transaction_path_phase_is_current \
      "${config_target}" ghostty-config initial 1 || return 1
    config_stage="$(mktemp \
      "${GHOSTTY_HOME}/.config.oh-my-claude.XXXXXX")" || return 1
    config_stage_id="$(install_node_identity "${config_stage}")" || return 1
    if [[ -f "${config_target}" ]]; then
      config_initial_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${config_target}")" || return 1
      config_mode="$(install_file_mode "${config_target}")" || return 1
      if ! cp -p -- "${config_target}" "${config_stage}" \
          || [[ "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
              "${config_stage}" 2>/dev/null || true)" \
            != "${config_initial_hash}" ]]; then
        rm -f -- "${config_stage}" 2>/dev/null || true
        return 1
      fi
      config_stage_id="$(install_node_identity "${config_stage}")" \
        || return 1
    else
      chmod "${config_mode}" "${config_stage}" || return 1
    fi
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      if ! append_if_missing "${config_stage}" "${line}"; then
        [[ "$(install_node_identity "${config_stage}" \
            2>/dev/null || true)" == "${config_stage_id}" ]] \
          && rm -f -- "${config_stage}" 2>/dev/null || true
        return 1
      fi
    done < "${snippet_path}"
    if ! verify_copied_file_hash "${snippet_path}" \
          "${SOURCE_GHOSTTY_SNIPPET_HASH}" \
          "private config/ghostty/config.snippet.ini" \
        || ! source_distribution_seal_is_current \
        || ! publish_install_regular_stage "${config_stage}" \
          "${config_target}" ghostty-config 1; then
      [[ "$(install_node_identity "${config_stage}" \
          2>/dev/null || true)" == "${config_stage_id}" ]] \
        && rm -f -- "${config_stage}" 2>/dev/null || true
      return 1
    fi
  fi
}

# ===========================================================================
# Main
# ===========================================================================

need_cmd rsync

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for runtime hook scripts but was not found.\n' >&2
  printf 'Install it with your package manager (e.g. brew install jq, apt install jq).\n' >&2
  exit 1
fi

TRUSTED_SHA256_TOOL=""
TRUSTED_SHA256_TOOL="$(\resolve_trusted_sha256_executable 2>/dev/null)" \
  || TRUSTED_SHA256_TOOL=""
if [[ -z "${TRUSTED_SHA256_TOOL}" ]]; then
  printf 'A SHA-256 tool is required for Definition, verification receipt, and Quality Constitution authority identities.\n' >&2
  printf 'Install shasum or sha256sum with your package manager, then re-run the installer.\n' >&2
  exit 1
fi

# The complete closeout stack needs both MessageDisplay and Stop
# additionalContext. MessageDisplay arrived in 2.1.152; the latter arrived in
# 2.1.163, so fail before filesystem mutation on older installed clients.
if command -v claude >/dev/null 2>&1; then
  _claude_version_rc=0
  claude_code_version_at_least 163 || _claude_version_rc=$?
  if [[ "${_claude_version_rc}" -eq 1 ]]; then
    printf 'Claude Code 2.1.163 or newer is required (complete closeout hook support).\n' >&2
    printf 'Upgrade Claude Code, then re-run: bash "%s/install.sh"\n' "${SCRIPT_DIR}" >&2
    exit 1
  elif [[ "${_claude_version_rc}" -eq 2 ]]; then
    printf 'Could not parse `claude --version`; continuing, but Claude Code 2.1.163+ is required.\n' >&2
  fi
fi

if [[ ! -d "${BUNDLE_CLAUDE}" ]]; then
  printf 'Missing bundle directory: %s\n' "${BUNDLE_CLAUDE}" >&2
  exit 1
fi

# This proof intentionally runs before acquire_install_lock: a malformed or
# incomplete release must not create ~/.claude, a backup, or a lock, and must
# never be able to hide a missing source file behind a stale installed orphan.
trap 'cleanup_source_preflight_tmpfiles' EXIT
# Source preflight allocates private lists/snapshots before the full install
# transaction exists. Its narrow EXIT cleanup is replaced by the full handler
# after lock setup below.
if ! preflight_source_distribution_trees; then
  exit 1
fi
if ! preflight_source_shipped_model_roster; then
  exit 1
fi
if ! preflight_source_settings_patch; then
  exit 1
fi
if ! preflight_existing_settings_input; then
  exit 1
fi

# Up-front notice about --bypass-permissions. Shown BEFORE any filesystem
# changes so users who wanted maximum-autonomy mode can Ctrl-C and re-run
# with the flag rather than discover the option only in the post-install
# tip. The old placement (banner after install completed) meant power users
# ran the installer twice on their first day — once to "see what happens,"
# and once with the flag. Surface the choice before commitment instead.
#
# Only printed on interactive terminals (TTY stdin) — curl-pipe-bash and
# CI runs have no interactive cancel and would see a misleading "press
# Ctrl-C now" message from a stream they can't intercept anyway.
# CI detection: `-z "${CI:-}"` catches `CI=true` (GitHub Actions, GitLab,
# CircleCI, Travis, Buildkite), `CI=1` (custom runners), and anything else
# truthy. The prior `!= "1"` check was dead — no mainstream CI sets CI=1.
if [[ "${BYPASS_PERMISSIONS}" != "true" ]] && [[ -z "${CI:-}" ]] && [[ -t 0 ]]; then
  printf '\n'
  printf "  Installing with Claude Code's per-tool permission prompts on by default.\n"
  printf "  Once you've run /ulw-demo and trust the harness, --bypass-permissions removes\n"
  printf "  the prompts. Quality gates apply either way.\n"
  printf '\n'
fi

INSTALL_LOCK_DIR="${CLAUDE_HOME}/.install.lock"
INSTALL_LOCK_TOKEN=""
INSTALL_LOCK_HELD=0
INSTALL_LOCK_DIR_ID=""
INSTALL_LOCK_RELEASE_MARKER="${INSTALL_LOCK_DIR}/owner-released"
acquire_install_lock() {
  mkdir -p "${CLAUDE_HOME}"
  local attempts=0 lock_pid=""
  while ! (umask 077; mkdir "${INSTALL_LOCK_DIR}") 2>/dev/null; do
    if install_lock_reap_stranded_released_generation; then
      continue
    fi
    attempts=$((attempts + 1))
    # Never reclaim a pidless/dead record automatically: it may be an owner
    # paused immediately after atomic mkdir, and PID reuse makes kill(0)
    # insufficient ownership proof. Manual stale-lock removal is fail-closed.
    lock_pid="$(install_read_canonical_metadata_line \
      "${INSTALL_LOCK_DIR}/pid" 32 2>/dev/null || true)"
    if [[ "${attempts}" -ge 120 ]]; then
      printf 'Another oh-my-claude install/uninstall appears to be running (pid=%s, lock=%s).\n' \
        "${lock_pid:-unknown}" "${INSTALL_LOCK_DIR}" >&2
      printf 'If the owner is gone, inspect and remove this exact lock manually before retrying.\n' >&2
      printf 'First verify every participant.* PID is also gone; a child may still be using the borrowed lock.\n' >&2
      exit 1
    fi
    sleep 0.25 2>/dev/null || sleep 1
  done
  if ! chmod 700 "${INSTALL_LOCK_DIR}" 2>/dev/null; then
    rmdir "${INSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  INSTALL_LOCK_TOKEN="$$.${RANDOM}.$(date +%s)"
  if ! (umask 077; set -o noclobber; \
      printf '%s\n' "$$" > "${INSTALL_LOCK_DIR}/pid" \
      && printf '%s\n' "${INSTALL_LOCK_TOKEN}" \
        > "${INSTALL_LOCK_DIR}/token") 2>/dev/null; then
    rm -f -- "${INSTALL_LOCK_DIR}/pid" "${INSTALL_LOCK_DIR}/token" \
      2>/dev/null || true
    rmdir "${INSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  fi
  INSTALL_LOCK_DIR_ID="$(install_node_identity "${INSTALL_LOCK_DIR}")" || {
    rm -f -- "${INSTALL_LOCK_DIR}/pid" "${INSTALL_LOCK_DIR}/token" \
      2>/dev/null || true
    rmdir "${INSTALL_LOCK_DIR}" 2>/dev/null || true
    return 1
  }
  INSTALL_LOCK_HELD=1
}

install_lock_generation_matches() {
  local lock_id="${1:-}" owner_pid="${2:-}" owner_token="${3:-}"
  [[ "${lock_id}" =~ ^[0-9]+:[0-9]+$ \
      && "${owner_pid}" =~ ^[1-9][0-9]{0,19}$ \
      && -n "${owner_token}" && "${owner_token}" != *[[:cntrl:]]* \
      && -d "${INSTALL_LOCK_DIR}" && ! -L "${INSTALL_LOCK_DIR}" \
      && "$(install_node_identity "${INSTALL_LOCK_DIR}" \
        2>/dev/null || true)" == "${lock_id}" \
      && -f "${INSTALL_LOCK_DIR}/pid" \
      && ! -L "${INSTALL_LOCK_DIR}/pid" \
      && -f "${INSTALL_LOCK_DIR}/token" \
      && ! -L "${INSTALL_LOCK_DIR}/token" \
      && "$(install_read_canonical_metadata_line \
        "${INSTALL_LOCK_DIR}/pid" 32 2>/dev/null || true)" == "${owner_pid}" \
      && "$(install_read_canonical_metadata_line \
        "${INSTALL_LOCK_DIR}/token" 512 2>/dev/null || true)" \
        == "${owner_token}" ]]
}

install_lock_generation_is_current() {
  [[ "${INSTALL_LOCK_HELD:-0}" -eq 1 ]] \
    && install_lock_generation_matches "${INSTALL_LOCK_DIR_ID:-}" "$$" \
      "${INSTALL_LOCK_TOKEN}"
}

install_lock_release_marker_matches() {
  local marker_path="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" line=""
  [[ -n "${marker_path}" && -n "${lock_id}" && -n "${owner_pid}" \
      && -n "${owner_token}" && -f "${marker_path}" \
      && ! -L "${marker_path}" \
      && "$(install_file_mode "${marker_path}" 2>/dev/null || true)" \
        == "600" ]] || return 1
  line="$(install_read_canonical_metadata_line "${marker_path}" 1024)" \
    || return 1
  [[ "${line}" == $'v1\t'"${lock_id}"$'\t'"${owner_pid}"$'\t'"${owner_token}" ]]
}

install_lock_publish_release_marker() {
  install_lock_generation_is_current || return 1
  if [[ -e "${INSTALL_LOCK_RELEASE_MARKER}" \
      || -L "${INSTALL_LOCK_RELEASE_MARKER}" ]]; then
    install_lock_release_marker_matches \
      "${INSTALL_LOCK_RELEASE_MARKER}" "${INSTALL_LOCK_DIR_ID}" \
      "$$" "${INSTALL_LOCK_TOKEN}"
    return
  fi
  if ! (umask 077; set -o noclobber; printf 'v1\t%s\t%s\t%s\n' \
      "${INSTALL_LOCK_DIR_ID}" "$$" "${INSTALL_LOCK_TOKEN}" \
      > "${INSTALL_LOCK_RELEASE_MARKER}") 2>/dev/null; then
    return 1
  fi
  chmod 600 "${INSTALL_LOCK_RELEASE_MARKER}" || return 1
  install_lock_generation_is_current \
    && install_lock_release_marker_matches \
      "${INSTALL_LOCK_RELEASE_MARKER}" "${INSTALL_LOCK_DIR_ID}" \
      "$$" "${INSTALL_LOCK_TOKEN}"
}

install_lock_released_generation_is_exact() (
  local root="${1:-}" lock_id="${2:-}" owner_pid="${3:-}"
  local owner_token="${4:-}" pid_id="${5:-}" token_id="${6:-}"
  local marker_id="${7:-}" entry=""
  local -a entries=()
  [[ -d "${root}" && ! -L "${root}" \
      && "$(install_node_identity "${root}" 2>/dev/null || true)" \
        == "${lock_id}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${root}"/*)
  [[ "${#entries[@]}" -eq 3 ]] || return 1
  for entry in "${entries[@]}"; do
    case "${entry}" in
      "${root}/pid"|"${root}/token"|"${root}/owner-released") ;;
      *) return 1 ;;
    esac
  done
  [[ -f "${root}/pid" && ! -L "${root}/pid" \
      && "$(install_node_identity "${root}/pid" 2>/dev/null || true)" \
        == "${pid_id}" \
      && "$(install_read_canonical_metadata_line \
        "${root}/pid" 32 2>/dev/null || true)" == "${owner_pid}" \
      && -f "${root}/token" && ! -L "${root}/token" \
      && "$(install_node_identity "${root}/token" 2>/dev/null || true)" \
        == "${token_id}" \
      && "$(install_read_canonical_metadata_line \
        "${root}/token" 512 2>/dev/null || true)" == "${owner_token}" \
      && -f "${root}/owner-released" \
      && ! -L "${root}/owner-released" \
      && "$(install_node_identity "${root}/owner-released" \
        2>/dev/null || true)" == "${marker_id}" ]] || return 1
  install_lock_release_marker_matches "${root}/owner-released" \
    "${lock_id}" "${owner_pid}" "${owner_token}"
)

install_lock_retire_released_generation() {
  local lock_id="${1:-${INSTALL_LOCK_DIR_ID}}" owner_pid="${2:-$$}"
  local owner_token="${3:-${INSTALL_LOCK_TOKEN}}"
  local participant="" pid_id="" token_id="" marker_id=""
  local retired_root="" retired_root_id="" retired_lock=""
  [[ -e "${INSTALL_LOCK_RELEASE_MARKER}" \
      || -L "${INSTALL_LOCK_RELEASE_MARKER}" ]] || return 0
  install_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  install_lock_release_marker_matches \
    "${INSTALL_LOCK_RELEASE_MARKER}" "${lock_id}" \
    "${owner_pid}" "${owner_token}" || return 1
  for participant in "${INSTALL_LOCK_DIR}"/participant.*; do
    [[ -e "${participant}" || -L "${participant}" ]] || continue
    return 0
  done
  pid_id="$(install_node_identity "${INSTALL_LOCK_DIR}/pid")" || return 1
  token_id="$(install_node_identity "${INSTALL_LOCK_DIR}/token")" \
    || return 1
  marker_id="$(install_node_identity "${INSTALL_LOCK_RELEASE_MARKER}")" \
    || return 1
  install_lock_released_generation_is_exact "${INSTALL_LOCK_DIR}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || return 1

  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-lock-retired.XXXXXX")" || return 1
  if ! chmod 700 "${retired_root}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  retired_root_id="$(install_node_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_lock="${retired_root}/lock"
  install_lock_released_generation_is_exact "${INSTALL_LOCK_DIR}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || {
      [[ "$(install_node_identity "${retired_root}" \
        2>/dev/null || true)" == "${retired_root_id}" ]] \
        && rmdir "${retired_root}" 2>/dev/null || true
      return 1
    }
  command mv -- "${INSTALL_LOCK_DIR}" "${retired_lock}" || {
    [[ "$(install_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] \
      && rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  # The rename releases the public lock pathname atomically. A valid
  # contender may already have created the next generation there, so cleanup
  # authority is now exclusively the retired inode below.
  [[ "$(install_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  install_lock_released_generation_is_exact "${retired_lock}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" \
    "${pid_id}" "${token_id}" "${marker_id}" || return 1
  [[ "$(install_node_identity "${retired_lock}/pid" \
      2>/dev/null || true)" == "${pid_id}" ]] \
    && rm -f -- "${retired_lock}/pid" || return 1
  [[ "$(install_node_identity "${retired_lock}/token" \
      2>/dev/null || true)" == "${token_id}" ]] \
    && rm -f -- "${retired_lock}/token" || return 1
  [[ "$(install_node_identity "${retired_lock}/owner-released" \
      2>/dev/null || true)" == "${marker_id}" ]] \
    && install_lock_release_marker_matches \
      "${retired_lock}/owner-released" "${lock_id}" \
      "${owner_pid}" "${owner_token}" \
    && rm -f -- "${retired_lock}/owner-released" || return 1
  rmdir "${retired_lock}" || return 1
  [[ "$(install_node_identity "${retired_root}" \
      2>/dev/null || true)" == "${retired_root_id}" ]] || return 1
  rmdir "${retired_root}"
}

install_lock_reap_stranded_released_generation() {
  local lock_id="" owner_pid="" owner_token="" source_id=""
  [[ -d "${INSTALL_LOCK_DIR}" && ! -L "${INSTALL_LOCK_DIR}" \
      && -f "${INSTALL_LOCK_DIR}/pid" \
      && ! -L "${INSTALL_LOCK_DIR}/pid" \
      && -f "${INSTALL_LOCK_DIR}/token" \
      && ! -L "${INSTALL_LOCK_DIR}/token" \
      && -f "${INSTALL_LOCK_RELEASE_MARKER}" \
      && ! -L "${INSTALL_LOCK_RELEASE_MARKER}" ]] || return 1
  lock_id="$(install_node_identity "${INSTALL_LOCK_DIR}")" || return 1
  owner_pid="$(install_read_canonical_metadata_line \
    "${INSTALL_LOCK_DIR}/pid" 32)" || return 1
  owner_token="$(install_read_canonical_metadata_line \
    "${INSTALL_LOCK_DIR}/token" 512)" || return 1
  install_lock_generation_matches "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  install_lock_release_marker_matches "${INSTALL_LOCK_RELEASE_MARKER}" \
    "${lock_id}" "${owner_pid}" "${owner_token}" || return 1
  install_lock_retire_released_generation "${lock_id}" "${owner_pid}" \
    "${owner_token}" || return 1
  source_id="$(install_node_identity "${INSTALL_LOCK_DIR}" \
    2>/dev/null || true)"
  [[ "${source_id}" != "${lock_id}" ]]
}

# ---------------------------------------------------------------------------
# Fixed install-transaction receipt
# ---------------------------------------------------------------------------
#
# The full rollback snapshot lives below the invocation's timestamped backup.
# That location alone is not discoverable after SIGKILL: a later install could
# snapshot the half-published generation as its new baseline. Keep a fixed,
# narrow receipt under CLAUDE_HOME for the whole mutation interval. A prepared
# receipt is deliberately a startup refusal, not guessed rollback authority:
# several legacy rollback seals are process-local and cannot be reconstructed
# honestly after death. Terminal receipts are safe to retire automatically.

install_durable_transaction_exact_entries() (
  local directory="${1:-}" expected="${2:-}" entry=""
  local -a entries=()
  [[ -d "${directory}" && ! -L "${directory}" \
      && -n "${expected}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${directory}"/*)
  [[ "${#entries[@]}" -eq 1 \
      && "${entries[0]}" == "${directory}/${expected}" ]] || return 1
  entry="${entries[0]}"
  [[ -f "${entry}" && ! -L "${entry}" ]]
)

install_durable_transaction_empty_dir() (
  local directory="${1:-}"
  local -a entries=()
  [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${directory}"/*)
  [[ "${#entries[@]}" -eq 0 ]]
)

# A failure before receipt publication owns no recovery authority and has not
# mutated a managed destination. Retire only the exact empty fixed generation
# this invocation created. Any receipt, stage, foreign entry, replacement
# inode, or lost lock leaves the path in place for fail-closed inspection.
cleanup_empty_install_durable_transaction_generation() {
  local expected_id="${1:-${INSTALL_DURABLE_TRANSACTION_DIR_ID:-}}"
  [[ -n "${expected_id}" ]] || return 1
  install_lock_generation_is_current || return 1
  [[ -d "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && "$(install_directory_identity \
        "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
        == "${expected_id}" ]] || return 1
  install_durable_transaction_empty_dir \
    "${INSTALL_DURABLE_TRANSACTION_DIR}" || return 1
  [[ "$(install_directory_identity \
      "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
      == "${expected_id}" ]] || return 1
  rmdir "${INSTALL_DURABLE_TRANSACTION_DIR}" || return 1
  [[ ! -e "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_DIR}" ]] || return 1
  INSTALL_DURABLE_TRANSACTION_DIR_ID=""
}

install_durable_transaction_receipt_is_valid() {
  local expected_phase="${1:-}" directory_id="" receipt_id=""
  local receipt_hash="" receipt_size="" phase="" operation_id=""
  local backup_dir="" backup_id="" snapshot_dir="" snapshot_id=""
  local created_at=""
  install_lock_generation_is_current || return 1
  [[ -d "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && "$(install_file_mode "${INSTALL_DURABLE_TRANSACTION_DIR}" \
          2>/dev/null || true)" == "700" ]] || return 1
  install_durable_transaction_exact_entries \
    "${INSTALL_DURABLE_TRANSACTION_DIR}" receipt.json || return 1
  [[ -f "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
      && "$(install_file_mode "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
          2>/dev/null || true)" == "600" ]] || return 1
  receipt_size="$(wc -c <"${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
    2>/dev/null | tr -d '[:space:]')"
  [[ "${receipt_size}" =~ ^[1-9][0-9]*$ \
      && "${receipt_size}" -le 8192 ]] || return 1
  directory_id="$(install_directory_identity \
    "${INSTALL_DURABLE_TRANSACTION_DIR}")" || return 1
  receipt_id="$(install_node_identity \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  receipt_hash="$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  jq -e '
    type == "object"
    and (keys == ["_v","backup_dir","backup_dir_id","created_at",
      "operation_id","phase","transaction_dir","transaction_dir_id"])
    and ._v == 1
    and (.phase == "prepared" or .phase == "committed"
      or .phase == "rolled-back")
    and (.operation_id | type == "string"
      and test("^[1-9][0-9]*[.][0-9]+[.][1-9][0-9]*$"))
    and (.backup_dir | type == "string" and length >= 1 and length <= 4096
      and (test("[\u0000-\u001f]") | not))
    and (.backup_dir_id | type == "string"
      and test("^[0-9]+:[0-9]+$"))
    and (.transaction_dir | type == "string" and length >= 1
      and length <= 4096 and (test("[\u0000-\u001f]") | not))
    and (.transaction_dir_id | type == "string"
      and test("^[0-9]+:[0-9]+$"))
    and (.created_at | type == "number" and floor == . and . >= 1)
  ' "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" >/dev/null 2>&1 \
    || return 1
  phase="$(jq -r '.phase' "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" \
    || return 1
  operation_id="$(jq -r '.operation_id' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  backup_dir="$(jq -r '.backup_dir' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  backup_id="$(jq -r '.backup_dir_id' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  snapshot_dir="$(jq -r '.transaction_dir' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  snapshot_id="$(jq -r '.transaction_dir_id' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  created_at="$(jq -r '.created_at' \
    "${INSTALL_DURABLE_TRANSACTION_RECEIPT}")" || return 1
  [[ -z "${expected_phase}" || "${phase}" == "${expected_phase}" ]] \
    || return 1
  [[ "${created_at}" =~ ^[1-9][0-9]*$ \
      && "${snapshot_dir}" == "${backup_dir}/.install-transaction" ]] \
    || return 1
  preflight_backup_prune_target "${backup_dir}" "${backup_id}" \
    || return 1
  [[ -d "${snapshot_dir}" && ! -L "${snapshot_dir}" \
      && "$(install_directory_identity "${snapshot_dir}" \
          2>/dev/null || true)" == "${snapshot_id}" ]] || return 1
  install_lock_generation_is_current \
    && [[ "$(install_directory_identity \
          "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
          == "${directory_id}" \
        && "$(install_node_identity \
          "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
          2>/dev/null || true)" == "${receipt_id}" \
        && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
          2>/dev/null || true)" == "${receipt_hash}" ]] \
    && install_durable_transaction_exact_entries \
      "${INSTALL_DURABLE_TRANSACTION_DIR}" receipt.json \
    || return 1

  INSTALL_DURABLE_TRANSACTION_DIR_ID="${directory_id}"
  INSTALL_DURABLE_TRANSACTION_RECEIPT_ID="${receipt_id}"
  INSTALL_DURABLE_TRANSACTION_RECEIPT_HASH="${receipt_hash}"
  INSTALL_DURABLE_TRANSACTION_OPERATION_ID="${operation_id}"
  INSTALL_DURABLE_TRANSACTION_PHASE="${phase}"
  INSTALL_DURABLE_TRANSACTION_BACKUP_ID="${backup_id}"
  INSTALL_DURABLE_TRANSACTION_SNAPSHOT_ID="${snapshot_id}"
  INSTALL_DURABLE_TRANSACTION_CREATED_AT="${created_at}"
  BACKUP_DIR="${backup_dir}"
  INSTALL_TRANSACTION_DIR="${snapshot_dir}"
  return 0
}

write_install_durable_transaction_receipt() {
  local phase="${1:-}" backup_dir="${2:-}" backup_id="${3:-}"
  local snapshot_dir="${4:-}" snapshot_id="${5:-}"
  local operation_id="${6:-}" created_at="${7:-}"
  local stage="" stage_id="" prior_id="" prior_hash=""
  [[ "${phase}" =~ ^(prepared|committed|rolled-back)$ \
      && "${operation_id}" =~ ^[1-9][0-9]*\.[0-9]+\.[1-9][0-9]*$ \
      && "${created_at}" =~ ^[1-9][0-9]*$ ]] || return 1
  install_lock_generation_is_current || return 1
  [[ -d "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && "$(install_directory_identity \
        "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
        == "${INSTALL_DURABLE_TRANSACTION_DIR_ID}" ]] || return 1
  if [[ -e "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
      || -L "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" ]]; then
    install_durable_transaction_receipt_is_valid || return 1
    [[ "${INSTALL_DURABLE_TRANSACTION_OPERATION_ID}" == "${operation_id}" \
        && "${BACKUP_DIR}" == "${backup_dir}" \
        && "${INSTALL_DURABLE_TRANSACTION_BACKUP_ID}" == "${backup_id}" \
        && "${INSTALL_TRANSACTION_DIR}" == "${snapshot_dir}" \
        && "${INSTALL_DURABLE_TRANSACTION_SNAPSHOT_ID}" == "${snapshot_id}" \
        && "${INSTALL_DURABLE_TRANSACTION_CREATED_AT}" == "${created_at}" ]] \
      || return 1
    prior_id="${INSTALL_DURABLE_TRANSACTION_RECEIPT_ID}"
    prior_hash="${INSTALL_DURABLE_TRANSACTION_RECEIPT_HASH}"
  else
    install_durable_transaction_empty_dir \
      "${INSTALL_DURABLE_TRANSACTION_DIR}" || return 1
  fi
  stage="$(mktemp \
    "${INSTALL_DURABLE_TRANSACTION_DIR}/.receipt.json.stage.XXXXXX")" \
    || return 1
  if ! jq -nc --arg phase "${phase}" \
      --arg operation_id "${operation_id}" \
      --arg backup_dir "${backup_dir}" --arg backup_dir_id "${backup_id}" \
      --arg transaction_dir "${snapshot_dir}" \
      --arg transaction_dir_id "${snapshot_id}" \
      --argjson created_at "${created_at}" '
        {_v:1,phase:$phase,operation_id:$operation_id,
         backup_dir:$backup_dir,backup_dir_id:$backup_dir_id,
         transaction_dir:$transaction_dir,
         transaction_dir_id:$transaction_dir_id,created_at:$created_at}
      ' >"${stage}" \
      || ! chmod 600 "${stage}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  stage_id="$(install_node_identity "${stage}")" || {
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  }
  if ! install_lock_generation_is_current \
      || [[ "$(install_directory_identity \
          "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
          != "${INSTALL_DURABLE_TRANSACTION_DIR_ID}" ]] \
      || [[ "$(install_node_identity "${stage}" 2>/dev/null || true)" \
          != "${stage_id}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  if [[ -n "${prior_id}" ]]; then
    [[ -f "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
        && ! -L "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
        && "$(install_node_identity \
          "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
          2>/dev/null || true)" == "${prior_id}" \
        && "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
          "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
          2>/dev/null || true)" == "${prior_hash}" ]] || {
      rm -f -- "${stage}" 2>/dev/null || true
      return 1
    }
  elif [[ -e "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
      || -L "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
  if ! mv -f -- "${stage}" "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" \
      || ! install_durable_transaction_receipt_is_valid "${phase}"; then
    rm -f -- "${stage}" 2>/dev/null || true
    return 1
  fi
}

begin_install_durable_transaction() {
  local backup_id="" snapshot_id="" created_at=""
  install_lock_generation_is_current || return 1
  [[ ! -e "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      && -d "${BACKUP_DIR}" && ! -L "${BACKUP_DIR}" \
      && -d "${INSTALL_TRANSACTION_DIR}" \
      && ! -L "${INSTALL_TRANSACTION_DIR}" ]] || return 1
  backup_id="$(install_directory_identity "${BACKUP_DIR}")" || return 1
  snapshot_id="$(install_directory_identity "${INSTALL_TRANSACTION_DIR}")" \
    || return 1
  preflight_backup_prune_target "${BACKUP_DIR}" "${backup_id}" || return 1
  [[ "${INSTALL_TRANSACTION_DIR}" == "${BACKUP_DIR}/.install-transaction" ]] \
    || return 1
  if ! mkdir -- "${INSTALL_DURABLE_TRANSACTION_DIR}"; then
    return 1
  fi
  INSTALL_DURABLE_TRANSACTION_DIR_ID="$(install_directory_identity \
    "${INSTALL_DURABLE_TRANSACTION_DIR}")" || return 1
  if ! chmod 700 "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      || [[ "$(install_directory_identity \
        "${INSTALL_DURABLE_TRANSACTION_DIR}" 2>/dev/null || true)" \
        != "${INSTALL_DURABLE_TRANSACTION_DIR_ID}" ]]; then
    cleanup_empty_install_durable_transaction_generation \
      "${INSTALL_DURABLE_TRANSACTION_DIR_ID}" 2>/dev/null || true
    return 1
  fi
  created_at="$(date +%s)"
  INSTALL_DURABLE_TRANSACTION_OPERATION_ID="${INSTALL_LOCK_TOKEN}"
  INSTALL_DURABLE_TRANSACTION_BACKUP_ID="${backup_id}"
  INSTALL_DURABLE_TRANSACTION_SNAPSHOT_ID="${snapshot_id}"
  INSTALL_DURABLE_TRANSACTION_CREATED_AT="${created_at}"
  if [[ "${OMC_TEST_INSTALL_FAIL_DURABLE_RECEIPT_PUBLICATION:-0}" \
      == "1" ]] \
      || ! write_install_durable_transaction_receipt prepared \
        "${BACKUP_DIR}" "${backup_id}" "${INSTALL_TRANSACTION_DIR}" \
        "${snapshot_id}" "${INSTALL_LOCK_TOKEN}" "${created_at}"; then
    cleanup_empty_install_durable_transaction_generation \
      "${INSTALL_DURABLE_TRANSACTION_DIR_ID}" 2>/dev/null || true
    return 1
  fi
}

mark_install_durable_transaction_terminal() {
  local phase="${1:-}"
  [[ "${phase}" == "committed" || "${phase}" == "rolled-back" ]] \
    || return 1
  install_durable_transaction_receipt_is_valid prepared || return 1
  [[ "${INSTALL_DURABLE_TRANSACTION_OPERATION_ID}" \
      == "${INSTALL_LOCK_TOKEN}" ]] || return 1
  write_install_durable_transaction_receipt "${phase}" "${BACKUP_DIR}" \
    "${INSTALL_DURABLE_TRANSACTION_BACKUP_ID}" \
    "${INSTALL_TRANSACTION_DIR}" \
    "${INSTALL_DURABLE_TRANSACTION_SNAPSHOT_ID}" \
    "${INSTALL_DURABLE_TRANSACTION_OPERATION_ID}" \
    "${INSTALL_DURABLE_TRANSACTION_CREATED_AT}"
}

retire_terminal_install_durable_transaction() {
  local expected_phase="${1:-}" retired_root="" retired_root_id=""
  local retired_dir="" directory_id="" receipt_id="" receipt_hash=""
  [[ "${expected_phase}" == "committed" \
      || "${expected_phase}" == "rolled-back" ]] || return 1
  install_durable_transaction_receipt_is_valid "${expected_phase}" \
    || return 1
  directory_id="${INSTALL_DURABLE_TRANSACTION_DIR_ID}"
  receipt_id="${INSTALL_DURABLE_TRANSACTION_RECEIPT_ID}"
  receipt_hash="${INSTALL_DURABLE_TRANSACTION_RECEIPT_HASH}"
  retired_root="$(mktemp -d \
    "${CLAUDE_HOME}/.install-transaction-retired.XXXXXX")" || return 1
  chmod 700 "${retired_root}" || { rmdir "${retired_root}"; return 1; }
  retired_root_id="$(install_directory_identity "${retired_root}")" || {
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  }
  retired_dir="${retired_root}/transaction"
  install_durable_transaction_receipt_is_valid "${expected_phase}" \
    || { rmdir "${retired_root}" 2>/dev/null || true; return 1; }
  if ! mv -- "${INSTALL_DURABLE_TRANSACTION_DIR}" "${retired_dir}"; then
    rmdir "${retired_root}" 2>/dev/null || true
    return 1
  fi
  # The fixed pathname is now atomically free. Cleanup authority remains bound
  # to the retired inode; a new installer generation can never be mistaken for
  # this terminal transaction.
  if [[ "$(install_directory_identity "${retired_root}" \
        2>/dev/null || true)" != "${retired_root_id}" \
      || "$(install_directory_identity "${retired_dir}" \
        2>/dev/null || true)" != "${directory_id}" \
      || ! -f "${retired_dir}/receipt.json" \
      || -L "${retired_dir}/receipt.json" \
      || "$(install_node_identity "${retired_dir}/receipt.json" \
        2>/dev/null || true)" != "${receipt_id}" \
      || "$(\trusted_sha256_file "${TRUSTED_SHA256_TOOL}" \
        "${retired_dir}/receipt.json" 2>/dev/null || true)" \
        != "${receipt_hash}" ]] \
      || ! install_durable_transaction_exact_entries \
        "${retired_dir}" receipt.json; then
    printf '  [warn] Terminal install transaction was retired but its private cleanup artifacts remain at %s\n' \
      "${retired_root}" >&2
    return 0
  fi
  rm -f -- "${retired_dir}/receipt.json" \
    && rmdir "${retired_dir}" \
    && rmdir "${retired_root}" \
    || printf '  [warn] Terminal install transaction cleanup remains at %s\n' \
      "${retired_root}" >&2
  return 0
}

settle_prior_install_durable_transaction() {
  local phase="" interrupted_backup=""
  [[ -e "${INSTALL_DURABLE_TRANSACTION_DIR}" \
      || -L "${INSTALL_DURABLE_TRANSACTION_DIR}" ]] || return 0
  if ! install_durable_transaction_receipt_is_valid; then
    printf 'Refusing install: fixed install transaction metadata is unsafe or malformed: %s\n' \
      "${INSTALL_DURABLE_TRANSACTION_DIR}" >&2
    printf 'No new backup or managed-file snapshot was created. Inspect this exact path and its retained timestamped backup before retrying.\n' >&2
    return 1
  fi
  phase="${INSTALL_DURABLE_TRANSACTION_PHASE}"
  interrupted_backup="${BACKUP_DIR}"
  case "${phase}" in
    committed|rolled-back)
      if ! retire_terminal_install_durable_transaction "${phase}"; then
        printf 'Refusing install: terminal install transaction metadata could not be retired safely: %s\n' \
          "${INSTALL_DURABLE_TRANSACTION_DIR}" >&2
        return 1
      fi
      printf '  Recovered terminal install transaction metadata (%s).\n' \
        "${phase}"
      ;;
    prepared)
      printf 'Refusing install: an interrupted install transaction is still prepared.\n' >&2
      printf 'Recovery backup: %s\n' "${interrupted_backup}" >&2
      printf 'No new backup or managed-file snapshot was created, so the interrupted generation was not accepted as a baseline.\n' >&2
      printf 'Inspect or restore that exact backup, then retire %s only after the managed generation is resolved.\n' \
        "${INSTALL_DURABLE_TRANSACTION_DIR}" >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

installed_transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.switch-tier-transaction" \
      "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
      "${CLAUDE_HOME}"/.switch-tier-retired.* \
      "${CLAUDE_HOME}/.omc-config-transaction" \
      "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
      "${CLAUDE_HOME}"/.omc-config-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

installed_switch_transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.switch-tier-transaction" \
      "${CLAUDE_HOME}"/.switch-tier-transaction.stage.* \
      "${CLAUDE_HOME}"/.switch-tier-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

installed_omc_config_transaction_metadata_present() {
  local candidate=""
  for candidate in \
      "${CLAUDE_HOME}/.omc-config-transaction" \
      "${CLAUDE_HOME}"/.omc-config-transaction.stage.* \
      "${CLAUDE_HOME}"/.omc-config-retired.*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] && return 0
  done
  return 1
}

# Install, uninstall, tier switching, config writes, and watchdog setup share
# one operation lock. A process killed after publishing a tier/config WAL but
# before rollback must be settled before this installer snapshots or replaces
# any managed leaf. Use the already-sealed private distribution generation,
# and recover the child tier transaction before its parent config transaction
# so omc-config never has to reopen the mutable installed switcher path.
settle_installed_configuration_transactions() {
  local switcher="${SOURCE_BUNDLE_SNAPSHOT}/switch-tier.sh"
  local configurer="${SOURCE_BUNDLE_SNAPSHOT}/skills/autowork/scripts/omc-config.sh"
  installed_transaction_metadata_present || return 0
  install_lock_generation_is_current || return 1
  source_distribution_seal_is_current || return 1
  [[ -f "${switcher}" && ! -L "${switcher}" \
      && -f "${configurer}" && ! -L "${configurer}" ]] || return 1

  if installed_switch_transaction_metadata_present; then
    HOME="${TARGET_HOME}" BASH_ENV='' ENV='' \
      OMC_PARENT_OPERATION_LOCK_PID="$$" \
      OMC_PARENT_OPERATION_LOCK_TOKEN="${INSTALL_LOCK_TOKEN}" \
      OMC_PARENT_OPERATION_LOCK_ID="${INSTALL_LOCK_DIR_ID}" \
      bash "${switcher}" --recover-only || return 1
    install_lock_generation_is_current || return 1
    source_distribution_seal_is_current || return 1
    installed_switch_transaction_metadata_present && return 1
  fi
  if installed_omc_config_transaction_metadata_present; then
    HOME="${TARGET_HOME}" BASH_ENV='' ENV='' \
      OMC_PARENT_OPERATION_LOCK_PID="$$" \
      OMC_PARENT_OPERATION_LOCK_TOKEN="${INSTALL_LOCK_TOKEN}" \
      OMC_PARENT_OPERATION_LOCK_ID="${INSTALL_LOCK_DIR_ID}" \
      bash "${configurer}" recover-only || return 1
    install_lock_generation_is_current || return 1
    source_distribution_seal_is_current || return 1
    installed_omc_config_transaction_metadata_present && return 1
  fi
  ! installed_transaction_metadata_present
}

# release_install_lock removes the lock dir ONLY if this process owns it.
# The pid-match guard matters because the EXIT trap is registered BEFORE
# acquire_install_lock — if our acquire fails (another install is running),
# a naive rm -rf would erase the contending process's lock dir and let
# two installs race. The guard scopes cleanup to locks we actually hold.
release_install_lock() {
  [[ "${INSTALL_LOCK_HELD:-0}" -eq 1 ]] || return 0
  if install_lock_generation_is_current; then
    if ! install_lock_publish_release_marker \
        || ! install_lock_retire_released_generation; then
      printf 'WARNING: the exact released install-lock generation could not be retired; it was preserved for manual inspection: %s\n' \
        "${INSTALL_LOCK_DIR}" >&2
    fi
  fi
  INSTALL_LOCK_HELD=0
}

cleanup_install_tmpfiles() {
  rm -f "${PRE_INSTALL_SIGNATURES:-}" "${POST_INSTALL_SIGNATURES:-}" \
    "${SETTINGS_PATCH_SNAPSHOT:-}" \
    "${SETTINGS_RENDER_BASE_PATH:-}" \
    "${SETTINGS_RENDER_PATCH_PATH:-}" \
    "${SETTINGS_RENDER_OUTPUT_PATH:-}" \
    "${SETTINGS_SEAL_CONTENT_SNAPSHOT:-}" \
    "${SETTINGS_STAGE_CONTENT_SNAPSHOT:-}" \
    "${MANIFEST_STAGE_PATH:-}" "${HASHES_STAGE_PATH:-}" \
    "${STAMP_STAGE_PATH:-}" "${REPORT_STAGE_PATH:-}" \
    2>/dev/null || true
  if [[ -n "${SETTINGS_STAGE_PATH:-}" ]]; then
    rm -f -- "${SETTINGS_STAGE_PATH}" "${SETTINGS_STAGE_PATH}.ready" \
      2>/dev/null || true
  fi
  cleanup_source_preflight_tmpfiles
}

# v1.42.x F-023 (SRE-lens): rollback-aware emergency trap.
#
# Pre-fix, a mid-install crash (rsync OOM, disk-full, SIGKILL during a
# post-rsync mutation) left the user with a half-installed CLAUDE_HOME
# AND a fresh BACKUP_DIR they had to discover and restore by hand. The
# trap below auto-prints a copy-paste recovery command naming the
# specific backup path on this run so the user has a one-line rollback
# at the bottom of their terminal scroll.
#
# The install transaction restores every path this invocation owns: copied
# bundle leaves, the physical settings target, config, control manifests,
# stamp/report, CLI link, seeded override, and optional Ghostty files. Custom
# paths remain outside its ownership.
_emergency_recovery_msg() {
  local _rc="${1:-$?}"
  if [[ ${_rc} -eq 0 ]]; then
    return 0
  fi
  printf >&2 '\n'
  printf >&2 'install.sh exited with status %d. Partial install possible.\n' "${_rc}"
  if [[ "${BACKUP_DIR_ALLOCATED:-0}" -eq 1 && -d "${BACKUP_DIR}" ]]; then
    printf >&2 'Backup of pre-install state: %s\n' "${BACKUP_DIR}"
    printf >&2 'Recovery if the automatic install rollback above was incomplete:\n'
    printf >&2 '  cp -a "%s/settings.json" "%s/settings.json" 2>/dev/null\n' "${BACKUP_DIR}" "${CLAUDE_HOME}"
    printf >&2 '  cp -a "%s/oh-my-claude.conf" "%s/oh-my-claude.conf" 2>/dev/null\n' "${BACKUP_DIR}" "${CLAUDE_HOME}"
    printf >&2 'Or re-run `bash install.sh` after fixing the underlying error.\n'
  fi
  return "${_rc}"
}

# Preserve the install's status while making cleanup unconditional. Calling
# the nonzero-returning reporter directly in a semicolon-delimited EXIT trap
# under `set -e` can stop the trap before temp-file and lock cleanup, leaving a
# failed install wedged behind its own stale lock.
_install_exit_handler() {
  local _rc=$?
  set +e
  # The receipt rename is the commit point. A catchable signal may arrive in
  # the few shell instructions between that atomic rename and the in-memory
  # rollback disarm below. In that case the durable, invocation-bound commit
  # wins: rolling back after commitment could itself be interrupted and leave
  # a partial prior generation behind metadata that says the attested commit
  # is safe to retire on the next startup.
  if [[ "${_rc}" -ne 0 ]] \
      && [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 ]] \
      && install_durable_transaction_receipt_is_valid committed \
      && [[ "${INSTALL_DURABLE_TRANSACTION_OPERATION_ID}" \
        == "${INSTALL_LOCK_TOKEN}" ]]; then
    INSTALL_ROLLBACK_ARMED=0
    printf >&2 'Install commit was already durable; preserving the fully attested managed generation.\n'
  fi
  if [[ "${_rc}" -ne 0 ]] \
      && [[ "${INSTALL_ROLLBACK_ARMED:-0}" -eq 1 ]]; then
    printf >&2 'Install transaction failed; restoring the exact pre-install managed generation.\n'
    if rollback_install_transaction; then
      if mark_install_durable_transaction_terminal rolled-back; then
        retire_terminal_install_durable_transaction rolled-back \
          || printf >&2 '  [warn] Rolled-back install transaction metadata remains for startup settlement: %s\n' \
            "${INSTALL_DURABLE_TRANSACTION_DIR}"
      else
        printf >&2 '  [warn] Rollback completed, but its durable terminal receipt could not be published; preserving startup refusal metadata at %s\n' \
          "${INSTALL_DURABLE_TRANSACTION_DIR}"
      fi
      INSTALL_ROLLBACK_ARMED=0
      printf >&2 'Install rollback complete. Foreign and custom paths were left untouched.\n'
    else
      printf >&2 '  [error] Install rollback was incomplete; restore the backup at %s and rerun install.sh.\n' \
        "${BACKUP_DIR}"
    fi
  fi
  _emergency_recovery_msg "${_rc}"
  cleanup_install_tmpfiles
  release_install_lock
  return "${_rc}"
}

_install_signal_handler() {
  local _status="$1"
  # Prevent a repeated shutdown signal from interrupting the rollback that the
  # EXIT handler is about to perform. `exit` still runs that EXIT handler.
  trap '' HUP INT TERM
  exit "${_status}"
}

PRE_INSTALL_SIGNATURES=""
POST_INSTALL_SIGNATURES=""

# Register the EXIT trap BEFORE acquire_install_lock so a lock-acquire
# failure (mid-mkdir crash, exhausted attempts) still triggers tmpfile
# cleanup. release_install_lock is pid-scoped above — it only removes
# locks this process owns, so safe to fire even when acquire failed.
trap '_install_exit_handler' EXIT
trap '_install_signal_handler 129' HUP
trap '_install_signal_handler 130' INT
trap '_install_signal_handler 143' TERM

acquire_install_lock

if ! settle_prior_install_durable_transaction; then
  printf 'Refusing install: an earlier install transaction must be resolved before any new managed snapshot is taken.\n' >&2
  exit 1
fi

if ! settle_installed_configuration_transactions; then
  printf 'Refusing install: an interrupted model/config transaction could not be settled safely. Managed files were not replaced.\n' >&2
  exit 1
fi
install_test_barrier \
  "${OMC_TEST_INSTALL_TX_SETTLED_READY_FILE:-}" \
  "${OMC_TEST_INSTALL_TX_SETTLED_RELEASE_FILE:-}" \
  "${CLAUDE_HOME}" || exit 1

printf 'Installing oh-my-claude into %s ...\n' "${CLAUDE_HOME}"

if ! source_distribution_seal_is_current \
    || ! settings_patch_seal_is_current; then
  printf 'Refusing install: source distribution changed after preflight. No bundle files were copied.\n' >&2
  exit 1
fi
if ! preflight_managed_destination_paths 0; then
  printf 'Refusing install: an existing managed destination path is unsafe. No bundle files were copied.\n' >&2
  exit 1
fi

# Resolve user-owned merge preferences and render the complete settings
# document before the first bundle byte is copied. The stage remains beside
# the physical destination until Step 4 publishes it atomically.
OMC_OUTPUT_STYLE_PREF="opencode"
OMC_OUTPUT_STYLE_PREF_EXPLICIT=0
_output_style_env="${OMC_OUTPUT_STYLE:-}"
if [[ "${_output_style_env}" =~ ^(opencode|executive|preserve)$ ]]; then
  OMC_OUTPUT_STYLE_PREF="${_output_style_env}"
  OMC_OUTPUT_STYLE_PREF_EXPLICIT=1
elif [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
  _pref_from_conf=""
  while IFS= read -r _output_style_line \
      || [[ -n "${_output_style_line}" ]]; do
    [[ "${_output_style_line}" == "output_style="* ]] || continue
    _output_style_value="${_output_style_line#*=}"
    _output_style_value="${_output_style_value#"${_output_style_value%%[![:space:]]*}"}"
    _output_style_value="${_output_style_value%"${_output_style_value##*[![:space:]]}"}"
    case "${_output_style_value}" in
      opencode|executive|preserve) _pref_from_conf="${_output_style_value}" ;;
    esac
  done < "${CLAUDE_HOME}/oh-my-claude.conf"
  if [[ -n "${_pref_from_conf}" ]]; then
    OMC_OUTPUT_STYLE_PREF="${_pref_from_conf}"
    OMC_OUTPUT_STYLE_PREF_EXPLICIT=1
  fi
fi
export OMC_OUTPUT_STYLE_PREF
export OMC_OUTPUT_STYLE_PREF_EXPLICIT
PRE_MERGE_STATUSLINE_CMD=""
if ! stage_settings_install_merge; then
  printf 'No bundle files were copied. Repair settings.json and rerun install.sh.\n' >&2
  exit 1
fi

# Step 1 — Create directories and back up existing files.
# Security: BACKUP_DIR holds copies of prior settings.json + oh-my-claude.conf
# (which carries claude_bin pin, model_tier, and other host-specific values).
# A2-MED-6 (4-attacker security review): chmod 700 the backup tree so a
# read-anywhere-in-${HOME} attacker cannot mine prior state for credentials,
# tokens, or oracle the user's PATH layout. The parent tree (${CLAUDE_HOME})
# is not blanket-700 (Claude Code itself reads files there), so harden the
# backup directly. The chmod runs before backup_existing_targets writes to
# the dir so the perms apply to the freshly-created tree.
mkdir -p "${CLAUDE_HOME}"
allocate_backup_dir
# v1.36.0: surface user edits in memory/ before rsync overwrites them.
# Runs BEFORE backup_existing_targets and BEFORE rsync — the warning
# fires while the live edit is still untouched on disk, so a Ctrl-C
# during the 5s wait (interactive only) leaves the file intact for the
# user to migrate. The subsequent backup_existing_targets does eventually
# preserve a copy under ${BACKUP_DIR}, but that recovery path is the
# fallback, not the contract surfaced in the warn message.
warn_modified_memory_files
snapshot_prior_model_configuration
backup_existing_targets
# Publish the fixed receipt before rollback is armed. From the next line onward,
# SIGKILL cannot make a later install silently accept this run's partial output
# as its pre-install baseline.
if ! begin_install_durable_transaction; then
  printf 'Refusing install: the fixed install transaction receipt could not be published. No managed files were replaced.\n' >&2
  exit 1
fi
# From this point until final attestation publishes the durable commit, every
# nonzero or catchable-signal exit restores the exact prior shipped roster and
# config. Arm only after every required backup completed, and before the first
# bundle mutation; SIGKILL is covered by the prepared startup refusal above.
INSTALL_ROLLBACK_ARMED=1

# Capture the pre-install managed-file snapshot before rsync mutates
# ~/.claude/. The current manifest enumerates exactly which installed
# files belonged to the last bundle generation.
PREVIOUS_MANIFEST_PATH="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
PREVIOUS_MANIFEST_PRESENT=0
if [[ -f "${PREVIOUS_MANIFEST_PATH}" ]]; then
  PREVIOUS_MANIFEST_PRESENT=1
fi
PRE_INSTALL_SIGNATURES="$(mktemp)"
build_signature_snapshot "${CLAUDE_HOME}" "${PREVIOUS_MANIFEST_PATH}" "${PRE_INSTALL_SIGNATURES}"
PRE_SETTINGS_SIGNATURE="$(file_cksum_signature "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"

# Step 2 — Copy bundle into ~/.claude/.
if ! source_distribution_seal_is_current \
    || ! settings_patch_seal_is_current; then
  printf 'Refusing install: source distribution changed before copy. Restore prior state from %s if needed and rerun install.sh.\n' \
    "${BACKUP_DIR}" >&2
  exit 1
fi
install_test_barrier \
  "${OMC_TEST_INSTALL_BUNDLE_COPY_READY_FILE:-}" \
  "${OMC_TEST_INSTALL_BUNDLE_COPY_RELEASE_FILE:-}" \
  "${BUNDLE_CLAUDE}" || exit 1
copy_admitted_source_snapshot "${SOURCE_BUNDLE_SNAPSHOT}" \
  "${SOURCE_BUNDLE_FILE_LIST}" "${CLAUDE_HOME}" \
  "${SOURCE_BUNDLE_MODE_MANIFEST}"
install_test_barrier \
  "${OMC_TEST_INSTALL_BUNDLE_COPIED_READY_FILE:-}" \
  "${OMC_TEST_INSTALL_BUNDLE_COPIED_RELEASE_FILE:-}" \
  "${CLAUDE_HOME}" || exit 1
verify_all_published_bundle_seals || exit 1
if ! source_distribution_seal_is_current; then
  printf '  [error] Source distribution changed while bundle bytes were copied; restore %s and rerun install.sh.\n' \
    "${BACKUP_DIR}" >&2
  exit 1
fi
if ! preflight_managed_destination_paths 1; then
  printf '  [error] Installed bundle contains an unsafe or non-regular managed path; restore %s and rerun install.sh.\n' \
    "${BACKUP_DIR}" >&2
  exit 1
fi
if ! verify_copied_tree_content "${CLAUDE_HOME}" \
    "${SOURCE_BUNDLE_FILE_LIST}" \
    "${SOURCE_BUNDLE_CONTENT_MANIFEST_HASH}" "bundle/dot-claude"; then
  printf '  [error] Refusing post-copy mutation because installed bundle bytes were not the preflight-approved source generation.\n' >&2
  exit 1
fi
if ! verify_tree_mode_manifest "${CLAUDE_HOME}" \
    "${SOURCE_BUNDLE_FILE_LIST}" "${SOURCE_BUNDLE_MODE_MANIFEST_HASH}" 0; then
  printf '  [error] Refusing post-copy mutation because installed bundle modes were not the preflight-approved source generation.\n' >&2
  exit 1
fi

# Strip macOS extended attributes (com.apple.provenance, com.apple.quarantine)
# inherited from the git clone. Without this, launchd processes (e.g. the
# resume-watchdog) get "Operation not permitted" reading installed scripts on
# macOS 15+ due to TCC restrictions on provenance-tagged files.
if [[ "$(uname)" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.provenance "${CLAUDE_HOME}/" 2>/dev/null || true
  xattr -dr com.apple.quarantine "${CLAUDE_HOME}/" 2>/dev/null || true
fi

# omc CLI on PATH (v1.48 W2): the walk-away goal loop ships at
# ~/.claude/bin/omc via the bundle rsync above. Expose it through
# ~/.local/bin when that directory already exists — never create the
# directory ourselves, and never clobber a foreign omc binary (only an
# absent target or a symlink already pointing at us is fair game).
if [[ -d "${TARGET_HOME}/.local/bin" && -x "${CLAUDE_HOME}/bin/omc" ]]; then
  if [[ ( ! -e "${TARGET_HOME}/.local/bin/omc" \
        && ! -L "${TARGET_HOME}/.local/bin/omc" ) ]] \
    || [[ "$(readlink "${TARGET_HOME}/.local/bin/omc" 2>/dev/null)" == "${CLAUDE_HOME}/bin/omc" ]]; then
    publish_install_symlink "${TARGET_HOME}/.local/bin/omc" \
      "${CLAUDE_HOME}/bin/omc" omc-cli || {
        printf '%s\n' \
          '  [error] Refusing unsafe or concurrent omc CLI publication.' >&2
        exit 1
      }
  fi
fi

# Remove iOS agents if --no-ios was specified.
if [[ "${EXCLUDE_IOS}" == "true" ]]; then
  for ios_agent in "${CLAUDE_HOME}/agents/ios-"*.md; do
    if [[ -f "${ios_agent}" ]]; then
      _ios_relative="agents/${ios_agent##*/}"
      bundle_published_path_seal_is_current \
        "${_ios_relative}" "${ios_agent}" || exit 1
      arm_published_bundle_path "${CLAUDE_HOME}" \
        "${_ios_relative}" absent || exit 1
      rm "${ios_agent}"
      record_published_bundle_path "${CLAUDE_HOME}" \
        "${_ios_relative}" absent || exit 1
      printf '  Excluded: %s\n' "$(basename "${ios_agent}")"
    fi
  done
fi

# Step 2b — Apply model tier (rewrite agent model assignments if needed),
# then per-agent overrides on top. Overrides run unconditionally (even when
# no tier is set) so a user can pin individual agents without opting into a
# whole-roster tier.
if ! preflight_installed_shipped_model_roster; then
  printf '  [error] Model setup aborted before changing declarations; restoring the prior shipped agent roster and config through the install transaction.\n' >&2
  exit 1
fi
apply_model_tier
apply_model_overrides "${CLAUDE_HOME}/agents" "${CLAUDE_HOME}/oh-my-claude.conf"
if ! preflight_installed_shipped_model_roster; then
  printf '  [error] Model setup verification failed after tier/override materialization; the install transaction will restore prior state.\n' >&2
  exit 1
fi

# Step 2c — Save repo path, installed version, and installed SHA for
# easy updates. The SHA lets the stale-install indicator detect a
# commits-ahead state even when VERSION hasn't been bumped (e.g. the
# repo has unreleased commits on main past the last tag). Silently
# clears installed_sha when the install source is not a git checkout
# (tarball, extracted zip) so a prior checkout-based install's SHA does not
# linger as a false comparator.
#
# v1.30.0: capture the prior installed_version BEFORE overwriting so the
# post-install summary can render a "What's new since v$prev" block.
# Empty on first install, on tarball / zip extracts without a prior conf,
# and on the unusual case where a custom build cleared the conf.
PRIOR_INSTALLED_VERSION=""
PRIOR_INSTALLED_SHA=""
if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
  PRIOR_INSTALLED_VERSION="$(read_last_valid_install_metadata \
    "${CLAUDE_HOME}/oh-my-claude.conf" installed_version)"
  PRIOR_INSTALLED_SHA="$(read_last_valid_install_metadata \
    "${CLAUDE_HOME}/oh-my-claude.conf" installed_sha)"
fi

set_conf "repo_path" "${SCRIPT_DIR}"
set_conf "installed_version" "${OMC_VERSION}"
if [[ "${EXCLUDE_IOS}" == "true" ]]; then
  set_conf "exclude_ios" "on"
else
  set_conf "exclude_ios" "off"
fi
if should_install_ghostty; then
  set_conf "ghostty_installed" "on"
else
  set_conf "ghostty_installed" "off"
fi

installed_sha=""
if is_git_checkout "${SCRIPT_DIR}"; then
  installed_sha="$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -n "${installed_sha}" ]]; then
  set_conf "installed_sha" "${installed_sha}"
else
  # Source is not a git checkout (tarball, extracted zip) — remove any
  # stale installed_sha left from a previous checkout-based install so
  # the statusline's commit-distance probe fails closed (returns None)
  # instead of reading an orphaned SHA and producing a misleading
  # `(+?)` marker against the next checkout this repo path maps to.
  _conf_path="${CLAUDE_HOME}/oh-my-claude.conf"
  if [[ -f "${_conf_path}" ]] && grep -q '^installed_sha=' "${_conf_path}"; then
    unset_conf "installed_sha"
  fi
fi

# Ensure the non-bundle state directory exists under the same transaction that
# owns its three installer controls. On a fresh install all three snapshots see
# an absent shared parent; bind the sibling keys to the exact directory created
# for the manifest key before any control stage is allocated there.
if ! ensure_install_transaction_parent \
      "${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt" manifest \
    || ! ensure_install_transaction_parent \
      "${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt" hashes manifest \
    || ! ensure_install_transaction_parent \
      "${CLAUDE_HOME}/quality-pack/state/last-install-report.json" report manifest; then
  printf 'Refusing install: quality-pack state parent changed after transaction snapshot.\n' >&2
  exit 1
fi

# Tighten quality-pack directory permissions to 700. Files inside are
# created with `umask 077` (set by common.sh) so they're already 600,
# but the parent directories default to 755 from `mkdir -p` under the
# user's umask. On shared machines this lets local peers list session
# UUIDs and time-correlate harness activity even when the file contents
# are unreadable. Tightening the parent dirs to 700 closes that
# exposure. Idempotent — re-running install on an already-700 dir is
# a no-op. Soft-failure (`|| true`) so a permission-restricted parent
# (synced volume, mounted FUSE) does not abort the install.
chmod 700 "${CLAUDE_HOME}/quality-pack" "${CLAUDE_HOME}/quality-pack/state" 2>/dev/null || true

# Step 2c-manifest — Orphan detection via bundle-file manifest.
# rsync -a without --delete leaves files from prior releases sitting in
# ~/.claude/ if the new bundle removed them (e.g. a renamed script). The
# manifest snapshot compares what was in the previous install against
# what's in the new bundle and warns about files that no longer ship so
# the user can decide whether to keep, delete, or clean-reinstall.
MANIFEST_PATH="${CLAUDE_HOME}/quality-pack/state/installed-manifest.txt"
create_install_control_stage "${MANIFEST_PATH}" MANIFEST_STAGE_PATH
# Collect bundle's relative file list from the new source, sorted. Used
# both to diff against the previous manifest (orphan detection) and to
# persist as the new manifest for the next install cycle.
#
# Locale discipline matters here: `comm -23` requires identically-sorted
# inputs, but `sort` (and `comm`) honor LC_COLLATE. A user who installs
# under `LC_ALL=en_US.UTF-8` and later re-installs under `LC_ALL=C`
# would see every mixed-case filename mis-ordered relative to the
# on-disk manifest, producing spurious orphan warnings. Pinning both
# the manifest build AND the comm comparison to `LC_ALL=C` gives a
# stable byte-order key that matches across install runs regardless of
# the user's environment. The persisted set is the exact post-exclusion
# installed set, not the source set: --no-ios therefore has no manifest/hash
# rows for the intentionally absent ios-* definitions.
if ! build_active_managed_file_list "${MANIFEST_STAGE_PATH}"; then
  printf 'Failed to build the exact post-exclusion installed manifest.\n' >&2
  exit 1
fi

orphan_count=0
orphan_list=""
if [[ -f "${MANIFEST_PATH}" && ! -L "${MANIFEST_PATH}" ]]; then
  # `comm -23 OLD NEW` prints lines in OLD that are not in NEW — i.e.
  # files that shipped in a prior release but are no longer in the new
  # bundle. We only warn when the orphan file still exists on disk; a
  # user may have already cleaned it up manually.
  while IFS= read -r orphan_rel; do
    [[ -z "${orphan_rel}" ]] && continue
    if [[ -f "${CLAUDE_HOME}/${orphan_rel}" ]]; then
      orphan_count=$((orphan_count + 1))
      orphan_list="${orphan_list}    ${orphan_rel}"$'\n'
    fi
  done < <(LC_ALL=C comm -23 "${MANIFEST_PATH}" "${MANIFEST_STAGE_PATH}")
fi

# Step 2c-hash — SHA-256 manifest for drift detection (A2-MED-4 from
# 4-attacker security review).
#
# The path-only manifest above tells verify.sh "these files should
# exist". It does NOT tell verify.sh "these files should still contain
# their bundled bytes". An A2 attacker (write-inside-`~/.claude/`)
# who replaces an installed script (e.g., stop-guard.sh swapped for an
# exfiltration shim that still passes `bash -n`) goes undetected by the
# existing existence-and-syntax checks. The hashes file closes that gap:
# verify.sh re-hashes each tracked path and fails on mismatch.
#
# SHA-256 authority is required by preflight above. Generate this manifest
# with that same exact executable; imported functions and later PATH changes
# cannot forge or suppress installed hashes.
#
# v1.36.0 (item #16): hash CLAUDE_HOME bytes (not BUNDLE_CLAUDE).
#
# The pre-fix design hashed BUNDLE_CLAUDE under the assumption that
# rsync -a preserves bytes faithfully so bundle hash == at-rest hash.
# This was broken-by-design for any user with model_tier=quality or
# model_tier=economy: apply_model_tier() runs AFTER rsync and rewrites
# the `model:` field of every agent file in CLAUDE_HOME. The hash
# manifest still reflects the bundle bytes (sonnet/opus original),
# but the live files now carry the rewritten tier — so verify.sh
# drift detection fired FAILED on every model-tier-customized install.
# Symptom: 21 spurious actionable warnings on a clean install for a
# user on quality tier (one per agent file with a `model:` field).
#
# Fix: hash the live CLAUDE_HOME files AFTER all post-rsync mutations
# (apply_model_tier, --no-ios removals). The hash manifest now reflects
# what's actually on disk. The MANIFEST_PATH file (written above)
# enumerates the bundle file list; we filter to "still exists in
# CLAUDE_HOME" so --no-ios removals are not treated as drift.
HASHES_PATH="${CLAUDE_HOME}/quality-pack/state/installed-hashes.txt"
create_install_control_stage "${HASHES_PATH}" HASHES_STAGE_PATH
# Hash every admitted relative path with the preflight-pinned executable.
# Avoid xargs here: an imported shell function named xargs would otherwise be
# another way to forge or suppress the manifest despite pinning the hasher.
if ! \generate_trusted_sha256_manifest "${TRUSTED_SHA256_TOOL}" \
    "${CLAUDE_HOME}" "${MANIFEST_STAGE_PATH}" "${HASHES_STAGE_PATH}"; then
  printf 'Failed to generate SHA-256 drift manifest with trusted executable: %s\n' \
    "${TRUSTED_SHA256_TOOL}" >&2
  exit 1
fi
manifest_row_count="$(wc -l < "${MANIFEST_STAGE_PATH}" | tr -d '[:space:]')"
hash_row_count="$(wc -l < "${HASHES_STAGE_PATH}" | tr -d '[:space:]')"
if [[ ! -s "${MANIFEST_STAGE_PATH}" || ! -s "${HASHES_STAGE_PATH}" \
    || "${manifest_row_count}" != "${hash_row_count}" ]]; then
  printf 'Refusing to publish incomplete installed manifest/hash controls.\n' >&2
  exit 1
fi
chmod 600 "${MANIFEST_STAGE_PATH}" "${HASHES_STAGE_PATH}" || exit 1
if ! source_distribution_seal_is_current \
    || ! publish_install_control_stage "${HASHES_STAGE_PATH}" "${HASHES_PATH}" hashes; then
  printf 'Failed to publish the installed hash manifest atomically.\n' >&2
  exit 1
fi
HASHES_STAGE_PATH=""
if ! publish_install_control_stage "${MANIFEST_STAGE_PATH}" "${MANIFEST_PATH}" manifest; then
  printf 'Failed to publish the installed path manifest atomically.\n' >&2
  exit 1
fi
MANIFEST_STAGE_PATH=""

# Step 2d — Create user-override directory (never overwritten by rsync).
# Files in omc-user/ survive updates. Existing user content is preserved.
# The template is seeded on first install; subsequent installs only ensure
# overrides.md exists (the bundle CLAUDE.md @-references it unconditionally).
if ! source_distribution_seal_is_current; then
  printf 'Refusing install: source distribution changed before user-template copy. Restore %s and rerun install.sh.\n' \
    "${BACKUP_DIR}" >&2
  exit 1
fi
OMC_USER_DIR="${CLAUDE_HOME}/omc-user"
OMC_USER_TEMPLATE="${SOURCE_USER_TEMPLATE_SNAPSHOT}"
_override_source="${OMC_USER_TEMPLATE}/overrides.md"
_override_target="${OMC_USER_DIR}/overrides.md"
_override_mode="$(awk -F $'\t' '$2 == "overrides.md" { print $1; found++ } END { if (found != 1) exit 1 }' \
  "${SOURCE_USER_TEMPLATE_MODE_MANIFEST}")" || {
    printf 'Refusing install: user override template mode authority is incomplete.\n' >&2
    exit 1
  }
if [[ ! -f "${_override_source}" || -L "${_override_source}" ]]; then
  printf 'Refusing install: required private user override template is missing.\n' >&2
  exit 1
fi
_omc_user_dir_was_missing=0
[[ -d "${OMC_USER_DIR}" ]] || _omc_user_dir_was_missing=1
if ! ensure_install_transaction_parent \
    "${_override_target}" user-overrides; then
  printf 'Refusing install: omc-user destination parent changed after preflight.\n' >&2
  exit 1
fi
if [[ ! -e "${_override_target}" && ! -L "${_override_target}" ]]; then
  if ! publish_install_regular_source "${_override_source}" \
      "${_override_target}" user-overrides "${_override_mode}" 1 \
      || ! source_distribution_seal_is_current \
      || ! verify_copied_file_hash "${_override_target}" \
        "${SOURCE_USER_TEMPLATE_OVERRIDES_HASH}" \
        "bundle/omc-user-template/overrides.md"; then
    printf 'Refusing install: copied user-template bytes did not match preflight authority. Restore %s and rerun install.sh.\n' \
      "${BACKUP_DIR}" >&2
    exit 1
  fi
  if [[ "${_omc_user_dir_was_missing}" -eq 1 ]]; then
    printf '  Created user-override directory: %s\n' "${OMC_USER_DIR}"
  fi
fi

# Step 3 — Install Ghostty theme/config (no-op if bundle has none, or
# if --no-ghostty / auto-detect skipped it).
if should_install_ghostty; then
  if ! source_distribution_seal_is_current; then
    printf 'Refusing install: source distribution changed before Ghostty copy. Restore %s and rerun install.sh.\n' \
      "${BACKUP_DIR}" >&2
    exit 1
  fi
  if ! install_ghostty; then
    printf 'Refusing install: Ghostty source/copy bytes changed after preflight. Restore %s and rerun install.sh.\n' \
      "${BACKUP_DIR}" >&2
    exit 1
  fi
fi

# Step 4 — Publish the already-rendered settings transaction. This remains
# late so config/model/materialization failures cannot expose hook commands
# before their target scripts exist. The exact original seal is re-attested
# immediately before the same-directory rename.
if ! publish_staged_settings_install; then
  exit 1
fi

# Step 4a — Foreign hook detection (A2-HIGH-1 from 4-attacker security
# review).
#
# The settings-merge above is purely additive: any hook entry already
# present in settings.json that doesn't conflict with a bundled patch
# entry (matcher- AND exact-identity-disjoint) survives every reinstall. An
# A2 attacker (write-inside-`~/.claude/`) who plants
#   { "matcher": "*", "command": "bash /tmp/persistence.sh" }
# inside ~/.claude/settings.json gains a hook that fires on every event
# AND survives every reinstall the user runs to "fix" their environment.
# Without this warning the survival is silent: the user's natural
# recovery action (re-install) returns no signal of foreign content.
#
# We do not DELETE foreign entries here because (a) the user may
# legitimately have non-bundled hooks (custom integrations), and (b)
# destructive automation at install time would be alarming. We surface
# them so the user can audit and prune. The verify.sh-side equivalent
# (Step 8 in verify.sh) reports the same detection (default-warn or
# --strict-fail), giving the user a clear "your install passes
# structural checks but contains unexpected hook commands" signal.
#
# The allowlist is the exact command set declared by settings.patch.json.
# A path merely living under a managed directory is not sufficient: an
# untracked script, omitted role argument, extra shell operator, or cosmetic
# command rewrite is foreign. This keeps install diagnostics aligned with the
# exact event/matcher/type/command contract verified by verify.sh.
warn_foreign_hooks() {
  local settings_file="$1"
  [[ -f "${settings_file}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Distinguish jq parse failure (malformed JSON — itself an A2
  # indicator that warrants a loud signal) from "no foreign entries
  # found" (silence is correct).
  local jq_err jq_rc=0
  jq_err="$(jq -r --slurpfile patch "${SETTINGS_PATCH_SNAPSHOT}" '
    . as $settings
    |
    def hook_command:
      if type == "object" and has("command") and .command != null
      then .command else "" end;
    def command_text:
      if type == "string" then . else tojson end;
    [($patch[0].hooks // {}) | to_entries[] | .value[]?
      | (.hooks // [])[]? | select(type == "object")
      | hook_command] | unique as $allowed
    | [($settings.hooks // {}) | to_entries[] | .value[]?
       | (.hooks // [])[]? | select(type == "object")
       | hook_command] | unique
    | .[] as $command
    | select(($allowed | index($command)) == null)
    | $command | command_text
  ' "${settings_file}" 2>&1)" || jq_rc=$?

  if [[ ${jq_rc} -ne 0 ]]; then
    printf '\n'
    printf '  [warn] settings.json could not be parsed by jq:\n'
    printf '    %s\n' "${jq_err}"
    printf '  Foreign-hook detection skipped on this install. Re-check\n'
    printf '  the file and re-run install.sh.\n'
    printf '\n'
    return 0
  fi
  local foreign="" cmd
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    foreign+="    ${cmd}"$'\n'
  done <<< "${jq_err}"

  if [[ -n "${foreign}" ]]; then
    printf '\n'
    printf '  [warn] Detected non-bundled hook commands in settings.json:\n'
    printf '%s' "${foreign}"
    printf '  These survive reinstalls. They may be legitimate custom hooks,\n'
    printf '  but warrant a manual audit. Inspect with:\n'
    printf '    jq .hooks %s\n' "${settings_file}"
    printf '\n'
  fi

}

warn_global_hook_disable() {
  local settings_file="$1"
  local disabled="false"
  [[ -f "${settings_file}" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -e '.disableAllHooks == true' "${settings_file}" >/dev/null 2>&1 && disabled="true"
  elif command -v python3 >/dev/null 2>&1; then
    disabled="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        value = json.load(f).get("disableAllHooks") is True
    sys.stdout.write("true" if value else "false")
except Exception:
    sys.stdout.write("false")
' "${settings_file}" 2>/dev/null || printf 'false')"
  fi
  if [[ "${disabled}" == "true" ]]; then
    printf '\n'
    printf '  [warn] settings.json has disableAllHooks=true.\n'
    printf '  The bundled hook entries are installed but Claude Code will not run them.\n'
    printf '  Remove that setting (or set it to false), then re-run verify.sh.\n'
    printf '\n'
  fi
}

# warn_foreign_statusline — paired with warn_foreign_hooks, fires
# AFTER merge_settings_*. Compares the PRE_MERGE_STATUSLINE_CMD
# value (captured BEFORE the merge above) against the bundled value;
# if they differed, surface a warning so the user knows install.sh
# just thwarted (or normalized) a divergence. .statusLine.command is
# a code-execution surface Claude Code execs every status-bar
# refresh; the bundled patch is a single fixed value
# (`~/.claude/statusline.py`) — equality check is cheaper than the
# foreign-hook regex.
warn_foreign_statusline() {
  # shellcheck disable=SC2088 # comparing unexpanded `~` literal — bundled patch ships the unexpanded form, Claude Code expands at exec time
  if [[ -n "${PRE_MERGE_STATUSLINE_CMD}" \
     && "${PRE_MERGE_STATUSLINE_CMD}" != "~/.claude/statusline.py" ]]; then
    printf '\n'
    printf '  [warn] .statusLine.command differed from bundled value pre-install.\n'
    printf '    Pre-install: %s\n' "${PRE_MERGE_STATUSLINE_CMD}"
    printf '    Restored to: ~/.claude/statusline.py\n'
    printf '  install.sh always overwrites .statusLine on merge, but the\n'
    printf '  divergence has been logged so you can investigate whether\n'
    printf '  it was intentional or a sign of tampering.\n'
    printf '\n'
  fi
}

warn_foreign_hooks "${CLAUDE_HOME}/settings.json"
warn_global_hook_disable "${CLAUDE_HOME}/settings.json"
warn_foreign_statusline

# Step 5 — Set executable bits on scripts.
ensure_executable_bits

# Snapshot the final managed installed bytes after all post-rsync
# mutations. This is the source of truth for "did a reinstall/update
# actually change what a running session would use?"
POST_INSTALL_SIGNATURES="$(mktemp)"
build_signature_snapshot "${CLAUDE_HOME}" "${MANIFEST_PATH}" "${POST_INSTALL_SIGNATURES}"
POST_SETTINGS_SIGNATURE="$(file_cksum_signature "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"

# v1.47 (the 17-day CI release blocker, traced to THIS line on the GitHub
# runner): GNU join enforces an input-order check in the AMBIENT locale and
# exits 1 on perceived disorder — with stderr formerly sent to /dev/null,
# `set -euo pipefail` killed the whole install silently right here, only on
# the runner, only on re-installs (the failed attempt's own manifest rewrite
# healed the retry — the live-fire signature that finally exposed it). The
# snapshot files are LC_ALL=C-sorted by construction, so the joins now run
# under LC_ALL=C too (check-locale == sort-locale: the divergence class is
# gone), stderr is no longer hidden, and the substitutions are guarded:
# these counts feed the install SUMMARY — telemetry must never abort an
# install (same fail-open-but-observable contract as the hook ERR-traps).
managed_added_count="$(LC_ALL=C join -t $'\t' -v 2 "${PRE_INSTALL_SIGNATURES}" "${POST_INSTALL_SIGNATURES}" | wc -l | tr -d '[:space:]' || true)"
managed_removed_count="$(LC_ALL=C join -t $'\t' -v 1 "${PRE_INSTALL_SIGNATURES}" "${POST_INSTALL_SIGNATURES}" | wc -l | tr -d '[:space:]' || true)"
managed_modified_count="$(LC_ALL=C join -t $'\t' "${PRE_INSTALL_SIGNATURES}" "${POST_INSTALL_SIGNATURES}" \
  | awk -F $'\t' '$2 != $3 { c++ } END { print c+0 }' || true)"
managed_added_count="${managed_added_count:-0}"
managed_removed_count="${managed_removed_count:-0}"
managed_modified_count="${managed_modified_count:-0}"
[[ "${managed_added_count}" =~ ^[0-9]+$ ]] || managed_added_count=0
[[ "${managed_removed_count}" =~ ^[0-9]+$ ]] || managed_removed_count=0
[[ "${managed_modified_count}" =~ ^[0-9]+$ ]] || managed_modified_count=0
managed_change_total=$((managed_added_count + managed_removed_count + managed_modified_count))

settings_changed_json="false"
if [[ "${PRE_SETTINGS_SIGNATURE}" != "${POST_SETTINGS_SIGNATURE}" ]]; then
  settings_changed_json="true"
fi

# Step 6 — Install stamp. Gives users a reliable "what changed in this
# install" reference (find ~/.claude -newer ~/.claude/.install-stamp).
# rsync -a preserves the bundle's mtimes rather than setting them to now,
# so without an explicit stamp no tooling can distinguish "touched by this
# install" from "cloned at this time". Uses `touch` with no flags so both
# BSD (macOS) and GNU (Linux) touch behave identically (-d is a GNU-ism).
INSTALL_STAMP_PATH="${CLAUDE_HOME}/.install-stamp"
create_install_control_stage "${INSTALL_STAMP_PATH}" STAMP_STAGE_PATH
touch "${STAMP_STAGE_PATH}"
chmod 600 "${STAMP_STAGE_PATH}" || exit 1
if ! publish_install_control_stage "${STAMP_STAGE_PATH}" \
    "${INSTALL_STAMP_PATH}" stamp; then
  printf 'Failed to publish the install stamp atomically.\n' >&2
  exit 1
fi
STAMP_STAGE_PATH=""

LAST_INSTALL_REPORT_PATH="${CLAUDE_HOME}/quality-pack/state/last-install-report.json"
install_stamp_epoch="$(_install_file_mtime "${INSTALL_STAMP_PATH}" || true)"
fresh_install_json="false"
update_install_json="false"
restart_required_json="false"
install_kind="reinstall"
restart_reason="No managed bundle or settings changes detected on this reinstall."
change_summary_available_json="false"
change_summary_reason="Not an update install."
change_summary_commit_count="0"
change_summary_truncated_count="0"
change_summary_commits_json='[]'

if [[ -z "${PRIOR_INSTALLED_VERSION}" ]] && [[ "${PREVIOUS_MANIFEST_PRESENT}" -eq 0 ]]; then
  fresh_install_json="true"
  install_kind="fresh-install"
  restart_required_json="true"
  restart_reason="Fresh install — current Claude Code sessions do not have oh-my-claude hook wiring loaded."
elif [[ "${PRIOR_INSTALLED_VERSION}" != "${OMC_VERSION}" ]] \
  || { [[ -n "${PRIOR_INSTALLED_SHA}" ]] && [[ -n "${installed_sha}" ]] && [[ "${PRIOR_INSTALLED_SHA}" != "${installed_sha}" ]]; }; then
  update_install_json="true"
  install_kind="update"
fi

if [[ "${fresh_install_json}" != "true" ]]; then
  if [[ "${managed_change_total}" -gt 0 ]] && [[ "${settings_changed_json}" == "true" ]]; then
    restart_required_json="true"
    restart_reason="${managed_change_total} managed installed path(s) changed and settings.json changed."
  elif [[ "${managed_change_total}" -gt 0 ]]; then
    restart_required_json="true"
    restart_reason="${managed_change_total} managed installed path(s) changed."
  elif [[ "${settings_changed_json}" == "true" ]]; then
    restart_required_json="true"
    restart_reason="settings.json changed."
  elif [[ "${install_kind}" == "update" ]]; then
    restart_reason="Update completed, but managed bundle files and settings.json were unchanged."
  elif [[ "${install_kind}" == "reinstall" ]]; then
    install_kind="reinstall-noop"
  fi
fi

if [[ "${install_kind}" == "update" ]]; then
  change_summary_reason=""
  if [[ -z "${PRIOR_INSTALLED_SHA}" ]]; then
    change_summary_reason="Previous install had no installed_sha metadata."
  elif [[ -z "${installed_sha}" ]]; then
    change_summary_reason="Current install source is not a git checkout, so commit history is unavailable."
  elif ! git -C "${SCRIPT_DIR}" rev-parse "${PRIOR_INSTALLED_SHA}^{commit}" >/dev/null 2>&1; then
    change_summary_reason="Previous installed_sha is not present in the current checkout."
  else
    change_summary_commit_count="$(git -C "${SCRIPT_DIR}" rev-list --count "${PRIOR_INSTALLED_SHA}..HEAD" 2>/dev/null || echo 0)"
    if [[ "${change_summary_commit_count}" =~ ^[0-9]+$ ]]; then
      change_summary_available_json="true"
      if [[ "${change_summary_commit_count}" -gt 12 ]]; then
        change_summary_truncated_count="$((change_summary_commit_count - 12))"
      fi
      change_summary_commits_json="$(
        git -C "${SCRIPT_DIR}" log --format='%H%x09%s' --no-decorate "${PRIOR_INSTALLED_SHA}..HEAD" 2>/dev/null \
          | sed -n '1,12p' \
          | jq -Rsc '
              split("\n")
              | map(select(length > 0))
              | map(split("\t"))
              | map({
                  sha: .[0],
                  subject: (.[1] // "")
                })
            '
      )"
      change_summary_reason="Computed from previous_install.installed_sha..HEAD."
    else
      change_summary_reason="Could not determine commit count for previous_install.installed_sha..HEAD."
      change_summary_commit_count="0"
    fi
  fi
fi

create_install_control_stage "${LAST_INSTALL_REPORT_PATH}" REPORT_STAGE_PATH
jq -n \
  --argjson schema_version 1 \
  --arg install_kind "${install_kind}" \
  --argjson fresh_install "${fresh_install_json}" \
  --argjson update_install "${update_install_json}" \
  --argjson restart_required "${restart_required_json}" \
  --arg restart_reason "${restart_reason}" \
  --arg prior_installed_version "${PRIOR_INSTALLED_VERSION}" \
  --arg prior_installed_sha "${PRIOR_INSTALLED_SHA}" \
  --arg installed_version "${OMC_VERSION}" \
  --arg installed_sha "${installed_sha}" \
  --argjson settings_changed "${settings_changed_json}" \
  --argjson install_stamp_epoch "${install_stamp_epoch:-0}" \
  --argjson managed_added "${managed_added_count:-0}" \
  --argjson managed_removed "${managed_removed_count:-0}" \
  --argjson managed_modified "${managed_modified_count:-0}" \
  --argjson managed_total "${managed_change_total:-0}" \
  --argjson change_summary_available "${change_summary_available_json}" \
  --arg change_summary_reason "${change_summary_reason}" \
  --argjson change_summary_commit_count "${change_summary_commit_count:-0}" \
  --argjson change_summary_truncated_count "${change_summary_truncated_count:-0}" \
  --argjson change_summary_commits "${change_summary_commits_json}" \
  '{
    schema_version: $schema_version,
    install_kind: $install_kind,
    fresh_install: $fresh_install,
    update_install: $update_install,
    restart_required: $restart_required,
    restart_reason: $restart_reason,
    previous_install: {
      installed_version: (if $prior_installed_version == "" then null else $prior_installed_version end),
      installed_sha: (if $prior_installed_sha == "" then null else $prior_installed_sha end)
    },
    current_install: {
      installed_version: $installed_version,
      installed_sha: (if $installed_sha == "" then null else $installed_sha end)
    },
    managed_changes: {
      added: $managed_added,
      removed: $managed_removed,
      modified: $managed_modified,
      total: $managed_total
    },
    change_summary: {
      available: $change_summary_available,
      reason: (if $change_summary_reason == "" then null else $change_summary_reason end),
      commit_count: $change_summary_commit_count,
      truncated_count: $change_summary_truncated_count,
      commits: $change_summary_commits
    },
    settings_changed: $settings_changed,
    install_stamp_epoch: $install_stamp_epoch
  }' > "${REPORT_STAGE_PATH}"
if ! jq -e '
    type == "object"
    and .schema_version == 1
    and (.install_kind | type == "string" and length > 0)
    and (.restart_required | type == "boolean")
    and (.managed_changes | type == "object")
    and (.settings_changed | type == "boolean")
    and (.install_stamp_epoch | type == "number")
  ' "${REPORT_STAGE_PATH}" >/dev/null \
    || ! publish_install_control_stage "${REPORT_STAGE_PATH}" \
      "${LAST_INSTALL_REPORT_PATH}" report; then
  printf 'Failed to validate or atomically publish last-install-report.json.\n' >&2
  exit 1
fi
REPORT_STAGE_PATH=""

# Step 7 — Optional: install the post-merge git hook in the source checkout.
if [[ "${INSTALL_GIT_HOOKS}" == "true" ]]; then
  install_git_hooks || exit 1
elif installed_git_hook_needs_refresh; then
  printf '  Git hooks:     refreshing previously installed post-merge hook\n'
  install_git_hooks || exit 1
fi

# Clean up the old-name output style while rollback authority is still armed.
# This is the final transaction-owned mutation; no success-shaped output is
# emitted until every managed generation is re-attested and committed below.
if [[ -f "${CLAUDE_HOME}/output-styles/opencode-compact.md" ]]; then
  if ! install_control_target_is_safe \
      "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
      || ! install_transaction_path_phase_is_current \
        "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
        legacy-output-style initial \
      || ! arm_install_transaction_publication \
        "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
        legacy-output-style absent \
      || ! rm -f -- "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
      || ! record_install_transaction_publication \
        "${CLAUDE_HOME}/output-styles/opencode-compact.md" \
        legacy-output-style absent; then
    printf '  [error] Refusing unsafe legacy output-style cleanup target.\n' >&2
    exit 1
  fi
fi
if [[ "${OMC_TEST_INSTALL_FAIL_AFTER_LEGACY_CLEANUP:-0}" == "1" ]]; then
  printf '  [test] Injected failure after legacy output-style cleanup.\n' >&2
  exit 97
fi

install_test_barrier \
  "${OMC_TEST_INSTALL_FINAL_ATTEST_READY_FILE:-}" \
  "${OMC_TEST_INSTALL_FINAL_ATTEST_RELEASE_FILE:-}" \
  "${INSTALL_STATE_REPORT_SOURCE}" || exit 1
source_distribution_seal_is_current || exit 1
verify_all_published_bundle_seals || exit 1
verify_all_install_transaction_publications || exit 1
published_settings_install_is_current || exit 1
if ! mark_install_durable_transaction_terminal committed; then
  printf '  [error] Final managed generation passed attestation, but its durable install commit could not be confirmed; resolving through the durable receipt.\n' >&2
  exit 1
fi
INSTALL_ROLLBACK_ARMED=0
install_test_barrier \
  "${OMC_TEST_INSTALL_COMMIT_MARKED_READY_FILE:-}" \
  "${OMC_TEST_INSTALL_COMMIT_MARKED_RELEASE_FILE:-}" \
  "${INSTALL_DURABLE_TRANSACTION_RECEIPT}" || exit 1
if ! retire_terminal_install_durable_transaction committed; then
  printf '  [warn] The committed install transaction receipt could not be retired; the next installer will settle it before taking a new snapshot.\n' >&2
fi

# ===========================================================================
# Summary
# ===========================================================================

printf '\n'
# v1.31.0 Wave 5 (visual-craft F-1): unified box-rule card head matching
# /ulw-time, show-status, and the welcome banner. Pre-Wave-5 used the
# generic `=== title ===` form which reads as "default-Bash-tutorial"
# in the visual-craft assessment.
#
# v1.42.x F-019 (visual-craft post-W2 review): honor OMC_PLAIN here for
# parity with omc_box_rule_glyph (common.sh:4106). The installer can't
# safely source common.sh (the install hasn't happened yet), so the
# OMC_PLAIN branch is inlined for symmetry.
case "${OMC_PLAIN:-}" in
  1|on|true|yes) printf -- '--- oh-my-claude install complete ---\n' ;;
  *) printf '─── oh-my-claude install complete ───\n' ;;
esac
printf '\n'
printf '  Version:       %s\n' "${OMC_VERSION}"
if [[ -n "${installed_sha}" ]]; then
  printf '  Commit:        %s\n' "${installed_sha:0:12}"
fi
# v1.30.0: when the installed_version changed, surface the version
# headings between PRIOR_INSTALLED_VERSION and OMC_VERSION extracted
# from CHANGELOG.md. Closes the v1.29.0 product-lens P2-10 / growth-lens
# P2-10 deferred item — users running `git pull && bash install.sh`
# weekly previously got zero in-context awareness of what changed.
# Silent on: first install (PRIOR empty), same-version reinstall (no
# upgrade), missing CHANGELOG, awk extraction failure. Caps at 30 entries
# (v1.32.7 raised from 15 to end the recurring cap-bump cycle that
# broke install-whats-new tests in v1.31.1 / v1.32.1 / v1.32.3 /
# v1.32.5 / v1.32.6 — every 3-5 patches the cap had to be re-bumped
# because adding entries pushed a real 1.27.0 → head upgrade past it.
# 30 covers any reasonable upgrade span without the periodic bump
# pressure. The deeper "derive from tag count" answer doesn't work
# reliably because install-remote.sh defaults to a shallow clone
# (--depth=1) without --tags, so `git tag --list` is unreliable.
# user can read CHANGELOG.md for full detail.
if [[ -n "${PRIOR_INSTALLED_VERSION}" ]] \
    && [[ "${PRIOR_INSTALLED_VERSION}" != "${OMC_VERSION}" ]] \
    && [[ -f "${CHANGELOG_SNAPSHOT}" ]]; then
  # v1.36.0 (item #6): collapse same-X.Y patches into one summary line.
  # Pre-v1.36.0 the awk listed every CHANGELOG `## [X.Y.Z]` heading
  # individually — e.g., a 1.27.0 → 1.34.x upgrade rendered 16 separate
  # 1.32.x patch lines, dominating the install footer with low-signal
  # noise. New shape:
  #   - 1.34.0  (date)              ← single-entry minor: full line
  #   - 1.32.x  (16 entries — see CHANGELOG.md, range 1.32.0 → 1.32.15)
  #
  # Two-pass logic kept inside one awk invocation: pass 1 walks lines
  # in the file's natural reverse-chronological order, accumulates a
  # current minor (X.Y), counts patches, and flushes one line per
  # minor (or per individual entry if the minor has only one). Stops
  # at the prior version. The 40-entry cap from v1.34.2 stays in
  # place but now bounds the number of UNIQUE minors that can be
  # emitted, which is more forgiving than the old per-patch cap.
  #
  # OMC_INSTALL_VERBOSE=1 toggles the full per-patch view back on for
  # users who specifically want it (e.g., debugging which exact patch
  # fixed something).
  if [[ "${OMC_INSTALL_VERBOSE:-0}" == "1" ]]; then
    _whats_new="$(awk -v prev="${PRIOR_INSTALLED_VERSION}" -v curr="${OMC_VERSION}" '
      /^## \[/ {
        ver = $0
        sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
        datepart = $0
        sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)
        if (ver == prev) { exit }
        kept++
        # v1.42.0: cap raised from 40 → 60. The project has accumulated
        # 43 unique major.minor releases as of v1.42.0, pushing the
        # previous cap into truncation on full-history spans. 60 gives
        # ~17 minor-release headroom at current cadence (~1-2 years).
        # Bump in lockstep with install.sh:1901 (collapsed cap) and
        # the historical long-span synthesizer (>60 needed).
        if (kept > 60) { truncated = 1; exit }
        if (ver == "Unreleased") {
          printf "                   - %s\n", ver
        } else {
          printf "                   - %s%s\n", ver, (datepart == "" ? "" : "  (" datepart ")")
        }
      }
      END { if (truncated) print "                   - ... (older entries — see CHANGELOG.md)" }
    ' "${CHANGELOG_SNAPSHOT}" 2>/dev/null || true)"
  else
    _whats_new="$(awk -v prev="${PRIOR_INSTALLED_VERSION}" -v curr="${OMC_VERSION}" '
      function flush(   line) {
        if (current_minor == "") return
        if (current_count == 1) {
          line = current_first
          if (current_first_date != "") { line = line "  (" current_first_date ")" }
          printf "                   - %s\n", line
        } else {
          # current_first is the FIRST seen (highest patch since CHANGELOG
          # is reverse-chronological); current_last is the LAST seen
          # (lowest patch in the run). Emit the inclusive range so users
          # know the span at a glance without reading the full CHANGELOG.
          printf "                   - %s.x  (%d entries — range %s → %s)\n", \
            current_minor, current_count, current_last, current_first
        }
        current_minor = ""; current_count = 0
        current_first = ""; current_first_date = ""; current_last = ""
      }
      /^## \[/ {
        ver = $0
        sub(/^## \[/, "", ver); sub(/\].*/, "", ver)
        datepart = $0
        sub(/^[^]]*\][[:space:]]*-?[[:space:]]*/, "", datepart)

        # Stop at the prior version — flush any pending group first
        # so the trailing minor is rendered before exit.
        if (ver == prev) { flush(); exit }

        if (ver == "Unreleased") {
          flush()
          printf "                   - %s\n", ver
          next
        }

        # Extract minor (X.Y) from X.Y.Z. Non-semver versions go
        # through unchanged as their own minor.
        n = split(ver, parts, ".")
        if (n >= 2) {
          minor = parts[1] "." parts[2]
        } else {
          minor = ver
        }

        if (minor != current_minor) {
          flush()
          # Cap on UNIQUE minors emitted (was 40 per-patch; now 40 minors).
          minors_emitted++
          # v1.42.0: cap raised 40 → 60 (lockstep with install.sh:1844).
          if (minors_emitted > 60) { truncated = 1; exit }
          current_minor = minor
          current_count = 1
          current_first = ver
          current_first_date = datepart
          current_last = ver
        } else {
          current_count++
          current_last = ver
        }
      }
      END {
        flush()
        if (truncated) print "                   - ... (older entries — see CHANGELOG.md)"
      }
    ' "${CHANGELOG_SNAPSHOT}" 2>/dev/null || true)"
  fi
  if [[ -n "${_whats_new}" ]]; then
    printf '  What'\''s new:    versions since v%s:\n' "${PRIOR_INSTALLED_VERSION}"
    printf '%s' "${_whats_new}"
    printf '                   See %s/CHANGELOG.md for details.\n' "${SCRIPT_DIR}"
  fi
fi

# v1.36.0 (item #14): surface the v1.34.0 omc-repro.sh redaction
# advisory if the user is upgrading from a version inside the affected
# range (v1.29.0 ≤ prior ≤ v1.33.2). Pre-v1.34.0 omc-repro.sh tarballs
# may carry prompt-text fragments under state-corruption rows in the
# bundled gate_events.jsonl — the advisory was buried mid-CHANGELOG and
# easily missed. Surface as a [security] line in the install footer so
# users who are likely to be affected see it during upgrade rather than
# discovering it later.
#
# Affected range encoding: a simple lexical-by-component check. Matches
# 1.29.x, 1.30.x, 1.31.x, 1.32.x, 1.33.0, 1.33.1, 1.33.2 — and excludes
# 1.33.3+ and 1.34.x+. Custom builds outside the semver shape silently
# skip — the BASH_REMATCH check below returns 1 on non-`X.Y.Z` input,
# so suffixed versions like `1.30.0-beta` and pre-tag dev strings are
# treated as out-of-range (conservative — no advisory fires).
_omc_in_affected_repro_range() {
  local v="$1"
  [[ -z "${v}" ]] && return 1
  # Must match X.Y.Z numeric.
  [[ "${v}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[2]}" pat="${BASH_REMATCH[3]}"
  # Only major=1 is relevant.
  [[ "${maj}" -eq 1 ]] || return 1
  # 1.29 to 1.32 — entire minor window.
  if [[ "${min}" -ge 29 ]] && [[ "${min}" -le 32 ]]; then return 0; fi
  # 1.33.0 to 1.33.2 inclusive.
  if [[ "${min}" -eq 33 ]] && [[ "${pat}" -le 2 ]]; then return 0; fi
  return 1
}

if [[ -n "${PRIOR_INSTALLED_VERSION}" ]] \
    && _omc_in_affected_repro_range "${PRIOR_INSTALLED_VERSION}"; then
  printf '\n'
  printf '  [security]     Upgrading from v%s — affected by the v1.34.0 omc-repro.sh advisory.\n' "${PRIOR_INSTALLED_VERSION}"
  printf '                 If you ran `omc-repro.sh` on v1.29.0–v1.33.2 AND shared the output,\n'
  printf '                 the bundled gate_events.jsonl may carry prompt-text fragments under\n'
  printf '                 state-corruption rows. Rotate or redact any tarball you have already\n'
  printf '                 shared. The cross-session ledger in this install is already scrubbed.\n'
  printf '                 See CHANGELOG.md v1.34.0 entry for full details.\n'
fi
_last_update_summary="$(TARGET_HOME="${TARGET_HOME}" \
  bash "${INSTALL_STATE_REPORT_SNAPSHOT}" \
    --last-update-summary 2>/dev/null || true)"
if [[ -n "${_last_update_summary}" ]]; then
  printf '%s\n' "${_last_update_summary}"
fi
printf '  Destination:   %s\n' "${CLAUDE_HOME}"
printf '  Backup:        %s\n' "${BACKUP_DIR}"
if [[ -d "${BUNDLE_GHOSTTY}" ]] && should_install_ghostty; then
  printf '  Ghostty:       %s\n' "${GHOSTTY_HOME}"
fi
if [[ "${BYPASS_PERMISSIONS}" == "true" ]]; then
  printf '  Permissions:   bypass-permissions mode enabled\n'
fi
if [[ -f "${CLAUDE_HOME}/oh-my-claude.conf" ]]; then
  _tier=""
  _tier_rows_seen=0
  read_last_valid_model_tier "${CLAUDE_HOME}/oh-my-claude.conf" \
    _tier _tier_rows_seen || true
  if [[ -n "${_tier}" ]]; then
    printf '  Model tier:    %s\n' "${_tier}"
  fi
fi
if [[ -f "${CLAUDE_HOME}/output-styles/oh-my-claude.md" || -f "${CLAUDE_HOME}/output-styles/executive-brief.md" ]]; then
  # Print the style that's actually active in settings.json — not the
  # bundled file's frontmatter — so the summary tells the truth under
  # output_style=preserve (where settings.json may carry a different
  # value or no value at all). Fallback chain: settings.outputStyle →
  # conf-resolved bundled file frontmatter → silent skip.
  _active_style=""
  _active_style_kind="missing"
  _active_style_note=""
  if [[ -f "${CLAUDE_HOME}/settings.json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      _active_style_kind="$(jq -r '
        if type == "object" and has("outputStyle")
        then (.outputStyle | type)
        else "missing"
        end
      ' "${CLAUDE_HOME}/settings.json" 2>/dev/null || printf invalid)"
      if [[ "${_active_style_kind}" == "string" ]]; then
        _active_style="$(jq -r '.outputStyle' \
          "${CLAUDE_HOME}/settings.json" 2>/dev/null || true)"
      fi
    elif command -v python3 >/dev/null 2>&1; then
      _active_style_kind="$(python3 - "${CLAUDE_HOME}/settings.json" <<'PY' 2>/dev/null || printf invalid
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
if not isinstance(data, dict) or "outputStyle" not in data:
    print("missing")
elif data["outputStyle"] is None:
    print("null")
elif isinstance(data["outputStyle"], str):
    print("string")
elif isinstance(data["outputStyle"], bool):
    print("boolean")
elif isinstance(data["outputStyle"], list):
    print("array")
elif isinstance(data["outputStyle"], dict):
    print("object")
elif isinstance(data["outputStyle"], (int, float)):
    print("number")
else:
    print("unknown")
PY
)"
      if [[ "${_active_style_kind}" == "string" ]]; then
        _active_style="$(python3 - "${CLAUDE_HOME}/settings.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as handle:
    value = json.load(handle)["outputStyle"]
sys.stdout.write(value)
PY
)"
      fi
    fi
  fi
  case "${_active_style_kind}" in
    object|array|number|boolean)
      _active_style_note="preserved non-string settings.outputStyle (${_active_style_kind}); bundled fallback not selected"
      ;;
    string)
      if [[ -z "${_active_style}" ]]; then
        _active_style_note="preserved empty settings.outputStyle string; bundled fallback not selected"
      fi
      ;;
  esac
  if [[ "${_active_style_kind}" == "missing" \
      || "${_active_style_kind}" == "null" \
      || "${_active_style_kind}" == "invalid" ]]; then
    case "${OMC_OUTPUT_STYLE_PREF:-opencode}" in
      executive) _fallback_style_file="${CLAUDE_HOME}/output-styles/executive-brief.md" ;;
      *)         _fallback_style_file="${CLAUDE_HOME}/output-styles/oh-my-claude.md" ;;
    esac
    if [[ -f "${_fallback_style_file}" ]]; then
      _active_style="$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}' "${_fallback_style_file}" 2>/dev/null || true)"
      if [[ -n "${_active_style}" && "${OMC_OUTPUT_STYLE_PREF:-opencode}" == "preserve" ]]; then
        _active_style="${_active_style} (bundle file; settings.json untouched per output_style=preserve)"
      fi
    fi
  fi
  if [[ -n "${_active_style_note}" ]]; then
    printf '  Output style:  %s\n' "${_active_style_note}"
  elif [[ -n "${_active_style}" ]]; then
    printf '  Output style:  %s\n' "${_active_style}"
    # Onboarding nudge: when the active style is the default oh-my-claude,
    # mention the executive-brief alternative once. Skipped under preserve
    # (the user has already chosen) and on executive (already on the
    # alternative). Single line so it does not dominate the summary.
    case "${_active_style}" in
      "oh-my-claude")
        printf '                 Tip: try the executive-brief style for CEO-grade status reports — `/omc-config` → cluster 5, or set output_style=executive in oh-my-claude.conf and re-run install.\n'
        ;;
    esac
  fi
fi

# Orphan warning: surface files that were in a prior bundle but removed
# in this release. These linger in ~/.claude/ because rsync -a has no
# --delete flag (removing --delete would wipe user-created files too).
if [[ "${orphan_count}" -gt 0 ]]; then
  printf '\n'
  printf '  Orphans:       %d file(s) from a prior release remain in %s\n' "${orphan_count}" "${CLAUDE_HOME}"
  printf '                 (rsync preserves them; the new bundle no longer ships them):\n'
  printf '%s' "${orphan_list}"
  printf '                 Review and delete manually, or run:\n'
  printf '                   bash %s/uninstall.sh && bash %s/install.sh\n' "${SCRIPT_DIR}" "${SCRIPT_DIR}"
fi

printf '\n'
# v1.31.0 Wave 5 (visual-craft F-6 partial): TTY-guard the bold escape
# so log-redirected installs (`bash install.sh > install.log`) get
# plain text instead of literal `\033[1m...`. NO_COLOR env honored
# per the de-facto convention.
# v1.36.x W4 F-018: collapse the post-install staircase. Pre-fix the
# footer named four "Then:" steps + a --bypass-permissions tip, all
# competing for first-action attention. The growth funnel narrowed
# significantly when users had to choose between Verify / Configure /
# Demo / Real work — most picked Real work, skipped the demo, and
# never felt the gates fire on a controlled fixture. The single
# canonical next-action is /ulw-demo: it's the highest-leverage
# activation moment, and Configure / Verify / Real work are all best
# discovered AFTER the demo (the demo's epilogue routes there).
#
# v1.44.x install-outcome report: same-version reinstalls after doc-only
# pulls can leave the managed installed bytes AND settings.json unchanged.
# In that case, forcing a restart is wrong noise. The footer branches on
# last-install-report.json's computed restart_required signal.
if [[ "${restart_required_json}" == "true" ]]; then
  _restart_guidance="$(TARGET_HOME="${TARGET_HOME}" \
    bash "${INSTALL_STATE_REPORT_SNAPSHOT}" \
      --restart-guidance 2>/dev/null || true)"
  if [[ -n "${_restart_guidance}" ]]; then
    printf '%s\n' "${_restart_guidance}"
  fi
  printf '\n'
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    printf 'Then run \033[1m/ulw-demo\033[0m in the new Claude Code session — under 2 minutes,\n'
  else
    printf 'Then run /ulw-demo in the new Claude Code session — under 2 minutes,\n'
  fi
  printf '  it fires real gates on a throwaway file in /tmp so you can see the harness\n'
  printf '  work end-to-end. Its closing card routes you to /omc-config (settings) and\n'
  printf '  /ulw <task> (real work) when you are ready.\n'
  printf '\n'
  if [[ "${BYPASS_PERMISSIONS}" != "true" ]]; then
    printf 'After the demo confirms the harness is firing, re-run with --bypass-permissions\n'
    printf "to skip Claude Code's per-tool prompts. Quality gates apply either way.\n"
  fi
else
  _restart_guidance="$(TARGET_HOME="${TARGET_HOME}" \
    bash "${INSTALL_STATE_REPORT_SNAPSHOT}" \
      --restart-guidance 2>/dev/null || true)"
  if [[ -n "${_restart_guidance}" ]]; then
    printf '%s\n' "${_restart_guidance}"
  fi
  printf '  If you only pulled docs or other non-installed repo files, you can keep working.\n'
fi
printf '\n'
printf 'Recovery if something feels off: bash %s/verify.sh\n' "${SCRIPT_DIR}"

# Backup pruning is intentionally post-commit: deleting older recovery
# generations is irreversible and therefore cannot happen while an install
# rollback still promises exact pre-install restoration. A prune failure is a
# maintenance warning, not a failed install.
if ! prune_old_backups; then
  printf '  [warn] Backup retention cleanup was incomplete; installed generation is committed.\n' >&2
fi
