#!/usr/bin/env bash
#
# tools/render-release-title.sh — canonical GitHub release title renderer.

set -euo pipefail

VERSION_ARG=""
CHANGELOG_PATH="${OMC_RELEASE_CHANGELOG_PATH:-CHANGELOG.md}"

usage() {
  cat <<'EOF'
Usage: bash tools/render-release-title.sh X.Y.Z

Renders the canonical GitHub release title for vX.Y.Z by extracting the
first meaningful summary block from the matching CHANGELOG.md section.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      printf 'render-release-title: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${VERSION_ARG}" ]]; then
        VERSION_ARG="$1"
        shift
      else
        printf 'render-release-title: unexpected positional arg: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "${VERSION_ARG}" ]] || { usage >&2; exit 2; }
[[ "${VERSION_ARG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'render-release-title: version must be X.Y.Z, got: %s\n' "${VERSION_ARG}" >&2
  exit 2
}

[[ -f "${CHANGELOG_PATH}" ]] || {
  printf 'render-release-title: CHANGELOG not found at %s\n' "${CHANGELOG_PATH}" >&2
  exit 1
}

release_notes="$(awk "/^## \\[${VERSION_ARG}\\]/{found=1;next} /^## \\[/{if(found)exit} found" "${CHANGELOG_PATH}")"
[[ -n "${release_notes}" ]] || {
  printf 'render-release-title: no CHANGELOG section found for v%s\n' "${VERSION_ARG}" >&2
  exit 1
}

normalize_candidate() {
  local candidate="$1"
  candidate="$(printf '%s' "${candidate}" | perl -0pe '
    s/\r//g;
    s/\x{2013}|\x{2014}/ — /g;
    s/^\s*#+\s*//;
    s/^\s*[-*]\s+//;
    s/^\s*>\s*//;
    s/\[([^\]]+)\]\([^)]+\)/$1/g;
    s/`([^`]+)`/$1/g;
    s/\*\*([^*]+)\*\*/$1/g;
    s/__([^_]+)__/$1/g;
    s/\*([^*]+)\*/$1/g;
    s/\s+/ /g;
    s/^\s+|\s+$//g;
  ')"
  candidate="$(printf '%s' "${candidate}" | env VERSION_FOR_PERL="${VERSION_ARG}" perl -0pe '
    my $v = $ENV{VERSION_FOR_PERL};
    s{^[A-Za-z0-9._/-]+\.(?:md|sh|json|py|txt|ya?ml|toml|js|ts|tsx|jsx|rb|go|rs|swift|java|kt)\s+}{};
    s{^[A-Za-z0-9._/-]+\.(?:md|sh|json|py|txt|ya?ml|toml|js|ts|tsx|jsx|rb|go|rs|swift|java|kt)\s+(?:\x{2014}|-)\s+}{};
    s{^[A-Za-z0-9._/-]+/[A-Za-z0-9._/-]+\s+(?:\x{2014}|-)\s+}{};
    s{^(?:T[0-9]+|F-[0-9]+|G[0-9]+|R[0-9]+)\s+}{};
    s{^(?:T[0-9]+|F-[0-9]+|G[0-9]+|R[0-9]+|Wave[ -]\d+(?:/\d+)?)\s*(?::|\x{2014}|-)\s*}{};
    s{^Wave[ -]\d+(?:/\d+)?\s+}{};
    s{^v\Q$v\E\s+candidate set\s+(?:\x{2014}|-)\s+}{};
    s{^v\Q$v\E\s*(?::|\x{2014}|-)\s+}{};
    s{^v\Q$v\E\s*\((.*)\)$}{$1};
    s{^User commissioned (?:a|an)\s+}{};
    s{^A user reported that\s+}{};
    s{^(?:\x{2014}|-)\s+}{};
    s{\s+\(v[0-9][^)]+\)$}{};
    s/\s+/ /g;
    s/^\s+|\s+$//g;
  ')"
  case "${candidate}" in
    "v${VERSION_ARG} candidate set — "*) candidate="${candidate#v${VERSION_ARG} candidate set — }" ;;
    "v${VERSION_ARG} candidate set - "*) candidate="${candidate#v${VERSION_ARG} candidate set - }" ;;
    "V${VERSION_ARG} candidate set — "*) candidate="${candidate#V${VERSION_ARG} candidate set — }" ;;
    "V${VERSION_ARG} candidate set - "*) candidate="${candidate#V${VERSION_ARG} candidate set - }" ;;
  esac
  candidate="${candidate#— }"
  candidate="${candidate#- }"
  printf '%s' "${candidate}"
}

is_generic_heading() {
  case "$1" in
    Added|Fixed|Changed|Removed|Deprecated|Security|Triage\ outcome:|Triage\ outcome)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

shorten_summary() {
  local summary="$1"
  local cut=""

  if [[ ${#summary} -gt 72 && "${summary}" == *" + "* ]]; then
    cut="${summary%% + *}"
    [[ ${#cut} -ge 24 ]] && summary="${cut}"
  fi
  if [[ ${#summary} -gt 72 && "${summary}" == *". "* ]]; then
    cut="${summary%%. *}"
    [[ ${#cut} -ge 24 ]] && summary="${cut}"
  fi
  if [[ ${#summary} -gt 72 && "${summary}" == *" ("* ]]; then
    cut="${summary%% (*}"
    [[ ${#cut} -ge 24 ]] && summary="${cut}"
  fi
  if [[ ${#summary} -gt 72 && "${summary}" == *", "* ]]; then
    cut="${summary%%, *}"
    [[ ${#cut} -ge 24 ]] && summary="${cut}"
  fi
  if [[ ${#summary} -gt 88 ]]; then
    summary="$(printf '%s' "${summary}" | perl -0pe 's/^(.{0,88})\b.*/$1/; s/\s+$//')"
    summary="${summary}..."
  fi
  summary="$(printf '%s' "${summary}" | perl -0pe 's/:\s*$//; s/\s+$//; s/^([a-z])/\U$1/')"
  printf '%s' "${summary}"
}

summary=""
current_block=""
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ -z "${line//[[:space:]]/}" ]]; then
    if [[ -n "${current_block}" ]]; then
      candidate="$(normalize_candidate "${current_block}")"
      if [[ -n "${candidate}" ]] && ! is_generic_heading "${candidate}"; then
        summary="${candidate}"
        break
      fi
      current_block=""
    fi
    continue
  fi

  if [[ "${line}" =~ ^#[#[:space:]] ]]; then
    if [[ -n "${current_block}" ]]; then
      candidate="$(normalize_candidate "${current_block}")"
      if [[ -n "${candidate}" ]] && ! is_generic_heading "${candidate}"; then
        summary="${candidate}"
        break
      fi
      current_block=""
    fi
    candidate="$(normalize_candidate "${line}")"
    if [[ -n "${candidate}" ]] && ! is_generic_heading "${candidate}"; then
      summary="${candidate}"
      break
    fi
    continue
  fi

  if [[ -z "${current_block}" ]]; then
    current_block="${line}"
  else
    current_block="${current_block} ${line}"
  fi
done <<< "${release_notes}"

if [[ -z "${summary}" && -n "${current_block}" ]]; then
  candidate="$(normalize_candidate "${current_block}")"
  if [[ -n "${candidate}" ]] && ! is_generic_heading "${candidate}"; then
    summary="${candidate}"
  fi
fi

if [[ -z "${summary}" ]]; then
  printf 'v%s\n' "${VERSION_ARG}"
  exit 0
fi

printf 'v%s — %s\n' "${VERSION_ARG}" "$(shorten_summary "${summary}")"
