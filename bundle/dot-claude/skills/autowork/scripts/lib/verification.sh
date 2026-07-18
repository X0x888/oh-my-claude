# shellcheck shell=bash
# verification.sh — Verification subsystem for oh-my-claude.
#
# Sourced by common.sh after state-io.sh. Inherits `set -euo pipefail`
# from the caller (no shebang, no top-level `set` line — this is a
# sourced library).
#
# Extracted from common.sh in v1.14.0. Behavior is identical to the
# prior in-place definitions; this module is purely a clearer ownership
# boundary that mirrors the v1.12.0 state-io extract and the v1.13.0
# classifier extract.
#
# Public API:
#   verification_matches_project_test_command  — exact/family match against detected ptc
#   verification_has_framework_keyword         — recognize pytest/jest/cargo/bash tests/*.sh/etc.
#   verification_output_has_counts             — output carries assertion/test counts
#   verification_output_has_clear_outcome      — output carries pass/fail signals
#   detect_verification_method                 — pick a verification-method label
#   score_verification_confidence              — 0-100 confidence score for a Bash invocation
#   classify_mcp_verification_tool             — map an MCP tool name to a verify category
#   score_mcp_verification_confidence          — 0-100 confidence score for an MCP call
#   detect_mcp_verification_outcome            — pass/fail from MCP tool output
#   mcp_tool_attempts_artifact_mutation         — conservative connector-write classifier
#   verification_receipt_evidence_kind         — derive a non-model proof kind
#
# Required dependencies (must be defined BEFORE this lib is sourced):
#   environment: OMC_CUSTOM_VERIFY_MCP_TOOLS (with default — set in common.sh)
#
# All functions are pure (no state I/O, no side effects, no JSON).

# --- Bash command verification ---

verification_matches_project_test_command() {
  local cmd="${1:-}"
  local project_test_cmd="${2:-}"

  [[ -n "${cmd}" && -n "${project_test_cmd}" ]] || return 1

  local norm_cmd norm_ptc
  norm_cmd="$(printf '%s' "${cmd}" | sed 's/^[[:space:]]*//' | sed 's/^[A-Z_][A-Z0-9_]*=[^ ]* //')"
  norm_ptc="$(printf '%s' "${project_test_cmd}" | sed 's/^[[:space:]]*//')"

  # Direct prefix/substring match first — covers the common case.
  if [[ "${norm_cmd}" == "${norm_ptc}"* ]] || [[ "${norm_cmd}" == *"${norm_ptc}"* ]]; then
    return 0
  fi

  # Bash-project family match: when the detected project_test_cmd is a
  # concrete `bash tests/<file>.sh` invocation, a user running *any* other
  # `bash tests/<file>.sh` from the same directory is exercising the same
  # test family and should get the +40 project-test bonus. Without this,
  # pure-bash projects (where our detector picks the alphabetically first
  # file) would lose the bonus whenever the user runs a different test
  # file, even though they are demonstrably running the project's test
  # suite. Narrow to the exact `bash <dir>/<file>.sh` shape:
  #
  #   - Reject captured `_dir` containing `..` (path traversal) or any
  #     regex metacharacter we don't intend to interpret literally.
  #   - Escape the captured dir's regex metachars (`.`, `[`, `*`, `^`,
  #     `$`, `+`, `?`, `(`, `)`, `|`, `\`, `/`) before interpolating into
  #     the second regex, so e.g. a ptc of `bash t.sts/foo.sh` does not
  #     also match `bash txsts/other.sh`.
  #   - Require the user's cmd's directory to contain no `/` beyond the
  #     captured prefix, so `bash tests/nested/foo.sh` still matches
  #     `bash tests/foo.sh` (same root) but not `bash other/x.sh`.
  if [[ "${norm_ptc}" =~ ^bash[[:space:]]+([^[:space:]]+/)[^[:space:]]*\.sh$ ]]; then
    local _dir="${BASH_REMATCH[1]}"
    # Path-traversal guard: ../ segments in the ptc are either a
    # misconfigured project root or a malicious input (detection comes
    # from filesystem probing, so the former is more likely, but either
    # way we don't want to over-credit).
    if [[ "${_dir}" == *"../"* ]] || [[ "${_dir}" == "../"* ]]; then
      return 1
    fi
    # Any unusual metachar in a directory name is so uncommon in real
    # project layouts that we reject rather than try to escape. Without
    # this, a ptc like `bash t.sts/foo.sh` would over-match `bash
    # txsts/other.sh` because `.` in a bash regex matches any character.
    # The only metachar we've observed in real test dir names is `.`,
    # which we escape below (bash pattern and ERE agree on `\.`); any
    # other metachar falls through to `return 1` (no bonus), which is
    # the safe default — the user's cmd still scores via the framework-
    # keyword rule.
    case "${_dir}" in
      *[!A-Za-z0-9._/\ -]*) return 1 ;;
    esac
    # Escape `.` using bash parameter expansion — portable across
    # BSD/GNU sed variants, no subshell, no shell-metachar hazards.
    local _dir_esc="${_dir//./\\.}"
    if [[ "${norm_cmd}" =~ ^bash[[:space:]]+${_dir_esc}[^[:space:]]*\.sh($|[[:space:]]) ]]; then
      return 0
    fi
  fi

  return 1
}

