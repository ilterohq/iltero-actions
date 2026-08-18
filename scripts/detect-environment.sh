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
# Usage (branch on the exit code — see detect_environment below):
#   source detect-environment.sh
#   rc=0; env=$(detect_environment "/path/to/config.yml") || rc=$?
#     rc 0 -> use "$env"   |   rc 3 -> no env maps to this ref (skip)
#     rc 2 -> config error (fail)
#
# Environment Variables Used:
#   GITHUB_REF        - Full git ref (e.g., refs/heads/main)
#   GITHUB_BASE_REF   - Base branch for PRs
#   GITHUB_EVENT_NAME - Event type (push, pull_request, etc.)
# =============================================================================

# Guard against re-sourcing — the readonly constants below would error on a
# second source. Not exported: an exported guard would make a child shell skip
# the function definitions.
if [[ -n "${ILTERO_DETECT_ENVIRONMENT_SOURCED:-}" ]]; then
    # shellcheck disable=SC2317  # dual-mode: returns when sourced, exits when run
    return 0 2>/dev/null || exit 0
fi
ILTERO_DETECT_ENVIRONMENT_SOURCED=1

# detect_environment() exit codes — the caller contract. Distinguishing a
# benign no-match from a real config error lets callers skip the former and
# fail loud on the latter, instead of collapsing both into one signal.
readonly DETECT_ENV_MATCHED=0    # matched exactly one environment (key on stdout)
readonly DETECT_ENV_ERROR=2      # missing/unreadable/malformed config, or branch undeterminable
readonly DETECT_ENV_NO_MATCH=3   # config parsed; current ref maps to no environment

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
                branch="${GITHUB_BASE_REF}"
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

    echo "${branch}"
}

# Is an environment name a literal key rather than a pattern?
#
# yq matches keys by glob, so a name containing * or ? answers for environments
# the caller never asked about: "prod?" reads its own settings and "prod1"'s
# together, and the two-line result then equals neither. Every setting read that
# way falls back to its default — an approval requirement silently becomes
# "not required". Names come from config.yml, so a pattern there is a config
# error and callers stop rather than read the wrong environment's settings.
#
# Args:    $1=environment name
# Returns: 0 when the name is a literal key, 1 when it would glob.
env_name_is_literal() {
    [[ "${1}" != *[*?]* ]]
}

