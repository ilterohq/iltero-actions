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
    # Stub the attestation helper (defined in attestation.sh, not sourced here).
    # Mirrors the real contract: sets PLAN_DIGEST / PLAN_CANON_VERSION.
    compute_plan_digest() {
        PLAN_DIGEST="${MOCK_PLAN_DIGEST:-}"
        PLAN_CANON_VERSION="${MOCK_CANON_VERSION:-}"
    }

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

# A valid lowercase 64-char hex SHA-256 (the digest of the empty string).
HEX_DIGEST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Install a fake `aws` on PATH that records its argv to aws.log and exits with
# the configured code.
_mock_aws() {
    local exit_code="${1:-0}"
    cat > "${TEST_TEMP}/aws" <<EOF
#!/bin/bash
echo "aws \$*" >> "${TEST_TEMP}/aws.log"
exit ${exit_code}
EOF
    chmod +x "${TEST_TEMP}/aws"
    export PATH="${TEST_TEMP}:${PATH}"
}

# Pre-create the unit's local terraform state so the S3-backend extraction in
# prepare_terraform_plan finds an S3 backend (bucket my-bucket, prefix
# stacks/unit-x).
_setup_s3_backend() {
    mkdir -p "${UNIT_DIR}/.terraform"
    cat > "${UNIT_DIR}/.terraform/terraform.tfstate" <<'EOF'
{"backend":{"type":"s3","config":{"bucket":"my-bucket","region":"us-west-2","key":"stacks/unit-x/terraform.tfstate"}}}
EOF
}

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

@test "prepare_terraform_plan binds the unit when the plan binary uploads" {
    _mock_terraform 0 0 true
    _mock_aws 0
    _setup_s3_backend
    export MOCK_PLAN_DIGEST="${HEX_DIGEST}"
    export MOCK_CANON_VERSION="1"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "" "run-123"

    [[ "${TF_PLAN_DIGEST}" == "${HEX_DIGEST}" ]]
    [[ "${TF_CANON_VERSION}" == "1" ]]
    [[ "${TF_PLAN_BINARY_URL}" == "s3://my-bucket/stacks/unit-x/plans/run-123/unit-x.tfplan" ]]
    grep -q "s3://my-bucket/stacks/unit-x/plans/run-123/unit-x.tfplan" "${TEST_TEMP}/aws.log"

    unset MOCK_PLAN_DIGEST MOCK_CANON_VERSION
}

@test "prepare_terraform_plan drops the digest when the plan binary cannot be persisted" {
    _mock_terraform 0 0 true
    # No S3 backend configured -> upload_plan_binary fails -> unit not bound.
    export MOCK_PLAN_DIGEST="${HEX_DIGEST}"
    export MOCK_CANON_VERSION="1"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "" "run-123"

    [[ -z "${TF_PLAN_DIGEST}" ]]
    [[ -z "${TF_CANON_VERSION}" ]]
    [[ -z "${TF_PLAN_BINARY_URL}" ]]

    unset MOCK_PLAN_DIGEST MOCK_CANON_VERSION
}

@test "prepare_terraform_plan does not bind in best-effort mode" {
    _mock_terraform 0 0 true
    _mock_aws 0
    _setup_s3_backend
    export MOCK_DEP_STATE="unavailable"
    export MOCK_PLAN_DIGEST="${HEX_DIGEST}"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "upstream" "run-123"

    [[ "${TF_PLAN_MODE}" == "best_effort" ]]
    [[ -z "${TF_PLAN_DIGEST}" ]]
    [[ -z "${TF_PLAN_BINARY_URL}" ]]

    unset MOCK_DEP_STATE MOCK_PLAN_DIGEST
}

@test "prepare_terraform_plan leaves plan digest empty when attestation is off" {
    _mock_terraform 0 0 true

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ -z "${TF_PLAN_DIGEST}" ]]
    [[ -z "${TF_CANON_VERSION}" ]]
    [[ -z "${TF_PLAN_BINARY_URL}" ]]
}

@test "prepare_terraform_plan leaves plan URL empty when the JSON upload fails" {
    _mock_terraform 0 0 true
    _mock_aws 1
    _setup_s3_backend

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "" "run-123"

    # The aws failure must be detected (not masked by a pipe), so no URL is set.
    [[ -z "${TF_PLAN_S3_URL}" ]]
}

