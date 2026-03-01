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
# Usage:
#   source detect-environment.sh
#   ENVIRONMENT=$(detect_environment "/path/to/config.yml")
#
# Environment Variables Used:
#   GITHUB_REF      - Full git ref (e.g., refs/heads/main)
#   GITHUB_BASE_REF - Base branch for PRs
#   GITHUB_HEAD_REF - Head branch for PRs
# =============================================================================

# =============================================================================
# Get current branch name from GitHub context
# =============================================================================
get_current_branch() {
    local branch=""
    
    # Handle different GitHub event types
    if [[ -n "${GITHUB_HEAD_REF:-}" ]]; then
        # Pull request - use head branch
        branch="$GITHUB_HEAD_REF"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/heads/(.+)$ ]]; then
        # Push to branch
        branch="${BASH_REMATCH[1]}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/tags/(.+)$ ]]; then
        # Tag push - extract tag name
        branch="${BASH_REMATCH[1]}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/pull/[0-9]+/merge$ ]]; then
        # PR merge ref - use base branch
        branch="${GITHUB_BASE_REF:-develop}"
    else
        # Fallback to develop
        branch="develop"
    fi
    
    echo "$branch"
}

# =============================================================================
# Detect environment from config.yml git_ref mapping
# =============================================================================
detect_environment() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "development"
        return
    fi
    
    local current_branch
    current_branch=$(get_current_branch)
    
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "DEBUG: Detecting environment for branch: $current_branch" >&2
    fi
    
    # Search all environments for matching git_ref.name
    local envs
    envs=$(yq eval '.environments | keys | .[]' "$config_file" 2>/dev/null)
    
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
                    return
                fi
                ;;
            tag)
                # For tags, check if current ref matches tag pattern
                if [[ "$current_branch" == "$ref_name" ]] || [[ "$current_branch" =~ ^${ref_name} ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched tag '$current_branch' to environment '$env'" >&2
                    fi
                    echo "$env"
                    return
                fi
                ;;
            pattern)
                # Regex pattern matching
                if [[ "$current_branch" =~ ${ref_name} ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched pattern '$ref_name' to environment '$env'" >&2
                    fi
                    echo "$env"
                    return
                fi
                ;;
        esac
    done
    
    # No git_ref match — try using first environment key as fallback
    local first_env
    first_env=$(yq eval '.environments | keys | .[0]' "$config_file" 2>/dev/null)
    if [[ -n "$first_env" ]] && [[ "$first_env" != "null" ]]; then
        echo "WARNING: No git_ref match for '$current_branch', using first environment: $first_env" >&2
        echo "$first_env"
        return
    fi

    # No environments configured at all — provide helpful error message
    echo "ERROR: No environment found with git_ref.name matching '$current_branch'" >&2
    echo "Available environments and their git_ref mappings:" >&2

    for env in $envs; do
        local ref_name
        ref_name=$(yq eval ".environments.${env}.git_ref.name // \"(not configured)\"" "$config_file")
        local ref_type
        ref_type=$(yq eval ".environments.${env}.git_ref.type // \"branch\"" "$config_file")
        echo "  - $env: $ref_name ($ref_type)" >&2
    done

    # Default to development with warning
    echo "WARNING: Falling back to 'development' environment" >&2
    echo "development"
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
