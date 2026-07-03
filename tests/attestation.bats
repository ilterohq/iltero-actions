#!/usr/bin/env bats
# =============================================================================
# Tests for attestation.sh - Provenance attestation helpers
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    unset ILTERO_ATTESTATION_SOURCED
    source_iltero_core "attestation.sh"

    PLAN_JSON="${TEST_TEMP}/tfplan.json"
    echo '{"format_version":"1.0"}' > "${PLAN_JSON}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
    unset ILTERO_ATTEST ILTERO_CLI_BIN PREVIEW_MODE
}

# Install a fake `iltero` whose `scan plan-digest` prints the contents of
# out_file and exits with exit_code. Any other invocation exits 0.
_mock_iltero_plan_digest() {
    local out_file="$1"
    local exit_code="${2:-0}"
    cat > "${TEST_TEMP}/iltero" <<EOF
#!/bin/bash
if [[ "\$1" == "scan" && "\$2" == "plan-digest" ]]; then
    cat "${out_file}"
    exit ${exit_code}
fi
exit 0
EOF
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
}

# -----------------------------------------------------------------------------
# attestation_enabled
# -----------------------------------------------------------------------------

@test "attestation_enabled is false by default" {
    unset ILTERO_ATTEST
    run attestation_enabled
    assert_exit_code 1
}

@test "attestation_enabled is false for any value other than 'true'" {
    export ILTERO_ATTEST="1"
    run attestation_enabled
    assert_exit_code 1
}

@test "attestation_enabled is true only when ILTERO_ATTEST=true" {
    export ILTERO_ATTEST="true"
    run attestation_enabled
    assert_exit_code 0
}

@test "attestation_enabled is false in preview even when ILTERO_ATTEST=true" {
    # A preview plan (even a credentialed same-repo one) must never attest.
    export ILTERO_ATTEST="true"
    export PREVIEW_MODE="true"
    run attestation_enabled
    assert_exit_code 1
}

# -----------------------------------------------------------------------------
# compute_plan_digest
# -----------------------------------------------------------------------------

@test "compute_plan_digest is a no-op when attestation is disabled" {
    unset ILTERO_ATTEST
    local digest_out="${TEST_TEMP}/digest.json"
    echo '{"plan_digest":"sha256:abc","canonicalization_version":"1"}' > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${PLAN_JSON}"

    [[ -z "${PLAN_DIGEST}" ]]
    [[ -z "${PLAN_CANON_VERSION}" ]]
}

# A valid lowercase 64-char hex SHA-256 (here: the digest of the empty string).
HEX_DIGEST="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

@test "compute_plan_digest captures digest and version from the CLI when enabled" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo "{\"plan_digest\":\"${HEX_DIGEST}\",\"canonicalization_version\":\"2\"}" > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${PLAN_JSON}"

    [[ "${PLAN_DIGEST}" == "${HEX_DIGEST}" ]]
    [[ "${PLAN_CANON_VERSION}" == "2" ]]
}

@test "compute_plan_digest ignores a malformed (non-hex) plan_digest" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo '{"plan_digest":"--terraform-plan-json=/etc/passwd","canonicalization_version":"1"}' > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${PLAN_JSON}"

    [[ -z "${PLAN_DIGEST}" ]]
    # A voided digest also voids the version (a version cannot bind alone).
    [[ -z "${PLAN_CANON_VERSION}" ]]
}

@test "compute_plan_digest drops a malformed version but keeps a valid digest" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo "{\"plan_digest\":\"${HEX_DIGEST}\",\"canonicalization_version\":\"v 1; rm\"}" > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${PLAN_JSON}"

    [[ "${PLAN_DIGEST}" == "${HEX_DIGEST}" ]]
    [[ -z "${PLAN_CANON_VERSION}" ]]
}

@test "compute_plan_digest fails soft when the CLI exits non-zero" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo 'boom' > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 1

    run compute_plan_digest "${PLAN_JSON}"
    assert_exit_code 0

    # Direct call to inspect the (empty) outputs.
    compute_plan_digest "${PLAN_JSON}"
    [[ -z "${PLAN_DIGEST}" ]]
    [[ -z "${PLAN_CANON_VERSION}" ]]
}

@test "compute_plan_digest fails soft when the plan JSON is missing" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo '{"plan_digest":"sha256:abc","canonicalization_version":"1"}' > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${TEST_TEMP}/does-not-exist.json"

    [[ -z "${PLAN_DIGEST}" ]]
}

@test "compute_plan_digest leaves digest empty when CLI omits plan_digest" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo '{"canonicalization_version":"1"}' > "${digest_out}"
    _mock_iltero_plan_digest "${digest_out}" 0

    compute_plan_digest "${PLAN_JSON}"

    [[ -z "${PLAN_DIGEST}" ]]
}

@test "compute_plan_digest resets stale outputs on each call" {
    export ILTERO_ATTEST="true"
    PLAN_DIGEST="stale"
    PLAN_CANON_VERSION="stale"

    # Disabled path should clear the stale values.
    unset ILTERO_ATTEST
    compute_plan_digest "${PLAN_JSON}"

    [[ -z "${PLAN_DIGEST}" ]]
    [[ -z "${PLAN_CANON_VERSION}" ]]
}

@test "compute_plan_digest honours ILTERO_CLI_BIN override" {
    export ILTERO_ATTEST="true"
    local digest_out="${TEST_TEMP}/digest.json"
    echo "{\"plan_digest\":\"${HEX_DIGEST}\",\"canonicalization_version\":\"1\"}" > "${digest_out}"
    # Install the stub under a non-default name and point the var at it.
    cat > "${TEST_TEMP}/iltero-custom" <<EOF
#!/bin/bash
if [[ "\$1" == "scan" && "\$2" == "plan-digest" ]]; then
    cat "${digest_out}"
    exit 0
fi
exit 0
EOF
    chmod +x "${TEST_TEMP}/iltero-custom"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero-custom"

    compute_plan_digest "${PLAN_JSON}"

    [[ "${PLAN_DIGEST}" == "${HEX_DIGEST}" ]]
}

# -----------------------------------------------------------------------------
# provenance_eval_flags
# -----------------------------------------------------------------------------

@test "provenance_eval_flags emits both flags when digest and version are present" {
    provenance_eval_flags "${HEX_DIGEST}" "1"

    [[ "${#PROVENANCE_EVAL_FLAGS[@]}" -eq 4 ]]
    [[ "${PROVENANCE_EVAL_FLAGS[0]}" == "--plan-digest" ]]
    [[ "${PROVENANCE_EVAL_FLAGS[1]}" == "${HEX_DIGEST}" ]]
    [[ "${PROVENANCE_EVAL_FLAGS[2]}" == "--canonicalization-version" ]]
    [[ "${PROVENANCE_EVAL_FLAGS[3]}" == "1" ]]
}

@test "provenance_eval_flags omits the version flag when version is empty" {
    provenance_eval_flags "${HEX_DIGEST}" ""

    [[ "${#PROVENANCE_EVAL_FLAGS[@]}" -eq 2 ]]
    [[ "${PROVENANCE_EVAL_FLAGS[0]}" == "--plan-digest" ]]
    [[ "${PROVENANCE_EVAL_FLAGS[1]}" == "${HEX_DIGEST}" ]]
}

@test "provenance_eval_flags emits nothing when there is no digest" {
    provenance_eval_flags "" "1"

    [[ "${#PROVENANCE_EVAL_FLAGS[@]}" -eq 0 ]]
}