verification_has_framework_keyword() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || return 1
  if printf '%s' "${cmd}" | grep -Eiq '\b(pytest|vitest|jest|mocha|cargo test|go test|npm test|pnpm test|yarn test|bun test|rspec|phpunit|xcodebuild test|swift test|mix test|gradle test|mvn test|dotnet test|rake test|deno test|shellcheck|bash -n)\b'; then
    return 0
  fi
  # Shell-native project test scripts — closes the shell-only confidence
  # gap where a project's own bash test runner (e.g.
  # `bash tests/test-install-artifacts.sh`) scored the same as a bare
  # `bash -n`, starving the quality gate of trustworthy signal on
  # harness-style repos. Matches two shapes:
  #   (a) a `tests/` or `test/` directory segment followed by a `.sh`
  #       file — the dominant convention ("bash tests/test-x.sh",
  #       "./tests/runner.sh", "/abs/path/tests/foo.sh").
  #   (b) a filename that itself names it as a test script — `test-x.sh`,
  #       `test_x.sh`, `x_test.sh`, `tests.sh` — invoked via bash/sh
  #       or a relative path.
  # Narrow by design: requires `.sh` terminus (so `bash tests/data.json`
  # is not a test), and requires a bash/sh/./ prefix so `cat tests/x.sh`
  # isn't mistaken for a test run. Word boundaries on `test` prevent
  # matches on `testing`, `testdata`, etc.
  # Word-boundary `\btests?/` is critical: without it, `bash contests/foo.sh`,
  # `bash latests/foo.sh`, `bash greatestsmod/foo.sh` all false-positive
  # because `tests/` appears as a substring inside a non-test directory
  # name. `\b` requires a non-word→word transition before `t`, which is
  # satisfied by `/tests/` (slash → word) and ` tests/` (space → word) but
  # not by `contests/` (n → t). Applies to `test[-_]` and `_test` already.
  if printf '%s' "${cmd}" | grep -Eiq '(^|[[:space:]]|;|&|\||\()(bash|sh|\./)[[:space:]]*[^[:space:]]*(\btests?/|\btest[-_]|_test\b)[^[:space:]]*\.sh\b'; then
    return 0
  fi

  # Definition proof also admits one plain, directly executed verifier script
  # whose filename states the operation it performs. Keep this narrower than a
  # generic `*.sh`: the name must carry a check/verify/audit/benchmark/compare/
  # render token, and the ordinary output factors still have to supply the
  # remaining confidence needed to cross the gate. A silent `render.sh` earns
  # only 30/100; it is not promoted merely because its name sounds authoritative.
  printf '%s' "${cmd}" | grep -Eiq '(^|[[:space:]]|;|&|\||\()(bash|sh|\./)[[:space:]]*([^[:space:]]*/)?([^[:space:]]*[_-])?(check|verify|audit|benchmark|compare|render)([_-][^[:space:]]*)?\.sh\b'
}

verification_output_has_counts() {
  local output="${1:-}"
  [[ -n "${output}" ]] || return 1
  printf '%s' "${output}" | grep -Eiq '[0-9]+ (passed|tests?|specs?|assertions?|examples?|ok)\b|Tests:[[:space:]]*[0-9]+|test result:'
}

