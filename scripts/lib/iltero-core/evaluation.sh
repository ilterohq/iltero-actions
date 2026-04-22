#!/bin/bash
# =============================================================================
# Iltero Core - Plan Evaluation
# =============================================================================
# Functions for running Terraform plan evaluation via Iltero CLI.
#
# Remote State Handling Flow:
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 1. Check dependency remote state status (via depends_on parameter)      │
# │ 2. If any dependency has unavailable state → use -backend=false        │
# │ 3. If no deps or all deps available → try with backend first           │
# │ 4. If backend init fails on remote state → fallback to -backend=false  │
# │ 5. Update unit's remote state status for downstream dependencies       │
# │ 6. Always run plan and evaluate (never skip the unit entirely)         │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Evaluation passed, no violations above threshold
#   EXIT_VIOLATIONS (1) - Evaluation found violations above fail_on threshold
#   EXIT_ERROR (2)      - Evaluation failed (Terraform error, API error, etc.)
#
# Exports after run_plan_evaluation():
#   EVAL_RUN_ID, EVAL_SCAN_ID, EVAL_PASSED, EVAL_VIOLATIONS, EVAL_EXIT_CODE,
#   APPROVAL_ID, PLAN_JSON_FILE, PLAN_URL, EVAL_MODE
#
# EVAL_MODE values:
#   "full"        - Full evaluation with backend (remote state available)
#   "best_effort" - Evaluation without backend (remote state unavailable)
# =============================================================================

