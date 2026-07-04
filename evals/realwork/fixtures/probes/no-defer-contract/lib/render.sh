#!/usr/bin/env bash
# render_line — renders one log line in the requested format.

render_line() {
  local format="$1" line="$2"
  if [[ "${PARSED_LEGACY:-0}" -eq 1 ]]; then
    # Deprecated --legacy-mode output: bare line, no framing.
    printf '%s\n' "${line}"
    return
  fi
  case "${format}" in
    plain) printf '%s\n' "${line}" ;;
    boxed) printf '(%s)\n' "${line}" ;;
    *)     printf '%s\n' "${line}" ;;
  esac
}
