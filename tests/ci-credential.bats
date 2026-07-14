#!/usr/bin/env bats
# =============================================================================
# Tests for ci-credential.sh - CI credential resolution
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    touch "${GITHUB_OUTPUT}"

    unset ILTERO_CI_CREDENTIAL_SOURCED

    source_iltero_core "ci-credential.sh"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    # Remove any prepended test PATH segment
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

# Install a fake `iltero` on PATH that prints $stdout and exits with $exit_code.
# Args: $1=stdout $2=exit_code (default 0)
_mock_iltero_cli() {
    local stdout="$1"
    local exit_code="${2:-0}"
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<EOF
#!/bin/bash
cat <<'PAYLOAD'
${stdout}
PAYLOAD
exit ${exit_code}
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

VALID_UUID="0b278217-a809-465a-b9df-00eda8414cb8"
VALID_ENV="production"
VALID_ROLE_ARN="arn:aws:iam::111122223333:role/iltero-prod"
VALID_REGION="us-east-1"

# =============================================================================
# Input validation
# =============================================================================

@test "resolve_ci_credential rejects missing first argument" {
    run resolve_ci_credential
    assert_exit_code 2
    assert_output_contains "--stack-id or --workspace-id"
}

@test "resolve_ci_credential rejects unknown first argument" {
    run resolve_ci_credential "not-a-flag" "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "--stack-id or --workspace-id"
}

@test "resolve_ci_credential rejects empty stack-id" {
    run resolve_ci_credential --stack-id "" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "stack-id"
}

@test "resolve_ci_credential rejects non-UUID stack-id" {
    run resolve_ci_credential --stack-id "not-a-uuid" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "UUID"
}

@test "resolve_ci_credential rejects empty environment" {
    run resolve_ci_credential --stack-id "${VALID_UUID}" ""
    assert_exit_code 2
    assert_output_contains "environment"
}

@test "resolve_ci_credential rejects environment with semicolon" {
    run resolve_ci_credential --stack-id "${VALID_UUID}" "prod;rm-rf"
    assert_exit_code 2
    assert_output_contains "unsupported characters"
}

@test "resolve_ci_credential rejects environment with slash" {
    run resolve_ci_credential --stack-id "${VALID_UUID}" "prod/extra"
    assert_exit_code 2
    assert_output_contains "unsupported characters"
}

# =============================================================================
# CLI failure
# =============================================================================

@test "resolve_ci_credential fails when CLI exits non-zero" {
    _mock_iltero_cli "" 1

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "resolution failed"
}

# =============================================================================
# Response shape — provider field
# =============================================================================

@test "resolve_ci_credential fails on missing provider" {
    _mock_iltero_cli '{}' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "missing provider"
}

@test "resolve_ci_credential fails on unknown provider" {
    _mock_iltero_cli '{"provider":"oracle"}' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "unknown provider"
}

@test "resolve_ci_credential rejects gcp provider" {
    _mock_iltero_cli '{"provider":"gcp","project_id":"x"}' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "not supported"
}

@test "resolve_ci_credential rejects azure provider" {
    _mock_iltero_cli '{"provider":"azure","tenant_id":"x"}' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "not supported"
}

# =============================================================================
# AWS branch — response validation
# =============================================================================

@test "resolve_ci_credential happy path AWS sets module variables" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    assert_output_contains "aws"
}

@test "resolve_ci_credential AWS sets CI_CREDENTIAL_* vars" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0

    resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"

    [[ "${CI_CREDENTIAL_PROVIDER}" == "aws" ]]
    [[ "${CI_CREDENTIAL_AWS_ROLE_ARN}" == "${VALID_ROLE_ARN}" ]]
    [[ "${CI_CREDENTIAL_AWS_REGION}" == "${VALID_REGION}" ]]
}

@test "resolve_ci_credential --stack-id passes --stack-id flag to CLI" {
    # Mirror of the --workspace-id passthrough test: verify the stack path
    # forwards --stack-id (not --workspace-id) to the CLI.
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<'EOF'
#!/bin/bash
# Fail if --stack-id is not among the args
found=0
for arg in "$@"; do
    [[ "${arg}" == "--stack-id" ]] && found=1
done
[[ "${found}" -eq 1 ]] || { echo "::error::--stack-id not passed to CLI" >&2; exit 2; }
cat <<'JSON'
{"provider":"aws","role_arn":"arn:aws:iam::111122223333:role/iltero-prod","region":"us-east-1"}
JSON
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
}

