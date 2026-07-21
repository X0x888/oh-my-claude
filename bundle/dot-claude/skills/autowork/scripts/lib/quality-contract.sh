# shellcheck shell=bash
# quality-contract.sh — Definition of Excellent decision and validation module.
#
# Sourced after common.sh. The module deliberately performs no top-level work
# and owns no hook wiring; callers decide when to persist the canonical JSON it
# returns. All model-authored semantic data is validated before an authoritative
# causal envelope can be built around it.
#
# Public API:
#   quality_contract_should_arm MODE INTENT RISK BROAD EXPLICIT
#   quality_contract_arm_decision_json MODE INTENT RISK BROAD EXPLICIT
#   quality_contract_extract_json MESSAGE
#   quality_review_extract_json MESSAGE
#   quality_contract_validate_payload JSON
#   quality_contract_canonicalize_payload JSON
#   quality_contract_validate_profile_bindings DEFINITION [REQUIRED_IDS_JSON]
#       [HISTORICAL_PROFILE_STANDARDS_JSON]
#   quality_contract_build_envelope DEFINITION CYCLE OBJECTIVE_TS PROMPT_REV
#       OBJECTIVE_DIGEST ENFORCEMENT_GENERATION PLAN_REV CREATED_TS
#       PLANNER_AGENT NATIVE_AGENT_ID LIFECYCLE_DISPATCH_ID [CONTRACT_REV]
#   quality_contract_validate_envelope JSON
#   quality_contract_canonicalize_envelope JSON
#   quality_contract_revision_preserves_floor NEW_DEFINITION OLD_ENVELOPE
#       [live|intrinsic]
#   quality_contract_validate_current [CONTRACT_FILE]
#   quality_review_validate_payload JSON
#   quality_review_canonicalize_payload JSON
#   quality_review_validate_against_contract REVIEW CONTRACT VERDICT
#   quality_contract_gate_status_json [CONTRACT_FILE] [EVIDENCE_FILE] [FRONTIER_FILE]
#   quality_contract_router_summary MODE INTENT RISK BROAD EXPLICIT
#   quality_contract_status_summary [CONTRACT_FILE] [EVIDENCE_FILE] [FRONTIER_FILE]
#
# Required common.sh dependencies:
#   read_state, session_file, _omc_authority_digest, truncate_chars,
#   is_zero_steering_policy_enabled (or OMC_QUALITY_POLICY fallback).

_quality_contract_bool() {
  case "${1:-}" in
    1|true|on|yes) printf '1' ;;
    *) printf '0' ;;
  esac
}

_quality_contract_zero_steering() {
  if declare -F is_zero_steering_policy_enabled >/dev/null 2>&1; then
    is_zero_steering_policy_enabled
  else
    [[ "${OMC_QUALITY_POLICY:-balanced}" == "zero_steering" ]]
  fi
}

quality_contract_should_arm() {
  local mode="${1:-${OMC_DEFINITION_OF_EXCELLENT:-adaptive}}"
  local intent="${2:-}" risk="${3:-low}"
  local broad explicit
  broad="$(_quality_contract_bool "${4:-0}")"
  explicit="$(_quality_contract_bool "${5:-0}")"

  case "${intent}" in
    execution|continuation) ;;
    *) return 1 ;;
  esac

  case "${mode}" in
    off) return 1 ;;
    always) return 0 ;;
    adaptive) ;;
    *) mode="adaptive" ;;
  esac

  _quality_contract_zero_steering && return 0
  [[ "${explicit}" == "1" || "${broad}" == "1" ]] && return 0
  case "${risk}" in
    medium|high|critical) return 0 ;;
  esac
  return 1
}

quality_contract_arm_decision_json() {
  local mode="${1:-${OMC_DEFINITION_OF_EXCELLENT:-adaptive}}"
  local intent="${2:-}" risk="${3:-low}"
  local broad explicit required=false reason="low-risk-narrow"
  broad="$(_quality_contract_bool "${4:-0}")"
  explicit="$(_quality_contract_bool "${5:-0}")"

  case "${mode}" in
    adaptive|always|off) ;;
    *) mode="adaptive" ;;
  esac

  if [[ "${intent}" != "execution" && "${intent}" != "continuation" ]]; then
    reason="non-execution-intent"
  elif [[ "${mode}" == "off" ]]; then
    reason="configured-off"
  elif [[ "${mode}" == "always" ]]; then
    required=true; reason="configured-always"
  elif _quality_contract_zero_steering; then
    required=true; reason="zero-steering-promotion"
  elif [[ "${explicit}" == "1" ]]; then
    required=true; reason="explicit-excellence-mandate"
  elif [[ "${broad}" == "1" ]]; then
    required=true; reason="broad-scope"
  elif [[ "${risk}" == "medium" || "${risk}" == "high" || "${risk}" == "critical" ]]; then
    required=true; reason="${risk}-risk"
  fi

  jq -cnS \
    --arg mode "${mode}" --arg intent "${intent}" --arg risk "${risk}" \
    --arg reason "${reason}" --argjson required "${required}" \
    --argjson broad "${broad}" --argjson explicit "${explicit}" \
    '{_v:1,required:$required,reason:$reason,mode:$mode,intent:$intent,
      risk:$risk,broad_scope:($broad == 1),explicit_mandate:($explicit == 1)}'
}

_quality_contract_extract_marker_raw() {
  local message="${1:-}" marker="${2:-}" kind="${3:-}"
  local normalized marker_count tail line1 line2 line3 candidate json
  [[ -n "${message}" && -n "${marker}" ]] || return 1
  normalized="$(printf '%s\n' "${message}" | tr -d '\r')"
  marker_count="$(printf '%s\n' "${normalized}" | awk -v p="${marker}: " \
    'index($0,p) == 1 { n++ } END { print n + 0 }')"
  [[ "${marker_count}" == "1" ]] || return 1

  tail="$(printf '%s\n' "${normalized}" | awk '
    NF { a=b; b=c; c=$0 }
    END { print a; print b; print c }
  ')"
  line1="$(printf '%s\n' "${tail}" | sed -n '1p')"
  line2="$(printf '%s\n' "${tail}" | sed -n '2p')"
  line3="$(printf '%s\n' "${tail}" | sed -n '3p')"

  case "${kind}" in
    contract)
      [[ "${line3}" =~ ^VERDICT:[[:space:]]*PLAN_READY[[:space:]]*$ ]] || return 1
      ;;
    review)
      [[ "${line3}" =~ ^VERDICT:[[:space:]]*(CLEAN|SHIP|FINDINGS[[:space:]]*\([[:space:]]*[1-9][0-9]*[[:space:]]*\)|BLOCK[[:space:]]*\([[:space:]]*[1-9][0-9]*[[:space:]]*\))[[:space:]]*$ ]] || return 1
      ;;
    *) return 1 ;;
  esac

  if [[ "${line2}" =~ ^REVIEW_DISPATCH_ID:[[:space:]]*[A-Za-z0-9][A-Za-z0-9._-]{0,63}[[:space:]]*$ ]]; then
    candidate="${line1}"
  else
    candidate="${line2}"
  fi
  [[ "${candidate}" == "${marker}: "* ]] || return 1
  json="${candidate#"${marker}: "}"
  [[ -n "${json}" && ${#json} -le 32768 ]] || return 1
  # The structural marker is intentionally one physical line. Reject literal
  # C0 controls even if jq would otherwise accept an escaped representation.
  [[ "${json}" != *$'\n'* && "${json}" != *$'\r'* ]] || return 1
  jq -e 'type == "object"' <<<"${json}" >/dev/null 2>&1 || return 1
  printf '%s' "${json}"
}

quality_contract_extract_json() {
  local raw
  raw="$(_quality_contract_extract_marker_raw "${1:-}" \
    "QUALITY_CONTRACT_JSON" "contract")" || return 1
  quality_contract_canonicalize_payload "${raw}"
}

quality_review_extract_json() {
  local raw
  raw="$(_quality_contract_extract_marker_raw "${1:-}" \
    "QUALITY_REVIEW_JSON" "review")" || return 1
  quality_review_canonicalize_payload "${raw}"
}

_quality_contract_mcp_kind_for_classifier() {
  case "${1:-}" in
    browser_visual_check) printf 'render' ;;
    browser_dom_check|browser_console_check|browser_network_check|browser_eval_check|visual_check|custom_mcp_tool)
      printf 'inspection' ;;
    *) return 1 ;;
  esac
}

_quality_contract_verification_threshold() {
  local threshold="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
  _omc_canonical_uint_in_range "${threshold}" 0 100 || threshold=40
  printf '%s' "${threshold}"
}

# Contract feasibility must use evidence a tool can honestly produce, not the
# largest score arbitrary text could trick the generic scorer into awarding.
# For observational MCP calls, only the empty-result base score is guaranteed.
# UI context is contingent session history, not a property of the frozen proof
# language, so it cannot make an otherwise unreachable contract feasible. In
# particular, neither an earlier UI edit nor words such as "3 tests passed" in
# a filename/wrapper message may turn a passive observation into a certifying
# proof language at plan time.
_quality_contract_mcp_confidence_feasible() {
  local verify_type="${1:-}" threshold="${2:-}" score
  [[ -n "${verify_type}" ]] || return 1
  score="$(score_mcp_verification_confidence \
    "${verify_type}" "" "false" 2>/dev/null || true)"
  if ! _omc_canonical_uint_in_range "${threshold}" 0 100; then
    threshold="$(_quality_contract_verification_threshold)"
  fi
  [[ "${score}" =~ ^[0-9]+$ && "${score}" -ge "${threshold}" ]]
}

_quality_contract_tool_possible_kinds() {
  local pattern="${1:-}" threshold="${2:-}" verify_type="" candidate="" kinds=""
  if ! _omc_canonical_uint_in_range "${threshold}" 0 100; then
    threshold="$(_quality_contract_verification_threshold)"
  fi
  case "${pattern}" in
    Bash) printf 'test benchmark comparison render inspection'; return 0 ;;
    Read)
      [[ 70 -ge "${threshold}" ]] || return 1
      printf 'source'; return 0
      ;;
    Grep)
      [[ 70 -ge "${threshold}" ]] || return 1
      printf 'inspection'; return 0
      ;;
    mcp__*) ;;
    *) return 1 ;;
  esac

  if [[ "${pattern}" == *'*' ]]; then
    local candidates=(
      "mcp__plugin_playwright_playwright__browser_snapshot"
      "mcp__plugin_playwright_playwright__browser_take_screenshot"
      "mcp__plugin_playwright_playwright__browser_console_messages"
      "mcp__plugin_playwright_playwright__browser_network_requests"
      "mcp__plugin_playwright_playwright__browser_evaluate"
      "mcp__plugin_playwright_playwright__browser_run_code"
      "mcp__computer-use__screenshot"
    )
    for candidate in "${candidates[@]}"; do
      # shellcheck disable=SC2254
      case "${candidate}" in ${pattern}) ;;
        *) continue ;;
      esac
      # Classification alone is not receipt admission. A connector call whose
      # operation can mutate (notably Playwright evaluate/run_code) is consumed
      # by the edit clock and record-verification deliberately mints no receipt.
      # It therefore cannot make a frozen proof language feasible.
      if mcp_tool_attempts_artifact_mutation "${candidate}" '{}'; then
        continue
      fi
      verify_type="$(classify_mcp_verification_tool "${candidate}" 2>/dev/null || true)"
      _quality_contract_mcp_confidence_feasible \
        "${verify_type}" "${threshold}" || continue
      candidate="$(_quality_contract_mcp_kind_for_classifier \
        "${verify_type}" 2>/dev/null || true)"
      [[ -n "${candidate}" && " ${kinds} " != *" ${candidate} "* ]] \
        && kinds="${kinds:+${kinds} }${candidate}"
    done
  else
    mcp_tool_attempts_artifact_mutation "${pattern}" '{}' && return 1
    verify_type="$(classify_mcp_verification_tool "${pattern}" 2>/dev/null || true)"
    _quality_contract_mcp_confidence_feasible \
      "${verify_type}" "${threshold}" || return 1
    kinds="$(_quality_contract_mcp_kind_for_classifier \
      "${verify_type}" 2>/dev/null || true)"
  fi
  [[ -n "${kinds}" ]] || return 1
  printf '%s' "${kinds}"
}

_quality_contract_known_mcp_candidates() {
  local pattern="${1:-}" candidate
  [[ "${pattern}" == mcp__* ]] || return 1
  local candidates=(
    "mcp__plugin_playwright_playwright__browser_snapshot"
    "mcp__plugin_playwright_playwright__browser_take_screenshot"
    "mcp__playwright__browser_snapshot"
    "mcp__playwright__browser_take_screenshot"
    "mcp__plugin_playwright_playwright__browser_console_messages"
    "mcp__plugin_playwright_playwright__browser_network_requests"
    "mcp__plugin_playwright_playwright__browser_evaluate"
    "mcp__plugin_playwright_playwright__browser_run_code"
    "mcp__computer-use__screenshot"
  )
  if [[ "${pattern}" != *'*' ]]; then
    for candidate in "${candidates[@]}"; do
      [[ "${candidate}" == "${pattern}" ]] \
        && { printf '%s\n' "${candidate}"; return 0; }
    done
    return 1
  fi
  for candidate in "${candidates[@]}"; do
    # shellcheck disable=SC2254
    case "${candidate}" in ${pattern}) printf '%s\n' "${candidate}" ;; esac
  done
}

# A frozen MCP target must be constructible from the concrete tool's declared
# input schema and the recorder's exact descriptor grammar. Both supported
# Playwright observations expose a root `target` scalar; the recorder persists
# that as `target=<value>`. Output-derived `observed_url` is deliberately not a
# feasibility witness because connector configuration can suppress that output.
# Unknown/custom connectors may still mint ordinary verification receipts, but
# without a declared schema they cannot freeze target-bound proof.
_quality_contract_mcp_candidate_target_key() {
  case "${1:-}" in
    mcp__plugin_playwright_playwright__browser_snapshot|\
    mcp__plugin_playwright_playwright__browser_take_screenshot|\
    mcp__playwright__browser_snapshot|\
    mcp__playwright__browser_take_screenshot)
      printf 'target' ;;
    *) return 1 ;;
  esac
}

# `observed_url` is extracted from result text, not tool input. Freeze it only
# for operations whose result schema exposes the current Page URL. Playwright's
# DOM snapshot does; browser_take_screenshot returns image/path output and
# therefore cannot construct this descriptor reliably.
_quality_contract_mcp_candidate_supports_observed_url() {
  case "${1:-}" in
    mcp__plugin_playwright_playwright__browser_snapshot|\
    mcp__playwright__browser_snapshot)
      return 0 ;;
    *) return 1 ;;
  esac
}

_quality_contract_mcp_target_witness() {
  local criterion="${1:-}" candidate="${2:-}" key anchor normalized value witness
  local encoded_value=""
  local anchor_key="" count="" target_descriptor="" route_descriptor=""
  key="$(_quality_contract_mcp_candidate_target_key \
    "${candidate}" 2>/dev/null || true)"
  [[ -n "${key}" ]] || return 1
  count="$(jq -r '.proof_spec.artifact_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${count}" == "1" || "${count}" == "2" ]] || return 1
  while IFS= read -r anchor; do
    normalized="$(printf '%s' "${anchor}" \
      | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ "${normalized}" =~ ^([A-Za-z0-9_.-]+)=(.*)$ ]] || return 1
    anchor_key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Leading/trailing selector whitespace is not an independent browser
    # target. Canonicalize it exactly as the recorder does before encoding.
    value="$(printf '%s' "${value}" \
      | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    anchor_key="$(printf '%s' "${anchor_key}" \
      | tr '[:upper:]' '[:lower:]')"
    [[ -n "${value}" && ${#value} -le 240 ]] || return 1
    encoded_value="$(_verification_descriptor_encode_value \
      "${value}" 2>/dev/null || true)"
    [[ -n "${encoded_value}" && ${#encoded_value} -le 240 ]] || return 1
    case "${anchor_key}" in
      "${key}")
        [[ -z "${target_descriptor}" ]] || return 1
        if [[ "${key}" =~ ^(url|page_url)$ \
            && "${value}" == http*://* ]]; then
          _verification_url_is_canonical "${value}" || return 1
        fi
        target_descriptor="${key}=${encoded_value}"
        ;;
      observed_url)
        [[ -z "${route_descriptor}" \
            && "${value}" =~ ^https?://[^[:space:]]+$ ]] || return 1
        _quality_contract_mcp_candidate_supports_observed_url \
          "${candidate}" || return 1
        _verification_url_is_canonical "${value}" || return 1
        route_descriptor="observed_url=${encoded_value}"
        ;;
      *) return 1 ;;
    esac
  done < <(jq -r '.proof_spec.artifact_contains[]' <<<"${criterion}")
  [[ -n "${target_descriptor}" ]] || return 1
  witness="${target_descriptor}${route_descriptor:+;${route_descriptor}}"
  printf '%s' "${witness}"
}

_quality_contract_mcp_candidate_satisfies() {
  local criterion="${1:-}" candidate="${2:-}" threshold="${3:-}"
  local verify_type kind requested anchor
  local candidate_lower anchor_lower target_witness
  [[ "${candidate}" == mcp__* && "${candidate}" != *'*' ]] || return 1
  mcp_tool_attempts_artifact_mutation "${candidate}" '{}' && return 1
  verify_type="$(classify_mcp_verification_tool "${candidate}" 2>/dev/null || true)"
  [[ -n "${verify_type}" ]] || return 1
  _quality_contract_mcp_confidence_feasible \
    "${verify_type}" "${threshold}" || return 1
  kind="$(_quality_contract_mcp_kind_for_classifier "${verify_type}" 2>/dev/null || true)"
  requested="$(jq -r '.proof_spec.receipt_kinds[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ -n "${kind}" && "${kind}" == "${requested}" ]] || return 1
  # Screenshot render proof binds decoded PNG pixels, not a success sentence.
  # Do not freeze an impossible visual criterion on hosts without the bounded
  # CRC/zlib/scanline decoder used by record-verification.
  if [[ "${kind}" == "render" ]]; then
    verification_png_decoder_available || return 1
  fi

  # MCP receipts persist `tool_name[ target-descriptor]`. Command anchors are
  # therefore constructive only when the concrete tool identity itself carries
  # them; target language belongs in artifact_contains. Allowing arbitrary
  # command tokens to borrow the descriptor admitted exact and wildcard proof
  # specs that no concrete connector schema could necessarily produce.
  candidate_lower="$(printf '%s' "${candidate}" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r anchor; do
    [[ -n "${anchor}" ]] || continue
    anchor_lower="$(printf '%s' "${anchor}" | tr '[:upper:]' '[:lower:]')"
    [[ "${candidate_lower}" == *"${anchor_lower}"* ]] || return 1
  done < <(jq -r '.proof_spec.command_contains[]' <<<"${criterion}")

  target_witness="$(_quality_contract_mcp_target_witness \
    "${criterion}" "${candidate}" 2>/dev/null || true)"
  [[ -n "${target_witness}" ]] || return 1
  return 0
}

_quality_contract_mcp_proof_feasible() {
  [[ -n "$(_quality_contract_mcp_proof_target_witness \
    "${1:-}" "${2:-}" 2>/dev/null || true)" ]]
}

_quality_contract_mcp_proof_target_witness() {
  local criterion="${1:-}" threshold="${2:-}" pattern candidate saw=0
  local verify_type="" target_witness=""
  pattern="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${pattern}" == mcp__* ]] || return 1
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    saw=1
    if _quality_contract_mcp_candidate_satisfies \
        "${criterion}" "${candidate}" "${threshold}"; then
      verify_type="$(classify_mcp_verification_tool \
        "${candidate}" 2>/dev/null || true)"
      target_witness="$(_quality_contract_mcp_target_witness \
        "${criterion}" "${candidate}" 2>/dev/null || true)"
      [[ -n "${verify_type}" && -n "${target_witness}" ]] || return 1
      printf 'mcp:%s:%s' "${verify_type}" "${target_witness}"
      return 0
    fi
  done < <(_quality_contract_known_mcp_candidates "${pattern}" 2>/dev/null || true)
  [[ "${saw}" -eq 1 ]] || return 1
  return 1
}

_quality_contract_mcp_pattern_matches_candidate() {
  local pattern="${1:-}" candidate="${2:-}"
  [[ "${pattern}" == mcp__* && "${candidate}" == mcp__* ]] || return 1
  # shellcheck disable=SC2254
  case "${candidate}" in ${pattern}) return 0 ;; esac
  return 1
}

# Return success when one concrete observational call could satisfy both
# criteria. Exact-one receipt admission makes such a pair impossible to
# certify: a route-bound receipt also contains its selector-only descriptor,
# so command-label differences cannot create independent proof surfaces on the
# same concrete connector operation.
_quality_contract_mcp_criteria_overlap() {
  local left="${1:-}" right="${2:-}" threshold="${3:-}"
  local left_pattern right_pattern candidate left_descriptor right_descriptor
  local left_target right_target left_route="" right_route=""
  left_pattern="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${left}" 2>/dev/null || true)"
  right_pattern="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${right}" 2>/dev/null || true)"
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    _quality_contract_mcp_pattern_matches_candidate \
      "${right_pattern}" "${candidate}" || continue
    _quality_contract_mcp_candidate_satisfies \
      "${left}" "${candidate}" "${threshold}" || continue
    _quality_contract_mcp_candidate_satisfies \
      "${right}" "${candidate}" "${threshold}" || continue
    left_descriptor="$(_quality_contract_mcp_target_witness \
      "${left}" "${candidate}" 2>/dev/null || true)"
    right_descriptor="$(_quality_contract_mcp_target_witness \
      "${right}" "${candidate}" 2>/dev/null || true)"
    [[ -n "${left_descriptor}" && -n "${right_descriptor}" ]] || continue
    left_target="${left_descriptor%%;*}"
    right_target="${right_descriptor%%;*}"
    [[ "${left_target}" == "${right_target}" ]] || continue
    left_route=""
    right_route=""
    case "${left_descriptor}" in
      *';observed_url='*) left_route="${left_descriptor#*;observed_url=}" ;;
    esac
    case "${right_descriptor}" in
      *';observed_url='*) right_route="${right_descriptor#*;observed_url=}" ;;
    esac
    # With a shared selector, absent route language is a subset of any route;
    # two explicit routes overlap only when they are exactly the same.
    if [[ -z "${left_route}" || -z "${right_route}" \
        || "${left_route}" == "${right_route}" ]]; then
      return 0
    fi
  done < <(_quality_contract_known_mcp_candidates \
    "${left_pattern}" 2>/dev/null || true)
  return 1
}

_quality_contract_bash_proof_feasible() {
  [[ -n "$(_quality_contract_bash_target_witness \
    "${1:-}" 2>/dev/null || true)" ]]
}

_quality_contract_bash_targets_overlap() {
  local left="${1:-}" right="${2:-}" family="" left_scope="" right_scope=""
  [[ -n "${left}" && -n "${right}" ]] || return 1
  [[ "${left}" == "${right}" ]] && return 0
  # Opaque/custom and formerly collapsed families bind normalized suffix argv
  # into receipt identity, but argv variation cannot manufacture independent
  # criteria over one verifier-owned scope. Compare the scope surface before
  # the policy suffix when freezing cross-criterion overlap.
  left_scope="${left%%|policy=*}"
  right_scope="${right%%|policy=*}"
  [[ "${left_scope}" == "${right_scope}" ]] && return 0
  for family in pytest vitest jest cargo-test go-test shellcheck; do
    if { [[ "${left_scope}" == "${family}" \
            && "${right_scope}" == "${family}:"* ]] \
        || [[ "${right_scope}" == "${family}" \
            && "${left_scope}" == "${family}:"* ]]; }; then
      return 0
    fi
  done
  return 1
}

