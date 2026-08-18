#!/usr/bin/env bats
# =============================================================================
# Tests for authorization.sh - deployment authorization (+ provenance digest)
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    source_iltero_core "authorization.sh"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

# Install a fake `iltero` that records its argv and exits with the given code.
# The deploy gate refuses to run a binary it cannot identify, so the recorded
# path is set as well as PATH — see verify_authorization.
_mock_iltero_authz() {
    local exit_code="${1:-0}"
    cat > "${TEST_TEMP}/iltero" <<EOF
#!/bin/bash
echo "iltero \$*" >> "${TEST_TEMP}/iltero.log"
exit ${exit_code}
EOF
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero"
}

HEX_DIGEST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

@test "verify_authorization requires run_id" {
    _mock_iltero_authz 0
    run verify_authorization "" "stack-1" "prod" "unit-x"
    assert_exit_code 2
}

@test "verify_authorization requires stack_id" {
    _mock_iltero_authz 0
    run verify_authorization "run-1" "" "prod" "unit-x"
    assert_exit_code 2
}

@test "verify_authorization returns 0 when the CLI authorizes" {
    _mock_iltero_authz 0
    run verify_authorization "run-1" "stack-1" "prod" "unit-x"
    assert_exit_code 0
}

@test "verify_authorization returns 1 when the CLI blocks (exit 10)" {
    _mock_iltero_authz 10
    run verify_authorization "run-1" "stack-1" "prod" "unit-x"
    assert_exit_code 1
}

@test "verify_authorization maps auth failure (exit 2) to error" {
    _mock_iltero_authz 2
    run verify_authorization "run-1" "stack-1" "prod" "unit-x"
    assert_exit_code 2
}

@test "verify_authorization does NOT pass --plan-digest when none is given" {
    _mock_iltero_authz 0
    verify_authorization "run-1" "stack-1" "prod" "unit-x"
    ! grep -q -- "--plan-digest" "${TEST_TEMP}/iltero.log"
}

@test "verify_authorization never forwards --environment (CLI reads env from OIDC claims)" {
    # Regression: forwarding --environment makes `authorize-deployment` exit 2
    # (unknown option), silently disabling the deploy gate. The env arg ($3) is
    # accepted for caller compat but must NOT reach the CLI.
    _mock_iltero_authz 0
    verify_authorization "run-1" "stack-1" "prod" "unit-x"
    ! grep -q -- "--environment" "${TEST_TEMP}/iltero.log"
}

@test "verify_authorization passes the digest and version when provided" {
    _mock_iltero_authz 0
    verify_authorization "run-1" "stack-1" "prod" "unit-x" "${HEX_DIGEST}" "1"
    grep -q -- "--plan-digest ${HEX_DIGEST}" "${TEST_TEMP}/iltero.log"
    grep -q -- "--canonicalization-version 1" "${TEST_TEMP}/iltero.log"
}

@test "verify_authorization omits the version flag when only a digest is given" {
    _mock_iltero_authz 0
    verify_authorization "run-1" "stack-1" "prod" "unit-x" "${HEX_DIGEST}" ""
    grep -q -- "--plan-digest ${HEX_DIGEST}" "${TEST_TEMP}/iltero.log"
    ! grep -q -- "--canonicalization-version" "${TEST_TEMP}/iltero.log"
}