# =============================================================================
# Detect environment from config.yml git_ref mapping
#
# Exit codes (see the constants above):
#   DETECT_ENV_MATCHED (0)  - env key on stdout
#   DETECT_ENV_NO_MATCH (3) - config parsed but no env maps to the current ref
#                             (empty stdout; a benign "skip this stack" signal)
#   DETECT_ENV_ERROR (2)    - missing/unreadable/malformed config, or the branch
#                             could not be determined (empty stdout; hard fail)
# Callers MUST branch on the exit code, never on the stderr text.
# =============================================================================
detect_environment() {
    local config_file="$1"

    if [[ ! -f "${config_file}" ]]; then
        echo "ERROR: Config file not found: ${config_file}" >&2
        echo ""
        return "${DETECT_ENV_ERROR}"
    fi

    local current_branch
    if ! current_branch=$(get_current_branch); then
        echo ""
        return "${DETECT_ENV_ERROR}"
    fi

    if [[ -z "${current_branch}" ]]; then
        echo "ERROR: Could not determine current branch" >&2
        echo ""
        return "${DETECT_ENV_ERROR}"
    fi

    if [[ "${DEBUG:-}" == "true" ]]; then
        echo "DEBUG: Detecting environment for branch: ${current_branch}" >&2
    fi

    # Search all environments for matching git_ref.name
    local envs
    if ! envs=$(yq eval '.environments | keys | .[]' "${config_file}" 2>&1); then
        echo "ERROR: Failed to parse environments from config: ${envs}" >&2
        echo ""
        return "${DETECT_ENV_ERROR}"
    fi

    # Reject pattern names before matching anything, so that which environment
    # happens to be listed first does not decide whether a malformed config is
    # caught. An empty `environments:` map yields one empty line here, not none.
    local env
    while IFS= read -r env; do
        [[ -n "${env}" ]] || continue
        if ! env_name_is_literal "${env}"; then
            echo "ERROR: Environment name '${env}' contains * or ?; names must be literal keys" >&2
            echo ""
            return "${DETECT_ENV_ERROR}"
        fi
    done <<< "${envs}"

    # Read line by line rather than splitting on whitespace: an environment
    # name containing a space would otherwise be split into two names, which
    # match nothing — the same failure the strenv() lookup below fixes, one
    # layer up. Unquoted expansion would also glob-expand a name.
    while IFS= read -r env; do
        [[ -n "${env}" ]] || continue
        local ref_type
        ref_type=$(ILTERO_ENV_KEY="${env}" yq eval '.environments[strenv(ILTERO_ENV_KEY)].git_ref.type // "branch"' "${config_file}")
        local ref_name
        ref_name=$(ILTERO_ENV_KEY="${env}" yq eval '.environments[strenv(ILTERO_ENV_KEY)].git_ref.name // ""' "${config_file}")

        if [[ -z "${ref_name}" ]]; then
            continue
        fi

        # Match based on ref type
        case "${ref_type}" in
            branch)
                if [[ "${ref_name}" == "${current_branch}" ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched branch '${current_branch}' to environment '${env}'" >&2
                    fi
                    echo "${env}"
                    return 0
                fi
                ;;
            tag)
                # For tags, exact string match only
                if [[ "${current_branch}" == "${ref_name}" ]]; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched tag '${current_branch}' to environment '${env}'" >&2
                    fi
                    echo "${env}"
                    return 0
                fi
                ;;
            pattern)
                # Regex pattern matching — fully anchored, guard against ERE parse errors
                if [[ "${current_branch}" =~ ^${ref_name}$ ]] 2>/dev/null; then
                    if [[ "${DEBUG:-}" == "true" ]]; then
                        echo "DEBUG: Matched pattern '${ref_name}' to environment '${env}'" >&2
                    fi
                    echo "${env}"
                    return 0
                fi
                ;;
        esac
    done <<< "${envs}"

    # No environment maps to the current ref. This is a benign "skip" signal,
    # distinct from a config error — callers may skip the stack gracefully.
    echo "WARNING: No environment matched for branch '${current_branch}'" >&2
    echo "Available git_ref mappings:" >&2

    # Read line by line rather than splitting on whitespace: an environment
    # name containing a space would otherwise be split into two names, which
    # match nothing — the same failure the strenv() lookup below fixes, one
    # layer up. Unquoted expansion would also glob-expand a name.
    while IFS= read -r env; do
        # An empty `environments:` map yields one empty line here, not none.
        [[ -n "${env}" ]] || continue
        local ref_name ref_type
        ref_name=$(ILTERO_ENV_KEY="${env}" yq eval '.environments[strenv(ILTERO_ENV_KEY)].git_ref.name // "(not configured)"' "${config_file}")
        ref_type=$(ILTERO_ENV_KEY="${env}" yq eval '.environments[strenv(ILTERO_ENV_KEY)].git_ref.type // "branch"' "${config_file}")
        echo "  - ${env}: ${ref_name} (${ref_type})" >&2
    done <<< "${envs}"

    echo ""
    return "${DETECT_ENV_NO_MATCH}"
}

# Note: multi-config agreement across a stacks directory now lives in the CLI
# (`iltero environment detect`), which `resolve-credentials` calls directly so
# the credential step has no `yq` dependency. `detect_environment` above stays
# for `run-pipeline.sh`'s per-stack (single-config) detection.

# =============================================================================
# Validate environment exists in config
# =============================================================================
validate_environment() {
    local config_file="$1"
    local environment="$2"

    if [[ ! -f "${config_file}" ]]; then
        return 1
    fi

    # A pattern is not a key. has() below answers exactly, but every setting the
    # caller goes on to read is indexed, and indexing globs — so admitting a
    # name that globs hands back another environment's settings.
    env_name_is_literal "${environment}" || return 1

    # strenv() rather than env(): env() parses its value as YAML, so a name that
    # is not a valid scalar makes yq fail — and an unchecked failure would leave
    # this empty, which any "is it declared" comparison reads as yes.
    #
    # has() rather than indexing: [] does glob matching, so a name of "*" would
    # match every environment and answer for one the caller never asked about.
    local env_exists
    if ! env_exists=$(ILTERO_ENV_KEY="${environment}" yq eval \
        '(.environments // {}) | has(strenv(ILTERO_ENV_KEY))' "${config_file}"); then
        return 1
    fi

    [[ "${env_exists}" == "true" ]]
}

# =============================================================================
# Get all environments from config
# =============================================================================
get_all_environments() {
    local config_file="$1"

    if [[ ! -f "${config_file}" ]]; then
        echo "[]"
        return
    fi

    yq eval '.environments | keys' "${config_file}" -o json
}