verification_output_has_clear_outcome() {
  local output="${1:-}"
  [[ -n "${output}" ]] || return 1
  printf '%s' "${output}" | grep -Eiq '\b(PASS(ED)?|FAIL(ED)?|SUCCESS|OK|ALL.*PASSED|0 failures)\b|exit (code|status)[: ]*[0-9]'
}

detect_verification_method() {
  local cmd="${1:-}"
  local output="${2:-}"
  local project_test_cmd="${3:-}"

  if verification_matches_project_test_command "${cmd}" "${project_test_cmd}"; then
    printf 'project_test_command'
  elif verification_has_framework_keyword "${cmd}"; then
    printf 'framework_keyword'
  elif verification_output_has_counts "${output}" || verification_output_has_clear_outcome "${output}"; then
    printf 'output_signal'
  else
    printf 'builtin_verification'
  fi
}

# score_verification_confidence: Score how confident we are that a command
# actually exercised project-relevant verification. Returns a value 0-100
# on stdout. Scoring factors:
#   - Exact match with project test command: +40
#   - Contains known test framework keyword: +30
#   - Output contains assertion/test count: +20
#   - Output indicates pass/fail (not ambiguous): +10
score_verification_confidence() {
  local cmd="${1:-}"
  local output="${2:-}"
  local project_test_cmd="${3:-}"
  local score=0

  [[ -z "${cmd}" ]] && { printf '0'; return; }

  # Factor 1: Exact/prefix match with detected project test command
  if verification_matches_project_test_command "${cmd}" "${project_test_cmd}"; then
    score=$((score + 40))
  fi

  # Factor 2: Known test framework keywords in the command
  if verification_has_framework_keyword "${cmd}"; then
    score=$((score + 30))
  fi

  # Factor 3: Output contains test counts (e.g. "42 passed", "Tests: 10")
  if verification_output_has_counts "${output}"; then
    score=$((score + 20))
  fi

  # Factor 4: Clear pass/fail outcome in output
  if verification_output_has_clear_outcome "${output}"; then
    score=$((score + 10))
  fi

  printf '%s' "${score}"
}

# score_verification_confidence_factors: same scoring logic as
# score_verification_confidence but returns the per-factor contributions
# as a pipe-delimited key:value string. Lets downstream surfaces (the
# /ulw-status verification debug card, /ulw-report) explain WHY a score
# was what it was without having to re-run the scorer.
#
# v1.27.0 (F-023): closes the user complaint that the verification
# score was "a black box" — when the gate blocked at confidence 30,
# the user couldn't see whether the lint-only command lacked a
# project-test-cmd match (factor 1 = 0) and a framework keyword
# (factor 2 = 0), or whether all factors fired but capped low.
#
# Output format (stable, parser-friendly):
#   "test_match:N|framework:N|output_counts:N|clear_outcome:N|total:N"
# Each N is the contribution to the total (40/30/20/10/0). Total at
# the end matches score_verification_confidence on the same inputs.
score_verification_confidence_factors() {
  local cmd="${1:-}"
  local output="${2:-}"
  local project_test_cmd="${3:-}"
  local f1=0 f2=0 f3=0 f4=0

  if [[ -n "${cmd}" ]]; then
    verification_matches_project_test_command "${cmd}" "${project_test_cmd}" && f1=40
    verification_has_framework_keyword "${cmd}" && f2=30
    verification_output_has_counts "${output}" && f3=20
    verification_output_has_clear_outcome "${output}" && f4=10
  fi
  printf 'test_match:%s|framework:%s|output_counts:%s|clear_outcome:%s|total:%s' \
    "${f1}" "${f2}" "${f3}" "${f4}" "$((f1 + f2 + f3 + f4))"
}

# --- MCP verification helpers ---

# Builtin MCP tool names recognized as verification. Matches against the full
# tool_name from the hook JSON (e.g. mcp__plugin_playwright_playwright__browser_snapshot).
# Pattern uses bash glob-style matching via case statements, not regex.
readonly MCP_VERIFY_SNAPSHOT='*playwright*__browser_snapshot'
readonly MCP_VERIFY_SCREENSHOT='*playwright*__browser_take_screenshot'
readonly MCP_VERIFY_CONSOLE='*playwright*__browser_console_messages'
readonly MCP_VERIFY_NETWORK='*playwright*__browser_network_requests'
readonly MCP_VERIFY_EVALUATE='*playwright*__browser_evaluate'
readonly MCP_VERIFY_RUN_CODE='*playwright*__browser_run_code'
readonly MCP_VERIFY_CU_SCREENSHOT='mcp__computer-use__screenshot'