_quality_contract_bash_candidate_rank() {
  local candidate="${1:-}" target="${2:-}" first="" family="" script=""
  _verification_tokenize_argv "${candidate}" 2>/dev/null || return 1
  _verification_strip_literal_env_prefix 2>/dev/null || return 1
  first="${_VERIFICATION_ARGV[0]:-}"
  family="$(_verification_executable_family_name \
    "${first}" 2>/dev/null || true)"
  [[ -n "${family}" ]] || return 1

  # Structured runner targets are stronger witnesses than treating a selector
  # such as tests/test_alpha.py as a directly executed named verifier. Within
  # custom executables, an explicit path is stronger than a coincidentally
  # installed bare command named `benchmark` or `comparison`. Ambiguity is only
  # meaningful between equally credible executable interpretations.
  case "${target}" in
    executable:*)
      if [[ "${family}" == "bash" || "${family}" == "zsh" \
          || "${family}" == "sh" ]]; then
        script="${_VERIFICATION_ARGV[1]:-}"
        [[ "${script}" == "-n" ]] && script="${_VERIFICATION_ARGV[2]:-}"
      else
        script="${first}"
      fi
      case "${script}" in */*|.*) printf '3' ;; *) printf '2' ;; esac
      ;;
    *) printf '4' ;;
  esac
}

# Return one semantic execution target that can satisfy the criterion's frozen
# Bash substrings. The receipt layer deduplicates by this target, not by opaque
# argv, so a contract that assigns `check.sh Q-001` through `Q-005` to five
# criteria can never be completed honestly. Try each frozen anchor as the
# command-leading token while retaining every other required substring; this
# proves existence without evaluating model-authored shell text.
_quality_contract_bash_target_witness() {
  local criterion="${1:-}" count idx candidate target candidate_rank=0
  local requested_kind="" project_test_cmd="" scope="" method=""
  local observed_kind="" confidence="" threshold="${2:-}" output_witness=""
  local candidate_output="" semantic_surface="" launcher_witness=""
  local subject_witness=""
  local first_anchor=""
  local -a candidate_variants=()
  local best_target="" best_rank=0
  requested_kind="$(jq -r '.proof_spec.receipt_kinds[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "$(jq -r '.proof_spec.artifact_contains | length' \
      <<<"${criterion}" 2>/dev/null || true)" == "0" ]] || return 1
  case "${requested_kind}" in
    test|benchmark|comparison|render|inspection) ;;
    *) return 1 ;;
  esac
  count="$(jq -r '.proof_spec.command_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || return 1
  project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  case "${requested_kind}" in
    benchmark) output_witness='1 benchmark completed; exit code: 0' ;;
    comparison) output_witness='1 comparison matched; 0 differences; exit code: 0' ;;
    render) output_witness='render: 1 image produced; artifact: proof.png; exit code: 0' ;;
    inspection) output_witness='inspection: 1 check passed; exit code: 0' ;;
    *) output_witness='1 test passed; exit code: 0' ;;
  esac
  if ! _omc_canonical_uint_in_range "${threshold}" 0 100; then
    threshold="$(_quality_contract_verification_threshold)"
  fi
  for ((idx=0; idx<count; idx++)); do
    candidate="$(jq -r --argjson idx "${idx}" '
      .proof_spec.command_contains as $a
      | [$a[$idx]] + [range(0; ($a | length)) as $i
          | select($i != $idx) | $a[$i]] | join(" ")
    ' <<<"${criterion}" 2>/dev/null || true)"
    [[ -n "${candidate}" ]] || continue
    candidate_variants=("${candidate}")
    first_anchor="${candidate%% *}"
    case "${first_anchor}" in
      *.sh) candidate_variants+=("bash ${candidate}") ;;
    esac
    for candidate in "${candidate_variants[@]}"; do
      # Score and freeze the same concrete, non-evaluated argv witness.
      # Prefixing an unrelated detected project test can make an opaque anchor
      # language look reachable even though its own executable can never cross
      # the gate. `bash` is admitted only as the launcher of that exact .sh
      # anchor and therefore preserves its semantic target.
      [[ ${#candidate} -le 500 ]] || continue
      verification_command_is_authoritative_execution \
        "${candidate}" "${project_test_cmd}" || continue
      # Module execution has authority-bearing package bytes beyond the
      # interpreter, but the observer deliberately refuses to execute import
      # resolution while freezing provenance. Do not freeze a criterion whose
      # only witness can never produce a subject-bound receipt.
      if _verification_parse_interpreter_subject "${candidate}" \
          && [[ "${_VERIFICATION_INTERPRETER_SUBJECT_KIND:-}" == "module" ]]; then
        continue
      fi
      # Freeze only a command whose exact runtime provenance surfaces can be
      # snapshotted by the same strict observers used at PreTool/PostTool. A
      # PATH symlink (or an unresolved interpreter subject) otherwise yields a
      # plausible semantic target here but can only produce a rejected receipt
      # later, making the sealed Definition impossible to complete.
      launcher_witness="$(verification_command_launcher_path \
        "${candidate}" 2>/dev/null || true)"
      [[ -n "${launcher_witness}" ]] || continue
      subject_witness="$(verification_command_subject_path \
        "${candidate}" "${PWD}" 2>/dev/null || true)"
      [[ -n "${subject_witness}" ]] || continue
      target="$(verification_command_semantic_target \
        "${candidate}" "${project_test_cmd}" 2>/dev/null || true)"
      [[ -n "${target}" ]] || continue
      semantic_surface="${target%%|policy=*}"
      candidate_output=""
      case "${semantic_surface}" in
        executable:*|package-script:*|make:*|just:*|pytest:*|pytest|vitest:*|vitest|jest:*|jest|cargo-test:*|cargo-test|go-test:*|go-test|swift-test|phpunit-suite|rspec-suite|rake-test|deno-test|bun-test|gradle-project|xcodebuild-test|maven:test|maven:verify|dotnet-test|mix-test)
          # These are either model-owned wrappers/package targets or
          # assertion runners whose successful invocation can construct the
          # result-shaped witness. Fixed silent analyzers/build validators do
          # not borrow fabricated test prose merely to cross a low threshold.
          candidate_output="${output_witness}"
          ;;
      esac
      scope="$(classify_verification_scope \
        "${candidate}" "${project_test_cmd}")"
      method="$(detect_verification_method \
        "${candidate}" "${candidate_output}" "${project_test_cmd}")"
      observed_kind="$(verification_receipt_evidence_kind \
        "${method}" "${scope}" "${candidate}" "${candidate_output}")"
      [[ "${observed_kind}" == "${requested_kind}" ]] || continue
      confidence="$(score_verification_confidence \
        "${candidate}" "${candidate_output}" \
        "${project_test_cmd}" 2>/dev/null || true)"
      [[ "${confidence}" =~ ^[0-9]+$ \
          && "${confidence}" -ge "${threshold}" ]] || continue
      candidate_rank="$(_quality_contract_bash_candidate_rank \
        "${candidate}" "${target}" 2>/dev/null || true)"
      [[ "${candidate_rank}" =~ ^[234]$ ]] || continue
      if [[ -z "${best_target}" || "${candidate_rank}" -gt "${best_rank}" ]]; then
        best_target="${target}"
        best_rank="${candidate_rank}"
      elif [[ "${candidate_rank}" -eq "${best_rank}" \
          && "${target}" != "${best_target}" ]]; then
        # `command_contains` is an unordered substring language. If two
        # equally credible executable positions are feasible, the frozen
        # criterion has no unique semantic target and runtime equality would
        # reject one honest spelling arbitrarily. Lower-ranked interpretations
        # (for example directly executing a structured runner's file selector)
        # do not make an otherwise precise criterion ambiguous.
        return 1
      fi
    done
  done
  [[ -n "${best_target}" ]] || return 1
  printf '%s' "${best_target}"
}

_quality_contract_nonbash_anchor_bounds_feasible() {
  local criterion="${1:-}" tool command_count command_joined artifact_joined
  local command_overhead union_joined canonical_root target_witness_length
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  command_count="$(jq -r '.proof_spec.command_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  command_joined="$(jq -r '
      .proof_spec.command_contains
      | if length == 0 then 0 else (map(length) | add) + length - 1 end
    ' <<<"${criterion}" 2>/dev/null || true)"
  artifact_joined="$(jq -r '
      .proof_spec.artifact_contains
      | if length == 0 then 0 else (map(length) | add) + length - 1 end
    ' <<<"${criterion}" 2>/dev/null || true)"
  union_joined="$(jq -r '
      (.proof_spec.command_contains + .proof_spec.artifact_contains | unique)
      | if length == 0 then 0 else (map(length) | add) + length - 1 end
    ' <<<"${criterion}" 2>/dev/null || true)"
  [[ "${command_count}" =~ ^[0-9]+$ && "${command_joined}" =~ ^[0-9]+$ \
      && "${artifact_joined}" =~ ^[0-9]+$ && "${union_joined}" =~ ^[0-9]+$ ]] \
    || return 1
  case "${tool}" in
    Read|Grep)
      # Source receipts contain the canonical project-root prefix whether or
      # not the planner names it. Construct a conservative, satisfiable path
      # witness by placing every distinct command/artifact anchor below that
      # root. Counting only the model-authored suffix admits contracts whose
      # final anchors are inevitably truncated from the 500-character command.
      canonical_root="$(pwd -P 2>/dev/null)" || return 1
      [[ -n "${canonical_root}" ]] || return 1
      target_witness_length=$((${#canonical_root} + 1 + union_joined))
      [[ "${target_witness_length}" -le 1000 ]] || return 1
      command_overhead=$((${#tool} + 1))
      [[ $((command_overhead + target_witness_length)) -le 500 ]] || return 1
      return 0
      ;;
    mcp__*\*) command_overhead=257 ;; # max receipt tool name plus separator
    mcp__*) command_overhead=$((${#tool} + 1)) ;;
    *) return 1 ;;
  esac
  # MCP artifact_target is independently persisted to 1000 chars. A stricter
  # per-descriptor value cap is enforced below for target-bearing MCP proof.
  [[ "${artifact_joined}" -le 1000 ]] || return 1
  # When command anchors exist, command + target anchors can share one target
  # descriptor/path. Their conservative joined witness plus the tool prefix
  # must survive the recorder's 500-character command cap.
  if [[ "${command_count}" -gt 0 ]]; then
    [[ $((command_overhead + union_joined)) -le 500 ]] || return 1
  fi
}

_quality_contract_mcp_target_anchors_feasible() {
  local criterion="${1:-}" tool artifact_count artifact_joined anchor normalized value
  local descriptor_key="" generic_value=""
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${tool}" == mcp__* ]] || return 0
  artifact_count="$(jq -r '.proof_spec.artifact_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  artifact_joined="$(jq -r '
      .proof_spec.artifact_contains
      | if length == 0 then 0 else (map(length) | add) + length - 1 end
    ' <<<"${criterion}" 2>/dev/null || true)"
  [[ "${artifact_count}" =~ ^[12]$ \
      && "${artifact_joined}" =~ ^[0-9]+$ ]] || return 1

  # The recorder truncates each URL/path/route/selector/target leaf to 240
  # characters before composing artifact_target. Requiring the whole frozen
  # target language to fit one value is constructive: there is always a
  # descriptor that can retain every required target token. The 240-byte cap
  # applies to the value, not to the complete `target=` descriptor.
  while IFS= read -r anchor; do
    normalized="$(printf '%s' "${anchor}" \
      | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    value="${normalized}"
    if [[ "${normalized}" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      descriptor_key="$(printf '%s' "${BASH_REMATCH[1]}" \
        | tr '[:upper:]' '[:lower:]')"
      case "${descriptor_key}" in
        url|page_url|path|file_path|route|endpoint|selector|locator|target|observed_url)
          value="${BASH_REMATCH[2]}" ;;
        *) return 1 ;;
      esac
    fi
    [[ ${#value} -le 240 ]] || return 1
    generic_value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
    case "${generic_value}" in
      ''|'/'|'.'|'..'|'*'|'test'|'tests'|'check'|'verify'|'verification'|\
      'comparison'|'compare'|'benchmark'|'render'|'artifact'|'output'|\
      'result'|'quality'|'current'|'all'|'ok'|'src'|'source'|'target'|\
      'url'|'path'|'route'|'selector'|'deliberate'|'distinctive'|\
      'coherent'|'visionary'|'complete') return 1 ;;
    esac
    [[ "${value}" =~ [[:alnum:]] ]] || return 1
  done < <(jq -r '.proof_spec.artifact_contains[]' <<<"${criterion}")
}

_quality_contract_canonical_source_anchors_feasible() {
  local criterion="${1:-}" tool anchor
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  case "${tool}" in
    Read|Grep)
      # Source receipts are `Tool:<canonical-target>` (plus a Grep pattern
      # truncated to 120 characters). Feasibility does not rely on that lossy
      # suffix: every frozen token must be capable of living in the canonical
      # target witness. This also closes multibyte NAME_MAX cases where a token
      # is fewer than 200 codepoints but far beyond 255 filesystem bytes.
      while IFS= read -r anchor; do
        case "${anchor}" in *'//'*|*'/../'*|*'/./'*) return 1 ;; esac
        LC_ALL=C awk -F/ '{for (i=1;i<=NF;i++) if (length($i)>255) exit 1}' \
          <<<"${anchor}" || return 1
      done < <(jq -r '.proof_spec.command_contains[]' <<<"${criterion}")
      while IFS= read -r anchor; do
        case "${anchor}" in *'//'*|*'/../'*|*'/./'*) return 1 ;; esac
        LC_ALL=C awk -F/ '{for (i=1;i<=NF;i++) if (length($i)>255) exit 1}' \
          <<<"${anchor}" || return 1
      done < <(jq -r '.proof_spec.artifact_contains[]' <<<"${criterion}")
      ;;
  esac
  return 0
}

_quality_contract_source_target_witness() {
  local criterion="${1:-}" tool="" count="" anchor="" root="" candidate=""
  local target=""
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  case "${tool}" in Read|Grep) ;; *) return 1 ;; esac
  count="$(jq -r '.proof_spec.artifact_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${count}" == "1" ]] || return 1
  anchor="$(jq -r '.proof_spec.artifact_contains[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ -n "${anchor}" ]] || return 1
  root="$(pwd -P 2>/dev/null)" || return 1
  [[ -n "${root}" ]] || return 1
  root="$(_verification_normalize_proof_path \
    "${root}" 2>/dev/null || true)"
  [[ -n "${root}" ]] || return 1
  candidate="${anchor}"
  [[ "${candidate}" == /* ]] || candidate="${root}/${candidate}"
  [[ ! -L "${candidate}" ]] || return 1
  target="$(_verification_normalize_proof_path \
    "${candidate}" 0 source 2>/dev/null || true)"
  [[ -n "${target}" && ${#target} -le 1000 ]] || return 1
  case "${target}" in "${root}"|"${root}"/*) ;; *) return 1 ;; esac
  if [[ "${tool}" == "Read" ]]; then
    [[ -f "${target}" ]] \
      && awk 'NR > 2000 || length($0) > 2000 { exit 1 }' \
        "${target}" 2>/dev/null
  else
    # Grep receipts are exact-file observations. Directory/tree searches have
    # no bounded subject identity and therefore cannot be frozen as proof.
    [[ -f "${target}" ]]
  fi || return 1
  printf '%s' "${target}"
}

_quality_contract_source_command_witness() {
  local criterion="${1:-}" target="${2:-}" tool="" command="" anchor=""
  local pattern="" lower_base="" lower_anchor="" artifact_anchor=""
  local lower_artifact_anchor=""
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ -n "${target}" ]] || target="$(_quality_contract_source_target_witness \
    "${criterion}" 2>/dev/null || true)"
  [[ -n "${target}" ]] || return 1
  command="${tool}:${target}"
  lower_base="$(printf '%s' "${command}" | tr '[:upper:]' '[:lower:]')"
  artifact_anchor="$(jq -r '.proof_spec.artifact_contains[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  lower_artifact_anchor="$(printf '%s' "${artifact_anchor}" \
    | tr '[:upper:]' '[:lower:]')"
  if [[ "${tool}" == "Grep" ]]; then
    while IFS= read -r anchor; do
      [[ -n "${anchor}" ]] || continue
      lower_anchor="$(printf '%s' "${anchor}" \
        | tr '[:upper:]' '[:lower:]')"
      if [[ "${command}" == *"${anchor}"* ]]; then
        continue
      fi
      if [[ "${tool}" != "Grep" && -n "${lower_artifact_anchor}" \
          && "${lower_anchor}" == "${lower_artifact_anchor}" \
          && "${lower_base}" == *"${lower_anchor}"* ]]; then
        continue
      fi
      pattern="${pattern:+${pattern} }${anchor}"
    done < <(jq -r '.proof_spec.command_contains[]' <<<"${criterion}")
    [[ ${#pattern} -le 120 ]] || return 1
    if [[ -n "${pattern}" ]]; then
      local regex_rc=0
      if command -v rg >/dev/null 2>&1; then
        rg --no-config -e "${pattern}" /dev/null >/dev/null 2>&1 \
          || regex_rc=$?
      else
        grep -E -e "${pattern}" /dev/null >/dev/null 2>&1 \
          || regex_rc=$?
      fi
      [[ "${regex_rc}" -ne 2 ]] || return 1
    fi
    [[ -z "${pattern}" ]] || command="${command}:${pattern}"
  fi
  while IFS= read -r anchor; do
    [[ -n "${anchor}" ]] || continue
    lower_anchor="$(printf '%s' "${anchor}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${command}" == *"${anchor}"* ]]; then
      continue
    fi
    [[ "${tool}" != "Grep" && -n "${lower_artifact_anchor}" \
        && "${lower_anchor}" == "${lower_artifact_anchor}" \
        && "${lower_base}" == *"${lower_anchor}"* ]] || return 1
  done < <(jq -r '.proof_spec.command_contains[]' <<<"${criterion}")
  if declare -F omc_redact_secrets >/dev/null 2>&1; then
    [[ "$(printf '%s' "${command}" | omc_redact_secrets)" \
        == "${command}" ]] || return 1
  fi
  printf '%s' "${command}"
}

_quality_contract_source_command_feasible() {
  [[ -n "$(_quality_contract_source_command_witness \
    "${1:-}" "${2:-}" 2>/dev/null || true)" ]]
}

_quality_contract_expected_proof_identity() {
  local proof_tool_name="${1:-}" proof_target="${2:-}" artifact_target="${3:-}"
  local contract="${4:-}" edit_revision="${5:-}" plan_revision="${6:-}"
  local proof_target_digest proof_material proof_identity
  local contract_id contract_revision review_cycle_id
  [[ -n "${proof_tool_name}" && -n "${proof_target}" ]] || return 1
  [[ "${edit_revision}" =~ ^[0-9]+$ && "${plan_revision}" =~ ^[0-9]+$ ]] \
    || return 1
  if [[ "${proof_tool_name}" == "Bash" ]]; then
    # The exact normalized argv is authenticated separately by the receipt's
    # command digest and receipt ID. Proof identity deliberately collapses the
    # verifier's opaque policy suffix so harmless labels, timeouts, and claimed
    # evidence-kind decoration cannot become distinct proof or counterproof.
    proof_target="${proof_target%%|policy=*}"
  fi
  contract_id="$(jq -r '.contract_id // empty' <<<"${contract}" 2>/dev/null || true)"
  contract_revision="$(jq -r '.contract_revision // empty' \
    <<<"${contract}" 2>/dev/null || true)"
  review_cycle_id="$(jq -r '.review_cycle_id // empty' \
    <<<"${contract}" 2>/dev/null || true)"
  [[ "${contract_id}" =~ ^qc-[A-Za-z0-9._:-]{8,80}$ \
      && "${contract_revision}" =~ ^[1-9][0-9]*$ \
      && "${review_cycle_id}" =~ ^[1-9][0-9]*$ ]] || return 1
  proof_target_digest="$(_omc_authority_digest \
    "${proof_target}" 2>/dev/null || true)"
  [[ -n "${proof_target_digest}" ]] || return 1
  proof_material="$(jq -cnS \
    --arg tool_name "${proof_tool_name}" \
    --arg proof_target_digest "${proof_target_digest}" \
    --arg artifact_target "${artifact_target}" \
    --argjson edit_revision "${edit_revision}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson review_cycle_id "${review_cycle_id}" \
    --arg quality_contract_id "${contract_id}" \
    --argjson quality_contract_revision "${contract_revision}" '
      {tool_name:$tool_name,proof_target_digest:$proof_target_digest,
       artifact_target:$artifact_target,edit_revision:$edit_revision,
       plan_revision:$plan_revision,review_cycle_id:$review_cycle_id,
       quality_contract_id:$quality_contract_id,
       quality_contract_revision:$quality_contract_revision}')" || return 1
  proof_identity="vp-$(_omc_authority_digest \
    "${proof_material}" 2>/dev/null || true)"
  [[ "${proof_identity}" =~ ^vp-[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  printf '%s' "${proof_identity}"
}

_quality_contract_receipt_expected_proof_identity_for_contract() {
  local receipt="${1:-}" contract="${2:-}" tool="" proof_tool=""
  local proof_target="" artifact="" command="" method=""
  local edit_revision="" plan_revision="" project_test_cmd=""
  [[ -n "${receipt}" && -n "${contract}" ]] || return 1
  tool="$(jq -r '.tool_name // empty' <<<"${receipt}" 2>/dev/null || true)"
  command="$(jq -r '.command // empty' <<<"${receipt}" 2>/dev/null || true)"
  artifact="$(jq -r '.artifact_target // empty' \
    <<<"${receipt}" 2>/dev/null || true)"
  edit_revision="$(jq -r '.edit_revision // empty' \
    <<<"${receipt}" 2>/dev/null || true)"
  plan_revision="$(jq -r '.plan_revision // empty' \
    <<<"${receipt}" 2>/dev/null || true)"
  case "${tool}" in
    Bash)
      proof_tool="Bash"
      project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
      [[ -n "${project_test_cmd}" ]] \
        || project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
      proof_target="$(verification_command_semantic_target \
        "${command}" "${project_test_cmd}" 2>/dev/null || true)"
      ;;
    Read|Grep)
      proof_tool="${tool}"
      proof_target="${command}"
      ;;
    mcp__*)
      method="$(jq -r '.method // empty' <<<"${receipt}" \
        2>/dev/null || true)"
      [[ "${method}" == mcp_* ]] || return 1
      proof_tool="${method}"
      proof_target="mcp:${method#mcp_}:${artifact:-untargeted}"
      ;;
    *) return 1 ;;
  esac
  _quality_contract_expected_proof_identity \
    "${proof_tool}" "${proof_target}" "${artifact}" "${contract}" \
    "${edit_revision}" "${plan_revision}"
}

# Resolve the verifier-owned Bash scope once per receipt while separately
# proving that its harness-minted semantic proof identity and its full-argv
# receipt identity are authentic for this contract. Criteria intentionally
# match the policy-independent scope: a project verifier may accept honest
# diagnostic/criterion flags that were not part of the planner's minimal
# feasibility witness. The receipt ID still binds every normalized argv byte,
# so this map is not an authority downgrade.
_quality_contract_bash_receipt_surface_map() {
  local receipts="${1:-}" contract="${2:-}" project_test_cmd=""
  local receipt="" receipt_id="" command="" artifact="" target="" surface=""
  local edit_revision="" plan_revision="" expected_identity="" stored_identity=""
  local surfaces='{}'
  [[ "$(jq -r 'type' <<<"${receipts}" 2>/dev/null || true)" == "array" \
      && "$(jq -r 'type' <<<"${contract}" 2>/dev/null || true)" == "object" ]] \
    || return 1
  project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
  [[ -n "${project_test_cmd}" ]] \
    || project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    receipt_id="$(jq -r '.receipt_id // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    command="$(jq -r '.command // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    artifact="$(jq -r '.artifact_target // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    edit_revision="$(jq -r '.edit_revision // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    plan_revision="$(jq -r '.plan_revision // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    stored_identity="$(jq -r '.proof_identity // empty' <<<"${receipt}" \
      2>/dev/null || true)"
    [[ "${receipt_id}" =~ ^vr-[A-Za-z0-9._:-]{8,80}$ \
        && "${edit_revision}" =~ ^[0-9]+$ \
        && "${plan_revision}" =~ ^[0-9]+$ ]] || continue
    target="$(verification_command_semantic_target \
      "${command}" "${project_test_cmd}" 2>/dev/null || true)"
    [[ -n "${target}" ]] || continue
    expected_identity="$(_quality_contract_expected_proof_identity \
      "Bash" "${target}" "${artifact}" "${contract}" \
      "${edit_revision}" "${plan_revision}" 2>/dev/null || true)"
    [[ -n "${expected_identity}" \
        && "${stored_identity}" == "${expected_identity}" ]] || continue
    surface="${target%%|policy=*}"
    [[ -n "${surface}" ]] || continue
    surfaces="$(jq -cn \
      --argjson surfaces "${surfaces}" --arg id "${receipt_id}" \
      --arg surface "${surface}" '$surfaces + {($id):$surface}')" \
      || return 1
  done < <(jq -c '.[] | select(.tool_name == "Bash")' \
    <<<"${receipts}" 2>/dev/null)
  printf '%s\n' "${surfaces}"
}

# Decide whether a later receipt is materially distinct counterevidence for an
# already-open frontier. A different semantic proof identity is always
# distinct. Re-running the same identity is eligible only for passive
# observation tools, and only when both the content-bearing artifact digest and
# the complete observed-result digest changed. This prevents incidental timing
# or log variance in assertion-bearing tests from clearing a finding while
# still allowing a frozen Read/Grep/MCP observation to reveal new facts.
_quality_contract_counterproof_is_distinct() {
  local prior="${1:-}" current="${2:-}" prior_identity="" current_identity=""
  local prior_result="" current_result="" prior_artifact="" current_artifact=""
  local prior_shape="" current_shape=""
  [[ -n "${prior}" && -n "${current}" ]] || return 1
  prior_identity="$(jq -r '.proof_identity // empty' \
    <<<"${prior}" 2>/dev/null || true)"
  current_identity="$(jq -r '.proof_identity // empty' \
    <<<"${current}" 2>/dev/null || true)"
  [[ -n "${prior_identity}" && -n "${current_identity}" ]] || return 1
  [[ "${prior_identity}" != "${current_identity}" ]] && return 0

  prior_shape="$(jq -r '(.evidence_kind // "") + ":" + (.tool_name // "")' \
    <<<"${prior}" 2>/dev/null || true)"
  current_shape="$(jq -r '(.evidence_kind // "") + ":" + (.tool_name // "")' \
    <<<"${current}" 2>/dev/null || true)"
  case "${prior_shape}" in
    source:*|inspection:Read|inspection:Grep|inspection:mcp__*|render:mcp__*) ;;
    *) return 1 ;;
  esac
  case "${current_shape}" in
    source:*|inspection:Read|inspection:Grep|inspection:mcp__*|render:mcp__*) ;;
    *) return 1 ;;
  esac
  prior_result="$(jq -r '.result_digest // empty' \
    <<<"${prior}" 2>/dev/null || true)"
  current_result="$(jq -r '.result_digest // empty' \
    <<<"${current}" 2>/dev/null || true)"
  prior_artifact="$(jq -r '.artifact_digest // empty' \
    <<<"${prior}" 2>/dev/null || true)"
  current_artifact="$(jq -r '.artifact_digest // empty' \
    <<<"${current}" 2>/dev/null || true)"
  [[ -n "${prior_result}" && -n "${current_result}" \
      && "${prior_result}" != "${current_result}" \
      && -n "${prior_artifact}" && -n "${current_artifact}" \
      && "${prior_artifact}" != "${current_artifact}" ]]
}

quality_contract_criterion_authority_json() {
  local criterion="${1:-}" contract="${2:-}" edit_revision="${3:-}"
  local plan_revision="${4:-}" threshold="${5:-}" tool target command
  local proof_identity proof_surface witness remainder classifier descriptor
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  case "${tool}" in
    Bash)
      target="$(_quality_contract_bash_target_witness \
        "${criterion}" "${threshold}" 2>/dev/null || true)"
      [[ -n "${target}" ]] || return 1
      proof_surface="${target%%|policy=*}"
      [[ -n "${proof_surface}" ]] || return 1
      jq -cnS --arg proof_surface "${proof_surface}" \
        '{mode:"bash_surface",proof_surface:$proof_surface,
          artifact_target:"",expected_command:""}'
      ;;
    Read|Grep)
      target="$(_quality_contract_source_target_witness \
        "${criterion}" 2>/dev/null || true)"
      [[ -n "${target}" ]] || return 1
      command="$(_quality_contract_source_command_witness \
        "${criterion}" "${target}" 2>/dev/null || true)"
      [[ -n "${command}" ]] || return 1
      proof_identity="$(_quality_contract_expected_proof_identity \
        "${tool}" "${command}" "${target}" "${contract}" \
        "${edit_revision}" "${plan_revision}")" || return 1
      jq -cnS --arg proof_identity "${proof_identity}" \
        --arg artifact_target "${target}" --arg expected_command "${command}" \
        '{mode:"proof_identity",proof_identity:$proof_identity,
          artifact_target:$artifact_target,expected_command:$expected_command}'
      ;;
    mcp__*)
      witness="$(_quality_contract_mcp_proof_target_witness \
        "${criterion}" "${threshold}" 2>/dev/null || true)"
      [[ "${witness}" == mcp:*:* ]] || return 1
      remainder="${witness#mcp:}"
      classifier="${remainder%%:*}"
      descriptor="${remainder#*:}"
      [[ -n "${classifier}" && -n "${descriptor}" ]] || return 1
      jq -cnS --arg classifier "${classifier}" --arg descriptor "${descriptor}" \
        '{mode:"mcp",classifier:$classifier,descriptor:$descriptor,
          artifact_target:"",expected_command:""}'
      ;;
    *) return 1 ;;
  esac
}

quality_contract_proof_specs_feasible() {
  local json="${1:-}" threshold="${2:-}" criterion tool possible requested proof_target
  local seen_proof_targets=$'\n'
  local prior_mcp_criteria='[]' prior_mcp_criterion
  local prior_bash_targets='[]' prior_bash_target
  while IFS= read -r criterion; do
    [[ -n "${criterion}" ]] || continue
    tool="$(jq -r '.proof_spec.tool_names[0] // empty' <<<"${criterion}")"
    requested="$(jq -r '.proof_spec.receipt_kinds[0] // empty' <<<"${criterion}")"
    case "${tool}" in
      Bash)
        proof_target="$(_quality_contract_bash_target_witness \
          "${criterion}" "${threshold}" 2>/dev/null || true)"
        [[ -n "${proof_target}" ]] || return 1
        # Distinct shell spelling cannot satisfy independent proof criteria.
        # Fail during planning instead of freezing a contract whose evidence
        # gate can only discover the collision after all work is complete.
        while IFS= read -r prior_bash_target; do
          [[ -n "${prior_bash_target}" ]] || continue
          _quality_contract_bash_targets_overlap \
            "${prior_bash_target}" "${proof_target}" && return 1
        done < <(jq -r '.[]' <<<"${prior_bash_targets}")
        seen_proof_targets="${seen_proof_targets}${proof_target}"$'\n'
        prior_bash_targets="$(jq -cn \
          --argjson rows "${prior_bash_targets}" \
          --arg target "${proof_target}" '$rows + [$target]')" || return 1
        ;;
      Read|Grep)
        possible="$(_quality_contract_tool_possible_kinds \
          "${tool}" "${threshold}" 2>/dev/null || true)"
        [[ " ${possible} " == *" ${requested} "* ]] || return 1
        _quality_contract_nonbash_anchor_bounds_feasible "${criterion}" || return 1
        _quality_contract_canonical_source_anchors_feasible "${criterion}" || return 1
        proof_target="$(_quality_contract_source_target_witness \
          "${criterion}" 2>/dev/null || true)"
        [[ -n "${proof_target}" ]] || return 1
        _quality_contract_source_command_feasible \
          "${criterion}" "${proof_target}" || return 1
        proof_target="source:${tool}:${proof_target}"
        case "${seen_proof_targets}" in
          *$'\n'"${proof_target}"$'\n'*) return 1 ;;
        esac
        seen_proof_targets="${seen_proof_targets}${proof_target}"$'\n'
        ;;
      mcp__*)
        _quality_contract_nonbash_anchor_bounds_feasible "${criterion}" || return 1
        _quality_contract_mcp_target_anchors_feasible "${criterion}" || return 1
        proof_target="$(_quality_contract_mcp_proof_target_witness \
          "${criterion}" "${threshold}" 2>/dev/null || true)"
        [[ -n "${proof_target}" ]] || return 1
        while IFS= read -r prior_mcp_criterion; do
          [[ -n "${prior_mcp_criterion}" ]] || continue
          if _quality_contract_mcp_criteria_overlap \
              "${prior_mcp_criterion}" "${criterion}" "${threshold}"; then
            return 1
          fi
        done < <(jq -c '.[]' <<<"${prior_mcp_criteria}")
        case "${seen_proof_targets}" in
          *$'\n'"${proof_target}"$'\n'*) return 1 ;;
        esac
        seen_proof_targets="${seen_proof_targets}${proof_target}"$'\n'
        prior_mcp_criteria="$(jq -cn \
          --argjson rows "${prior_mcp_criteria}" \
          --argjson row "${criterion}" '$rows + [$row]')" || return 1
        ;;
      *) return 1 ;;
    esac
  done < <(jq -c '.criteria[]' <<<"${json}")
  return 0
}

quality_contract_validate_payload() {
  local json="${1:-}" validation_mode="${2:-live}" threshold="${3:-}" redacted=""
  case "${validation_mode}" in live|intrinsic) ;; *) return 1 ;; esac
  [[ -n "${json}" && ${#json} -le 32768 ]] || return 1
  if declare -F omc_redact_secrets >/dev/null 2>&1; then
    redacted="$(printf '%s' "${json}" | omc_redact_secrets)" || return 1
    [[ "${redacted}" == "${json}" ]] || return 1
  fi
  jq -e '
    def text($min;$max):
      type == "string" and length <= $max
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length >= $min)
      and (test("[\u0000-\u001f]") | not)
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase
        | test("^(n/?a|none|tbd|todo|excellent|high quality)$") | not);
    def axis_name:
      . == "deliberate" or . == "distinctive" or . == "visionary"
      or . == "coherent" or . == "complete";
    def allowed_kind:
      . == "test" or . == "render" or . == "benchmark"
      or . == "inspection" or . == "comparison" or . == "source"
      or . == "review";
    def receipt_kind:
      . == "test" or . == "render" or . == "benchmark"
      or . == "inspection" or . == "comparison" or . == "source";
    def unique_strings:
      type == "array" and length == (unique | length);
    def norm:
      ascii_downcase | gsub("[[:space:]]+"; " ")
      | gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def generic_surface:
      norm | test("^(artifact|output|quality|work|result|deliverable|system|thing)$");
    def generic_anchor:
      norm | test("^(test|tests|check|verify|verification|comparison|compare|benchmark|render|artifact|output|result|quality|current|all|ok|src|source|deliberate|distinctive|coherent|visionary|complete)$");
    def proof_anchors($spec):
      ([$spec.command_contains[] | . as $value
        | {key:("command:" + ($value | norm)),
           generic:($value | generic_anchor)}]
       + [$spec.artifact_contains[] | . as $value
        | {key:("artifact:" + $value),
           generic:($value | generic_anchor)}]);
    def tool_covers($weak;$strong):
      if ($strong | endswith("*")) then
        if ($weak | endswith("*")) then
          ($strong[0:-1] | startswith($weak[0:-1]))
        else false end
      else
        if ($weak | endswith("*")) then
          ($strong | startswith($weak[0:-1]))
        else $strong == $weak end
      end;
    def anchors_imply($strong;$weak):
      all($weak.command_contains[]; . as $needle
        | any($strong.command_contains[];
            ascii_downcase | contains($needle | ascii_downcase)))
      and all($weak.artifact_contains[]; . as $needle
        | ($strong.artifact_contains | index($needle)) != null);
    def spec_implies($strong;$weak):
      all($strong.tool_names[]; . as $tool
        | any($weak.tool_names[]; tool_covers(.;$tool)))
      and all($strong.receipt_kinds[]; . as $kind
        | ($weak.receipt_kinds | index($kind)) != null)
      and anchors_imply($strong;$weak);
    type == "object"
    and (keys_unsorted | all(. as $k |
      ["north_star","audience","stakes","ambition_boundary","axes",
       "standards","anti_goals","criteria"] | index($k)))
    and (.north_star | text(12;2000))
    and (.audience | text(3;1000))
    and (.stakes | text(8;1500))
    and (.ambition_boundary | text(12;2000))
    and (.axes | type == "object")
    and (.axes | keys | sort == ["coherent","complete","deliberate","distinctive","visionary"])
    and ([.axes[] | text(12;2000)] | all)
    and ([.axes[] | norm] | length == (unique | length))
    and (.anti_goals | unique_strings and length >= 1 and length <= 10
      and all(.[]; text(4;500)))
    and (.standards | type == "array" and length >= 1 and length <= 20
      and all(.[]; type == "object"
        and (keys_unsorted | all(. as $k |
          ["kind","reference","rationale","profile_entry_id"] | index($k)))
        and (.kind == "user" or .kind == "profile" or .kind == "repo"
          or .kind == "domain" or .kind == "external")
        and (.reference | text(2;1000))
        and (.rationale | text(4;1000))
        # A Constitution binding is meaningful only on a profile standard;
        # forbid free-floating IDs and require every profile row to name its
        # exact durable source.
        and (if .kind == "profile" then
          (.profile_entry_id | type == "string"
            and test("^[A-Za-z0-9._:-]{3,128}$"))
        else (has("profile_entry_id") | not) end))
      # A reworded/removed Constitution claim does not erase the already-frozen
      # standard. Additive revisions may therefore contain the historical row
      # and a new current row with the same durable ID. Reject only byte-equal
      # duplicate standards; live binding validation below proves provenance.
      and ([.[] | tojson] | length == (unique | length)))
    and (any(.standards[]; .kind == "user"))
    # Initial contracts are capped more tightly by build_envelope. Payloads
    # retain bounded additive headroom so a full ten-criterion floor can absorb
    # later authoritative scope instead of forcing the planner to hide it.
    and (.criteria | type == "array" and length >= 5 and length <= 20)
    and ([.criteria[].id] | unique_strings)
    and (.criteria | all(.[];
      type == "object"
      and (keys_unsorted | all(. as $k |
        ["id","class","axis","claim","rationale","surfaces","evidence_policy",
         "proof_method","proof_spec","failure_signal","tradeoff_boundary"] | index($k)))
      and (.id | type == "string" and test("^Q-[0-9]{3}$"))
      and (.class == "must" or .class == "aspiration")
      and (.axis | axis_name)
      and (.claim | text(8;1000))
      and (.rationale | text(8;1500))
      and (.surfaces | unique_strings and length >= 1 and length <= 20
        and all(.[]; text(1;500) and (generic_surface | not)))
      and (.proof_method | text(8;1500))
      and (.proof_spec | type == "object"
        and (keys | sort == ["artifact_contains","command_contains","receipt_kinds","tool_names"])
        # One criterion is one proof language. Alternatives create union-cover
        # deadlocks: every tool/kind branch can overlap a different sibling even
        # when no one sibling subsumes the whole criterion.
        and (.receipt_kinds | unique_strings and length == 1
          and all(.[]; receipt_kind))
        and (.tool_names | unique_strings and length == 1
          and all(.[]; type == "string" and length >= 1 and length <= 160
            and test("^[A-Za-z0-9_.:*-]+$")
            and ((gsub("[^*]";"") | length) <= 1)
            and (if contains("*") then
              endswith("*") and (.[0:-1] | length) >= 8
              and startswith("mcp__")
            else true end)))
        and (.command_contains | unique_strings and length <= 8
          and all(.[]; text(2;200)))
        and (.artifact_contains | unique_strings and length <= 8
          and all(.[]; text(2;300)))
        and ((.command_contains | length) + (.artifact_contains | length) >= 1))
      and (.failure_signal | text(8;1000))
      and (.tradeoff_boundary | text(8;1000))
      and (.evidence_policy | type == "object"
        and (keys | sort == ["allowed_kinds","minimum","requires_empirical","requires_independent_review"])
        and (.allowed_kinds | unique_strings and length >= 1 and length <= 6
          and all(.[]; allowed_kind))
        # One criterion consumes exactly one uniquely matching receipt. When
        # independent proofs are required, model them as separate criteria
        # with separate anchors; shell spelling is not a semantic identity.
        and .minimum == 1
        and (.requires_empirical | type == "boolean")
        and (.requires_independent_review | type == "boolean")
        and (if .requires_empirical then
          (.allowed_kinds | any(. != "review")) else true end))))
    and all(.criteria[]; . as $criterion
      | ($criterion.proof_spec.receipt_kinds
        | all(.[]; . as $kind
          | ($criterion.evidence_policy.allowed_kinds | index($kind)) != null)))
    # The empirical floor is deliberately strong: every mandatory axis must be
    # represented by a mandatory, empirically checkable criterion.
    and (["deliberate","distinctive","coherent","visionary","complete"]
      | all(.[]; . as $axis | any($ARGS.named.doc.criteria[];
          .axis == $axis and .class == "must"
          and .evidence_policy.requires_empirical == true
          and .evidence_policy.requires_independent_review == true)))
    and (any(.criteria[]; .axis == "visionary" and .class == "must"))
    # A five-label checklist with one generic sentence copied five times is
    # still one self-certified finish line. Every criterion, including an
    # aspiration the reviewer must assess, needs distinct failure semantics
    # and a proof spec that can produce a uniquely matching receipt.
    and ([.criteria[].claim | norm]
      | length == (unique | length))
    and ([.criteria[].failure_signal | norm]
      | length == (unique | length))
    and ([.criteria[].proof_spec | tojson]
      | length == (unique | length))
    and all(.criteria[]; . as $criterion
      | proof_anchors($criterion.proof_spec) as $anchors
      | any($anchors[]; (.generic | not))
      and any($anchors[]; .key as $anchor
        | ([ $ARGS.named.doc.criteria[]
             | select(.id != $criterion.id)
             | proof_anchors(.proof_spec)[] | .key ]
          | index($anchor)) == null))
    # Reject any criterion whose entire proof language is a subset of another
    # compatible criterion. Such a criterion can never receive an exact-one
    # match and would freeze an unprovable contract floor.
    and all(.criteria[]; . as $strong
      | all($ARGS.named.doc.criteria[] | select(.id != $strong.id); . as $weak
          | (spec_implies($strong.proof_spec;$weak.proof_spec) | not)))
    and all(.criteria[]; . as $criterion
      | if $criterion.axis == "visionary" and $criterion.class == "must" then
          ($criterion.proof_spec.receipt_kinds
            | any(. == "benchmark" or . == "render" or . == "comparison"))
        else true end)
  ' --argjson doc "${json}" <<<"${json}" >/dev/null 2>&1 || return 1
  [[ "${validation_mode}" == "intrinsic" ]] \
    || quality_contract_proof_specs_feasible "${json}" "${threshold}"
}

quality_contract_canonicalize_payload() {
  local json="${1:-}" validation_mode="${2:-live}" threshold="${3:-}"
  local canonical=""
  quality_contract_validate_payload \
    "${json}" "${validation_mode}" "${threshold}" || return 1
  canonical="$(jq -cS '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def stable_unique:
      reduce .[] as $item ([];
        if index($item) == null then . + [$item] else . end);
    .north_star |= trim
    | .audience |= trim
    | .stakes |= trim
    | .ambition_boundary |= trim
    | .axes |= with_entries(.value |= trim)
    | .standards |= (map(.reference |= trim | .rationale |= trim)
        | sort_by(.kind, .profile_entry_id // "", .reference))
    | .anti_goals |= (map(trim) | unique)
    | .criteria |= (map(
        .claim |= trim
        | .rationale |= trim
        | .surfaces |= (map(trim) | unique)
        | .proof_method |= trim
        # Grep joins command anchors in declared order to form its exact regex.
        # Preserve that semantic order while de-duplicating canonical values.
        | .proof_spec.command_contains |= (map(trim) | stable_unique)
        | .proof_spec.artifact_contains |= (map(trim) | stable_unique)
        | .proof_spec.receipt_kinds |= unique
        | .proof_spec.tool_names |= unique
        | .failure_signal |= trim
        | .tradeoff_boundary |= trim
        | .evidence_policy.allowed_kinds |= unique
      ) | sort_by(.id))
  ' <<<"${json}")" || return 1
  quality_contract_validate_payload \
    "${canonical}" "${validation_mode}" "${threshold}" || return 1
  printf '%s\n' "${canonical}"
}

_quality_contract_digest() {
  _omc_authority_digest "${1:-}"
}

_quality_contract_required_profile_ids_json() {
  local raw="" key file
  for key in quality_constitution_blocking_ids quality_profile_blocking_ids \
      doe_profile_blocking_ids; do
    raw="$(read_state "${key}" 2>/dev/null || true)"
    [[ -n "${raw}" ]] && break
  done
  if [[ -n "${raw}" ]]; then
    if jq -e 'type == "array" and all(.[]; type == "string")' \
        <<<"${raw}" >/dev/null 2>&1; then
      jq -cS 'unique | sort' <<<"${raw}"
      return
    fi
    printf '%s' "${raw}" | jq -Rc '
      [splits("[,[:space:]]+") | select(length > 0)] | unique | sort'
    return
  fi
  for file in "$(session_file "quality_constitution_snapshot.json")" \
      "$(session_file "quality_constitution.json")"; do
    if [[ -f "${file}" && ! -L "${file}" ]]; then
      jq -cS '[.blocking_claims[]?.id | select(type == "string")] | unique | sort' \
        "${file}" 2>/dev/null && return
    fi
  done
  printf '[]'
}

quality_contract_validate_profile_bindings() {
  local definition="${1:-}" required_ids="${2:-}" historical="${3:-[]}"
  local snapshot="" snapshot_file
  quality_contract_validate_payload "${definition}" intrinsic || return 1
  [[ -n "${required_ids}" ]] \
    || required_ids="$(_quality_contract_required_profile_ids_json)" || return 1
  jq -e 'type == "array" and length == (unique | length)
    and all(.[]; type == "string" and test("^[A-Za-z0-9._:-]{3,128}$"))' \
    <<<"${required_ids}" >/dev/null 2>&1 || return 1
  jq -e 'type == "array" and length <= 20 and all(.[];
      type == "object" and .kind == "profile"
      and (.profile_entry_id | type == "string"
        and test("^[A-Za-z0-9._:-]{3,128}$"))
      and (.reference | type == "string")
      and (.rationale | type == "string"))
    and ([.[] | tojson] | length == (unique | length))' \
    <<<"${historical}" >/dev/null 2>&1 || return 1
  snapshot_file="$(session_file "quality_constitution_snapshot.json")"
  if [[ -f "${snapshot_file}" && ! -L "${snapshot_file}" ]]; then
    snapshot="$(_quality_contract_read_json_file "${snapshot_file}" 262144)" || return 1
    jq -e '.schema_version == 1
      and (.generation | type == "number" and floor == .
        and . >= 0 and . <= 999999999999999)
      and (.digest | type == "string")
      and ([.blocking_claims[],.advisory_claims[],.tentative_claims[]]
        | all(.[]; (.id|type)=="string" and (.statement|type)=="string"))' \
      <<<"${snapshot}" >/dev/null 2>&1 || return 1
  elif [[ "$(jq -r 'length' <<<"${required_ids}")" -gt 0 ]] \
      || jq -e 'any(.standards[]; .kind == "profile")' \
        <<<"${definition}" >/dev/null 2>&1; then
    return 1
  else
    snapshot='{"blocking_claims":[],"advisory_claims":[],"tentative_claims":[]}'
  fi
  jq -e --argjson required "${required_ids}" --argjson snapshot "${snapshot}" \
      --argjson historical "${historical}" '
    . as $definition
    | ([$snapshot.blocking_claims[], $snapshot.advisory_claims[],
        $snapshot.tentative_claims[]]) as $current
    # Every current blocking ID needs an exact current statement binding. An
    # old row with the same durable ID cannot impersonate a reworded claim.
    | all($required[]; . as $id
        | any($definition.standards[];
            .kind == "profile" and .profile_entry_id == $id
            and .reference as $statement
            | any($current[]; .id == $id and .statement == $statement)))
    # A profile standard is either live now or byte-for-byte inherited from
    # the immediately preceding sealed contract. This permits additive floor
    # preservation without allowing a planner to invent historical authority.
    and all($definition.standards[] | select(.kind == "profile"); . as $standard
      | any($current[];
          .id == $standard.profile_entry_id
          and .statement == $standard.reference)
        or any($historical[]; . == $standard))
  ' <<<"${definition}" >/dev/null 2>&1
}

_quality_contract_sha256_file() {
  local path="${1:-}" PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_quality_contract_sha256_canonical_json_file() {
  local path="${1:-}" PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    jq -cS . "${path}" 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    jq -cS . "${path}" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_quality_contract_sha256_canonical_json_text() {
  local json="${1:-}" PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}"
  if command -v shasum >/dev/null 2>&1; then
    jq -cS . <<<"${json}" 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    jq -cS . <<<"${json}" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_quality_contract_effective_constitution_digest() {
  local profile_digest="${1:-}" reference_digest="${2:-}"
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}"
  [[ -n "${profile_digest}" && -n "${reference_digest}" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf 'profile=%s\nreferences=%s\n' "${profile_digest}" "${reference_digest}" \
      | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf 'profile=%s\nreferences=%s\n' "${profile_digest}" "${reference_digest}" \
      | sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

_quality_contract_physical_existing_path() {
  local path="${1:-}" resolved parent base
  [[ -n "${path}" ]] || return 1
  if [[ "${path}" == "/" ]]; then
    printf '/'
    return 0
  fi
  if declare -F _omc_resolve_path >/dev/null 2>&1; then
    resolved="$(_omc_resolve_path "${path}" 2>/dev/null)" || return 1
  else
    resolved="${path}"
  fi
  [[ ! -L "${resolved}" && -e "${resolved}" ]] || return 1
  parent="${resolved%/*}"
  base="${resolved##*/}"
  [[ "${parent}" != "${resolved}" ]] || parent="."
  parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "${parent}" "${base}"
}

