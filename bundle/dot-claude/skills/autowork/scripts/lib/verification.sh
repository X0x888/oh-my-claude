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
#   verification_command_is_authoritative_execution — reject non-executing shell proof
#   verification_command_semantic_target       — deduplicate one observable execution target
#   verification_output_reports_zero_execution — detect explicit no-test success output
#
# Required dependencies (must be defined BEFORE this lib is sourced):
#   environment: OMC_CUSTOM_VERIFY_MCP_TOOLS (with default — set in common.sh)
#
# Ordinary subsystem functions are pure (no state I/O, no JSON). The two
# explicitly delimited SHA authority regions are deliberate source-time
# bootstrap/seal operations; focused tests audit their hostile-shell behavior.

# BEGIN OMC_SHA_AUTHORITY_SOURCE_BOOTSTRAP
# BASH_ENV may enable alias expansion before this sourced file is parsed. Stop
# it before any authority function or callsite below is defined: otherwise an
# alias for `builtin`, `local`, or an authority helper is baked into the
# function body and cannot be repaired at invocation time. POSIX lookup makes
# the special unset/set builtins outrank same-named functions while `shopt` is
# removed explicitly. Readonly hostile shims fail the source operation closed.
_OMC_SHA_ALIAS_POSIX_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=0
_OMC_SHA_ALIAS_POSIX_VALUE=""
if [[ -o posix ]]; then
  _OMC_SHA_ALIAS_POSIX_WAS_SET=1
fi
if [[ "${POSIXLY_CORRECT+x}" == "x" ]]; then
  _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET=1
  _OMC_SHA_ALIAS_POSIX_VALUE="${POSIXLY_CORRECT}"
fi
POSIXLY_CORRECT=1 || \return 1
# Remove any earlier authority implementation before this file defines the
# trusted chain. A readonly conflicting definition cannot be replaced and is
# therefore a source-time authority failure, never a reason to retain the
# caller's implementation. `builtin`/`readonly` are removed too so the seal at
# the end of the chain cannot be intercepted after alias expansion is off.
if ! \unset -f shopt unset set builtin readonly \
    _verification_sanitize_sha256_shell \
    _verification_trusted_sha256_executable \
    _verification_sha256_output_digest \
    _verification_sha256_text \
    _omc_authority_digest \
    _verification_sha256_file; then
  # Restore the caller before reporting the immutable-name conflict. Alias
  # expansion has not yet changed, and POSIX special builtins remain trusted
  # even if a same-named readonly function caused the failure above.
  if [[ "${_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET}" == "1" ]]; then
    POSIXLY_CORRECT="${_OMC_SHA_ALIAS_POSIX_VALUE}" || \return 1
  else
    \unset POSIXLY_CORRECT || \return 1
  fi
  if [[ "${_OMC_SHA_ALIAS_POSIX_WAS_SET}" == "1" ]]; then
    \set -o posix || \return 1
  else
    \set +o posix || \return 1
  fi
  \unset _OMC_SHA_ALIAS_POSIX_WAS_SET _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET \
    _OMC_SHA_ALIAS_POSIX_VALUE || \return 1
  \return 1
fi
\shopt -u expand_aliases || \return 1
if [[ "${_OMC_SHA_ALIAS_POSIX_VAR_WAS_SET}" == "1" ]]; then
  POSIXLY_CORRECT="${_OMC_SHA_ALIAS_POSIX_VALUE}" || \return 1
else
  \unset POSIXLY_CORRECT || \return 1
fi
if [[ "${_OMC_SHA_ALIAS_POSIX_WAS_SET}" == "1" ]]; then
  \set -o posix || \return 1
else
  \set +o posix || \return 1
fi
\unset _OMC_SHA_ALIAS_POSIX_WAS_SET _OMC_SHA_ALIAS_POSIX_VAR_WAS_SET \
  _OMC_SHA_ALIAS_POSIX_VALUE || \return 1
# END OMC_SHA_AUTHORITY_SOURCE_BOOTSTRAP

# --- Bash command verification ---

