#!/bin/bash
# =============================================================================
# Iltero Core - Deployment
# =============================================================================
# Functions for running Terraform deployments and notifying Iltero API.
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Deployment completed successfully
#   EXIT_VIOLATIONS (1) - Deployment blocked by policy violations
#   EXIT_ERROR (2)      - Deployment failed (Terraform error, API error, etc.)
#
# Exports after run_deployment():
#   DEPLOY_SUCCESS, RESOURCES_COUNT, OUTPUTS_FILE
# =============================================================================

# Run terraform deployment
# Args: $1=path $2=unit $3=environment $4=run_id (optional) $5=scan_id (optional)
# Sets: DEPLOY_SUCCESS, RESOURCES_COUNT, OUTPUTS_FILE, TERRAFORM_STATE_FILE
run_deployment() {
    local deploy_path="$1"
    local unit_name="$2"
    local environment="$3"
    local run_id="${4:-}"
    local scan_id="${5:-${ILTERO_SCAN_ID:-}}"

    # Reset outputs
    DEPLOY_SUCCESS="false"
    RESOURCES_COUNT="0"
    OUTPUTS_FILE=""
    TERRAFORM_STATE_FILE=""

    log_group "Deploy: ${unit_name}"

    pushd "$deploy_path" > /dev/null

    # Check for environment config
    check_env_config "$deploy_path" "$environment"

    # Initialize Terraform with backend
    if [[ -n "$BACKEND_HCL" ]]; then
        log_info "Initializing with backend config: $BACKEND_HCL"
        terraform init -backend-config="$BACKEND_HCL" -reconfigure -input=false
    else
        log_info "Initializing without backend config"
        terraform init -input=false
    fi

    # Create plan
    local plan_file="${unit_name}.tfplan"
    if [[ -n "$TFVARS_FILE" ]]; then
        terraform plan -var-file="$TFVARS_FILE" -out="$plan_file" -input=false
    else
        terraform plan -out="$plan_file" -input=false
    fi

    # Apply
    set +e
    terraform apply -auto-approve "$plan_file"
    local apply_exit=$?
    set -e

    if [[ $apply_exit -eq 0 ]]; then
        DEPLOY_SUCCESS="true"

        # Export outputs
        OUTPUTS_FILE="/tmp/${unit_name}_outputs.json"
        terraform output -json > "$OUTPUTS_FILE"

        # Get resource count
        RESOURCES_COUNT=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

        # Export terraform state JSON after apply (for audit trail and drift baseline)
        TERRAFORM_STATE_FILE="/tmp/${unit_name}_state.json"
        set +e
        terraform show -json > "$TERRAFORM_STATE_FILE" 2>/dev/null
        local state_export_exit=$?
        set -e
        
        if [[ $state_export_exit -ne 0 ]] || [[ ! -s "$TERRAFORM_STATE_FILE" ]]; then
            log_warning "Could not export terraform state JSON after apply"
            TERRAFORM_STATE_FILE=""
        else
            log_info "Exported terraform state to: $TERRAFORM_STATE_FILE"
        fi

        # Notify API with terraform state data
        notify_apply_result "$run_id" "$scan_id" "$unit_name" "$environment" "true" "$RESOURCES_COUNT" "$TERRAFORM_STATE_FILE"

        log_success "Deployment complete: $RESOURCES_COUNT resources"
    else
        # Notify API of failure (no state file on failure)
        notify_apply_result "$run_id" "$scan_id" "$unit_name" "$environment" "false" "0" ""

        log_error "Deployment failed for ${unit_name}"
    fi

    popd > /dev/null
    log_group_end

    [[ "$DEPLOY_SUCCESS" == "true" ]] && return 0 || return 1
}

# Notify Iltero API of apply result
# Args: $1=run_id $2=scan_id $3=unit $4=environment $5=success $6=resources_count $7=terraform_state_file
notify_apply_result() {
    local run_id="$1"
    local scan_id="$2"
    local unit_name="$3"
    local environment="$4"
    local success="$5"
    local resources_count="$6"
    local terraform_state_file="${7:-}"

    if [[ -z "$run_id" ]]; then
        log_debug "No run ID, skipping API notification"
        return 0
    fi
    
    if [[ -z "$scan_id" ]]; then
        log_warning "No scan ID provided, API notification may fail (scan_id is required)"
    fi

    local cmd=(
        iltero scan apply
        --run-id "$run_id"
        --unit "$unit_name"
        --environment "$environment"
        --resources-count "$resources_count"
        --output json
    )
    
    # Add required scan_id parameter
    if [[ -n "$scan_id" ]]; then
        cmd+=(--scan-id "$scan_id")
    fi
    
    # Provide terraform state JSON for audit trail (from 'terraform show -json')
    if [[ -n "$terraform_state_file" ]] && [[ -f "$terraform_state_file" ]]; then
        cmd+=(--terraform-state-json "$terraform_state_file")
        log_info "Including terraform state JSON in apply notification"
    fi

    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        cmd+=(--external-run-id "$GITHUB_RUN_ID")
        cmd+=(--external-run-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}")
    fi

    if [[ "$success" == "true" ]]; then
        cmd+=(--success)
    else
        cmd+=(--failed)
    fi

    set +e
    "${cmd[@]}" || log_warning "Failed to notify API of deployment"
    set -e
}
