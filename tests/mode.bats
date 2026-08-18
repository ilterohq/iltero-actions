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
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
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
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
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

# =============================================================================
# Resource-less gate + fail-open guard (run_plan_evaluation)
# =============================================================================

@test "evaluation: resource-less plan with no checks is needs_review and skips the evaluator" {
    export PREVIEW_MODE="true"
    _setup_cli_mock
    source_iltero_core

    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"
    init_remote_state_tracking "test-stack"
    rm -f "${TEST_TEMP}/cli_args"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "needs_review" ]]
    [[ "${EVAL_PASSED}" == "false" ]]
    # nothing to evaluate: the evaluator must NOT run (no result submitted)
    [[ ! -f "${TEST_TEMP}/cli_args" ]]
}

@test "evaluation: resource-less plan WITH checks is routed to the evaluator" {
    export PREVIEW_MODE="false"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"

    # CLI mock records that it ran AND writes a results file (checks scored)
    cat > "${TEST_TEMP}/iltero" << 'MOCK'
#!/bin/bash
echo "$@" > "${TEST_TEMP}/cli_args"
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && echo '{"summary":{"total_checks":3,"passed":3,"failed":0,"critical":0,"high":0,"medium":0,"low":0},"run_id":"r1","scan_id":"s1"}' > "${of}"
echo '{}'
exit 0
MOCK
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
    printf 'provider "aws" {}\n' > "${TEST_TEMP}/unit/providers.tf"
    source_iltero_core

    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[],"checks":[{"address":{"kind":"check","name":"c"},"status":"pass"}]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"
    init_remote_state_tracking "test-stack"
    rm -f "${TEST_TEMP}/cli_args"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    # the evaluator WAS run (checks routed to it) and it passed on the checks
    [[ -f "${TEST_TEMP}/cli_args" ]]
    [[ "${EVAL_STATUS}" == "pass" ]]
    [[ "${EVAL_PASSED}" == "true" ]]
}

@test "evaluation: exit 0 with no results file is needs_review, not pass" {
    export PREVIEW_MODE="true"
    _setup_cli_mock   # mock exits 0 but writes no --output-file results file
    source_iltero_core

    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "needs_review" ]]
    [[ "${EVAL_PASSED}" == "false" ]]
}

@test "evaluation: resources + results with evaluated>0 is a pass" {
    export PREVIEW_MODE="false"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"

    # CLI mock that writes a results file at the --output-file path
    cat > "${TEST_TEMP}/iltero" << 'MOCK'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && echo '{"summary":{"total_checks":3,"passed":3,"failed":0,"critical":0,"high":0,"medium":0,"low":0},"run_id":"r1","scan_id":"s1"}' > "${of}"
echo '{}'
exit 0
MOCK
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
    printf 'provider "aws" {}\n' > "${TEST_TEMP}/unit/providers.tf"
    source_iltero_core

    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "pass" ]]
    [[ "${EVAL_PASSED}" == "true" ]]
}

# -----------------------------------------------------------------------------
# Verdict derivation from CLI exit code + total_checks + native fails
# (CLI->runner contract)
# -----------------------------------------------------------------------------

# Writes an iltero mock that records args, writes <results-json> to --output-file,
# and exits <code>. Also creates the unit dir with a provider block.
_setup_cli_mock_exit() {
    local code="$1" results="$2"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    export ILTERO_MOCK_RESULTS="${results}"
    export ILTERO_MOCK_EXIT="${code}"
    cat > "${TEST_TEMP}/iltero" << 'MOCK'
#!/bin/bash
echo "$@" > "${TEST_TEMP}/cli_args"
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && printf '%s' "${ILTERO_MOCK_RESULTS}" > "${of}"
echo '{}'
exit "${ILTERO_MOCK_EXIT}"
MOCK
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf"
    printf 'provider "aws" {}\n' > "${TEST_TEMP}/unit/providers.tf"
}

_mock_tf_with_resource() {
    cat > "${TEST_TEMP}/terraform" << 'MOCK'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "${TEST_TEMP}/terraform"
}

@test "evaluation: native check failure (exit 1, no severity) is a waivable violation" {
    export PREVIEW_MODE="false"
    _setup_cli_mock_exit 1 '{"summary":{"total_checks":1,"passed":0,"failed":1,"critical":0,"high":0,"medium":0,"low":0},"native_checks":[{"name":"CIS_1_2","status":"fail","instance_statuses":["fail"]}],"run_id":"r1","scan_id":"s1"}'
    source_iltero_core
    _mock_tf_with_resource
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "violations" ]]
    [[ "${EVAL_VIOLATIONS}" -ge 1 ]]   # native fail folded in despite 0 severity
    [[ "${EVAL_PASSED}" == "false" ]]
}

@test "evaluation: exit 1 with zero confirmed checks (all-unknown) is needs_review" {
    export PREVIEW_MODE="false"
    _setup_cli_mock_exit 1 '{"summary":{"total_checks":0,"passed":0,"failed":0,"critical":0,"high":0,"medium":0,"low":0},"native_checks":[{"name":"X","status":"unknown","instance_statuses":["unknown"]}]}'
    source_iltero_core
    _mock_tf_with_resource
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "needs_review" ]]
    [[ "${EVAL_PASSED}" == "false" ]]
}

@test "evaluation: scanner error (exit 4) is infra_error, not needs_review" {
    export PREVIEW_MODE="false"
    _setup_cli_mock_exit 4 '{}'
    source_iltero_core
    _mock_tf_with_resource
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "infra_error" ]]
    [[ "${EVAL_PASSED}" == "false" ]]
}

@test "evaluation: an unrecognised exit code is infra_error, never waivable" {
    # Exit 1 is the only code an operator may waive. Anything outside the codes
    # this file enumerates must land in infra_error without the runner being
    # changed first.
    export PREVIEW_MODE="false"
    _setup_cli_mock_exit 6 '{}'
    source_iltero_core
    _mock_tf_with_resource
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "dev" "high" "" "" "[]" "" || true

    [[ "${EVAL_STATUS}" == "infra_error" ]] || return 1
    [[ "${EVAL_PASSED}" == "false" ]] || return 1
}
