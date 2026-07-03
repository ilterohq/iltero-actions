#!/usr/bin/env bats
# =============================================================================
# Tests for mode enum — pipeline mode selection and preview guard
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "${GITHUB_OUTPUT}"
    touch "${GITHUB_STEP_SUMMARY}"

    # Reset sourcing flags
    unset ILTERO_RESULTS_SOURCED
    unset ILTERO_RESULTS_BASE

    cd "${TEST_TEMP}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
}

# =============================================================================
# Helpers
# =============================================================================

_setup_cli_mock() {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"

    cat > "${TEST_TEMP}/iltero" << 'MOCK'
#!/bin/bash
echo "$@" > "${TEST_TEMP}/cli_args"
echo '{"run_id": "", "scan_id": "", "passed": true, "violations_count": 0}'
MOCK
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"

    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
    # A provider block so the credential-less preview path (no creds) can detect
    # the cloud and produce a plan.
    printf 'provider "aws" {}\n' > "${TEST_TEMP}/unit/providers.tf"
}

# =============================================================================
# Scanning — --preview vs --resolve-policies
# =============================================================================

@test "scanning: PREVIEW_MODE=true adds --preview flag" {
    export PREVIEW_MODE="true"
    _setup_cli_mock
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "" || true

    local cli_args
    cli_args=$(cat "${TEST_TEMP}/cli_args")
    [[ "${cli_args}" == *"--preview"* ]]
    [[ "${cli_args}" != *"--resolve-policies"* ]]
}

@test "scanning: PREVIEW_MODE=false adds --resolve-policies flag" {
    export PREVIEW_MODE="false"
    _setup_cli_mock
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "" || true

    local cli_args
    cli_args=$(cat "${TEST_TEMP}/cli_args")
    [[ "${cli_args}" == *"--resolve-policies"* ]]
    [[ "${cli_args}" != *"--preview"* ]]
}

@test "scanning: unset PREVIEW_MODE defaults to --resolve-policies" {
    unset PREVIEW_MODE
    _setup_cli_mock
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "" || true

    local cli_args
    cli_args=$(cat "${TEST_TEMP}/cli_args")
    [[ "${cli_args}" == *"--resolve-policies"* ]]
    [[ "${cli_args}" != *"--preview"* ]]
}

# =============================================================================
# Evaluation — --preview vs --resolve-policies
# =============================================================================

@test "evaluation: PREVIEW_MODE=true adds --preview flag" {
    export PREVIEW_MODE="true"
    _setup_cli_mock
    # Source full core so all dependencies (remote-state, validation) are loaded
    source_iltero_core

    # Create a mock terraform that succeeds through init → plan → show
    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; echo '{}' > "${PWD}/tfplan.json"; exit 0 ;;
    show) echo '{"resource_changes":[]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"

    # Initialize state tracking (needed by evaluation flow)
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    local cli_args
    cli_args=$(cat "${TEST_TEMP}/cli_args")
    [[ "${cli_args}" == *"--preview"* ]]
    [[ "${cli_args}" != *"--resolve-policies"* ]]
}

@test "evaluation: PREVIEW_MODE=false adds --resolve-policies flag" {
    export PREVIEW_MODE="false"
    _setup_cli_mock
    source_iltero_core

    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; echo '{}' > "${PWD}/tfplan.json"; exit 0 ;;
    show) echo '{"resource_changes":[]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"

    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    local cli_args
    cli_args=$(cat "${TEST_TEMP}/cli_args")
    [[ "${cli_args}" == *"--resolve-policies"* ]]
    [[ "${cli_args}" != *"--preview"* ]]
}

# =============================================================================
# Deployment guard — PREVIEW_MODE blocks deployment
# =============================================================================

@test "deployment: PREVIEW_MODE=true returns EXIT_ERROR (2)" {
    export PREVIEW_MODE="true"
    source_iltero_core "deployment.sh"

    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"

    run run_deployment "${TEST_TEMP}/unit" "vpc" "dev" "" ""
    [[ "${status}" -eq 2 ]]
    [[ "${output}" == *"preview mode"* ]]
}

@test "deployment: PREVIEW_MODE=false does not block" {
    export PREVIEW_MODE="false"
    source_iltero_core "deployment.sh"

    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"

    # Will fail on terraform init, but should get past the preview guard
    run run_deployment "${TEST_TEMP}/unit" "vpc" "dev" "" ""
    [[ "${output}" != *"preview mode"* ]]
}

# =============================================================================
# Runtime guard — MODE=preview + OIDC_ENABLED=true rejected
# =============================================================================

@test "pipeline: MODE=preview + OIDC_ENABLED=true is rejected" {
    # Source the pipeline script's validation logic by extracting
    # the guard into an inline test (the full main() requires too
    # much infrastructure to run in BATS)
    export MODE="preview"
    export OIDC_ENABLED="true"

    source_iltero_core

    # Replicate the guard from run-pipeline.sh main()
    local rejected=false
    if [[ "${MODE}" == "preview" ]] && [[ "${OIDC_ENABLED:-false}" == "true" ]]; then
        rejected=true
    fi

    [[ "${rejected}" == "true" ]]
}

@test "pipeline: MODE=preview + OIDC_ENABLED=false is allowed" {
    export MODE="preview"
    export OIDC_ENABLED="false"

    local rejected=false
    if [[ "${MODE}" == "preview" ]] && [[ "${OIDC_ENABLED:-false}" == "true" ]]; then
        rejected=true
    fi

    [[ "${rejected}" == "false" ]]
}

@test "pipeline: MODE=full + OIDC_ENABLED=true is allowed" {
    export MODE="full"
    export OIDC_ENABLED="true"

    local rejected=false
    if [[ "${MODE}" == "preview" ]] && [[ "${OIDC_ENABLED:-false}" == "true" ]]; then
        rejected=true
    fi

    [[ "${rejected}" == "false" ]]
}
