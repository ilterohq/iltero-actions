#!/usr/bin/env bats
# =============================================================================
# Tests for the static-scan verdict — SCAN_STATUS and the waiver rule
# =============================================================================
# A compliance run ends one of three ways: it passed, it found violations, or
# it could not determine compliance at all. block_on_violations lets an operator
# accept the second. These tests pin that it can never accept the third.
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "${GITHUB_OUTPUT}"
    touch "${GITHUB_STEP_SUMMARY}"
    cd "${TEST_TEMP}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
}

# =============================================================================
# Helpers
# =============================================================================

# Iltero CLI stub.
# Args: $1=exit code  $2="results" to write a results file, anything else not to
_stub_cli() {
    export STUB_EXIT="${1}"
    export STUB_WRITE_RESULTS="${2:-none}"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"

    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
if [[ "${STUB_WRITE_RESULTS}" == "results" && -n "${of}" ]]; then
    cat > "${of}" << 'JSON'
{"run_id":"r1","scan_id":"s1","violations_count":3,
 "violations":[{"severity":"critical"},{"severity":"high"},{"severity":"low"}]}
JSON
fi
exit "${STUB_EXIT}"
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"

    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
}

_run_scan() {
    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "" || true
}

# =============================================================================
# SCAN_STATUS derivation — the exit code decides first
# =============================================================================

@test "scanning: exit 0 is a pass" {
    _stub_cli 0 results
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "pass" ]
    [ "${SCAN_PASSED}" = "true" ]
}

@test "scanning: exit 1 with recorded results is a violations verdict" {
    _stub_cli 1 results
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "violations" ]
    [ "${SCAN_PASSED}" = "false" ]
    [ "${SCAN_VIOLATIONS}" = "3" ]
}

@test "scanning: exit 1 with no results file is an infra error, not violations" {
    # The CLI uses exit 1 both for findings and for "could not start" (no
    # workspace configured). Only the first wrote results.
    _stub_cli 1 none
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "infra_error" ]
    [ "${SCAN_PASSED}" = "false" ]
}

@test "scanning: exit 3 is an infra error even when a results file exists" {
    # Pins exit-code-first ordering. A partially written results file must not
    # promote a refusal into a compliance verdict.
    _stub_cli 3 results
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "infra_error" ]
}

@test "scanning: exit 2 is an infra error" {
    _stub_cli 2 none
    source_iltero_core "scanning.sh"
    _run_scan
    [ "${SCAN_STATUS}" = "infra_error" ]
}

@test "scanning: exit 4 is an infra error" {
    _stub_cli 4 none
    source_iltero_core "scanning.sh"
    _run_scan
    [ "${SCAN_STATUS}" = "infra_error" ]
}

@test "scanning: exit 5 is an infra error" {
    _stub_cli 5 none
    source_iltero_core "scanning.sh"
    _run_scan
    [ "${SCAN_STATUS}" = "infra_error" ]
}

# =============================================================================
# Rendering — an infra error must not read as a zero-finding compliance failure
# =============================================================================

@test "scanning: an infra error never prints a finding count" {
    _stub_cli 3 none
    source_iltero_core "scanning.sh"

    output="$(_run_scan 2>&1)"

    [[ "${output}" == *"no compliance verdict"* ]] || return 1
    # The two shapes that made exit 3 read as "FAIL — 0 findings".
    [[ "${output}" != *"findings at or above"* ]] || return 1
    [[ "${output}" != *"Findings: 0 total"* ]] || return 1
}

@test "scanning: an infra error is not tagged FAIL" {
    _stub_cli 3 none
    source_iltero_core "scanning.sh"

    output="$(_run_scan 2>&1)"

    [[ "${output}" == *"[ERROR]"* ]]
    [[ "${output}" != *"[FAIL]"* ]]
}

@test "scanning: a violations verdict still reports its finding count" {
    _stub_cli 1 results
    source_iltero_core "scanning.sh"

    output="$(_run_scan 2>&1)"

    [[ "${output}" == *"[FAIL]"* ]]
    [[ "${output}" == *"at or above"* ]]
}