@test "prepare_terraform_plan passes --sse through the JSON upload when set" {
    _mock_terraform 0 0 true
    _mock_aws 0
    _setup_s3_backend
    export ILTERO_S3_SSE="AES256"

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}" "" "run-123"

    grep -q -- "--sse AES256" "${TEST_TEMP}/aws.log"
    unset ILTERO_S3_SSE
}

# =============================================================================
# upload_plan_binary
# =============================================================================

@test "upload_plan_binary uploads to the deterministic key and sets the URL" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET="my-bucket"
    TF_BACKEND_S3_KEY_PREFIX="stacks/unit-x"
    TF_BACKEND_S3_REGION="us-west-2"
    cd "${TEST_TEMP}"
    echo "binary" > tfplan

    upload_plan_binary "run-123" "unit-x"

    [[ "${PLAN_BINARY_URL}" == "s3://my-bucket/stacks/unit-x/plans/run-123/unit-x.tfplan" ]]
    grep -q -- "--region us-west-2" "${TEST_TEMP}/aws.log"
}

@test "upload_plan_binary fails when there is no S3 backend" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET=""
    TF_BACKEND_S3_KEY_PREFIX=""
    TF_BACKEND_S3_REGION="us-west-2"
    cd "${TEST_TEMP}"; echo x > tfplan

    run upload_plan_binary "run-123" "unit-x"
    assert_exit_code 1
}

@test "upload_plan_binary fails when run_id is empty" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    cd "${TEST_TEMP}"; echo x > tfplan

    run upload_plan_binary "" "unit-x"
    assert_exit_code 1
}

@test "upload_plan_binary fails when the region is empty" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION=""
    cd "${TEST_TEMP}"; echo x > tfplan

    run upload_plan_binary "run-123" "unit-x"
    assert_exit_code 1
}

@test "upload_plan_binary fails when tfplan is missing" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    cd "${TEST_TEMP}"; rm -f tfplan

    run upload_plan_binary "run-123" "unit-x"
    assert_exit_code 1
}

@test "upload_plan_binary empties the URL when aws errors" {
    _mock_aws 1
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    cd "${TEST_TEMP}"; echo x > tfplan

    run upload_plan_binary "run-123" "unit-x"
    assert_exit_code 1

    upload_plan_binary "run-123" "unit-x" || true
    [[ -z "${PLAN_BINARY_URL}" ]]
}

@test "upload_plan_binary passes --sse when ILTERO_S3_SSE is set" {
    _mock_aws 0
    export ILTERO_S3_SSE="aws:kms"
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    cd "${TEST_TEMP}"; echo x > tfplan

    upload_plan_binary "run-123" "unit-x"

    grep -q -- "--sse aws:kms" "${TEST_TEMP}/aws.log"
    unset ILTERO_S3_SSE
}

@test "upload_plan_binary omits --sse when ILTERO_S3_SSE is unset" {
    _mock_aws 0
    unset ILTERO_S3_SSE
    TF_BACKEND_S3_BUCKET="b"; TF_BACKEND_S3_KEY_PREFIX="p"; TF_BACKEND_S3_REGION="r"
    cd "${TEST_TEMP}"; echo x > tfplan

    upload_plan_binary "run-123" "unit-x"

    ! grep -q -- "--sse" "${TEST_TEMP}/aws.log"
}

# =============================================================================
# extract_s3_backend_config
# =============================================================================

@test "extract_s3_backend_config reads bucket/region/prefix from local state" {
    cd "${UNIT_DIR}"
    _setup_s3_backend

    extract_s3_backend_config

    [[ "${TF_BACKEND_S3_BUCKET}" == "my-bucket" ]]
    [[ "${TF_BACKEND_S3_REGION}" == "us-west-2" ]]
    [[ "${TF_BACKEND_S3_KEY_PREFIX}" == "stacks/unit-x" ]]
}

