#!/usr/bin/env bash
#
# tests/lib/composition-stubs.sh — shared mk_stub / mk_json_stub helpers
# for the readiness-composer test family (test-professional-readiness,
# test-install-readiness, test-project-readiness, future composers).
#
# Why this exists (defect D12 from the post-91fc96b cumulative review):
# the same stub-emitter shape (write #!/usr/bin/env bash + cat-heredoc +
# exit code) was hand-rolled in four test files with minor variations.
# Each composer family that ships a new test will copy the pattern and
# the four-way divergence widens. The shared lib closes that drift
# surface — one schema change propagates atomically.
#
# Contract:
#   - TMP_DIR must be set by the caller (each test's own teardown trap
#     removes it). The lib does NOT manage tempdirs.
#   - mk_stub <name> <exit_code> <line> [<line>...] writes a stub script
#     that prints each <line> verbatim then exits <exit_code>.
#   - mk_json_stub <name> <result> <ok> <skip> <fail> <summary> <message>
#     <exit_code> writes a stub that prints the canonical readiness-JSON
#     envelope (`{tool, result, counts:{ok,skip,fail}, summary_text,
#     message}`) then exits.
#   - Both emit the absolute path of the stub script on stdout.

# shellcheck disable=SC2154  # TMP_DIR set by caller

mk_stub() {
  local name="$1" exit_code="$2"
  shift 2
  local path="${TMP_DIR}/${name}.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf "cat <<'EOF'\n"
    while [[ $# -gt 0 ]]; do
      printf '%s\n' "$1"
      shift
    done
    printf "EOF\n"
    printf 'exit %s\n' "${exit_code}"
  } > "${path}"
  chmod +x "${path}"
  printf '%s' "${path}"
}

mk_json_stub() {
  local name="$1" result="$2" ok="$3" skip="$4" fail_count="$5" summary="$6" message="$7" exit_code="$8"
  local path="${TMP_DIR}/${name}.sh"
  cat > "${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "tool": "${name}",
  "result": "${result}",
  "counts": {
    "ok": ${ok},
    "skip": ${skip},
    "fail": ${fail_count}
  },
  "summary_text": "${summary}",
  "message": "${message}"
}
JSON
exit ${exit_code}
EOF
  chmod +x "${path}"
  printf '%s' "${path}"
}
