#!/bin/bash
# =============================================================================
# Iltero Core - CI Credential Resolution
# =============================================================================
# Wraps `iltero ci-credential --json`. Validates the response shape strictly
# before exposing values, so a malformed response can never reach a downstream
# step.
#
# Exit Codes:
#   EXIT_SUCCESS (0) - Credential resolved
#   EXIT_ERROR   (2) - CLI failed, response malformed, or provider unsupported
#
# Module-level outputs after resolve_ci_credential():
#   CI_CREDENTIAL_PROVIDER
#   CI_CREDENTIAL_AWS_ROLE_ARN, CI_CREDENTIAL_AWS_REGION (when provider=aws)
# =============================================================================

if [[ -n "${ILTERO_CI_CREDENTIAL_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ILTERO_CI_CREDENTIAL_SOURCED=1

CI_CREDENTIAL_PROVIDER=""
CI_CREDENTIAL_AWS_ROLE_ARN=""
CI_CREDENTIAL_AWS_REGION=""

# RHS of `[[ … =~ … ]]` MUST be unquoted to be treated as a regex; quoting
# turns it into a literal substring match. The `readonly` guard prevents a
# caller from shadowing these constants in the calling shell.
readonly _ci_credential_uuid_regex='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly _ci_credential_env_key_regex='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
readonly _ci_credential_aws_role_arn_regex='^arn:aws:iam::[0-9]{12}:role(/[A-Za-z0-9+=,.@_-]+)+$'
# Region pattern accepts standard, GovCloud, and China partitions
# (e.g. us-east-1, us-gov-east-1, cn-north-1).
readonly _ci_credential_aws_region_regex='^[a-z]{2}(-[a-z]+){1,3}-[0-9]+$'

# Resolve the CI credential for a (stack, environment) or (workspace, environment).
# Args: --stack-id <uuid> <env_key>
#       --workspace-id <uuid> <env_key>
# Returns: 0 on success, 2 on error
resolve_ci_credential() {
    local scope_flag=""
    local scope_value=""
    local env_key=""
    local label=""

    # Parse flags: first arg is --stack-id or --workspace-id, second is its
    # value, third is the environment key.
    case "${1:-}" in
        --stack-id|--workspace-id)
            scope_flag="${1}"
            scope_value="${2:-}"
            env_key="${3:-}"
            ;;
        *)
            log_error "resolve_ci_credential: first argument must be --stack-id or --workspace-id"
            return "${EXIT_ERROR}"
            ;;
    esac
    label="${scope_flag#--}"   # "stack-id" / "workspace-id", for messages

    CI_CREDENTIAL_PROVIDER=""
    CI_CREDENTIAL_AWS_ROLE_ARN=""
    CI_CREDENTIAL_AWS_REGION=""

    if ! [[ "${scope_value}" =~ ${_ci_credential_uuid_regex} ]]; then
        log_error "${label} is missing or not a UUID"
        return "${EXIT_ERROR}"
    fi
    if ! [[ "${env_key}" =~ ${_ci_credential_env_key_regex} ]]; then
        log_error "environment is missing or contains unsupported characters"
        return "${EXIT_ERROR}"
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for CI credential resolution"
        return "${EXIT_ERROR}"
    fi

    log_info "Resolving CI credential for ${label}=${scope_value} (env=${env_key})"

    # Prefer the absolute path exported by setup (ILTERO_CLI_BIN); fall back
    # to a bare `iltero` lookup for direct callers that did not run setup.
    local cmd=(
        "${ILTERO_CLI_BIN:-iltero}" ci-credential
        "${scope_flag}" "${scope_value}"
        --env "${env_key}"
        --json
    )

    local response
    local cli_exit
    local stderr_capture
    stderr_capture=$(mktemp)
    set +e
    response=$("${cmd[@]}" 2>"${stderr_capture}")
    cli_exit=$?
    set -e

    if [[ ${cli_exit} -ne 0 ]]; then
        log_error "CI credential resolution failed (exit ${cli_exit})"
        local stderr_text
        stderr_text=$(<"${stderr_capture}")
        if [[ -n "${stderr_text}" ]]; then
            log_error "iltero stderr: ${stderr_text}"
        fi
        rm -f "${stderr_capture}"
        return "${EXIT_ERROR}"
    fi
    rm -f "${stderr_capture}"

    if ! printf '%s' "${response}" | jq empty &>/dev/null; then
        log_error "CI credential response is not valid JSON"
        return "${EXIT_ERROR}"
    fi

    local provider
    provider=$(printf '%s' "${response}" | jq -r '.provider // empty')
    if [[ -z "${provider}" ]]; then
        log_error "CI credential response missing provider"
        return "${EXIT_ERROR}"
    fi

    case "${provider}" in
        aws)
            _ci_credential_parse_aws "${response}" || return $?
            ;;
        gcp|azure)
            log_error "CI credential provider '${provider}' is not supported by this action"
            return "${EXIT_ERROR}"
            ;;
        *)
            log_error "CI credential response has unknown provider"
            return "${EXIT_ERROR}"
            ;;
    esac

    CI_CREDENTIAL_PROVIDER="${provider}"
    log_success "CI credential resolved (provider=${provider})"
    return "${EXIT_SUCCESS}"
}

# Inspect terraform stdout/stderr for credential-related failure markers and
# emit an actionable hint pointing at the cloud-auth gating in the composite.
# Args: $1=output_text
emit_cloud_credentials_hint_if_needed() {
    local output="$1"
    if [[ -z "${output}" ]]; then
        return 0
    fi
    # Markers selected to avoid false positives: drop "access denied" (matches
    # IAM-policy denials with valid credentials) and "signature did not match"
    # (typically clock skew, not credential absence).
    if printf '%s' "${output}" | grep -qiE 'Unable to locate credentials|NoCredentialProviders|InvalidClientTokenId|ExpiredToken|could not load credentials|no valid providers in chain'; then
        log_error ""
        log_error "Hint: terraform reports missing or invalid cloud credentials."
        log_error "Ensure the calling job grants 'permissions: id-token: write'"
        log_error "and that this stack and environment have a CI credential bound."
    fi
}

_ci_credential_parse_aws() {
    local response="$1"

    local role_arn
    local region
    role_arn=$(printf '%s' "${response}" | jq -r '.role_arn // empty')
    region=$(printf '%s' "${response}" | jq -r '.region // empty')

    if [[ -z "${role_arn}" || -z "${region}" ]]; then
        log_error "CI credential response missing required AWS fields"
        return "${EXIT_ERROR}"
    fi
    if ! [[ "${role_arn}" =~ ${_ci_credential_aws_role_arn_regex} ]]; then
        log_error "CI credential response has malformed AWS role ARN"
        return "${EXIT_ERROR}"
    fi
    if ! [[ "${region}" =~ ${_ci_credential_aws_region_regex} ]]; then
        log_error "CI credential response has malformed AWS region"
        return "${EXIT_ERROR}"
    fi

    CI_CREDENTIAL_AWS_ROLE_ARN="${role_arn}"
    CI_CREDENTIAL_AWS_REGION="${region}"
    return "${EXIT_SUCCESS}"
}

