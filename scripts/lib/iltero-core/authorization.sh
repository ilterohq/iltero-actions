#!/bin/bash
# =============================================================================
# Iltero Core - Authorization
# =============================================================================
# Wraps `iltero stack authorize-deployment`. Streams the CLI's own
# success/denial message to the workflow log; we only interpret its exit code.
# =============================================================================

# Verify deployment authorization via the Iltero CLI.
# Args: $1=run_id $2=stack_id $3=environment (unused, kept for caller compat)
#       $4=unit (optional) $5=plan_digest (optional) $6=canonicalization_version (optional)
# When a plan_digest is supplied, the backend additionally verifies that the
# digest of the plan about to be applied matches the digest recorded under the
# run at evaluate time (provenance integrity), denying on mismatch. The backend
# is the authority for this comparison — the runner only submits the digest.
# Returns: 0 authorized, 1 denied, 2 error
verify_authorization() {
    local run_id="$1"
    local stack_id="$2"
    # shellcheck disable=SC2034  # $3 is intentionally unused. authorize-deployment
    # exposes no --environment option; forwarding it makes the CLI exit 2 (unknown
    # option) and fails the gate. Kept in the signature for caller compatibility.
    local _environment="$3"
    local unit_name="$4"
    local plan_digest="${5:-}"
    local canon_version="${6:-}"

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
    if [[ -n "${plan_digest}" ]]; then
        cli_args+=(--plan-digest "${plan_digest}")
        if [[ -n "${canon_version}" ]]; then
            cli_args+=(--canonicalization-version "${canon_version}")
        fi
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
