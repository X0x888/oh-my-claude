#!/usr/bin/env bash
# rolling_avg — integer average of the arguments, built on window_sum.
# Requires lib/sum.sh to be sourced first.

rolling_avg() {
  local total
  total="$(window_sum "$@")"
  printf '%s\n' "$(( total / $# ))"
}