@test "resolve_ci_credential AWS rejects missing role_arn" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "missing required AWS fields"
}

@test "resolve_ci_credential AWS rejects missing region" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "missing required AWS fields"
}

@test "resolve_ci_credential AWS rejects malformed role_arn (wrong prefix)" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"http://evil.example/role\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "malformed AWS role ARN"
}

@test "resolve_ci_credential AWS rejects malformed role_arn (short account id)" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"arn:aws:iam::123:role/x\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "malformed AWS role ARN"
}

@test "resolve_ci_credential AWS rejects malformed region" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"US East 1\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "malformed AWS region"
}

@test "resolve_ci_credential AWS rejects role_arn with newline" {
    # Newlines in API response could otherwise inject extra GITHUB_ENV entries
    # if the value reached env writing. Validation refuses upstream.
    local bad_arn="${VALID_ROLE_ARN}"$'\nINJECTED=1'
    local payload
    payload=$(printf '{"provider":"aws","role_arn":"%s","region":"%s"}' "${bad_arn}" "${VALID_REGION}")
    _mock_iltero_cli "${payload}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
}

# =============================================================================
# Adversarial cases — input/response shape edges
# =============================================================================

@test "resolve_ci_credential rejects malformed JSON (missing brace)" {
    _mock_iltero_cli '{"provider":"aws","role_arn":"x"' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "not valid JSON"
}

@test "resolve_ci_credential rejects empty stdout from CLI" {
    _mock_iltero_cli '' 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
}

@test "resolve_ci_credential treats stderr noise + valid JSON as success" {
    # Mock that writes a stderr warning before emitting JSON on stdout.
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<'EOF'
#!/bin/bash
echo "WARN: deprecated something" >&2
cat <<'JSON'
{"provider":"aws","role_arn":"arn:aws:iam::111122223333:role/iltero-prod","region":"us-east-1"}
JSON
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    assert_output_contains "aws"
}

@test "resolve_ci_credential rejects uppercase provider 'AWS'" {
    _mock_iltero_cli "{\"provider\":\"AWS\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "unknown provider"
}

@test "resolve_ci_credential rejects role_arn with shell-meta characters" {
    local bad_arn='arn:aws:iam::111122223333:role/x$(whoami)'
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${bad_arn}\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "malformed AWS role ARN"
}

@test "resolve_ci_credential rejects empty-string role_arn" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "missing required AWS fields"
}

@test "resolve_ci_credential accepts GovCloud region" {
    # ARN partition is `aws` per the regex; only the region varies here.
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"us-gov-east-1\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
}

@test "resolve_ci_credential accepts China region" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"cn-north-1\"}" 0

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
}

# =============================================================================
# emit_cloud_credentials_hint_if_needed
# =============================================================================

@test "emit_cloud_credentials_hint_if_needed fires on Unable to locate credentials" {
    run emit_cloud_credentials_hint_if_needed "Error: Unable to locate credentials"
    assert_exit_code 0
    assert_output_contains "id-token: write"
}

@test "emit_cloud_credentials_hint_if_needed fires on InvalidClientTokenId" {
    run emit_cloud_credentials_hint_if_needed "InvalidClientTokenId: The security token included in the request is invalid"
    assert_exit_code 0
    assert_output_contains "missing or invalid cloud credentials"
}

@test "emit_cloud_credentials_hint_if_needed fires on ExpiredToken" {
    run emit_cloud_credentials_hint_if_needed "ExpiredToken: The provided token has expired"
    assert_exit_code 0
    assert_output_contains "id-token: write"
}

@test "emit_cloud_credentials_hint_if_needed silent on unrelated error" {
    run emit_cloud_credentials_hint_if_needed "Error: invalid resource argument 'foo'"
    assert_exit_code 0
    [[ -z "${output}" ]]
}

@test "emit_cloud_credentials_hint_if_needed silent on AccessDeniedException (IAM policy denial)" {
    # The role exists and the credential is valid; the customer just lacks the
    # required IAM permission. The hint would mislead the operator.
    run emit_cloud_credentials_hint_if_needed "Error: AccessDeniedException: User is not authorized to perform: s3:PutObject"
    assert_exit_code 0
    [[ -z "${output}" ]]
}

@test "emit_cloud_credentials_hint_if_needed silent on SignatureDoesNotMatch (clock skew)" {
    run emit_cloud_credentials_hint_if_needed "Error: SignatureDoesNotMatch: The request signature we calculated does not match the signature you provided"
    assert_exit_code 0
    [[ -z "${output}" ]]
}

