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
#   quality_contract_build_envelope DEFINITION CYCLE OBJECTIVE_TS PROMPT_REV
#       OBJECTIVE_DIGEST ENFORCEMENT_GENERATION PLAN_REV CREATED_TS
#       PLANNER_AGENT NATIVE_AGENT_ID LIFECYCLE_DISPATCH_ID [CONTRACT_REV]
#   quality_contract_validate_envelope JSON
#   quality_contract_canonicalize_envelope JSON
#   quality_contract_revision_preserves_floor NEW_DEFINITION OLD_ENVELOPE
#   quality_contract_validate_current [CONTRACT_FILE]
#   quality_review_validate_payload JSON
#   quality_review_canonicalize_payload JSON
#   quality_review_validate_against_contract REVIEW CONTRACT VERDICT
#   quality_contract_gate_status_json [CONTRACT_FILE] [EVIDENCE_FILE] [FRONTIER_FILE]
#   quality_contract_router_summary MODE INTENT RISK BROAD EXPLICIT
#   quality_contract_status_summary [CONTRACT_FILE] [EVIDENCE_FILE] [FRONTIER_FILE]
#
# Required common.sh dependencies:
#   read_state, session_file, _omc_token_digest, truncate_chars,
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
  [[ "${threshold}" =~ ^[0-9]+$ && "${threshold}" -le 100 ]] || threshold=40
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
  local verify_type="${1:-}" score threshold
  [[ -n "${verify_type}" ]] || return 1
  score="$(score_mcp_verification_confidence \
    "${verify_type}" "" "false" 2>/dev/null || true)"
  threshold="$(_quality_contract_verification_threshold)"
  [[ "${score}" =~ ^[0-9]+$ && "${score}" -ge "${threshold}" ]]
}