@test "extract_s3_backend_config leaves vars empty for a non-S3 backend" {
    cd "${UNIT_DIR}"
    mkdir -p .terraform
    echo '{"backend":{"type":"local"}}' > .terraform/terraform.tfstate

    extract_s3_backend_config

    [[ -z "${TF_BACKEND_S3_BUCKET}" ]]
    [[ -z "${TF_BACKEND_S3_KEY_PREFIX}" ]]
}

@test "extract_s3_backend_config leaves vars empty when no local state exists" {
    cd "${UNIT_DIR}"
    rm -rf .terraform

    extract_s3_backend_config

    [[ -z "${TF_BACKEND_S3_BUCKET}" ]]
}

# =============================================================================
# download_plan_binary
# =============================================================================

@test "download_plan_binary fetches the deterministic key on success" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET="my-bucket"
    TF_BACKEND_S3_KEY_PREFIX="stacks/unit-x"
    TF_BACKEND_S3_REGION="us-west-2"

    run download_plan_binary "run-123" "unit-x" "${TEST_TEMP}/got.tfplan"
    assert_exit_code 0

    grep -q "s3://my-bucket/stacks/unit-x/plans/run-123/unit-x.tfplan" "${TEST_TEMP}/aws.log"
}

@test "download_plan_binary fails when the object is absent (aws error)" {
    _mock_aws 1
    TF_BACKEND_S3_BUCKET="my-bucket"
    TF_BACKEND_S3_KEY_PREFIX="stacks/unit-x"
    TF_BACKEND_S3_REGION="us-west-2"

    run download_plan_binary "run-123" "unit-x" "${TEST_TEMP}/got.tfplan"
    assert_exit_code 1
}

@test "download_plan_binary fails when preconditions are unmet" {
    _mock_aws 0
    TF_BACKEND_S3_BUCKET=""
    TF_BACKEND_S3_KEY_PREFIX=""
    TF_BACKEND_S3_REGION=""

    run download_plan_binary "run-123" "unit-x" "${TEST_TEMP}/got.tfplan"
    assert_exit_code 1
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

# -----------------------------------------------------------------------------
# Credential-less preview path (A′): PREVIEW_MODE + no creds -> real plan with
# no backend, mock creds, provider skip-flags via an override, assume-role
# dropped. Never provenance-bound; mock creds must not leak to the env.
# -----------------------------------------------------------------------------

# Fake terraform that also records the AWS_ACCESS_KEY_ID it ran with and whether
# the preview override file was present at plan time.
_mock_terraform_preview() {
    local mock="${TEST_TEMP}/terraform"
    cat > "${mock}" <<EOF
#!/bin/bash
echo "terraform \$*" >> "${TEST_TEMP}/tf.log"
echo "\${AWS_ACCESS_KEY_ID:-<unset>}" >> "${TEST_TEMP}/tf.creds.log"
case "\$1" in
    plan)
        if [[ -f zzz_iltero_preview_override.tf ]]; then
            echo present >> "${TEST_TEMP}/tf.override.log"
            cp zzz_iltero_preview_override.tf "${TEST_TEMP}/tf.override.content"
        fi
        echo "{}" > tfplan
        exit 0
        ;;
    show)
        if [[ "\$2" == "-json" && "\$3" == "tfplan" ]]; then echo '{"format_version":"1.0"}'
        elif [[ "\$2" == "-json" ]]; then echo '{"format_version":"1.0","values":{}}'; fi
        exit 0 ;;
esac
exit 0
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

@test "prepare_terraform_plan (preview, no creds) runs credential-less" {
    _unset_cloud_cred_env
    export PREVIEW_MODE="true"
    export MOCK_BACKEND_HCL="${TEST_TEMP}/backend.hcl"  # would drive -backend-config
    printf 'provider "aws" {}\n' > "${UNIT_DIR}/providers.tf"
    _mock_terraform_preview

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ "${TF_PLAN_MODE}" == "preview" ]]
    [[ -z "${TF_PLAN_DIGEST}" ]]
    # init ran with no -backend=false and no real backend-config: the preview
    # override supplies a local backend instead.
    ! grep -q -- "-backend=false" "${TEST_TEMP}/tf.log"
    ! grep -q -- "-backend-config" "${TEST_TEMP}/tf.log"
    # plan skipped refresh and dropped the assume-role block
    grep -q -- "-refresh=false" "${TEST_TEMP}/tf.log"
    grep -q -- "assume_role_arn=" "${TEST_TEMP}/tf.log"
    # remote-state deps disabled too
    grep -q -- "enable_remote_state_dependencies=false" "${TEST_TEMP}/tf.log"
    # the override was present while planning, and removed afterwards
    grep -q present "${TEST_TEMP}/tf.override.log"
    [[ ! -f "${UNIT_DIR}/zzz_iltero_preview_override.tf" ]]
    # the override supplied a local backend (replacing the real s3 backend) plus
    # the provider skip flags, so init/plan need no credentials
    grep -q 'backend "local"' "${TEST_TEMP}/tf.override.content"
    grep -q "skip_credentials_validation" "${TEST_TEMP}/tf.override.content"

    unset PREVIEW_MODE MOCK_BACKEND_HCL
}

