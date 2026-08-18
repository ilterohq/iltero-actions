#!/bin/bash
# =============================================================================
# Iltero Core - Common Utilities
# =============================================================================
# Shared utilities: exit codes, progress indicators, and helper functions.
# =============================================================================

# Prevent double-sourcing
if [[ -n "${ILTERO_UTILS_SOURCED:-}" ]]; then
    # shellcheck disable=SC2317  # dual-mode: returns when sourced, exits when run
    return 0 2>/dev/null || exit 0
fi
export ILTERO_UTILS_SOURCED=1

# =============================================================================
# EXIT CODE CONSTANTS
# =============================================================================
# Standard exit codes for consistent error handling across all modules.
#
# Usage in functions:
#   return $EXIT_SUCCESS      # Operation succeeded
#   return $EXIT_VIOLATIONS   # Operation succeeded but found violations
#   return $EXIT_ERROR        # Operation failed due to error
# =============================================================================

readonly EXIT_SUCCESS=0       # Operation completed successfully
readonly EXIT_VIOLATIONS=1    # Violations found (not an error, but needs attention)
readonly EXIT_ERROR=2         # Actual error (API failure, timeout, invalid input)

# =============================================================================
# PROGRESS INDICATORS
# =============================================================================

# State for spinner
_PROGRESS_PID=""
_PROGRESS_ACTIVE=false

# Start a spinner/progress indicator for long-running operations
# Args: $1=message
# Usage: start_progress "Processing..."; long_operation; stop_progress
start_progress() {
    local message="${1:-Processing}"
    
    # Only show progress in interactive terminals
    if [[ ! -t 1 ]] || [[ -n "${CI:-}" ]]; then
        echo "${message}"
        return 0
    fi
    
    _PROGRESS_ACTIVE=true
    
    # Background spinner
    (
        local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r%s %s" "${spin_chars:${i}:1}" "${message}"
            i=$(( (i + 1) % ${#spin_chars} ))
            sleep 0.1
        done
    ) &
    _PROGRESS_PID=$!
    
    # Ensure cleanup on exit
    trap 'stop_progress' EXIT
}

# Stop the progress indicator
stop_progress() {
    if [[ "${_PROGRESS_ACTIVE}" == "true" ]] && [[ -n "${_PROGRESS_PID}" ]]; then
        kill "${_PROGRESS_PID}" 2>/dev/null || true
        wait "${_PROGRESS_PID}" 2>/dev/null || true
        printf "\r%s\n" "                                        "  # Clear line
        _PROGRESS_PID=""
        _PROGRESS_ACTIVE=false
    fi
}

# Show a countdown timer
# Args: $1=seconds $2=message
show_countdown() {
    local seconds="$1"
    local message="${2:-Waiting}"
    
    while [[ ${seconds} -gt 0 ]]; do
        printf "\r%s: %ds remaining " "${message}" "${seconds}"
        sleep 1
        ((seconds--))
    done
    printf "\r%s: done                \n" "${message}"
}

# Show dots progress for polling operations
# Args: $1=message $2=current_dots
# Returns: Updated dots string
show_polling_dots() {
    local message="$1"
    local dots="${2:-}"
    
    dots+="."
    if [[ ${#dots} -gt 60 ]]; then
        dots=""
        echo ""  # New line
    fi
    printf "\r%s%s" "${message}" "${dots}"
    echo "${dots}"
}

# =============================================================================
# VALIDATION UTILITIES
# =============================================================================

# Check if required commands are available
# Args: $@=command names
# Returns: 0=all available, 2=missing commands
require_commands() {
    local missing=()
    
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return "${EXIT_ERROR}"
    fi
    
    return "${EXIT_SUCCESS}"
}

# Check if required environment variables are set
# Args: $@=variable names
# Returns: 0=all set, 2=missing variables
require_env_vars() {
    local missing=()
    
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        return "${EXIT_ERROR}"
    fi
    
    return "${EXIT_SUCCESS}"
}

# =============================================================================
# JSON UTILITIES
# =============================================================================

# Safely extract value from JSON
# Args: $1=json $2=jq_expression $3=default_value
# Outputs: Extracted value or default
json_get() {
    local json="$1"
    local expr="$2"
    local default="${3:-}"
    
    local result
    result=$(echo "${json}" | jq -r "${expr} // empty" 2>/dev/null)
    
    if [[ -z "${result}" ]]; then
        echo "${default}"
    else
        echo "${result}"
    fi
}

# Check if JSON has a specific boolean value
# Args: $1=json $2=key
# Returns: 0=true, 1=false or missing
json_is_true() {
    local json="$1"
    local key="$2"
    
    local value
    value=$(echo "${json}" | jq -r ".${key} // false" 2>/dev/null)
    
    [[ "${value}" == "true" ]]
}

# =============================================================================
# TEMP FILE MANAGEMENT
# =============================================================================

# Create a temp file with automatic cleanup
# Args: $1=prefix
# Outputs: Path to temp file
create_temp_file() {
    local prefix="${1:-iltero}"
    local temp_file
    temp_file=$(mktemp "/tmp/${prefix}-XXXXXX")
    
    # Register for cleanup on exit - use single quotes to delay expansion
    # shellcheck disable=SC2064
    trap 'rm -f "'"${temp_file}"'"' EXIT
    
    echo "${temp_file}"
}

# =============================================================================
# PATH INPUT VALIDATION
# =============================================================================

# Reject a caller-supplied path that is not a simple relative path.
# Args: $1=input name (for the message)  $2=value
# Returns: 0 when acceptable, EXIT_ERROR otherwise.
#
# These values become directory components the runner writes into. A traversal
# would put results outside the workspace, where a workspace-relative artifact
# upload silently finds nothing while the run still reports success. An empty
# value is accepted — callers decide whether the input is required.
#
# The all-in-one action carries its own copy of this check because it validates
# before the library is sourced.
reject_path() {
    local name="${1}"
    local value="${2}"

    [[ -z "${value}" ]] && return 0

    case "${value}" in
        /*|*..*|*'$'*|*'`'*|*'*'*|*'?'*|*'['*)
            log_error "${name} must be a simple relative path: ${value}"
            return "${EXIT_ERROR}"
            ;;
    esac
    if [[ ! "${value}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        log_error "${name} contains disallowed characters: ${value}"
        return "${EXIT_ERROR}"
    fi
    return "${EXIT_SUCCESS}"
}

# The last thing a command said, for a wrapper that has no better diagnosis.
#
# When a scan or evaluation produces no verdict, the tool's own last line is
# usually the only thing that names the cause. A generic message in its place
# ("did not complete — re-run") describes a transient failure, and this state
# often is not transient: a run that stopped because a scanner is missing fails
# identically on every re-run, so the advice is worse than no advice.
#
# One line, carriage returns stripped. Callers prefix it, so the result cannot
# begin a line and cannot be read by the runner as a command.
#
# Args:   $1=path to the captured output
# Prints: the last non-blank line, or nothing
last_diagnostic_line() {
    local log_file="${1:-}"
    [[ -s "${log_file}" ]] || return 0
    grep -v '^[[:space:]]*$' "${log_file}" | tail -n 1 | tr -d '\r'
}