_quality_contract_tool_possible_kinds() {
  local pattern="${1:-}" verify_type="" candidate="" kinds="" threshold
  threshold="$(_quality_contract_verification_threshold)"
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
    local prefix="${pattern%\*}"
    local candidates=(
      "mcp__plugin_playwright_playwright__browser_snapshot"
      "mcp__plugin_playwright_playwright__browser_take_screenshot"
      "mcp__plugin_playwright_playwright__browser_console_messages"
      "mcp__plugin_playwright_playwright__browser_network_requests"
      "mcp__plugin_playwright_playwright__browser_evaluate"
      "mcp__plugin_playwright_playwright__browser_run_code"
      "mcp__computer-use__screenshot"
      "${prefix}verification_probe"
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
      _quality_contract_mcp_confidence_feasible "${verify_type}" || continue
      candidate="$(_quality_contract_mcp_kind_for_classifier \
        "${verify_type}" 2>/dev/null || true)"
      [[ -n "${candidate}" && " ${kinds} " != *" ${candidate} "* ]] \
        && kinds="${kinds:+${kinds} }${candidate}"
    done
  else
    mcp_tool_attempts_artifact_mutation "${pattern}" '{}' && return 1
    verify_type="$(classify_mcp_verification_tool "${pattern}" 2>/dev/null || true)"
    _quality_contract_mcp_confidence_feasible "${verify_type}" || return 1
    kinds="$(_quality_contract_mcp_kind_for_classifier \
      "${verify_type}" 2>/dev/null || true)"
  fi
  [[ -n "${kinds}" ]] || return 1
  printf '%s' "${kinds}"
}

_quality_contract_bash_proof_feasible() {
  local criterion="${1:-}" requested_kind anchors witness scope observed_kind
  local project_test_cmd="" confidence threshold output_witness
  requested_kind="$(jq -r '.proof_spec.receipt_kinds[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  anchors="$(jq -r '.proof_spec.command_contains | join(" ")' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ -n "${requested_kind}" && -n "${anchors}" ]] || return 1

  # Build one non-executed witness through the same production admission and
  # kind derivation used by record-verification. If a frozen substring forces
  # help/compound grammar or a higher-priority kind, every real matching Bash
  # command would be rejected or stamped differently too.
  project_test_cmd="$(detect_project_test_command "." 2>/dev/null || true)"
  case "${requested_kind}" in
    test)       witness="${project_test_cmd:-bash tests/omc_definition_test.sh}" ;;
    benchmark)  witness="${project_test_cmd:-bash tests/omc_definition_test.sh} --benchmark" ;;
    comparison) witness="${project_test_cmd:-bash tests/omc_definition_test.sh} --comparison" ;;
    render)     witness="${project_test_cmd:-bash tests/omc_definition_render.sh} --render" ;;
    inspection) witness="${project_test_cmd:-bash tests/omc_definition_test.sh} vale" ;;
    *) return 1 ;;
  esac
  witness="${witness} ${anchors}"
  # The recorder persists only the first 500 command characters. Admission of
  # a longer witness would certify a language whose tail anchors can never
  # survive into the authoritative receipt.
  [[ ${#witness} -le 500 ]] || return 1
  verification_has_framework_keyword "${witness}" || return 1
  verification_command_is_authoritative_execution "${witness}" "" || return 1
  scope="$(classify_verification_scope "${witness}" "")"
  observed_kind="$(verification_receipt_evidence_kind \
    "framework_keyword" "${scope}" "${witness}")"
  [[ "${observed_kind}" == "${requested_kind}" ]] || return 1

  # Use only ordinary verifier-owned signals for the reachability witness: a
  # count and a clear process outcome. Unlike passive MCP prose, these are
  # emitted by the directly executed test/render process whose command was
  # admitted above. This proves that the frozen Bash language can actually
  # reach the same threshold record-reviewer later enforces.
  output_witness='1 test passed; exit code: 0'
  confidence="$(score_verification_confidence \
    "${witness}" "${output_witness}" "${project_test_cmd}" 2>/dev/null || true)"
  threshold="$(_quality_contract_verification_threshold)"
  [[ "${confidence}" =~ ^[0-9]+$ && "${confidence}" -ge "${threshold}" ]]
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
  tool="$(jq -r '.proof_spec.tool_names[0] // empty' \
    <<<"${criterion}" 2>/dev/null || true)"
  [[ "${tool}" == mcp__* ]] || return 0
  artifact_count="$(jq -r '.proof_spec.artifact_contains | length' \
    <<<"${criterion}" 2>/dev/null || true)"
  artifact_joined="$(jq -r '
      .proof_spec.artifact_contains
      | if length == 0 then 0 else (map(length) | add) + length - 1 end
    ' <<<"${criterion}" 2>/dev/null || true)"
  [[ "${artifact_count}" =~ ^[1-9][0-9]*$ \
      && "${artifact_joined}" =~ ^[0-9]+$ ]] || return 1

  # The recorder truncates each URL/path/route/selector/target leaf to 240
  # characters before composing artifact_target. Requiring the whole frozen
  # target language to fit one value is conservative but constructive: there
  # is always a descriptor that can retain every required target token.
  [[ "${artifact_joined}" -le 233 ]] || return 1 # "target=" + value <= 240
  while IFS= read -r anchor; do
    normalized="$(printf '%s' "${anchor}" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    value="${normalized}"
    if [[ "${normalized}" =~ ^([a-z0-9_.-]+\.)?(url|page_url|path|file_path|route|endpoint|selector|locator|target|observed_url)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[3]}"
    elif [[ "${normalized}" =~ ^([a-z0-9_.-]+\.)?(url|page_url|path|file_path|route|endpoint|selector|locator|target|observed_url)[[:space:]]*[:=]?[[:space:]]*$ ]]; then
      return 1
    fi
    case "${value}" in
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

quality_contract_proof_specs_feasible() {
  local json="${1:-}" criterion tool possible kind all_kinds target_capable
  while IFS= read -r criterion; do
    [[ -n "${criterion}" ]] || continue
    all_kinds=""
    target_capable=0
    while IFS= read -r tool; do
      [[ -n "${tool}" ]] || continue
      possible="$(_quality_contract_tool_possible_kinds "${tool}" 2>/dev/null || true)"
      [[ -n "${possible}" ]] || return 1
      case "${tool}" in Read|Grep|mcp__*) target_capable=1 ;; esac
      for kind in ${possible}; do
        [[ " ${all_kinds} " == *" ${kind} "* ]] \
          || all_kinds="${all_kinds:+${all_kinds} }${kind}"
      done
    done < <(jq -r '.proof_spec.tool_names[]' <<<"${criterion}")
    while IFS= read -r kind; do
      [[ " ${all_kinds} " == *" ${kind} "* ]] || return 1
    done < <(jq -r '.proof_spec.receipt_kinds[]' <<<"${criterion}")
    if [[ "$(jq -r '.proof_spec.tool_names[0]' <<<"${criterion}")" == "Bash" ]]; then
      _quality_contract_bash_proof_feasible "${criterion}" || return 1
    else
      _quality_contract_nonbash_anchor_bounds_feasible "${criterion}" || return 1
      _quality_contract_canonical_source_anchors_feasible "${criterion}" || return 1
      _quality_contract_mcp_target_anchors_feasible "${criterion}" || return 1
    fi
    if [[ "$(jq -r '.proof_spec.artifact_contains | length' \
        <<<"${criterion}")" -gt 0 && "${target_capable}" -ne 1 ]]; then
      return 1
    fi
  done < <(jq -c '.criteria[]' <<<"${json}")
  return 0
}

quality_contract_validate_payload() {
  local json="${1:-}" redacted=""
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
        | any($strong.artifact_contains[];
            ascii_downcase | contains($needle | ascii_downcase)));
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
      and ([.[] | .profile_entry_id? // empty] | length == (unique | length)))
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
      | (($criterion.proof_spec.command_contains
          + $criterion.proof_spec.artifact_contains) | map(norm)) as $anchors
      | any($anchors[]; generic_anchor | not)
      and any($anchors[]; . as $anchor
        | ([ $ARGS.named.doc.criteria[]
             | select(.id != $criterion.id)
             | (.proof_spec.command_contains[]?,
                .proof_spec.artifact_contains[]?) | norm ]
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
  quality_contract_proof_specs_feasible "${json}"
}

quality_contract_canonicalize_payload() {
  local json="${1:-}"
  quality_contract_validate_payload "${json}" || return 1
  jq -cS '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
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
        | .proof_spec.command_contains |= (map(trim) | unique)
        | .proof_spec.artifact_contains |= (map(trim) | unique)
        | .proof_spec.receipt_kinds |= unique
        | .proof_spec.tool_names |= unique
        | .failure_signal |= trim
        | .tradeoff_boundary |= trim
        | .evidence_policy.allowed_kinds |= unique
      ) | sort_by(.id))
  ' <<<"${json}"
}

_quality_contract_digest() {
  _omc_token_digest "${1:-}"
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
  local definition="${1:-}" required_ids="${2:-}" snapshot="" snapshot_file
  quality_contract_validate_payload "${definition}" || return 1
  [[ -n "${required_ids}" ]] \
    || required_ids="$(_quality_contract_required_profile_ids_json)" || return 1
  jq -e 'type == "array" and length == (unique | length)
    and all(.[]; type == "string" and test("^[A-Za-z0-9._:-]{3,128}$"))' \
    <<<"${required_ids}" >/dev/null 2>&1 || return 1
  snapshot_file="$(session_file "quality_constitution_snapshot.json")"
  if [[ -f "${snapshot_file}" && ! -L "${snapshot_file}" ]]; then
    snapshot="$(_quality_contract_read_json_file "${snapshot_file}" 262144)" || return 1
    jq -e '.schema_version == 1 and (.generation | type == "number")
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
  jq -e --argjson required "${required_ids}" --argjson snapshot "${snapshot}" '
    ([.standards[] | .profile_entry_id? // empty] | unique) as $bound
    | all($required[]; . as $id | $bound | index($id))
    and all(.standards[] | select(.kind == "profile"); . as $standard
      | any([$snapshot.blocking_claims[], $snapshot.advisory_claims[],
             $snapshot.tentative_claims[]][];
          .id == $standard.profile_entry_id
          and .statement == $standard.reference))
  ' <<<"${definition}" >/dev/null 2>&1
}

_quality_contract_profile_metadata_json() {
  local snapshot_file snapshot
  snapshot_file="$(session_file "quality_constitution_snapshot.json")"
  if [[ ! -e "${snapshot_file}" ]]; then
    jq -cnS '{generation:0,digest:"none"}'
    return
  fi
  snapshot="$(_quality_contract_read_json_file "${snapshot_file}" 262144)" || return 1
  jq -ceS '
    select(.schema_version == 1)
    | select((.generation|type)=="number" and .generation >= 0)
    | select((.digest|type)=="string" and (.digest|length) >= 4)
    | {generation,digest}
  ' <<<"${snapshot}"
}

quality_contract_build_envelope() {
  [[ "$#" -ge 11 && "$#" -le 12 ]] || return 1
  local definition="$1" cycle="$2" objective_ts="$3" prompt_revision="$4"
  local objective_digest="$5" enforcement_generation="$6" plan_revision="$7"
  local created_ts="$8" planner_agent="$9" native_agent_id="${10}"
  local lifecycle_dispatch_id="${11}" contract_revision="${12:-1}"
  local canonical payload_digest contract_identity contract_digest contract_id envelope
  local profile_blocking_ids profile_metadata late=false

  [[ "$(read_state "quality_constitution_status" 2>/dev/null || true)" != "invalid" ]] \
    || return 1
  canonical="$(quality_contract_canonicalize_payload "${definition}")" || return 1
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
  quality_contract_validate_profile_bindings \
    "${canonical}" "${profile_blocking_ids}" || return 1
  # `late` diagnoses only the forbidden first freeze after implementation has
  # begun. A later revision is admitted by record-plan only after it preserves
  # both the immutable pre-mutation floor and the current contract, so marking
  # that additive re-contract late would deadlock legitimate scope expansion.
  if [[ "${contract_revision}" == "1" ]] \
      && [[ -n "$(read_state "first_mutation_ts" 2>/dev/null || true)" ]]; then
    late=true
  fi
  [[ "${cycle}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${objective_ts}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${prompt_revision}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${plan_revision}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${created_ts}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${contract_revision}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${objective_digest}" =~ ^[A-Za-z0-9._:-]{8,128}$ ]] || return 1
  [[ "${enforcement_generation}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${planner_agent}" =~ ^[A-Za-z0-9_.:-]{1,128}$ ]] || return 1
  [[ "${native_agent_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "${lifecycle_dispatch_id}" =~ ^dispatch-[A-Za-z0-9._:-]{8,120}$ ]] || return 1

  payload_digest="$(_quality_contract_digest "${canonical}")" || return 1
  contract_identity="$(jq -cnS \
    --argjson contract_revision "${contract_revision}" \
    --argjson review_cycle_id "${cycle}" \
    --argjson objective_prompt_ts "${objective_ts}" \
    --argjson objective_prompt_revision "${prompt_revision}" \
    --arg objective_digest "${objective_digest}" \
    --arg enforcement_generation "${enforcement_generation}" \
    --argjson plan_revision "${plan_revision}" \
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
       plan_revision:$plan_revision,created_ts:$created_ts,
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
    --argjson created_ts "${created_ts}" \
    --arg planner_agent "${planner_agent}" \
    --arg native_agent_id "${native_agent_id}" \
    --arg lifecycle_dispatch_id "${lifecycle_dispatch_id}" \
    --arg payload_digest "${payload_digest}" \
    --argjson profile_blocking_ids "${profile_blocking_ids}" \
    --argjson quality_constitution_generation "$(jq -r '.generation' <<<"${profile_metadata}")" \
    --arg quality_constitution_digest "$(jq -r '.digest' <<<"${profile_metadata}")" \
    --argjson late "${late}" '
      {_v:1,contract_id:$contract_id,contract_revision:$contract_revision,
       review_cycle_id:$review_cycle_id,objective_prompt_ts:$objective_prompt_ts,
       objective_prompt_revision:$objective_prompt_revision,
       objective_digest:$objective_digest,
       ulw_enforcement_generation:$enforcement_generation,
       plan_revision:$plan_revision,created_ts:$created_ts,
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
    and (keys | sort == ["_v","contract_id","contract_revision","created_ts",
      "definition","late","objective_digest","objective_prompt_revision",
      "objective_prompt_ts","payload_digest","plan_revision","planner",
      "profile_blocking_ids","quality_constitution_digest",
      "quality_constitution_generation","review_cycle_id","ulw_enforcement_generation"])
    and ._v == 1
    and (.contract_id | type == "string" and test("^qc-[A-Za-z0-9._:-]{8,80}$"))
    and (.contract_revision | type == "number" and floor == . and . >= 1)
    and (.review_cycle_id | type == "number" and floor == . and . >= 1)
    and (.objective_prompt_ts | type == "number" and floor == . and . >= 1)
    and (.objective_prompt_revision | type == "number" and floor == . and . >= 1)
    and (.objective_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,128}$"))
    and (.ulw_enforcement_generation | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.plan_revision | type == "number" and floor == . and . >= 1)
    and (.created_ts | type == "number" and floor == . and . >= 1)
    and .created_ts >= .objective_prompt_ts
    and (.payload_digest | type == "string" and test("^[A-Za-z0-9._:-]{8,80}$"))
    and (.late | type == "boolean")
    and (.profile_blocking_ids | type == "array" and length == (unique | length)
      and all(.[]; type == "string" and test("^[A-Za-z0-9._:-]{3,128}$")))
    and (.quality_constitution_generation | type == "number" and floor == . and . >= 0)
    and (.quality_constitution_digest | type == "string" and length >= 4 and length <= 128)
    and (.planner | type == "object"
      and (keys | sort == ["agent_type","lifecycle_dispatch_id","native_agent_id"])
      and (.agent_type | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,120}$")))
  ' <<<"${json}" >/dev/null 2>&1 || return 1

  definition="$(jq -c '.definition' <<<"${json}")" || return 1
  canonical="$(quality_contract_canonicalize_payload "${definition}")" || return 1
  quality_contract_validate_profile_bindings "${canonical}" \
    "$(jq -c '.profile_blocking_ids' <<<"${json}")" || return 1
  payload_digest="$(_quality_contract_digest "${canonical}")" || return 1
  [[ "$(jq -r '.payload_digest' <<<"${json}")" == "${payload_digest}" ]] || return 1
  contract_identity="$(jq -cS '
    {contract_revision,review_cycle_id,objective_prompt_ts,
     objective_prompt_revision,objective_digest,ulw_enforcement_generation,
     plan_revision,created_ts,planner,payload_digest,profile_blocking_ids,
     quality_constitution_generation,quality_constitution_digest,late}
  ' <<<"${json}")" || return 1
  expected_id="qc-$(_quality_contract_digest "${contract_identity}")" || return 1
  [[ "$(jq -r '.contract_id' <<<"${json}")" == "${expected_id}" ]]
}

quality_contract_canonicalize_envelope() {
  local json="${1:-}" canonical_definition
  quality_contract_validate_envelope "${json}" || return 1
  canonical_definition="$(quality_contract_canonicalize_payload \
    "$(jq -c '.definition' <<<"${json}")")" || return 1
  jq -cS --argjson definition "${canonical_definition}" \
    '.definition = $definition' <<<"${json}"
}

quality_contract_revision_preserves_floor() {
  local new_definition="${1:-}" old_envelope="${2:-}"
  local canonical_new canonical_old
  canonical_new="$(quality_contract_canonicalize_payload \
    "${new_definition}")" || return 1
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

_quality_contract_read_json_file() {
  local file="${1:-}" max_bytes="${2:-65536}" bytes
  [[ -n "${file}" && -f "${file}" && ! -L "${file}" && -r "${file}" ]] || return 1
  bytes="$(wc -c <"${file}" | tr -d '[:space:]')"
  [[ "${bytes}" =~ ^[0-9]+$ && "${bytes}" -le "${max_bytes}" ]] || return 1
  jq -ce '.' "${file}" 2>/dev/null
}

quality_contract_validate_current() {
  local contract_file="${1:-}" contract cycle objective_ts objective_digest
  local objective_prompt_revision enforcement plan_revision contract_id
  local contract_revision contract_late mirror scope_recheck first_mutation_ts
  local floor_file floor frozen_id frozen_revision frozen_payload_digest
  local current_profile_ids current_profile_metadata
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
  quality_contract_validate_profile_bindings \
    "$(jq -c '.definition' <<<"${contract}")" "${current_profile_ids}" || return 1
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
      "$(jq -c '.definition' <<<"${contract}")" "${floor}" || return 1
  fi
  quality_contract_canonicalize_envelope "${contract}"
}

_quality_contract_cost_only_text() {
  local text="${1:-}" lower
  lower="$(printf '%s' "${text}" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "${lower}" | grep -Eiq \
    '(too (expensive|costly|large|hard)|takes? too long|time[- ]consuming|requires? (significant|too much) (effort|work|time)|not worth (it|the effort)|session (is|was) (already )?(large|long)|blocked by (cost|complexity)|risk(y)? to change)' \
    || return 1
  printf '%s' "${lower}" | grep -Eiq \
    '(measur|benchmark|experiment|test(ed|ing)?|observ(ed|ation)|receipt|regress(ed|ion)?|failed|latency|throughput|error rate|conversion|accessibility audit)' \
    && return 1
  return 0
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
      and (test("[\u0000-\u001f]") | not);
    def ids:
      type == "array" and length == (unique | length)
      and all(.[]; type == "string" and test("^Q-[0-9]{3}$"));
    def refs:
      type == "array" and length >= 1 and length <= 20
      and length == (unique | length)
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
      and length == (unique | length) and all(.[]; text(8;1000)))
    and (.limits | type == "array" and length >= 1 and length <= 10
      and length == (unique | length) and all(.[]; text(4;500)))
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
  done < <(jq -r '.criteria[].basis, .frontier.why, .frontier.recommended_move,
    .alternatives_searched[]' \
    <<<"${json}")
}

quality_review_canonicalize_payload() {
  local json="${1:-}"
  quality_review_validate_payload "${json}" || return 1
  jq -cS '
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
  ' <<<"${json}"
}

quality_review_validate_against_contract() {
  local review="${1:-}" contract="${2:-}" verdict="${3:-}"
  local canonical_review canonical_contract token expected_count actual_count
  canonical_review="$(quality_review_canonicalize_payload "${review}")" || return 1
  canonical_contract="$(quality_contract_canonicalize_envelope "${contract}")" || return 1

  jq -e --argjson contract "${canonical_contract}" '
    ([.criteria[].id] | sort) == ([$contract.definition.criteria[].id] | sort)
    and all(.frontier.criterion_ids[];
      . as $id | ([$contract.definition.criteria[].id] | index($id)) != null)
    and all(.criteria[];
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
      ([.criteria[] | select(.status == "unmet") | .id] as $unmet
       | any($contract.definition.criteria[]; . as $criterion
          | $criterion.class == "must"
            and ($unmet | index($criterion.id)) != null))
      or ((.frontier.material == true or .frontier.bar_quality == "weak")
        and (.frontier.criterion_ids | length) >= 1)
    ' \
      <<<"${canonical_review}" >/dev/null 2>&1
    return
  fi
  return 1
}

_quality_contract_read_jsonl_array() {
  local file="${1:-}" max_bytes="${2:-262144}" max_lines="${3:-512}"
  local bytes lines
  [[ "${max_bytes}" =~ ^[1-9][0-9]*$ && "${max_bytes}" -le 2097152 ]] || return 1
  [[ "${max_lines}" =~ ^[1-9][0-9]*$ && "${max_lines}" -le 4096 ]] || return 1
  if [[ ! -e "${file}" ]]; then
    printf '[]'
    return 0
  fi
  [[ -f "${file}" && ! -L "${file}" && -r "${file}" ]] || return 1
  bytes="$(wc -c <"${file}" | tr -d '[:space:]')"
  lines="$(wc -l <"${file}" | tr -d '[:space:]')"
  [[ "${bytes}" =~ ^[0-9]+$ && "${bytes}" -le "${max_bytes}" ]] || return 1
  [[ "${lines}" =~ ^[0-9]+$ && "${lines}" -le "${max_lines}" ]] || return 1
  jq -sc '.' "${file}" 2>/dev/null
}

_quality_contract_receipts_schema_valid() {
  local receipts="${1:-}" max_rows="${2:-512}"
  [[ "${max_rows}" =~ ^[1-9][0-9]*$ && "${max_rows}" -le 4096 ]] || return 1
  jq -e --argjson max_rows "${max_rows}" '
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
        "edit_revision","evidence_kind","input_digest","method","outcome",
        "plan_revision","proof_identity","quality_contract_id","quality_contract_revision",
        "receipt_id","result","result_digest","review_cycle_id","scope",
        "tool_name","tool_use_id","ts"])
      and ._v == 2
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
      and (.artifact_target | type == "string" and length <= 1000)
      and (.artifact_digest | type == "string" and length <= 128)
      and (.edit_revision | type == "number" and floor == . and . >= 0)
      and (.code_revision | type == "number" and floor == . and . >= 0)
      and (.plan_revision | type == "number" and floor == . and . >= 0)
      and (.review_cycle_id | type == "number" and floor == . and . >= 0)
      and (.quality_contract_id | type == "string"
        and (. == "" or test("^qc-[A-Za-z0-9._:-]{8,80}$")))
      and (.quality_contract_revision | type == "number" and floor == . and . >= 0)
      and (.ts | type == "number" and floor == . and . >= 1))
  ' <<<"${receipts}" >/dev/null 2>&1
}

quality_contract_receipt_matches_criterion() {
  local receipt="${1:-}" criterion="${2:-}"
  jq -en --argjson receipt "${receipt}" --argjson criterion "${criterion}" '
    def tool_match($pattern;$actual):
      if ($pattern | endswith("*")) then
        $actual | startswith($pattern[0:-1])
      else $actual == $pattern end;
    ($criterion.proof_spec.receipt_kinds | index($receipt.evidence_kind)) != null
    and any($criterion.proof_spec.tool_names[]; tool_match(.;$receipt.tool_name))
    and all($criterion.proof_spec.command_contains[];
      . as $token | ($receipt.command | ascii_downcase | contains($token | ascii_downcase)))
    and all($criterion.proof_spec.artifact_contains[];
      . as $token | ($receipt.artifact_target | ascii_downcase | contains($token | ascii_downcase)))
  ' >/dev/null 2>&1
}

quality_contract_receipt_matching_criterion_ids() {
  local receipt="${1:-}" contract="${2:-}"
  jq -cne --argjson receipt "${receipt}" --argjson contract "${contract}" '
    def tool_match($pattern;$actual):
      if ($pattern | endswith("*")) then
        $actual | startswith($pattern[0:-1])
      else $actual == $pattern end;
    def matches($criterion):
      ($criterion.proof_spec.receipt_kinds
        | index($receipt.evidence_kind)) != null
      and any($criterion.proof_spec.tool_names[];
        tool_match(.;$receipt.tool_name))
      and all($criterion.proof_spec.command_contains[];
        . as $token | ($receipt.command | ascii_downcase
          | contains($token | ascii_downcase)))
      and all($criterion.proof_spec.artifact_contains[];
        . as $token | ($receipt.artifact_target | ascii_downcase
          | contains($token | ascii_downcase)));
    [$contract.definition.criteria[] | select(matches(.)) | .id]
  '
}

_quality_contract_evidence_schema_valid() {
  local evidence="${1:-}"
  jq -e '
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
      and (.contract_revision | type == "number" and floor == . and . >= 1)
      and (.review_cycle_id | type == "number" and floor == . and . >= 1)
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
      and (.edit_revision | type == "number" and floor == . and . >= 0)
      and (.plan_revision | type == "number" and floor == . and . >= 1)
      and (.reviewed_at | type == "number" and floor == . and . >= 1)
      and (.reviewer | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
      and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
      and (.lifecycle_dispatch_id | type == "string"
        and test("^dispatch-[A-Za-z0-9._:-]{8,120}$")))
  ' <<<"${evidence}" >/dev/null 2>&1
}

_quality_contract_verification_current() {
  local outcome confidence threshold verify_ts edit_ts verify_revision code_revision
  outcome="$(read_state "last_verify_outcome" 2>/dev/null || true)"
  confidence="$(read_state "last_verify_confidence" 2>/dev/null || true)"
  threshold="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
  verify_ts="$(read_state "last_verify_ts" 2>/dev/null || true)"
  edit_ts="$(read_state "last_edit_ts" 2>/dev/null || true)"
  verify_revision="$(read_state "last_verify_code_revision" 2>/dev/null || true)"
  code_revision="$(read_state "last_code_edit_revision" 2>/dev/null || true)"
  [[ "${confidence}" =~ ^[0-9]+$ && "${threshold}" =~ ^[0-9]+$ ]] || return 1
  [[ "${outcome}" == "passed" && "${confidence}" -ge "${threshold}" ]] || return 1
  [[ "${verify_ts}" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -n "${edit_ts}" ]]; then
    [[ "${edit_ts}" =~ ^[1-9][0-9]*$ && "${verify_ts}" -ge "${edit_ts}" ]] || return 1
  fi
  if [[ -n "${verify_revision}" || -n "${code_revision}" ]]; then
    [[ "${verify_revision:-0}" == "${code_revision:-0}" ]] || return 1
  fi
  return 0
}

_quality_contract_frontier_schema_valid() {
  local frontier="${1:-}" decision_text
  jq -e '
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
    and (.contract_revision | type == "number" and floor == . and . >= 1)
    and (.review_cycle_id | type == "number" and floor == . and . >= 1)
    and (.edit_revision | type == "number" and floor == . and . >= 0)
    and (.plan_revision | type == "number" and floor == . and . >= 1)
    and (.status == "open" or .status == "clear")
    and (.materiality == "none" or .materiality == "medium" or .materiality == "high")
    and (.dominates_current | type == "boolean")
    and (if .status == "clear" then
      .materiality == "none" and .dominates_current == false
      else (.materiality == "medium" or .materiality == "high")
        and .dominates_current == true end)
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
    and (.reviewed_at | type == "number" and floor == . and . >= 1)
    and (.reviewer | type == "string" and test("^[A-Za-z0-9_.:-]{1,128}$"))
    and (.native_agent_id | type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))
    and (.lifecycle_dispatch_id | type == "string"
      and test("^dispatch-[A-Za-z0-9._:-]{8,120}$"))
  ' <<<"${frontier}" >/dev/null 2>&1 || return 1
  while IFS= read -r decision_text; do
    if _quality_contract_cost_only_text "${decision_text}"; then
      return 1
    fi
  done < <(jq -r '.why, .recommended_move, .alternatives_searched[]' <<<"${frontier}")
}

quality_contract_gate_status_json() {
  local contract_file="${1:-}" evidence_file="${2:-}" frontier_file="${3:-}"
  local receipts_file="${4:-}"
  local required contract evidence receipts frontier="" contract_id contract_revision cycle
  local edit_revision plan_revision verify_current=false assessment status threshold
  if [[ -z "${contract_file}" ]]; then
    contract_file="$(session_file "quality_contract.json")"
  fi
  [[ -n "${evidence_file}" ]] || evidence_file="$(session_file "quality_evidence.jsonl")"
  [[ -n "${frontier_file}" ]] || frontier_file="$(session_file "quality_frontier.json")"
  [[ -n "${receipts_file}" ]] || receipts_file="$(session_file "verification_receipts.jsonl")"
  required="$(read_state "quality_contract_required" 2>/dev/null || true)"

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
  if ! jq -e --argjson receipts "${receipts}" '
      [ .[] as $row
        | [$receipts[] | select(.receipt_id == $row.receipt_id)]
        | select(length == 1)
        | {criterion_id:$row.criterion_id,
           proof_key:.[0].proof_identity} ]
      | group_by(.proof_key)
      | all(.[]; ([.[].criterion_id] | unique | length) == 1)
    ' <<<"${evidence}" >/dev/null 2>&1; then
    jq -cnS '{_v:1,status:"invalid_evidence",contract_valid:true,
      required_count:0,satisfied_count:0,missing_ids:[],stale_ids:[],
      verification_current:false,frontier_status:"unknown"}'
    return 1
  fi
  contract_id="$(jq -r '.contract_id' <<<"${contract}")"
  contract_revision="$(jq -r '.contract_revision' <<<"${contract}")"
  cycle="$(jq -r '.review_cycle_id' <<<"${contract}")"
  edit_revision="$(read_state "edit_revision" 2>/dev/null || true)"
  plan_revision="$(read_state "plan_revision" 2>/dev/null || true)"
  [[ "${edit_revision}" =~ ^[0-9]+$ ]] || edit_revision=0
  threshold="${OMC_VERIFY_CONFIDENCE_THRESHOLD:-40}"
  [[ "${threshold}" =~ ^[0-9]+$ && "${threshold}" -le 100 ]] || threshold=40

  assessment="$(jq -cnS \
    --argjson contract "${contract}" --argjson evidence "${evidence}" \
    --argjson receipts "${receipts}" \
    --arg contract_id "${contract_id}" \
    --argjson contract_revision "${contract_revision}" \
    --argjson cycle "${cycle}" --argjson edit_revision "${edit_revision}" \
    --argjson plan_revision "${plan_revision}" \
    --argjson threshold "${threshold}" '
      def cost_only:
        (ascii_downcase) as $s
        | ($s | test("too (expensive|costly|large|hard)|takes? too long|time[- ]consuming|requires? (significant|too much) (effort|work|time)|not worth (it|the effort)|session (is|was) (already )?(large|long)|blocked by (cost|complexity)|risk(y)? to change"))
        and (($s | test("measur|benchmark|experiment|test(ed|ing)?|observ(ed|ation)|receipt|regress(ed|ion)?|failed|latency|throughput|error rate|conversion|accessibility audit")) | not);
      def same_contract($row):
        $row.contract_id == $contract_id
        and $row.contract_revision == $contract_revision
        and $row.review_cycle_id == $cycle;
      def tool_match($pattern;$actual):
        if ($pattern | endswith("*")) then
          $actual | startswith($pattern[0:-1])
        else $actual == $pattern end;
      def receipt_matches_spec($receipt;$criterion):
        ($criterion.proof_spec.receipt_kinds | index($receipt.evidence_kind)) != null
        and any($criterion.proof_spec.tool_names[];
          tool_match(.;$receipt.tool_name))
        and all($criterion.proof_spec.command_contains[];
          . as $token
          | ($receipt.command | ascii_downcase
            | contains($token | ascii_downcase)))
        and all($criterion.proof_spec.artifact_contains[];
          . as $token
          | ($receipt.artifact_target | ascii_downcase
            | contains($token | ascii_downcase)));
      def observation_bearing($receipt):
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
      def bound_receipt($row;$criterion):
        ([$receipts[] | select(.receipt_id == $row.receipt_id)]) as $matched
        | ($matched | length) == 1
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
            and $receipt.quality_contract_revision == $contract_revision
            and $receipt.review_cycle_id == $cycle
            and $receipt.edit_revision == $edit_revision
            and $receipt.plan_revision == $plan_revision
            and $receipt.outcome == "failed"
            and (observation_bearing($receipt) | not)
            and receipt_matches_spec($receipt;$criterion))
          | $i];
      def current_unreviewed_observation_indexes($criterion):
        [range(0; ($receipts | length)) as $i
          | $receipts[$i] as $receipt
          | select($receipt.quality_contract_id == $contract_id
            and $receipt.quality_contract_revision == $contract_revision
            and $receipt.review_cycle_id == $cycle
            and $receipt.edit_revision == $edit_revision
            and $receipt.plan_revision == $plan_revision
            and $receipt.outcome == "passed"
            and observation_bearing($receipt)
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
        | (current_unreviewed_observation_indexes($criterion) | max // -1) as $observation_index
        | ($failed_index > $accepted_index) as $newer_failed
        | ($accepted_index >= 0 and $observation_index > $accepted_index) as $newer_observation
        | {id:$criterion.id,minimum:$criterion.evidence_policy.minimum,
           current:(if ($newer_failed or $newer_observation)
             then 0 else ($current_refs|length) end),
           candidate_count:($candidates|length),
           stale:($newer_failed or $newer_observation or
             ([$all_candidates[] | select(proof_valid(.;$criterion)
               and .result == "passed"
               and ((same_contract(.) | not)
                 or .edit_revision != $edit_revision
                 or .plan_revision != $plan_revision
                 or (current_receipt(.;$criterion) | not)))]
               | length > 0))}
      ] as $rows
      | {required_count:($rows|length),
         satisfied_count:([$rows[] | select(.current >= .minimum)]|length),
         missing_ids:[$rows[] | select(.current < .minimum and (.stale|not)) | .id],
         stale_ids:[$rows[] | select(.current < .minimum and .stale) | .id]}
    ')" || return 1

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
    and all($frontier.evidence[]; . as $receipt
      | ([$evidence[].receipt_id] | index($receipt)) != null)
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