# Run terraform plan and evaluate against policies
# Args: $1=path $2=stack_id $3=unit $4=environment $5=fail_on $6=run_id $7=plan_file $8=depends_on $9=frameworks (optional)
# Sets: EVAL_RUN_ID, EVAL_SCAN_ID, EVAL_PASSED, EVAL_VIOLATIONS, EVAL_EXIT_CODE, APPROVAL_ID, PLAN_JSON_FILE, EVAL_MODE
run_plan_evaluation() {
    local eval_path="$1"
    local stack_id="$2"
    local unit_name="$3"
    local environment="$4"
    local fail_on="${5:-high}"
    local chain_run_id="${6:-}"
    local existing_plan="${7:-}"
    local depends_on="${8:-}"
    local frameworks="${9:-}"

    local results_file
    local results_dir
    results_dir="$(pwd)/.iltero/${ILTERO_STACK_NAME:?ILTERO_STACK_NAME not set}/evaluation"
    mkdir -p "${results_dir}"
    results_file="${results_dir}/evaluation-${unit_name}-$(date +%s).json"

    # Reset outputs
    EVAL_RUN_ID=""
    EVAL_SCAN_ID=""
    EVAL_PASSED="false"
    EVAL_VIOLATIONS="0"
    EVAL_EXIT_CODE=0
    APPROVAL_ID=""
    PLAN_JSON_FILE=""
    PLAN_URL=""
    EVAL_MODE="full"

    log_group "Plan Evaluation: ${unit_name}"

    # Use existing plan or generate one
    if [[ -n "${existing_plan}" ]] && [[ -f "${existing_plan}" ]]; then
        log_info "Using existing plan file: ${existing_plan}"
        PLAN_JSON_FILE="${existing_plan}"
    else
        # Work in unit directory
        pushd "${eval_path}" > /dev/null

        # =====================================================================
        # Step 1: Check dependency status to determine if remote state refs are available
        # =====================================================================
        local dep_state_status
        dep_state_status=$(check_dependency_remote_state "${depends_on}")
        log_info "Dependency remote state check: ${dep_state_status}"
        
        if [[ "${dep_state_status}" == "unavailable" ]]; then
            # One or more dependencies don't have remote state available
            if [[ -n "${DEP_CHECK_DETAILS:-}" ]]; then
                log_warning "Dependencies missing remote state: ${DEP_CHECK_DETAILS}"
            fi
            log_info "Will disable remote state dependencies in plan"
            EVAL_MODE="best_effort"
        fi

        # =====================================================================
        # Step 2: Initialize terraform (always with backend for this unit's state)
        # =====================================================================
        # Resolve backend config before init (partial backend configs need -backend-config)
        log_info "Working directory: $(pwd)"
        log_info "Resolving env config: eval_path=${eval_path} environment=${environment}"
        check_env_config "${eval_path}" "${environment}"
        log_info "Resolved: BACKEND_HCL=${BACKEND_HCL:-<empty>} TFVARS_FILE=${TFVARS_FILE:-<empty>}"

        local init_args=(-input=false)
        if [[ -n "${BACKEND_HCL}" ]]; then
            init_args+=(-backend-config="${BACKEND_HCL}")
        fi

        log_info "Running: terraform init ${init_args[*]}"
        local init_output
        set +e
        init_output=$(terraform init "${init_args[@]}" 2>&1)
        local init_exit=$?
        set -e

        if [[ ${init_exit} -ne 0 ]]; then
            log_step "terraform init" "FAILED"
            echo ""
            echo "${init_output}" | grep -A 5 "Error:" | head -30 || echo "${init_output}" | tail -20
            log_result "FAIL" "Plan evaluation aborted: terraform init failed for ${unit_name}"
            update_unit_remote_state_status "${unit_name}" "unavailable" "init_failed"
            popd > /dev/null
            log_group_end
            EVAL_EXIT_CODE=2
            return 1
        fi

        log_step "terraform init" "ok"

        # Extract S3 backend config from terraform's local state (works for all stack types)
        local s3_bucket="" s3_key_prefix="" s3_region=""
        local tf_backend_state=".terraform/terraform.tfstate"
        if [[ -f "${tf_backend_state}" ]]; then
            local backend_type
            backend_type=$(jq -r '.backend.type // empty' "${tf_backend_state}" 2>/dev/null || echo "")
            if [[ "${backend_type}" == "s3" ]]; then
                s3_bucket=$(jq -r '.backend.config.bucket // empty' "${tf_backend_state}")
                s3_region=$(jq -r '.backend.config.region // empty' "${tf_backend_state}")
                # Strip the .tfstate filename to get the key prefix
                local s3_key
                s3_key=$(jq -r '.backend.config.key // empty' "${tf_backend_state}")
                s3_key_prefix="${s3_key%/*}"
            fi
        fi

        # =====================================================================
        # Step 2.5: Check if THIS unit has existing state in the backend
        # This determines if downstream units can reference our remote state
        # =====================================================================
        local has_backend_state=false
        set +e
        local state_output
        state_output=$(terraform state list 2>&1)
        local state_exit=$?
        set -e
        
        if [[ ${state_exit} -eq 0 ]] && [[ -n "${state_output}" ]]; then
            has_backend_state=true
            log_info "Unit has existing backend state ($(echo "${state_output}" | wc -l | tr -d ' ') resources)"
            update_unit_remote_state_status "${unit_name}" "available" "has_backend_state"
        else
            log_info "Unit has no backend state yet (not deployed)"
            update_unit_remote_state_status "${unit_name}" "unavailable" "no_backend_state"
        fi

        # =====================================================================
        # Step 3: Build and run terraform plan
        # =====================================================================
        local plan_args=(-out=tfplan -input=false)

        # If dependencies are unavailable, disable remote state loading in terraform
        # This allows plan to succeed for policy evaluation even when deps aren't deployed
        if [[ "${EVAL_MODE}" == "best_effort" ]]; then
            plan_args+=(-var="enable_remote_state_dependencies=false")
            log_info "Disabling remote state dependencies (dependencies not yet deployed)"
        fi

        # Use tfvars resolved earlier by check_env_config
        if [[ -n "${TFVARS_FILE}" ]]; then
            plan_args+=(-var-file="${TFVARS_FILE}")
            log_info "Using tfvars: ${TFVARS_FILE}"
        else
            log_warning "No tfvars file found for environment: ${environment}"
        fi

        # Run terraform plan
        log_info "Running: terraform plan ${plan_args[*]}"
        local plan_output
        set +e
        plan_output=$(terraform plan "${plan_args[@]}" 2>&1)
        local plan_exit=$?
        set -e

        if [[ ${plan_exit} -ne 0 ]] || [[ ! -f "tfplan" ]]; then
            # Check if this is a remote state reference error
            if echo "${plan_output}" | grep -qE "Unable to find remote state|No stored state was found|Error loading state"; then
                log_warning "Remote state unavailable for ${unit_name} (upstream dependency not deployed)"
                update_unit_remote_state_status "${unit_name}" "unavailable" "remote_state_reference_error"
            else
                update_unit_remote_state_status "${unit_name}" "unavailable" "plan_failed"
            fi

            log_step "terraform plan" "FAILED"
            echo ""
            echo "${plan_output}" | grep -A 5 "Error:" | head -50 || echo "${plan_output}" | tail -30
            
            log_result "FAIL" "Plan evaluation aborted: terraform plan failed for ${unit_name}"
            popd > /dev/null
            log_group_end
            EVAL_EXIT_CODE=2  # Infrastructure error (not policy violation)
            EVAL_PASSED="false"
            return 1
        fi

        local resource_count
        resource_count=$(echo "${state_output}" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${has_backend_state}" == "true" ]]; then
            log_step "terraform plan" "ok" "${resource_count} existing resources"
        else
            log_step "terraform plan" "ok" "no existing state"
        fi
        
        # Note: Unit state availability was already determined by `terraform state list`
        # after init - we don't update it here based on plan success

        # Convert plan to JSON (full terraform plan JSON for policy evaluation)
        terraform show -json tfplan > tfplan.json 2>/dev/null
        PLAN_JSON_FILE="$(pwd)/tfplan.json"

        # Upload plan JSON to S3 alongside the state file
        local plan_s3_url=""
        if [[ -n "${s3_bucket}" ]] && [[ -n "${s3_key_prefix}" ]]; then
            local plan_s3_key="${s3_key_prefix}/plans/${chain_run_id:-$(date +%s)}-tfplan.json"
            log_info "Uploading plan JSON to s3://${s3_bucket}/${plan_s3_key}"
            if aws s3 cp "${PLAN_JSON_FILE}" "s3://${s3_bucket}/${plan_s3_key}" \
                --region "${s3_region:-us-east-1}" 2>&1 | tail -1; then
                plan_s3_url="s3://${s3_bucket}/${plan_s3_key}"
                log_info "Plan uploaded successfully"
            else
                log_warning "Failed to upload plan to S3 (non-fatal, continuing)"
            fi
        fi

        # Export current STATE (not plan) for audit trail and drift detection baseline
        # Note: `terraform show -json` (no args) shows the current state from the backend,
        # NOT the plan. This will be empty/minimal if the unit hasn't been deployed yet.
        # The plan JSON above contains the planned changes; this is the pre-existing state.
        local state_json_file
        state_json_file="$(pwd)/tfstate-before-plan.json"
        set +e
        terraform show -json > "${state_json_file}" 2>/dev/null
        local state_export_exit=$?
        set -e

        if [[ ${state_export_exit} -ne 0 ]] || [[ ! -s "${state_json_file}" ]]; then
            log_info "No existing state to export (unit not yet deployed or state is empty)"
            state_json_file=""
        else
            log_info "Exported current state to: ${state_json_file}"
        fi

        popd > /dev/null
    fi

    # Ensure OPA policy directory exists (policies will be resolved from Iltero backend)
    local opa_policy_dir="${ILTERO_OPA_POLICY_DIR:-${PWD}/.iltero/opa-policies}"
    mkdir -p "${opa_policy_dir}"

    # =====================================================================
    # Step 3.5: Generate resource source map for violation file paths
    # =====================================================================
    local source_map_file="${eval_path}/resource_source_map.json"
    log_info "Generating resource source map..."
    set +e
    iltero scan generate-source-map --path "${eval_path}" --output "${source_map_file}"
    local source_map_exit=$?
    set -e

    if [[ ${source_map_exit} -ne 0 ]] || [[ ! -f "${source_map_file}" ]]; then
        log_warning "Source map generation failed (violations will use 'plan.json')"
        source_map_file=""
    fi

    # Run evaluation
    local cmd=(
        iltero scan evaluation "${PLAN_JSON_FILE}"
        --stack-id "${stack_id}"
        --unit "${unit_name}"
        --environment "${environment}"
        --fail-on "${fail_on}"
        --output json
        --output-file "${results_file}"
        --opa-policy-dir "${opa_policy_dir}"
        --resolve-policies
    )

    # Pass source map for accurate violation file paths
    if [[ -n "${source_map_file}" ]] && [[ -f "${source_map_file}" ]]; then
        cmd+=(--opa-source-map "${source_map_file}")
    fi

    # Provide full terraform plan JSON for compliance evaluation
    # The plan file is the first argument, but we also pass it via --terraform-plan-json
    # for the backend submission (includes resource changes, provider configs, etc.)
    cmd+=(--terraform-plan-json "${PLAN_JSON_FILE}")
    
    # Provide current terraform state JSON if available (for drift baseline and audit)
    if [[ -n "${state_json_file:-}" ]] && [[ -f "${state_json_file:-}" ]]; then
        cmd+=(--terraform-state-json "${state_json_file}")
    fi

    # Add GitHub context if available
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        cmd+=(--external-run-id "${GITHUB_RUN_ID}")
        cmd+=(--external-run-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}")
    fi

    if [[ -n "${chain_run_id}" ]]; then
        log_info "Chaining evaluation to run ID: ${chain_run_id}"
        cmd+=(--run-id "${chain_run_id}")
    fi

    # Pass frameworks if configured
    if [[ -n "${frameworks}" ]]; then
        cmd+=(--frameworks "${frameworks}")
    fi

    # Pass plan URL if upload succeeded
    if [[ -n "${plan_s3_url:-}" ]]; then
        cmd+=(--plan-url "${plan_s3_url}")
    fi

    # Note: Upload happens via Compliance API using scan_id from policy resolution
    # No --skip-upload needed - the CLI handles this automatically

    log_info "Running: ${cmd[*]}"
    set +e
    "${cmd[@]}"
    EVAL_EXIT_CODE=$?
    set -e

    PLAN_URL="${plan_s3_url:-}"

    # Extract results
    if [[ -f "${results_file}" ]]; then
        EVAL_RUN_ID=$(jq -r '.run_id // empty' "${results_file}" 2>/dev/null || echo "")
        # Extract scan_id from policy resolution (required for apply phase)
        EVAL_SCAN_ID=$(jq -r '.scan_id // empty' "${results_file}" 2>/dev/null || echo "")
        APPROVAL_ID=$(jq -r '.approval_id // empty' "${results_file}" 2>/dev/null || echo "")
        
        # Calculate violations at or above threshold severity
        # Severity levels: critical > high > medium > low > info
        local critical high medium low
        critical=$(jq -r '.summary.critical // 0' "${results_file}" 2>/dev/null || echo "0")
        high=$(jq -r '.summary.high // 0' "${results_file}" 2>/dev/null || echo "0")
        medium=$(jq -r '.summary.medium // 0' "${results_file}" 2>/dev/null || echo "0")
        low=$(jq -r '.summary.low // 0' "${results_file}" 2>/dev/null || echo "0")
        
        case "${fail_on}" in
            critical)
                EVAL_VIOLATIONS=${critical}
                ;;
            high)
                EVAL_VIOLATIONS=$((critical + high))
                ;;
            medium)
                EVAL_VIOLATIONS=$((critical + high + medium))
                ;;
            low)
                EVAL_VIOLATIONS=$((critical + high + medium + low))
                ;;
            *)
                # Default to all failed checks if threshold not recognized
                EVAL_VIOLATIONS=$(jq -r '.summary.failed // (.violations | length) // 0' "${results_file}" 2>/dev/null || echo "0")
                ;;
        esac
        
        if [[ -n "${EVAL_SCAN_ID}" ]]; then
            log_info "Scan ID: ${EVAL_SCAN_ID}"
        fi

        # Structured policy results
        local total_evaluated passed_count failed_count
        total_evaluated=$(jq -r '.summary.total // 0' "${results_file}" 2>/dev/null || echo "0")
        passed_count=$(jq -r '.summary.passed // 0' "${results_file}" 2>/dev/null || echo "0")
        failed_count=$(jq -r '.summary.failed // 0' "${results_file}" 2>/dev/null || echo "0")

        log_info "Mode: ${EVAL_MODE}"
        log_info "Threshold: ${fail_on}"
        echo ""
        log_info "Policy results: ${total_evaluated} evaluated, ${passed_count} passed, ${failed_count} failed"
        log_info "  critical  ${critical}"
        log_info "  high      ${high}"
        log_info "  medium    ${medium}"
        log_info "  low       ${low}"
        echo ""
    else
        log_warning "Results file not found: ${results_file}"
    fi

    if [[ ${EVAL_EXIT_CODE} -eq 0 ]]; then
        EVAL_PASSED="true"
        if [[ "${EVAL_MODE}" == "best_effort" ]]; then
            log_result "PASS" "Plan evaluation passed (best-effort mode, ${EVAL_VIOLATIONS} violations)"
        else
            log_result "PASS" "Plan evaluation passed (${EVAL_VIOLATIONS} policy violations)"
        fi
    else
        EVAL_PASSED="false"
        if [[ "${EVAL_VIOLATIONS}" -gt 0 ]]; then
            log_result "FAIL" "${EVAL_VIOLATIONS} policy violations at or above '${fail_on}' threshold"
        else
            log_result "FAIL" "Plan evaluation failed for ${unit_name} (exit code: ${EVAL_EXIT_CODE})"
        fi
    fi

    if [[ -n "${APPROVAL_ID}" ]]; then
        log_info "Approval ID: ${APPROVAL_ID}"
    fi

    log_group_end
    return ${EVAL_EXIT_CODE}
}