_quality_contract_load_constitution_authority() {
  declare -F qc_constitution_is_valid >/dev/null 2>&1 && return 0
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" \
    || return 1
  # shellcheck source=quality-constitution-authority.sh
  . "${lib_dir}/quality-constitution-authority.sh"
}

_quality_contract_snapshot_live_current() {
  local snapshot="${1:-}" profile_exists profile_path profile_digest live_digest
  local reference_digest effective_digest cwd root observation kind locator
  local integrity observed candidate resolved project_key expected_profile_path
  local qc_root qc_profiles profile_dir component profile_parent
  local selector_mirror current_time
  jq -e '
    .schema_version == 1
    and all(.. | strings; index("\u0000") == null)
    and (.profile_exists | type == "boolean")
    and (.profile_path | type == "string" and length >= 1 and length <= 1000
      and (test("[\u0000-\u001f]") | not))
    and (.selectors | type == "object")
    and (.blocking_claims | type == "array" and length <= 500)
    and (.advisory_claims | type == "array" and length <= 12)
    and (.tentative_claims | type == "array" and length <= 8)
    and (.generation | type == "number" and floor == .
      and . >= 0 and . <= 999999999999999)
    and (.digest | type == "string" and test("^(none|[a-f0-9]{64})$"))
    and (.profile_digest | type == "string"
      and test("^(none|[a-f0-9]{64})$"))
    and (.reference_integrity_digest | type == "string"
      and test("^(none|[a-f0-9]{64})$"))
    and (if .profile_exists then
      (.digest != "none" and .profile_digest != "none"
        and .reference_integrity_digest != "none")
      else (.digest == "none" and .profile_digest == "none"
        and .reference_integrity_digest == "none") end)
    and (.reference_observations | type == "array" and length <= 200
      and ([.[].id] | length == (unique | length))
      and all(.[];
        (keys | sort == ["detail","id","integrity","kind","locator",
          "observed_digest","recorded_digest"])
        and (.id | type == "string" and test("^[A-Za-z0-9._:-]{3,128}$"))
        and (.kind == "repo_path" or .kind == "url" or .kind == "description")
        and (.locator | type == "string" and length >= 1 and length <= 1000
          and (test("[\u0000-\u001f]") | not))
        and (.detail | type == "string" and length <= 1000
          and (test("[\u0000-\u001f]") | not))
        and (.recorded_digest | type == "string"
          and test("^$|^[a-f0-9]{64}$"))
        and (.observed_digest | type == "string"
          and test("^$|^[a-f0-9]{64}$"))
        and (if .kind == "repo_path" then
          (if .integrity == "verified" then
             .recorded_digest != ""
             and .observed_digest == .recorded_digest
             and .detail == ""
           elif .integrity == "drifted" then
             .observed_digest != ""
             and .observed_digest != .recorded_digest
             and (.detail | length) > 0
           elif .integrity == "unavailable" then
             .observed_digest == "" and (.detail | length) > 0
           else false end)
        else
          .integrity == "not_applicable"
          and .observed_digest == "" and .detail == ""
        end)))' \
    <<<"${snapshot}" >/dev/null 2>&1 || return 1

  cwd="$(read_state "cwd" 2>/dev/null || true)"
  [[ -n "${cwd}" ]] || cwd="${PWD:-}"
  [[ -n "${cwd}" ]] || return 1
  root="$(PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}" \
    git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${root}" ]] || root="$(cd "${cwd}" 2>/dev/null && pwd -P)" || return 1
  root="$(_quality_contract_physical_existing_path "${root}" 2>/dev/null)" \
    || return 1

  _quality_contract_load_constitution_authority || return 1
  project_key="$(PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin}" \
    qc_authority_project_key "${root}" 2>/dev/null)" || return 1
  [[ "${project_key}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  qc_root="${HOME}/.claude/omc-user/quality-constitutions"
  qc_profiles="${qc_root}/profiles"
  profile_dir="${qc_profiles}/qcp_${project_key}"
  expected_profile_path="${profile_dir}/constitution.json"
  profile_exists="$(jq -r '.profile_exists' <<<"${snapshot}")"
  profile_path="$(jq -r '.profile_path' <<<"${snapshot}")"
  [[ "${profile_path}" == "${expected_profile_path}" ]] || return 1
  selector_mirror="$(read_state "quality_constitution_selectors" 2>/dev/null || true)"
  jq -e 'type == "object"
      and (keys | sort == ["audience","domain","path","surface","task_type"])
      and all(.[]; type == "string" and length <= 240
        and (test("[\u0000-\u001f]") | not))' \
    <<<"${selector_mirror}" >/dev/null 2>&1 || return 1
  jq -e --argjson selectors "${selector_mirror}" \
    '.selectors == $selectors' <<<"${snapshot}" >/dev/null 2>&1 || return 1

  # Exact lexical binding above rejects `..` aliases. Reject symlinked data
  # components as well, including dangling links in an otherwise absent
  # profile, so canonical hashing can never follow the snapshot outside the
  # per-project Constitution root.
  for component in \
      "${HOME}/.claude" \
      "${HOME}/.claude/omc-user" \
      "${qc_root}" \
      "${qc_profiles}" \
      "${profile_dir}" \
      "${profile_path}"; do
    [[ ! -L "${component}" ]] || return 1
  done
  if [[ "${profile_exists}" == "true" ]]; then
    [[ -d "${qc_root}" && -d "${qc_profiles}" && -d "${profile_dir}" ]] \
      || return 1
    profile_parent="$(cd "${profile_path%/*}" 2>/dev/null && pwd -P)" \
      || return 1
    [[ "${profile_parent}" == "$(cd "${profile_dir}" 2>/dev/null && pwd -P)" ]] \
      || return 1
    qc_constitution_is_valid "${profile_path}" 500 200 || return 1
    jq -e --arg expected_profile_id "qcp_${project_key}" \
      '.profile_id == $expected_profile_id' \
      "${profile_path}" >/dev/null 2>&1 || return 1
    [[ "$(jq -r '.generation' "${profile_path}" 2>/dev/null || true)" \
        == "$(jq -r '.generation' <<<"${snapshot}")" ]] || return 1
    current_time="$(now_epoch 2>/dev/null || true)"
    [[ "${current_time}" =~ ^[0-9]+$ ]] || return 1
    # Compiled claims are also derived authority. Re-run the compiler's exact
    # eligibility/scope/rank/cap projection against the sealed live profile and
    # the selector mirror written by the router. Neither a fabricated advisory
    # standard nor a coordinated selector+claim omission can survive this
    # comparison merely because the raw profile digest itself is current.
    jq -e --argjson snapshot "${snapshot}" --argjson now "${current_time}" '
      def exact_applies($values; $selector):
        (($values // []) | length == 0) or
        ($selector != "" and (($values // []) | index($selector) != null));
      def path_applies($values; $selector):
        if (($values // []) | length) == 0 then true
        elif $selector == "" then false
        else [($values // [])[] as $scope_path
          | select($selector == $scope_path or
              ($selector | startswith($scope_path + "/")))] | length > 0
        end;
      def applies($selectors):
        exact_applies(.scope.domains; $selectors.domain) and
        exact_applies(.scope.task_types; $selectors.task_type) and
        exact_applies(.scope.surfaces; $selectors.surface) and
        exact_applies(.scope.audiences; $selectors.audience) and
        path_applies(.scope.paths; $selectors.path);
      def rank:
        if .enforcement == "blocking" then 0
        elif .authority == "user_pinned" then 1
        elif .authority == "user_confirmed" then 2
        elif .authority == "user_selected" then 3
        else 4 end;
      ([.claims[]
        | select(if .authority == "inferred" then
            ((.status == "active" or .status == "review_due" or
              .status == "tentative") and ((.review_after // 0) >= $now))
          else (.status == "active" or .status == "review_due") end)]) as $eligible
      | ([$eligible[] | select(applies($snapshot.selectors))]
          | sort_by(rank, .created_at)) as $matching
      | ($snapshot.blocking_claims ==
          [$matching[] | select(.enforcement == "blocking")])
        and ($snapshot.advisory_claims ==
          [$matching[] | select(.enforcement == "advisory" and
            .authority != "inferred")][0:12])
        and ($snapshot.tentative_claims ==
          [$matching[] | select(.authority == "inferred")][0:8])
    ' "${profile_path}" >/dev/null 2>&1 || return 1
    # The observation base projection is derived authority, not caller input.
    # Bind it exactly to every live active/stale reference before trusting any
    # recorded/observed digest or integrity label. This prevents a resealed
    # snapshot from omitting a drifted exemplar or laundering it by replacing
    # both digests with the current bytes.
    jq -e --argjson observations \
        "$(jq -c '.reference_observations' <<<"${snapshot}")" '
      ([.references[]
        | select(.status == "active" or .status == "stale")
        | {id,kind,locator,recorded_digest:(.content_digest // "")}]
        | sort_by(.id,.kind,.locator,.recorded_digest))
      == ($observations
        | map({id,kind,locator,recorded_digest})
        | sort_by(.id,.kind,.locator,.recorded_digest))
    ' "${profile_path}" >/dev/null 2>&1 || return 1
    profile_digest="$(jq -r '.profile_digest' <<<"${snapshot}")"
    live_digest="$(_quality_contract_sha256_canonical_json_file \
      "${profile_path}" 2>/dev/null || true)"
    [[ -n "${live_digest}" && "${live_digest}" == "${profile_digest}" ]] || return 1
    reference_digest="$(_quality_contract_sha256_canonical_json_text \
      "$(jq -c '.reference_observations' <<<"${snapshot}")" 2>/dev/null || true)"
    [[ -n "${reference_digest}" \
        && "${reference_digest}" == \
          "$(jq -r '.reference_integrity_digest' <<<"${snapshot}")" ]] || return 1
    effective_digest="$(_quality_contract_effective_constitution_digest \
      "${profile_digest}" "${reference_digest}" 2>/dev/null || true)"
    [[ -n "${effective_digest}" \
        && "${effective_digest}" == "$(jq -r '.digest' <<<"${snapshot}")" ]] || return 1
  else
    [[ "$(jq -r '.generation' <<<"${snapshot}")" == "0" \
        && "$(jq -r '.profile_digest' <<<"${snapshot}")" == "none" \
        && "$(jq -r '.reference_integrity_digest' <<<"${snapshot}")" == "none" \
        && "$(jq -r '.digest' <<<"${snapshot}")" == "none" ]] || return 1
    [[ ! -e "${profile_path}" && ! -L "${profile_path}" ]] || return 1
    jq -e '.blocking_claims == [] and .advisory_claims == []
      and .tentative_claims == [] and .reference_observations == []' \
      <<<"${snapshot}" >/dev/null 2>&1 || return 1
  fi

  while IFS= read -r observation; do
    [[ -n "${observation}" ]] || continue
    kind="$(jq -r '.kind' <<<"${observation}")"
    integrity="$(jq -r '.integrity' <<<"${observation}")"
    if [[ "${kind}" != "repo_path" ]]; then
      [[ "${integrity}" == "not_applicable" ]] || return 1
      continue
    fi
    locator="$(jq -r '.locator' <<<"${observation}")"
    [[ -n "${locator}" && "${locator}" != /* ]] || return 1
    case "/${locator}/" in */../*|*/./*) return 1 ;; esac
    candidate="${root}/${locator}"
    resolved="$(_quality_contract_physical_existing_path \
      "${candidate}" 2>/dev/null || true)"
    if [[ "${root}" == "/" ]]; then
      case "${resolved}" in /*) ;; *) resolved="" ;; esac
    else
      case "${resolved}" in "${root}"/*) ;; *) resolved="" ;; esac
    fi
    if [[ "${integrity}" == "unavailable" ]]; then
      [[ -z "${resolved}" || ! -f "${resolved}" ]] || return 1
      continue
    fi
    [[ "${integrity}" == "verified" || "${integrity}" == "drifted" ]] || return 1
    [[ -n "${resolved}" && -f "${resolved}" && ! -L "${resolved}" ]] || return 1
    observed="$(_quality_contract_sha256_file "${resolved}" 2>/dev/null || true)"
    [[ -n "${observed}" \
        && "${observed}" == "$(jq -r '.observed_digest' <<<"${observation}")" ]] \
      || return 1
  done < <(jq -c '.reference_observations[]' <<<"${snapshot}")
  return 0
}

_quality_contract_profile_metadata_json() {
  local snapshot_file snapshot status state_generation state_digest
  local state_ids_raw state_ids snapshot_ids
  snapshot_file="$(session_file "quality_constitution_snapshot.json")"
  status="$(read_state "quality_constitution_status" 2>/dev/null || true)"
  if [[ ! -e "${snapshot_file}" && ! -L "${snapshot_file}" ]]; then
    case "${status}" in
      disabled|not_applicable) jq -cnS '{generation:0,digest:"none"}'; return ;;
      *) return 1 ;;
    esac
  fi
  [[ "${status}" == "current" ]] || return 1
  snapshot="$(_quality_contract_read_json_file "${snapshot_file}" 262144)" || return 1
  _quality_contract_snapshot_live_current "${snapshot}" || return 1
  state_generation="$(read_state "quality_constitution_generation" 2>/dev/null || true)"
  state_digest="$(read_state "quality_constitution_digest" 2>/dev/null || true)"
  _omc_canonical_uint_in_range \
    "${state_generation}" 0 999999999999999 || return 1
  [[ "${state_generation}" == "$(jq -r '.generation' <<<"${snapshot}")" ]] \
    || return 1
  [[ -n "${state_digest}" \
      && "${state_digest}" == "$(jq -r '.digest' <<<"${snapshot}")" ]] || return 1
  state_ids_raw="$(read_state "quality_constitution_blocking_ids" 2>/dev/null || true)"
  if [[ -z "${state_ids_raw}" ]]; then
    state_ids='[]'
  elif jq -e 'type == "array" and all(.[]; type == "string")' \
      <<<"${state_ids_raw}" >/dev/null 2>&1; then
    state_ids="$(jq -cS 'unique | sort' <<<"${state_ids_raw}")" || return 1
  else
    state_ids="$(printf '%s' "${state_ids_raw}" | jq -RcS \
      '[splits("[,[:space:]]+") | select(length > 0)] | unique | sort')" \
      || return 1
  fi
  snapshot_ids="$(jq -cS '[.blocking_claims[].id] | unique | sort' \
    <<<"${snapshot}")" || return 1
  [[ "${state_ids}" == "${snapshot_ids}" ]] || return 1
  jq -ceS '
    select(.schema_version == 1)
    | select((.generation|type)=="number" and (.generation|floor)==.generation
      and .generation >= 0 and .generation <= 999999999999999)
    | select((.digest|type)=="string" and (.digest|length) >= 4)
    | {generation,digest}
  ' <<<"${snapshot}"
}

_quality_contract_scope_transition_allows_digest_change() {
  [[ "$#" -eq 6 ]] || return 1
  local prior_contract="$1" new_objective_digest="$2" prompt_revision="$3"
  local cycle="$4" enforcement_generation="$5" contract_revision="$6"
  local transition scope_ledger current_objective_digest addition_digest

  [[ "$(read_state "quality_contract_recheck_required" 2>/dev/null || true)" == "1" ]] \
    || return 1
  # quality_contract_status is an observational mirror used by guards and
  # Stop diagnostics. Those consumers legitimately replace `recheck-required`
  # with a concrete gate result (for example `missing-or-stale`) while the
  # authoritative recheck latch and exact transition remain live. Never make
  # that presentation field part of the one-use scope authorization below.
  transition="$(read_state "quality_contract_scope_transition" 2>/dev/null || true)"
  [[ -n "${transition}" && ${#transition} -le 4096 ]] || return 1
  jq -e \
    --arg new_digest "${new_objective_digest}" \
    --argjson prompt_revision "${prompt_revision}" \
    --argjson cycle "${cycle}" \
    --arg enforcement "${enforcement_generation}" \
    --argjson contract_revision "${contract_revision}" \
    --argjson prior "${prior_contract}" '
      type == "object"
      and (keys | sort == ["addition_digests","enforcement_generation",
        "merged_objective_digest","prior_contract_id",
        "prior_contract_revision","prior_objective_digest",
        "review_cycle_id","schema_version","scope_prompt_revision"])
      and .schema_version == 1
      and (.prior_contract_id == $prior.contract_id)
      and (.prior_contract_revision == $prior.contract_revision)
      and (.prior_contract_revision + 1 == $contract_revision)
      and (.prior_objective_digest == $prior.objective_digest)
      and (.merged_objective_digest == $new_digest)
      and (.review_cycle_id == $cycle
        and .review_cycle_id == $prior.review_cycle_id)
      and (.enforcement_generation == $enforcement
        and .enforcement_generation == $prior.ulw_enforcement_generation)
      and (.scope_prompt_revision | type == "number" and floor == .)
      and (.scope_prompt_revision > $prior.objective_prompt_revision)
      and (.scope_prompt_revision <= $prompt_revision)
      and (.addition_digests | type == "array"
        and length >= 1 and length <= 20
        and length == (unique | length)
        and all(.[]; type == "string" and test("^[A-Fa-f0-9]{8,40}$")))
    ' <<<"${transition}" >/dev/null 2>&1 || return 1

  [[ "$(read_state "quality_contract_prompt_revision" 2>/dev/null || true)" \
      == "${prompt_revision}" ]] || return 1
  [[ "$(read_state "review_cycle_id" 2>/dev/null || true)" == "${cycle}" ]] \
    || return 1
  current_objective_digest="$(_quality_contract_digest \
    "$(read_state "current_objective" 2>/dev/null || true)")" || return 1
  [[ "${current_objective_digest}" == "${new_objective_digest}" ]] || return 1

  # The transition carries only digests, but every addition must also remain in
  # the router's bounded per-objective idempotence ledger. A stale transition
  # or a stale ledger by itself is therefore insufficient authority.
  scope_ledger="$(read_state \
    "quality_contract_scope_addition_digests" 2>/dev/null || true)"
  [[ "${scope_ledger}" \
      =~ ^[A-Fa-f0-9]{8,40}(,[A-Fa-f0-9]{8,40}){0,19}$ ]] || return 1
  for addition_digest in $(jq -r '.addition_digests[]' <<<"${transition}"); do
    case ",${scope_ledger}," in
      *",${addition_digest},"*) ;;
      *) return 1 ;;
    esac
  done
}

quality_contract_build_envelope() {
  [[ "$#" -ge 11 && "$#" -le 12 ]] || return 1
  local definition="$1" cycle="$2" objective_ts="$3" prompt_revision="$4"
  local objective_digest="$5" enforcement_generation="$6" plan_revision="$7"
  local created_ts="$8" planner_agent="$9" native_agent_id="${10}"
  local lifecycle_dispatch_id="${11}" contract_revision="${12:-1}"
  local canonical payload_digest contract_identity contract_digest contract_id envelope
  local verification_threshold
  local profile_blocking_ids profile_metadata historical_profile_standards='[]'
  local prior_contract_file prior_contract prior_revision prior_objective_digest
  local prior_enforcement_generation late=false

  [[ "$(read_state "quality_constitution_status" 2>/dev/null || true)" != "invalid" ]] \
    || return 1
  # Validate every scalar before it is used in arithmetic, path selection, or
  # jq --argjson. These fields originate in hook/model output at some callers.
  _omc_canonical_uint_in_range \
    "${cycle}" 1 999999999999999 || return 1
  _omc_canonical_uint_in_range \
    "${objective_ts}" 1 999999999999999 || return 1
  _omc_canonical_uint_in_range \
    "${prompt_revision}" 1 999999999999999 || return 1
  _omc_canonical_uint_in_range \
    "${plan_revision}" 1 999999999999999 || return 1
  _omc_canonical_uint_in_range \
    "${created_ts}" 1 999999999999999 || return 1
  _omc_canonical_uint_in_range \
    "${contract_revision}" 1 999999999999999 || return 1
  [[ "${objective_digest}" =~ ^[A-Za-z0-9._:-]{8,128}$ ]] || return 1
  [[ "${enforcement_generation}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${planner_agent}" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || return 1
  [[ "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${lifecycle_dispatch_id}" =~ ^dispatch-[A-Za-z0-9._:-]{8,120}$ ]] || return 1
  verification_threshold="$(_quality_contract_verification_threshold)"
  if [[ "${contract_revision}" != "1" ]]; then
    prior_contract_file="$(session_file "quality_contract.json")"
    prior_contract="$(_quality_contract_read_json_file \
      "${prior_contract_file}" 65536)" || return 1
    quality_contract_validate_envelope "${prior_contract}" || return 1
    verification_threshold="$(jq -r '.verification_threshold // 40' \
      <<<"${prior_contract}")"
  fi
  _omc_canonical_uint_in_range \
    "${verification_threshold}" 0 100 || return 1
  canonical="$(quality_contract_canonicalize_payload \
    "${definition}" live "${verification_threshold}")" || return 1
  local criterion_count
  criterion_count="$(jq -r '.criteria | length' <<<"${canonical}")" || return 1
  [[ "${criterion_count}" =~ ^[0-9]+$ ]] || return 1
  # Reserve ten additive slots at the first freeze. Revisions remain globally
  # bounded by payload validation (20); hitting that explicit ceiling fails
  # closed and requires a human rescope/new objective rather than silent prose.
  if [[ "${contract_revision}" == "1" ]]; then
    [[ "${criterion_count}" -le 10 ]] || return 1
  fi
  profile_blocking_ids="$(_quality_contract_required_profile_ids_json)" || return 1
  profile_metadata="$(_quality_contract_profile_metadata_json)" || return 1
  if [[ "${contract_revision}" != "1" ]]; then
    prior_revision="$(jq -r '.contract_revision' <<<"${prior_contract}")"
    _omc_canonical_uint_in_range \
      "${prior_revision}" 1 999999999999998 || return 1
    [[ $((prior_revision + 1)) -eq "${contract_revision}" ]] || return 1
    prior_objective_digest="$(jq -r '.objective_digest' <<<"${prior_contract}")"
    prior_enforcement_generation="$(jq -r \
      '.ulw_enforcement_generation' <<<"${prior_contract}")"
    [[ "$(jq -r '.review_cycle_id' <<<"${prior_contract}")" == "${cycle}" \
        && "$(jq -r '.objective_prompt_ts' <<<"${prior_contract}")" == "${objective_ts}" \
        && "${prior_enforcement_generation}" == "${enforcement_generation}" ]] \
      || return 1
    if [[ "${prior_objective_digest}" != "${objective_digest}" ]]; then
      _quality_contract_scope_transition_allows_digest_change \
        "${prior_contract}" "${objective_digest}" "${prompt_revision}" \
        "${cycle}" "${enforcement_generation}" "${contract_revision}" \
        || return 1
    fi
    historical_profile_standards="$(jq -cS \
      '[.definition.standards[] | select(.kind == "profile")]' \
      <<<"${prior_contract}")" || return 1
  fi
  quality_contract_validate_profile_bindings \
    "${canonical}" "${profile_blocking_ids}" \
    "${historical_profile_standards}" || return 1
  # `late` diagnoses only the forbidden first freeze after implementation has
  # begun. A later revision is admitted by record-plan only after it preserves
  # both the immutable pre-mutation floor and the current contract, so marking
  # that additive re-contract late would deadlock legitimate scope expansion.
  if [[ "${contract_revision}" == "1" ]] \
      && [[ -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
    late=true
  fi
  payload_digest="$(_quality_contract_digest "${canonical}")" || return 1
  contract_identity="$(jq -cnS \
    --argjson contract_revision "${contract_revision}" \
    --argjson review_cycle_id "${cycle}" \
    --argjson objective_prompt_ts "${objective_ts}" \
    --argjson objective_prompt_revision "${prompt_revision}" \
    --arg objective_digest "${objective_digest}" \
    --arg enforcement_generation "${enforcement_generation}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson verification_threshold "${verification_threshold}" \
    --argjson created_ts "${created_ts}" \
    --arg planner_agent "${planner_agent}" \
    --arg native_agent_id "${native_agent_id}" \
    --arg lifecycle_dispatch_id "${lifecycle_dispatch_id}" \
    --arg payload_digest "${payload_digest}" \
    --argjson profile_blocking_ids "${profile_blocking_ids}" \
    --argjson quality_constitution_generation "$(jq -r '.generation' <<<"${profile_metadata}")" \
    --arg quality_constitution_digest "$(jq -r '.digest' <<<"${profile_metadata}")" \
    --argjson late "${late}" '
      {contract_revision:$contract_revision,review_cycle_id:$review_cycle_id,
       objective_prompt_ts:$objective_prompt_ts,
       objective_prompt_revision:$objective_prompt_revision,
       objective_digest:$objective_digest,
       ulw_enforcement_generation:$enforcement_generation,
       plan_revision:$plan_revision,verification_threshold:$verification_threshold,
       created_ts:$created_ts,
       planner:{agent_type:$planner_agent,native_agent_id:$native_agent_id,
                lifecycle_dispatch_id:$lifecycle_dispatch_id},
       payload_digest:$payload_digest,profile_blocking_ids:$profile_blocking_ids,
       quality_constitution_generation:$quality_constitution_generation,
       quality_constitution_digest:$quality_constitution_digest,
       late:$late}'
  )" || return 1
  contract_digest="$(_quality_contract_digest "${contract_identity}")" || return 1
  contract_id="qc-${contract_digest}"
  envelope="$(jq -cnS \
    --argjson definition "${canonical}" \
    --arg contract_id "${contract_id}" \
    --argjson contract_revision "${contract_revision}" \
    --argjson review_cycle_id "${cycle}" \
    --argjson objective_prompt_ts "${objective_ts}" \
    --argjson objective_prompt_revision "${prompt_revision}" \
    --arg objective_digest "${objective_digest}" \
    --arg enforcement_generation "${enforcement_generation}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson verification_threshold "${verification_threshold}" \
    --argjson created_ts "${created_ts}" \
    --arg planner_agent "${planner_agent}" \
    --arg native_agent_id "${native_agent_id}" \
    --arg lifecycle_dispatch_id "${lifecycle_dispatch_id}" \
    --arg payload_digest "${payload_digest}" \
    --argjson profile_blocking_ids "${profile_blocking_ids}" \
    --argjson quality_constitution_generation "$(jq -r '.generation' <<<"${profile_metadata}")" \
    --arg quality_constitution_digest "$(jq -r '.digest' <<<"${profile_metadata}")" \
    --argjson late "${late}" '
      {_v:2,contract_id:$contract_id,contract_revision:$contract_revision,
       review_cycle_id:$review_cycle_id,objective_prompt_ts:$objective_prompt_ts,
       objective_prompt_revision:$objective_prompt_revision,
       objective_digest:$objective_digest,
       ulw_enforcement_generation:$enforcement_generation,
       plan_revision:$plan_revision,verification_threshold:$verification_threshold,
       created_ts:$created_ts,
       planner:{agent_type:$planner_agent,native_agent_id:$native_agent_id,
                lifecycle_dispatch_id:$lifecycle_dispatch_id},
       definition:$definition,payload_digest:$payload_digest,
       profile_blocking_ids:$profile_blocking_ids,
       quality_constitution_generation:$quality_constitution_generation,
       quality_constitution_digest:$quality_constitution_digest,late:$late}'
  )" || return 1
  quality_contract_validate_envelope "${envelope}" || return 1
  printf '%s' "${envelope}"
}

quality_contract_validate_envelope() {
  local json="${1:-}" definition canonical payload_digest contract_identity expected_id
  [[ -n "${json}" && ${#json} -le 65536 ]] || return 1
  jq -e '
    type == "object"
    and all(.. | strings; index("\u0000") == null)
    and ((._v == 1 and (keys | sort == ["_v","contract_id","contract_revision","created_ts",
        "definition","late","objective_digest","objective_prompt_revision",
        "objective_prompt_ts","payload_digest","plan_revision","planner",
        "profile_blocking_ids","quality_constitution_digest",
        "quality_constitution_generation","review_cycle_id","ulw_enforcement_generation"]))
      or (._v == 2 and (keys | sort == ["_v","contract_id","contract_revision","created_ts",
        "definition","late","objective_digest","objective_prompt_revision",
        "objective_prompt_ts","payload_digest","plan_revision","planner",
        "profile_blocking_ids","quality_constitution_digest",
        "quality_constitution_generation","review_cycle_id","ulw_enforcement_generation",
        "verification_threshold"])))
    and (.contract_id | type == "string" and test("^qc-[A-Za-z0-9._:-]{8,80}$"))
    and (.contract_revision | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and (.review_cycle_id | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and (.objective_prompt_ts | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and (.objective_prompt_revision | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and (.objective_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,128}$"))
    and (.ulw_enforcement_generation | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.plan_revision | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and (if ._v == 2 then
      (.verification_threshold | type == "number" and floor == .
        and . >= 0 and . <= 100)
      else (has("verification_threshold") | not) end)
    and (.created_ts | type == "number" and floor == .
      and . >= 1 and . <= 999999999999999)
    and .created_ts >= .objective_prompt_ts
    and (.payload_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,80}$"))
    and (.late | type == "boolean")
    and (.profile_blocking_ids | type == "array" and length == (unique | length)
      and all(.[]; type == "string" and test("^[A-Za-z0-9._:-]{3,128}$")))
    and (.quality_constitution_generation | type == "number" and floor == .
      and . >= 0 and . <= 999999999999999)
    and (.quality_constitution_digest | type == "string"
      and test("^(none|[a-f0-9]{64})$"))
    and (.planner | type == "object"
      and (keys | sort == ["agent_type","lifecycle_dispatch_id","native_agent_id"])
      and (.agent_type | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,120}$")))
  ' <<<"${json}" >/dev/null 2>&1 || return 1

  definition="$(jq -c '.definition' <<<"${json}")" || return 1
  canonical="$(quality_contract_canonicalize_payload \
    "${definition}" intrinsic)" || return 1
  payload_digest="$(_quality_contract_digest "${canonical}")" || return 1
  [[ "$(jq -r '.payload_digest' <<<"${json}")" == "${payload_digest}" ]] || return 1
  contract_identity="$(jq -cS '
    if ._v == 2 then
      {contract_revision,review_cycle_id,objective_prompt_ts,
       objective_prompt_revision,objective_digest,ulw_enforcement_generation,
       plan_revision,verification_threshold,created_ts,planner,payload_digest,
       profile_blocking_ids,quality_constitution_generation,
       quality_constitution_digest,late}
    else
      {contract_revision,review_cycle_id,objective_prompt_ts,
       objective_prompt_revision,objective_digest,ulw_enforcement_generation,
       plan_revision,created_ts,planner,payload_digest,profile_blocking_ids,
       quality_constitution_generation,quality_constitution_digest,late}
    end
  ' <<<"${json}")" || return 1
  expected_id="qc-$(_quality_contract_digest "${contract_identity}")" || return 1
  [[ "$(jq -r '.contract_id' <<<"${json}")" == "${expected_id}" ]]
}

quality_contract_canonicalize_envelope() {
  local json="${1:-}" canonical_definition
  quality_contract_validate_envelope "${json}" || return 1
  canonical_definition="$(quality_contract_canonicalize_payload \
    "$(jq -c '.definition' <<<"${json}")" intrinsic)" || return 1
  jq -cS --argjson definition "${canonical_definition}" \
    '.definition = $definition' <<<"${json}"
}

quality_contract_revision_preserves_floor() {
  local new_definition="${1:-}" old_envelope="${2:-}" validation_mode="${3:-live}"
  local canonical_new canonical_old threshold
  threshold="$(jq -r '.verification_threshold // 40' \
    <<<"${old_envelope}" 2>/dev/null || true)"
  _omc_canonical_uint_in_range "${threshold}" 0 100 || return 1
  canonical_new="$(quality_contract_canonicalize_payload \
    "${new_definition}" "${validation_mode}" "${threshold}")" || return 1
  canonical_old="$(quality_contract_canonicalize_envelope \
    "${old_envelope}")" || return 1
  jq -en --argjson new "${canonical_new}" --argjson old "${canonical_old}" '
    # Once mutation begins, the north star and every articulated dimension are
    # a floor, not planner prose that can be rewritten to fit the artifact.
    ($new.north_star == $old.definition.north_star)
    and ($new.audience == $old.definition.audience)
    and ($new.stakes == $old.definition.stakes)
    and ($new.ambition_boundary == $old.definition.ambition_boundary)
    and ($new.axes == $old.definition.axes)
    and ($old.definition.criteria
      | all(.[]; . as $old_criterion
        | any($new.criteria[]; .id == $old_criterion.id and . == $old_criterion)))
    and ($old.definition.anti_goals
      | all(.[]; . as $old_anti_goal | $new.anti_goals | index($old_anti_goal)))
    and ($old.definition.standards
      | all(.[]; . as $old_standard
        | any($new.standards[]; . == $old_standard)))
  ' >/dev/null 2>&1
}

_quality_contract_file_size() {
  local path="${1:-}" value=""
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  # BSD stat and GNU stat reuse `-f` for unrelated operations. Select the
  # implementation from Bash's host tag instead of accepting a numeric-looking
  # filesystem-stat result as a file size.
  case "${OSTYPE:-}" in
    darwin*|freebsd*|netbsd*|openbsd*)
      value="$(command stat -f '%z' "${path}" 2>/dev/null || true)"
      ;;
    linux*)
      value="$(command stat -c '%s' "${path}" 2>/dev/null || true)"
      ;;
    *) return 1 ;;
  esac
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

_quality_contract_reader_test_barrier() {
  local source="${1:-}"
  local ready="${OMC_TEST_QUALITY_CONTRACT_READER_READY_FILE:-}"
  local release="${OMC_TEST_QUALITY_CONTRACT_READER_RELEASE_FILE:-}"
  local match="${OMC_TEST_QUALITY_CONTRACT_READER_MATCH_FILE:-}"
  local attempts=0
  [[ -z "${match}" || "${match}" == "${source}" ]] || return 0
  if [[ -z "${ready}" && -z "${release}" ]]; then
    return 0
  fi
  [[ "${ready}" == /* && "${release}" == /* \
      && "${ready}" != "${release}" \
      && "${ready}" != "${source}" && "${release}" != "${source}" \
      && ! -L "${ready}" && ! -L "${release}" ]] || return 1
  printf '%s\n' "${source}" >"${ready}" || return 1
  while [[ ! -e "${release}" && ! -L "${release}" \
      && "${attempts}" -lt 1000 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [[ -f "${release}" && ! -L "${release}" ]]
}

# Parse one persisted JSON/JSONL authority from a private, bounded regular-file
# snapshot. A hard link first pins the exact public inode without opening a
# replacement FIFO/device. The bounded copy is then parsed in a mode-700
# directory, and a second hard link re-attests the public source's identity and
# digest before any parsed bytes are emitted. This closes the raw-check/size/jq
# pathname race without putting a potentially multi-megabyte JSON value in argv.
_quality_contract_read_private_json_snapshot() (
  local file="${1:-}" max_bytes="${2:-}" mode="${3:-json}"
  local max_lines="${4:-0}" private_dir="" source_link="" snapshot=""
  local reattest_link="" source_size="" snapshot_size=""
  local source_digest="" copied_digest="" reattest_digest="" payload=""
  local descriptor_digest="" hasher="" hash_output=""
  local snapshot_identity="" descriptor_identity_8=""
  local descriptor_identity_9=""
  local copy_limit=0 cleanup_rc=0 fallback_base=""
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"

  _quality_contract_snapshot_cleanup() {
    local rc=0
    [[ -z "${reattest_link}" ]] \
      || command rm -f -- "${reattest_link}" 2>/dev/null || rc=1
    [[ -z "${snapshot}" ]] \
      || command rm -f -- "${snapshot}" 2>/dev/null || rc=1
    [[ -z "${source_link}" ]] \
      || command rm -f -- "${source_link}" 2>/dev/null || rc=1
    [[ -z "${private_dir}" ]] \
      || command rmdir -- "${private_dir}" 2>/dev/null || rc=1
    return "${rc}"
  }
  trap '_quality_contract_snapshot_cleanup >/dev/null 2>&1 || true' EXIT
  trap 'exit 1' HUP INT TERM

  [[ -n "${file}" && -f "${file}" && ! -L "${file}" && -r "${file}" ]] \
    || return 1
  _omc_canonical_uint_in_range "${max_bytes}" 1 2097152 || return 1
  case "${mode}" in
    json) [[ "${max_lines}" == "0" ]] || return 1 ;;
    jsonl)
      _omc_canonical_uint_in_range "${max_lines}" 1 4096 || return 1
      ;;
    *) return 1 ;;
  esac

  # The adjacent directory keeps the hard link on the source filesystem. A
  # read-only source parent may fall back to TMPDIR, but only if the subsequent
  # hard link proves that both locations share a filesystem; otherwise this
  # authority read fails closed rather than reopening the public pathname.
  private_dir="$(command mktemp -d \
    "${file}.quality-read.XXXXXX" 2>/dev/null || true)"
  if [[ -z "${private_dir}" ]]; then
    fallback_base="${TMPDIR:-/tmp}"
    [[ "${fallback_base}" == /* && -d "${fallback_base}" \
        && ! -L "${fallback_base}" ]] || return 1
    private_dir="$(command mktemp -d \
      "${fallback_base%/}/omc-quality-read.XXXXXX" 2>/dev/null || true)"
  fi
  [[ -n "${private_dir}" && -d "${private_dir}" \
      && ! -L "${private_dir}" ]] || return 1
  command chmod 700 "${private_dir}" || return 1
  source_link="${private_dir}/source-link"
  snapshot="${private_dir}/snapshot"
  reattest_link="${private_dir}/source-reattest"
  command ln -- "${file}" "${source_link}" 2>/dev/null || return 1
  [[ -f "${source_link}" && ! -L "${source_link}" \
      && -f "${file}" && ! -L "${file}" \
      && "${source_link}" -ef "${file}" ]] || return 1

  source_size="$(_quality_contract_file_size "${source_link}")" || return 1
  _omc_canonical_uint_in_range "${source_size}" 0 "${max_bytes}" || return 1
  _omc_regular_file_has_no_raw_nul "${source_link}" "${max_bytes}" || return 1
  source_digest="$(_verification_sha256_file "${source_link}")" || return 1
  [[ "${source_digest}" =~ ^[a-f0-9]{64}$ ]] || return 1

  copy_limit=$((max_bytes + 1))
  if ! (umask 077; command head -c "${copy_limit}" \
      <"${source_link}" >"${snapshot}"); then
    return 1
  fi
  command chmod 400 "${snapshot}" || return 1
  [[ -f "${snapshot}" && ! -L "${snapshot}" ]] || return 1
  snapshot_size="$(_quality_contract_file_size "${snapshot}")" || return 1
  [[ "${snapshot_size}" == "${source_size}" ]] || return 1
  _omc_regular_file_has_no_raw_nul "${snapshot}" "${max_bytes}" || return 1
  copied_digest="$(_verification_sha256_file "${snapshot}")" || return 1
  [[ "${copied_digest}" == "${source_digest}" \
      && "$(_verification_sha256_file "${source_link}" 2>/dev/null || true)" \
        == "${source_digest}" ]] || return 1
  snapshot_identity="$(_omc_regular_file_identity "${snapshot}")" \
    || return 1

  # Bind both validation and parsing to the exact copied inode. The pathname
  # lives in a mode-700 directory, but another process under the same account
  # could still rename it. Two independently opened descriptors plus their
  # fstat identities reject a swap between opens on both GNU and BSD systems;
  # hashing fd 8 proves that fd 9 (the parser input) is the source-bound
  # generation without putting its bytes in argv.
  exec 8<"${snapshot}" || return 1
  exec 9<"${snapshot}" || return 1
  descriptor_identity_8="$(_omc_regular_fd_identity 8)" || return 1
  descriptor_identity_9="$(_omc_regular_fd_identity 9)" || return 1
  [[ "${descriptor_identity_8}" == "${snapshot_identity}" \
      && "${descriptor_identity_9}" == "${snapshot_identity}" \
      && "$(_omc_regular_file_identity "${snapshot}" 2>/dev/null || true)" \
        == "${snapshot_identity}" ]] || return 1
  hasher="$(_verification_trusted_sha256_executable)" || return 1
  case "${hasher##*/}" in
    shasum)
      hash_output="$(command -- "${hasher}" -a 256 <&8 2>/dev/null)" \
        || return 1
      ;;
    sha256sum)
      hash_output="$(command -- "${hasher}" <&8 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  descriptor_digest="$(_verification_sha256_output_digest \
    "${hash_output}")" || return 1
  [[ "${descriptor_digest}" == "${source_digest}" ]] || return 1

  if [[ "${mode}" == "jsonl" ]]; then
    payload="$(jq -Rsce --argjson max_lines "${max_lines}" '
      def decoded_nul_free:
        all(.. | strings; index("\u0000") == null)
        and all(.. | objects | keys[]; index("\u0000") == null);
      if . == "" then []
      elif (endswith("\n") | not) then error("unterminated JSONL")
      else split("\n")[0:-1] as $physical_rows
        | if ($physical_rows | length) > $max_lines then
            error("too many JSONL rows")
          else [$physical_rows[] | select(length > 0) | fromjson]
          end
      end
      | if decoded_nul_free then . else error("decoded NUL") end
    ' <&9 2>/dev/null)" || return 1
  else
    payload="$(jq -sce '
      def decoded_nul_free:
        all(.. | strings; index("\u0000") == null)
        and all(.. | objects | keys[]; index("\u0000") == null);
      if length == 1 and (.[0] | decoded_nul_free) then .[0]
      else error("invalid JSON authority") end
    ' <&9 2>/dev/null)" || return 1
  fi
  exec 8<&- 9<&-
  [[ "$(_verification_sha256_file "${snapshot}" 2>/dev/null || true)" \
      == "${source_digest}" ]] || return 1

  _quality_contract_reader_test_barrier "${file}" || return 1

  # Pin the public pathname a second time. If it was atomically replaced with
  # another regular file, symlink, FIFO, or device, either link admission or the
  # exact device/inode comparison fails without parsing/reading that node.
  command ln -- "${file}" "${reattest_link}" 2>/dev/null || return 1
  [[ -f "${file}" && ! -L "${file}" \
      && -f "${reattest_link}" && ! -L "${reattest_link}" \
      && "${reattest_link}" -ef "${source_link}" \
      && "${file}" -ef "${source_link}" \
      && "$(_quality_contract_file_size "${reattest_link}" 2>/dev/null || true)" \
        == "${source_size}" ]] || return 1
  _omc_regular_file_has_no_raw_nul "${reattest_link}" "${max_bytes}" || return 1
  reattest_digest="$(_verification_sha256_file "${reattest_link}")" || return 1
  [[ "${reattest_digest}" == "${source_digest}" \
      && -f "${file}" && ! -L "${file}" \
      && "${file}" -ef "${source_link}" ]] || return 1

  trap - HUP INT TERM
  _quality_contract_snapshot_cleanup || cleanup_rc=$?
  trap - EXIT
  [[ "${cleanup_rc}" -eq 0 ]] || return 1
  printf '%s\n' "${payload}"
)