# classify_mcp_verification_tool: Given a tool_name, return a verification
# category string if the tool is verification-grade, or empty string if not.
classify_mcp_verification_tool() {
  local tool_name="${1:-}"
  [[ -n "${tool_name}" ]] || return 0

  # Check custom MCP verification tools from config
  if [[ -n "${OMC_CUSTOM_VERIFY_MCP_TOOLS}" ]]; then
    local custom_mcp_tools="${OMC_CUSTOM_VERIFY_MCP_TOOLS}"
    # custom_verify_mcp_tools is a pipe-separated list of glob patterns
    local _old_IFS="${IFS}"
    IFS='|'
    for pattern in ${custom_mcp_tools}; do
      # shellcheck disable=SC2254
      case "${tool_name}" in ${pattern}) IFS="${_old_IFS}"; printf 'custom_mcp_tool'; return 0 ;; esac
    done
    IFS="${_old_IFS}"
  fi

  # Builtin classifications (patterns are globs — expansion is intentional)
  # shellcheck disable=SC2254
  case "${tool_name}" in
    ${MCP_VERIFY_SNAPSHOT})     printf 'browser_dom_check' ;;
    ${MCP_VERIFY_SCREENSHOT})   printf 'browser_visual_check' ;;
    ${MCP_VERIFY_CONSOLE})      printf 'browser_console_check' ;;
    ${MCP_VERIFY_NETWORK})      printf 'browser_network_check' ;;
    ${MCP_VERIFY_EVALUATE})     printf 'browser_eval_check' ;;
    ${MCP_VERIFY_RUN_CODE})     printf 'browser_eval_check' ;;
    ${MCP_VERIFY_CU_SCREENSHOT}) printf 'visual_check' ;;
    *) printf '' ;;
  esac
}

# score_mcp_verification_confidence: Score how confident we are that an MCP
# tool call constitutes meaningful verification. Returns 0-100 on stdout.
#
# Base scores are deliberately below the default threshold (40) so that a
# single passive observation (e.g. an empty browser_snapshot) cannot clear
# the verify gate on its own. Passing the gate requires either:
#   - Output that carries assertion/pass-fail signals (+15/+10 bonuses), OR
#   - A UI-edit context bonus when recent edits were to UI files. The
#     bonus is +20 for *targeted* checks (DOM/console/network/eval) and
#     capped at +10 for *purely passive* observations (visual screenshots
#     of either browser or computer-use), so a passive screenshot in a
#     UI-edit session does NOT silently clear the gate at the default
#     threshold of 40 without an assertion-bearing signal.
#
# Args: verify_type, output, has_ui_context ("true"/"false")
score_mcp_verification_confidence() {
  local verify_type="${1:-}"
  local output="${2:-}"
  local has_ui_context="${3:-false}"
  local score=0

  # Base scores — all below default threshold of 40
  case "${verify_type}" in
    browser_dom_check)     score=25 ;;  # DOM snapshot — passive observation
    browser_visual_check)  score=20 ;;  # Screenshot — most passive
    browser_console_check) score=30 ;;  # Console errors — targeted check
    browser_network_check) score=30 ;;  # Network requests — targeted check
    browser_eval_check)    score=35 ;;  # JS evaluation — closest to assertions
    visual_check)          score=15 ;;  # Computer-use screenshot — least targeted
    custom_mcp_tool)       score=35 ;;  # User-configured — some trust
    *)                     score=10 ;;
  esac

  # UI-context bonus: if recent edits include UI files, browser-based
  # verification becomes meaningfully more relevant. Targeted checks
  # (DOM/console/network/eval) earn the full +20; purely passive
  # screenshots earn only +10 so they cannot clear the default
  # threshold (40) on context alone — an assertion-bearing signal in
  # the output is still required.
  if [[ "${has_ui_context}" == "true" ]]; then
    case "${verify_type}" in
      browser_visual_check|visual_check)
        score=$((score + 10))
        ;;
      *)
        score=$((score + 20))
        ;;
    esac
  fi

  # Bonus: output contains assertion-like content or test counts
  if [[ -n "${output}" ]]; then
    if printf '%s' "${output}" | grep -Eiq '[0-9]+ (passed|tests?|errors?|warnings?)\b'; then
      score=$((score + 15))
    fi
    if printf '%s' "${output}" | grep -Eiq '\b(PASS(ED)?|SUCCESS|OK|no errors|0 errors)\b'; then
      score=$((score + 10))
    fi
  fi

  # Cap at 100
  [[ "${score}" -gt 100 ]] && score=100
  printf '%s' "${score}"
}

