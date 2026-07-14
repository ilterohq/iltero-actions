#!/usr/bin/env bats
# =============================================================================
# Tests for oidc-exchange.sh — stack-mode vs repo-mode scope selection
# =============================================================================
# The script picks exactly one scope (--stack-id or --workspace-id) from the
# env and forwards it to `iltero auth oidc`. A mock `iltero` echoes its args so
# we can assert which scope flag was passed. org-id is required in both modes.

load 'test_helper'

VALID_UUID="0b278217-a809-465a-b9df-00eda8414cb8"

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_ENV="${TEST_TEMP}/github_env"; touch "${GITHUB_ENV}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"; touch "${GITHUB_OUTPUT}"

    # Baseline required env for a successful exchange.
    export ILTERO_ORG_ID="${VALID_UUID}"
    export ILTERO_API_URL="https://api.iltero.io/v1"
    export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/request"

    # Start with no scope set; each test sets the one(s) it needs.
    unset ILTERO_STACK_ID ILTERO_WORKSPACE_ID INPUT_API_URL 2>/dev/null || true

    # Mock `iltero` that echoes its args (so we can assert the scope flag).
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<'EOF'
#!/bin/bash
echo "AUTH_OIDC_ARGS: $*"
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

_run_exchange() {
    run bash "${PROJECT_ROOT}/scripts/oidc-exchange.sh"
}

@test "oidc-exchange stack mode forwards --stack-id and --org-id" {
    export ILTERO_STACK_ID="${VALID_UUID}"
    _run_exchange
    assert_exit_code 0
    assert_output_contains "--stack-id"
    assert_output_contains "--org-id"   # backward-compat: rest of invocation intact
    [[ "${output}" != *"--workspace-id"* ]]
}

@test "oidc-exchange repo mode forwards --workspace-id" {
    export ILTERO_WORKSPACE_ID="${VALID_UUID}"
    _run_exchange
    assert_exit_code 0
    assert_output_contains "--workspace-id"
    [[ "${output}" != *"--stack-id"* ]]
}

@test "oidc-exchange rejects both stack-id and workspace-id" {
    export ILTERO_STACK_ID="${VALID_UUID}"
    export ILTERO_WORKSPACE_ID="${VALID_UUID}"
    _run_exchange
    assert_exit_code 1
    assert_output_contains "not both"
}

@test "oidc-exchange requires one of stack-id or workspace-id" {
    _run_exchange
    assert_exit_code 1
    assert_output_contains "is required"
}

@test "oidc-exchange treats an empty stack-id input as unset (repo mode wins)" {
    # Composite passes ILTERO_STACK_ID='' when the input is omitted.
    export ILTERO_STACK_ID=""
    export ILTERO_WORKSPACE_ID="${VALID_UUID}"
    _run_exchange
    assert_exit_code 0
    assert_output_contains "--workspace-id"
}

@test "oidc-exchange treats an empty workspace-id input as unset (stack mode wins)" {
    export ILTERO_STACK_ID="${VALID_UUID}"
    export ILTERO_WORKSPACE_ID=""
    _run_exchange
    assert_exit_code 0
    assert_output_contains "--stack-id"
}

@test "oidc-exchange rejects a non-UUID scope value before calling the CLI" {
    export ILTERO_WORKSPACE_ID="not-a-uuid"
    _run_exchange
    assert_exit_code 1
    assert_output_contains "not a valid UUID"
    [[ "${output}" != *"AUTH_OIDC_ARGS"* ]]   # CLI not invoked
}

@test "oidc-exchange still requires org-id in repo mode" {
    export ILTERO_WORKSPACE_ID="${VALID_UUID}"
    unset ILTERO_ORG_ID
    _run_exchange
    assert_exit_code 1
    assert_output_contains "ILTERO_ORG_ID"
}

@test "oidc-exchange derives and forwards the URL-host audience" {
    export ILTERO_WORKSPACE_ID="${VALID_UUID}"
    _run_exchange
    assert_exit_code 0
    assert_output_contains "--audience api.iltero.io"
}

@test "oidc-exchange fails loud without id-token permission" {
    export ILTERO_STACK_ID="${VALID_UUID}"
    unset ACTIONS_ID_TOKEN_REQUEST_URL
    _run_exchange
    assert_exit_code 1
    assert_output_contains "id-token: write"
}