verification_matches_project_test_command() {
  local cmd="${1:-}"
  local project_test_cmd="${2:-}"
  local idx=0 argv_prefix=1
  local -a command_argv=() project_argv=()

  [[ -n "${cmd}" && -n "${project_test_cmd}" ]] || return 1

  local norm_cmd norm_ptc
  norm_cmd="$(printf '%s' "${cmd}" | sed 's/^[[:space:]]*//' | sed 's/^[A-Z_][A-Z0-9_]*=[^ ]* //')"
  norm_ptc="$(printf '%s' "${project_test_cmd}" | sed 's/^[[:space:]]*//')"

  # A project command must be the actual argv prefix. Raw substring matching
  # lets an unrelated wrapper borrow the bonus by passing `npm test` as ignored
  # suffix prose, and quoted one-token labels can impersonate split argv.
  if _verification_tokenize_argv "${cmd}" 2>/dev/null \
      && _verification_strip_literal_env_prefix 2>/dev/null; then
    command_argv=("${_VERIFICATION_ARGV[@]}")
    if _verification_tokenize_argv "${project_test_cmd}" 2>/dev/null \
        && _verification_strip_literal_env_prefix 2>/dev/null; then
      project_argv=("${_VERIFICATION_ARGV[@]}")
      if [[ "${#command_argv[@]}" -ge "${#project_argv[@]}" ]]; then
        for ((idx=0; idx<${#project_argv[@]}; idx++)); do
          if [[ "${command_argv[${idx}]}" != "${project_argv[${idx}]}" ]]; then
            argv_prefix=0
            break
          fi
        done
        [[ "${argv_prefix}" -eq 1 ]] && return 0
      fi
    fi
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
  if printf '%s' "${cmd}" | grep -Eiq '\b(pytest|vitest|jest|mocha|cargo test|go test|npm test|pnpm test|yarn test|bun test|rspec|phpunit|xcodebuild test|swift test|mix test|gradle test|mvn test|dotnet test|rake test|deno test|shellcheck|bash -n|zsh -n|sh -n)\b'; then
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
  # generic `*.sh`: the name must carry a check/verify/validate/audit/benchmark/
  # compare/render token, and the ordinary output factors still have to supply the
  # remaining confidence needed to cross the gate. A silent `render.sh` earns
  # only 30/100; it is not promoted merely because its name sounds authoritative.
  if printf '%s' "${cmd}" | grep -Eiq '(^|[[:space:]]|;|&|\||\()(bash|zsh|sh|\./)[[:space:]]*([^[:space:]]*/)?([^[:space:]]*[_-])?(check|verify|validate|audit|benchmark|compare|comparison|render)([_-][^[:space:]]*)?\.sh\b'; then
    return 0
  fi

  # Keep named-verifier scoring aligned with authoritative argv admission,
  # including extensionless checks and `run-tests.sh`. Parse actual tokens so
  # a quoted executable cannot borrow keywords from joined prose.
  if _verification_tokenize_argv "${cmd}" 2>/dev/null \
      && _verification_strip_literal_env_prefix 2>/dev/null; then
    case "$(_verification_executable_family_name \
      "${_VERIFICATION_ARGV[0]}" 2>/dev/null || true)" in
      bash|zsh|sh)
        _verification_token_is_named_verifier \
          "${_VERIFICATION_ARGV[1]:-}" && return 0
        ;;
      *)
        _verification_token_is_named_verifier \
          "${_VERIFICATION_ARGV[0]}" && return 0
        ;;
    esac
  fi
  return 1
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

# Detect an actual negative result without treating green zero summaries such
# as `0 failures`, `Failures: 0, Errors: 0`, or `no errors` as failures. This
# remains output evidence only; a hook-reported nonzero tool status always wins
# in the caller.
verification_output_reports_failure() {
  local output="${1:-}" line="" lower="" verdict=-1
  [[ -n "${output}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lower="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
    # Prefer result-shaped envelopes and counts. Incidental prose such as
    # `ok 1 - returns an error` or `PASS renders the error page` is not a
    # negative result. A later decisive line may supersede an earlier retry.
    if printf '%s' "${lower}" | grep -Eiq \
        'error\[e[0-9]+\]|exit[[:space:]]+(code|status)[: ]*[1-9][0-9]*|(^|[^0-9])[1-9][0-9]*[[:space:]]+(failed|failures?|errors?)([^[:alnum:]_]|$)|(failures?|errors?)[[:space:]]*:[[:space:]]*[1-9][0-9]*([^0-9]|$)|^[[:space:]]*not[[:space:]]+ok([[:space:]]|$)|^[[:space:]]*#[[:space:]]*fail[[:space:]]+[1-9][0-9]*([^0-9]|$)|(benchmark|comparison|render|snapshot|screenshot|worker|command|process|build|checks?|verification|suite|tests?)[^[:alnum:]_]+(failed|failure|errored|crashed|timed[ -]?out)([^[:alnum:]_]|$)'; then
      verdict=1
      continue
    fi
    if printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])0[[:space:]]+(failed|failures?|errors?)([^[:alnum:]_]|$)|(failures?|errors?)[[:space:]]*:[[:space:]]*0([^0-9]|$)|(^|[^[:alnum:]_])no[[:space:]]+(failures?|errors?)([^[:alnum:]_]|$)'; then
      if printf '%s' "${lower}" | grep -Eiq \
          '(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|ok)([^[:alnum:]_]|$)|^[[:space:]=_-]*(pass(ed)?|success|ok)([[:space:]:-]|$)|test[[:space:]]+result:[[:space:]]*(ok|passed)|exit[[:space:]]+(code|status)[: ]*0([^0-9]|$)|^[[:space:]]*[1-9][0-9]*[[:space:]]+examples?([,[:space:]]|$)|tests[[:space:]]+run:[[:space:]]*[1-9][0-9]*([^0-9]|$)'; then
        verdict=0
      fi
      continue
    fi
    if printf '%s' "${lower}" | grep -Eiq \
        '^[[:space:]=_-]*(fail(ed|ure|ures)?|errors?)([[:space:]:-]|$)'; then
      verdict=1
      continue
    fi
    if printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|ok)([^[:alnum:]_]|$)|^[[:space:]=_-]*(pass(ed)?|success|ok)([[:space:]:-]|$)|test[[:space:]]+result:[[:space:]]*(ok|passed)|exit[[:space:]]+(code|status)[: ]*0([^0-9]|$)'; then
      verdict=0
    fi
  done <<<"${output}"
  [[ "${verdict}" -eq 1 ]]
}

_verification_descriptor_encode_value() {
  local value="${1:-}"
  [[ -n "${value}" \
      && "${value}" != *$'\n'* && "${value}" != *$'\r'* \
      && "${value}" != *$'\t'* ]] || return 1
  # Escape the escape byte first so literal `%3B` and literal `;` remain
  # distinct proof values. Semicolon is the descriptor-list delimiter.
  printf '%s' "${value}" | sed -e 's/%/%25/g' -e 's/;/%3B/g'
}

_verification_ipv6_is_canonical() {
  local address="${1:-}" left="" right="" part=""
  local explicit=0 missing=0 index=0 run_start=0 run_len=0
  local best_start=-1 best_len=0 compressed=0
  local -a left_parts=() right_parts=() full=()
  [[ -n "${address}" && "${address}" == "$(printf '%s' "${address}" \
      | tr '[:upper:]' '[:lower:]')" \
      && "${address}" =~ ^[0-9a-f:]+$ \
      && "${address}" != *:::* ]] || return 1
  if [[ "${address}" == *::* ]]; then
    compressed=1
    [[ "${address#*::}" != *::* ]] || return 1
    left="${address%%::*}"
    right="${address#*::}"
  else
    [[ "${address}" != :* && "${address}" != *: ]] || return 1
    left="${address}"
  fi
  [[ -z "${left}" ]] || IFS=':' read -r -a left_parts <<<"${left}"
  [[ -z "${right}" ]] || IFS=':' read -r -a right_parts <<<"${right}"
  if (( ${#left_parts[@]} > 0 )); then
    for part in "${left_parts[@]}"; do
      [[ "${part}" =~ ^[0-9a-f]{1,4}$ \
          && ( ${#part} -eq 1 || "${part}" != 0* ) ]] || return 1
    done
  fi
  if (( ${#right_parts[@]} > 0 )); then
    for part in "${right_parts[@]}"; do
      [[ "${part}" =~ ^[0-9a-f]{1,4}$ \
          && ( ${#part} -eq 1 || "${part}" != 0* ) ]] || return 1
    done
  fi
  explicit=$((${#left_parts[@]} + ${#right_parts[@]}))
  if [[ "${compressed}" -eq 1 ]]; then
    (( explicit < 8 )) || return 1
    missing=$((8 - explicit))
  else
    [[ "${explicit}" -eq 8 ]] || return 1
  fi
  full=()
  if (( ${#left_parts[@]} > 0 )); then full=("${left_parts[@]}"); fi
  for ((index=0; index<missing; index++)); do full+=(0); done
  if (( ${#right_parts[@]} > 0 )); then full+=("${right_parts[@]}"); fi
  run_len=0
  for ((index=0; index<=8; index++)); do
    if (( index < 8 )) && [[ "${full[${index}]}" == "0" ]]; then
      [[ "${run_len}" -gt 0 ]] || run_start="${index}"
      run_len=$((run_len + 1))
    else
      if (( run_len > best_len )); then
        best_start="${run_start}"
        best_len="${run_len}"
      fi
      run_len=0
    fi
  done
  if (( best_len >= 2 )); then
    [[ "${compressed}" -eq 1 \
        && "${#left_parts[@]}" -eq "${best_start}" \
        && "${missing}" -eq "${best_len}" ]]
  else
    [[ "${compressed}" -eq 0 ]]
  fi
}

# Browser URL serialization normalizes scheme/host case, default ports, and
# path dot segments. Frozen route proof accepts only an already-canonical
# HTTP(S) spelling so a constructible runtime observation can match it exactly.
_verification_url_is_canonical() {
  local url="${1:-}" scheme="" rest="" authority="" suffix=""
  local host="" port="" path="" scan="" code="" segment="" label=""
  local lower_authority="" colon_bytes="" has_port=0
  local ipv4_component="" ipv6_address="" authority_tail="" is_ipv6=0
  local -a labels=() segments=()
  case "${url}" in
    http://*) scheme="http"; rest="${url#http://}" ;;
    https://*) scheme="https"; rest="${url#https://}" ;;
    *) return 1 ;;
  esac
  if printf '%s' "${url}" | LC_ALL=C grep -q '[^ -~]'; then
    return 1
  fi
  case "${url}" in *['"<>^`{}']*) return 1 ;; esac
  [[ "${rest}" == */* ]] || return 1
  authority="${rest%%/*}"
  suffix="/${rest#*/}"
  [[ -n "${authority}" && "${authority}" != *'@'* ]] || return 1
  lower_authority="$(printf '%s' "${authority}" \
    | tr '[:upper:]' '[:lower:]')"
  [[ "${authority}" == "${lower_authority}" ]] || return 1
  if [[ "${authority}" == '['* ]]; then
    [[ "${authority}" == *']'* ]] || return 1
    ipv6_address="${authority#\[}"
    ipv6_address="${ipv6_address%%\]*}"
    authority_tail="${authority#*\]}"
    [[ -z "${authority_tail}" || "${authority_tail}" == :* ]] || return 1
    _verification_ipv6_is_canonical "${ipv6_address}" || return 1
    host="[${ipv6_address}]"
    is_ipv6=1
    if [[ -n "${authority_tail}" ]]; then
      has_port=1
      port="${authority_tail#:}"
    fi
  else
    [[ "${authority}" != *'['* && "${authority}" != *']'* ]] || return 1
    colon_bytes="$(printf '%s' "${authority}" | tr -cd ':' | wc -c \
      | tr -d '[:space:]')"
    [[ "${colon_bytes}" =~ ^[01]$ ]] || return 1
    host="${authority}"
    if [[ "${authority}" == *:* ]]; then
      has_port=1
      host="${authority%:*}"
      port="${authority##*:}"
    fi
  fi
  if [[ "${has_port}" -eq 1 ]]; then
    [[ ${#port} -le 5 && "${port}" =~ ^[1-9][0-9]*$ \
        && "${port}" -le 65535 ]] || return 1
    if [[ ( "${scheme}" == "http" && "${port}" == "80" ) \
        || ( "${scheme}" == "https" && "${port}" == "443" ) ]]; then
      return 1
    fi
  fi
  [[ -n "${host}" ]] || return 1
  if [[ "${is_ipv6}" -eq 0 ]]; then
    [[ "${host}" != .* && "${host}" != *. \
        && "${host}" != *'..'* ]] || return 1
    IFS='.' read -r -a labels <<<"${host}"
  fi
  if [[ "${is_ipv6}" -eq 0 && "${host}" =~ ^[0-9.]+$ ]]; then
    [[ "${#labels[@]}" -eq 4 ]] || return 1
    for ipv4_component in "${labels[@]}"; do
      [[ ${#ipv4_component} -le 3 \
          && ( "${ipv4_component}" == "0" \
          || "${ipv4_component}" =~ ^[1-9][0-9]*$ ) ]] || return 1
      [[ "${ipv4_component}" -le 255 ]] || return 1
    done
  elif [[ "${is_ipv6}" -eq 0 && ( "${host}" =~ ^0[xX] \
      || "${labels[$((${#labels[@]} - 1))]}" =~ ^[0-9]+$ ) ]]; then
    # WHATWG treats alternate integer/hex or numeric-final-label spellings as
    # IPv4 and serializes different bytes. Admit only canonical dotted decimal.
    return 1
  fi
  if [[ "${is_ipv6}" -eq 0 ]]; then
    for label in "${labels[@]}"; do
      [[ ${#label} -le 63 \
          && "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
  fi
  [[ "${suffix}" != *' '* && "${suffix}" != *'\\'* ]] || return 1
  scan="${suffix}"
  while [[ "${scan}" == *%* ]]; do
    scan="${scan#*%}"
    [[ ${#scan} -ge 2 ]] || return 1
    code="${scan:0:2}"
    [[ "${code}" =~ ^[0-9A-F][0-9A-F]$ ]] || return 1
    scan="${scan:2}"
  done
  path="$(printf '%s' "${suffix}" | sed -E 's/[?#].*$//')"
  IFS='/' read -r -a segments <<<"${path}"
  for segment in "${segments[@]}"; do
    case "${segment}" in
      '.'|'..'|'%2E'|'.%2E'|'%2E.'|'%2E%2E') return 1 ;;
    esac
  done
  return 0
}

# Remove lines that describe absence, configuration, stale/cached output, or
# an explicit failure rather than a current specialized observation. Keep this
# line-oriented so a later concrete retry result can supersede an earlier
# diagnostic without the diagnostic donating its incidental units/counts.
_verification_specialized_observation_lines() {
  local output="${1:-}" kind="${2:-}" nouns="" negative="" line=""
  local retained="" diagnostic_pattern="" diagnostic_line=""
  negative='missing|unavailable|skipped|failed([[:space:]]+to)?|disabled|dry[ -]?run|cached|reused|planned([ -]only)?|pending|config(ured|uration)?|timed?[ -]?out|exceeded([[:space:]]+(budget|limit|threshold))?|not[[:space:]]+(run|produced|created|written|saved|executed|available)'
  case "${kind}" in
    benchmark) nouns='benchmarks?|benchmarking' ;;
    comparison) nouns='comparisons?|comparing|baseline|candidate|delta' ;;
    render) nouns='renders?|rendering|snapshots?|screenshots?|artifacts?|images?' ;;
    *) return 1 ;;
  esac
  diagnostic_pattern="(${nouns}).*(${negative})|(^|[^[:alnum:]_])(${negative})([^[:alnum:]_]|$).*(${nouns})|no[[:space:]]+(${nouns})"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Zero failure/skip counts are result metadata, not diagnostics. Normalize
    # both count-first ("0 failed") and label-first ("failures: 0") forms
    # before scanning for negative words. Nonzero failures are already handled
    # by the ordered failure parser.
    diagnostic_line="$(printf '%s' "${line}" | sed -E \
      -e 's/(^|[^0-9])0[[:space:]]+skipped([^[:alnum:]_]|$)/\1\2/g' \
      -e 's/skipped[[:space:]]*:[[:space:]]*0([^0-9]|$)/\1/g' \
      -e 's/(^|[^0-9])0[[:space:]]+fail(ed|ures?)([^[:alnum:]_]|$)/\1\3/g' \
      -e 's/fail(ed|ures?)[[:space:]]*[:=][[:space:]]*0([^0-9]|$)/\2/g')"
    if printf '%s' "${diagnostic_line}" | grep -Eiq "${diagnostic_pattern}" \
        || verification_output_reports_failure "${line}"; then
      # A later failed/unavailable attempt supersedes earlier partial output.
      # Clearing rather than globally filtering also permits the inverse:
      # a later concrete retry can become the current decisive observation.
      retained=""
      continue
    fi
    retained="${retained}${line}"$'\n'
  done <<<"${output}"
  printf '%s' "${retained%$'\n'}"
}

# A successful process can still make no empirical observation (`pytest --co`,
# a non-matching `go test -run`, an empty benchmark, or an all-skipped Jest
# suite). Definition evidence must not turn that absence into a pass. The
# optional kind selects evidence-specific zero signals; test remains the
# default for compatibility with existing callers.
verification_output_reports_zero_execution() {
  local output="${1:-}" kind="${2:-test}" lower="" observed=""
  local total=0 passed=0 failed=0 errors=0 skipped=0 line=""
  local saw_summary=0 executed_summary=0
  [[ -n "${output}" ]] || return 1
  lower="$(printf '%s' "${output}" | tr '[:upper:]' '[:lower:]')"

  case "${kind}" in
    benchmark)
      observed="$(_verification_specialized_observation_lines \
        "${lower}" benchmark)"
      if printf '%s' "${observed}" | grep -Eiq \
          'benchmark[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]+tests?([^[:alnum:]_]|$)' \
          || { printf '%s' "${observed}" | grep -Eiq \
              '^[[:space:]]*benchmark[[:space:]]+[1-9][0-9]*:' \
            && printf '%s' "${observed}" | grep -Eiq \
              'time[[:space:]]*\((mean|median).*[1-9][0-9]*([.][0-9]+)?[[:space:]]*(ns|us|ms|s)|[1-9][0-9]*([.][0-9]+)?[[:space:]]*(ns/op|ops/s|req/s|requests/s|iterations/s)'; } \
          || printf '%s' "${observed}" | grep -Eiq \
            '(^|[^0-9])[1-9][0-9]*[[:space:]]+benchmarks?([^[:alnum:]_]|$)|benchmarks?[[:space:]]*:[[:space:]]*[1-9][0-9]*([^0-9]|$)|(benchmark|hyperfine|latency|throughput).*(time[[:space:]]*\((mean|median)|[1-9][0-9]*([.][0-9]+)?[[:space:]]*(ns/op|ns|us|ms|s|ops/s|req/s|requests/s|iterations/s))'; then
        return 1
      fi
      [[ "${observed}" == "${lower}" ]] || return 0
      printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])0[[:space:]]+benchmarks?([^[:alnum:]_]|$)|benchmarks?[[:space:]]*:[[:space:]]*0([^0-9]|$)|no[[:space:]]+benchmarks?[[:space:]]+(were[[:space:]]+)?(run|executed|found|matched)'
      return
      ;;
    comparison)
      observed="$(_verification_specialized_observation_lines \
        "${lower}" comparison)"
      if printf '%s' "${observed}" | grep -Eiq \
          '(^|[^0-9])[1-9][0-9]*[[:space:]]+comparisons?([^[:alnum:]_]|$)|comparisons?[[:space:]]*:[[:space:]]*[1-9][0-9]*([^0-9]|$)|(compare|comparison|diff|difference).*[1-9][0-9]*([.][0-9]+)?[[:space:]]*(matched|changed|differences?)|delta.*[1-9][0-9]*([.][0-9]+)?[[:space:]]*(%|percent|ms|s)|(baseline.*candidate|before.*after).*delta'; then
        return 1
      fi
      [[ "${observed}" == "${lower}" ]] || return 0
      printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])0[[:space:]]+comparisons?([^[:alnum:]_]|$)|comparisons?[[:space:]]*:[[:space:]]*0([^0-9]|$)|no[[:space:]]+comparisons?[[:space:]]+(were[[:space:]]+)?(run|executed|found|matched)'
      return
      ;;
    render)
      observed="$(_verification_specialized_observation_lines \
        "${lower}" render)"
      if printf '%s' "${observed}" | grep -Eiq \
          '(^|[^0-9])[1-9][0-9]*[[:space:]]+(renders?|rendered[[:space:]]+(frames?|pages?|images?)|snapshots?|screenshots?)([^[:alnum:]_]|$)|(renders?|snapshots?|screenshots?)[[:space:]]*:[[:space:]]*[1-9][0-9]*([^0-9]|$)|(render|rendered|snapshot|screenshot|visual).*([1-9][0-9]*([.][0-9]+)?[[:space:]]*(pages?|frames?|images?|px)|artifact|digest|sha(256)?|[^[:space:]]+[.](png|jpe?g|webp|pdf|svg))'; then
        return 1
      fi
      [[ "${observed}" == "${lower}" ]] || return 0
      printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])0[[:space:]]+(renders?|rendered|snapshots?)([^[:alnum:]_]|$)|(renders?|snapshots?)[[:space:]]*:[[:space:]]*0([^0-9]|$)|no[[:space:]]+(renders?|snapshots?)[[:space:]]+(were[[:space:]]+)?(produced|created|found)'
      return
      ;;
    inspection)
      if printf '%s' "${lower}" | grep -Eiq \
          '(^|[^0-9])[1-9][0-9]*[[:space:]]+(files?[[:space:]]+(checked|inspected)|checks?|matches?)([^[:alnum:]_]|$)'; then
        return 1
      fi
      printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])0[[:space:]]+(files?[[:space:]]+(checked|inspected)|checks?|matches?)([^[:alnum:]_]|$)|no[[:space:]]+(files?|checks?|matches?)[[:space:]]+(were[[:space:]]+)?(checked|inspected|found)'
      return
      ;;
  esac

  # Aggregate repeated module summaries line by line. A cross-line `.*`
  # regex can pair one module's total with another module's skipped count. The
  # aggregate must run before broad zero detection: Maven and RSpec suites often
  # contain empty/all-pending modules beside modules that really executed.
  while IFS= read -r line; do
    if [[ "${line}" =~ tests[[:space:]]+run:[[:space:]]*([0-9]+).*failures:[[:space:]]*([0-9]+).*errors:[[:space:]]*([0-9]+).*skipped:[[:space:]]*([0-9]+) ]]; then
      total="${BASH_REMATCH[1]}"
      failed="${BASH_REMATCH[2]}"
      errors="${BASH_REMATCH[3]}"
      skipped="${BASH_REMATCH[4]}"
      passed=$((total - failed - errors - skipped))
      [[ "${passed}" -lt 0 ]] && passed=0
    elif [[ "${line}" =~ total[[:space:]]+tests:[[:space:]]*([0-9]+).*passed:[[:space:]]*([0-9]+).*failed:[[:space:]]*([0-9]+).*skipped:[[:space:]]*([0-9]+) ]]; then
      total="${BASH_REMATCH[1]}"
      passed="${BASH_REMATCH[2]}"
      failed="${BASH_REMATCH[3]}"
      errors=0
      skipped="${BASH_REMATCH[4]}"
    elif [[ "${line}" =~ ([0-9]+)[[:space:]]+examples?,[[:space:]]*([0-9]+)[[:space:]]+failures?,[[:space:]]*([0-9]+)[[:space:]]+pending ]]; then
      total="${BASH_REMATCH[1]}"
      failed="${BASH_REMATCH[2]}"
      errors=0
      skipped="${BASH_REMATCH[3]}"
      passed=$((total - failed - skipped))
      [[ "${passed}" -lt 0 ]] && passed=0
    else
      continue
    fi
    saw_summary=1
    if [[ "${total}" -gt 0 ]] \
        && { [[ "${passed}" -gt 0 ]] || [[ "${failed}" -gt 0 ]] \
          || [[ "${errors}" -gt 0 ]] || [[ "${skipped}" -lt "${total}" ]]; }; then
      executed_summary=1
    fi
  done <<<"${lower}"
  if [[ "${saw_summary}" -eq 1 ]]; then
    [[ "${executed_summary}" -eq 1 ]] && return 1
    # Empty Maven/RSpec modules can coexist with a concrete result from a
    # different runner or custom check. Do not let the first recognized zero
    # summary short-circuit a later nonzero execution count.
    if printf '%s' "${lower}" | grep -Eiq \
        '(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|failed|errors?|ok)([^[:alnum:]_]|$)|(passed|failed|errors?)[[:space:]:=]+[1-9][0-9]*([^0-9]|$)|(^|[^0-9])[1-9][0-9]*[[:space:]]+(checks?|specs?)[[:space:]]+(passed|failed|executed|run)([^[:alnum:]_]|$)|running[[:space:]]+[1-9][0-9]*[[:space:]]+tests?'; then
      return 1
    fi
    return 0
  fi

  # A concrete custom check/spec observation dominates an empty sibling just
  # like a framework pass does. Evaluate it before terse all-skipped prose.
  if printf '%s' "${lower}" | grep -Eiq \
      '^[[:space:]=_-]*[1-9][0-9]*[[:space:]]+(checks?|specs?)[[:space:]]+(passed|failed|executed|run)([^[:alnum:]_]|$)'; then
    return 1
  fi

  # All-skipped summaries have non-zero totals but still no observation.
  # Evaluate these before generic suite-pass prose because Jest can report a
  # passing suite count while every individual test is skipped.
  if printf '%s' "${lower}" | grep -Eiq \
      'tests:.*[1-9][0-9]*[[:space:]]+(skipped|todo).*[1-9][0-9]*[[:space:]]+total' \
      && ! printf '%s' "${lower}" | grep -Eiq \
        'tests:.*[1-9][0-9]*[[:space:]]+(passed|failed)'; then
    return 0
  fi
  if printf '%s' "${lower}" | grep -Eiq \
      '(^|[[:space:];])[1-9][0-9]*[[:space:]]+skipped[[:space:]]+in([[:space:]]|$)' \
      && ! printf '%s' "${lower}" | grep -Eiq \
        '(^|[[:space:];])[1-9][0-9]*[[:space:]]+(passed|failed|errors?)([[:space:];,]|$)'; then
    return 0
  fi
  # Named project checks often use terse skip summaries rather than framework
  # counters. Once structured mixed-run summaries above have found no concrete
  # execution, an all/numbered check skip or standalone SKIP line is absence,
  # not a green empirical observation.
  if printf '%s' "${lower}" | grep -Eiq \
      '(^|[[:space:];])(all[[:space:]]+(checks?|specs?)[[:space:]]+skipped|[1-9][0-9]*[[:space:]]+(checks?|specs?)[[:space:]]+skipped)([[:space:];,.]|$)|(^|[[:space:]])skip(ped)?[[:space:]]*:' \
      && ! printf '%s' "${lower}" | grep -Eiq \
        '(^|[[:space:];])[1-9][0-9]*[[:space:]]+(passed|passing|failed|failures?|errors?)([[:space:];,]|$)'; then
    return 0
  fi

  # A concrete execution in a mixed run dominates empty sibling targets.
  # Keep line-leading counts narrower than arbitrary `setup: 1 passed` prose so
  # collection-only setup chatter cannot manufacture execution.
  if printf '%s' "${lower}" | grep -Eiq \
      '^[[:space:]=_-]*[1-9][0-9]*[[:space:]]+(passed|passing|failed|failures?|errors?)([^[:alnum:]_]|$)|^[[:space:]=_-]*[1-9][0-9]*[[:space:]]+(checks?|specs?)[[:space:]]+(passed|failed|executed|run)([^[:alnum:]_]|$)|test[[:space:]]+result:.*(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|failed)([^[:alnum:]_]|$)|tests?:.*(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|failed)([^[:alnum:]_]|$)|passed:[[:space:]]*[1-9][0-9]*|^[[:space:]]*ok[[:space:]]+[^[:space:]]+'; then
    return 1
  fi

  # Pytest collection-only mode reports a non-zero collected count and exits
  # successfully. Normal execution emits the same collection line followed by
  # a concrete passed/failed summary handled above, so a surviving collection
  # summary here is explicit zero execution (including config-injected
  # collect-only modes that have no revealing CLI flag).
  if printf '%s' "${lower}" | grep -Eiq \
      'collected[[:space:]]+[1-9][0-9]*[[:space:]]+(items?|tests?)'; then
    return 0
  fi

  # Explicit zero-suite summaries dominate incidental setup/build prose such
  # as `setup: 1 passed; collected 0 items`, but only after mixed structured
  # summaries and concrete framework observations have been considered.
  if printf '%s' "${lower}" | grep -Eiq \
      '(^|[^0-9])0[[:space:]]+(tests?|passed|passing|specs?|checks?|assertions?|examples?|selected)([^[:alnum:]_]|$)|tests?((:[[:space:]]*)|[[:space:]]+)0([^0-9]|$)|tests[[:space:]]+run:[[:space:]]*0([^0-9]|$)|collected[[:space:]]+0[[:space:]]+(items?|tests?)|running[[:space:]]+0[[:space:]]+(tests?|specs?|checks?)|no[[:space:]]+(tests?|specs?|checks?)[[:space:]]+((were[[:space:]]+)?(found|executed|collected|matched|run)|to[[:space:]]+run|ran|run)|warning:[[:space:]]+no[[:space:]]+tests?[[:space:]]+to[[:space:]]+run|(^|[[:space:]])1[.][.]0([[:space:]]*#[[:space:]]*skip[^[:space:]]*)?([[:space:]]|$)'; then
    return 0
  fi

  # Pytest reports deselected items alongside actually executed items. A
  # non-zero deselected count is absence only when the same output contains no
  # positive or negative execution count.
  if printf '%s' "${output}" | grep -Eiq \
      '(^|[^0-9])[1-9][0-9]*[[:space:]]+(passed|passing|failed|failures?|errors?)([^[:alnum:]_]|$)'; then
    return 1
  fi
  if printf '%s' "${lower}" | grep -Eiq \
      '(^|[^0-9])[1-9][0-9]*[[:space:]]+deselected([[:space:]]|$)'; then
    return 0
  fi

  printf '%s' "${lower}" | grep -Eiq \
    '\[no[[:space:]]+test[[:space:]]+files\]|(^|[[:space:]:])[^[:space:]]*test[^[:space:]]*[[:space:]]+(no-source|skipped|up-to-date)([[:space:]]|$)|(tests?|specs?|checks?)[[:space:]]+(are|were)[[:space:]]+skipped'
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
#   - Output indicates an outcome, or an authoritative verifier completed: +10
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

  # Factor 4: a clear result signal, or a hook-observed authoritative argv
  # whose process completion itself is meaningful (clean ShellCheck and
  # `bash -n` are intentionally silent). The receipt stores pass/fail
  # independently; this factor measures execution authority, not success.
  if verification_output_has_clear_outcome "${output}" \
      || verification_command_is_authoritative_execution \
        "${cmd}" "${project_test_cmd}" 2>/dev/null; then
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
    if verification_output_has_clear_outcome "${output}" \
        || verification_command_is_authoritative_execution \
          "${cmd}" "${project_test_cmd}" 2>/dev/null; then
      f4=10
    fi
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
    local custom_mcp_tools="${OMC_CUSTOM_VERIFY_MCP_TOOLS}" pattern=""
    local -a custom_mcp_patterns=()
    # custom_verify_mcp_tools is a pipe-separated list of glob patterns
    # whose glob syntax belongs only to the case matcher. An unquoted `for`
    # expansion first globbed against cwd filenames, so a coincidentally named
    # repo file could corrupt the configured verification authority.
    IFS='|' read -ra custom_mcp_patterns <<< "${custom_mcp_tools}"
    for pattern in "${custom_mcp_patterns[@]}"; do
      [[ -n "${pattern}" ]] || continue
      # shellcheck disable=SC2254
      case "${tool_name}" in ${pattern}) printf 'custom_mcp_tool'; return 0 ;; esac
    done
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

  # No hook-observed result is not an observation. Empty structured values
  # arrive as `[]`/`{}` and remain meaningful for console/network checks; an
  # actually absent/empty response fails closed.
  [[ -n "${output}" ]] || { printf 'failed'; return; }

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
  local tool_name="${1:-}" tool_input_json="${2:-}" lower operation=""
  local tool_operation="" graphql_document="" sql_document="" query_document=""
  [[ -n "${tool_input_json}" ]] || tool_input_json='{}'
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
    sql_document="$(jq -r \
      '[.sql?,.statement?,.query_text?,.queryText?]
       | map(select(type == "string" and length > 0)) | .[0] // empty' \
      <<<"${tool_input_json}" 2>/dev/null || true)"
    query_document="$(jq -r '.query? // empty
      | if type == "string" then . else empty end' \
      <<<"${tool_input_json}" 2>/dev/null || true)"
  fi
  tool_operation="${lower##*__}"

  # A connector that persists its observation mutates an artifact regardless
  # of the read-like operation name. These destination keys recur across
  # browser, filesystem, export, and document connectors.
  if jq -e '
      [.. | objects |
       (.output_file? // .outputFile? // .output_path? // .outputPath?
         // .save_path? // .savePath? // .destination_file?
         // .destinationFile? // empty)
       | select(type == "string" and length > 0)]
      | length > 0
    ' <<<"${tool_input_json}" >/dev/null 2>&1; then
    return 0
  fi

  # Several Playwright observations can optionally persist their result. That
  # file write is an artifact mutation even though the browser operation is
  # labelled read-only by the connector. It must advance edit generations and
  # may not mint a verification receipt in the same call.
  case "${tool_operation}" in
    browser_snapshot|browser_take_screenshot|browser_console_messages|browser_network_requests)
      if jq -e '
          (.filename? // empty)
          | type == "string" and length > 0
        ' <<<"${tool_input_json}" >/dev/null 2>&1; then
        return 0
      fi
      ;;
  esac

  # GraphQL hides its mutation verb inside the document rather than the tool
  # name. Inspect only the operation prefix, not arbitrary prose/content.
  if [[ "${lower}" == *graphql* ]] \
      && grep -Eiq '^[[:space:]]*mutation([[:space:]({]|$)' \
        <<<"${graphql_document}"; then
    return 0
  fi

  # Aggregator tools commonly put the observation verb in `method` and the
  # object noun after it (`get_diff`, `get_comments`). Admit that shape, while
  # any unambiguous action token still wins. Suffix `_read` tools such as
  # `pull_request_read` use the same rule below.
  if [[ -n "${operation}" ]]; then
    if ! grep -Eq '^(read|get|head|options|list|search|find|query|fetch|inspect|stat|status|schema|describe|metadata|preview|validate|verify|check|snapshot|screenshot)(_[a-z0-9]+)*$' \
        <<<"${operation}" \
        || grep -Eiq '(^|_)(create|update|edit|write|delete|remove|archive|restore|move|copy|rename|append|insert|replace|format|clear|upload|download|export|sync|publish|send|reply|share|grant|revoke|permission|batch|set|add|import|apply|submit|fix|save|upsert|ensure|click|type|fill|select|press|drag|drop|navigate|goto|evaluate|execute|run|code|call|post|put|patch)(_|$)' \
          <<<"${operation}"; then
      return 0
    fi
  fi

  # A generic database query cannot be proven read-only from SQL text alone:
  # SELECT may invoke mutating functions or write files, and dialect-specific
  # PRAGMA/ATTACH/EXPLAIN forms expand the parser indefinitely. Fail closed for
  # explicit SQL fields and SQL-shaped overloaded query values. Server-enforced
  # read-only connectors can expose a dedicated observational operation name.
  if [[ "${lower}" != *graphql* ]]; then
    if [[ "${tool_operation}" == query* ]] \
        && grep -Eiq '__(postgres|postgresql|mysql|mariadb|sqlite|sql|database|db|snowflake|bigquery|redshift|clickhouse|duckdb)__' \
          <<<"${lower}"; then
      return 0
    fi
    if [[ -z "${sql_document}" ]] \
        && grep -Eiq '^[[:space:]]*(select|show|describe|desc|explain|with|insert|update|delete|merge|replace|create|alter|drop|truncate|grant|revoke|call|execute|do|copy|vacuum|analyze|refresh|reindex|cluster|comment|pragma|attach|detach)([[:space:](]|$)' \
          <<<"${query_document}"; then
      sql_document="${query_document}"
    fi
    if [[ -n "${sql_document}" ]]; then
      return 0
    fi
  fi

  # Leading reader verbs describe an observation. Nouns such as `comment`,
  # `commit`, `request`, and `open_issue` remain object names in
  # get_comment/get_commit/get_pull_request/get_open_issue. Only an explicit
  # chained action can turn a reader operation into a write.
  case "${tool_operation}" in
    snapshot|snapshot_*|screenshot|screenshot_*|browser_snapshot|browser_take_screenshot|browser_console_messages|browser_network_requests|console_messages|network_requests|read|read_*|*_read|get|get_*|list|list_*|search|search_*|find|find_*|query|query_*|fetch|fetch_*|inspect|inspect_*|stat|stat_*|status|status_*|schema|schema_*|describe|describe_*|metadata|metadata_*|preview|preview_*|validate|validate_*|verify|verify_*|check|check_*)
      if grep -Eiq '(^|_)(create|update|edit|write|delete|remove|archive|restore|move|copy|rename|append|insert|replace|format|clear|upload|download|export|sync|publish|send|reply|share|grant|revoke|permission|batch|set|add|import|apply|submit|fix|save|upsert|ensure|click|type|fill|select|press|drag|drop|navigate|goto|evaluate|execute|run|code|call|post|put|patch)(_|$)' \
          <<<"${tool_operation}"; then
        return 0
      fi
      return 1
      ;;
  esac

  # Unknown terminal operations remain fail-closed. Scan only that operation,
  # not provider/plugin namespace nouns, before applying the default.
  if grep -Eiq '(^|_)(create|update|edit|write|delete|remove|archive|restore|move|copy|rename|append|insert|replace|format|clear|upload|download|export|sync|publish|send|reply|comment|share|grant|revoke|permission|batch|set|add|import|apply|submit|commit|click|type|fill|select|press|drag|drop|navigate|open|goto|evaluate|execute|run|code|request|call|post|put|patch)(_|$)' \
      <<<"${tool_operation}"; then
    return 0
  fi
  return 0
}

# Enter POSIX lookup before relying on any ordinary Bash builtin. In POSIX
# mode the special `unset` builtin outranks a same-named function, so it can
# remove every ordinary builtin/function name used by the SHA authority path.
# A readonly hostile function makes unset fail and therefore fails authority
# closed. Keep callers in a subshell: assigning a readonly POSIXLY_CORRECT is
# itself a hard shell error and must terminate only the authority attempt.
function _verification_sanitize_sha256_shell () {
  POSIXLY_CORRECT=1 || \return 1
  \unset -f builtin command printf read local type declare unset cd pwd \
    return shasum sha256sum readlink || \return 1
}

# Resolve one exact SHA-256 executable without consulting shell functions,
# aliases, builtins, or a writable package-manager prefix. The observer PATH
# is still the portability allowlist, but only canonical OS bins and immutable
# Nix store bins may supply authority. This deliberately excludes
# /usr/local/bin and /opt/homebrew/bin even though generic observers may use
# them; macOS supplies /usr/bin/shasum and mainstream Linux/Nix supplies a
# system/store sha256sum.
function _verification_trusted_sha256_executable () (
  \_verification_sanitize_sha256_shell || \return 1
  \local safe_path="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  \local old_ifs="${IFS}" directory="" canonical="" name="" candidate=""
  \local reader="" resolved=""
  [[ -n "${safe_path}" && "${safe_path}" != *$'\n'* \
      && "${safe_path}" != *$'\r'* ]] || \return 1
  for name in shasum sha256sum; do
    IFS=':'
    for directory in ${safe_path}; do
      IFS="${old_ifs}"
      [[ -n "${directory}" && "${directory}" == /* \
          && "${directory}" != *[[:cntrl:]]* ]] || continue
      canonical="$(\builtin cd -- "${directory}" 2>/dev/null \
        && \builtin pwd -P)" || continue
      case "${canonical}" in
        /usr/bin|/bin|/usr/sbin|/sbin|/nix/store/*/bin) ;;
        *) continue ;;
      esac
      candidate="${canonical%/}/${name}"
      [[ -f "${candidate}" && -x "${candidate}" ]] || continue
      if [[ -L "${candidate}" ]]; then
        case "${candidate}" in /nix/store/*/bin/*) ;; *) continue ;; esac
        resolved=""
        # Nix bin outputs commonly use immutable symlinks. Resolve the leaf
        # with an exact system/store readlink and admit it only when the final
        # executable remains an ordinary immutable Nix-store file.
        for reader in /usr/bin/readlink /bin/readlink \
            "${canonical%/}/readlink"; do
          [[ -x "${reader}" ]] || continue
          resolved="$(\builtin command -- "${reader}" -f -- \
            "${candidate}" 2>/dev/null)" || resolved=""
          case "${resolved}" in /nix/store/*) ;; *) resolved="" ;; esac
          [[ -n "${resolved}" && -f "${resolved}" \
              && -x "${resolved}" && ! -L "${resolved}" ]] && break
          resolved=""
        done
        [[ -n "${resolved}" ]] || continue
        \builtin printf '%s' "${candidate}"
        IFS="${old_ifs}"
        \return 0
      fi
      [[ ! -L "${candidate}" ]] || continue
      \builtin printf '%s' "${candidate}"
      IFS="${old_ifs}"
      \return 0
    done
    IFS="${old_ifs}"
  done
  IFS="${old_ifs}"
  \return 1
)

function _verification_sha256_output_digest () (
  \_verification_sanitize_sha256_shell || \return 1
  \local output="${1:-}" digest="" remainder=""
  [[ -n "${output}" && "${output}" != *$'\n'* \
      && "${output}" != *$'\r'* ]] || \return 1
  \builtin read -r digest remainder <<<"${output}" || \return 1
  [[ "${digest}" =~ ^[0-9a-f]{64}$ && -n "${remainder}" ]] || \return 1
  \builtin printf '%s' "${digest}"
)

# Return a digest only from the exact trusted executable above. For MCP image
# callers, a path or success sentence remains transport metadata, not pixels.
function _verification_sha256_text () (
  \_verification_sanitize_sha256_shell || \return 1
  \local text="${1:-}" hasher="" output=""
  hasher="$(\_verification_trusted_sha256_executable)" || \return 1
  case "${hasher##*/}" in
    shasum)
      output="$(\builtin printf '%s' "${text}" \
        | \builtin command -- "${hasher}" -a 256 2>/dev/null)" || \return 1
      ;;
    sha256sum)
      output="$(\builtin printf '%s' "${text}" \
        | \builtin command -- "${hasher}" 2>/dev/null)" || \return 1
      ;;
    *) \return 1 ;;
  esac
  \_verification_sha256_output_digest "${output}"
)

# Authority identities keep the established 24-hex wire format, but unlike
# generic telemetry tokens they must never fall back to cksum. A weak or
# differently formatted fallback could make a Definition, receipt, proof, or
# one-shot causal snapshot collide across distinct authoritative inputs.
function _omc_authority_digest () (
  \_verification_sanitize_sha256_shell || \return 1
  \local authority_sha=""
  authority_sha="$(\_verification_sha256_text \
    "${1:-}" 2>/dev/null)" || \return 1
  [[ "${authority_sha}" =~ ^[0-9a-f]{64}$ ]] || \return 1
  \builtin printf '%.24s' "${authority_sha}"
)

function _verification_sha256_file () (
  \_verification_sanitize_sha256_shell || \return 1
  \local path="${1:-}" hasher="" output=""
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || \return 1
  hasher="$(\_verification_trusted_sha256_executable)" || \return 1
  case "${hasher##*/}" in
    shasum)
      output="$(\builtin command -- "${hasher}" -a 256 \
        "${path}" 2>/dev/null)" || \return 1
      ;;
    sha256sum)
      output="$(\builtin command -- "${hasher}" \
        "${path}" 2>/dev/null)" || \return 1
      ;;
    *) \return 1 ;;
  esac
  \_verification_sha256_output_digest "${output}"
)

# These six functions form one authority boundary. Once common.sh has loaded
# them, later BASH_ENV code or a sourced helper must not be able to replace one
# link while leaving the other five apparently trusted. Ordinary common.sh
# re-sourcing remains idempotent because its guard returns before this library;
# a direct attempt to reload this file fails closed at the unset block above.
# BEGIN OMC_SHA_AUTHORITY_SOURCE_SEAL
\builtin readonly -f \
  _verification_sanitize_sha256_shell \
  _verification_trusted_sha256_executable \
  _verification_sha256_output_digest \
  _verification_sha256_text \
  _omc_authority_digest \
  _verification_sha256_file || \return 1
# END OMC_SHA_AUTHORITY_SOURCE_SEAL

# Filesystem identity used beside a content digest. Digest equality alone
# cannot detect an A -> B -> A replacement during a tool interval. The leaf
# tuple catches overwrite/restore and direct rename-back. The strict ancestry
# digest includes directory ctime so exact PreTool/PostTool comparison catches
# a restored ancestor-directory swap. The stable ancestry digest uses only
# device/inode pairs so a later settled-state review does not invalidate every
# sibling receipt merely because another file changed the directory ctime.
# The optional anchor is normally the exact tool cwd and bounds both chains.
_verification_file_identity() {
  local path="${1:-}" anchor="${2:-}" identity="" directory_identity=""
  local stable_directory_identity="" parent="" current="" relative=""
  local component="" ancestry="" stable_ancestry="" ancestry_digest=""
  local stable_ancestry_digest="" result=""
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || return 1
  identity="$(stat -f 'bsd:%d:%i:%z:%Fm:%Fc' "${path}" \
    2>/dev/null || true)"
  if [[ ! "${identity}" =~ ^bsd:[0-9]+:[0-9]+:[0-9]+:[0-9]+\.[0-9]+:[0-9]+\.[0-9]+$ ]]; then
    identity="$(stat -c 'gnu:%d:%i:%s:%y:%z' "${path}" \
      2>/dev/null || true)"
  fi
  [[ -n "${identity}" && ${#identity} -le 256 ]] || return 1
  [[ "$(LC_ALL=C printf '%s' "${identity}" \
    | LC_ALL=C tr -d '\001-\037\177')" == "${identity}" ]] || return 1
  parent="${path%/*}"
  [[ "${parent}" != "${path}" ]] || parent="."
  if [[ -n "${anchor}" && -d "${anchor}" && ! -L "${anchor}" ]]; then
    anchor="$(_verification_normalize_proof_path \
      "${anchor}" 0 content 2>/dev/null || true)"
    [[ -n "${anchor}" ]] || return 1
  else
    anchor=""
  fi
  if [[ -n "${anchor}" ]]; then
    case "${parent}" in
      "${anchor}"|"${anchor}"/*) current="${anchor}" ;;
      *) current="${parent}"; anchor="" ;;
    esac
  else
    current="${parent}"
  fi
  while :; do
    directory_identity="$(stat -f 'bsd:%d:%i:%Fc' "${current}" \
      2>/dev/null || true)"
    if [[ ! "${directory_identity}" =~ ^bsd:[0-9]+:[0-9]+:[0-9]+\.[0-9]+$ ]]; then
      directory_identity="$(stat -c 'gnu:%d:%i:%z' "${current}" \
        2>/dev/null || true)"
    fi
    stable_directory_identity="$(stat -f 'bsd:%d:%i' "${current}" \
      2>/dev/null || true)"
    if [[ ! "${stable_directory_identity}" =~ ^bsd:[0-9]+:[0-9]+$ ]]; then
      stable_directory_identity="$(stat -c 'gnu:%d:%i' "${current}" \
        2>/dev/null || true)"
    fi
    [[ -n "${directory_identity}" \
        && "${stable_directory_identity}" =~ ^(bsd|gnu):[0-9]+:[0-9]+$ ]] \
      || return 1
    ancestry="${ancestry}${ancestry:+$'\n'}${directory_identity}"
    stable_ancestry="${stable_ancestry}${stable_ancestry:+$'\n'}${stable_directory_identity}"
    [[ -n "${anchor}" && "${current}" != "${parent}" ]] || break
    relative="${parent#"${current}"}"
    relative="${relative#/}"
    component="${relative%%/*}"
    [[ -n "${component}" ]] || break
    current="${current%/}/${component}"
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
  done
  ancestry_digest="$(_verification_sha256_text \
    "${ancestry}" 2>/dev/null || true)"
  stable_ancestry_digest="$(_verification_sha256_text \
    "${stable_ancestry}" 2>/dev/null || true)"
  [[ "${ancestry_digest}" =~ ^[0-9a-f]{64}$ \
      && "${stable_ancestry_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  result="v3:${identity}:a:${ancestry_digest}:s:${stable_ancestry_digest}"
  [[ ${#result} -le 512 ]] || return 1
  printf '%s' "${result}"
}

# A proof interval compares the complete identity above byte-for-byte. A later
# reviewer instead needs durable settled-state equivalence: unchanged leaf
# identity plus unchanged directory objects, while ignoring ctime-only sibling
# churn. Legacy v2 identities do not carry that stable projection and therefore
# remain exact-only. Unknown identity formats fail closed.
_verification_file_identity_review_matches() {
  local recorded="${1:-}" current="${2:-}"
  local recorded_leaf="" recorded_stable=""
  local current_leaf="" current_stable=""
  [[ -n "${recorded}" && -n "${current}" \
      && ${#recorded} -le 512 && ${#current} -le 512 ]] || return 1
  [[ "$(LC_ALL=C printf '%s' "${recorded}" \
      | LC_ALL=C tr -d '\001-\037\177')" == "${recorded}" \
      && "$(LC_ALL=C printf '%s' "${current}" \
      | LC_ALL=C tr -d '\001-\037\177')" == "${current}" ]] || return 1
  [[ "${recorded}" == "${current}" ]] && return 0
  if [[ "${recorded}" =~ ^v3:(.+):a:([0-9a-f]{64}):s:([0-9a-f]{64})$ ]]; then
    recorded_leaf="${BASH_REMATCH[1]}"
    recorded_stable="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  if [[ "${current}" =~ ^v3:(.+):a:([0-9a-f]{64}):s:([0-9a-f]{64})$ ]]; then
    current_leaf="${BASH_REMATCH[1]}"
    current_stable="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  [[ "${recorded_leaf}" == "${current_leaf}" \
      && "${recorded_stable}" == "${current_stable}" ]]
}

_verification_decode_base64_file() {
  local encoded="${1:-}" destination="${2:-}"
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -n "${encoded}" && -n "${destination}" ]] || return 1
  if printf '%s' "${encoded}" | base64 --decode >"${destination}" 2>/dev/null; then
    return 0
  fi
  : >"${destination}"
  if printf '%s' "${encoded}" | base64 -d >"${destination}" 2>/dev/null; then
    return 0
  fi
  : >"${destination}"
  if printf '%s' "${encoded}" | base64 -D >"${destination}" 2>/dev/null; then
    return 0
  fi
  : >"${destination}"
  if command -v openssl >/dev/null 2>&1 \
      && printf '%s' "${encoded}" \
        | openssl base64 -d -A >"${destination}" 2>/dev/null; then
    return 0
  fi
  : >"${destination}"
  return 1
}

verification_png_decoder_available() {
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  command -v perl >/dev/null 2>&1 || return 1
  PERL5LIB='' PERLLIB='' PERL5OPT='' \
    perl -MCompress::Raw::Zlib=Z_OK,Z_STREAM_END,Z_BUF_ERROR,crc32 \
      -e 'exit 0' >/dev/null 2>&1
}

_verification_png_file_is_structurally_valid() {
  local path="${1:-}"
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  # Header/chunk-shape checks alone are not pixel authority: forged CRCs or a
  # corrupt IDAT stream can look like a PNG without decoding to any scanline.
  # Perl and Compress::Raw::Zlib are system/core facilities on the supported
  # Unix hosts. Fail closed when they are unavailable, validate every chunk
  # CRC, inflate the complete zlib stream with a bounded output buffer, and
  # require exact PNG scanline/filter semantics (including Adam7 passes).
  verification_png_decoder_available || return 1
  PERL5LIB='' PERLLIB='' PERL5OPT='' \
    perl -MCompress::Raw::Zlib=Z_OK,Z_STREAM_END,Z_BUF_ERROR,crc32 \
      - "${path}" <<'PERL'
use strict;
use warnings;

my $path = shift @ARGV;
open my $fh, '<:raw', $path or exit 1;
local $/;
my $png = <$fh>;
close $fh or exit 1;
defined($png) && length($png) >= 57 or exit 1;
substr($png, 0, 8) eq "\x89PNG\r\n\x1a\n" or exit 1;

my ($pos, $chunks) = (8, 0);
my ($width, $height, $depth, $color, $compression, $filter, $interlace);
my ($saw_ihdr, $saw_plte, $saw_idat, $idat_ended, $saw_iend) = (0, 0, 0, 0, 0);
my $idat = '';
while ($pos < length($png)) {
  length($png) - $pos >= 12 or exit 1;
  my $len = unpack('N', substr($png, $pos, 4));
  $pos += 4;
  $len <= 52_428_800 && length($png) - $pos >= $len + 8 or exit 1;
  my $type = substr($png, $pos, 4);
  $pos += 4;
  $type =~ /^[A-Za-z]{2}[A-Z][A-Za-z]$/ or exit 1;
  my $data = substr($png, $pos, $len);
  $pos += $len;
  my $stored_crc = unpack('N', substr($png, $pos, 4));
  $pos += 4;
  (crc32($type . $data) & 0xffffffff) == $stored_crc or exit 1;
  ++$chunks;

  if ($type eq 'IHDR') {
    $chunks == 1 && !$saw_ihdr && $len == 13 or exit 1;
    ($width, $height, $depth, $color, $compression, $filter, $interlace) =
      unpack('NNCCCCC', $data);
    $width > 0 && $height > 0 && $width <= 100_000 && $height <= 100_000
      or exit 1;
    $compression == 0 && $filter == 0 && ($interlace == 0 || $interlace == 1)
      or exit 1;
    my %legal_depth = (
      0 => { map { $_ => 1 } (1, 2, 4, 8, 16) },
      2 => { 8 => 1, 16 => 1 },
      3 => { map { $_ => 1 } (1, 2, 4, 8) },
      4 => { 8 => 1, 16 => 1 },
      6 => { 8 => 1, 16 => 1 },
    );
    $legal_depth{$color} && $legal_depth{$color}{$depth} or exit 1;
    $saw_ihdr = 1;
  } elsif ($type eq 'PLTE') {
    $saw_ihdr && !$saw_plte && !$saw_idat && $len >= 3
      && $len <= 768 && $len % 3 == 0 or exit 1;
    ($color == 0 || $color == 4) and exit 1;
    $color != 3 || ($len / 3) <= (2 ** $depth) or exit 1;
    $saw_plte = 1;
  } elsif ($type eq 'IDAT') {
    $saw_ihdr && !$idat_ended && !$saw_iend or exit 1;
    $color != 3 || $saw_plte or exit 1;
    length($idat) + $len <= 52_428_800 or exit 1;
    $idat .= $data;
    $saw_idat = 1;
  } elsif ($type eq 'IEND') {
    $saw_ihdr && $saw_idat && !$saw_iend && $len == 0 or exit 1;
    $saw_iend = 1;
    $idat_ended = 1;
    $pos == length($png) or exit 1;
  } else {
    # Unknown critical chunks are not decodable under the PNG contract.
    substr($type, 0, 1) =~ /[a-z]/ or exit 1;
    $idat_ended = 1 if $saw_idat;
  }
}
$saw_ihdr && $saw_idat && $saw_iend && $pos == length($png) or exit 1;

my %channels = (0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4);
my $bits_per_pixel = $channels{$color} * $depth;
my @rows;
my $expected = 0;
if ($interlace == 0) {
  my $row_bytes = int(($width * $bits_per_pixel + 7) / 8);
  $expected = $height * ($row_bytes + 1);
  push @rows, [$height, $row_bytes];
} else {
  my @passes = (
    [0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4],
    [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2],
  );
  for my $pass (@passes) {
    my ($x0, $y0, $dx, $dy) = @{$pass};
    my $pass_width = $width <= $x0 ? 0 : int(($width - $x0 + $dx - 1) / $dx);
    my $pass_height = $height <= $y0 ? 0 : int(($height - $y0 + $dy - 1) / $dy);
    next unless $pass_width && $pass_height;
    my $row_bytes = int(($pass_width * $bits_per_pixel + 7) / 8);
    $expected += $pass_height * ($row_bytes + 1);
    push @rows, [$pass_height, $row_bytes];
  }
}
$expected > 0 && $expected <= 134_217_728 or exit 1;

my ($inflater, $status) = Compress::Raw::Zlib::Inflate->new(
  -LimitOutput => 1, -Bufsize => 65_536);
$status == Z_OK or exit 1;
my $compressed = $idat;
my $raw = '';
my $iterations = 0;
while (1) {
  my $out = '';
  $status = $inflater->inflate($compressed, $out);
  $raw .= $out;
  length($raw) <= $expected && ++$iterations <= 131_072 or exit 1;
  last if $status == Z_STREAM_END;
  ($status == Z_OK || $status == Z_BUF_ERROR) && length($out) > 0 or exit 1;
}
length($compressed) == 0 && length($raw) == $expected or exit 1;

my $raw_pos = 0;
for my $row_group (@rows) {
  my ($row_count, $row_bytes) = @{$row_group};
  for (1 .. $row_count) {
    my $filter_byte = ord(substr($raw, $raw_pos, 1));
    $filter_byte >= 0 && $filter_byte <= 4 or exit 1;
    $raw_pos += $row_bytes + 1;
  }
}
$raw_pos == length($raw) or exit 1;
exit 0;
PERL
}

mcp_verification_embedded_image_digest() {
  local hook_json="${1:-}" image_rows="" temp_dir="" decoded=""
  local mime="" data="" prefix="" size="" digest=""
  local material="" row_count=0 valid=1
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  [[ -n "${hook_json}" ]] || return 1
  image_rows="$(jq -r '
    [(.tool_response?, .tool_result?)
      | select(. != null)
      | .. | objects
      | ((.type? // "") | tostring | ascii_downcase) as $type
      | ((.mimeType? // .mime_type? // .media_type?
          // .source.media_type? // "") | tostring | ascii_downcase) as $mime
      | (.data? // .source.data? // .image.data? // "") as $raw_data
      | (if ((.image_url.url? // null) | type) == "string" then
           .image_url.url
         elif ((.image_url? // null) | type) == "string" then
           .image_url
         elif ((.url? // null) | type) == "string" then
           .url
         else "" end) as $url
      | (if (($raw_data | type) == "string"
            and ($raw_data | length) > 0) then $raw_data
         elif (($url | startswith("data:image/"))) then $url
         else "" end) as $data
      | select(($data | type) == "string" and ($data | length) > 0)
      | select($type == "image" or ($mime | startswith("image/"))
          or ($data | startswith("data:image/")))
      | [$mime,$data] | @tsv]
    | unique[]
  ' <<<"${hook_json}" 2>/dev/null || true)"
  [[ -n "${image_rows}" ]] || return 1
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/omc-image.XXXXXX" 2>/dev/null \
    || true)"
  [[ -n "${temp_dir}" && -d "${temp_dir}" ]] || return 1
  decoded="${temp_dir}/image.bin"
  while IFS=$'\t' read -r mime data; do
    [[ -n "${data}" ]] || { valid=0; break; }
    if [[ "${data}" == data:image/*';base64,'* ]]; then
      prefix="${data%%,*}"
      data="${data#*,}"
      [[ -n "${mime}" ]] || mime="${prefix#data:}"
      mime="${mime%%;*}"
    fi
    mime="$(printf '%s' "${mime}" | tr '[:upper:]' '[:lower:]')"
    [[ "${mime}" == "image/png" ]] || { valid=0; break; }
    [[ ${#data} -le 69905068 \
        && "${data}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
      || { valid=0; break; }
    _verification_decode_base64_file "${data}" "${decoded}" \
      || { valid=0; break; }
    size="$(wc -c <"${decoded}" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "${size}" =~ ^[0-9]+$ && "${size}" -ge 45 \
        && "${size}" -le 52428800 ]] || { valid=0; break; }
    _verification_png_file_is_structurally_valid "${decoded}" \
      || { valid=0; break; }
    digest="$(_verification_sha256_file "${decoded}" 2>/dev/null || true)"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || { valid=0; break; }
    material="${material}${mime}:${digest}"$'\n'
    row_count=$((row_count + 1))
  done <<<"${image_rows}"
  rm -f -- "${decoded}" 2>/dev/null || true
  rmdir -- "${temp_dir}" 2>/dev/null || true
  [[ "${valid}" -eq 1 && "${row_count}" -ge 1 ]] || return 1
  _verification_sha256_text "${material}"
}

# Resolve a connector-reported screenshot path and hash the image bytes. Only
# default screenshot formats, regular non-symlink files, bounded sizes, and
# matching file signatures are accepted. A missing connector-side file fails
# closed instead of letting two path-only responses share one visual identity.
mcp_verification_screenshot_file_digest() {
  local tool_name="${1:-}" output="${2:-}" tool_cwd="${3:-}"
  local lower="" candidate="" raw_path="" parent="" basename=""
  local resolved="" extension="" size="" digest=""
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  lower="$(printf '%s' "${tool_name}" | tr '[:upper:]-' '[:lower:]_')"
  case "${lower##*__}" in
    screenshot|screenshot_*|browser_take_screenshot) ;;
    *) return 1 ;;
  esac

  candidate="$(printf '%s\n' "${output}" | awk '
    BEGIN {
      phrase[1] = "screenshot saved to"
      phrase[2] = "saved screenshot to"
      phrase[3] = "screenshot written to"
      phrase[4] = "screenshot path"
    }
    {
      line = $0
      lower = tolower(line)
      rest = ""
      for (i = 1; i <= 4; i++) {
        at = index(lower, phrase[i])
        if (at > 0) {
          rest = substr(line, at + length(phrase[i]))
          break
        }
      }
      if (rest == "") next
      sub(/^[[:space:]:=-]+/, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      quote = substr(rest, 1, 1)
      if (quote == "\"" || quote == "\047" || quote == "`") {
        if (length(rest) < 3 || substr(rest, length(rest), 1) != quote) next
        rest = substr(rest, 2, length(rest) - 2)
      } else if (quote == "<") {
        if (length(rest) < 3 || substr(rest, length(rest), 1) != ">") next
        rest = substr(rest, 2, length(rest) - 2)
      }
      if (rest != "" && tolower(rest) ~ /[.]png$/) {
        print rest
        exit
      }
    }
  ' 2>/dev/null || true)"
  [[ -n "${candidate}" && "${candidate}" != *://* ]] || return 1
  if [[ "${candidate}" == /* ]]; then
    raw_path="${candidate}"
  else
    [[ -n "${tool_cwd}" && -d "${tool_cwd}" ]] || return 1
    raw_path="${tool_cwd%/}/${candidate}"
  fi
  basename="${raw_path##*/}"
  [[ -n "${basename}" && "${basename}" != "." && "${basename}" != ".." ]] \
    || return 1
  if [[ "${raw_path}" == */* ]]; then
    parent="${raw_path%/*}"
    [[ -n "${parent}" ]] || parent="/"
  else
    parent="."
  fi
  parent="$(cd -P -- "${parent}" 2>/dev/null && pwd -P)" || return 1
  resolved="${parent%/}/${basename}"
  [[ -f "${resolved}" && ! -L "${resolved}" ]] || return 1
  size="$(wc -c <"${resolved}" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "${size}" =~ ^[0-9]+$ && "${size}" -ge 45 \
      && "${size}" -le 52428800 ]] || return 1
  extension="$(printf '%s' "${basename##*.}" | tr '[:upper:]' '[:lower:]')"
  case "${extension}" in
    png) _verification_png_file_is_structurally_valid "${resolved}" \
      || return 1 ;;
    *) return 1 ;;
  esac
  digest="$(_verification_sha256_file "${resolved}" 2>/dev/null || true)"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "${digest}"
}

# Generated Playwright screenshot paths are transport metadata, not visual
# content. Callers may normalize the default `page-{timestamp}` component only
# after binding a separate image-content digest; image bytes/text and every
# other result byte remain identity-bearing.
mcp_verification_observation_digest_material() {
  local tool_name="${1:-}" output="${2:-}" lower=""
  local PATH="${_OMC_OBSERVER_SAFE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin}"
  lower="$(printf '%s' "${tool_name}" | tr '[:upper:]-' '[:lower:]_')"
  case "${lower##*__}" in
    browser_take_screenshot)
      printf '%s' "${output}" | sed -E \
        's#([^[:space:]"'"'"'()<>]*/)?page-[0-9][0-9T:._+-]*[.](png|jpeg)#page-{timestamp}.\2#g'
      ;;
    *) printf '%s' "${output}" ;;
  esac
}

# Derive the quality-contract evidence kind from the hook-observed tool, not
# from reviewer prose. The planner may permit several kinds, but a reviewer can
# only cite the kind actually stamped into the authoritative verification
# receipt.
#
# A special-purpose word in argv is only intent, not an observation. Require a
# result-side, kind-specific signal before stamping benchmark/comparison/render;
# otherwise an ordinary test runner that silently ignores `--benchmark` could
# launder generic test output into a stronger proof kind. Explicit zero counts
# are deliberately accepted here: the caller records those as current negative
# evidence via verification_output_reports_zero_execution().
verification_output_reports_kind_observation() {
  local output="${1:-}" kind="${2:-}" lower="" observed=""
  [[ -n "${output}" ]] || return 1
  lower="$(printf '%s' "${output}" | tr '[:upper:]' '[:lower:]')"

  case "${kind}" in
    benchmark)
      # Ignore non-observation/configuration lines, then require a structured
      # count or measured result. A later concrete result may supersede an
      # earlier retry diagnostic, while `benchmark unavailable; retry 1 ms`
      # and latency budgets cannot borrow their incidental units.
      observed="$(_verification_specialized_observation_lines \
        "${lower}" benchmark)"
      if printf '%s' "${observed}" | grep -Eiq \
          'benchmark[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]+tests?([^[:alnum:]_]|$)'; then
        return 0
      fi
      if printf '%s' "${observed}" | grep -Eiq \
          '^[[:space:]]*benchmark[[:space:]]+[1-9][0-9]*:' \
          && printf '%s' "${observed}" | grep -Eiq \
            '(time[[:space:]]*\((mean|median)|mean|median|p(50|75|90|95|99)|elapsed|took).*[1-9][0-9]*([.][0-9]+)?[[:space:]]*(ns|us|ms|s)|[1-9][0-9]*([.][0-9]+)?[[:space:]]*(ns/op|ops/s|req/s|requests/s|iterations/s)'; then
        return 0
      fi
      printf '%s' "${observed}" | grep -Eiq \
        '(^|[^0-9])[0-9]+[[:space:]]+(benchmarks?|benchmark[[:space:]]+(cases?|runs?|iterations?))([^[:alnum:]_]|$)|benchmarks?[[:space:]]*:[[:space:]]*[0-9]+([^0-9]|$)|(benchmark|hyperfine).*(mean|median|p(50|75|90|95|99)|elapsed|took|[0-9]+([.][0-9]+)?[[:space:]]*(ns/op|ops/s|req/s|requests/s|iterations/s)).*[0-9]+([.][0-9]+)?[[:space:]]*(ns|us|ms|s|ns/op|ops/s|req/s|requests/s|iterations/s)'
      ;;
    comparison)
      observed="$(_verification_specialized_observation_lines \
        "${lower}" comparison)"
      printf '%s' "${observed}" | grep -Eiq \
        '(^|[^0-9])[0-9]+[[:space:]]+comparisons?([^[:alnum:]_]|$)|comparisons?[[:space:]]*:[[:space:]]*[0-9]+([^0-9]|$)|(compare|comparison|diff|difference).*[0-9]+([.][0-9]+)?[[:space:]]*(matched|changed|differences?)|(baseline.*candidate|before.*after).*(delta|difference)[[:space:]]*[:=]?[[:space:]]*[-+]?[0-9]+([.][0-9]+)?[[:space:]]*(%|percent|ns|us|ms|s)'
      ;;
    render)
      observed="$(_verification_specialized_observation_lines \
        "${lower}" render)"
      printf '%s' "${observed}" | grep -Eiq \
        '(^|[^0-9])[0-9]+[[:space:]]+(renders?|rendered[[:space:]]+(frames?|pages?|images?)|snapshots?|screenshots?)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])render(ed)?[[:space:]]+[0-9]+[[:space:]]+(pages?|frames?|images?)([^[:alnum:]_]|$)|(renders?|snapshots?|screenshots?)[[:space:]]*:[[:space:]]*[0-9]+([^0-9]|$)|((render|snapshot|screenshot|artifact|image).*(created|produced|wrote|written|saved)|(created|produced|wrote|written|saved).*(render|snapshot|screenshot|artifact|image)).*([1-9][0-9]*[[:space:]]*(pages?|frames?|images?)|(artifact|digest|sha(256)?)[[:space:]]*[:=]|[^[:space:]]+[.](png|jpe?g|webp|pdf|svg))'
      ;;
    *) return 1 ;;
  esac
}

verification_command_requested_evidence_kind() {
  local command_text="${1:-}" family="" executable="" base="" token=""
  local lower="" requested="" candidate="" idx=0 script_idx=0 custom=0
  _verification_tokenize_argv "${command_text}" 2>/dev/null || return 1
  _verification_strip_literal_env_prefix 2>/dev/null || return 1
  family="$(_verification_executable_family_name \
    "${_VERIFICATION_ARGV[0]:-}" 2>/dev/null || true)"
  [[ -n "${family}" ]] || return 1
  executable="${_VERIFICATION_ARGV[0]:-}"
  case "${family}" in
    bash|zsh|sh)
      script_idx=1
      while [[ "${_VERIFICATION_ARGV[${script_idx}]:-}" == -* ]]; do
        script_idx=$((script_idx + 1))
      done
      executable="${_VERIFICATION_ARGV[${script_idx}]:-}"
      custom=1
      ;;
    pytest|vitest|jest|python|python3|uv|npx|cargo|go|swift|ruff|mypy|eslint|tsc|phpunit|rspec|bundle|rake|zig|deno|nix|shellcheck|npm|pnpm|yarn|bun|make|just|gradle|gradlew|xcodebuild|mvn|maven|dotnet|mix|docker|terraform|ansible-lint|helm)
      ;;
    *) custom=1 ;;
  esac
  base="$(printf '%s' "${executable##*/}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${custom}" -eq 1 ]]; then
    case "${base}" in
      benchmark|benchmark[-_.]*|bench|bench[-_.]*|run[-_.]benchmark|run[-_.]benchmark[-_.]*) requested='benchmark' ;;
      compare|compare[-_.]*|comparison|comparison[-_.]*|run[-_.]compare|run[-_.]compare[-_.]*|run[-_.]comparison|run[-_.]comparison[-_.]*) requested='comparison' ;;
      render|render[-_.]*|run[-_.]render|run[-_.]render[-_.]*) requested='render' ;;
    esac
  fi

  for ((idx=0; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
    token="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
      | tr '[:upper:]' '[:lower:]')"
    candidate=""
    case "${token}" in
      --benchmark-disable|--benchmark-disable=*|--benchmark-skip|--benchmark-skip=*) ;;
      --benchmark|--benchmark=*|--benchmark-only|--benchmark-only=*|--benchmark-enable|--benchmark-enable=*|--bench|--bench=*|-bench|-bench=*)
        candidate='benchmark' ;;
      --compare|--compare=*|--comparison|--comparison=*|--visual-diff|--snapshot-diff)
        candidate='comparison' ;;
      --render|--render=*|--rendering|--rendering=*) candidate='render' ;;
      benchmark|bench) [[ "${custom}" -eq 1 ]] && candidate='benchmark' ;;
      compare|comparison) [[ "${custom}" -eq 1 ]] && candidate='comparison' ;;
      render|rendering) [[ "${custom}" -eq 1 ]] && candidate='render' ;;
    esac
    [[ -n "${candidate}" ]] || continue
    if [[ -n "${requested}" && "${requested}" != "${candidate}" ]]; then
      return 1
    fi
    requested="${candidate}"
  done
  [[ -n "${requested}" ]] || return 1
  printf '%s' "${requested}"
}