_quality_contract_read_json_file() {
  local file="${1:-}" max_bytes="${2:-65536}"
  _omc_canonical_uint_in_range "${max_bytes}" 1 2097152 || return 1
  _quality_contract_read_private_json_snapshot \
    "${file}" "${max_bytes}" json 0
}

_quality_contract_previous_profile_standards() {
  local current="${1:-}" revision history_file history previous
  local previous_objective_digest current_objective_digest
  revision="$(jq -r '.contract_revision // 0' <<<"${current}" 2>/dev/null || true)"
  _omc_canonical_uint_in_range \
    "${revision}" 1 999999999999999 || return 1
  if [[ "${revision}" == "1" ]]; then
    printf '[]'
    return 0
  fi
  history_file="$(session_file "quality_contract_history.jsonl")"
  history="$(_quality_contract_read_jsonl_array \
    "${history_file}" 2097152 24)" || return 1
  jq -e 'type == "array" and length >= 1 and length <= 24' \
    <<<"${history}" >/dev/null 2>&1 || return 1
  previous="$(jq -ce 'last | del(.archived_at,.archive_reason)' \
    <<<"${history}" 2>/dev/null)" || return 1
  quality_contract_validate_envelope "${previous}" || return 1
  jq -e --argjson expected "$((revision - 1))" --argjson current "${current}" '
    .contract_revision == $expected
    and .review_cycle_id == $current.review_cycle_id
    and .objective_prompt_ts == $current.objective_prompt_ts
  ' <<<"${previous}" >/dev/null 2>&1 || return 1
  previous_objective_digest="$(jq -r '.objective_digest' <<<"${previous}")"
  current_objective_digest="$(jq -r '.objective_digest' <<<"${current}")"
  if [[ "${previous_objective_digest}" != "${current_objective_digest}" ]]; then
    # Publication already consumed the exact one-use router transition. Keep
    # enough sealed adjacency checks here for later current validation: only a
    # newer prompt-bound, floor-preserving contract in the same objective cycle
    # may have a different objective digest in its immediately prior history.
    [[ "$(jq -r '.objective_prompt_revision' <<<"${current}")" \
        -gt "$(jq -r '.objective_prompt_revision' <<<"${previous}")" ]] \
      || return 1
    quality_contract_revision_preserves_floor \
      "$(jq -c '.definition' <<<"${current}")" "${previous}" intrinsic \
      || return 1
  fi
  jq -cS '[.definition.standards[] | select(.kind == "profile")]' \
    <<<"${previous}"
}

