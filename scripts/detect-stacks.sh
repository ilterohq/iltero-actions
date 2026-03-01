#!/bin/bash
# =============================================================================
# Iltero Actions - Stack Detection
# =============================================================================
# Detects which stacks have changed based on git diff of modified files.
#
# A stack is detected if any file under ${STACKS_PATH}/${stack}/ has changed
# and the stack has a valid config.yml file.
#
# Usage:
#   source detect-stacks.sh
#   STACKS_JSON=$(detect_stacks "/path/to/stacks")
#
# Environment Variables Used:
#   GITHUB_EVENT_NAME - Event type (push, pull_request, etc.)
#   GITHUB_BASE_REF   - Base branch for PRs
# =============================================================================

# =============================================================================
# Get changed files from git
# =============================================================================
get_changed_files() {
    local changed_files=""
    
    case "${GITHUB_EVENT_NAME:-push}" in
        pull_request|pull_request_target)
            # For PRs, compare against base branch
            if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
                git fetch origin "$GITHUB_BASE_REF" --depth=1 2>/dev/null || true
                changed_files=$(git diff --name-only "origin/$GITHUB_BASE_REF"...HEAD 2>/dev/null || echo "")
            fi
            ;;
        push)
            # For pushes, compare against previous commit
            changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD 2>/dev/null || echo "")
            ;;
        workflow_dispatch|schedule)
            # For manual/scheduled runs, no automatic detection
            # Return empty to process all stacks or rely on manual input
            changed_files=""
            ;;
        *)
            # Default: compare against previous commit
            changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
            ;;
    esac
    
    echo "$changed_files"
}

# =============================================================================
# Detect stacks from changed files
# =============================================================================
detect_stacks() {
    local stacks_path="$1"
    
    # Normalize path (remove trailing slash)
    stacks_path="${stacks_path%/}"
    
    # Get changed files
    local changed_files
    changed_files=$(get_changed_files)
    
    if [[ -z "$changed_files" ]]; then
        # No changed files detected - check if this is workflow_dispatch
        if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
            # For manual dispatch without file changes, list all stacks
            if [[ "${DEBUG:-}" == "true" ]]; then
                echo "DEBUG: workflow_dispatch with no changes, listing all stacks" >&2
            fi
            list_all_stacks "$stacks_path"
            return
        fi
        
        echo "[]"
        return
    fi
    
    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "DEBUG: Changed files:" >&2
        echo "$changed_files" | head -20 >&2
    fi
    
    # Extract unique stacks from changed file paths
    local stacks=()
    local seen_stacks=""
    
    while IFS= read -r file; do
        # Check if file is under stacks_path
        if [[ "$file" =~ ^${stacks_path}/([a-zA-Z0-9][a-zA-Z0-9_-]*)/.*$ ]]; then
            local stack="${BASH_REMATCH[1]}"
            
            # Skip if already seen
            if [[ "$seen_stacks" == *"|$stack|"* ]]; then
                continue
            fi
            
            # Validate stack has config.yml
            local config_file="${stacks_path}/${stack}/config.yml"
            if [[ -f "$config_file" ]]; then
                stacks+=("$stack")
                seen_stacks="${seen_stacks}|$stack|"
                
                if [[ "${DEBUG:-}" == "true" ]]; then
                    echo "DEBUG: Detected stack: $stack (from $file)" >&2
                fi
            fi
        fi
    done <<< "$changed_files"
    
    # Convert to JSON array
    if [[ ${#stacks[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${stacks[@]}" | jq -R . | jq -s .
    fi
}

# =============================================================================
# Detect brownfield stack from config file
# =============================================================================
detect_brownfield_stack() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "[]"
        return
    fi

    # Read terraform_working_directory from config
    local tf_dir
    tf_dir=$(yq eval '.stack.terraform_working_directory // "."' "$config_file")

    local changed_files
    changed_files=$(get_changed_files)

    if [[ -z "$changed_files" ]]; then
        if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
            # Always process on manual dispatch
            echo '["brownfield"]'
            return
        fi
        echo "[]"
        return
    fi

    # Check if any changed files are under terraform_working_directory or .iltero/
    local trigger=false
    while IFS= read -r file; do
        if [[ "$file" == .iltero/* ]]; then
            trigger=true
            break
        fi
        if [[ "$tf_dir" == "." ]]; then
            # Root directory: trigger on .tf files and .iltero changes only
            if [[ "$file" == *.tf ]]; then
                trigger=true
                break
            fi
        else
            # Specific directory: trigger on any file under it
            local normalized_tf_dir="${tf_dir%/}"
            if [[ "$file" == "${normalized_tf_dir}"/* ]]; then
                trigger=true
                break
            fi
        fi
    done <<< "$changed_files"

    if [[ "$trigger" == "true" ]]; then
        echo '["brownfield"]'
    else
        echo "[]"
    fi
}

# =============================================================================
# List all stacks in stacks directory
# =============================================================================
list_all_stacks() {
    local stacks_path="$1"
    local stacks=()
    
    # Find all directories with config.yml
    for dir in "$stacks_path"/*/; do
        if [[ -d "$dir" ]]; then
            local stack
            stack=$(basename "$dir")
            local config_file="${dir}config.yml"
            
            if [[ -f "$config_file" ]]; then
                stacks+=("$stack")
            fi
        fi
    done
    
    if [[ ${#stacks[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${stacks[@]}" | jq -R . | jq -s .
    fi
}

# =============================================================================
# Validate stack exists and has valid config
# =============================================================================
validate_stack() {
    local stacks_path="$1"
    local stack="$2"
    
    local stack_dir="${stacks_path}/${stack}"
    local config_file="${stack_dir}/config.yml"
    
    if [[ ! -d "$stack_dir" ]]; then
        echo "ERROR: Stack directory not found: $stack_dir" >&2
        return 1
    fi
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    # Basic validation of config structure
    local stack_id
    stack_id=$(yq eval '.stack.id // ""' "$config_file" 2>/dev/null)
    if [[ -z "$stack_id" ]]; then
        echo "ERROR: stack.id is required in $config_file" >&2
        return 1
    fi
    
    return 0
}