@test "emit_cloud_credentials_hint_if_needed silent on empty input" {
    run emit_cloud_credentials_hint_if_needed ""
    assert_exit_code 0
    [[ -z "${output}" ]]
}

@test "emit_cloud_credentials_hint_if_needed handles multiline output" {
    local output_text
    output_text="terraform init complete
preparing to call STS
Error: NoCredentialProviders: no valid providers in chain"
    run emit_cloud_credentials_hint_if_needed "${output_text}"
    assert_exit_code 0
    assert_output_contains "id-token: write"
}

@test "resolve_ci_credential prefers ILTERO_CLI_BIN over PATH" {
    # Locks in the PATH-injection mitigation: when ILTERO_CLI_BIN is set,
    # the resolver MUST use it instead of looking up `iltero` on $PATH.
    # On-PATH mock returns an unsupported provider (would fail the test);
    # the absolute-path mock returns the valid AWS payload (test passes).
    _mock_iltero_cli '{"provider":"oracle"}' 0
    local pinned="${TEST_TEMP}/pinned-iltero"
    cat > "${pinned}" <<EOF
#!/bin/bash
cat <<'PAYLOAD'
{"provider":"aws","role_arn":"${VALID_ROLE_ARN}","region":"${VALID_REGION}"}
PAYLOAD
EOF
    chmod +x "${pinned}"
    export ILTERO_CLI_BIN="${pinned}"

    run resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    assert_output_contains "aws"

    unset ILTERO_CLI_BIN
}

@test "resolve_ci_credential resets module vars on failure" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0
    resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}"
    [[ "${CI_CREDENTIAL_AWS_ROLE_ARN}" == "${VALID_ROLE_ARN}" ]]

    _mock_iltero_cli '{}' 1
    resolve_ci_credential --stack-id "${VALID_UUID}" "${VALID_ENV}" || true

    [[ -z "${CI_CREDENTIAL_PROVIDER}" ]]
    [[ -z "${CI_CREDENTIAL_AWS_ROLE_ARN}" ]]
    [[ -z "${CI_CREDENTIAL_AWS_REGION}" ]]
}

# =============================================================================
# workspace-id path — input validation
# =============================================================================

@test "resolve_ci_credential --workspace-id rejects empty uuid" {
    run resolve_ci_credential --workspace-id "" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "workspace-id"
}

@test "resolve_ci_credential --workspace-id rejects non-UUID" {
    run resolve_ci_credential --workspace-id "not-a-uuid" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "UUID"
}

@test "resolve_ci_credential --workspace-id rejects empty environment" {
    run resolve_ci_credential --workspace-id "${VALID_UUID}" ""
    assert_exit_code 2
    assert_output_contains "environment"
}

@test "resolve_ci_credential --workspace-id rejects environment with semicolon" {
    run resolve_ci_credential --workspace-id "${VALID_UUID}" "prod;rm-rf"
    assert_exit_code 2
    assert_output_contains "unsupported characters"
}

@test "resolve_ci_credential --workspace-id rejects environment with slash" {
    run resolve_ci_credential --workspace-id "${VALID_UUID}" "prod/extra"
    assert_exit_code 2
    assert_output_contains "unsupported characters"
}

# =============================================================================
# workspace-id path — CLI failure and response shape
# =============================================================================

@test "resolve_ci_credential --workspace-id fails when CLI exits non-zero" {
    _mock_iltero_cli "" 1

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "resolution failed"
}

@test "resolve_ci_credential --workspace-id fails on missing provider" {
    _mock_iltero_cli '{}' 0

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "missing provider"
}

@test "resolve_ci_credential --workspace-id fails on unknown provider" {
    _mock_iltero_cli '{"provider":"oracle"}' 0

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "unknown provider"
}

@test "resolve_ci_credential --workspace-id happy path AWS sets module variables" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    assert_output_contains "aws"
}

@test "resolve_ci_credential --workspace-id AWS sets CI_CREDENTIAL_* vars" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"${VALID_ROLE_ARN}\",\"region\":\"${VALID_REGION}\"}" 0

    resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"

    [[ "${CI_CREDENTIAL_PROVIDER}" == "aws" ]]
    [[ "${CI_CREDENTIAL_AWS_ROLE_ARN}" == "${VALID_ROLE_ARN}" ]]
    [[ "${CI_CREDENTIAL_AWS_REGION}" == "${VALID_REGION}" ]]
}