quality_contract_validate_current() {
  local contract_file="${1:-}" contract cycle objective_ts objective_digest
  local objective_prompt_revision enforcement plan_revision contract_id
  local contract_revision contract_late mirror scope_recheck first_mutation_ts
  local floor_file floor frozen_id frozen_revision frozen_payload_digest
  local current_profile_ids current_profile_metadata historical_profile_standards
  if [[ -z "${contract_file}" ]]; then
    contract_file="$(session_file "quality_contract.json")"
  fi
  contract="$(_quality_contract_read_json_file "${contract_file}" 65536)" || return 1
  quality_contract_validate_envelope "${contract}" || return 1
  # A first contract authored after mutation is diagnostic evidence of a
  # sequencing failure, never an acceptable quality bar.
  [[ "$(jq -r '.late' <<<"${contract}")" == "false" ]] || return 1

  cycle="$(read_state "review_cycle_id" 2>/dev/null || true)"
  objective_ts="$(read_state "review_cycle_prompt_ts" 2>/dev/null || true)"
  [[ "${objective_ts}" =~ ^[0-9]+$ ]] \
    || objective_ts="$(read_state "last_user_prompt_ts" 2>/dev/null || true)"
  objective_digest="$(_quality_contract_digest \
    "$(read_state "current_objective" 2>/dev/null || true)")" || return 1
  objective_prompt_revision="$(read_state "quality_contract_prompt_revision" 2>/dev/null || true)"
  # The contract belongs to the objective, not to one assistant-turn callback
  # interval. Advisory/checkpoint Stop legitimately closes the current ULW
  # enforcement generation; a later bare continuation opens a new one while
  # preserving the same objective and frozen bar. Planner/reviewer dispatch
  # rows still bind to the live per-turn generation independently.
  enforcement="$(read_state "quality_contract_enforcement_generation" 2>/dev/null || true)"
  [[ -n "${enforcement}" ]] \
    || enforcement="$(read_state "ulw_enforcement_generation" 2>/dev/null || true)"
  plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
  contract_id="$(read_state "quality_contract_id" 2>/dev/null || true)"
  contract_revision="$(read_state "quality_contract_revision" 2>/dev/null || true)"
  contract_late="$(read_state "quality_contract_late" 2>/dev/null || true)"
  scope_recheck="$(read_state "quality_contract_recheck_required" 2>/dev/null || true)"

  [[ "$(read_state "quality_constitution_status" 2>/dev/null || true)" != "invalid" ]] \
    || return 1
  [[ "${scope_recheck}" != "1" ]] || return 1
  [[ "${cycle}" =~ ^[0-9]+$ && "${objective_ts}" =~ ^[0-9]+$ \
      && "${plan_revision}" =~ ^[0-9]+$ ]] || return 1
  [[ "$(jq -r '.review_cycle_id' <<<"${contract}")" == "${cycle}" ]] || return 1
  [[ "$(jq -r '.objective_prompt_ts' <<<"${contract}")" == "${objective_ts}" ]] || return 1
  [[ "${objective_prompt_revision}" =~ ^[0-9]+$ ]] || return 1
  [[ "$(jq -r '.objective_prompt_revision' <<<"${contract}")" == "${objective_prompt_revision}" ]] || return 1
  [[ "$(jq -r '.objective_digest' <<<"${contract}")" == "${objective_digest}" ]] || return 1
  [[ "$(jq -r '.ulw_enforcement_generation' <<<"${contract}")" == "${enforcement}" ]] || return 1
  [[ "$(jq -r '.plan_revision' <<<"${contract}")" == "${plan_revision}" ]] || return 1
  current_profile_ids="$(_quality_contract_required_profile_ids_json)" || return 1
  [[ "$(jq -cS '.profile_blocking_ids | unique | sort' <<<"${contract}")" \
      == "${current_profile_ids}" ]] || return 1
  historical_profile_standards="$(_quality_contract_previous_profile_standards \
    "${contract}")" || return 1
  quality_contract_validate_profile_bindings \
    "$(jq -c '.definition' <<<"${contract}")" "${current_profile_ids}" \
    "${historical_profile_standards}" || return 1
  current_profile_metadata="$(_quality_contract_profile_metadata_json)" || return 1
  [[ "$(jq -r '.quality_constitution_generation' <<<"${contract}")" \
      == "$(jq -r '.generation' <<<"${current_profile_metadata}")" ]] || return 1
  [[ "$(jq -r '.quality_constitution_digest' <<<"${contract}")" \
      == "$(jq -r '.digest' <<<"${current_profile_metadata}")" ]] || return 1
  [[ -z "${contract_id}" || "$(jq -r '.contract_id' <<<"${contract}")" == "${contract_id}" ]] || return 1
  [[ -z "${contract_revision}" || "$(jq -r '.contract_revision' <<<"${contract}")" == "${contract_revision}" ]] || return 1
  if [[ -n "${contract_late}" ]]; then
    case "${contract_late}" in
      1|true) contract_late="true" ;;
      0|false) contract_late="false" ;;
      *) return 1 ;;
    esac
    [[ "$(jq -r '.late' <<<"${contract}")" == "${contract_late}" ]] || return 1
  fi
  mirror="$(read_state "quality_contract_cycle_id" 2>/dev/null || true)"
  [[ -z "${mirror}" || "$(jq -r '.review_cycle_id' <<<"${contract}")" == "${mirror}" ]] || return 1
  mirror="$(read_state "quality_contract_plan_revision" 2>/dev/null || true)"
  [[ -z "${mirror}" || "$(jq -r '.plan_revision' <<<"${contract}")" == "${mirror}" ]] || return 1

  # After the first mutation, the immutable pre-mutation floor is part of the
  # live authority—not merely a pretool convenience. Stop, review dispatch,
  # compaction, and ordinary current-contract validation all fail closed if it
  # disappears, is replaced, or the current additive revision weakens it.
  first_mutation_ts="$(read_state "first_mutation_ts" 2>/dev/null || true)"
  if [[ -n "${first_mutation_ts}" ]]; then
    [[ "${first_mutation_ts}" =~ ^[1-9][0-9]*$ ]] || return 1
    floor_file="$(session_file "quality_contract_floor.json")"
    floor="$(_quality_contract_read_json_file "${floor_file}" 65536)" || return 1
    quality_contract_validate_envelope "${floor}" || return 1
    [[ "$(jq -r '.late' <<<"${floor}")" == "false" ]] || return 1
    frozen_id="$(read_state "quality_contract_frozen_id" 2>/dev/null || true)"
    frozen_revision="$(read_state "quality_contract_frozen_revision" 2>/dev/null || true)"
    frozen_payload_digest="$(read_state "quality_contract_frozen_payload_digest" 2>/dev/null || true)"
    [[ "${frozen_id}" == "$(jq -r '.contract_id' <<<"${floor}")" ]] || return 1
    [[ "${frozen_revision}" == "$(jq -r '.contract_revision' <<<"${floor}")" ]] || return 1
    [[ "${frozen_payload_digest}" == "$(jq -r '.payload_digest' <<<"${floor}")" ]] || return 1
    quality_contract_revision_preserves_floor \
      "$(jq -c '.definition' <<<"${contract}")" "${floor}" intrinsic || return 1
  fi
  quality_contract_canonicalize_envelope "${contract}"
}

