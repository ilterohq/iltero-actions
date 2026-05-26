#!/usr/bin/env bats
# =============================================================================
# Tests for terraform.sh - Shared terraform plan preparation
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    touch "${GITHUB_OUTPUT}"

    unset ILTERO_TERRAFORM_SOURCED
    source_iltero_core "terraform.sh"

    # Stub helpers that prepare_terraform_plan calls into.
    check_dependency_remote_state() {
        printf '%s' "${MOCK_DEP_STATE:-available}"
    }
    update_unit_remote_state_status() { :; }
    check_env_config() {
        BACKEND_HCL="${MOCK_BACKEND_HCL:-}"
        TFVARS_FILE="${MOCK_TFVARS_FILE:-}"
    }
    emit_cloud_credentials_hint_if_needed() { :; }

    # Build a unit directory the function will pushd into.
    UNIT_DIR="${TEST_TEMP}/unit"
    mkdir -p "${UNIT_DIR}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

# Install a fake `terraform` on PATH that records its argv into a log
# and exits with the configured exit code per subcommand. Stdout for
# `show -json tfplan` writes the plan JSON; for `show -json` writes state.
_mock_terraform() {
    local init_exit="${1:-0}"
    local plan_exit="${2:-0}"
    local plan_writes_file="${3:-true}"
    local mock="${TEST_TEMP}/terraform"
    cat > "${mock}" <<EOF
#!/bin/bash
echo "terraform \$*" >> "${TEST_TEMP}/tf.log"
case "\$1" in
    init)
        exit ${init_exit}
        ;;
    plan)
        if [[ "${plan_writes_file}" == "true" ]]; then
            echo "{}" > tfplan
        fi
        exit ${plan_exit}
        ;;
    state)
        case "\$2" in
            list) exit 0 ;;
        esac
        exit 0
        ;;
    show)
        if [[ "\$2" == "-json" && "\$3" == "tfplan" ]]; then
            echo '{"format_version":"1.0"}'
        elif [[ "\$2" == "-json" ]]; then
            echo '{"format_version":"1.0","values":{}}'
        fi
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

VALID_ENV="production"

@test "prepare_terraform_plan rejects missing eval_path" {
    run prepare_terraform_plan "" "unit-x" "${VALID_ENV}"
    assert_exit_code 1
}

@test "prepare_terraform_plan rejects non-existent eval_path" {
    run prepare_terraform_plan "${TEST_TEMP}/does-not-exist" "unit-x" "${VALID_ENV}"
    assert_exit_code 1
}

@test "prepare_terraform_plan returns 1 on init failure" {
    _mock_terraform 1 0 true

    run prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"
    assert_exit_code 1
}

@test "prepare_terraform_plan returns 2 on plan failure" {
    _mock_terraform 0 1 false

    run prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"
    assert_exit_code 2
}

@test "prepare_terraform_plan happy path sets module vars" {
    _mock_terraform 0 0 true

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ -n "${TF_PLAN_JSON_FILE}" ]]
    [[ -f "${TF_PLAN_JSON_FILE}" ]]
    [[ "${TF_PLAN_MODE}" == "full" ]]
}

@test "prepare_terraform_plan switches to best_effort when deps unavailable" {
    _mock_terraform 0 0 true
    export MOCK_DEP_STATE="unavailable"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "upstream-unit"

    [[ "${TF_PLAN_MODE}" == "best_effort" ]]
    grep -q "enable_remote_state_dependencies=false" "${TEST_TEMP}/tf.log"
}

@test "prepare_terraform_plan resets outputs at start of each call" {
    _mock_terraform 0 0 true
    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"
    [[ -n "${TF_PLAN_JSON_FILE}" ]]

    _mock_terraform 1 0 true
    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" || true

    [[ -z "${TF_PLAN_JSON_FILE}" ]]
    [[ "${TF_PLAN_MODE}" == "full" ]]
}

@test "prepare_terraform_plan returns to original directory after success" {
    _mock_terraform 0 0 true
    local before
    before="$(pwd)"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ "$(pwd)" == "${before}" ]]
}

@test "prepare_terraform_plan returns to original directory after init failure" {
    _mock_terraform 1 0 true
    local before
    before="$(pwd)"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" || true

    [[ "$(pwd)" == "${before}" ]]
}

@test "prepare_terraform_plan returns to original directory after plan failure" {
    _mock_terraform 0 1 false
    local before
    before="$(pwd)"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" || true

    [[ "$(pwd)" == "${before}" ]]
}

# =============================================================================
# cloud_credentials_present — cloud-agnostic credential detection
# =============================================================================

# Helper: clear all cloud-cred env vars so each cloud_credentials_present
# test starts from a known state regardless of CI inheritance.
_unset_cloud_cred_env() {
    unset AWS_ACCESS_KEY_ID GOOGLE_APPLICATION_CREDENTIALS \
          GOOGLE_GHA_CREDS_PATH AZURE_CLIENT_ID
}

@test "cloud_credentials_present is false when no cloud env vars set" {
    _unset_cloud_cred_env

    run cloud_credentials_present
    assert_exit_code 1
}

@test "cloud_credentials_present treats empty AWS_ACCESS_KEY_ID as unset" {
    _unset_cloud_cred_env
    export AWS_ACCESS_KEY_ID=""

    run cloud_credentials_present
    assert_exit_code 1

    unset AWS_ACCESS_KEY_ID
}

@test "cloud_credentials_present is true on AWS_ACCESS_KEY_ID" {
    _unset_cloud_cred_env
    export AWS_ACCESS_KEY_ID="AKIA-test"

    run cloud_credentials_present
    assert_exit_code 0

    unset AWS_ACCESS_KEY_ID
}

@test "cloud_credentials_present is true on GOOGLE_APPLICATION_CREDENTIALS" {
    _unset_cloud_cred_env
    export GOOGLE_APPLICATION_CREDENTIALS="/tmp/gcp-key.json"

    run cloud_credentials_present
    assert_exit_code 0

    unset GOOGLE_APPLICATION_CREDENTIALS
}

@test "cloud_credentials_present is true on GOOGLE_GHA_CREDS_PATH" {
    _unset_cloud_cred_env
    export GOOGLE_GHA_CREDS_PATH="/tmp/gcp-creds"

    run cloud_credentials_present
    assert_exit_code 0

    unset GOOGLE_GHA_CREDS_PATH
}

@test "cloud_credentials_present is true on AZURE_CLIENT_ID" {
    _unset_cloud_cred_env
    export AZURE_CLIENT_ID="azure-test-client"

    run cloud_credentials_present
    assert_exit_code 0

    unset AZURE_CLIENT_ID
}