# =============================================================================
# The waiver rule — block_on_violations may accept findings, nothing else
# =============================================================================

@test "verdict: an infra error is NOT waived by block_on_violations=false" {
    source_iltero_core "scanning.sh"
    apply_static_scan_verdict "infra_error" "false"

    [ "${SCAN_GATE_BLOCK}" = "true" ]
    [ "${SCAN_GATE_REASON}" = "scan_error" ]
}

@test "verdict: violations ARE waived by block_on_violations=false" {
    source_iltero_core "scanning.sh"
    apply_static_scan_verdict "violations" "false"

    [ "${SCAN_GATE_BLOCK}" = "false" ]
    [ "${SCAN_GATE_REASON}" = "static_scan_failed" ]
}

@test "verdict: violations block when block_on_violations=true" {
    source_iltero_core "scanning.sh"
    apply_static_scan_verdict "violations" "true"

    [ "${SCAN_GATE_BLOCK}" = "true" ]
}

@test "verdict: an empty status fails closed" {
    source_iltero_core "scanning.sh"
    apply_static_scan_verdict "" "false"

    [ "${SCAN_GATE_BLOCK}" = "true" ]
}

@test "verdict: an unrecognised status fails closed" {
    source_iltero_core "scanning.sh"
    apply_static_scan_verdict "something_new" "false"

    [ "${SCAN_GATE_BLOCK}" = "true" ]
}

# =============================================================================
# Action output
# =============================================================================

@test "scanning: set_scan_outputs writes the status it was given" {
    # Uses a value that is NOT the fail-closed default, so a hardcoded
    # "infra_error" in the helper cannot pass this test.
    source_iltero_core "index.sh"
    SCAN_PASSED="false"
    SCAN_STATUS="violations"
    SCAN_RUN_ID=""
    SCAN_VIOLATIONS="3"

    set_scan_outputs

    grep -q "status=violations" "${GITHUB_OUTPUT}"
}

@test "scanning: set_scan_outputs defaults to infra_error when status is unset" {
    source_iltero_core "index.sh"
    SCAN_PASSED="false"
    unset SCAN_STATUS
    SCAN_RUN_ID=""
    SCAN_VIOLATIONS="0"

    set_scan_outputs

    grep -q "status=infra_error" "${GITHUB_OUTPUT}"
}

@test "scanning: exit 1 with an empty results file is an infra error" {
    # A truncated or zero-byte file must not promote a scan that never ran into
    # a waivable verdict reporting zero findings.
    _stub_cli 1 none
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && : > "${of}"
exit 1
STUB
    chmod +x "${TEST_TEMP}/iltero"
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "infra_error" ]
}

@test "scanning: exit 1 with an unparsable results file is an infra error" {
    _stub_cli 1 none
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && printf '{"violations": [' > "${of}"
exit 1
STUB
    chmod +x "${TEST_TEMP}/iltero"
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "infra_error" ]
}

# =============================================================================
# A run that produced no verdict must say why, not prescribe a re-run
# =============================================================================
# The generic "did not complete" message describes a transient failure. The
# states that reach it — a missing scanner, unfetchable policies — reproduce
# identically on every re-run, so the tool's own last line is what the reader
# needs.

@test "last_diagnostic_line returns the last non-blank line" {
    source_iltero_core "utils.sh"
    local f="${BATS_TEST_TMPDIR}/log"
    printf 'Resolving policies\nPolicy bundle could not be fetched\n\n\n' > "${f}"

    run last_diagnostic_line "${f}"

    [ "${output}" = "Policy bundle could not be fetched" ]
}

@test "last_diagnostic_line yields one line, so it cannot be read as a command" {
    source_iltero_core "utils.sh"
    local f="${BATS_TEST_TMPDIR}/log"
    printf 'first\n::error::injected\nlast line\n' > "${f}"

    run last_diagnostic_line "${f}"

    [ "$(printf '%s' "${output}" | wc -l | tr -d ' ')" -eq 0 ]
    [ "${output}" = "last line" ]
}

