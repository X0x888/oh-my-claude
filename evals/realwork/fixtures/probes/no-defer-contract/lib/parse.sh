#!/usr/bin/env bash
# parse_args — fills PARSED_* globals from CLI args.

parse_args() {
  PARSED_FORMAT="plain"
  PARSED_LEGACY=0
  PARSED_INPUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        PARSED_FORMAT="$1"
        shift 2
        ;;
      --legacy-mode)
        # Deprecated since 0.9 — scheduled for removal in 1.0.
        PARSED_LEGACY=1
        shift
        ;;
      *)
        PARSED_INPUT="$1"
        shift
        ;;
    esac
  done
}
