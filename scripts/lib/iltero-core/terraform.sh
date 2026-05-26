#!/bin/bash
# =============================================================================
# Iltero Core - Terraform Plan Preparation
# =============================================================================
# Shared terraform init + plan flow used by both static scanning (when a
# plan is available) and policy evaluation. Handles the dependency
# best-effort fallback, S3 backend extraction, plan-JSON conversion, plan
# upload, and pre-plan state export.
#
# Exit Codes:
#   0 - Success; TF_PLAN_JSON_FILE is set
#   1 - terraform init failed
#   2 - terraform plan failed
#
# Module-level outputs after prepare_terraform_plan():
#   TF_PLAN_JSON_FILE        Absolute path to the plan JSON file
#   TF_STATE_JSON_FILE       Absolute path to the pre-plan state JSON, or ""
#   TF_PLAN_MODE             "full" | "best_effort"
#   TF_PLAN_S3_URL           s3:// URL of the uploaded plan, or ""
#   TF_BACKEND_S3_BUCKET     Bucket name when the unit uses an S3 backend
#   TF_BACKEND_S3_KEY_PREFIX Key prefix derived from the backend key
#   TF_BACKEND_S3_REGION     Backend region
# =============================================================================

if [[ -n "${ILTERO_TERRAFORM_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ILTERO_TERRAFORM_SOURCED=1

TF_PLAN_JSON_FILE=""
TF_STATE_JSON_FILE=""
TF_PLAN_MODE="full"
TF_PLAN_S3_URL=""
TF_BACKEND_S3_BUCKET=""
TF_BACKEND_S3_KEY_PREFIX=""
TF_BACKEND_S3_REGION=""

# cloud_credentials_present
# Returns 0 if any supported cloud has credentials present in the
# environment, 1 otherwise. Used to decide whether a terraform init+plan
# attempt has a realistic chance of succeeding (plan-mode) versus skipping
# straight to source-mode.
#
# Each entry is the env var the cloud's official auth Action exports after
# successful authentication. Add new providers here as adapters land —
# this is the single decision point so consumers stay cloud-agnostic. The
# list is function-local because bash arrays do not propagate to subshells
# (which `bats run` and similar test harnesses use).
#
#   AWS_ACCESS_KEY_ID            — aws-actions/configure-aws-credentials
#   GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_GHA_CREDS_PATH
#                                — google-github-actions/auth
#   AZURE_CLIENT_ID              — azure/login
cloud_credentials_present() {
    local var
    local cred_env_vars=(
        AWS_ACCESS_KEY_ID
        GOOGLE_APPLICATION_CREDENTIALS
        GOOGLE_GHA_CREDS_PATH
        AZURE_CLIENT_ID
    )
    for var in "${cred_env_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            return 0
        fi
    done
    return 1
}

# prepare_terraform_plan
# Args:
#   $1 = eval_path     absolute path to the unit directory
#   $2 = unit_name     unit name for state tracking and log lines
#   $3 = environment   environment slug
#   $4 = depends_on    comma-separated dependency unit names (optional)
#   $5 = chain_run_id  run id used for the plan S3 key (optional)
# Returns: 0 success, 1 init failed, 2 plan failed
prepare_terraform_plan() {
    local eval_path="$1"
    local unit_name="$2"
    local environment="$3"
    local depends_on="${4:-}"
    local chain_run_id="${5:-}"

    TF_PLAN_JSON_FILE=""
    TF_STATE_JSON_FILE=""
    TF_PLAN_MODE="full"
    TF_PLAN_S3_URL=""
    TF_BACKEND_S3_BUCKET=""
    TF_BACKEND_S3_KEY_PREFIX=""
    TF_BACKEND_S3_REGION=""

    if [[ -z "${eval_path}" || ! -d "${eval_path}" ]]; then
        log_error "prepare_terraform_plan: invalid eval_path '${eval_path}'"
        return 1
    fi

    pushd "${eval_path}" > /dev/null

    # -------------------------------------------------------------------------
    # Step 1: Dependency remote-state availability check
    # -------------------------------------------------------------------------
    local dep_state_status
    dep_state_status=$(check_dependency_remote_state "${depends_on}")
    log_info "Dependency remote state check: ${dep_state_status}"

    if [[ "${dep_state_status}" == "unavailable" ]]; then
        if [[ -n "${DEP_CHECK_DETAILS:-}" ]]; then
            log_warning "Dependencies missing remote state: ${DEP_CHECK_DETAILS}"
        fi
        log_info "Will disable remote state dependencies in plan"
        TF_PLAN_MODE="best_effort"
    fi

    # -------------------------------------------------------------------------
    # Step 2: terraform init
    # -------------------------------------------------------------------------
    log_info "Working directory: $(pwd)"
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
        emit_cloud_credentials_hint_if_needed "${init_output}"
        update_unit_remote_state_status "${unit_name}" "unavailable" "init_failed"
        popd > /dev/null
        return 1
    fi

    log_step "terraform init" "ok"

    # -------------------------------------------------------------------------
    # Step 2.5: Extract S3 backend config from terraform's local state
    # -------------------------------------------------------------------------
    local tf_backend_state=".terraform/terraform.tfstate"
    if [[ -f "${tf_backend_state}" ]]; then
        local backend_type
        backend_type=$(jq -r '.backend.type // empty' "${tf_backend_state}" 2>/dev/null || echo "")
        if [[ "${backend_type}" == "s3" ]]; then
            TF_BACKEND_S3_BUCKET=$(jq -r '.backend.config.bucket // empty' "${tf_backend_state}")
            TF_BACKEND_S3_REGION=$(jq -r '.backend.config.region // empty' "${tf_backend_state}")
            local s3_key
            s3_key=$(jq -r '.backend.config.key // empty' "${tf_backend_state}")
            TF_BACKEND_S3_KEY_PREFIX="${s3_key%/*}"
        fi
    fi

    # -------------------------------------------------------------------------
    # Step 2.6: Inspect existing backend state for this unit
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # Step 3: terraform plan
    # -------------------------------------------------------------------------
    local plan_args=(-out=tfplan -input=false)
    if [[ "${TF_PLAN_MODE}" == "best_effort" ]]; then
        plan_args+=(-var="enable_remote_state_dependencies=false")
        log_info "Disabling remote state dependencies (dependencies not yet deployed)"
    fi
    if [[ -n "${TFVARS_FILE}" ]]; then
        plan_args+=(-var-file="${TFVARS_FILE}")
        log_info "Using tfvars: ${TFVARS_FILE}"
    else
        log_warning "No tfvars file found for environment: ${environment}"
    fi

    log_info "Running: terraform plan ${plan_args[*]}"
    local plan_output
    set +e
    plan_output=$(terraform plan "${plan_args[@]}" 2>&1)
    local plan_exit=$?
    set -e

    if [[ ${plan_exit} -ne 0 ]] || [[ ! -f "tfplan" ]]; then
        if echo "${plan_output}" | grep -qE "Unable to find remote state|No stored state was found|Error loading state"; then
            log_warning "Remote state unavailable for ${unit_name} (upstream dependency not deployed)"
            update_unit_remote_state_status "${unit_name}" "unavailable" "remote_state_reference_error"
        else
            update_unit_remote_state_status "${unit_name}" "unavailable" "plan_failed"
        fi

        log_step "terraform plan" "FAILED"
        echo ""
        echo "${plan_output}" | grep -A 5 "Error:" | head -50 || echo "${plan_output}" | tail -30
        emit_cloud_credentials_hint_if_needed "${plan_output}"

        popd > /dev/null
        return 2
    fi

    local resource_count
    resource_count=$(echo "${state_output}" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${has_backend_state}" == "true" ]]; then
        log_step "terraform plan" "ok" "${resource_count} existing resources"
    else
        log_step "terraform plan" "ok" "no existing state"
    fi

    # Convert plan to JSON for downstream consumers
    terraform show -json tfplan > tfplan.json 2>/dev/null
    TF_PLAN_JSON_FILE="$(pwd)/tfplan.json"

    # Upload plan JSON alongside the state file when an S3 backend is used
    if [[ -n "${TF_BACKEND_S3_BUCKET}" ]] && [[ -n "${TF_BACKEND_S3_KEY_PREFIX}" ]]; then
        local plan_s3_key="${TF_BACKEND_S3_KEY_PREFIX}/plans/${chain_run_id:-$(date +%s)}-tfplan.json"
        log_info "Uploading plan JSON to s3://${TF_BACKEND_S3_BUCKET}/${plan_s3_key}"
        if aws s3 cp "${TF_PLAN_JSON_FILE}" "s3://${TF_BACKEND_S3_BUCKET}/${plan_s3_key}" \
            --region "${TF_BACKEND_S3_REGION:-us-east-1}" 2>&1 | tail -1; then
            TF_PLAN_S3_URL="s3://${TF_BACKEND_S3_BUCKET}/${plan_s3_key}"
            log_info "Plan uploaded successfully"
        else
            log_warning "Failed to upload plan to S3 (non-fatal, continuing)"
        fi
    fi

    # Export pre-plan state JSON (audit trail and drift baseline)
    local state_json_file
    state_json_file="$(pwd)/tfstate-before-plan.json"
    set +e
    terraform show -json > "${state_json_file}" 2>/dev/null
    local state_export_exit=$?
    set -e

    if [[ ${state_export_exit} -ne 0 ]] || [[ ! -s "${state_json_file}" ]]; then
        log_info "No existing state to export (unit not yet deployed or state is empty)"
        TF_STATE_JSON_FILE=""
    else
        log_info "Exported current state to: ${state_json_file}"
        TF_STATE_JSON_FILE="${state_json_file}"
    fi

    popd > /dev/null
    return 0
}
