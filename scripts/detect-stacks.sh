#!/bin/bash
# =============================================================================
# Iltero Actions - Stack Detection
# =============================================================================
# Detects which stacks have changed based on git diff of modified files.
#
# Detection is driven by code changes under ${STACKS_PATH}/${stack}/. Config
# is resolved from ${STACKS_CONFIG}/${stack}/config.yml (exported by the
# pipeline before this script is sourced).
#
# Usage:
#   source detect-stacks.sh
#   STACKS_JSON=$(detect_stacks "/path/to/stacks")
#
# Environment Variables Used:
#   STACKS_CONFIG     - Path to stacks metadata directory (set by pipeline)
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
                git fetch origin "${GITHUB_BASE_REF}" --depth=1 2>/dev/null || true
                changed_files=$(git diff --name-only "origin/${GITHUB_BASE_REF}"...HEAD 2>/dev/null || echo "")
            fi
            ;;
        push)
            # For pushes, compare against previous commit
            changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only HEAD 2>/dev/null || echo "")
            ;;
        workflow_dispatch|schedule)
            # For manual/scheduled runs, no automatic detection
            changed_files=""
            ;;
        *)
            # Default: compare against previous commit
            changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
            ;;
    esac

    echo "${changed_files}"
}

# =============================================================================
# Detect stacks from changed files
# =============================================================================
detect_stacks() {
    local stacks_path="${1}"

    # Normalize path (remove trailing slash)
    stacks_path="${stacks_path%/}"

    # STACKS_CONFIG is exported by the pipeline — required for config resolution
    local stacks_config="${STACKS_CONFIG:?STACKS_CONFIG must be set}"
    stacks_config="${stacks_config%/}"

    # Get changed files
    local changed_files
    changed_files=$(get_changed_files)

    if [[ -z "${changed_files}" ]]; then
        # No changed files detected — check if this is workflow_dispatch
        if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
            if [[ "${DEBUG:-}" == "true" ]]; then
                echo "DEBUG: workflow_dispatch with no changes, listing all stacks" >&2
            fi
            list_all_stacks
            return
        fi

        echo "[]"
        return
    fi

    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "DEBUG: Changed files:" >&2
        echo "${changed_files}" | head -20 >&2
    fi

    # Extract unique stacks from changed file paths.
    # Detection is driven by code changes only — config edits under
    # STACKS_CONFIG do not trigger a run (the config file is tool-owned).
    local stacks=()
    local seen_stacks=""

    while IFS= read -r file; do
        # Use prefix comparison instead of regex to avoid metachar issues
        # in stacks_path (e.g. dots matching any character)
        if [[ "${file}" == "${stacks_path}/"* ]]; then
            local remainder="${file#"${stacks_path}"/}"
            local stack="${remainder%%/*}"

            # Slug must match expected pattern and file must be inside the stack dir
            if [[ ! "${stack}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || [[ "${remainder}" != */* ]]; then
                continue
            fi

            # Skip if already seen
            [[ "${seen_stacks}" == *"|${stack}|"* ]] && continue

            # Config authority is in the metadata root
            local config_file="${stacks_config}/${stack}/config.yml"
            if [[ -f "${config_file}" ]]; then
                stacks+=("${stack}")
                seen_stacks="${seen_stacks}|${stack}|"

                if [[ "${DEBUG:-}" == "true" ]]; then
                    echo "DEBUG: Detected stack: ${stack} (from ${file})" >&2
                fi
            fi
        fi
    done <<< "${changed_files}"

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
    local config_file="${1}"

    if [[ ! -f "${config_file}" ]]; then
        echo "[]"
        return
    fi

    # Read terraform_working_directory from config
    local tf_dir
    tf_dir=$(yq eval '.stack.terraform_working_directory // "."' "${config_file}")

    local changed_files
    changed_files=$(get_changed_files)

    if [[ -z "${changed_files}" ]]; then
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
        if [[ "${file}" == .iltero/* ]]; then
            trigger=true
            break
        fi
        if [[ "${tf_dir}" == "." ]]; then
            # Root directory: trigger on .tf files and .iltero changes only
            if [[ "${file}" == *.tf ]]; then
                trigger=true
                break
            fi
        else
            # Specific directory: trigger on any file under it
            local normalized_tf_dir="${tf_dir%/}"
            if [[ "${file}" == "${normalized_tf_dir}"/* ]]; then
                trigger=true
                break
            fi
        fi
    done <<< "${changed_files}"

    if [[ "${trigger}" == "true" ]]; then
        echo '["brownfield"]'
    else
        echo "[]"
    fi
}

# =============================================================================
# List all stacks in stacks directory
# =============================================================================
list_all_stacks() {
    local stacks_config="${STACKS_CONFIG:?STACKS_CONFIG must be set}"
    stacks_config="${stacks_config%/}"
    local stacks=()

    # Iterate config directories — config authority lives in STACKS_CONFIG
    for dir in "${stacks_config}"/*/; do
        if [[ -d "${dir}" ]]; then
            local stack
            stack=$(basename "${dir}")

            # Defense-in-depth: slug must match the same regex as detect_stacks
            if [[ ! "${stack}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
                continue
            fi

            if [[ -f "${dir}config.yml" ]]; then
                stacks+=("${stack}")
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
    local stacks_path="${1}"
    local stack="${2}"
    local stacks_config="${STACKS_CONFIG:?STACKS_CONFIG must be set}"

    local stack_dir="${stacks_path}/${stack}"
    local config_file="${stacks_config%/}/${stack}/config.yml"

    if [[ ! -d "${stack_dir}" ]]; then
        echo "ERROR: Stack code directory not found: ${stack_dir}" >&2
        return 1
    fi

    if [[ ! -f "${config_file}" ]]; then
        echo "ERROR: Config file not found: ${config_file}" >&2
        return 1
    fi

    # Basic validation of config structure
    local stack_id
    stack_id=$(yq eval '.stack.id // ""' "${config_file}" 2>/dev/null)
    if [[ -z "${stack_id}" ]]; then
        echo "ERROR: stack.id is required in ${config_file}" >&2
        return 1
    fi

    return 0
}