# detect_mcp_verification_outcome: Detect pass/fail from MCP tool output.
# Returns "passed" or "failed" on stdout.
detect_mcp_verification_outcome() {
  local output="${1:-}"
  local verify_type="${2:-}"

  # Default: passed (MCP observation tools don't inherently "fail")
  [[ -n "${output}" ]] || { printf 'passed'; return; }

  # Check for explicit error signals in output
  case "${verify_type}" in
    browser_console_check)
      # Console messages: look for JS error types, uncaught exceptions, and
      # generic "Error:" prefix (common in console.error output).
      if printf '%s' "${output}" | grep -Eq '\b(TypeError|ReferenceError|SyntaxError|RangeError|URIError|EvalError|uncaught|Uncaught)\b|^Error:|[[:space:]]Error:'; then
        printf 'failed'; return
      fi
      ;;
    browser_network_check)
      # Network: look for failed HTTP statuses and connection errors.
      # Uses "timed? out" instead of bare "timeout" to avoid matching config values.
      if printf '%s' "${output}" | grep -Eiq '\b(401|403|404|500|502|503|failed|timed? out|CORS|ERR_|Unauthorized|Forbidden)\b'; then
        printf 'failed'; return
      fi
      ;;
    browser_eval_check)
      # JS evaluation: look for specific error types, assertion failures, and
      # generic "Error:" prefix (thrown errors stringify as "Error: message").
      if printf '%s' "${output}" | grep -Eq '\b(AssertionError|TypeError|ReferenceError|SyntaxError|RangeError)\b|Uncaught|FAIL|^Error:|[[:space:]]Error:'; then
        printf 'failed'; return
      fi
      ;;
    *)
      # DOM snapshots and screenshots: check for error page indicators
      if printf '%s' "${output}" | grep -Eiq '\b(500 Internal Server Error|404 Not Found|Application Error|Something went wrong)\b'; then
        printf 'failed'; return
      fi
      ;;
  esac

  printf 'passed'
}

