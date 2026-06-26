#!/usr/bin/env bats
# =============================================================================
# Tests for notify_apply_result (deployment.sh) — the `iltero scan apply` call.
# The CLI derives the applied-resource breakdown from the `terraform apply -json`
# NDJSON stream, so the runner forwards --apply-json (not a --resources-count total)
# on BOTH the success and failure paths.
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    source_iltero_core "deployment.sh"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

# Install a fake `iltero` that records its argv.
_mock_iltero() {
    cat > "${TEST_TEMP}/iltero" <<EOF
#!/bin/bash
echo "iltero \$*" >> "${TEST_TEMP}/iltero.log"
exit 0
EOF
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
}

@test "notify_apply_result forwards --apply-json and never --resources-count (success)" {
    _mock_iltero
    local apply_json="${TEST_TEMP}/apply.jsonl"
    echo '{}' > "${apply_json}"
    notify_apply_result "run-1" "scan-1" "unit-x" "prod" "true" "${apply_json}" ""
    grep -q -- "--apply-json ${apply_json}" "${TEST_TEMP}/iltero.log"
    grep -q -- "--success" "${TEST_TEMP}/iltero.log"
    grep -q -- "--scan-id scan-1" "${TEST_TEMP}/iltero.log"
    grep -q -- "--environment prod" "${TEST_TEMP}/iltero.log"
    ! grep -q -- "--resources-count" "${TEST_TEMP}/iltero.log"
}

@test "notify_apply_result forwards --apply-json with --failed on a partial failure" {
    _mock_iltero
    local apply_json="${TEST_TEMP}/apply.jsonl"
    echo '{}' > "${apply_json}"
    notify_apply_result "run-1" "scan-1" "unit-x" "prod" "false" "${apply_json}" ""
    grep -q -- "--failed" "${TEST_TEMP}/iltero.log"
    grep -q -- "--apply-json ${apply_json}" "${TEST_TEMP}/iltero.log"
}

@test "notify_apply_result skips the call entirely when run_id is empty" {
    _mock_iltero
    notify_apply_result "" "scan-1" "unit-x" "prod" "true" "" ""
    [[ ! -f "${TEST_TEMP}/iltero.log" ]]
}
