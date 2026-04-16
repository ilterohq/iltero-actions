#!/bin/bash
# =============================================================================
# Iltero Core - Authorization
# =============================================================================
# Wraps `iltero stack authorize-deployment`. Streams the CLI's own
# success/denial message to the workflow log; we only interpret its exit code.
# =============================================================================

# Verify deployment authorization via the Iltero CLI.
# Args: $1=run_id $2=stack_id $3=environment (unused, kept for caller compat)
#       $4=unit (optional)
# Returns: 0 authorized, 1 denied, 2 error
verify_authorization() {
    local run_id="$1"
    local stack_id="$2"
    local _environment="$3"
    local unit_name="$4"

    if [[ -z "${run_id}" ]]; then
        log_error "run-id is required for deployment authorization"
        return 2
    fi
    if [[ -z "${stack_id}" ]]; then
        log_error "stack-id is required for deployment authorization"
        return 2
    fi

    log_info "Verifying deployment authorization..."

    local cli_args=(
        --stack-id "${stack_id}"
        --run-id "${run_id}"
    )
    if [[ -n "${unit_name}" ]]; then
        cli_args+=(--unit "${unit_name}")
    fi

    set +e
    iltero stack authorize-deployment "${cli_args[@]}"
    local auth_exit=$?
    set -e

    case ${auth_exit} in
        0)
            log_success "Deployment authorized"
            return 0
            ;;
        10)
            log_error "Deployment blocked (see message above)"
            return 1
            ;;
        2)
            log_error "Authentication failed while verifying deployment authorization"
            return 2
            ;;
        9)
            log_error "Network failure while verifying deployment authorization"
            return 2
            ;;
        *)
            log_error "Unexpected exit code ${auth_exit} from iltero stack authorize-deployment"
            return 2
            ;;
    esac
}