_quality_contract_cost_only_text() {
  local text="${1:-}" lower context cost time_pressure frontier_scope
  local accessibility_quality
  # Deliberately mirror jq's `ascii_downcase`: locale-aware folding would make
  # publication and the in-gate recheck disagree on non-ASCII boundaries.
  # shellcheck disable=SC2018,SC2019
  lower="$(LC_ALL=C printf '%s' "${text}" | LC_ALL=C tr 'A-Z' 'a-z')"
  # User difficulty ("navigation is too hard") and product latency ("takes
  # too long") are legitimate quality findings. Reject only an implementation
  # effort/cost rationale, irrespective of decorative words such as "tested";
  # real counterevidence is established by its bound receipt, not prose.
  context='(implementation|implementing|change|changing|fix|fixing|solution|refactor|refactoring|rewrite|scope|work|engineering|build|building|development|developing)'
  cost='(too (expensive|costly|large|hard)|takes? too long|time[- ]consuming|requires? (significant|too much) (effort|work|time)|not worth (it|the effort)|blocked by (cost|complexity)|risk(y)? to change)'
  accessibility_quality='too hard for[^.!?]{0,80}(keyboard|screen[- ]reader|users?|customers?)[^.!?]{0,80}(use|navigate|operate|complete|understand|access)'
  # Correlate engineering context and cost across the whole bounded decision
  # field. Sentence punctuation is not an authority boundary, and a product
  # noun such as render/load/checkout must never whitelist an implementation
  # cost rationale. The sole override is an unmistakable accessibility impact
  # on named users performing a product action.
  if LC_ALL=C printf '%s' "${lower}" | LC_ALL=C grep -Eq \
      "(^|[^A-Za-z0-9_])${context}([^A-Za-z0-9_]|$)" \
      && LC_ALL=C printf '%s' "${lower}" | LC_ALL=C grep -Eq \
        "(^|[^A-Za-z0-9_])${cost}([^A-Za-z0-9_]|$)"; then
    if LC_ALL=C printf '%s' "${lower}" \
        | LC_ALL=C grep -Eq "${accessibility_quality}"; then
      return 1
    fi
    return 0
  fi
  time_pressure='(we ran out of time|our time ran out|we had no (more )?time|we lacked time|no time remained|we ran out of runway|(time constraints?|limited time|time limitations?|scheduling constraints?) (prevented|constrained|blocked|did not permit|did not allow|left)|the (time budget|schedule) (did not|does not|would not) (permit|allow)|the timebox (ended|expired)|insufficient time|not enough time|too little time|before the deadline|deadline([ -]driven)? pressure|([^A-Za-z0-9_]|^)(the |our |implementation |work |review )?deadline (arrived|expired|passed|left|limited|prevented|constrained)|(our|implementation|work|review) session (ended|was over|is over))'
  frontier_scope='(improvement|alternative|candidate|option|experiment|explor|scope|step[- ]change|leap)'
  LC_ALL=C printf '%s' "${lower}" | LC_ALL=C grep -Eq "${time_pressure}" \
    && LC_ALL=C printf '%s' "${lower}" \
      | LC_ALL=C grep -Eq "${frontier_scope}"
}

quality_review_validate_payload() {
  local json="${1:-}" decision_text redacted=""
  [[ -n "${json}" && ${#json} -le 32768 ]] || return 1
  if declare -F omc_redact_secrets >/dev/null 2>&1; then
    redacted="$(printf '%s' "${json}" | omc_redact_secrets)" || return 1
    [[ "${redacted}" == "${json}" ]] || return 1
  fi
  jq -e '
    def text($min;$max):
      type == "string" and length <= $max
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length >= $min)
      and (test("[\u0000-\u001f\u007f]") | not);
    def ids:
      type == "array" and length == (unique | length)
      and all(.[]; type == "string" and test("^Q-[0-9]{3}$"));
    def refs:
      type == "array" and length >= 1 and length <= 20
      and length == (unique | length)
      and (map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        | length == (unique | length))
      and all(.[]; type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$"));
    def evidence_kind:
      . == "test" or . == "render" or . == "benchmark"
      or . == "inspection" or . == "comparison" or . == "source"
      or . == "review";
    type == "object"
    and (keys | sort == ["alternatives_searched","criteria","frontier","limits"])
    and (.criteria | type == "array" and length >= 5 and length <= 20
      and ([.[].id] | length == (unique | length))
      and all(.[]; type == "object"
        and (keys | sort == ["basis","evidence_kind","id","refs","status"])
        and (.id | type == "string" and test("^Q-[0-9]{3}$"))
        and (.status == "met" or .status == "unmet")
        and (.evidence_kind | evidence_kind)
        and (.basis | text(4;1500))
        and (.refs | refs)))
    and (.alternatives_searched | type == "array" and length >= 2 and length <= 10
      and length == (unique | length)
      and (map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        | length == (unique | length))
      and all(.[]; text(8;1000)))
    and (.limits | type == "array" and length >= 1 and length <= 10
      and length == (unique | length)
      and (map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        | length == (unique | length))
      and all(.[]; text(4;500)))
    and (.frontier | type == "object"
      and (keys | sort == ["bar_quality","criterion_ids","evidence","experiment",
        "material","recommended_move","title","why"])
      and (.material | type == "boolean")
      and (.bar_quality == "strong" or .bar_quality == "weak")
      and (.title | text(4;500))
      and (.why | text(4;1500))
      and (.recommended_move | text(4;1500))
      and (.criterion_ids | ids)
      and (.evidence | refs)
      and (.experiment | text(4;1500)))
  ' <<<"${json}" >/dev/null 2>&1 || return 1
  while IFS= read -r decision_text; do
    if _quality_contract_cost_only_text "${decision_text}"; then
      return 1
    fi
  done < <(jq -r '.criteria[].basis, .frontier.title, .frontier.why,
    .frontier.recommended_move, .frontier.experiment,
    .alternatives_searched[], .limits[]' \
    <<<"${json}")
}

quality_review_canonicalize_payload() {
  local json="${1:-}" canonical=""
  quality_review_validate_payload "${json}" || return 1
  canonical="$(jq -cS '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    .criteria |= (map(.basis |= trim | .refs |= (map(trim) | unique)) | sort_by(.id))
    | .alternatives_searched |= (map(trim) | unique)
    | .limits |= (map(trim) | unique)
    | .frontier.title |= trim
    | .frontier.why |= trim
    | .frontier.recommended_move |= trim
    | .frontier.experiment |= trim
    | .frontier.criterion_ids |= unique
    | .frontier.evidence |= (map(trim) | unique)
  ' <<<"${json}")" || return 1
  quality_review_validate_payload "${canonical}" || return 1
  printf '%s\n' "${canonical}"
}

quality_review_validate_against_contract() {
  local review="${1:-}" contract="${2:-}" verdict="${3:-}"
  local canonical_review canonical_contract token expected_count actual_count
  canonical_review="$(quality_review_canonicalize_payload "${review}")" || return 1
  canonical_contract="$(quality_contract_canonicalize_envelope "${contract}")" || return 1

  jq -e --argjson contract "${canonical_contract}" '
    . as $review
    | ([$review.criteria[].refs[]] | unique) as $assessment_refs
    | ([$review.criteria[].id] | sort) == ([$contract.definition.criteria[].id] | sort)
    and all($review.frontier.evidence[]; . as $ref
        | ($assessment_refs | index($ref)) != null)
    and all($review.frontier.criterion_ids[];
      . as $id | ([$contract.definition.criteria[].id] | index($id)) != null)
    and all($review.frontier.criterion_ids[]; . as $id
      | ([$review.criteria[] | select(.id == $id) | .refs[]] | unique) as $refs
      | any($review.frontier.evidence[]; . as $ref
          | ($refs | index($ref)) != null))
    and all($review.criteria[];
      . as $assessment
      |
      ($contract.definition.criteria[] | select(.id == $assessment.id)) as $criterion
      | ($criterion.evidence_policy.allowed_kinds | index($assessment.evidence_kind)) != null
      and ($criterion.proof_spec.receipt_kinds | index($assessment.evidence_kind)) != null
      and ($assessment.refs | length) == 1
      and (if $criterion.evidence_policy.requires_empirical then
        $assessment.evidence_kind != "review" else true end))
  ' <<<"${canonical_review}" >/dev/null 2>&1 || return 1

  token="$(printf '%s' "${verdict}" | tr -d '\r')"
  if [[ "${token}" =~ ^VERDICT:[[:space:]]*(CLEAN|SHIP)[[:space:]]*$ ]]; then
    jq -e --argjson contract "${canonical_contract}" '
      ([.criteria[] | select(.status == "unmet") | .id] as $unmet
       | all($contract.definition.criteria[]; . as $criterion
          | $criterion.class != "must" or ($unmet | index($criterion.id)) == null))
      and .frontier.material == false
      and .frontier.bar_quality == "strong"
      and (.frontier.criterion_ids | length) == 0
    ' <<<"${canonical_review}" >/dev/null 2>&1
    return
  fi
  if [[ "${token}" =~ ^VERDICT:[[:space:]]*(FINDINGS|BLOCK)[[:space:]]*\([[:space:]]*([1-9][0-9]*)[[:space:]]*\)[[:space:]]*$ ]]; then
    expected_count="${BASH_REMATCH[2]}"
    actual_count="$(jq -r --argjson contract "${canonical_contract}" '
      ([.criteria[] | select(.status == "unmet") | .id] as $unmet
       | [$contract.definition.criteria[]
          | . as $criterion
          | select($criterion.class == "must"
            and ($unmet | index($criterion.id)) != null)] | length) as $must
      | if $must > 0 then $must
        elif (.frontier.material == true or .frontier.bar_quality == "weak") then 1
        else 0 end
    ' <<<"${canonical_review}")"
    [[ "${actual_count}" == "${expected_count}" ]] || return 1
    jq -e --argjson contract "${canonical_contract}" '
      . as $review
      | ([$review.criteria[] | select(.status == "unmet") | .id] as $unmet
       | [$contract.definition.criteria[] | . as $criterion
          | select($criterion.class == "must"
            and ($unmet | index($criterion.id)) != null) | .id]) as $unmet_must
      | ($review.frontier.criterion_ids | length) >= 1
        and all($unmet_must[]; . as $id
          | ($review.frontier.criterion_ids | index($id)) != null)
        and (($unmet_must | length) > 0
          or $review.frontier.material == true
          or $review.frontier.bar_quality == "weak")
    ' \
      <<<"${canonical_review}" >/dev/null 2>&1
    return
  fi
  return 1
}

_quality_contract_read_jsonl_array() {
  local file="${1:-}" max_bytes="${2:-262144}" max_lines="${3:-512}"
  _omc_canonical_uint_in_range "${max_bytes}" 1 2097152 || return 1
  _omc_canonical_uint_in_range "${max_lines}" 1 4096 || return 1
  if [[ ! -e "${file}" && ! -L "${file}" ]]; then
    printf '[]'
    return 0
  fi
  _quality_contract_read_private_json_snapshot \
    "${file}" "${max_bytes}" jsonl "${max_lines}"
}

_quality_contract_receipts_schema_valid() {
  local receipts="${1:-}" max_rows="${2:-512}"
  _omc_canonical_uint_in_range "${max_rows}" 1 4096 || return 1
  jq -e --argjson max_rows "${max_rows}" '
    def bounded_uint($minimum):
      type == "number" and floor == . and . >= $minimum
      and . <= 999999999999999;
    def text($min;$max):
      type == "string" and length <= $max
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length >= $min)
      and (test("[\u0000-\u001f]") | not);
    def kind:
      . == "test" or . == "render" or . == "benchmark"
      or . == "inspection" or . == "comparison" or . == "source";
    type == "array" and length <= $max_rows
    and ([.[].receipt_id] | length == (unique | length))
    and all(.[];
      type == "object"
      and (keys | sort == ["_v","artifact_digest","artifact_target",
        "code_revision","command","command_digest","confidence",
        "edit_revision","evidence_kind","input_digest","launcher_digest",
        "launcher_identity","launcher_path","method","outcome","plan_revision","proof_identity",
        "quality_contract_id","quality_contract_revision",
        "receipt_id","result","result_digest","review_cycle_id","scope",
        "subject_digest","subject_identity","subject_path","tool_cwd",
        "tool_name","tool_use_id","ts"])
      and ._v == 3
      and (.receipt_id | type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$"))
      and (.tool_use_id | text(1;256))
      and (.tool_name | text(1;256))
      and (.input_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,80}$"))
      and (.command | text(1;500))
      and (.command_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,80}$"))
      and (.result_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,80}$"))
      and (.proof_identity | type == "string" and test("^vp-[A-Za-z0-9._:-]{8,80}$"))
      and (.outcome == "passed" or .outcome == "failed" or .outcome == "unknown")
      and (.confidence | type == "number" and floor == . and . >= 0 and . <= 100)
      and (.method | text(2;160)) and (.scope | text(2;160))
      and (.evidence_kind | kind)
      and (.result | text(1;500))
      and (.artifact_target | type == "string" and length <= 1000
        and (test("[\u0000-\u001f\u007f]") | not))
      and (.artifact_digest | type == "string" and length <= 128)
      and (.launcher_path | type == "string" and length <= 1000
        and (test("[\u0000-\u001f\u007f]") | not))
      and (.launcher_digest | type == "string"
        and (. == "" or test("^[0-9a-f]{64}$")))
      and (.launcher_identity | type == "string" and length <= 512
        and (test("[\u0000-\u001f\u007f]") | not))
      and ((.launcher_path == "") == (.launcher_digest == "")
        and (.launcher_path == "") == (.launcher_identity == ""))
      and (.subject_path | type == "string" and length <= 1000
        and (test("[\u0000-\u001f\u007f]") | not))
      and (.subject_digest | type == "string"
        and (. == "" or test("^[0-9a-f]{64}$")))
      and (.subject_identity | type == "string" and length <= 512
        and (test("[\u0000-\u001f\u007f]") | not))
      and ((.subject_path == "") == (.subject_digest == "")
        and (.subject_path == "") == (.subject_identity == ""))
      and (.tool_cwd | type == "string" and length <= 1000
        and (test("[\u0000-\u001f\u007f]") | not))
      and (if .quality_contract_id != "" and .tool_name == "Bash" then
        .launcher_path != "" and .subject_path != "" and .tool_cwd != ""
      elif .quality_contract_id != "" and .tool_name == "Read"
          and .outcome == "passed" then
        .subject_path != "" and .tool_cwd != ""
        and .subject_path == .artifact_target
        and .subject_digest == .artifact_digest
      elif .quality_contract_id != "" and .tool_name == "Grep"
          and .outcome == "passed" then
        .subject_path != "" and .tool_cwd != ""
        and .subject_path == .artifact_target
      else true end)
      and (.edit_revision | bounded_uint(0))
      and (.code_revision | bounded_uint(0))
      and (.plan_revision | bounded_uint(0))
      and (.review_cycle_id | bounded_uint(0))
      and (.quality_contract_id | type == "string"
        and (. == "" or test("^qc-[A-Za-z0-9._:-]{8,80}$")))
      and (.quality_contract_revision | bounded_uint(0))
      and ((.quality_contract_id == "") == (.quality_contract_revision == 0))
      and (.ts | bounded_uint(1)))
  ' <<<"${receipts}" >/dev/null 2>&1 || return 1

  local receipt="" expected_id="" actual_id="" expected_command_digest=""
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    expected_command_digest="$(verification_receipt_command_digest \
      "$(jq -r '.command' <<<"${receipt}")" \
      "$(jq -r '.tool_name' <<<"${receipt}")" 2>/dev/null || true)"
    [[ -n "${expected_command_digest}" \
        && "$(jq -r '.command_digest' <<<"${receipt}")" \
          == "${expected_command_digest}" ]] || return 1
    expected_id="$(_quality_contract_receipt_expected_id \
      "${receipt}" 2>/dev/null || true)"
    actual_id="$(jq -r '.receipt_id // empty' \
      <<<"${receipt}" 2>/dev/null || true)"
    [[ -n "${expected_id}" && "${actual_id}" == "${expected_id}" ]] \
      || return 1
  done < <(jq -c '.[]' <<<"${receipts}" 2>/dev/null)
  return 0
}

_quality_contract_receipt_expected_id() {
  local receipt="${1:-}" material="" digest=""
  [[ -n "${receipt}" ]] || return 1
  material="$(jq -cS '
    {tool_use_id,tool_name,input_digest,command_digest,result,result_digest,
     outcome,confidence,method,scope,evidence_kind,artifact_target,
     artifact_digest,launcher_path,launcher_digest,launcher_identity,
     subject_path,subject_digest,subject_identity,tool_cwd,proof_identity,
     edit_revision,code_revision,plan_revision,review_cycle_id,
     quality_contract_id,quality_contract_revision}
  ' <<<"${receipt}" 2>/dev/null || true)"
  [[ -n "${material}" ]] || return 1
  digest="$(_omc_authority_digest "${material}" 2>/dev/null || true)"
  [[ "${digest}" =~ ^[A-Za-z0-9._:-]{8,80}$ ]] || return 1
  printf 'vr-%s' "${digest}"
}

_quality_contract_receipt_provenance_current() {
  local receipt="${1:-}" tool="" path="" digest="" identity=""
  local mode="executable" normalized="" current_digest="" current_identity=""
  local command="" tool_cwd="" expected_launcher="" expected_subject=""
  [[ -n "${receipt}" ]] || return 1
  tool="$(jq -r '.tool_name // empty' <<<"${receipt}" 2>/dev/null || true)"
  case "${tool}" in
    Bash)
      command="$(jq -r '.command // empty' <<<"${receipt}" \
        2>/dev/null || true)"
      tool_cwd="$(jq -r '.tool_cwd // empty' <<<"${receipt}" \
        2>/dev/null || true)"
      normalized="$(_verification_normalize_proof_path \
        "${tool_cwd}" 0 content 2>/dev/null || true)"
      [[ -n "${command}" && "${normalized}" == "${tool_cwd}" ]] || return 1
      expected_launcher="$(verification_command_launcher_path \
        "${command}" 2>/dev/null || true)"
      expected_subject="$(verification_command_subject_path \
        "${command}" "${tool_cwd}" 2>/dev/null || true)"
      [[ -n "${expected_launcher}" && -n "${expected_subject}" \
          && "$(jq -r '.launcher_path // empty' <<<"${receipt}")" \
            == "${expected_launcher}" \
          && "$(jq -r '.subject_path // empty' <<<"${receipt}")" \
            == "${expected_subject}" ]] || return 1
      for mode in launcher subject; do
        path="$(jq -r --arg key "${mode}_path" '.[$key] // empty' \
          <<<"${receipt}" 2>/dev/null || true)"
        digest="$(jq -r --arg key "${mode}_digest" '.[$key] // empty' \
          <<<"${receipt}" 2>/dev/null || true)"
        identity="$(jq -r --arg key "${mode}_identity" '.[$key] // empty' \
          <<<"${receipt}" 2>/dev/null || true)"
        [[ -n "${path}" && "${digest}" =~ ^[0-9a-f]{64}$ \
            && -n "${identity}" ]] || return 1
        normalized="$(_verification_normalize_proof_path \
          "${path}" 0 executable 2>/dev/null || true)"
        [[ "${normalized}" == "${path}" ]] || return 1
        current_digest="$(_verification_sha256_file \
          "${path}" 2>/dev/null || true)"
        if [[ "${mode}" == "subject" ]]; then
          current_identity="$(_verification_file_identity \
            "${path}" "${tool_cwd}" 2>/dev/null || true)"
        else
          current_identity="$(_verification_file_identity \
            "${path}" 2>/dev/null || true)"
        fi
        [[ "${current_digest}" == "${digest}" ]] || return 1
        _verification_file_identity_review_matches \
          "${identity}" "${current_identity}" || return 1
      done
      ;;
    Read)
      [[ "$(jq -r '.outcome' <<<"${receipt}" 2>/dev/null || true)" \
          == "passed" ]] || return 0
      path="$(jq -r '.subject_path // empty' <<<"${receipt}")"
      digest="$(jq -r '.subject_digest // empty' <<<"${receipt}")"
      identity="$(jq -r '.subject_identity // empty' <<<"${receipt}")"
      tool_cwd="$(jq -r '.tool_cwd // empty' <<<"${receipt}")"
      normalized="$(_verification_normalize_proof_path \
        "${tool_cwd}" 0 content 2>/dev/null || true)"
      [[ -n "${path}" && "${digest}" =~ ^[0-9a-f]{64}$ \
          && -n "${identity}" \
          && "${normalized}" == "${tool_cwd}" \
          && "$(jq -r '.command' <<<"${receipt}")" == "Read:${path}" \
          && "$(jq -r '.artifact_target' <<<"${receipt}")" == "${path}" \
          && "$(jq -r '.artifact_digest' <<<"${receipt}")" == "${digest}" ]] \
        || return 1
      normalized="$(_verification_normalize_proof_path \
        "${path}" 0 source 2>/dev/null || true)"
      [[ "${normalized}" == "${path}" ]] || return 1
      current_digest="$(_verification_sha256_file \
        "${path}" 2>/dev/null || true)"
      current_identity="$(_verification_file_identity \
        "${path}" "${tool_cwd}" 2>/dev/null || true)"
      [[ "${current_digest}" == "${digest}" ]] || return 1
      _verification_file_identity_review_matches \
        "${identity}" "${current_identity}" || return 1
      ;;
    Grep)
      [[ "$(jq -r '.outcome' <<<"${receipt}" 2>/dev/null || true)" \
          == "passed" ]] || return 0
      path="$(jq -r '.subject_path // empty' <<<"${receipt}")"
      digest="$(jq -r '.subject_digest // empty' <<<"${receipt}")"
      identity="$(jq -r '.subject_identity // empty' <<<"${receipt}")"
      command="$(jq -r '.command // empty' <<<"${receipt}")"
      tool_cwd="$(jq -r '.tool_cwd // empty' <<<"${receipt}")"
      normalized="$(_verification_normalize_proof_path \
        "${tool_cwd}" 0 content 2>/dev/null || true)"
      [[ -n "${path}" && "${digest}" =~ ^[0-9a-f]{64}$ \
          && -n "${identity}" \
          && "${normalized}" == "${tool_cwd}" \
          && "$(jq -r '.artifact_target' <<<"${receipt}")" == "${path}" ]] \
        || return 1
      case "${command}" in
        "Grep:${path}"|"Grep:${path}:"*) ;;
        *) return 1 ;;
      esac
      normalized="$(_verification_normalize_proof_path \
        "${path}" 0 source 2>/dev/null || true)"
      [[ "${normalized}" == "${path}" ]] || return 1
      current_digest="$(_verification_sha256_file \
        "${path}" 2>/dev/null || true)"
      current_identity="$(_verification_file_identity \
        "${path}" "${tool_cwd}" 2>/dev/null || true)"
      [[ "${current_digest}" == "${digest}" ]] || return 1
      _verification_file_identity_review_matches \
        "${identity}" "${current_identity}" || return 1
      ;;
  esac
  return 0
}