verification_receipt_evidence_kind() {
  local method="${1:-}" scope="${2:-}" command_text="${3:-}"
  local output="${4:-}" outcome="${5:-passed}" lower requested_kind=""
  lower="$(printf '%s' "${command_text}" | tr '[:upper:]' '[:lower:]')"
  case "${method}" in
    mcp_browser_visual_check|mcp_computer_visual_check) printf 'render'; return ;;
    mcp_*) printf 'inspection'; return ;;
  esac
  requested_kind="$(verification_command_requested_evidence_kind \
    "${command_text}" 2>/dev/null || true)"
  if [[ -n "${requested_kind}" ]] \
      && { [[ "${outcome}" == "failed" ]] \
        || verification_output_reports_kind_observation \
          "${output}" "${requested_kind}"; }; then
    printf '%s' "${requested_kind}"
  elif [[ "${scope}" == "lint" ]] && printf '%s' "${lower}" | grep -Eiq \
    '(^|[[:space:]])(vale|textlint|alex|write-good|markdownlint|mdl)([[:space:]]|$)'; then
    printf 'inspection'
  else
    printf 'test'
  fi
}

# Parse one shell argv vector without evaluation. The Definition surface does
# not need a general shell parser because composition/redirection is forbidden,
# but it must preserve quoted and backslash-escaped path bytes exactly so two
# spellings of the same executed target cannot mint separate proof identities.
_verification_tokenize_argv() {
  local text="${1:-}" token="" quote="" ch="" next=""
  local escaped=0 token_started=0 index=0 tilde_expands=0
  local assignment_prefix_plain=1 assignment_equal_seen=0 assignment_word=0
  _VERIFICATION_ARGV=()
  _VERIFICATION_ARGV_TILDE_EXPANDS=()
  _VERIFICATION_ARGV_ASSIGNMENT_WORDS=()
  _VERIFICATION_HAD_ENV_PREFIX=0
  for ((index=0; index<${#text}; index++)); do
    ch="${text:index:1}"
    if (( escaped == 1 )); then
      token="${token}${ch}"
      token_started=1
      escaped=0
      continue
    fi
    case "${quote}" in
      single)
        if [[ "${ch}" == "'" ]]; then
          quote=""
        else
          token="${token}${ch}"
          token_started=1
        fi
        ;;
      double)
        case "${ch}" in
          '"') quote="" ;;
          \\)
            next="${text:$((index + 1)):1}"
            case "${next}" in
              '$'|'`'|'"'|\\|$'\n') escaped=1 ;;
              *) token="${token}\\" ;;
            esac
            token_started=1
            ;;
          '$'|'`') return 1 ;;
          *) token="${token}${ch}"; token_started=1 ;;
        esac
        ;;
      *)
        case "${ch}" in
          "'")
            [[ "${assignment_equal_seen}" -eq 1 ]] \
              || assignment_prefix_plain=0
            quote="single"; token_started=1
            ;;
          '"')
            [[ "${assignment_equal_seen}" -eq 1 ]] \
              || assignment_prefix_plain=0
            quote="double"; token_started=1
            ;;
          \\)
            [[ "${assignment_equal_seen}" -eq 1 ]] \
              || assignment_prefix_plain=0
            escaped=1; token_started=1
            ;;
          ' '|$'\t')
            if (( token_started == 1 )); then
              _VERIFICATION_ARGV+=("${token}")
              assignment_word=0
              if [[ "${assignment_prefix_plain}" -eq 1 \
                  && "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
                assignment_word=1
              fi
              _VERIFICATION_ARGV_TILDE_EXPANDS+=("${tilde_expands}")
              _VERIFICATION_ARGV_ASSIGNMENT_WORDS+=("${assignment_word}")
              token=""
              token_started=0
              tilde_expands=0
              assignment_prefix_plain=1
              assignment_equal_seen=0
            fi
            ;;
          ';'|'|'|'&'|'<'|'>'|'('|')'|'{'|'}'|'['|']'|'`'|'#'|'$'|'*'|'?') return 1 ;;
          *)
            if [[ "${token_started}" -eq 0 && "${ch}" == "~" ]]; then
              tilde_expands=1
            fi
            [[ "${ch}" == "=" ]] && assignment_equal_seen=1
            token="${token}${ch}"; token_started=1
            ;;
        esac
        ;;
    esac
  done
  [[ -z "${quote}" && "${escaped}" -eq 0 ]] || return 1
  if (( token_started == 1 )); then
    _VERIFICATION_ARGV+=("${token}")
    assignment_word=0
    if [[ "${assignment_prefix_plain}" -eq 1 \
        && "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
      assignment_word=1
    fi
    _VERIFICATION_ARGV_TILDE_EXPANDS+=("${tilde_expands}")
    _VERIFICATION_ARGV_ASSIGNMENT_WORDS+=("${assignment_word}")
  fi
  (( ${#_VERIFICATION_ARGV[@]} > 0 ))
}

# Remove only literal environment prefixes from the already tokenized argv.
# Expansion and shell grammar were rejected by the tokenizer, so these bytes
# cannot execute substitution. Environment spelling is execution context, not
# an independent proof surface.
_verification_strip_literal_env_prefix() {
  local idx=0 token="" env_utility=0
  local -a stripped=() stripped_tilde=() stripped_assignments=()
  [[ "${#_VERIFICATION_ARGV[@]}" -gt 0 ]] || return 1
  if [[ "${_VERIFICATION_ARGV[0]}" == "env" ]]; then
    env_utility=1
    _VERIFICATION_HAD_ENV_PREFIX=1
    idx=1
    [[ -n "${_VERIFICATION_ARGV[${idx}]:-}" \
        && "${_VERIFICATION_ARGV[${idx}]}" != -* ]] || return 1
  fi
  while [[ "${idx}" -lt "${#_VERIFICATION_ARGV[@]}" ]]; do
    token="${_VERIFICATION_ARGV[${idx}]}"
    [[ "${token}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || break
    if [[ "${env_utility}" -ne 1 \
        && "${_VERIFICATION_ARGV_ASSIGNMENT_WORDS[${idx}]:-0}" -ne 1 ]]; then
      break
    fi
    _VERIFICATION_HAD_ENV_PREFIX=1
    idx=$((idx + 1))
  done
  [[ "${idx}" -lt "${#_VERIFICATION_ARGV[@]}" ]] || return 1
  while [[ "${idx}" -lt "${#_VERIFICATION_ARGV[@]}" ]]; do
    stripped+=("${_VERIFICATION_ARGV[${idx}]}")
    stripped_tilde+=("${_VERIFICATION_ARGV_TILDE_EXPANDS[${idx}]:-0}")
    stripped_assignments+=("${_VERIFICATION_ARGV_ASSIGNMENT_WORDS[${idx}]:-0}")
    idx=$((idx + 1))
  done
  _VERIFICATION_ARGV=("${stripped[@]}")
  _VERIFICATION_ARGV_TILDE_EXPANDS=("${stripped_tilde[@]}")
  _VERIFICATION_ARGV_ASSIGNMENT_WORDS=("${stripped_assignments[@]}")
}

# Return the filesystem spelling the shell passes for an argv path token.
# Unquoted token-leading `~` expands before execution; quoted or escaped `~`
# is a literal cwd-relative directory name. The token text alone cannot
# distinguish those surfaces, so keep this provenance beside the parsed argv.
_verification_argv_path_token() {
  local idx="${1:-}" token="" tilde_char=$'~'
  [[ "${idx}" =~ ^[0-9]+$ ]] || return 1
  token="${_VERIFICATION_ARGV[${idx}]:-}"
  [[ -n "${token}" ]] || return 1
  case "${token}" in
    "${tilde_char}"|"${tilde_char}/"*)
      if [[ "${_VERIFICATION_ARGV_TILDE_EXPANDS[${idx}]:-0}" -eq 1 ]]; then
        token="${HOME}${token#\~}"
      else
        token="./${token}"
      fi
      ;;
    "${tilde_char}"*) return 1 ;;
  esac
  printf '%s' "${token}"
}

# Resolve only the executable identity, never its arguments. Matching a
# whitespace-joined argv lets one quoted token such as `"pytest fake"`
# impersonate two runner tokens. Basename normalization also makes a bare
# PATH-resolved runner and its absolute/venv spelling share one family.
_verification_executable_family_name() {
  local token="${1:-}" resolved="" normalized="" base="" lower=""
  [[ -n "${token}" ]] || return 1
  base="${token##*/}"
  lower="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    pytest|vitest|jest|python|python3|uv|npx|cargo|go|swift|ruff|mypy|eslint|tsc|phpunit|rspec|bundle|rake|zig|deno|nix|shellcheck|npm|pnpm|yarn|bun|make|just|gradle|gradlew|xcodebuild|mvn|maven|dotnet|mix|docker|terraform|ansible-lint|helm|bash|zsh|sh)
      printf '%s' "${lower}"
      return 0
      ;;
  esac
  if _verification_token_is_named_verifier "${token}" 2>/dev/null; then
    printf '%s' "${lower}"
    return 0
  fi
  if [[ "${token}" == */* || "${token}" == ~* ]]; then
    normalized="$(_verification_normalize_proof_path \
      "${token}" 0 executable 2>/dev/null || true)"
  else
    resolved="$(_verification_resolve_executable_path \
      "${token}" 2>/dev/null || true)"
    if [[ "${resolved}" == */* ]]; then
      normalized="${resolved}"
    fi
  fi
  [[ -n "${normalized}" ]] || normalized="${token}"
  base="${normalized##*/}"
  printf '%s' "${base}" | tr '[:upper:]' '[:lower:]'
}

_verification_token_is_named_verifier() {
  local token="${1:-}" base="" lower=""
  base="${token##*/}"
  [[ -n "${base}" && "${base}" != *[[:space:]]* ]] || return 1
  lower="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
  [[ "${lower}" =~ (^|[-_.])(test|tests|check|verify|validate|audit|benchmark|compare|comparison|render)([-_.]|$) ]]
}

_verification_token_is_constructive_named_verifier() {
  local token="${1:-}" mode="${2:-executable}" resolved=""
  _verification_token_is_named_verifier "${token}" || return 1
  case "${mode}" in executable|script) ;; *) return 1 ;; esac
  case "${token}" in
    */*)
      # A pre-mutation contract may deliberately freeze a verifier that the
      # implementation will create. Existing explicit paths must already have
      # executable/script shape; a future path remains constructive until an
      # actual successful PostTool completion proves it exists.
      if [[ ! -e "${token}" && ! -L "${token}" ]]; then
        return 0
      fi
      [[ -f "${token}" ]] || return 1
      [[ "${mode}" == "script" || -x "${token}" ]]
      return
      ;;
  esac
  if [[ "${mode}" == "script" ]]; then
    [[ -f "${token}" ]]
    return
  fi
  resolved="$(_verification_resolve_executable_path \
    "${token}" 2>/dev/null || true)"
  [[ "${resolved}" == /* && -f "${resolved}" && -x "${resolved}" ]]
}

# Return success when any lexical path component is a symlink. Canonicalizing
# first is insufficient: a component can point to B during execution and be
# restored to A before PostTool, yielding the same final canonical leaf. Proof
# provenance therefore rejects mutable symlink spellings before resolution.
_verification_path_has_symlink_component() {
  local value="${1:-}" base="${2:-${PWD}}" current="" component=""
  local -a parts=()
  [[ -n "${value}" && -n "${base}" ]] || return 1
  if [[ "${value}" == /* ]]; then
    current=""
  else
    current="$(cd "${base}" 2>/dev/null && pwd -P)" || return 1
  fi
  IFS='/' read -r -a parts <<<"${value}"
  for component in "${parts[@]}"; do
    case "${component}" in
      ''|.) continue ;;
      ..)
        current="${current%/*}"
        [[ -n "${current}" ]] || current="/"
        continue
        ;;
    esac
    if [[ "${current}" == "/" || -z "${current}" ]]; then
      current="/${component}"
    else
      current="${current%/}/${component}"
    fi
    [[ ! -L "${current}" ]] || return 0
  done
  return 1
}

# Reject symlink components controlled beneath the tool cwd without treating a
# stable platform alias in the cwd prefix itself (for example macOS `/var` ->
# `/private/var`) as project-controlled provenance. Absolute paths outside the
# cwd retain the fully strict check.
_verification_path_has_untrusted_symlink_component() {
  local value="${1:-}" tool_cwd="${2:-${PWD}}" relative=""
  [[ -n "${value}" && -n "${tool_cwd}" ]] || return 1
  if [[ "${value}" == /* ]]; then
    case "${value}" in
      "${tool_cwd}") return 1 ;;
      "${tool_cwd}"/*)
        relative="${value#"${tool_cwd}"/}"
        _verification_path_has_symlink_component \
          "${relative}" "${tool_cwd}"
        return
        ;;
      *)
        _verification_path_has_symlink_component "${value}" "/"
        return
        ;;
    esac
  fi
  _verification_path_has_symlink_component "${value}" "${tool_cwd}"
}

_verification_resolve_executable_path() {
  local token="${1:-}" strict="${2:-0}" resolved="" resolution_kind=""
  local search_path="${_OMC_HOOK_CALLER_PATH-${PATH:-}}"
  local observer_path="${PATH:-}" controls_removed=""
  [[ -n "${token}" ]] || return 1
  if [[ "${token}" != */* && "${token}" != ~* ]]; then
    [[ "${token}" != *[[:space:]]* ]] || return 1
    controls_removed="$(LC_ALL=C printf '%s' "${search_path}" \
      | LC_ALL=C tr -d '\001-\037\177')"
    [[ "${controls_removed}" == "${search_path}" ]] || return 1
    # `type` is a Bash builtin, so temporarily searching the captured caller
    # PATH is non-executing and cannot invoke a repo shim. It also preserves
    # the shell's builtin/function precedence exactly. Restore the pinned
    # observer PATH before canonicalization invokes any external observer.
    PATH="${search_path}"
    resolution_kind="$(builtin type -t -- "${token}" 2>/dev/null || true)"
    resolved="$(builtin type -P -- "${token}" 2>/dev/null || true)"
    PATH="${observer_path}"
    [[ "${resolution_kind}" == "file" \
        && "${resolved}" == */* && -f "${resolved}" && -x "${resolved}" ]] \
      || return 1
    if [[ "${strict}" -eq 1 ]] \
        && _verification_path_has_symlink_component "${resolved}" "/"; then
      return 1
    fi
    _verification_normalize_proof_path "${resolved}" 0 executable
    return
  fi
  if [[ "${strict}" -eq 1 ]] \
      && _verification_path_has_symlink_component "${token}" "${PWD}"; then
    return 1
  fi
  _verification_normalize_proof_path "${token}" 0 executable
}

# Resolve the exact executable the shell will launch for one plain argv proof
# command, using the caller PATH captured before observer pinning. This never
# executes the candidate. PreTool snapshots bind its canonical path and bytes;
# PostTool rejects a changed resolution/content before minting evidence.
verification_command_launcher_path() {
  local command_text="${1:-}" first=""
  [[ -n "${command_text}" ]] || return 1
  _verification_tokenize_argv "${command_text}" || return 1
  _verification_strip_literal_env_prefix || return 1
  [[ "${_VERIFICATION_HAD_ENV_PREFIX:-0}" -eq 0 ]] || return 1
  first="$(_verification_argv_path_token 0)" || return 1
  _verification_resolve_executable_path "${first}" 1
}

# Parse interpreter argv once for every provenance consumer. Results are
# exposed through globals because command substitution would hide the parsed
# argv arrays in a subshell. `file` identifies one concrete script, `inline`
# means all executable bytes are already sealed in the command input, and
# `module` names an interpreter-owned module surface whose launcher remains the
# conservative byte subject unless a concrete selector file is available.
_verification_parse_interpreter_subject() {
  local command_text="${1:-}" first="" family="" token="" flags=""
  local idx=1 argc=0
  _VERIFICATION_INTERPRETER_FAMILY=""
  _VERIFICATION_INTERPRETER_SUBJECT_KIND="none"
  _VERIFICATION_INTERPRETER_SUBJECT_INDEX=""
  _VERIFICATION_INTERPRETER_MODULE=""
  [[ -n "${command_text}" ]] || return 1
  _verification_tokenize_argv "${command_text}" || return 1
  _verification_strip_literal_env_prefix || return 1
  [[ "${_VERIFICATION_HAD_ENV_PREFIX:-0}" -eq 0 ]] || return 1
  first="$(_verification_argv_path_token 0)" || return 1
  family="$(_verification_executable_family_name \
    "${first}" 2>/dev/null || true)"
  _VERIFICATION_INTERPRETER_FAMILY="${family}"
  argc="${#_VERIFICATION_ARGV[@]}"
  case "${family}" in
    bash|zsh|sh)
      while [[ "${idx}" -lt "${argc}" ]]; do
        token="${_VERIFICATION_ARGV[${idx}]}"
        case "${token}" in
          --)
            idx=$((idx + 1))
            break
            ;;
          -c|--command|--command=*)
            _VERIFICATION_INTERPRETER_SUBJECT_KIND="inline"
            return 0
            ;;
          -s|--stdin)
            _VERIFICATION_INTERPRETER_SUBJECT_KIND="inline"
            return 0
            ;;
          -o|-O)
            idx=$((idx + 2))
            continue
            ;;
          --rcfile|--init-file)
            # An auxiliary startup file is a second executable subject. The
            # one-subject receipt cannot represent it without ambiguity.
            return 1
            ;;
          --rcfile=*|--init-file=*) return 1 ;;
          --debugger) return 1 ;;
          --help|--version|--dump-po-strings|--dump-strings) return 1 ;;
          --login|--noediting|--noprofile|--norc|--posix|--pretty-print|--restricted|--verbose)
            idx=$((idx + 1))
            continue
            ;;
          --*) return 1 ;;
          -*)
            flags="${token#-}"
            if [[ "${flags}" == *c* || "${flags}" == *s* ]]; then
              _VERIFICATION_INTERPRETER_SUBJECT_KIND="inline"
              return 0
            fi
            if [[ "${flags}" == *o || "${flags}" == *O ]]; then
              idx=$((idx + 2))
            elif [[ "${flags}" == *o* || "${flags}" == *O* ]]; then
              # A value-taking option embedded before more short flags is
              # ambiguous across supported shells; do not guess the script.
              return 1
            else
              idx=$((idx + 1))
            fi
            continue
            ;;
          *) break ;;
        esac
      done
      [[ "${idx}" -lt "${argc}" ]] || return 1
      _VERIFICATION_INTERPRETER_SUBJECT_KIND="file"
      _VERIFICATION_INTERPRETER_SUBJECT_INDEX="${idx}"
      return 0
      ;;
    python|python3)
      while [[ "${idx}" -lt "${argc}" ]]; do
        token="${_VERIFICATION_ARGV[${idx}]}"
        case "${token}" in
          --)
            idx=$((idx + 1))
            break
            ;;
          -c)
            _VERIFICATION_INTERPRETER_SUBJECT_KIND="inline"
            return 0
            ;;
          -c*)
            _VERIFICATION_INTERPRETER_SUBJECT_KIND="inline"
            return 0
            ;;
          -m)
            [[ -n "${_VERIFICATION_ARGV[$((idx + 1))]:-}" ]] || return 1
            _VERIFICATION_INTERPRETER_SUBJECT_KIND="module"
            _VERIFICATION_INTERPRETER_MODULE="${_VERIFICATION_ARGV[$((idx + 1))]}"
            _VERIFICATION_INTERPRETER_SUBJECT_INDEX="$((idx + 1))"
            return 0
            ;;
          -W|-X)
            idx=$((idx + 2))
            continue
            ;;
          --check-hash-based-pycs)
            idx=$((idx + 2))
            continue
            ;;
          --check-hash-based-pycs=*) idx=$((idx + 1)); continue ;;
          --help|--help-env|--help-xoptions|--help-all|--version) return 1 ;;
          --*) return 1 ;;
          -*) idx=$((idx + 1)); continue ;;
          *) break ;;
        esac
      done
      [[ "${idx}" -lt "${argc}" ]] || return 1
      _VERIFICATION_INTERPRETER_SUBJECT_KIND="file"
      _VERIFICATION_INTERPRETER_SUBJECT_INDEX="${idx}"
      return 0
      ;;
  esac
  return 1
}

# Resolve the concrete verifier bytes consumed by one proof command. A direct
# runner and an inline interpreter program use the launcher itself as their
# only filesystem subject (the inline program remains bound by input_digest).
# An interpreter script resolves to that exact script. Module execution fails
# closed because resolving arbitrary import machinery without executing the
# selected interpreter environment is not a trustworthy observer operation.
#
# The launcher and a concrete interpreter script are independent authority
# surfaces: snapshotting only `/bin/bash` would let `bash tests/check.sh`
# certify script bytes that were replaced while the tool was running.
verification_command_subject_path() {
  local command_text="${1:-}" tool_cwd="${2:-${PWD}}" subject=""
  local parsed=0 family="" kind=""
  [[ -n "${command_text}" && -n "${tool_cwd}" ]] || return 1
  if _verification_parse_interpreter_subject "${command_text}"; then
    parsed=1
  fi
  family="${_VERIFICATION_INTERPRETER_FAMILY:-}"
  kind="${_VERIFICATION_INTERPRETER_SUBJECT_KIND:-none}"
  case "${family}" in
    bash|zsh|sh|python|python3)
      [[ "${parsed}" -eq 1 ]] || return 1
      case "${kind}" in
        inline)
          verification_command_launcher_path "${command_text}"
          return
          ;;
        file)
          [[ "${_VERIFICATION_INTERPRETER_SUBJECT_INDEX}" =~ ^[0-9]+$ ]] \
            || return 1
          subject="$(_verification_argv_path_token \
            "${_VERIFICATION_INTERPRETER_SUBJECT_INDEX}")" || return 1
          [[ "${subject}" == /* ]] || subject="${tool_cwd%/}/${subject}"
          _verification_path_has_untrusted_symlink_component \
            "${subject}" "${tool_cwd}" && return 1
          [[ -f "${subject}" && ! -L "${subject}" ]] || return 1
          _verification_normalize_proof_path "${subject}" 0 executable
          return
          ;;
        # `python -m ...` has executable package bytes beyond the interpreter.
        # Refuse to mint a filesystem subject rather than pretend that hashing
        # only the Python launcher binds those module bytes.
        module) return 1 ;;
      esac
      return 1
      ;;
    *)
      # Non-interpreter proof commands execute their resolved launcher bytes.
      verification_command_launcher_path "${command_text}"
      ;;
  esac
}

# Recreate the exact display-command material sealed by a verification
# receipt. Bash proof identity ignores redundant whitespace outside quotes but
# preserves quoted and escaped bytes; every other tool seals the stored command
# verbatim. Keeping this in the shared verification library lets both the
# recorder and later contract validation derive the same command digest.
verification_receipt_command_material() {
  local command_text="${1:-}" tool_name="${2:-}"
  [[ -n "${command_text}" && -n "${tool_name}" ]] || return 1
  if [[ "${tool_name}" == "Bash" ]]; then
    printf '%s' "${command_text}" | awk '
      BEGIN { sq=0; dq=0; esc=0; pending=0; out="" }
      {
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1)
          if (esc) { if (pending) { out=out " "; pending=0 }; out=out c; esc=0; continue }
          if (c == "\\" && !sq) { if (pending) { out=out " "; pending=0 }; out=out c; esc=1; continue }
          if (c == "\047" && !dq) { if (pending) { out=out " "; pending=0 }; sq=!sq; out=out c; continue }
          if (c == "\"" && !sq) { if (pending) { out=out " "; pending=0 }; dq=!dq; out=out c; continue }
          if (c ~ /[[:space:]]/ && !sq && !dq) { if (length(out)>0) pending=1; continue }
          if (pending) { out=out " "; pending=0 }
          out=out c
        }
      }
      END { print out }
    '
  else
    printf '%s' "${command_text}"
  fi
}

verification_receipt_command_digest() {
  local material=""
  material="$(verification_receipt_command_material \
    "${1:-}" "${2:-}")" || return 1
  _omc_authority_digest "${material}"
}

# Resolve the exact regular file addressed by a Read call without executing
# any input-controlled bytes. Both aliases at once are ambiguous and fail
# closed. The caller hashes this canonical path before and after the tool so a
# result cannot be paired with different live file bytes.
verification_read_subject_path() {
  local input_json="${1:-}" tool_cwd="${2:-${PWD}}" subject=""
  [[ -n "${input_json}" && -n "${tool_cwd}" ]] || return 1
  subject="$(jq -er '
    if type != "object" then error("input must be an object")
    elif has("file_path") and has("path") then error("ambiguous path aliases")
    elif has("file_path") then .file_path
    elif has("path") then .path
    else error("missing path") end
    | select(type == "string" and length > 0)
    | if test("[\u0000-\u001f\u007f]")
      then error("path contains control bytes") else . end
  ' <<<"${input_json}" 2>/dev/null || true)"
  [[ -n "${subject}" ]] || return 1
  [[ "${subject}" == /* ]] || subject="${tool_cwd%/}/${subject}"
  _verification_path_has_untrusted_symlink_component \
    "${subject}" "${tool_cwd}" && return 1
  [[ -f "${subject}" && ! -L "${subject}" ]] || return 1
  _verification_normalize_proof_path "${subject}" 0 source
}

# Reject runner modes that can execute only a remembered, changed, sharded,
# filtered, or explicitly excluded subset while presenting the same broad
# semantic suite target. The caller has already tokenized a single argv vector
# and stripped (then rejected) environment prefixes. Named repository verifier
# scripts are deliberately outside this runner grammar: they are the escape
# hatch for a project-owned, reviewable scope policy.
_verification_definition_scope_policy_allows() {
  local first_family="${1:-}" runner="" idx=0 token=""
  local lower="" next="" option_value="" boundary=0 expect_value=0
  local scan_start=1
  runner="${first_family}"
  case "${first_family}" in
    python|python3)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "-m" \
          && "${_VERIFICATION_ARGV[2]:-}" == "pytest" ]] \
        && { runner="pytest"; scan_start=3; }
      ;;
    uv)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "run" \
          && "${_VERIFICATION_ARGV[2]:-}" == "pytest" ]] \
        && { runner="pytest"; scan_start=3; }
      ;;
    npx)
      case "${_VERIFICATION_ARGV[1]:-}" in
        pytest|vitest|jest)
          runner="${_VERIFICATION_ARGV[1]}"; scan_start=2 ;;
      esac
      ;;
    bundle)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "exec" \
          && "${_VERIFICATION_ARGV[2]:-}" == "rspec" ]] \
        && { runner="rspec"; scan_start=3; }
      ;;
    npm|pnpm|yarn|bun)
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "run" ]]; then
        scan_start=3
      else
        scan_start=2
      fi
      ;;
  esac

  case "${runner}" in
    pytest)
      for ((idx=scan_start; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        token="${_VERIFICATION_ARGV[${idx}]}"
        lower="$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')"
        next="${_VERIFICATION_ARGV[$((idx + 1))]:-}"
        case "${lower}" in
          -k|-k?*|-m|-m?*|--lf|--last-failed|--last-failed=*|--lfnf|--last-failed-no-failures|--last-failed-no-failures=*|--ff|--failed-first|--nf|--new-first|--sw|--stepwise|--stepwise=*|--stepwise-skip|--stepwise-skip=*|--ignore|--ignore=*|--ignore-glob|--ignore-glob=*|--deselect|--deselect=*|--pyargs)
            return 1 ;;
        esac
        option_value=""
        case "${lower}" in
          -o|--override-ini)
            option_value="$(printf '%s' "${next}" \
              | tr '[:upper:]' '[:lower:]')"
            ;;
          --override-ini=*) option_value="${lower#*=}" ;;
          -oaddopts=*) option_value="${lower#-o}" ;;
          -o=addopts=*) option_value="${lower#-o=}" ;;
          addopts=*) option_value="${lower}" ;;
        esac
        if [[ "${option_value}" == addopts=* ]] \
            && grep -Eiq '(^|[[:space:]])(-k|-m|--lf|--last-failed|--lfnf|--last-failed-no-failures|--ff|--failed-first|--nf|--new-first|--sw|--stepwise|--stepwise-skip|--ignore|--ignore-glob|--deselect|--pyargs)(=|[[:space:]]|$)' \
              <<<"${option_value#addopts=}"; then
          return 1
        fi
      done
      ;;
    jest|vitest)
      expect_value=0
      for ((idx=scan_start; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        if [[ "${expect_value}" -eq 1 ]]; then
          [[ -n "${lower}" && "${lower}" != -* ]] || return 1
          expect_value=0
          continue
        fi
        case "${lower}" in
          -o|-f|--onlychanged|--onlychanged=*|--onlyfailures|--onlyfailures=*|--changed|--changed=*|--changedsince|--changedsince=*|--lastcommit|--lastcommit=*|--related|--related=*|--findrelatedtests|--findrelatedtests=*|--runtestsbypath|--runtestsbypath=*|-t|-t?*|--testnamepattern|--testnamepattern=*|--testpathpattern|--testpathpattern=*|--testpathpatterns|--testpathpatterns=*|--testpathignorepatterns|--testpathignorepatterns=*|--testregex|--testregex=*|--testmatch|--testmatch=*|--selectprojects|--selectprojects=*|--ignoreprojects|--ignoreprojects=*|--projects|--projects=*|--project|--project=*|--roots|--roots=*|--include|--include=*|--shard|--shard=*|--filter|--filter=*|--exclude|--exclude=*|--dir|--dir=*|--root|--root=*|--watch|--watch=*|--watchall|--watchall=*)
            return 1 ;;
          --reporter|--reporters|--maxworkers|--max-workers|--workers|--pool|--testtimeout|--test-timeout|--hooktimeout|--hook-timeout)
            expect_value=1 ;;
          --reporter=*|--reporters=*|--maxworkers=*|--max-workers=*|--workers=*|--pool=*|--testtimeout=*|--test-timeout=*|--hooktimeout=*|--hook-timeout=*)
            ;;
        esac
        # Both runners interpret every remaining positional token as a test
        # name/path pattern, including opaque values such as `smoke`. Only
        # values consumed by an explicitly modeled non-selector option above
        # may appear without a leading dash.
        [[ "${lower}" == -* ]] || return 1
      done
      [[ "${expect_value}" -eq 0 ]] || return 1
      ;;
    cargo)
      boundary=0
      expect_value=0
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        if [[ "${boundary}" -eq 0 ]]; then
          if [[ "${expect_value}" -eq 1 ]]; then
            [[ -n "${lower}" && "${lower}" != "--" ]] || return 1
            expect_value=0
            continue
          fi
          [[ "${lower}" == "--" ]] && { boundary=1; continue; }
          case "${lower}" in
            --exclude|--exclude=*|--bins|--tests|--benches|--examples|--all-targets)
              return 1 ;;
            -p|--package|--manifest-path|--test|--bench|--example|--bin|-f|--features|--target|--target-dir|--profile|-j|--jobs|--color|--message-format|--config|-z)
              expect_value=1 ;;
            --package=*|--manifest-path=*|--test=*|--bench=*|--example=*|--bin=*|--features=*|--target=*|--target-dir=*|--profile=*|--jobs=*|--color=*|--message-format=*|--config=*|-j?*|-f?*|-z?*)
              ;;
            -q|--quiet|-v|--verbose|--workspace|--all|--lib|--doc|--release|--all-features|--no-default-features|--no-run|--no-fail-fast|--locked|--frozen|--offline|--keep-going|--timings|--timings=*)
              ;;
            -*)
              # An unmodeled Cargo option may itself be a target selector or
              # consume the next token. It cannot prove the broad suite.
              return 1 ;;
            *)
              # Cargo's sole pre-boundary positional is TESTNAME, a substring
              # filter. Treat even pathless labels as narrowed execution.
              return 1 ;;
          esac
          continue
        fi
        if [[ "${expect_value}" -eq 1 ]]; then
          [[ -n "${lower}" ]] || return 1
          expect_value=0
          continue
        fi
        case "${lower}" in
          -q|--quiet|--nocapture|--show-output) ;;
          --color|--format|--test-threads) expect_value=1 ;;
          --color=*|--format=*|--test-threads=*) ;;
          *) return 1 ;;
        esac
      done
      [[ "${expect_value}" -eq 0 ]] || return 1
      ;;
    go)
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
          -run|-run=*|-run?*|-skip|-skip=*|-skip?*|-short|-short=*|--)
            return 1 ;;
        esac
      done
      ;;
    npm|pnpm|yarn|bun)
      expect_value=0
      for ((idx=scan_start; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        if [[ "${expect_value}" -eq 1 ]]; then
          [[ -n "${lower}" && "${lower}" != -* ]] || return 1
          expect_value=0
          continue
        fi
        case "${lower}" in
          --) [[ $((idx + 1)) -ge ${#_VERIFICATION_ARGV[@]} ]] || return 1 ;;
          --color|--colors|--no-color|--no-colors|--silent|--verbose|--runinband|--run-in-band|--no-cache|--ci|--bail) ;;
          --reporter|--reporters|--maxworkers|--max-workers|--workers|--jobs|-j|--concurrency|--test-timeout)
            expect_value=1 ;;
          --color=*|--reporter=*|--reporters=*|--maxworkers=*|--max-workers=*|--workers=*|--jobs=*|--concurrency=*|--test-timeout=*|--cache=false) ;;
          *) return 1 ;;
        esac
      done
      [[ "${expect_value}" -eq 0 ]] || return 1
      ;;
    rspec)
      for ((idx=scan_start; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
          -e|--example|--example=*|-t|--tag|--tag=*|--only-failures|--next-failure) return 1 ;;
        esac
        if [[ "${lower}" != -* && "${lower}" == *:[0-9]* ]]; then
          return 1
        fi
      done
      ;;
    phpunit)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in
          --filter|--filter=*|--group|--group=*|--exclude-group|--exclude-group=*|--testsuite|--testsuite=*) return 1 ;;
        esac
        if [[ "${lower}" != -* ]]; then
          case "${lower}" in */*.php|*.php) return 1 ;; esac
        fi
      done
      ;;
    swift)
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in --filter|--filter=*|--skip|--skip=*|--skip-build) return 1 ;; esac
      done
      ;;
    gradle|gradlew)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in --tests|--tests=*|-x|--exclude-task|--exclude-task=*) return 1 ;; esac
      done
      ;;
    xcodebuild)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in -only-testing|-only-testing:*|-skip-testing|-skip-testing:*) return 1 ;; esac
      done
      ;;
    mvn|maven)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in -dtest|-dtest=*|-dit.test|-dit.test=*|-dgroups|-dgroups=*|-dexcludedgroups|-dexcludedgroups=*|-pl|-pl=*|--projects|--projects=*) return 1 ;; esac
      done
      ;;
    dotnet)
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in --filter|--filter=*|--list-tests|--list-tests=*) return 1 ;; esac
      done
      ;;
    deno)
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in --filter|--filter=*|--ignore|--ignore=*|--exclude|--exclude=*) return 1 ;; esac
      done
      ;;
    mix)
      for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        case "${lower}" in --only|--only=*|--exclude|--exclude=*|--stale|--failed) return 1 ;; esac
        if [[ "${lower}" != -* && "${lower}" == *:[0-9]* ]]; then
          return 1
        fi
      done
      ;;
  esac
  return 0
}