@test "last_diagnostic_line is silent for a missing or empty log" {
    source_iltero_core "utils.sh"
    run last_diagnostic_line "${BATS_TEST_TMPDIR}/does-not-exist"
    [ -z "${output}" ]

    : > "${BATS_TEST_TMPDIR}/empty"
    run last_diagnostic_line "${BATS_TEST_TMPDIR}/empty"
    [ -z "${output}" ]
}

@test "last_diagnostic_line strips carriage returns" {
    source_iltero_core "utils.sh"
    local f="${BATS_TEST_TMPDIR}/log"
    printf 'progress\r\nfinal answer\r\n' > "${f}"

    run last_diagnostic_line "${f}"

    [ "${output}" = "final answer" ]
}

@test "scanning: a run with no verdict reports what the scan actually said" {
    # The case this exists for: a cause that reproduces on every attempt.
    # Re-running fails identically, so the generic "did not complete — re-run"
    # is both loud and wrong. The scan's own last line names the cause.
    export STUB_EXIT=6
    export STUB_WRITE_RESULTS=none
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
echo "Resolving policies"
echo "Policy bundle could not be fetched" >&2
exit 6
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"

    source_iltero_core "scanning.sh"
    _run_scan > "${TEST_TEMP}/scan-out.txt" 2>&1

    [ "${SCAN_STATUS}" = "infra_error" ]
    grep -q "Policy bundle could not be fetched" "${TEST_TEMP}/scan-out.txt"
    # Never prescribe a re-run for a state that reproduces every time.
    ! grep -q "Re-run" "${TEST_TEMP}/scan-out.txt"
}

@test "scanning: an unrecognised exit code still blocks and is not waivable" {
    # Any code other than 0, or 1-with-results, is "no verdict was produced".
    # An unrecognised one must land there without this repository
    # having to be changed first.
    _stub_cli 6 none
    source_iltero_core "scanning.sh"
    _run_scan

    [ "${SCAN_STATUS}" = "infra_error" ]

    apply_static_scan_verdict "${SCAN_STATUS}" "false"
    [ "${SCAN_GATE_BLOCK}" = "true" ]
    [ "${SCAN_GATE_REASON}" = "scan_error" ]
}

# =============================================================================
# Opting in to failing on an unevaluated compliance framework
# =============================================================================
# The scanner reports a framework it did not evaluate either way; the flag
# decides whether that stops the run. Off by default, matching the scanner: a
# shortfall can also mean Iltero has no policy content for that framework yet.

# CLI stub that records the arguments it was given.
_stub_cli_recording_argv() {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    export ARGV_FILE="${TEST_TEMP}/argv"
    : > "${ARGV_FILE}"
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "${ARGV_FILE}"
exit 0
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
}

@test "scanning: the strict framework scope flag is not sent by default" {
    _stub_cli_recording_argv
    source_iltero_core "scanning.sh"
    _run_scan

    ! grep -qx -- '--strict-framework-scope' "${ARGV_FILE}"
}

@test "scanning: the strict framework scope flag is sent when opted in" {
    _stub_cli_recording_argv
    export STRICT_FRAMEWORK_SCOPE="true"
    source_iltero_core "scanning.sh"
    _run_scan

    grep -qx -- '--strict-framework-scope' "${ARGV_FILE}"
}

@test "scanning: any value other than true leaves the flag off" {
    # A gate must not be switched on by a typo, nor off by one.
    local v
    for v in "false" "TRUE" "1" "yes" ""; do
        _stub_cli_recording_argv
        export STRICT_FRAMEWORK_SCOPE="${v}"
        source_iltero_core "scanning.sh"
        _run_scan
        grep -qx -- '--strict-framework-scope' "${ARGV_FILE}" && {
            echo "value '${v}' turned the flag on"
            return 1
        }
    done
    return 0
}