_quality_contract_receipt_semantic_matches_criterion() {
  local receipt="${1:-}" criterion="${2:-}" threshold="${3:-}"
  local tool="" actual_tool="" expected_target="" actual_target=""
  local expected_surface="" actual_surface=""
  local project_test_cmd="" expected_command="" actual_command=""
  local expected_descriptor="" expected_piece="" actual_artifact="" descriptor=""
  local descriptor_found=0
  jq -en --argjson receipt "${receipt}" --argjson criterion "${criterion}" '
    def tool_match($pattern;$actual):
      if ($pattern | endswith("*")) then
        $actual | startswith($pattern[0:-1])
      else $actual == $pattern end;
    ($criterion.proof_spec.receipt_kinds | index($receipt.evidence_kind)) != null
    and any($criterion.proof_spec.tool_names[]; tool_match(.;$receipt.tool_name))
    and all($criterion.proof_spec.command_contains[];
      . as $token | ($receipt.command | ascii_downcase | contains($token | ascii_downcase)))
  ' >/dev/null 2>&1 || return 1

  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  actual_tool="$(jq -r '.tool_name // empty' \
    <<<"${receipt}" 2>/dev/null || true)"
  if [[ "${tool}" == "Bash" ]]; then
    [[ "${actual_tool}" \
        == "Bash" ]] || return 1
    expected_target="$(_quality_contract_bash_target_witness \
      "${criterion}" "${threshold}" 2>/dev/null || true)"
    project_test_cmd="$(read_state "project_test_cmd" 2>/dev/null || true)"
    [[ -n "${project_test_cmd}" ]] \
      || project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
    actual_target="$(verification_command_semantic_target \
      "$(jq -r '.command // empty' <<<"${receipt}" 2>/dev/null || true)" \
      "${project_test_cmd}" 2>/dev/null || true)"
    expected_surface="${expected_target%%|policy=*}"
    actual_surface="${actual_target%%|policy=*}"
    # The criterion freezes the verifier-owned execution surface; its
    # command_contains language separately proves every required policy token.
    # The receipt identity still binds the complete normalized argv policy,
    # but an honest additional flag cannot make the same named verifier a
    # different criterion target. Cross-criterion validation likewise rejects
    # reuse on this policy-independent surface.
    [[ -n "${expected_target}" && -n "${actual_target}" \
        && "${actual_surface}" == "${expected_surface}" ]] \
      || return 1
  elif [[ "${tool}" == "Read" || "${tool}" == "Grep" ]]; then
    [[ "${actual_tool}" == "${tool}" ]] || return 1
    expected_target="$(_quality_contract_source_target_witness \
      "${criterion}" 2>/dev/null || true)"
    actual_target="$(jq -r '.artifact_target // empty' \
      <<<"${receipt}" 2>/dev/null || true)"
    expected_command="$(_quality_contract_source_command_witness \
      "${criterion}" "${expected_target}" 2>/dev/null || true)"
    actual_command="$(jq -r '.command // empty' \
      <<<"${receipt}" 2>/dev/null || true)"
    [[ -n "${expected_target}" && -n "${expected_command}" \
        && "${actual_target}" == "${expected_target}" \
        && "${actual_command}" == "${expected_command}" ]] || return 1
  elif [[ "${tool}" == mcp__* ]]; then
    [[ "${actual_tool}" == mcp__* ]] || return 1
    expected_descriptor="$(_quality_contract_mcp_target_witness \
      "${criterion}" "${actual_tool}" 2>/dev/null || true)"
    [[ -n "${expected_descriptor}" ]] || return 1
    actual_artifact="$(jq -r '.artifact_target // empty' \
      <<<"${receipt}" 2>/dev/null || true)"
    while IFS= read -r expected_piece; do
      [[ -n "${expected_piece}" ]] || continue
      descriptor_found=0
      while IFS= read -r descriptor; do
        if [[ "${descriptor}" == "${expected_piece}" ]]; then
          descriptor_found=1
          break
        fi
      done < <(printf '%s\n' "${actual_artifact}" | tr ';' '\n')
      [[ "${descriptor_found}" -eq 1 ]] || return 1
    done < <(printf '%s\n' "${expected_descriptor}" | tr ';' '\n')
    expected_target="$(_quality_contract_mcp_proof_target_witness \
      "${criterion}" "${threshold}" 2>/dev/null || true)"
    actual_target="mcp:$(classify_mcp_verification_tool \
      "${actual_tool}" 2>/dev/null || true):${expected_descriptor}"
    [[ -n "${expected_target}" && "${actual_target}" == "${expected_target}" ]] \
      || return 1
  else
    return 1
  fi
  return 0
}

quality_contract_receipt_matches_criterion() {
  local receipt="${1:-}" criterion="${2:-}" threshold="${3:-}"
  _quality_contract_receipts_schema_valid "[${receipt}]" 1 || return 1
  _quality_contract_receipt_provenance_current "${receipt}" || return 1
  _quality_contract_receipt_semantic_matches_criterion \
    "${receipt}" "${criterion}" "${threshold}"
}

quality_contract_receipt_matching_criterion_ids() {
  local receipt="${1:-}" contract="${2:-}" criterion="" id="" ids='[]'
  local threshold=""
  threshold="$(jq -r '.verification_threshold // 40' \
    <<<"${contract}" 2>/dev/null || printf '40')"
  _omc_canonical_uint_in_range "${threshold}" 0 100 || threshold=40
  while IFS= read -r criterion; do
    [[ -n "${criterion}" ]] || continue
    if quality_contract_receipt_matches_criterion \
        "${receipt}" "${criterion}" "${threshold}"; then
      id="$(jq -r '.id' <<<"${criterion}")"
      ids="$(jq -cn --argjson ids "${ids}" --arg id "${id}" \
        '$ids + [$id]')" || return 1
    fi
  done < <(jq -c '.definition.criteria[]' <<<"${contract}" 2>/dev/null)
  printf '%s\n' "${ids}"
}