@test "prepare_terraform_plan (preview) does not leak mock creds to the env" {
    _unset_cloud_cred_env
    export PREVIEW_MODE="true"
    printf 'provider "aws" {}\n' > "${UNIT_DIR}/providers.tf"
    _mock_terraform_preview

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    # terraform saw the mock key...
    grep -q "iltero-preview-mock" "${TEST_TEMP}/tf.creds.log"
    # ...but it never leaked into the calling shell
    [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]
    run cloud_credentials_present
    assert_exit_code 1

    unset PREVIEW_MODE
}

@test "prepare_terraform_plan (preview) removes the override even when plan fails" {
    _unset_cloud_cred_env
    export PREVIEW_MODE="true"
    printf 'provider "aws" {}\n' > "${UNIT_DIR}/providers.tf"
    _mock_terraform 0 1 false  # plan fails, writes no tfplan

    run prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"
    assert_exit_code 2
    [[ ! -f "${UNIT_DIR}/zzz_iltero_preview_override.tf" ]]

    unset PREVIEW_MODE
}

@test "prepare_terraform_plan (preview) fails for a provider with no adapter" {
    _unset_cloud_cred_env
    export PREVIEW_MODE="true"
    # A cloud without a credential-less adapter: must not emit another cloud's
    # flags — it returns 2 (before terraform runs) and leaves no override.
    printf 'provider "google" {}\n' > "${UNIT_DIR}/providers.tf"
    _mock_terraform 0 0 true

    run prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"
    assert_exit_code 2
    [[ ! -f "${UNIT_DIR}/zzz_iltero_preview_override.tf" ]]
    # terraform was never invoked (no plan attempted for an unsupported cloud)
    [[ ! -f "${TEST_TEMP}/tf.log" ]]

    unset PREVIEW_MODE
}

@test "prepare_terraform_plan (preview WITH creds) stays on the credentialed path" {
    _unset_cloud_cred_env
    export PREVIEW_MODE="true"
    export AWS_ACCESS_KEY_ID="real-oidc-key"
    export MOCK_BACKEND_HCL="${TEST_TEMP}/backend.hcl"
    _mock_terraform 0 0 true

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ "${TF_PLAN_MODE}" != "preview" ]]
    grep -q -- "-backend-config=${TEST_TEMP}/backend.hcl" "${TEST_TEMP}/tf.log"
    ! grep -q -- "assume_role_arn=" "${TEST_TEMP}/tf.log"
    [[ ! -f "${UNIT_DIR}/zzz_iltero_preview_override.tf" ]]

    unset PREVIEW_MODE AWS_ACCESS_KEY_ID MOCK_BACKEND_HCL
}

@test "prepare_terraform_plan (no preview, no creds) does not go credential-less" {
    _unset_cloud_cred_env
    unset PREVIEW_MODE
    export MOCK_BACKEND_HCL="${TEST_TEMP}/backend.hcl"
    _mock_terraform 0 0 true

    prepare_terraform_plan "${UNIT_DIR}" "unit-x" "${VALID_ENV}"

    [[ "${TF_PLAN_MODE}" != "preview" ]]
    ! grep -q -- "-backend=false" "${TEST_TEMP}/tf.log"
    [[ ! -f "${UNIT_DIR}/zzz_iltero_preview_override.tf" ]]

    unset MOCK_BACKEND_HCL
}
