#!/bin/bash
# =============================================================================
# Iltero Core - Unit Validation
# =============================================================================
# Functions for validating Terraform unit structure and configuration.
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Validation passed
#   EXIT_VIOLATIONS (1) - Validation issues found
#   EXIT_ERROR (2)      - Invalid input or system error
# =============================================================================

# Required files for self-contained units
# Note: Don't use readonly here due to subshell issues in test frameworks
REQUIRED_UNIT_FILES=("main.tf" "providers.tf" "versions.tf" "backend.tf")

# Validate self-contained unit structure
# Args: $1=unit_path
# Returns: EXIT_SUCCESS=valid, EXIT_VIOLATIONS=missing files, EXIT_ERROR=invalid input
validate_unit_structure() {
    local unit_path="$1"
    local missing=()

    if [[ -z "$unit_path" ]]; then
        log_error "Unit path is required"
        return ${EXIT_ERROR:-2}
    fi

    if [[ ! -d "$unit_path" ]]; then
        log_error "Unit directory not found: $unit_path"
        return ${EXIT_ERROR:-2}
    fi

    for f in "${REQUIRED_UNIT_FILES[@]}"; do
        if [[ ! -f "$unit_path/$f" ]]; then
            missing+=("$f")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required terraform files: ${missing[*]}"
        log_error "Self-contained units must have: ${REQUIRED_UNIT_FILES[*]}"
        return ${EXIT_VIOLATIONS:-1}
    fi

    log_debug "Unit structure validated: $unit_path"
    return ${EXIT_SUCCESS:-0}
}

# Validate brownfield structure (relaxed — only requires .tf files)
# Args: $1=tf_dir
# Returns: EXIT_SUCCESS=valid, EXIT_VIOLATIONS=no tf files, EXIT_ERROR=invalid input
validate_brownfield_structure() {
    local tf_dir="$1"

    if [[ -z "$tf_dir" ]]; then
        log_error "Terraform directory path is required"
        return ${EXIT_ERROR:-2}
    fi

    if [[ ! -d "$tf_dir" ]]; then
        log_error "Terraform directory not found: $tf_dir"
        return ${EXIT_ERROR:-2}
    fi

    # For brownfield: only require that .tf files exist
    if ! ls "$tf_dir"/*.tf 1>/dev/null 2>&1; then
        log_error "No .tf files found in: $tf_dir"
        return ${EXIT_VIOLATIONS:-1}
    fi

    log_debug "Brownfield structure validated: $tf_dir"
    return ${EXIT_SUCCESS:-0}
}

# Check for environment-specific configuration files
# Args: $1=unit_path $2=environment
# Sets: TFVARS_FILE, BACKEND_HCL
check_env_config() {
    local unit_path="$1"
    local environment="$2"

    TFVARS_FILE=""
    BACKEND_HCL=""

    local tfvars="$unit_path/config/${environment}.tfvars"
    local backend="$unit_path/config/backend/${environment}.hcl"

    if [[ -f "$tfvars" ]]; then
        TFVARS_FILE="$tfvars"
        log_debug "Found tfvars: $tfvars"
    fi

    if [[ -f "$backend" ]]; then
        BACKEND_HCL="$backend"
        log_debug "Found backend config: $backend"
    fi
}
