#!/usr/bin/env bash

set -euo pipefail

STATE_ROOT="${HOME}/.claude/quality-pack/state"
STATE_JSON="session_state.json"

read_hook_json() {
  cat
}

json_get() {
  local query="$1"
  jq -r "${query} // empty" <<<"${HOOK_JSON}"
}

ensure_session_dir() {
  mkdir -p "${STATE_ROOT}/${SESSION_ID}"
}

session_file() {
  printf '%s/%s/%s\n' "${STATE_ROOT}" "${SESSION_ID}" "$1"
}

# --- P2: JSON-backed state ---

write_state() {
  local key="$1"
  local value="$2"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  if [[ ! -f "${state_file}" ]]; then
    printf '{}\n' >"${state_file}"
  fi

  jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${state_file}" >"${temp_file}" \
    && mv "${temp_file}" "${state_file}" \
    || rm -f "${temp_file}"
}

write_state_batch() {
  if [[ $(( $# % 2 )) -ne 0 ]]; then
    printf 'write_state_batch: odd number of arguments (%d)\n' "$#" >&2
    return 1
  fi

  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local temp_file
  temp_file="$(mktemp "${state_file}.XXXXXX")"

  if [[ ! -f "${state_file}" ]]; then
    printf '{}\n' >"${state_file}"
  fi

  local jq_filter="."
  local args=()
  local idx=0

  while [[ $# -ge 2 ]]; do
    args+=(--arg "k${idx}" "$1" --arg "v${idx}" "$2")
    jq_filter="${jq_filter} | .[(\$k${idx})] = \$v${idx}"
    shift 2
    idx=$((idx + 1))
  done

  jq "${args[@]}" "${jq_filter}" "${state_file}" >"${temp_file}" \
    && mv "${temp_file}" "${state_file}" \
    || rm -f "${temp_file}"
}

append_state() {
  local key="$1"
  local value="$2"
  printf '%s\n' "${value}" >>"$(session_file "${key}")"
}

append_limited_state() {
  local key="$1"
  local value="$2"
  local max_lines="${3:-20}"
  local target
  local temp

  target="$(session_file "${key}")"
  temp="${target}.tmp"

  printf '%s\n' "${value}" >>"${target}"
  tail -n "${max_lines}" "${target}" >"${temp}" 2>/dev/null || cp "${target}" "${temp}"
  mv "${temp}" "${target}"
}

read_state() {
  local key="$1"
  local state_file
  state_file="$(session_file "${STATE_JSON}")"
  local result=""

  if [[ -f "${state_file}" ]]; then
    result="$(jq -r --arg k "${key}" '.[$k] // empty' "${state_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${result}" ]]; then
    printf '%s' "${result}"
    return
  fi

  # Fallback: individual file (backwards compat or JSON key missing)
  cat "$(session_file "${key}")" 2>/dev/null || true
}

# --- end P2 ---

now_epoch() {
  date +%s
}

# --- State directory TTL sweep ---
# Deletes session state dirs older than 7 days. Runs at most once per day,
# gated by a marker file timestamp.

sweep_stale_sessions() {
  local marker="${STATE_ROOT}/.last_sweep"
  local now
  now="$(date +%s)"

  # Skip if swept within the last 24 hours
  if [[ -f "${marker}" ]]; then
    local last_sweep
    last_sweep="$(cat "${marker}" 2>/dev/null || echo 0)"
    if [[ $(( now - last_sweep )) -lt 86400 ]]; then
      return
    fi
  fi

  # Sweep directories older than 7 days (exclude dotfiles like .ulw_active, .last_sweep)
  if [[ -d "${STATE_ROOT}" ]]; then
    find "${STATE_ROOT}" -maxdepth 1 -type d -mtime +7 \
      ! -name '.' ! -name '..' ! -name '.*' ! -path "${STATE_ROOT}" \
      -exec rm -rf {} + 2>/dev/null || true
  fi

  printf '%s\n' "${now}" > "${marker}"
}

# --- end TTL sweep ---

is_maintenance_prompt() {
  local text="$1"
  [[ "${text}" =~ ^[[:space:]]*/(compact|clear|resume|memory|hooks|config|help|permissions|model|doctor|status)([[:space:]]|$) ]]
}

truncate_chars() {
  local limit="$1"
  local text="$2"

  if [[ "${#text}" -le "${limit}" ]]; then
    printf '%s' "${text}"
    return
  fi

  printf '%s...' "${text:0:limit}"
}

trim_whitespace() {
  local text="$1"

  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"

  printf '%s' "${text}"
}

normalize_task_prompt() {
  local text="$1"
  local changed=1
  local nocasematch_was_set=0

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  while [[ "${changed}" -eq 1 ]]; do
    changed=0

    if [[ "${text}" =~ ^[[:space:]]*/?(ulw|autowork|ultrawork|sisyphus)[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[2]}"
      changed=1
      continue
    fi

    if [[ "${text}" =~ ^[[:space:]]*ultrathink[[:space:]]*(.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      changed=1
    fi
  done

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  printf '%s' "${text}"
}

is_continuation_request() {
  local text="$1"
  local normalized
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1
  if [[ "${normalized}" =~ ^[[:space:]]*((continue|resume)([[:space:]]+(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off))?|carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))([[:space:][:punct:]].*)?$ ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

extract_continuation_directive() {
  local text="$1"
  local normalized
  local remainder=""
  local nocasematch_was_set=0

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if shopt -q nocasematch; then
    nocasematch_was_set=1
  fi

  shopt -s nocasematch

  if [[ "${normalized}" =~ ^(continue|resume)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[2]}"
    if [[ "${remainder}" =~ ^(the[[:space:]]+previous[[:space:]]+task|from[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off|where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
      remainder="${BASH_REMATCH[2]}"
    fi
  elif [[ "${normalized}" =~ ^(carry[[:space:]]+on|keep[[:space:]]+going|pick[[:space:]]+(it|this)[[:space:]]+back[[:space:]]+up|pick[[:space:]]+up[[:space:]]+where[[:space:]]+you[[:space:]]+left[[:space:]]+off)[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[3]}"
  elif [[ "${normalized}" =~ ^(next|go[[:space:]]+on|proceed|finish[[:space:]]+the[[:space:]]+rest|do[[:space:]]+the[[:space:]]+(remaining[[:space:]]+(work|items|tasks)|rest))[[:space:]]*(.*)$ ]]; then
    remainder="${BASH_REMATCH[4]}"
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then
    shopt -u nocasematch
  fi

  remainder="$(trim_whitespace "${remainder}")"
  remainder="${remainder#[,:;.-]}"
  remainder="$(trim_whitespace "${remainder}")"

  printf '%s' "${remainder}"
}

workflow_mode() {
  read_state "workflow_mode"
}

is_ultrawork_mode() {
  [[ "$(workflow_mode)" == "ultrawork" ]]
}

task_domain() {
  read_state "task_domain"
}

is_internal_claude_path() {
  local path="$1"

  [[ -z "${path}" ]] && return 1

  case "${path}" in
    "${HOME}/.claude/projects/"*|\
    "${HOME}/.claude/quality-pack/state/"*|\
    "${HOME}/.claude/tasks/"*|\
    "${HOME}/.claude/todos/"*|\
    "${HOME}/.claude/transcripts/"*|\
    "${HOME}/.claude/debug/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_checkpoint_request() {
  local text="$1"

  grep -Eiq '\b(checkpoint|pause here|stop here|for now|continue later|pick up later|resume later|for this session|one wave at a time|one phase at a time|wave [0-9]+ only|phase [0-9]+ only|first wave only|first phase only|just wave [0-9]+|just phase [0-9]+)\b' <<<"${text}"
}

is_session_management_request() {
  local text="$1"

  grep -Eiq '\b(new session|fresh session|same session|this session|continue here|continue in this session|stop here|pause here|resume later|pick up later|context budget|context window|context limit|usage limit|token limit|limit hit|compaction|compact)\b' <<<"${text}" \
    && grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\b|worth\b|prefer\b|advice\b|suggest\b)' <<<"${text}"
}

is_advisory_request() {
  local text="$1"

  grep -Eiq '(^[[:space:]]*(should|would|could|can|is|do|what|which|why)\b|\?|better\b|recommend\b|worth\b|prefer\b|advice\b|suggest\b|tradeoff\b|tradeoffs\b|pros and cons\b|should we\b|would it be better\b|is it better\b|do you think\b)' <<<"${text}"
}

# --- P0: Imperative detection (checked before advisory in classify_task_intent) ---

is_imperative_request() {
  local text="$1"
  local nocasematch_was_set=0

  if shopt -q nocasematch; then nocasematch_was_set=1; fi
  shopt -s nocasematch

  local result=1

  # "Can/Could/Would you [verb]..." — polite imperatives
  if [[ "${text}" =~ ^[[:space:]]*(can|could|would)[[:space:]]+you[[:space:]]+(please[[:space:]]+)?(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|set[[:space:]]+up|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|review|start|stop|enable|disable|open|close) ]]; then
    result=0
  # "Please [verb]..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*(please)[[:space:]]+(fix|implement|add|create|build|update|refactor|debug|deploy|test|write|make|change|modify|remove|delete|move|rename|install|configure|check|run|help|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|proceed|go) ]]; then
    result=0
  # "Go ahead and..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*go[[:space:]]+ahead ]]; then
    result=0
  # "I need/want you to..." patterns
  elif [[ "${text}" =~ ^[[:space:]]*i[[:space:]]+(need|want)[[:space:]]+(you[[:space:]]+to|to)[[:space:]] ]]; then
    result=0
  # Bare imperative: starts with unambiguous action verb, no trailing question mark
  # Excludes: check, test, help, review — too ambiguous as bare starts
  elif [[ ! "${text}" =~ \?[[:space:]]*$ ]] && [[ "${text}" =~ ^[[:space:]]*(fix|implement|add|create|build|update|refactor|debug|deploy|write|make|change|modify|remove|delete|move|rename|install|configure|run|handle|resolve|convert|migrate|optimize|improve|rewrite|restructure|integrate|connect|push|pull|merge|commit|start|stop|enable|disable|open|close|set[[:space:]]+up|proceed)[[:space:]] ]]; then
    result=0
  fi

  if [[ "${nocasematch_was_set}" -eq 0 ]]; then shopt -u nocasematch; fi
  return "${result}"
}

# --- end P0 ---

has_unfinished_session_handoff() {
  local text="$1"

  grep -Eiq '\b(ready for a new session|ready for another session|continue in a new session|continue in another session|new session\b|another session\b|next wave\b|next phase\b|wave [0-9]+[^.!\n]* is next|phase [0-9]+[^.!\n]* is next|remaining work\b|the rest\b|pick up .* later|continue .* later)\b' <<<"${text}"
}

# --- P1: Scoring-based domain classification ---

count_keyword_matches() {
  local pattern="$1"
  local text="$2"
  { grep -oEi "${pattern}" <<<"${text}" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

infer_domain() {
  local text="$1"

  local coding_score
  local writing_score
  local research_score
  local operations_score

  local coding_strong
  coding_strong=$(count_keyword_matches '\b(bugs?|fix(es|ed|ing)?|debug(ging)?|refactor(ing)?|implement(ation|ed|ing)?|repos?(itory)?|function|class(es)?|component|endpoints?|apis?|schema|database|quer(y|ies)|migration|lint(ing)?|compile|tsc|typescript|javascript|python|swift|xcode|react|next\.?js|css|html|webhooks?|codebase|source.?code|ci/?cd|docker|container|backend|frontend|fullstack)\b' "${text}")
  coding_strong=${coding_strong:-0}

  local coding_weak
  coding_weak=$(count_keyword_matches '\b(tests?|build|scripts?|config(uration)?|hooks?|deploy(ed|ing|ment)?|server)\b' "${text}")
  coding_weak=${coding_weak:-0}

  # Weak coding keywords only count when a strong signal is present,
  # OR when 3+ weak signals cluster together (multiple weak = strong).
  if [[ "${coding_strong}" -gt 0 ]]; then
    coding_score=$((coding_strong + coding_weak))
  elif [[ "${coding_weak}" -ge 3 ]]; then
    coding_score="${coding_weak}"
  else
    coding_score=0
  fi

  writing_score=$(count_keyword_matches '\b(paper|draft(ing)?|essay|article|report|proposal|email|memo|letter|statement|abstract|introduction|conclusion|outline|rewrite|polish(ing)?|paragraph|manuscript|cover.?letter|sop|personal.?statement|blog|post)\b' "${text}")
  writing_score=${writing_score:-0}

  research_score=$(count_keyword_matches '\b(research(ing)?|investigate|investigation|analy(sis|ze|zing)|compare|comparison|survey|literature|sources|citations?|references?|benchmark(ing)?|brief(ing)?|recommendation|summarize|summary|pros.?and.?cons|tradeoffs?|audit(ing)?|assess(ment|ing)?|evaluat(e|ion|ing)|inspect(ion|ing)?)\b' "${text}")
  research_score=${research_score:-0}

  operations_score=$(count_keyword_matches '\b(plan(ning)?|roadmap|timeline|agenda|meeting|follow[- ]?up|checklist|prioriti(es|se|ze)|project.?plan|travel.?plan|itinerary|reply(ing)?|respond(ing)?|application|submission)\b' "${text}")
  operations_score=${operations_score:-0}

  local max_score=0
  local primary_domain="general"

  if [[ "${coding_score}" -gt "${max_score}" ]]; then
    max_score="${coding_score}"
    primary_domain="coding"
  fi
  if [[ "${writing_score}" -gt "${max_score}" ]]; then
    max_score="${writing_score}"
    primary_domain="writing"
  fi
  if [[ "${research_score}" -gt "${max_score}" ]]; then
    max_score="${research_score}"
    primary_domain="research"
  fi
  if [[ "${operations_score}" -gt "${max_score}" ]]; then
    max_score="${operations_score}"
    primary_domain="operations"
  fi

  if [[ "${max_score}" -eq 0 ]]; then
    printf '%s\n' "general"
    return
  fi

  # Mixed: requires coding involvement with a second significant domain
  if [[ "${coding_score}" -gt 0 ]]; then
    local second_max=0
    if [[ "${primary_domain}" == "coding" ]]; then
      for s in "${writing_score}" "${research_score}" "${operations_score}"; do
        [[ "${s}" -gt "${second_max}" ]] && second_max="${s}"
      done
    else
      second_max="${coding_score}"
    fi
    if [[ "${second_max}" -gt 0 && "${max_score}" -gt 0 ]] \
      && [[ "$(( second_max * 100 / max_score ))" -ge 40 ]]; then
      printf '%s\n' "mixed"
      return
    fi
  fi

  printf '%s\n' "${primary_domain}"
}

# --- end P1 ---

classify_task_intent() {
  local text="$1"
  local normalized

  normalized="$(normalize_task_prompt "${text}")"
  normalized="$(trim_whitespace "${normalized}")"

  if [[ -z "${normalized}" ]]; then
    printf '%s\n' "execution"
    return
  fi

  if is_continuation_request "${text}"; then
    printf '%s\n' "continuation"
  elif is_checkpoint_request "${normalized}"; then
    printf '%s\n' "checkpoint"
  elif is_session_management_request "${normalized}"; then
    printf '%s\n' "session_management"
  elif is_imperative_request "${normalized}"; then
    printf '%s\n' "execution"
  elif is_advisory_request "${normalized}"; then
    printf '%s\n' "advisory"
  else
    printf '%s\n' "execution"
  fi
}

is_execution_intent_value() {
  local intent="$1"

  case "${intent}" in
    execution|continuation)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
