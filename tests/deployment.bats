#!/usr/bin/env bats
# =============================================================================
# Tests for deployment.sh - run_deployment, focused on the attested-apply path
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    source_iltero_core "deployment.sh"

    # Cross-module dependencies, stubbed to the real contract.
    check_env_config() { BACKEND_HCL=""; TFVARS_FILE=""; }
    emit_cloud_credentials_hint_if_needed() { :; }
    # notify_apply_result: record the success flag and whether the apply-json file
    # ($6) was handed over (it is removed right after this call in run_deployment).
    notify_apply_result() {
        local present=no
        [[ -n "${6:-}" && -f "${6}" ]] && present=yes
        echo "notify success=${5:-} apply_json_present=${present}" >> "${TEST_TEMP}/notify.log"
    }
    attestation_enabled() { [[ "${ILTERO_ATTEST:-false}" == "true" ]]; }
    # extract_s3_backend_config: provide a fake S3 backend.
    extract_s3_backend_config() {
        TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    }
    # download_plan_binary: succeed (and create dest) when MOCK_DOWNLOAD_OK=true.
    download_plan_binary() {
        if [[ "${MOCK_DOWNLOAD_OK:-false}" == "true" ]]; then
            echo "saved-binary" > "${3}"
            return 0
        fi
        return 1
    }
    # compute_plan_digest: yield the configured recomputed digest.
    compute_plan_digest() { PLAN_DIGEST="${MOCK_RECOMPUTED_DIGEST:-}"; PLAN_CANON_VERSION="1"; }
    # verify_authorization: return the configured exit code, recording the call.
    verify_authorization() {
        echo "authz digest=${5:-} canon=${6:-}" >> "${TEST_TEMP}/authz.log"
        return "${MOCK_AUTH_EXIT:-0}"
    }

    UNIT_DIR="${TEST_TEMP}/unit"
    mkdir -p "${UNIT_DIR}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    rm -f /tmp/unit-x_outputs.json /tmp/unit-x_state.json
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
    unset ILTERO_ATTEST MOCK_DOWNLOAD_OK MOCK_RECOMPUTED_DIGEST MOCK_AUTH_EXIT MOCK_APPLY_EXIT
}

# Fake `terraform` recording argv; init/plan/output/state/show succeed. `apply`
# exits with ${MOCK_APPLY_EXIT:-0}, so a test can drive the apply-failure path.
_mock_terraform() {
    cat > "${TEST_TEMP}/terraform" <<EOF
#!/bin/bash
echo "terraform \$*" >> "${TEST_TEMP}/tf.log"
case "\$1" in
    output) echo '{}' ;;
    show) echo '{"format_version":"1.0"}' ;;
    apply) exit \${MOCK_APPLY_EXIT:-0} ;;
esac
exit 0
EOF
    chmod +x "${TEST_TEMP}/terraform"
    export PATH="${TEST_TEMP}:${PATH}"
}

HEX_DIGEST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

@test "run_deployment fails closed below the Terraform version floor" {
    export TF_VERSION_OVERRIDE="1.9.0"
    ILTERO_TF_FLOOR_CHECKED=""
    local out status=0
    out="$(run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1" 2>&1)" || status=$?
    [ "${status}" -eq 2 ]
    [[ "${out}" == *"below the minimum"* ]]
}

@test "run_deployment re-plans when attestation is off" {
    _mock_terraform
    unset ILTERO_ATTEST

    run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"

    grep -q "terraform plan" "${TEST_TEMP}/tf.log"
    grep -q "terraform apply" "${TEST_TEMP}/tf.log"
    [[ ! -f "${TEST_TEMP}/authz.log" ]]   # run_deployment does not authorize when off
}

@test "run_deployment (attest) applies the saved plan and enforces it at the gate" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="true"
    export MOCK_RECOMPUTED_DIGEST="${HEX_DIGEST}"
    export MOCK_AUTH_EXIT="0"

    run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"

    ! grep -q "terraform plan" "${TEST_TEMP}/tf.log"     # no re-plan
    grep -q "terraform apply" "${TEST_TEMP}/tf.log"       # applied the saved plan
    grep -q "digest=${HEX_DIGEST}" "${TEST_TEMP}/authz.log"  # enforced at the gate
    [[ "${PROVENANCE_BOUND}" == "true" ]]
    # the apply outcome is recorded as a success, with the apply-json handed over
    grep -q "notify success=true apply_json_present=yes" "${TEST_TEMP}/notify.log"
}

@test "run_deployment records the apply outcome (success=false) when terraform apply fails" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="true"
    export MOCK_RECOMPUTED_DIGEST="${HEX_DIGEST}"
    export MOCK_AUTH_EXIT="0"
    export MOCK_APPLY_EXIT="1"   # apply fails AFTER authorization (partial-failure path)

    run run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"
    assert_exit_code 1            # the deploy reports failure

    grep -q "terraform apply" "${TEST_TEMP}/tf.log"
    # the partial outcome IS still recorded: notify is called with --failed AND the
    # apply-json, so the backend gets the per-resource breakdown of what applied.
    grep -q "notify success=false apply_json_present=yes" "${TEST_TEMP}/notify.log"
}

@test "run_deployment leaves an unbound (re-planned) unit not provenance-bound" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="false"   # unbound
    export MOCK_AUTH_EXIT="0"

    run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"

    grep -q "terraform apply" "${TEST_TEMP}/tf.log"
    [[ "${PROVENANCE_BOUND}" == "false" ]]
}

@test "run_deployment fails closed (no apply) when the backend denies the digest" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="true"
    export MOCK_RECOMPUTED_DIGEST="${HEX_DIGEST}"
    export MOCK_AUTH_EXIT="1"

    run run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"
    assert_exit_code 1

    ! grep -q "terraform apply" "${TEST_TEMP}/tf.log"     # never applied
}

@test "run_deployment fails closed when a saved binary downloads but cannot be digested" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="true"
    export MOCK_RECOMPUTED_DIGEST=""   # terraform show / CLI could not digest it
    export MOCK_AUTH_EXIT="0"          # even if the backend would authorize

    run run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"
    assert_exit_code 1

    ! grep -q "terraform apply" "${TEST_TEMP}/tf.log"   # never applied an unverified plan
    # Fails closed locally before even calling the backend authorize.
    [[ ! -f "${TEST_TEMP}/authz.log" ]]
}

@test "run_deployment re-plans (unbound) when no saved binary exists, authorizing with empty digest" {
    _mock_terraform
    export ILTERO_ATTEST="true"
    export MOCK_DOWNLOAD_OK="false"   # not provenance-bound
    export MOCK_AUTH_EXIT="0"

    run_deployment "${UNIT_DIR}" "unit-x" "prod" "run-1" "scan-1" "stack-1"

    grep -q "terraform plan" "${TEST_TEMP}/tf.log"        # re-planned
    grep -q "terraform apply" "${TEST_TEMP}/tf.log"
    grep -q "digest= " "${TEST_TEMP}/authz.log"           # authorized with empty digest
}