classify_verification_scope() {
  local command_text="${1:-}"
  local project_test_cmd="${2:-}"
  local lower project_lower
  lower="$(printf '%s' "${command_text}" | tr '[:upper:]' '[:lower:]')"
  project_lower="$(printf '%s' "${project_test_cmd}" | tr '[:upper:]' '[:lower:]')"

  [[ -z "${lower}" ]] && { printf 'unknown'; return; }

  if [[ -n "${project_lower}" && "${lower}" == *"${project_lower}"* ]]; then
    printf 'full'
    return
  fi

  if grep -Eiq '(^|[[:space:]])(shellcheck|bash[[:space:]]+-n|ruff|mypy|eslint|tsc|typecheck|markdownlint|mdl|vale|textlint|alex|write-good|ansible-lint|helm[[:space:]]+lint|terraform[[:space:]]+validate)\b' <<<"${lower}"; then
    printf 'lint'
    return
  fi

  if grep -Eiq '(^|[[:space:]])(docker[[:space:]]+build|docker[[:space:]]+compose[[:space:]]+build|swift[[:space:]]+build|cargo[[:space:]]+build|npm[[:space:]]+run[[:space:]]+build|pnpm[[:space:]]+build|yarn[[:space:]]+build|bun[[:space:]]+run[[:space:]]+build|nix[[:space:]]+build)\b' <<<"${lower}"; then
    printf 'build'
    return
  fi

  if grep -Eiq '(^|[[:space:]])(terraform[[:space:]]+plan|terraform[[:space:]]+apply|kubectl|helm|ansible|docker[[:space:]]+compose)\b' <<<"${lower}"; then
    printf 'operations'
    return
  fi

  if grep -Eiq '(^|[[:space:]])(npm[[:space:]]+(test|run[[:space:]]+test)|pnpm[[:space:]]+(test|run[[:space:]]+test)|yarn[[:space:]]+(test|run[[:space:]]+test)|bun[[:space:]]+(test|run[[:space:]]+test)|bash[[:space:]]+verify\.sh|bash[[:space:]]+tests?/test[^[:space:]]*\.sh|pytest|python[[:space:]]+-m[[:space:]]+pytest|vitest|jest|go[[:space:]]+test|cargo[[:space:]]+test|swift[[:space:]]+test|xcodebuild[[:space:]].*test|phpunit|rspec|gradle[[:space:]]+test|mvn[[:space:]]+(test|verify)|dotnet[[:space:]]+test|mix[[:space:]]+test|rake[[:space:]]+test|deno[[:space:]]+test|zig[[:space:]]+build[[:space:]]+test)\b' <<<"${lower}"; then
    if grep -Eiq '(^|[[:space:]])(-k|--testnamepattern|--test-name-pattern|--grep|--runintest|--filter|--tests?|--include|--only|:[[:alnum:]_.-]+|[./][^[:space:]]*(test|spec)[^[:space:]]*\.(js|jsx|ts|tsx|py|rb|go|rs|swift|php|java|cs)|tests?/[^[:space:]]+|spec/[^[:space:]]+)' <<<"${lower}"; then
      printf 'targeted'
    else
      printf 'full'
    fi
    return
  fi

  if grep -Eiq '\b(test|tests|verify|validate|check)\b' <<<"${lower}"; then
    printf 'unknown_test'
  else
    printf 'unknown'
  fi
}

