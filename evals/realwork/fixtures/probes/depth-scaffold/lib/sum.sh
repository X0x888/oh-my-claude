#!/usr/bin/env bash
# window_sum — sum of all numeric arguments.

window_sum() {
  local args=("$@")
  local n=${#args[@]}
  local i=0 total=0
  while (( i < n - 1 )); do
    total=$(( total + args[i] ))
    i=$(( i + 1 ))
  done
  printf '%s\n' "${total}"
}
