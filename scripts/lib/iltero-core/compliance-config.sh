#!/bin/bash
# =============================================================================
# Iltero Core - Compliance settings from a stack's config.yml
# =============================================================================
# One place that reads the compliance frameworks a stack declares for an
# environment, so every entry point derives the same value from the same file:
# the all-in-one pipeline action and the standalone scan / evaluate actions.
#
# The part of config.yml this reads:
#
#   environments:
#     production:
#       compliance:
#         frameworks: [SOC2, ISO27001, CIS-AWS]
#
# The value becomes the `--frameworks` argument of the Iltero CLI, which is
# what scopes a scan to those frameworks.
# =============================================================================

# Fail unless a lookup produced exactly one result.
#
# Two causes, both malformed input: a file holding more than one YAML document
# (yq emits one result per document), or an environment name containing * or ?,
# which yq matches as a glob and so answers for several environments at once.
# Either way a test against one expected value reads the wrong answer.
#
# Callers must request compact output (yq -I0) when asking for JSON, so one
# line means one result rather than one line of pretty-printing.
#
# Args: $1=config_file  $2=yq output to check
_assert_single_document() {
    local config_file="${1}"
    local output="${2}"

    if [[ "$(wc -l <<< "${output}" | tr -d " ")" -ne 1 ]]; then
        log_error "Expected a single result from ${config_file}: a stack config is one YAML document, and environment names must be literal keys (no * or ?)" >&2
        return "${EXIT_ERROR}"
    fi
    return "${EXIT_SUCCESS}"
}

# Read the frameworks configured for one environment, as a comma-separated list.
#
# Args:   $1=config_file  $2=environment
# Prints: "SOC2,ISO27001,CIS-AWS" — or nothing when the key is absent or empty
# Returns 0 on success, EXIT_ERROR (2) when the key is present but malformed.
#
# When the key is absent this prints nothing and succeeds: the caller then sends
# no `--frameworks` argument and Iltero decides which policies apply from the
# stack's own registration. Guessing a framework here would replace that with a
# worse answer.
#
# Callers read the value from standard output, so every message goes to standard
# error instead — otherwise the diagnostics would land in the caller's variable
# and never reach the log.
read_environment_frameworks() {
    local config_file="${1}"
    local environment="${2}"

    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}" >&2
        return "${EXIT_ERROR}"
    fi

    # The environment name is handed to yq as a value rather than spliced into
    # the query text, so a name containing a dot or a yq operator is looked up
    # as a literal key instead of being reinterpreted as part of the query.
    local frameworks_json
    if ! frameworks_json=$(ILTERO_ENV_KEY="${environment}" yq eval \
        '.environments[strenv(ILTERO_ENV_KEY)].compliance.frameworks // []' \
        "${config_file}" -o json -I0); then
        log_error "Could not read environments.${environment}.compliance.frameworks from ${config_file}" >&2
        return "${EXIT_ERROR}"
    fi

    _assert_single_document "${config_file}" "${frameworks_json}" || return "${EXIT_ERROR}"

    # A malformed value is an error, never an empty list. Scanning against zero
    # frameworks succeeds while proving nothing, which is the worst outcome a
    # compliance gate can produce.
    if ! jq -e 'type == "array"' <<< "${frameworks_json}" > /dev/null 2>&1; then
        {
            log_error "environments.${environment}.compliance.frameworks must be a list of framework names (in ${config_file})"
            log_error "  expected: frameworks: [SOC2, ISO27001]"
            log_error "  found:    frameworks: $(jq -c '.' <<< "${frameworks_json}" 2>/dev/null || printf '%s' "${frameworks_json}")"
        } >&2
        return "${EXIT_ERROR}"
    fi

    if ! jq -e 'all(.[]; type == "string" and length > 0)' <<< "${frameworks_json}" > /dev/null 2>&1; then
        {
            log_error "environments.${environment}.compliance.frameworks must contain only non-empty framework names (in ${config_file})"
            log_error "  expected: frameworks: [SOC2, ISO27001]"
            log_error "  found:    frameworks: $(jq -c '.' <<< "${frameworks_json}")"
        } >&2
        return "${EXIT_ERROR}"
    fi

    jq -r 'join(",")' <<< "${frameworks_json}"
}

# Is an environment declared in a stack's config.yml?
#
# Args:    $1=config_file  $2=environment
# Returns: 0 when declared, 1 when not, EXIT_ERROR when the file is unreadable.
#
# An undeclared environment name yields no compliance settings at all, so a
# caller that treats it as "nothing configured" scans against no frameworks and
# reports success. Callers check this first and stop.
#
# The name is handed to yq as a value rather than spliced into the query, so a
# name containing a dot or a yq operator is looked up as a literal key.
environment_declared() {
    local config_file="${1}"
    local environment="${2}"

    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}" >&2
        return "${EXIT_ERROR}"
    fi

    local found
    if ! found=$(ILTERO_ENV_KEY="${environment}" yq eval \
        '(.environments // {}) | has(strenv(ILTERO_ENV_KEY))' \
        "${config_file}"); then
        log_error "Could not read environments from ${config_file}" >&2
        return "${EXIT_ERROR}"
    fi
    _assert_single_document "${config_file}" "${found}" || return "${EXIT_ERROR}"

    [[ "${found}" == "true" ]]
}
