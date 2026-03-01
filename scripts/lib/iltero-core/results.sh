#!/bin/bash
# =============================================================================
# Iltero Core - Per-Stack Results Tracking
# =============================================================================
# File-based accumulation of per-unit scan/eval/deploy results for each stack.
# Uses .iltero/{stack}/results.json to avoid shell quoting issues with complex
# JSON. Consistent with existing .iltero/{stack}/ convention (state-status/,
# static/, evaluation/).
#
# Usage:
#   init_stack_results "my-stack"
#   append_unit_result "my-stack" "vpc" "$scan_json" "$eval_json" "$deploy_json"
#   results=$(get_stack_results "my-stack")
#   all=$(get_all_results)
# =============================================================================

# Prevent double-sourcing
if [[ -n "${ILTERO_RESULTS_SOURCED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
export ILTERO_RESULTS_SOURCED=1

# Base directory for results (set per-invocation)
ILTERO_RESULTS_BASE=""

# Initialize results tracking for a stack
# Creates .iltero/{stack}/results.json as an empty JSON array
# Args: $1=stack_name
init_stack_results() {
    local stack_name="${1:?Stack name is required}"

    ILTERO_RESULTS_BASE="$(pwd)/.iltero"
    local results_dir="${ILTERO_RESULTS_BASE}/${stack_name}"
    local results_file="${results_dir}/results.json"

    mkdir -p "${results_dir}"
    echo '[]' > "${results_file}"

    log_debug "Results tracking initialized at: ${results_file}"
}

# Append a unit result entry to the stack's results file
# Args: $1=stack_name $2=unit_name $3=scan_json $4=eval_json $5=deploy_json
#
# Each JSON arg should be a JSON object (or "null"/"" for skipped phases).
# The function wraps them into a structured entry:
# {
#   "unit": "<unit_name>",
#   "scan": { ... },
#   "evaluation": { ... },
#   "deploy": { ... }
# }
append_unit_result() {
    local stack_name="${1:?Stack name is required}"
    local unit_name="${2:?Unit name is required}"
    local scan_json="${3:-null}"
    local eval_json="${4:-null}"
    local deploy_json="${5:-null}"

    local results_file="${ILTERO_RESULTS_BASE}/${stack_name}/results.json"

    if [[ ! -f "${results_file}" ]]; then
        log_warning "Results file not found for stack '${stack_name}', initializing"
        init_stack_results "${stack_name}"
    fi

    # Normalize empty strings to null
    [[ -z "${scan_json}" ]] && scan_json="null"
    [[ -z "${eval_json}" ]] && eval_json="null"
    [[ -z "${deploy_json}" ]] && deploy_json="null"

    # Build the entry and append to the array
    local tmp_file
    tmp_file=$(mktemp)

    jq --arg unit "${unit_name}" \
       --argjson scan "${scan_json}" \
       --argjson eval "${eval_json}" \
       --argjson deploy "${deploy_json}" \
       '. += [{"unit": $unit, "scan": $scan, "evaluation": $eval, "deploy": $deploy}]' \
       "${results_file}" > "${tmp_file}" && mv "${tmp_file}" "${results_file}"

    log_debug "Appended result for unit '${unit_name}' in stack '${stack_name}'"
}

# Get accumulated results for a single stack
# Args: $1=stack_name
# Outputs: JSON array to stdout
get_stack_results() {
    local stack_name="${1:?Stack name is required}"
    local results_file="${ILTERO_RESULTS_BASE}/${stack_name}/results.json"

    if [[ ! -f "${results_file}" ]]; then
        echo '[]'
        return 0
    fi

    cat "${results_file}"
}

# Aggregate results from all processed stacks into a single JSON array
# Outputs: JSON array to stdout
get_all_results() {
    if [[ -z "${ILTERO_RESULTS_BASE}" ]] || [[ ! -d "${ILTERO_RESULTS_BASE}" ]]; then
        echo '[]'
        return 0
    fi

    local all_results="[]"

    for results_file in "${ILTERO_RESULTS_BASE}"/*/results.json; do
        if [[ -f "${results_file}" ]]; then
            all_results=$(jq -s '.[0] + .[1]' <(echo "${all_results}") "${results_file}")
        fi
    done

    echo "${all_results}"
}