@test "resolve_ci_credential --workspace-id passes --workspace-id flag to CLI" {
    # Verify the CLI is invoked with --workspace-id (not --stack-id).
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<'EOF'
#!/bin/bash
# Fail if --workspace-id is not among the args
found=0
for arg in "$@"; do
    [[ "${arg}" == "--workspace-id" ]] && found=1
done
[[ "${found}" -eq 1 ]] || { echo "::error::--workspace-id not passed to CLI" >&2; exit 2; }
cat <<'JSON'
{"provider":"aws","role_arn":"arn:aws:iam::111122223333:role/iltero-prod","region":"us-east-1"}
JSON
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
}

@test "resolve_ci_credential --workspace-id rejects malformed role_arn" {
    _mock_iltero_cli "{\"provider\":\"aws\",\"role_arn\":\"http://evil.example/role\",\"region\":\"${VALID_REGION}\"}" 0

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    assert_output_contains "malformed AWS role ARN"
}

@test "resolve_ci_credential --workspace-id prefers ILTERO_CLI_BIN over PATH" {
    _mock_iltero_cli '{"provider":"oracle"}' 0
    local pinned="${TEST_TEMP}/pinned-iltero"
    cat > "${pinned}" <<EOF
#!/bin/bash
cat <<'PAYLOAD'
{"provider":"aws","role_arn":"${VALID_ROLE_ARN}","region":"${VALID_REGION}"}
PAYLOAD
EOF
    chmod +x "${pinned}"
    export ILTERO_CLI_BIN="${pinned}"

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    assert_output_contains "aws"

    unset ILTERO_CLI_BIN
}

# =============================================================================
# Bounded retry — keyed on the CLI status-class exit codes (8/9/11 retry)
# =============================================================================

# Stateful mock: counts invocations in $counter, returns $first_exit until the
# last attempt, then valid AWS JSON + exit 0. Shadows sleep to skip the backoff.
_install_counting_mock() {
    local counter="$1" first_exit="$2" succeed_on="$3"
    local mock="${TEST_TEMP}/iltero"
    echo 0 > "${counter}"
    cat > "${mock}" <<EOF
#!/bin/bash
n=\$(cat "${counter}"); n=\$((n + 1)); echo "\${n}" > "${counter}"
if [[ "\${n}" -lt "${succeed_on}" ]]; then
    echo "transient" >&2
    exit ${first_exit}
fi
cat <<'JSON'
{"provider":"aws","role_arn":"${VALID_ROLE_ARN}","region":"${VALID_REGION}"}
JSON
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

@test "resolve_ci_credential retries a transient 5xx (exit 11) then succeeds" {
    local counter="${TEST_TEMP}/calls"
    _install_counting_mock "${counter}" 11 2   # fail once, succeed on 2nd
    sleep() { return 0; }

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    [[ "$(cat "${counter}")" -eq 2 ]]
}

@test "resolve_ci_credential retries a network error (exit 9) then succeeds" {
    local counter="${TEST_TEMP}/calls"
    _install_counting_mock "${counter}" 9 2
    sleep() { return 0; }

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 0
    [[ "$(cat "${counter}")" -eq 2 ]]
}

@test "resolve_ci_credential retries rate-limit (exit 8) up to the limit then fails" {
    local counter="${TEST_TEMP}/calls"
    _install_counting_mock "${counter}" 8 99   # never succeeds
    sleep() { return 0; }

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    [[ "$(cat "${counter}")" -eq 3 ]]          # max_attempts
    assert_output_contains "resolution failed"
}

@test "resolve_ci_credential does NOT retry a 401/403/404 (exit 4) and hints unbound env" {
    local counter="${TEST_TEMP}/calls"
    _install_counting_mock "${counter}" 4 99   # exit 4 is fail-fast
    sleep() { return 0; }

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    [[ "$(cat "${counter}")" -eq 1 ]]          # no retry
    assert_output_contains "credential is bound for this environment"
}

@test "resolve_ci_credential does NOT retry a usage error (exit 2)" {
    local counter="${TEST_TEMP}/calls"
    _install_counting_mock "${counter}" 2 99
    sleep() { return 0; }

    run resolve_ci_credential --workspace-id "${VALID_UUID}" "${VALID_ENV}"
    assert_exit_code 2
    [[ "$(cat "${counter}")" -eq 1 ]]
}

