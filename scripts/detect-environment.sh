#!/bin/bash
# =============================================================================
# Iltero Actions - Environment Detection
# =============================================================================
# Detects the target environment from the current git branch by matching
# against git_ref.name in the stack's config.yml.
#
# The git_ref → environment mapping enforces that each branch maps to exactly
# one environment per workspace (database-level constraint).
#
# For pull_request events, environment is resolved from the BASE branch (the
# merge target), not the head branch. Feature branches do not map to
# environments — compliance checks run against the target environment's
# policies.
#
# Usage:
#   source detect-environment.sh
#   ENVIRONMENT=$(detect_environment "/path/to/config.yml")
#
# Environment Variables Used:
#   GITHUB_REF        - Full git ref (e.g., refs/heads/main)
#   GITHUB_BASE_REF   - Base branch for PRs
#   GITHUB_EVENT_NAME - Event type (push, pull_request, etc.)
# =============================================================================

# =============================================================================
# Get the branch to resolve environment from.
#
# For PRs, this returns the BASE branch (merge target) — the environment the
# code will land in. For pushes, it returns the branch being pushed to.
# =============================================================================
get_current_branch() {
    local branch=""

    case "${GITHUB_EVENT_NAME:-push}" in
        pull_request|pull_request_target)
            # PR — resolve environment from the base (target) branch, not
            # the feature branch. The question is "what environment will
            # this code land in?", not "what branch am I on?"
            if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
                branch="$GITHUB_BASE_REF"
            else
                echo "ERROR: GITHUB_BASE_REF is not set for pull_request event" >&2
                echo ""
                return 1
            fi
            ;;
        push)
            if [[ "${GITHUB_REF:-}" =~ ^refs/heads/(.+)$ ]]; then
                branch="${BASH_REMATCH[1]}"
            elif [[ "${GITHUB_REF:-}" =~ ^refs/tags/(.+)$ ]]; then
                branch="${BASH_REMATCH[1]}"
            else
                echo "ERROR: Cannot determine branch from GITHUB_REF: ${GITHUB_REF:-<unset>}" >&2
                echo ""
                return 1
            fi
            ;;
        workflow_dispatch)
            # workflow_dispatch runs on the selected branch
            if [[ "${GITHUB_REF:-}" =~ ^refs/heads/(.+)$ ]]; then
                branch="${BASH_REMATCH[1]}"
            else
                echo "ERROR: Cannot determine branch from GITHUB_REF: ${GITHUB_REF:-<unset>}" >&2
                echo ""
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unsupported event type: ${GITHUB_EVENT_NAME:-<unset>}" >&2
            echo ""
            return 1
            ;;
    esac

    echo "$branch"
}

# =============================================================================
# Detect environment from config.yml git_ref mapping
#
# Returns the environment key on stdout and exit 0, or an empty string
# and exit 1 when no match is found. Callers must handle the failure.
# =============================================================================
detect_environment() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        echo ""
        return 1
    fi

    local current_branch
    if ! current_branch=$(get_current_branch); then
        echo ""
        return 1
    fi

    if [[ -z "$current_branch" ]]; then
        echo "ERROR: Could not determine current branch" >&2
        echo ""
        return 1
    fi

    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "DEBUG: Detecting environment for branch: $current_branch" >&2
    fi

    # Search all environments for matching git_ref.name
    local envs
    if ! envs=$(yq eval '.environments | keys | .[]' "$config_file" 2>&1); then
        echo "ERROR: Failed to parse environments from config: $envs" >&2
        echo ""
        return 1
    fi

    for env in $envs; do
        local ref_type
        ref_type=$(yq eval ".environments.${env}.git_ref.type // \"branch\"" "$config_file")
        local ref_name
        ref_name=$(yq eval ".environments.${env}.git_ref.name // \"\"" "$config_file")

        if [[ -z "$ref_name" ]]; then
            continue
        fi

        # Match based on ref type
        case "$ref_type" in
            branch)
                if [[ "$ref_name" == "$current_branch" ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched branch '$current_branch' to environment '$env'" >&2
                    fi
                    echo "$env"
                    return 0
                fi
                ;;
            tag)
                # For tags, exact string match only
                if [[ "$current_branch" == "$ref_name" ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched tag '$current_branch' to environment '$env'" >&2
                    fi
                    echo "$env"
                    return 0
                fi
                ;;
            pattern)
                # Regex pattern matching — fully anchored, guard against ERE parse errors
                if [[ "$current_branch" =~ ^${ref_name}$ ]] 2>/dev/null; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched pattern '$ref_name' to environment '$env'" >&2
                    fi
                    echo "$env"
                    return 0
                fi
                ;;
        esac
    done

    # No match found — fail explicitly (no fallback)
    echo "WARNING: No environment matched for branch '$current_branch'" >&2
    echo "Available git_ref mappings:" >&2

    for env in $envs; do
        local ref_name ref_type
        ref_name=$(yq eval ".environments.${env}.git_ref.name // \"(not configured)\"" "$config_file")
        ref_type=$(yq eval ".environments.${env}.git_ref.type // \"branch\"" "$config_file")
        echo "  - $env: $ref_name ($ref_type)" >&2
    done

    echo ""
    return 1
}

# =============================================================================
# Validate environment exists in config
# =============================================================================
validate_environment() {
    local config_file="$1"
    local environment="$2"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    local env_exists
    env_exists=$(yq eval ".environments.${environment} // null" "$config_file")

    if [[ "$env_exists" == "null" ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# Get all environments from config
# =============================================================================
get_all_environments() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "[]"
        return
    fi

    yq eval '.environments | keys' "$config_file" -o json
}
