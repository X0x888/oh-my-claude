#!/usr/bin/env bash
#
# SessionStart welcome banner — closes the v1.29.0 growth-lens P0-3
# silent-dropoff trap.
#
# The most common post-install failure mode is "user installed (or
# updated) oh-my-claude, but did not restart Claude Code." Hooks fire
# from `~/.claude/settings.json` at session-start time; a session that
# was already running before the install has the OLD settings.json
# loaded, so `/ulw` and the gates appear inert. Without a signal, the
# user concludes the harness "doesn't work" and walks away.
#
# This hook fires once per fresh install on the user's first new session
# AFTER an install (or update) and surfaces a one-line greeting in
# `additionalContext` recommending `/ulw-demo` (90 s, on a throwaway
# file) as the value-delivery moment.
#
# Idempotency rules:
#   1. Per-install one-shot via `${HOME}/.claude/.welcome-shown-at`. The
#      file stores the install-stamp epoch the welcome was last keyed
#      against; the hook re-emits only when `.install-stamp` is newer
#      (next install / update / reinstall). After the user has seen the
#      banner once, subsequent SessionStart hooks for the same install
#      generation are silent.
#   2. Per-session AND pre-prompt: skips when `recent_prompts.jsonl`
#      exists for the new session — by definition the user has already
#      typed at least one prompt and the harness is visibly active.
#   3. Per-session via `welcome_banner_emitted=1` in session state, so
#      a SessionStart fired multiple times for the same SESSION_ID
#      (e.g., resume + clear) does not re-emit.
#
# Privacy: the hook reads only the install-stamp's mtime + the active
# version. No prompt text is read or written; no cross-session lift.
# Respects `prompt_persist=off` trivially (does not touch persistence).
#
# Soft-failure throughout: never blocks Stop, never propagates non-zero.

set -euo pipefail

HOOK_JSON="$(cat)"

. "${HOME}/.claude/skills/autowork/scripts/common.sh"

SESSION_ID="$(json_get '.session_id')"
SOURCE="$(json_get '.source')"

if [[ -z "${SESSION_ID}" ]]; then
  exit 0
fi

ensure_session_dir

# v1.32.8: tag the session with project_key BEFORE any record_gate_event
# call so the sweep aggregator at common.sh:1193 can correctly tag
# cross-session telemetry rows for multi-project /ulw-report slicing.
# Pre-1.32.8 this only fired in the ULW path (router-side); non-ULW
# sessions (welcome banner / resume hint only) recorded gate events
# tagged project_key=null. Helper is first-write-wins; cheap on rerun.
record_project_key_if_unset

# Per-session idempotency. A second SessionStart in the same session
# (resume → compact → clear) skips trivially — the banner is a
# first-impression surface, not a recurring one.
if [[ "$(read_state "welcome_banner_emitted")" == "1" ]]; then
  exit 0
fi

# Per-session pre-prompt gate. If the user has already typed at least
# one prompt in this SESSION_ID, the harness is visibly active and
# the banner would be redundant noise.
recent_prompts_file="$(session_file "recent_prompts.jsonl")"
if [[ -f "${recent_prompts_file}" ]]; then
  exit 0
fi

# Per-install gate. The welcome banner exists to detect the
# install-without-restart trap. Without a fresh `.install-stamp`,
# either the user is on an old session that pre-dates any install
# (no harness loaded → this hook isn't even running) or they have
# already seen the banner for this install generation.
install_stamp="${HOME}/.claude/.install-stamp"
if [[ ! -f "${install_stamp}" ]]; then
  # No install-stamp at all — partial install, custom build, or a test
  # rig. Emit silently and let the user discover other surfaces.
  exit 0
fi

# Read install-stamp mtime. Two-hop stat (BSD then GNU) per the
# project's portability rule (v1.28.0 lessons).
install_ts="$(_lock_mtime "${install_stamp}")"
if [[ -z "${install_ts}" || "${install_ts}" -le 0 ]]; then
  exit 0
fi

welcome_marker="${HOME}/.claude/.welcome-shown-at"
if [[ -f "${welcome_marker}" ]]; then
  shown_ts="$(cat "${welcome_marker}" 2>/dev/null || echo "")"
  # Validate the marker is numeric — same defensive shape as
  # sweep_stale_sessions's marker guard (v1.30.0 Wave 3 / sre F-3).
  # On corrupt content: reset and re-emit (defensive against partial
  # writes from a crashed prior emit).
  if [[ "${shown_ts}" =~ ^[0-9]+$ ]] && [[ "${shown_ts}" -ge "${install_ts}" ]]; then
    exit 0
  fi