_quality_contract_evidence_schema_valid() {
  local evidence="${1:-}"
  jq -e '
    def bounded_uint($minimum):
      type == "number" and floor == . and . >= $minimum
      and . <= 999999999999999;
    def text($min;$max):
      type == "string" and length <= $max
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length >= $min)
      and (test("[\u0000-\u001f]") | not);
    def evidence_kind:
      . == "test" or . == "render" or . == "benchmark"
      or . == "inspection" or . == "comparison" or . == "source"
      or . == "review";
    type == "array" and length <= 512
    and ([.[].evidence_id] | length == (unique | length))
    and all(.[];
      type == "object"
      and (keys | sort == ["_v","axis","claim","class","contract_id",
        "contract_revision","criterion_id","edit_revision","evidence_id",
        "evidence_kind","lifecycle_dispatch_id","native_agent_id",
        "plan_revision","receipt_id","reference","result",
        "review_cycle_id","reviewed_at","reviewer"])
      and ._v == 1
      and (.contract_id | type == "string" and test("^qc-[A-Za-z0-9._:-]{8,80}$"))
      and (.contract_revision | bounded_uint(1))
      and (.review_cycle_id | bounded_uint(1))
      and (.criterion_id | type == "string" and test("^Q-[0-9]{3}$"))
      and (.axis == "deliberate" or .axis == "distinctive"
        or .axis == "coherent" or .axis == "visionary" or .axis == "complete")
      and (.class == "must" or .class == "aspiration")
      and (.evidence_id | type == "string" and test("^qe-[A-Za-z0-9._:-]{3,124}$"))
      and (.receipt_id | type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$"))
      and (.result == "passed" or .result == "failed")
      and (.evidence_kind | evidence_kind)
      and (.claim | text(4;1500))
      and (.reference | text(2;1000))
      and (.edit_revision | bounded_uint(0))
      and (.plan_revision | bounded_uint(1))
      and (.reviewed_at | bounded_uint(1))
      and (.reviewer | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,120}$")))
  ' <<<"${evidence}" >/dev/null 2>&1
}

_quality_contract_verification_current() {
  local threshold="${1:-}" outcome confidence verify_ts edit_ts
  local verify_revision code_revision
  outcome="$(read_state "last_verify_outcome" 2>/dev/null || true)"
  confidence="$(read_state "last_verify_confidence" 2>/dev/null || true)"
  if [[ -z "${threshold}" ]]; then
    threshold="$(_quality_contract_verification_threshold)"
  fi
  # A caller-supplied threshold is contract authority. Never reinterpret a
  # malformed value (for example an octal-looking leading zero) as the ambient
  # default and accidentally weaken the frozen verification bar.
  _omc_canonical_uint_in_range "${threshold}" 0 100 || return 1
  verify_ts="$(read_state "last_verify_ts" 2>/dev/null || true)"
  edit_ts="$(read_state "last_edit_ts" 2>/dev/null || true)"
  verify_revision="$(read_state "last_verify_code_revision" 2>/dev/null || true)"
  code_revision="$(read_state "last_code_edit_revision" 2>/dev/null || true)"
  _omc_canonical_uint_in_range "${confidence}" 0 100 || return 1
  [[ "${outcome}" == "passed" && "${confidence}" -ge "${threshold}" ]] || return 1
  _omc_canonical_uint_in_range "${verify_ts}" 1 999999999999999 || return 1
  if [[ -n "${edit_ts}" ]]; then
    _omc_canonical_uint_in_range "${edit_ts}" 1 999999999999999 \
      || return 1
    [[ "${verify_ts}" -ge "${edit_ts}" ]] || return 1
  fi
  if [[ -n "${verify_revision}" || -n "${code_revision}" ]]; then
    _omc_canonical_uint_in_range \
      "${verify_revision:-0}" 0 999999999999999 || return 1
    _omc_canonical_uint_in_range \
      "${code_revision:-0}" 0 999999999999999 || return 1
    [[ "${verify_revision:-0}" == "${code_revision:-0}" ]] || return 1
  fi
  return 0
}

_quality_contract_frontier_schema_valid() {
  local frontier="${1:-}" decision_text
  jq -e '
    def bounded_uint($minimum):
      type == "number" and floor == . and . >= $minimum
      and . <= 999999999999999;
    def text($min;$max):
      type == "string" and length <= $max
      and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length >= $min)
      and (test("[\u0000-\u001f]") | not);
    type == "object"
    and (keys | sort == ["_v","alternatives_searched","contract_id",
      "contract_revision","criterion_ids","dominates_current","edit_revision",
      "evidence","evidence_ids","experiment","lifecycle_dispatch_id","limits",
      "materiality","native_agent_id","plan_revision","recommended_move",
      "review_cycle_id","reviewed_at","reviewer","status","title","why"])
    and ._v == 1
    and (.contract_id | type == "string" and test("^qc-[A-Za-z0-9._:-]{8,80}$"))
    and (.contract_revision | bounded_uint(1))
    and (.review_cycle_id | bounded_uint(1))
    and (.edit_revision | bounded_uint(0))
    and (.plan_revision | bounded_uint(1))
    and (.status == "open" or .status == "clear")
    and (.materiality == "none" or .materiality == "medium" or .materiality == "high")
    and (.dominates_current | type == "boolean")
    and (if .status == "clear" then
      .materiality == "none" and .dominates_current == false
      and (.criterion_ids | length) == 0
      else (.materiality == "medium" or .materiality == "high")
        and .dominates_current == true
        and (.criterion_ids | length) > 0 end)
    and (.title | text(4;500))
    and (.why | text(4;1500))
    and (.recommended_move | text(4;1500))
    and (.criterion_ids | type == "array" and length == (unique | length)
      and all(.[]; type == "string" and test("^Q-[0-9]{3}$")))
    and (.evidence_ids | type == "array" and length >= 1
      and length == (unique | length)
      and all(.[]; type == "string" and test("^qe-[A-Za-z0-9._:-]{3,124}$")))
    and (.evidence | type == "array" and length >= 1 and length <= 20
      and length == (unique | length)
      and all(.[]; type == "string" and test("^vr-[A-Za-z0-9._:-]{8,80}$")))
    and (.alternatives_searched | type == "array" and length >= 2 and length <= 10
      and length == (unique | length) and all(.[]; text(8;1000)))
    and (.limits | type == "array" and length >= 1 and length <= 10
      and length == (unique | length) and all(.[]; text(4;500)))
    and (.experiment | text(4;1500))
    and (.reviewed_at | bounded_uint(1))
    and (.reviewer | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
    and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.lifecycle_dispatch_id | type == "string"
      and test("^dispatch-[A-Za-z0-9._:-]{8,120}$"))
  ' <<<"${frontier}" >/dev/null 2>&1 || return 1
  while IFS= read -r decision_text; do
    if _quality_contract_cost_only_text "${decision_text}"; then
      return 1
    fi
  done < <(jq -r '.title, .why, .recommended_move, .experiment,
    .alternatives_searched[], .limits[]' <<<"${frontier}")
}

quality_contract_gate_status_json() {
  local contract_file="${1:-}" evidence_file="${2:-}" frontier_file="${3:-}"
  local receipts_file="${4:-}"
  local required contract evidence receipts frontier="" contract_id contract_revision cycle
  local edit_revision plan_revision verify_current=false assessment status threshold
  local criterion="" criterion_id="" criterion_authority="" authority_map='{}'
  local authority_generations='{}' generation_authority='{}'
  local authority_edit="" authority_plan="" authority_key=""
  local receipt="" invalid_provenance_ids='[]' invalid_receipt_id=""
  local bash_receipt_surfaces='{}'
  if [[ -z "${contract_file}" ]]; then
    contract_file="$(session_file "quality_contract.json")"
  fi
  [[ -n "${evidence_file}" ]] || evidence_file="$(session_file "quality_evidence.jsonl")"
  [[ -n "${frontier_file}" ]] || frontier_file="$(session_file "quality_frontier.json")"
  [[ -n "${receipts_file}" ]] || receipts_file="$(session_file "verification_receipts.jsonl")"
  required="$(read_state "quality_contract_required" 2>/dev/null || true)"

  if [[ "${required}" == "1" \
      && -n "$(read_state \
        "quality_contract_scope_overflow" 2>/dev/null || true)" ]]; then
    jq -cnS '{_v:1,status:"scope_overflow",contract_valid:false,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi

  # Excellence review publishes evidence, frontier, state, history, then its
  # lifecycle receipt under one durable roll-forward WAL. Until that final
  # receipt lands, the earlier artifact writes are provisional and must never
  # make Stop report a certified Definition. Any node shape (including corrupt
  # or symlink authority) fails closed until dedicated recovery or /ulw-off.
  local reviewer_wal
  reviewer_wal="$(session_file ".reviewer-transaction.wal")"
  if [[ "${required}" == "1" ]] \
      && { [[ -e "${reviewer_wal}" ]] || [[ -L "${reviewer_wal}" ]]; }; then
    jq -cnS '{_v:1,status:"reviewer_publication_pending",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"pending"}'
    return 1
  fi

  if [[ ! -e "${contract_file}" ]]; then
    status="missing_contract"
    [[ "${required}" == "1" ]] || status="not_required"
    jq -cnS --arg status "${status}" \
      '{_v:1,status:$status,contract_valid:false,required_count:0,
        satisfied_count:0,missing_ids:[],stale_ids:[],verification_current:false,
        frontier_status:"missing"}'
    [[ "${status}" == "not_required" ]]
    return
  fi
  # Preserve a specific recovery status for a structurally valid contract that
  # was first published after mutation; validate_current intentionally rejects
  # it, but callers need to distinguish this from ordinary corruption/staleness.
  local _raw_contract=""
  _raw_contract="$(_quality_contract_read_json_file "${contract_file}" 65536 2>/dev/null || true)"
  if [[ -n "${_raw_contract}" ]] \
      && quality_contract_validate_envelope "${_raw_contract}" 2>/dev/null \
      && [[ "$(jq -r '.late' <<<"${_raw_contract}")" == "true" ]]; then
    jq -cnS '{_v:1,status:"late_contract",contract_valid:false,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi
  contract="$(quality_contract_validate_current "${contract_file}")" || {
    jq -cnS '{_v:1,status:"stale_contract",contract_valid:false,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }
  evidence="$(_quality_contract_read_jsonl_array "${evidence_file}")" || {
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }
  _quality_contract_evidence_schema_valid "${evidence}" || {
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }
  receipts="$(_quality_contract_read_jsonl_array "${receipts_file}" 524288 512)" || {
    jq -cnS '{_v:1,status:"invalid_receipts",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }
  _quality_contract_receipts_schema_valid "${receipts}" || {
    jq -cnS '{_v:1,status:"invalid_receipts",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    if ! _quality_contract_receipt_provenance_current "${receipt}"; then
      invalid_receipt_id="$(jq -r '.receipt_id' <<<"${receipt}")"
      invalid_provenance_ids="$(jq -cn \
        --argjson ids "${invalid_provenance_ids}" \
        --arg id "${invalid_receipt_id}" '$ids + [$id] | unique')" \
        || return 1
    fi
  done < <(jq -c '.[]' <<<"${receipts}")
  contract_id="$(jq -r '.contract_id' <<<"${contract}")"
  contract_revision="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  edit_revision="$(read_state "edit_revision" 2>/dev/null || true)"
  plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
  [[ -n "${edit_revision}" ]] || edit_revision=0
  [[ -n "${plan_revision}" ]] || plan_revision=0
  if ! _omc_canonical_uint_in_range \
      "${edit_revision}" 0 999999999999999 \
      || ! _omc_canonical_uint_in_range \
        "${plan_revision}" 0 999999999999999; then
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi
  threshold="$(jq -r '.verification_threshold // 40' \
    <<<"${contract}" 2>/dev/null || printf '40')"
  _omc_canonical_uint_in_range "${threshold}" 0 100 || threshold=40
  bash_receipt_surfaces="$(_quality_contract_bash_receipt_surface_map \
    "${receipts}" "${contract}" 2>/dev/null)" || {
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  }

  # Resolve each frozen proof surface once. Bash criteria consume the
  # verifier-owned scope map above while the receipt identity continues to bind
  # full argv. Source proof identity additionally freezes the exact Grep
  # pattern/case; MCP remains descriptor-subset based because the connector may
  # append an observed route to a selector-only contract.
  while IFS=$'\t' read -r authority_edit authority_plan; do
    _omc_canonical_uint_in_range \
      "${authority_edit}" 0 999999999999999 || continue
    _omc_canonical_uint_in_range \
      "${authority_plan}" 0 999999999999999 || continue
    generation_authority='{}'
    while IFS= read -r criterion; do
      [[ -n "${criterion}" ]] || continue
      criterion_id="$(jq -r '.id' <<<"${criterion}")"
      criterion_authority="$(quality_contract_criterion_authority_json \
        "${criterion}" "${contract}" "${authority_edit}" "${authority_plan}" \
        "${threshold}" 2>/dev/null || true)"
      if [[ "$(jq -r 'type' <<<"${criterion_authority}" \
          2>/dev/null || true)" != "object" ]]; then
        jq -cnS '{_v:1,status:"stale_contract",contract_valid:false,
          required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
          verification_current:false,frontier_status:"unknown"}'
        return 1
      fi
      generation_authority="$(jq -cn \
        --argjson map "${generation_authority}" --arg id "${criterion_id}" \
        --argjson authority "${criterion_authority}" \
        '$map + {($id):$authority}')" || return 1
    done < <(jq -c '.definition.criteria[]' <<<"${contract}")
    authority_key="${authority_edit}:${authority_plan}"
    authority_generations="$(jq -cn \
      --argjson maps "${authority_generations}" --arg key "${authority_key}" \
      --argjson authority "${generation_authority}" \
      '$maps + {($key):$authority}')" || return 1
    if [[ "${authority_edit}" == "${edit_revision}" \
        && "${authority_plan}" == "${plan_revision}" ]]; then
      authority_map="${generation_authority}"
    fi
  done < <(jq -r \
    --arg id "${contract_id}" --argjson revision "${contract_revision}" \
    --argjson cycle "${cycle}" --argjson edit "${edit_revision}" \
    --argjson plan "${plan_revision}" '
      ([.[] | select(.contract_id == $id
          and .contract_revision == $revision
          and .review_cycle_id == $cycle)
        | {edit:.edit_revision,plan:.plan_revision}]
       + [{edit:$edit,plan:$plan}])
      | unique_by([.edit,.plan])[] | [.edit,.plan] | @tsv
    ' <<<"${evidence}")
  [[ "$(jq -r 'length' <<<"${authority_map}" 2>/dev/null || true)" -gt 0 ]] \
    || return 1
  # A receipt proves at most one criterion. Reusing one green command across
  # five axes recreates self-certification under a different filename.
  if ! jq -e '
      group_by(.receipt_id)
      | all(.[]; ([.[].criterion_id] | unique | length) == 1)
    ' <<<"${evidence}" >/dev/null 2>&1; then
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi
  if ! jq -e --argjson receipts "${receipts}" \
      --argjson bash_surfaces "${bash_receipt_surfaces}" '
      [ .[] as $row
        | [$receipts[] | select(.receipt_id == $row.receipt_id)]
        | select(length == 1)
        | {criterion_id:$row.criterion_id,
           proof_key:(if .[0].tool_name == "Bash" then
             "bash:" + ($bash_surfaces[.[0].receipt_id] // "")
           else "identity:" + .[0].proof_identity end)} ]
      | group_by(.proof_key)
      | all(.[]; ([.[].criterion_id] | unique | length) == 1)
    ' <<<"${evidence}" >/dev/null 2>&1; then
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi
  assessment="$(jq -cnS \
    --argjson contract "${contract}" --argjson evidence "${evidence}" \
    --argjson receipts "${receipts}" \
    --argjson invalid_provenance "${invalid_provenance_ids}" \
    --argjson authority "${authority_map}" \
    --argjson authority_generations "${authority_generations}" \
    --argjson bash_surfaces "${bash_receipt_surfaces}" \
    --arg contract_id "${contract_id}" \
    --argjson contract_revision "${contract_revision}" \
    --argjson cycle "${cycle}" --argjson edit_revision "${edit_revision}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson threshold "${threshold}" '
      def cost_only:
        (ascii_downcase) as $s
        | ($s | test("(^|[^A-Za-z0-9_])(implementation|implementing|change|changing|fix|fixing|solution|refactor|refactoring|rewrite|scope|work|engineering|build|building|development|developing)([^A-Za-z0-9_]|$)")) as $context
        | ($s | test("(^|[^A-Za-z0-9_])(too (expensive|costly|large|hard)|takes? too long|time[- ]consuming|requires? (significant|too much) (effort|work|time)|not worth (it|the effort)|blocked by (cost|complexity)|risk(y)? to change)([^A-Za-z0-9_]|$)")) as $cost
        | ($s | test("too hard for[^.!?]{0,80}(keyboard|screen[- ]reader|users?|customers?)[^.!?]{0,80}(use|navigate|operate|complete|understand|access)")) as $accessibility_quality
        | ($s | test("(we ran out of time|our time ran out|we had no (more )?time|we lacked time|no time remained|we ran out of runway|(time constraints?|limited time|time limitations?|scheduling constraints?) (prevented|constrained|blocked|did not permit|did not allow|left)|the (time budget|schedule) (did not|does not|would not) (permit|allow)|the timebox (ended|expired)|insufficient time|not enough time|too little time|before the deadline|deadline([ -]driven)? pressure|(^|[^A-Za-z0-9_])(the |our |implementation |work |review )?deadline (arrived|expired|passed|left|limited|prevented|constrained)|(our|implementation|work|review) session (ended|was over|is over))")) as $time_pressure
        | ($s | test("(improvement|alternative|candidate|option|experiment|explor|scope|step[- ]change|leap)")) as $frontier_scope
        | (($context and $cost and ($accessibility_quality | not))
          or ($time_pressure and $frontier_scope));
      def same_contract($row):
        $row.contract_id == $contract_id
        and $row.contract_revision == $contract_revision
        and $row.review_cycle_id == $cycle;
      def tool_match($pattern;$actual):
        if ($pattern | endswith("*")) then
          $actual | startswith($pattern[0:-1])
        else $actual == $pattern end;
      def same_proof_surface_with($receipt;$criterion;$authority_map):
        ($authority_map[$criterion.id] // {}) as $auth
        | if $auth.mode == "bash_surface" then
            $receipt.tool_name == "Bash"
            and ($bash_surfaces[$receipt.receipt_id] // "")
              == $auth.proof_surface
            and $receipt.artifact_target == $auth.artifact_target
          elif $auth.mode == "proof_identity" then
            $receipt.proof_identity == $auth.proof_identity
            and $receipt.artifact_target == $auth.artifact_target
            and (if ($auth.expected_command // "") != "" then
              $receipt.command == $auth.expected_command else true end)
          elif $auth.mode == "mcp" then
            $receipt.method == ("mcp_" + $auth.classifier)
            and (($receipt.artifact_target | split(";")) as $actual
              | all(($auth.descriptor | split(";"))[];
                  . as $descriptor | ($actual | index($descriptor)) != null))
          else false end;
      def same_proof_surface($receipt;$criterion):
        same_proof_surface_with($receipt;$criterion;$authority);
      def receipt_matches_spec_with($receipt;$criterion;$authority_map):
        ($criterion.proof_spec.receipt_kinds
          | index($receipt.evidence_kind)) != null
        and any($criterion.proof_spec.tool_names[];
          tool_match(.;$receipt.tool_name))
        and (if $receipt.tool_name == "Grep"
              or $receipt.tool_name == "Read" then true
            else all($criterion.proof_spec.command_contains[];
              . as $token | ($receipt.command | ascii_downcase
                | contains($token | ascii_downcase))) end)
        and same_proof_surface_with($receipt;$criterion;$authority_map);
      def receipt_matches_spec($receipt;$criterion):
        receipt_matches_spec_with($receipt;$criterion;$authority);
      def generation_authority($row):
        $authority_generations[
          (($row.edit_revision | tostring) + ":"
            + ($row.plan_revision | tostring))] // {};
      def historical_receipt_matches_spec($receipt;$criterion;$row):
        receipt_matches_spec_with(
          $receipt;$criterion;generation_authority($row));
      def observation_bearing($receipt):
        ($receipt.evidence_kind == "source"
        or ($receipt.evidence_kind == "inspection"
          and ($receipt.tool_name == "Read"
            or $receipt.tool_name == "Grep"
            or ($receipt.tool_name | startswith("mcp__"))))
        or ($receipt.evidence_kind == "render"
          and ($receipt.tool_name | startswith("mcp__"))));
      def passive_observation($receipt):
        ($receipt.evidence_kind == "source")
        or ($receipt.evidence_kind == "inspection"
          and ($receipt.tool_name == "Read"
            or $receipt.tool_name == "Grep"
            or ($receipt.tool_name | startswith("mcp__"))))
        or ($receipt.evidence_kind == "render"
          and ($receipt.tool_name | startswith("mcp__")));
      def receipt_matching_ids($receipt):
        [$contract.definition.criteria[]
          | select(receipt_matches_spec($receipt;.)) | .id];
      def receipt_matching_ids_with($receipt;$authority_map):
        [$contract.definition.criteria[]
          | select(receipt_matches_spec_with($receipt;.;$authority_map)) | .id];
      def bound_receipt($row;$criterion):
        ([$receipts[] | select(.receipt_id == $row.receipt_id)]) as $matched
        | ($matched | length) == 1
        and ($invalid_provenance | index($row.receipt_id) | not)
        and ($matched[0] | .quality_contract_id == $contract_id
          and .quality_contract_revision == $contract_revision
          and .review_cycle_id == $cycle
          and .receipt_id == $row.reference
          and .edit_revision == $row.edit_revision
          and .plan_revision == $row.plan_revision
          and .evidence_kind == $row.evidence_kind
          and .confidence >= $threshold
          and (if observation_bearing(.) then .outcome == "passed"
               elif $row.result == "passed" then .outcome == "passed"
               else .outcome == "failed" end)
          and receipt_matches_spec(.;$criterion)
          and receipt_matching_ids(.) == [$criterion.id]);
      def historical_bound_receipt($row;$criterion):
        ([$receipts[] | select(.receipt_id == $row.receipt_id)]) as $matched
        | ($matched | length) == 1
        and ($invalid_provenance | index($row.receipt_id) | not)
        and ($matched[0] | .quality_contract_id == $contract_id
          and .quality_contract_revision == $contract_revision
          and .review_cycle_id == $cycle
          and .receipt_id == $row.reference
          and .edit_revision == $row.edit_revision
          and .plan_revision == $row.plan_revision
          and .evidence_kind == $row.evidence_kind
          and .confidence >= $threshold
          and (if observation_bearing(.) then .outcome == "passed"
               elif $row.result == "passed" then .outcome == "passed"
               else .outcome == "failed" end)
          and historical_receipt_matches_spec(.;$criterion;$row)
          and receipt_matching_ids_with(.;generation_authority($row))
            == [$criterion.id]);
      def current_receipt($row;$criterion):
        bound_receipt($row;$criterion)
        and ([$receipts[] | select(.receipt_id == $row.receipt_id)][0]
          | .edit_revision == $edit_revision
            and .plan_revision == $plan_revision);
      def proof_identity($row):
        ([$receipts[] | select(.receipt_id == $row.receipt_id)][0]
          | .proof_identity);
      def receipt_index($id):
        ([range(0; ($receipts | length)) as $i
          | select($receipts[$i].receipt_id == $id) | $i][0] // -1);
      def current_failed_receipt_indexes($criterion):
        [range(0; ($receipts | length)) as $i
          | $receipts[$i] as $receipt
          | select($receipt.quality_contract_id == $contract_id
            and ($invalid_provenance | index($receipt.receipt_id) | not)
            and $receipt.quality_contract_revision == $contract_revision
            and $receipt.review_cycle_id == $cycle
            and $receipt.edit_revision == $edit_revision
            and $receipt.plan_revision == $plan_revision
            and $receipt.outcome == "failed"
            and (passive_observation($receipt) | not)
            and same_proof_surface($receipt;$criterion))
          | $i];
      def current_unreviewed_observation_indexes($criterion;$accepted_index):
        (if $accepted_index >= 0 then
          $receipts[$accepted_index].artifact_digest else "" end) as $accepted_digest
        |
        [range(0; ($receipts | length)) as $i
          | $receipts[$i] as $receipt
          | select($receipt.quality_contract_id == $contract_id
            and ($invalid_provenance | index($receipt.receipt_id) | not)
            and $receipt.quality_contract_revision == $contract_revision
            and $receipt.review_cycle_id == $cycle
            and $receipt.edit_revision == $edit_revision
            and $receipt.plan_revision == $plan_revision
            and $receipt.outcome == "passed"
            and observation_bearing($receipt)
            and ($accepted_index < 0
              or $accepted_digest == ""
              or $receipt.artifact_digest == ""
              or $receipt.artifact_digest != $accepted_digest)
            and receipt_matches_spec($receipt;$criterion)
            and receipt_matching_ids($receipt) == [$criterion.id])
          | $i];
      def proof_valid($row;$criterion):
        $row.axis == $criterion.axis
        and $row.class == $criterion.class
        and ($criterion.evidence_policy.allowed_kinds | index($row.evidence_kind)) != null
        and ($row.claim | cost_only | not)
        and $row.reviewed_at >= $contract.created_ts
        and ($row.reviewer | endswith("excellence-reviewer"))
        and bound_receipt($row;$criterion);
      def historical_proof_valid($row;$criterion):
        $row.axis == $criterion.axis
        and $row.class == $criterion.class
        and ($criterion.evidence_policy.allowed_kinds
          | index($row.evidence_kind)) != null
        and ($row.claim | cost_only | not)
        and $row.reviewed_at >= $contract.created_ts
        and ($row.reviewer | endswith("excellence-reviewer"))
        and historical_bound_receipt($row;$criterion);
      [$contract.definition.criteria[] | select(.class == "must") | . as $criterion
        | ([$evidence[] | select(.criterion_id == $criterion.id)]) as $all_candidates
        | ([$all_candidates[] | select(same_contract(.))]) as $candidates
        | ([$candidates[] | select(proof_valid(.;$criterion)
            and .result == "passed"
            and .edit_revision == $edit_revision
            and .plan_revision == $plan_revision
            and current_receipt(.;$criterion))]) as $current
        | ([$current[] | proof_identity(.)] | unique) as $current_refs
        | ([$current[] | receipt_index(.receipt_id)] | max // -1) as $accepted_index
        | (current_failed_receipt_indexes($criterion) | max // -1) as $failed_index
        | (current_unreviewed_observation_indexes(
            $criterion;$accepted_index) | max // -1) as $observation_index
        | ($failed_index > $accepted_index) as $newer_failed
        | ($accepted_index >= 0 and $observation_index > $accepted_index) as $newer_observation
        | {id:$criterion.id,minimum:$criterion.evidence_policy.minimum,
           current:(if ($newer_failed or $newer_observation)
             then 0 else ($current_refs|length) end),
           candidate_count:($candidates|length),
           stale:($newer_failed or $newer_observation or
            ([$all_candidates[] | select(historical_proof_valid(.;$criterion)
               and .result == "passed"
               and ((same_contract(.) | not)
                 or .edit_revision != $edit_revision
                 or .plan_revision != $plan_revision
                 or (current_receipt(.;$criterion) | not)))]
               | length > 0))}
      ] as $rows
      | ([ $evidence[] as $row
          | ([$contract.definition.criteria[]
              | select(.id == $row.criterion_id)]) as $criteria
          | select((($criteria | length) == 1
              and same_contract($row)
              and ($criteria[0] as $criterion
                | historical_proof_valid($row;$criterion))) | not)
        ] | length == 0) as $all_rows_valid
      | (([$evidence[].criterion_id] | sort)
          == ([$contract.definition.criteria[].id] | sort)) as $exact_criteria
      | (($evidence | length)
          == ([$evidence[].receipt_id] | unique | length)) as $unique_receipts
      | {evidence_valid:($all_rows_valid and $exact_criteria and $unique_receipts),
         required_count:($rows|length),
         satisfied_count:([$rows[] | select(.current >= .minimum)]|length),
         missing_ids:[$rows[] | select(.current < .minimum and (.stale|not)) | .id],
         stale_ids:[$rows[] | select(.current < .minimum and .stale) | .id]}
    ')" || return 1

  if [[ "$(jq -r '.evidence_valid' <<<"${assessment}")" != "true" ]]; then
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi

  if [[ "$(jq -r '.satisfied_count == .required_count' <<<"${assessment}")" == "true" ]]; then
    verify_current=true
  fi

  if [[ "$(jq -r '.satisfied_count == .required_count' <<<"${assessment}")" != "true" ]]; then
    status="missing_evidence"
    [[ "$(jq -r '.stale_ids | length' <<<"${assessment}")" -eq 0 ]] || status="stale_evidence"
    jq -cnS --arg status "${status}" --argjson a "${assessment}" \
      --argjson verify "${verify_current}" '
      {_v:1,status:$status,contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:$a.missing_ids,stale_ids:$a.stale_ids,
       verification_current:$verify,frontier_status:"unchecked"}'
    return 1
  fi

  if [[ ! -e "${frontier_file}" ]]; then
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"missing_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"missing"}'
    return 1
  fi
  frontier="$(_quality_contract_read_json_file "${frontier_file}" 65536)" || {
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"invalid_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"invalid"}'
    return 1
  }
  _quality_contract_frontier_schema_valid "${frontier}" || {
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"invalid_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"invalid"}'
    return 1
  }
  if [[ "$(jq -r '.contract_id' <<<"${frontier}")" != "${contract_id}" \
      || "$(jq -r '.contract_revision' <<<"${frontier}")" != "${contract_revision}" \
      || "$(jq -r '.review_cycle_id' <<<"${frontier}")" != "${cycle}" \
      || "$(jq -r '.edit_revision' <<<"${frontier}")" != "${edit_revision}" \
      || "$(jq -r '.plan_revision' <<<"${frontier}")" != "${plan_revision}" ]]; then
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"stale_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"stale"}'
    return 1
  fi
  if ! jq -en --argjson contract "${contract}" --argjson evidence "${evidence}" \
      --argjson frontier "${frontier}" '
    ([ $frontier.criterion_ids[] as $id
       | select(([$contract.definition.criteria[].id] | index($id)) == null) ]
      | length) == 0
    and $frontier.reviewed_at >= $contract.created_ts
    and ([$frontier.evidence_ids[]] | sort) == ([$evidence[].evidence_id] | sort)
    and ([$frontier.evidence[]] | sort)
      == ([$evidence[].receipt_id] | unique | sort)
    and ([$evidence[].criterion_id] | unique | sort)
      == ([$contract.definition.criteria[].id] | unique | sort)
    and all($evidence[];
      .contract_id == $frontier.contract_id
      and .contract_revision == $frontier.contract_revision
      and .review_cycle_id == $frontier.review_cycle_id
      and .edit_revision == $frontier.edit_revision
      and .plan_revision == $frontier.plan_revision
      and .reviewed_at == $frontier.reviewed_at
      and .reviewer == $frontier.reviewer
      and .native_agent_id == $frontier.native_agent_id
      and .lifecycle_dispatch_id == $frontier.lifecycle_dispatch_id)
    and (if $frontier.status == "clear" then
      all($contract.definition.criteria[]; . as $criterion
        | $criterion.class != "must"
          or any($evidence[];
            .criterion_id == $criterion.id and .result == "passed"))
      else
        ($frontier.criterion_ids | length) > 0
        and all($frontier.criterion_ids[]; . as $id
          | any($evidence[]; .criterion_id == $id))
      end)
  ' >/dev/null 2>&1; then
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"invalid_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"invalid"}'
    return 1
  fi
  if [[ "$(jq -r '.status' <<<"${frontier}")" != "clear" ]]; then
    jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
      {_v:1,status:"open_frontier",contract_valid:true,
       required_count:$a.required_count,satisfied_count:$a.satisfied_count,
       missing_ids:[],stale_ids:[],verification_current:$verify,
       frontier_status:"open"}'
    return 1
  fi
  jq -cnS --argjson a "${assessment}" --argjson verify "${verify_current}" '
    {_v:1,status:"pass",contract_valid:true,
     required_count:$a.required_count,satisfied_count:$a.satisfied_count,
     missing_ids:[],stale_ids:[],verification_current:$verify,
     frontier_status:"clear"}'
}

quality_contract_router_summary() {
  local decision summary
  decision="$(quality_contract_arm_decision_json "$@")" || return 1
  if [[ "$(jq -r '.required' <<<"${decision}")" == "true" ]]; then
    summary="Definition of Excellent required ($(jq -r '.reason' <<<"${decision}")): deliberate, distinctive, coherent, visionary, and complete. Record a current quality contract before mutation."
  else
    summary="Definition of Excellent not required ($(jq -r '.reason' <<<"${decision}"))."
  fi
  if declare -F truncate_chars >/dev/null 2>&1; then
    truncate_chars 240 "${summary}"
  else
    printf '%.240s' "${summary}"
  fi
}

quality_contract_status_summary() {
  local gate rc=0 summary
  gate="$(quality_contract_gate_status_json "$@")" || rc=$?
  summary="$(jq -r '
    "Definition of Excellent: " + .status
    + "; criteria " + (.satisfied_count|tostring) + "/" + (.required_count|tostring)
    + "; frontier " + .frontier_status
    + (if (.missing_ids|length) > 0 then
        "; missing " + (.missing_ids | join(",")) else "" end)
    + (if (.stale_ids|length) > 0 then
        "; stale " + (.stale_ids | join(",")) else "" end)
  ' <<<"${gate}")" || return 1
  if declare -F truncate_chars >/dev/null 2>&1; then
    truncate_chars 320 "${summary}"
  else
    printf '%.320s' "${summary}"
  fi
  return "${rc}"
}