# Connector/app mutations do not pass through Edit/Write and historically
# escaped both the pre-contract gate and edit-generation clocks. The Definition
# boundary is deliberately fail-closed: only a small, syntactically
# observational operation set is exempt. Unknown wrappers, browser interaction,
# code evaluation, navigation, and generic request/call tools may mutate remote
# state and therefore advance the mutation generation.
mcp_tool_attempts_artifact_mutation() {
  local tool_name="${1:-}" tool_input_json="${2:-{}}" lower operation="" joined
  local tool_operation="" graphql_document=""
  [[ "${tool_name}" == mcp__* ]] || return 1
  lower="$(printf '%s' "${tool_name}" | tr '[:upper:]-' '[:lower:]_')"

  if command -v jq >/dev/null 2>&1; then
    operation="$(jq -r '
      [(.action? // empty),(.operation? // empty),(.method? // empty),
       (.verb? // empty),(.request_type? // empty),(.mode? // empty)]
      | map(select(type == "string" and length > 0)) | join("_")
    ' <<<"${tool_input_json}" 2>/dev/null || true)"
    operation="$(printf '%s' "${operation}" | tr '[:upper:]-' '[:lower:]_')"
    graphql_document="$(jq -r '.query? // .document? // empty' \
      <<<"${tool_input_json}" 2>/dev/null || true)"
  fi
  joined="${lower}_${operation}"
  tool_operation="${lower##*__}"

  # Any explicit interaction/write/evaluation verb wins over an observational
  # token elsewhere in the name (for example browser_get_and_click).
  if grep -Eiq '(^|_)(create|update|edit|write|delete|remove|archive|restore|move|copy|rename|append|insert|replace|format|clear|upload|download|export|sync|publish|send|reply|comment|share|grant|revoke|permission|batch|set|add|import|apply|submit|commit|click|type|fill|select|press|drag|drop|navigate|open|goto|evaluate|execute|run|code|request|call|post|put|patch)(_|$)' <<<"${joined}"; then
    return 0
  fi

  # GraphQL hides its mutation verb inside the document rather than the tool
  # name. Inspect only the operation prefix, not arbitrary prose/content.
  if [[ "${lower}" == *graphql* ]] \
      && grep -Eiq '^[[:space:]]*mutation([[:space:]({]|$)' \
        <<<"${graphql_document}"; then
    return 0
  fi

  # If the wrapper declares an action/method, every declared value must be a
  # known observational operation. This prevents a safe noun elsewhere in the
  # tool name from laundering a generic call.
  if [[ -n "${operation}" ]] \
      && ! grep -Eq '^(read|get|head|options|list|search|find|query|fetch|inspect|status|schema|describe|metadata|preview|validate|verify|check|snapshot|screenshot)(_(read|get|head|options|list|search|find|query|fetch|inspect|status|schema|describe|metadata|preview|validate|verify|check|snapshot|screenshot))*$' \
        <<<"${operation}"; then
    return 0
  fi

  # Only a terminal MCP function whose family is explicitly observational is
  # exempt. Unknown prefixes/suffixes such as sync_status or query_and_sync are
  # mutations because they do not begin with an allowed reader and mutation
  # tokens above win even when an allowed reader is also present.
  case "${tool_operation}" in
    snapshot|snapshot_*|screenshot|screenshot_*|browser_snapshot|browser_take_screenshot|browser_console_messages|browser_network_requests|console_messages|network_requests|read|read_*|get|get_*|list|list_*|search|search_*|find|find_*|query|query_*|fetch|fetch_*|inspect|inspect_*|status|status_*|schema|schema_*|describe|describe_*|metadata|metadata_*|preview|preview_*|validate|validate_*|verify|verify_*|check|check_*)
      return 1 ;;
  esac
  return 0
}

# Derive the quality-contract evidence kind from the hook-observed tool, not
# from reviewer prose. The planner may permit several kinds, but a reviewer can
# only cite the kind actually stamped into the authoritative verification
# receipt.
verification_receipt_evidence_kind() {
  local method="${1:-}" scope="${2:-}" command_text="${3:-}" lower
  lower="$(printf '%s' "${command_text}" | tr '[:upper:]' '[:lower:]')"
  case "${method}" in
    mcp_browser_visual_check|mcp_computer_visual_check) printf 'render'; return ;;
    mcp_*) printf 'inspection'; return ;;
  esac
  if printf '%s' "${lower}" | grep -Eiq \
    '(^|[^[:alnum:]_])(benchmark|bench|hyperfine|performance|latency|throughput)([^[:alnum:]_]|$)'; then
    printf 'benchmark'
  elif printf '%s' "${lower}" | grep -Eiq \
    '(^|[^[:alnum:]_])(compare|comparison|golden|snapshot[-_ ]diff|visual[-_ ]diff)([^[:alnum:]_]|$)'; then
    printf 'comparison'
  elif printf '%s' "${lower}" | grep -Eiq \
    '(^|[^[:alnum:]_])(render|rendering|rendered)([^[:alnum:]_]|$)'; then
    printf 'render'
  elif [[ "${scope}" == "lint" ]] && printf '%s' "${lower}" | grep -Eiq \
    '(^|[[:space:]])(vale|textlint|alex|write-good|markdownlint|mdl)([[:space:]]|$)'; then
    printf 'inspection'
  else
    printf 'test'
  fi
}