fi

# Active version — read from oh-my-claude.conf (last set by install.sh)
# rather than the bundled VERSION file, so the banner matches what was
# actually installed even if the user has the source repo on a newer
# branch.
version=""
if [[ -f "${HOME}/.claude/oh-my-claude.conf" ]]; then
  version="$(grep -E '^installed_version=' "${HOME}/.claude/oh-my-claude.conf" 2>/dev/null \
    | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
fi
if [[ -z "${version}" ]]; then
  version="(unknown)"
fi

# v1.31.0 Wave 5 (visual-craft F-2): card framing matches the install
# footer cadence — leading box-rule head, bold CTA, dim minor line,
# plain disclaimer. Pre-Wave-5 was 5 plain-text paragraphs with no
# visual hierarchy; the FIRST surface the user sees after install
# read like an email signature. Now reads as a coherent activation
# card. Box-rule glyph (─) is the canonical card head adopted across
# /ulw-time, /ulw-status --explain, and the install footer.
#
# Banner content. Five lines: box-rule head + CTA-bold + minor + minor
# + footer disclaimer. Bold + dim ANSI emitted only when stdout is a
# TTY (TTY-guarded; would otherwise leak literal `\033[1m` to log
# redirects). Same TTY guard as install.sh:1234.
banner_head="─── oh-my-claude v${version} active ───"
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  cta_open=$'\033[1m'
  cta_close=$'\033[0m'
  dim_open=$'\033[2m'
  dim_close=$'\033[0m'
else
  cta_open=""
  cta_close=""
  dim_open=""
  dim_close=""
fi
_omc_user_override_count=0
if [[ -f "${HOME}/.claude/oh-my-claude.conf" ]]; then
  # Append `|| true` to swallow pipeline-fail under set -e -o pipefail:
  # the inner `grep -vE` exits non-zero when zero lines match (e.g.,
  # a fresh install where the conf only contains auto-set keys), which
  # would otherwise abort the whole hook before the banner emits.
  _omc_user_override_count="$(grep -E '^[a-z_]+=' "${HOME}/.claude/oh-my-claude.conf" 2>/dev/null \
    | grep -vE '^(repo_path|installed_version|installed_sha|model_tier|output_style)=' \
    | wc -l | tr -d '[:space:]' || true)"
  [[ "${_omc_user_override_count}" =~ ^[0-9]+$ ]] || _omc_user_override_count=0
fi

if [[ "${_omc_user_override_count}" -eq 0 ]]; then
  _omc_profile_line="${dim_open}Profile: maximum defaults — gates fire loudly, directives are broad. Run \`/omc-config\` to switch profile (Balanced / Minimal) or tune individual flags.${dim_close}"
else
  _omc_profile_line="${dim_open}Profile: ${_omc_user_override_count} flag override(s) active. Run \`/omc-config\` to inspect or change.${dim_close}"
fi

banner="${banner_head}

${cta_open}You're now running oh-my-claude v${version}.${cta_close} The install completed and Claude Code reloaded the hooks for this fresh session — quality gates are active.

To see the harness work end-to-end (about 90 seconds, on a throwaway file in /tmp):

  ${cta_open}/ulw-demo${cta_close}

Or jump straight to your real work with \`/ulw <task>\`. Run \`/omc-config\` to inspect or change settings.

${_omc_profile_line}

${dim_open}This banner shows once per fresh install or update; silent on subsequent sessions until you re-run install.sh.${dim_close}"

payload="$(jq -nc --arg context "${banner}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}' 2>/dev/null || true)"

if [[ -z "${payload}" ]]; then
  log_anomaly "session-start-welcome" "failed to compose payload"
  exit 0
fi

# Stamp BOTH idempotency surfaces before printing. On a partial-write
# crash mid-emit, the user re-reads the banner once on the next session
# (acceptable noise floor; alternative is risking a never-shown banner).
write_state "welcome_banner_emitted" "1"
printf '%s\n' "${install_ts}" > "${welcome_marker}" 2>/dev/null || true

record_gate_event "session-start-welcome" "banner-emitted" \
  source="${SOURCE:-unknown}" \
  install_ts="${install_ts}" \
  version="${version}"

log_hook "session-start-welcome" "emitted version=${version} install_ts=${install_ts}"

printf '%s\n' "${payload}"