_verification_scope_policy_suffix() {
  local start="${1:-0}" idx=0 token="" material="" digest=""
  local LC_ALL=C
  [[ "${start}" =~ ^[0-9]+$ ]] || return 1
  for ((idx=start; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
    token="${_VERIFICATION_ARGV[${idx}]}"
    material+="${#token}:${token};"
  done
  [[ -n "${material}" ]] || return 0
  digest="$(_omc_authority_digest "${material}" 2>/dev/null)" || return 1
  [[ "${digest}" =~ ^[0-9a-f]{24}$ ]] || return 1
  printf '|policy=%s' "${digest}"
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
  local token="" lower_token="" idx=0 next_token="" first_family=""
  local first_token="" script_token="" option_value=""
  normalized="$(printf '%s' "${command_text}" \
    | tr '\t\r\n' '   ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"
  [[ -n "${normalized}" ]] || return 1

  # No shell grammar beyond a single argv vector. The tokenizer preserves
  # quoted/escaped bytes but rejects composition, expansion, globs,
  # substitutions, redirections, comments, and backgrounding.
  [[ "${command_text}" != *$'\n'* && "${command_text}" != *$'\r'* ]] || return 1
  _verification_tokenize_argv "${command_text}" || return 1
  _verification_strip_literal_env_prefix || return 1
  # Definition proof may not alter executable/library/plugin resolution in an
  # opaque prefix. Even apparently harmless variables have framework-specific
  # loader semantics; expose the environment in a named verifier wrapper when
  # it is part of the intended proof surface.
  [[ "${_VERIFICATION_HAD_ENV_PREFIX:-0}" -eq 0 ]] || return 1
  first_token="$(_verification_argv_path_token 0)" || return 1
  if [[ "${first_token}" == */* ]]; then
    if [[ -e "${first_token}" \
        || -L "${first_token}" ]]; then
      [[ -f "${first_token}" \
          && -x "${first_token}" ]] || return 1
    fi
  else
    # The shell may prefer a builtin, keyword, function, or alias over a PATH
    # executable with the same spelling. Receipt authority follows that actual
    # resolution order and therefore admits only a bare external file here.
    case "$(builtin type -t -- "${_VERIFICATION_ARGV[0]}" 2>/dev/null || true)" in
      alias|builtin|function|keyword) return 1 ;;
    esac
  fi
  first_family="$(_verification_executable_family_name \
    "${first_token}" 2>/dev/null || true)"
  [[ -n "${first_family}" ]] || return 1

  # Discovery/help/configuration and deliberate no-test modes do not execute
  # the claimed proof. Keep this family-level rather than tool-specific: a
  # project wrapper that forwards one of these flags is just as non-causal as
  # invoking the underlying runner directly.
  for ((idx=0; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
    token="${_VERIFICATION_ARGV[${idx}]}"
    lower_token="$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')"
    next_token="${_VERIFICATION_ARGV[$((idx + 1))]:-}"
    case "${lower_token}" in
      --version|--version=*|--help|--help=*|--collect-only|--collect-only=*|--collectonly|--collectonly=*|--co|--co=*|--fixtures|--fixtures=*|--fixtures-per-test|--fixtures-per-test=*|--markers|--markers=*|--setup-only|--setup-only=*|--setup-plan|--setup-plan=*|--list|--list=*|--list-tests|--list-tests=*|--list-tests-*|--list-suites|--list-suites=*|--listtests|--listtests=*|--dry-run|--dry-run=*|--showconfig|--showconfig=*|--print-config|--print-config=*|--print-only|--print-only=*|--no-run|--no-run=*|--pass-with-no-tests|--pass-with-no-tests=*|--passwithnotests|--passwithnotests=*|--if-present|--if-present=*|-list|-list=*|-dskiptests|-dskiptests=true|-dskipits|-dskipits=true|-dmaven.test.skip|-dmaven.test.skip=true)
        return 1 ;;
      --cache-show|--cache-show=*|--clearcache|--show-files|--show-settings|--init|--show-bin-path|--warm-coverage-cache)
        return 1 ;;
      --list-groups|--list-groups=*)
        return 1 ;;
      -x|--exclude-task)
        case "$(printf '%s' "${next_token}" | tr '[:upper:]' '[:lower:]')" in
          test|check|*:test|*:check) return 1 ;;
        esac
        ;;
      --exclude-task=test|--exclude-task=check|--exclude-task=*:test|--exclude-task=*:check)
        return 1 ;;
    esac
    case "${token}" in -V|-h) return 1 ;; esac

    # Pytest can smuggle discovery-only flags through its configuration
    # override values. Treat the value as an argv fragment only for the two
    # options that explicitly rewrite addopts; arbitrary option values must
    # not acquire shell semantics here.
    option_value=""
    case "${lower_token}" in
      -o|--override-ini)
        option_value="$(printf '%s' "${next_token}" | tr '[:upper:]' '[:lower:]')"
        ;;
      --override-ini=*) option_value="${lower_token#*=}" ;;
      -oaddopts=*) option_value="${lower_token#-o}" ;;
      -o=addopts=*) option_value="${lower_token#-o=}" ;;
      addopts=*) option_value="${lower_token}" ;;
    esac
    if [[ "${option_value}" == addopts=* ]] \
        && grep -Eiq '(^|[[:space:]])(--version|--help|--collect-only|--collectonly|--co|--fixtures|--fixtures-per-test|--markers|--setup-only|--setup-plan|--list|--list-tests|--list-suites|--dry-run|--no-run|--cache-show|--clearcache)(=|[[:space:]]|$)' \
          <<<"${option_value#addopts=}"; then
      return 1
    fi
  done

  # Runner-specific discovery aliases that are ambiguous or execution-bearing
  # elsewhere. They must be checked against actual argv elements.
  case "${first_family}" in
    dotnet)
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "test" ]]; then
        for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
          case "${_VERIFICATION_ARGV[${idx}]}" in -t) return 1 ;; esac
        done
      fi
      ;;
    swift)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "test" \
          && "${_VERIFICATION_ARGV[2]:-}" == "list" ]] && return 1
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        [[ "${_VERIFICATION_ARGV[${idx}]}" != "--show-bin-path" ]] || return 1
      done
      ;;
    go)
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "test" ]]; then
        for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
          case "${_VERIFICATION_ARGV[${idx}]}" in -c|-c=*) return 1 ;; esac
        done
      fi
      ;;
    make)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          -n|--just-print|--dry-run|--recon|-q|--question|-t|--touch) return 1 ;;
        esac
        [[ "${_VERIFICATION_ARGV[${idx}]}" != --* \
            && "${_VERIFICATION_ARGV[${idx}]}" =~ ^-[A-Za-z]*[nqt][A-Za-z]*$ ]] \
          && return 1
      done
      ;;
    just)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          -n|--just-print|--dry-run|--recon) return 1 ;;
        esac
      done
      ;;
    shellcheck)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          --list-optional|--list-optional=*) return 1 ;;
        esac
      done
      ;;
    xcodebuild)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          -showBuildSettings|-showdestinations|-showsdks) return 1 ;;
        esac
      done
      ;;
    pytest)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          --cache-show|--cache-show=*) return 1 ;;
        esac
      done
      ;;
    ruff)
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "check" ]]; then
        for ((idx=2; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
          case "${_VERIFICATION_ARGV[${idx}]}" in
            --show-files|--show-settings) return 1 ;;
          esac
        done
      fi
      ;;
    tsc)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        [[ "${_VERIFICATION_ARGV[${idx}]}" != "--init" ]] || return 1
      done
      ;;
    jest)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        [[ "${_VERIFICATION_ARGV[${idx}]}" != "--clearCache" ]] || return 1
      done
      ;;
    phpunit)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in
          --warm-coverage-cache|--list-groups|--list-groups=*) return 1 ;;
        esac
      done
      ;;
  esac

  _verification_definition_scope_policy_allows "${first_family}" || return 1

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

  case "${first_family}" in
    pytest|vitest|jest|phpunit|rspec|tsc) return 0 ;;
    python|python3)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "-m" \
          && "${_VERIFICATION_ARGV[2]:-}" == "pytest" ]] && return 0 ;;
    uv)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "run" \
          && "${_VERIFICATION_ARGV[2]:-}" == "pytest" ]] && return 0 ;;
    npx)
      case "${_VERIFICATION_ARGV[1]:-}" in pytest|vitest|jest) return 0 ;; esac ;;
    cargo|go|deno)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "test" ]] && return 0 ;;
    swift)
      case "${_VERIFICATION_ARGV[1]:-}" in test|build) return 0 ;; esac ;;
    ruff)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "check" \
          && "${#_VERIFICATION_ARGV[@]}" -gt 2 ]] && return 0 ;;
    mypy|eslint|shellcheck|ansible-lint)
      [[ "${#_VERIFICATION_ARGV[@]}" -gt 1 ]] && return 0 ;;
    bundle)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "exec" \
          && "${_VERIFICATION_ARGV[2]:-}" == "rspec" ]] && return 0 ;;
    rake)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "test" ]] && return 0 ;;
    zig|nix)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "build" ]] && return 0 ;;
    npm|pnpm|yarn|bun)
      case "${_VERIFICATION_ARGV[1]:-}" in test|check|lint|build) return 0 ;; esac
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "run" ]]; then
        case "${_VERIFICATION_ARGV[2]:-}" in test|check|lint|build) return 0 ;; esac
      fi
      ;;
    make|just)
      case "${_VERIFICATION_ARGV[1]:-}" in test|check|lint|verify|build) return 0 ;; esac ;;
    gradle|gradlew)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        lower_token="$(printf '%s' "${_VERIFICATION_ARGV[${idx}]}" \
          | tr '[:upper:]' '[:lower:]')"
        [[ "${lower_token}" != -* \
            && "${lower_token}" == *test* ]] && return 0
      done
      ;;
    xcodebuild)
      for ((idx=1; idx<${#_VERIFICATION_ARGV[@]}; idx++)); do
        case "${_VERIFICATION_ARGV[${idx}]}" in test|build) return 0 ;; esac
      done
      ;;
    mvn|maven)
      case "${_VERIFICATION_ARGV[1]:-}" in test|verify) return 0 ;; esac ;;
    dotnet|mix)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "test" ]] && return 0 ;;
    docker)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "build" \
          && "${#_VERIFICATION_ARGV[@]}" -gt 2 ]] && return 0
      [[ "${_VERIFICATION_ARGV[1]:-}" == "compose" \
          && "${_VERIFICATION_ARGV[2]:-}" == "build" ]] && return 0 ;;
    terraform)
      case "${_VERIFICATION_ARGV[1]:-}" in plan|validate) return 0 ;; esac ;;
    helm)
      [[ "${_VERIFICATION_ARGV[1]:-}" == "lint" \
          && "${#_VERIFICATION_ARGV[@]}" -gt 2 ]] && return 0 ;;
    bash|zsh|sh)
      if [[ "${_VERIFICATION_ARGV[1]:-}" == "-n" ]]; then
        [[ "${#_VERIFICATION_ARGV[@]}" -gt 2 ]] && return 0
      elif [[ "${_VERIFICATION_ARGV[1]:-}" != -* ]]; then
        script_token="$(_verification_argv_path_token 1 \
          2>/dev/null || true)"
        [[ -n "${script_token}" ]] \
          && _verification_token_is_constructive_named_verifier \
            "${script_token}" script \
          && return 0
      fi
      ;;
  esac

  _verification_token_is_constructive_named_verifier \
    "${first_token}" \
    && return 0
  return 1
}

# Return the verifier-owned semantic execution target used to deduplicate
# Definition-of-Excellent proof. Structured runner selectors are normalized
# directly. Opaque custom/collapsed-family suffix argv is bound by a compact
# `|policy=` digest, while Quality Contract overlap compares the underlying
# verifier scope before that suffix. Thus exact receipts bind the invocation,
# but `bash tests/check.sh Q-001` through `Q-005` still cannot mint five
# independent criterion scopes when check.sh ignores every argument.
#
# Known test runners retain modeled positional selectors, so independently
# targeted files/packages remain distinct only where the parser models them.
# Explicit cache/filter/changed/shard/exclusion modes fail admission; projects
# needing an unusual fixed scope expose it through a named verifier target.
_verification_command_semantic_target_unbound() {
  local command_text="${1:-}" project_test_cmd="${2:-}"
  local first="" first_family="" family="" script="" token="" target=""
  local existing="" duplicate=0 idx=0 start=0
  local selector_ambiguous=0 options_ended=0 normalized_selector=""
  local selector_candidate=0
  local option_value="" tilde_char=$'~' selector_mode="content"
  local policy_suffix=""
  local -a argv=() selectors=() unique_selectors=()

  verification_command_is_authoritative_execution \
    "${command_text}" "${project_test_cmd}" || return 1
  _verification_tokenize_argv "${command_text}" || return 1
  _verification_strip_literal_env_prefix || return 1
  argv=("${_VERIFICATION_ARGV[@]}")
  [[ "${#argv[@]}" -gt 0 ]] || return 1
  first="$(_verification_argv_path_token 0)" || return 1
  argv[0]="${first}"
  first_family="$(_verification_executable_family_name \
    "${first}" 2>/dev/null || true)"
  [[ -n "${first_family}" ]] || return 1

  case "${first_family}" in
    bash|zsh|sh)
      _verification_parse_interpreter_subject "${command_text}" || return 1
      if [[ "${_VERIFICATION_INTERPRETER_SUBJECT_KIND}" == "inline" ]]; then
        printf '%s:inline:%s\n' "${first_family}" "${command_text}"
        return 0
      fi
      [[ "${_VERIFICATION_INTERPRETER_SUBJECT_KIND}" == "file" \
          && "${_VERIFICATION_INTERPRETER_SUBJECT_INDEX}" =~ ^[0-9]+$ ]] \
        || return 1
      idx="${_VERIFICATION_INTERPRETER_SUBJECT_INDEX}"
      family="executable"
      for ((start=1; start<idx; start++)); do
        if [[ "${argv[${start}]}" == "-n" \
            || "${argv[${start}]}" =~ ^-[A-Za-z]*n[A-Za-z]*$ ]]; then
          family="${first_family}:syntax"
          break
        fi
      done
      # The script is the proof surface, not the spelling of the shell used
      # to launch it. Otherwise `bash check.sh`, `sh check.sh`, and an
      # executable `./check.sh` can mint three identities for one verifier.
      script="$(_verification_argv_path_token "${idx}" \
        2>/dev/null || true)"
      [[ -n "${script}" ]] || { printf '%s\n' "${family}"; return 0; }
      target="$(_verification_normalize_proof_path \
        "${script}" 0 executable)" || return 1
      [[ -n "${target}" ]] || return 1
      policy_suffix="$(_verification_scope_policy_suffix \
        "$((idx + 1))")" || return 1
      printf '%s:%s%s\n' "${family}" "${target}" "${policy_suffix}"
      return 0
      ;;
    python|python3)
      if [[ "${argv[1]:-}" == "-m" && "${argv[2]:-}" == "pytest" ]]; then
        family="pytest"; start=3
      fi
      ;;
    uv)
      if [[ "${argv[1]:-}" == "run" && "${argv[2]:-}" == "pytest" ]]; then
        family="pytest"; start=3
      fi
      ;;
    npx)
      case "${argv[1]:-}" in
        pytest|vitest|jest) family="${argv[1]}"; start=2 ;;
      esac
      ;;
    pytest|vitest|jest)
      family="${first_family}"; start=1
      ;;
    go)
      [[ "${argv[1]:-}" == "test" ]] && { family="go-test"; start=2; }
      ;;
    cargo)
      if [[ "${argv[1]:-}" == "test" ]]; then
        # Cargo's forwarded post-`--` vector is opaque, but its documented
        # package/manifest/target selectors before that boundary identify
        # genuinely distinct compilation/test surfaces.
        for ((idx=2; idx<${#argv[@]}; idx++)); do
          token="${argv[${idx}]}"
          [[ "${token}" == "--" ]] && break
          case "${token}" in
            -p|--package|--manifest-path|--test|--bench|--example|--bin)
              idx=$((idx + 1))
              [[ -n "${argv[${idx}]:-}" ]] || return 1
              case "${token}" in
                --manifest-path)
                  normalized_selector="$(_verification_normalize_proof_path \
                    "$(_verification_argv_path_token "${idx}")" \
                    2>/dev/null || true)"
                  [[ -n "${normalized_selector}" ]] || return 1
                  selectors+=("manifest:${normalized_selector}")
                  ;;
                -p|--package) selectors+=("package:${argv[${idx}]}") ;;
                --test) selectors+=("test:${argv[${idx}]}") ;;
                --bench) selectors+=("bench:${argv[${idx}]}") ;;
                --example) selectors+=("example:${argv[${idx}]}") ;;
                --bin) selectors+=("bin:${argv[${idx}]}") ;;
              esac
              ;;
            --package=*) selectors+=("package:${token#*=}") ;;
            --test=*) selectors+=("test:${token#*=}") ;;
            --bench=*) selectors+=("bench:${token#*=}") ;;
            --example=*) selectors+=("example:${token#*=}") ;;
            --bin=*) selectors+=("bin:${token#*=}") ;;
            --manifest-path=*)
              option_value="${token#*=}"
              case "${option_value}" in
                "${tilde_char}"|"${tilde_char}/"*)
                  # Tilde expansion is token-leading. Bash passes a tilde
                  # after an ordinary option `=` literally, even unquoted.
                  option_value="./${option_value}"
                  ;;
                "${tilde_char}"*) return 1 ;;
              esac
              normalized_selector="$(_verification_normalize_proof_path \
                "${option_value}" 2>/dev/null || true)"
              [[ -n "${normalized_selector}" ]] || return 1
              selectors+=("manifest:${normalized_selector}")
              ;;
            --workspace|--all) selectors+=("workspace") ;;
            --lib|--doc) selectors+=("${token#--}") ;;
          esac
        done
        family="cargo-test"
        if [[ "${#selectors[@]}" -gt 0 ]]; then
          for token in "${selectors[@]}"; do
            duplicate=0
            if [[ "${#unique_selectors[@]}" -gt 0 ]]; then
              for existing in "${unique_selectors[@]}"; do
                [[ "${existing}" == "${token}" ]] && duplicate=1 && break
              done
            fi
            [[ "${duplicate}" -eq 1 ]] || unique_selectors+=("${token}")
          done
        fi
        if [[ "${#unique_selectors[@]}" -eq 0 ]]; then
          printf '%s\n' "${family}"
        else
          target=""
          while IFS= read -r token; do
            target="${target:+${target}|}${token}"
          done < <(printf '%s\n' "${unique_selectors[@]}" \
            | LC_ALL=C sort -u)
          printf '%s:%s\n' "${family}" "${target}"
        fi
        return 0
      fi
      ;;
    shellcheck)
      family="shellcheck"; start=1
      ;;
    swift)
      case "${argv[1]:-}" in
        test)
          policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
          printf 'swift-test%s\n' "${policy_suffix}"; return 0 ;;
        build)
          policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
          printf 'swift-build%s\n' "${policy_suffix}"; return 0 ;;
      esac
      ;;
    ruff)
      if [[ "${argv[1]:-}" == "check" ]]; then
        policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
        printf 'ruff-check%s\n' "${policy_suffix}"; return 0
      fi
      ;;
    mypy|eslint|tsc)
      policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
      printf '%s-project%s\n' "${first_family}" "${policy_suffix}"
      return 0
      ;;
    phpunit)
      policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
      printf 'phpunit-suite%s\n' "${policy_suffix}"
      return 0
      ;;
    rspec)
      policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
      printf 'rspec-suite%s\n' "${policy_suffix}"
      return 0
      ;;
    bundle)
      if [[ "${argv[1]:-}" == "exec" && "${argv[2]:-}" == "rspec" ]]; then
        policy_suffix="$(_verification_scope_policy_suffix 3)" || return 1
        printf 'rspec-suite%s\n' "${policy_suffix}"
        return 0
      fi
      ;;
    rake)
      [[ "${argv[1]:-}" == "test" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'rake-test%s\n' "${policy_suffix}"; return 0; }
      ;;
    zig)
      [[ "${argv[1]:-}" == "build" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'zig-build%s\n' "${policy_suffix}"; return 0; }
      ;;
    deno)
      [[ "${argv[1]:-}" == "test" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'deno-test%s\n' "${policy_suffix}"; return 0; }
      ;;
    nix)
      [[ "${argv[1]:-}" == "build" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'nix-build%s\n' "${policy_suffix}"; return 0; }
      ;;
    npm|pnpm|yarn)
      # The named package script is the harness-observable target. Forwarded
      # custom argv, package-manager aliases, and `run` shorthand cannot
      # manufacture independent proof identities for one package.json script.
      case "${argv[1]:-}" in
        test|check|lint|build)
          policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
          printf 'package-script:%s%s\n' \
            "${argv[1]}" "${policy_suffix}"; return 0 ;;
        run)
          policy_suffix="$(_verification_scope_policy_suffix 3)" || return 1
          printf 'package-script:%s%s\n' \
            "${argv[2]:-unknown}" "${policy_suffix}"; return 0 ;;
      esac
      ;;
    bun)
      # `bun test` is Bun's runner; `bun run test` is a package script.
      if [[ "${argv[1]:-}" == "run" ]]; then
        policy_suffix="$(_verification_scope_policy_suffix 3)" || return 1
        printf 'package-script:%s%s\n' \
          "${argv[2]:-unknown}" "${policy_suffix}"
      else
        policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
        printf 'bun-test%s\n' "${policy_suffix}"
      fi
      return 0
      ;;
    make|just)
      policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
      printf '%s:%s%s\n' \
        "${first_family}" "${argv[1]:-default}" "${policy_suffix}"
      return 0
      ;;
    gradle|gradlew)
      # The system Gradle launcher and the repository wrapper address the same
      # current-project surface. Gradle's open-ended option grammar makes task
      # names indistinguishable from option values here, so collapse safely;
      # projects needing independent task proof can expose named wrappers.
      policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
      printf 'gradle-project%s\n' "${policy_suffix}"
      return 0
      ;;
    xcodebuild)
      for ((idx=1; idx<${#argv[@]}; idx++)); do
        case "${argv[${idx}]}" in
          test)
            policy_suffix="$(_verification_scope_policy_suffix 1)" \
              || return 1
            printf 'xcodebuild-test%s\n' "${policy_suffix}"; return 0 ;;
          build)
            policy_suffix="$(_verification_scope_policy_suffix 1)" \
              || return 1
            printf 'xcodebuild-build%s\n' "${policy_suffix}"; return 0 ;;
        esac
      done
      ;;
    mvn|maven)
      case "${argv[1]:-}" in
        test|verify)
          policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
          printf 'maven:%s%s\n' \
            "${argv[1]}" "${policy_suffix}"; return 0 ;;
      esac
      ;;
    dotnet)
      [[ "${argv[1]:-}" == "test" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'dotnet-test%s\n' "${policy_suffix}"; return 0; }
      ;;
    mix)
      [[ "${argv[1]:-}" == "test" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'mix-test%s\n' "${policy_suffix}"; return 0; }
      ;;
    docker)
      if [[ "${argv[1]:-}" == "build" ]]; then
        policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
        printf 'docker-build%s\n' "${policy_suffix}"; return 0
      elif [[ "${argv[1]:-}" == "compose" \
          && "${argv[2]:-}" == "build" ]]; then
        policy_suffix="$(_verification_scope_policy_suffix 3)" || return 1
        printf 'docker-compose-build%s\n' "${policy_suffix}"; return 0
      fi
      ;;
    terraform)
      case "${argv[1]:-}" in
        plan|validate)
          policy_suffix="$(_verification_scope_policy_suffix 2)" || return 1
          printf 'terraform:%s%s\n' \
            "${argv[1]}" "${policy_suffix}"; return 0 ;;
      esac
      ;;
    ansible-lint)
      policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
      printf 'ansible-lint%s\n' "${policy_suffix}"
      return 0
      ;;
    helm)
      [[ "${argv[1]:-}" == "lint" ]] \
        && { policy_suffix="$(_verification_scope_policy_suffix 2)" \
            || return 1; printf 'helm-lint%s\n' "${policy_suffix}"; return 0; }
      ;;
  esac

  if [[ -n "${family}" ]]; then
    [[ "${family}" != "pytest" ]] || selector_mode="pytest-selector"
    for ((idx=start; idx<${#argv[@]}; idx++)); do
      token="${argv[${idx}]}"
      [[ -n "${token}" ]] || continue
      if [[ "${token}" == "--" ]]; then
        if [[ "${family}" == "go-test" ]]; then
          selector_ambiguous=1
        else
          selector_ambiguous=0
        fi
        options_ended=1
        continue
      fi
      if [[ "${options_ended}" -eq 0 && "${token}" == -* ]]; then
        case "${token}" in
          -q|-v|-s|-x|-vv|-race|-short|-failfast|-json|--quiet|--verbose|--silent|--ci|--runInBand|--run-in-band|--release|--workspace|--all|--all-targets|--tests|--benches|--examples|--lib|--bins|--doc|--no-fail-fast|--disable-warnings|--strict-markers|--strict-config|--lf|--ff|--nf|--cache-clear)
            ;;
          *)
            selector_ambiguous=1
            selectors=()
            ;;
        esac
        continue
      fi
      # An unknown option can consume a path-shaped value. Once encountered,
      # collapse to the runner family until an explicit `--` boundary rather
      # than letting `--opaque /tmp/Q-001` manufacture target independence.
      [[ "${selector_ambiguous}" -eq 0 ]] || continue
      # Pytest defines every positional operand as a file/directory/node
      # selector; a plain directory such as `unit` must not collapse to the
      # broad `pytest` identity. Other runners retain only path-shaped tokens
      # because their positional grammars also contain opaque labels.
      selector_candidate=0
      if [[ "${family}" == "pytest" ]]; then
        selector_candidate=1
      else
        case "${token}" in
          */*|.*|*::*|*.py|*.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.rs|*.go|*.swift)
            selector_candidate=1 ;;
        esac
      fi
      if [[ "${selector_candidate}" -eq 1 ]]; then
        normalized_selector="$(_verification_normalize_proof_path \
          "$(_verification_argv_path_token "${idx}")" 0 \
          "${selector_mode}")" || return 1
        [[ -n "${normalized_selector}" ]] || return 1
        duplicate=0
        if [[ "${#selectors[@]}" -gt 0 ]]; then
          for existing in "${selectors[@]}"; do
            [[ "${existing}" == "${normalized_selector}" ]] \
              && duplicate=1 && break
          done
        fi
        [[ "${duplicate}" -eq 1 ]] \
          || selectors+=("${normalized_selector}")
      fi
    done
    if [[ "${#selectors[@]}" -eq 0 ]]; then
      printf '%s\n' "${family}"
    else
      # Selector ordering cannot manufacture a new observation identity. A
      # project whose order is a semantic mode must expose a named verifier
      # target, just like other opaque runner modes.
      target=""
      while IFS= read -r normalized_selector; do
        target="${target:+${target}|}${normalized_selector}"
      done < <(printf '%s\n' "${selectors[@]}" | LC_ALL=C sort -u)
      printf '%s:%s\n' "${family}" "${target}"
    fi
    return 0
  fi

  # Named wrappers and direct executables normalize the executable spelling;
  # the policy suffix binds their admitted argv without granting independent
  # cross-criterion scope.
  target="$(_verification_resolve_executable_path "${first}")" || return 1
  [[ -n "${target}" ]] || return 1
  policy_suffix="$(_verification_scope_policy_suffix 1)" || return 1
  printf 'executable:%s%s\n' "${target}" "${policy_suffix}"
}

verification_command_semantic_target() {
  local command_text="${1:-}" project_test_cmd="${2:-}"
  local surface="" first="" family="" launcher="" canonical_family=""
  local project_root=""
  surface="$(_verification_command_semantic_target_unbound \
    "${command_text}" "${project_test_cmd}")" || return 1
  _verification_tokenize_argv "${command_text}" || return 1
  _verification_strip_literal_env_prefix || return 1
  [[ "${_VERIFICATION_HAD_ENV_PREFIX:-0}" -eq 0 ]] || return 1
  first="$(_verification_argv_path_token 0)" || return 1
  family="$(_verification_executable_family_name \
    "${first}" 2>/dev/null || true)"
  [[ -n "${family}" ]] || return 1
  case "${family}" in
    bash|zsh|sh)
      # Interpreter-launched named scripts intentionally share the script
      # proof surface with direct execution, but only through the shell family
      # the current environment actually resolves. An explicit fake `bash`
      # path may not borrow that identity.
      canonical_family="$(_verification_resolve_executable_path \
        "${family}" 2>/dev/null || true)"
      [[ -n "${canonical_family}" ]] || return 1
      launcher="$(_verification_resolve_executable_path "${first}")" \
        || return 1
      [[ "${launcher}" == "${canonical_family}" ]] || return 1
      printf '%s\n' "${surface}"
      ;;
    *)
      if [[ "${surface}" == executable:* ]]; then
        # A named direct verifier already binds its canonical executable path.
        printf '%s\n' "${surface}"
      else
        launcher="$(_verification_resolve_executable_path "${first}")" \
          || return 1
        if [[ "${family}" == "gradlew" ]]; then
          project_root="$(git rev-parse --show-toplevel 2>/dev/null \
            || pwd -P 2>/dev/null || true)"
          [[ -n "${project_root}" && -f "${project_root}/gradlew" \
              && -x "${project_root}/gradlew" ]] || return 1
          canonical_family="$(_verification_normalize_proof_path \
            "${project_root}/gradlew" 0 executable)" || return 1
        else
          canonical_family="$(_verification_resolve_executable_path \
            "${family}" 2>/dev/null || true)"
          [[ -n "${canonical_family}" ]] || return 1
        fi
        # Binding is an admission check, not part of the semantic proof
        # surface: approved aliases such as pytest vs `python -m pytest`, npm
        # vs pnpm, and gradle vs the repository wrapper still collapse. An
        # explicit fake launcher cannot borrow that shared surface.
        [[ "${launcher}" == "${canonical_family}" ]] || return 1
        printf '%s\n' "${surface}"
      fi
      ;;
  esac
}

_verification_directory_has_exact_entry() {
  local directory="${1:-}" needle="${2:-}" entry=""
  [[ -d "${directory}" && -n "${needle}" ]] || return 1
  for entry in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    [[ "${entry##*/}" == "${needle}" ]] && return 0
  done
  return 1
}

_verification_directory_case_insensitive() {
  local probe="${1:-}" parent="" leaf="" alternate="" entry=""
  local probe_device="" parent_device=""
  [[ -d "${probe}" ]] || return 1
  probe="$(cd "${probe}" 2>/dev/null && pwd -P)" || return 1

  # Probe a direct child first. Lookup happens inside the target filesystem,
  # while the exact-name scan distinguishes a case-insensitive alias from two
  # case-variant hardlinks on a case-sensitive volume.
  for entry in "${probe}"/* "${probe}"/.[!.]* "${probe}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    leaf="${entry##*/}"
    alternate="$(printf '%s' "${leaf}" \
      | tr '[:lower:][:upper:]' '[:upper:][:lower:]')"
    [[ "${alternate}" != "${leaf}" ]] || continue
    # On a case-sensitive filesystem the alternate lookup normally fails.
    # Test that O(1) condition before scanning exact directory entries; doing
    # the full scan first turns a large Linux directory into O(N²) work.
    if [[ ! -e "${probe}/${alternate}" \
        && ! -L "${probe}/${alternate}" ]]; then
      return 1
    fi
    _verification_directory_has_exact_entry "${probe}" "${alternate}" \
      && continue
    if [[ -e "${probe}/${alternate}" \
        && "${probe}/${alternate}" -ef "${entry}" ]]; then
      return 0
    fi
  done

  if [[ "${probe}" != "/" ]]; then
    parent="${probe%/*}"; [[ -n "${parent}" ]] || parent="/"
    leaf="${probe##*/}"
    # The basename lookup is valid only when parent and child are on the same
    # device. Walking to an ancestor crosses mount boundaries and incorrectly
    # imports a case-insensitive macOS root policy into a case-sensitive APFS
    # development volume mounted beneath it.
    probe_device="$(stat -c '%d' "${probe}" 2>/dev/null)" \
      || probe_device="$(stat -f '%d' "${probe}" 2>/dev/null)" \
      || probe_device=""
    parent_device="$(stat -c '%d' "${parent}" 2>/dev/null)" \
      || parent_device="$(stat -f '%d' "${parent}" 2>/dev/null)" \
      || parent_device=""
    if [[ -n "${probe_device}" && "${probe_device}" == "${parent_device}" ]]; then
      alternate="$(printf '%s' "${leaf}" \
        | tr '[:lower:][:upper:]' '[:upper:][:lower:]')"
      if [[ "${alternate}" != "${leaf}" ]] \
          && ! _verification_directory_has_exact_entry \
            "${parent}" "${alternate}" \
          && [[ -e "${parent}/${alternate}" \
            && "${parent}/${alternate}" -ef "${probe}" ]]; then
        return 0
      fi
    fi
  fi
  return 1
}

