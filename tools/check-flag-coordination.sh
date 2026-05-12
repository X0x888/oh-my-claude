#!/usr/bin/env bash
#
# tools/check-flag-coordination.sh — audit the three flag-definition
# SoT sites for parity. Catches the most-violated CLAUDE.md
# coordination rule programmatically: when a flag exists in one
# site but not the others, the parser/example/omc-config trio
# silently drifts (flag undiscoverable, silently ignored, or
# unsettable via /omc-config).
#
# Sites audited:
#   1. bundle/dot-claude/skills/autowork/scripts/common.sh
#      — _parse_conf_file() case-statement clauses (the parser)
#   2. bundle/dot-claude/oh-my-claude.conf.example
#      — `#flag_name=value` documented entries
#   3. bundle/dot-claude/skills/autowork/scripts/omc-config.sh
#      — emit_known_flags() table rows
#
# Exit codes:
#   0 — all three sites in lockstep (or the only-statusline-flag
#       exemption applies, e.g. installation_drift_check which is
#       Python-side only)
#   1 — drift detected (sites enumerate different flag sets)
#   2 — a SoT site is missing or unparseable
#
# Run from repo root: `bash tools/check-flag-coordination.sh`
# Wired into CI via .github/workflows/validate.yml.
#
# v1.40.x abstraction-critic F-014: partial closure of the
# flags.yml codegen finding. Codegen is deferred; this audit
# script is the smallest shippable form — catches drift
# automatically. A future v1.41 PR can promote flags.yml as the
# single source and generate the three sites; this audit script
# becomes its post-codegen verification check.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_SH="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/common.sh"
CONF_EXAMPLE="${REPO_ROOT}/bundle/dot-claude/oh-my-claude.conf.example"
OMC_CONFIG="${REPO_ROOT}/bundle/dot-claude/skills/autowork/scripts/omc-config.sh"

# Flags exempt from the canonical _parse_conf_file() case statement.
# These read their value via a separate path (statusline.py for Python-side
# flags; grep-based parse in common.sh for install-time-only flags) and
# are intentionally not in the case statement. When this set grows,
# append here AND in the corresponding non-parser path's comment.
PARSER_EXEMPT_FLAGS=(
  installation_drift_check
  model_tier
)

for f in "${COMMON_SH}" "${CONF_EXAMPLE}" "${OMC_CONFIG}"; do
  if [[ ! -f "${f}" ]]; then
    printf 'error: SoT site missing: %s\n' "${f}" >&2
    exit 2
  fi
done

# Parser flags — every clause in _parse_conf_file's case statement.
parser_flags="$(awk '
  /^_parse_conf_file\(\)/ { in_fn = 1; next }
  in_fn && /^}$/ { in_fn = 0; next }
  in_fn && /^[[:space:]]+[a-z_]+\)/ {
    sub(/^[[:space:]]+/, "")
    sub(/\).*/, "")
    print
  }
' "${COMMON_SH}" | sort -u)"

# Example template — every documented `#flag_name=...` line.
example_flags="$(grep -E '^#[a-z_]+=' "${CONF_EXAMPLE}" 2>/dev/null \
  | sed -E 's/^#([a-z_]+)=.*/\1/' | sort -u)"

# omc-config table — emit_known_flags() embeds a heredoc with rows
# of the shape `flag_name|type|default|category|description`. Extract
# each row's flag_name (the first pipe-separated field).
omc_flags="$(awk '
  /^emit_known_flags\(\)/ { in_fn = 1; next }
  in_fn && /^EOF$/ { exit }
  in_fn && /^[a-z_]+\|/ {
    sub(/\|.*/, "")
    print
  }
' "${OMC_CONFIG}" | sort -u)"

# Strip parser-exempt flags from sets where parser is one side of the
# comparison — those flags are intentionally absent from the canonical
# parser path and present in example + omc-config.
exempt_pattern=""
for f in "${PARSER_EXEMPT_FLAGS[@]}"; do
  exempt_pattern="${exempt_pattern:+${exempt_pattern}|}^${f}\$"
done

filter_parser_exempt() {
  if [[ -n "${exempt_pattern}" ]]; then
    grep -vE "${exempt_pattern}" || true
  else
    cat
  fi
}

# Compute pairwise drift.
parser_only="$(comm -23 <(printf '%s\n' "${parser_flags}") <(printf '%s\n' "${example_flags}"))"
example_only="$(comm -13 <(printf '%s\n' "${parser_flags}") <(printf '%s\n' "${example_flags}") | filter_parser_exempt)"
parser_vs_omc_only="$(comm -23 <(printf '%s\n' "${parser_flags}") <(printf '%s\n' "${omc_flags}"))"
omc_vs_parser_only="$(comm -13 <(printf '%s\n' "${parser_flags}") <(printf '%s\n' "${omc_flags}") | filter_parser_exempt)"

has_drift=0
if [[ -n "${parser_only}" ]]; then
  printf 'DRIFT: flags in parser but NOT in oh-my-claude.conf.example:\n%s\n' "${parser_only}" | sed 's/^/  /'
  has_drift=1
fi
if [[ -n "${example_only}" ]]; then
  printf 'DRIFT: flags in oh-my-claude.conf.example but NOT in parser:\n%s\n' "${example_only}" | sed 's/^/  /'
  has_drift=1
fi
if [[ -n "${parser_vs_omc_only}" ]]; then
  printf 'DRIFT: flags in parser but NOT in omc-config.sh emit_known_flags:\n%s\n' "${parser_vs_omc_only}" | sed 's/^/  /'
  has_drift=1
fi
if [[ -n "${omc_vs_parser_only}" ]]; then
  printf 'DRIFT: flags in omc-config.sh but NOT in parser:\n%s\n' "${omc_vs_parser_only}" | sed 's/^/  /'
  has_drift=1
fi

parser_count="$(printf '%s\n' "${parser_flags}" | grep -c . || true)"
example_count="$(printf '%s\n' "${example_flags}" | grep -c . || true)"
omc_count="$(printf '%s\n' "${omc_flags}" | grep -c . || true)"

if [[ "${has_drift}" -eq 0 ]]; then
  printf 'flag coordination OK: parser=%d · example=%d · omc-config=%d (parser-exempt: %d)\n' \
    "${parser_count}" "${example_count}" "${omc_count}" "${#PARSER_EXEMPT_FLAGS[@]}"
  exit 0
fi

printf '\nFix: update ALL three SoT sites in the same commit when adding/removing/renaming a flag.\n'
printf 'See CLAUDE.md "Coordination Rules — keep in lockstep" → flag rule.\n'
exit 1
