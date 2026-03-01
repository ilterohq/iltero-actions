#!/bin/bash
# =============================================================================
# Iltero Core - Authorization
# =============================================================================
# Functions for verifying deployment authorization via Iltero backend.
# =============================================================================

# Verify deployment authorization via Iltero backend
# Args: $1=run_id $2=stack_id $3=environment $4=unit
# Returns: 0 if authorized, 1 if blocked, 2 if error
verify_authorization() {
    local run_id="$1"
    local stack_id="$2"
    local environment="$3"
    local unit_name="$4"

    if [[ -z "$run_id" ]]; then
        log_error "run-id is required for deployment authorization"
        return 2
    fi

    log_info "Verifying deployment authorization..."

    set +e
    local auth_output
    auth_output=$(iltero deploy authorize \
        --run-id "$run_id" \
        --stack-id "$stack_id" \
        --environment "$environment" \
        --unit "$unit_name" \
        --output json 2>&1)
    local auth_exit=$?
    set -e

    case $auth_exit in
        0)
            log_success "Deployment authorized"
            _record_external_approval "$run_id"
            return 0
            ;;
        1)
            local reason message
            reason=$(echo "$auth_output" | jq -r '.reason // "unknown"' 2>/dev/null || echo "unknown")
            message=$(echo "$auth_output" | jq -r '.message // "Not authorized"' 2>/dev/null || echo "Not authorized")
            log_error "Deployment blocked: $message (reason: $reason)"
            return 1
            ;;
        *)
            log_error "Failed to verify authorization (exit code: $auth_exit)"
            log_error "Output: $auth_output"
            return 2
            ;;
    esac
}

# Record external approval from GitHub (internal helper)
# Args: $1=run_id
_record_external_approval() {
    local run_id="$1"

    if [[ -z "${GITHUB_ACTOR:-}" ]]; then
        return 0
    fi

    log_info "Recording external approval from GitHub..."
    set +e
    iltero stack approvals record-external \
        --run-id "$run_id" \
        --source github_environment \
        --approver-id "$GITHUB_ACTOR" \
        --reference "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
        2>/dev/null || log_warning "Could not record external approval (non-fatal)"
    set -e
}