# Definition-of-Excellent proof is a stricter authority surface than the
# legacy "did this look test-like?" score. A compound shell command can print
# its own success text, hide a failure behind `|| true`, or use a diagnostic
# flag that never executes the suite. Admit only one plain invocation of a
# known execution family (or the repository's detected test command). This is
# intentionally conservative: an unusual verifier can still be run, but it
# cannot certify a Definition criterion until it is made a project command or
# wrapped by a clearly named test/check/verify/benchmark script.
verification_command_is_authoritative_execution() {
  local command_text="${1:-}" project_test_cmd="${2:-}" normalized project=""
  normalized="$(printf '%s' "${command_text}" \
    | tr '\t\r\n' '   ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
  [[ -n "${normalized}" ]] || return 1

  # No shell grammar beyond a single argv vector. Quoting is allowed; shell
  # composition, substitutions, redirections, comments, and backgrounding are
  # not. This closes `pytest --version; printf "10 passed"` and its variants.
  [[ "${command_text}" != *$'\n'* && "${command_text}" != *$'\r'* ]] || return 1
  case "${normalized}" in
    *';'*|*'&&'*|*'||'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('*|*'${'*|*'#'*|*'&') return 1 ;;
  esac

  # Discovery/help/configuration modes do not execute the claimed proof.
  if grep -Eiq '(^|[[:space:]])(--version|-V|--help|-h|--collect-only|--list(-tests)?|--dry-run|--showconfig|--print-config|--print-only|--no-run)([=[:space:]]|$)' \
      <<<"${normalized}"; then
    return 1
  fi

  if [[ -n "${project_test_cmd}" ]]; then
    project="$(printf '%s' "${project_test_cmd}" \
      | tr '\t\r\n' '   ' \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
    if [[ -n "${project}" ]] \
        && { [[ "${normalized}" == "${project}" ]] \
          || [[ "${normalized}" == "${project} "* ]]; }; then
      return 0
    fi
  fi

  # shellcheck disable=SC2254
  case "${normalized}" in
    pytest|pytest\ *|python\ -m\ pytest|python\ -m\ pytest\ *|python3\ -m\ pytest|python3\ -m\ pytest\ *|uv\ run\ pytest|uv\ run\ pytest\ *|vitest|vitest\ *|jest|jest\ *|npx\ vitest|npx\ vitest\ *|npx\ jest|npx\ jest\ *) return 0 ;;
    cargo\ test|cargo\ test\ *|go\ test|go\ test\ *|swift\ test|swift\ test\ *|swift\ build|swift\ build\ *|ruff\ check\ *|mypy\ *|eslint\ *|tsc|tsc\ *|phpunit|phpunit\ *|rspec|rspec\ *|bundle\ exec\ rspec|bundle\ exec\ rspec\ *|rake\ test|rake\ test\ *|zig\ build|zig\ build\ *|deno\ test|deno\ test\ *|nix\ build|nix\ build\ *) return 0 ;;
    shellcheck\ *|bash\ -n\ *|zsh\ -n\ *|sh\ -n\ *) return 0 ;;
    npm\ test|npm\ test\ *|npm\ run\ test|npm\ run\ test\ *|npm\ run\ check|npm\ run\ check\ *|npm\ run\ lint|npm\ run\ lint\ *|npm\ run\ build|npm\ run\ build\ *|pnpm\ test|pnpm\ test\ *|pnpm\ run\ test|pnpm\ run\ test\ *|pnpm\ run\ check|pnpm\ run\ check\ *|pnpm\ run\ lint|pnpm\ run\ lint\ *|pnpm\ run\ build|pnpm\ run\ build\ *|yarn\ test|yarn\ test\ *|yarn\ run\ test|yarn\ run\ test\ *|yarn\ run\ check|yarn\ run\ check\ *|yarn\ run\ lint|yarn\ run\ lint\ *|yarn\ run\ build|yarn\ run\ build\ *|bun\ test|bun\ test\ *|bun\ run\ test|bun\ run\ test\ *|bun\ run\ check|bun\ run\ check\ *|bun\ run\ lint|bun\ run\ lint\ *|bun\ run\ build|bun\ run\ build\ *) return 0 ;;
    make\ test|make\ test\ *|make\ check|make\ check\ *|make\ lint|make\ lint\ *|make\ verify|make\ verify\ *|make\ build|make\ build\ *|just\ test|just\ test\ *|just\ check|just\ check\ *|just\ lint|just\ lint\ *|just\ verify|just\ verify\ *|just\ build|just\ build\ *) return 0 ;;
    gradle\ *test*|./gradlew\ *test*|xcodebuild\ *test*|xcodebuild\ *build*|mvn\ test|mvn\ test\ *|mvn\ verify|mvn\ verify\ *|dotnet\ test|dotnet\ test\ *|mix\ test|mix\ test\ *) return 0 ;;
    docker\ build\ *|docker\ compose\ build\ *|terraform\ plan|terraform\ plan\ *|terraform\ validate|terraform\ validate\ *|ansible-lint\ *|helm\ lint\ *) return 0 ;;
  esac

  if grep -Eq '^(bash|zsh|sh)[[:space:]]+([^[:space:]]*/)?[^[:space:]]*(test|check|verify|audit|benchmark|compare|render)[^[:space:]]*([[:space:]]|$)' \
      <<<"${normalized}"; then
    return 0
  fi
  if grep -Eq '^([^[:space:]]*/)?[^[:space:]]*(test|check|verify|audit|benchmark|compare|render)[^[:space:]]*([[:space:]]|$)' \
      <<<"${normalized}"; then
    return 0
  fi
  return 1
}

# --- end verification helpers ---
