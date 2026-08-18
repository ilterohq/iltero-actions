#!/usr/bin/env bats
# =============================================================================
# Tests for log_result — the verdict tag must survive to the log
# =============================================================================
# log_result previously printed [FAIL] for anything that was not literally
# "PASS", so an operational error and a compliance failure were indistinguishable
# in the output an operator reads.
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    source "${LIB_DIR}/logging.sh"
    # Take the GitHub Actions branch: plain tags, no colour escapes to strip.
    export GITHUB_ACTIONS="true"
}

teardown() {
    rm -rf "${TEST_TEMP}"
}

@test "log_result renders PASS" {
    run log_result "PASS" "all good"
    [ "${status}" -eq 0 ]
    [ "${output}" = "[PASS] all good" ]
}

@test "log_result renders FAIL" {
    run log_result "FAIL" "3 findings"
    [ "${output}" = "[FAIL] 3 findings" ]
}

@test "log_result renders ERROR as ERROR, not FAIL" {
    run log_result "ERROR" "did not complete"
    [ "${output}" = "[ERROR] did not complete" ]
}

@test "log_result renders NEEDS_REVIEW as itself, not FAIL" {
    # The evaluation path already emits this tag; it was being shown as [FAIL].
    run log_result "NEEDS_REVIEW" "nothing was evaluated"
    [ "${output}" = "[NEEDS_REVIEW] nothing was evaluated" ]
}