_verification_normalize_proof_path() {
  local value="${1:-}" depth="${2:-0}" mode="${3:-content}"
  local suffix="" prefix="" tilde_char=$'~'
  local control_stripped=""
  local component="" joined="" idx=0 candidate="" link="" resolved=""
  local parent="" leaf="" physical_parent="" canonical_leaf=""
  local probe="" unresolved_component="" case_insensitive=0 component_bytes=0
  local link_count=""
  local -a parts=() stack=() unresolved=()
  (( depth < 16 )) || return 1
  # grep is line-oriented: it cannot expose LF itself to `[[:cntrl:]]`, and
  # the later `read -a` would then silently retain only the first line. Strip
  # every representable ASCII control byte and compare the exact shell value
  # before any line-oriented parser can see it. (Bash variables cannot contain
  # NUL, so bytes 1-31 and DEL cover every representable control byte.)
  control_stripped="$(LC_ALL=C printf '%s' "${value}" \
    | LC_ALL=C tr -d '\001-\037\177')"
  [[ "${control_stripped}" == "${value}" ]] || return 1
  case "${value}" in
    "${tilde_char}") value="${HOME}" ;;
    "${tilde_char}/"*) value="${HOME}/${value#"${tilde_char}"/}" ;;
    "${tilde_char}"*) return 1 ;; # ~user expansion is environment-owned.
  esac
  if [[ "${mode}" == "pytest-selector" && "${value}" == *::* ]]; then
    suffix="::${value#*::}"
    value="${value%%::*}"
  fi
  [[ "${value}" == /* ]] && prefix="/"
  IFS='/' read -r -a parts <<<"${value}"
  for component in "${parts[@]}"; do
    component_bytes="$(printf '%s' "${component}" \
      | LC_ALL=C wc -c | tr -d '[:space:]')"
    [[ "${component_bytes}" =~ ^[0-9]+$ \
        && "${component_bytes}" -le 255 ]] || return 1
    case "${component}" in
      ''|.) ;;
      ..)
        if [[ "${#stack[@]}" -gt 0 && "${stack[$((${#stack[@]} - 1))]}" != ".." ]]; then
          unset "stack[$((${#stack[@]} - 1))]"
        elif [[ -z "${prefix}" ]]; then
          stack+=("..")
        fi
        ;;
      *) stack+=("${component}") ;;
    esac
  done
  if [[ "${#stack[@]}" -gt 0 ]]; then
    joined="${stack[0]}"
    for ((idx=1; idx<${#stack[@]}; idx++)); do joined="${joined}/${stack[${idx}]}"; done
  fi
  candidate="${prefix}${joined:-.}"
  if [[ -L "${candidate}" ]]; then
    link="$(readlink "${candidate}" 2>/dev/null)" || return 1
    if [[ "${link}" != /* ]]; then
      parent="${candidate%/*}"
      [[ "${parent}" != "${candidate}" ]] || parent="."
      link="${parent}/${link}"
    fi
    resolved="$(_verification_normalize_proof_path \
      "${link}" "$((depth + 1))" "${mode}")" || return 1
    printf '%s%s\n' "${resolved}" "${suffix}"
    return 0
  fi
  if [[ -e "${candidate}" ]]; then
    if [[ -d "${candidate}" ]]; then
      resolved="$(cd "${candidate}" 2>/dev/null && pwd -P)" || return 1
      _verification_directory_case_insensitive "${resolved}" \
        && resolved="$(printf '%s' "${resolved}" | tr '[:upper:]' '[:lower:]')"
      printf '%s%s\n' "${resolved}" "${suffix}"
      return 0
    fi
    if [[ "${mode}" == "source" ]]; then
      link_count="$(stat -c '%h' "${candidate}" 2>/dev/null)" \
        || link_count="$(stat -f '%l' "${candidate}" 2>/dev/null)" \
        || link_count=""
      # Two path spellings for one inode cannot be made independently
      # observable by Read/Grep. Reject multiply-linked source files instead
      # of letting cross-directory hardlinks split one proof surface.
      [[ "${link_count}" =~ ^[0-9]+$ && "${link_count}" -eq 1 ]] \
        || return 1
    fi
    parent="${candidate%/*}"
    leaf="${candidate##*/}"
    [[ "${parent}" != "${candidate}" ]] || parent="."
    physical_parent="$(cd "${parent}" 2>/dev/null && pwd -P)" || return 1
    # `pwd -P` canonicalizes only the parent. On a case-insensitive volume the
    # raw leaf can still be an alias (FOO.sh vs foo.sh); hardlinks present the
    # same identity problem. Select the stable directory entry that is `-ef`
    # the executed target without depending on non-portable realpath/stat
    # flags.
    canonical_leaf="$(
      cd "${parent}" 2>/dev/null || exit 1
      shopt -s dotglob nullglob
      if [[ "${mode}" == "executable" ]]; then
        # Multicall executables may be hardlinked but select different behavior
        # from argv[0]. Preserve an exact entry; only a missing spelling may
        # fall back to its case alias on a case-insensitive volume.
        for component in *; do
          if [[ "${component}" == "${leaf}" ]]; then
            printf '%s' "${component}"
            exit 0
          fi
        done
      fi
      for component in *; do
        if [[ "${component}" -ef "${leaf}" ]] \
            && { [[ "${mode}" != "executable" ]] \
              || [[ "$(printf '%s' "${component}" | tr '[:upper:]' '[:lower:]')" \
                == "$(printf '%s' "${leaf}" | tr '[:upper:]' '[:lower:]')" ]]; }; then
          printf '%s' "${component}"
          break
        fi
      done
    )" || return 1
    [[ -n "${canonical_leaf}" ]] || return 1
    resolved="${physical_parent%/}/${canonical_leaf}"
    _verification_directory_case_insensitive "${physical_parent}" \
      && resolved="$(printf '%s' "${resolved}" | tr '[:upper:]' '[:lower:]')"
    printf '%s%s\n' "${resolved}" "${suffix}"
    return 0
  fi

  # Canonicalize the longest existing parent even when the planned target does
  # not exist yet. Otherwise relative/physical aliases and case variants can
  # freeze as distinct proof targets, then collapse after the verifier file is
  # created and make the contract impossible to complete.
  probe="${candidate}"
  while [[ ! -d "${probe}" ]]; do
    unresolved_component="${probe##*/}"
    [[ -n "${unresolved_component}" && "${unresolved_component}" != "." ]] \
      || return 1
    if [[ "${#unresolved[@]}" -eq 0 ]]; then
      unresolved=("${unresolved_component}")
    else
      unresolved=("${unresolved_component}" "${unresolved[@]}")
    fi
    parent="${probe%/*}"
    [[ "${parent}" != "${probe}" ]] || parent="."
    probe="${parent}"
  done
  physical_parent="$(cd "${probe}" 2>/dev/null && pwd -P)" || return 1
  _verification_directory_case_insensitive "${physical_parent}" \
    && case_insensitive=1
  resolved="${physical_parent%/}"
  for unresolved_component in "${unresolved[@]}"; do
    if [[ "${case_insensitive}" -eq 1 ]]; then
      unresolved_component="$(printf '%s' "${unresolved_component}" \
        | tr '[:upper:]' '[:lower:]')"
    fi
    resolved="${resolved}/${unresolved_component}"
  done
  [[ "${case_insensitive}" -eq 0 ]] \
    || resolved="$(printf '%s' "${resolved}" | tr '[:upper:]' '[:lower:]')"
  printf '%s%s\n' "${resolved}" "${suffix}"
}

# --- end verification helpers ---
