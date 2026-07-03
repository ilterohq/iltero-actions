#!/bin/bash
# =============================================================================
# Iltero Core - Plan Evaluation
# =============================================================================
# Functions for running Terraform plan evaluation via Iltero CLI.
#
# Remote State Handling Flow:
#   1. Check dependency remote state status (via the depends_on parameter).
#   2. If any dependency has unavailable state → best_effort mode: the plan runs
#      with -var enable_remote_state_dependencies=false (NOT -backend=false).
#   3. If no deps or all deps available → plan with the real backend.
#   4. Credential-less preview (PREVIEW_MODE + no creds) → init -backend=false and
#      a mock-credential plan; advisory only, never provenance-bound. See
#      prepare_terraform_plan in terraform.sh.
#   5. Update the unit's remote state status for downstream dependencies.
#   6. Always run plan and evaluate (never skip the unit entirely).
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Evaluation passed, no violations above threshold
#   EXIT_VIOLATIONS (1) - Evaluation found violations above fail_on threshold
#   EXIT_ERROR (2)      - Evaluation failed (Terraform error, API error, etc.)
#
# Exports after run_plan_evaluation():
#   EVAL_RUN_ID, EVAL_SCAN_ID, EVAL_PASSED, EVAL_VIOLATIONS, EVAL_EXIT_CODE,
#   APPROVAL_ID, PLAN_JSON_FILE, PLAN_URL, EVAL_MODE,
#   EVAL_PLAN_DIGEST, EVAL_CANON_VERSION  (provenance; "" when disabled)
#
# EVAL_MODE values:
#   "full"        - Full evaluation with backend (remote state available)
#   "best_effort" - Evaluation without backend (remote state unavailable)
#   "preview"     - Credential-less preview plan (never provenance-bound)
# =============================================================================

# Run terraform plan and evaluate against policies
# Args: $1=path $2=stack_id $3=unit $4=environment $5=fail_on $6=run_id $7=plan_file $8=depends_on $9=frameworks (optional)
# Sets: EVAL_RUN_ID, EVAL_SCAN_ID, EVAL_PASSED, EVAL_VIOLATIONS, EVAL_EXIT_CODE, APPROVAL_ID, PLAN_JSON_FILE, EVAL_MODE
run_plan_evaluation() {
    local eval_path
    eval_path="$(cd "$1" && pwd)"
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
    results_dir="$(pwd)/${STACKS_CONFIG:?STACKS_CONFIG must be set}/${ILTERO_STACK_NAME:?ILTERO_STACK_NAME not set}/evaluation"
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
    EVAL_PLAN_DIGEST=""
    EVAL_CANON_VERSION=""

    log_group "Plan Evaluation: ${unit_name}"

    # Use existing plan or generate one via the shared terraform-prep helper.
    # When `existing_plan` is set, also pick up the prep-state side-channels
    # (SCAN_PLAN_*) populated by run_static_scan in the same unit so the
    # full audit trail (S3 URL, pre-plan state JSON, best-effort mode)
    # carries through. Defaults preserve prior behaviour when the caller
    # didn't run scan in plan-mode.
    local plan_s3_url=""
    local state_json_file=""
    local plan_digest=""
    local canon_version=""
    if [[ -n "${existing_plan}" ]] && [[ -f "${existing_plan}" ]]; then
        log_info "Using existing plan file: ${existing_plan}"
        PLAN_JSON_FILE="${existing_plan}"
        EVAL_MODE="${SCAN_PLAN_MODE:-full}"
        plan_s3_url="${SCAN_PLAN_S3_URL:-}"
        state_json_file="${SCAN_PLAN_STATE_JSON_FILE:-}"
        plan_digest="${SCAN_PLAN_DIGEST:-}"
        canon_version="${SCAN_PLAN_CANON_VERSION:-}"
    else
        set +e
        prepare_terraform_plan "${eval_path}" "${unit_name}" "${environment}" "${depends_on}" "${chain_run_id}"
        local prep_exit=$?
        set -e

        if [[ ${prep_exit} -ne 0 ]]; then
            local failure_step="terraform init"
            [[ ${prep_exit} -eq 2 ]] && failure_step="terraform plan"
            log_result "FAIL" "Plan evaluation aborted: ${failure_step} failed for ${unit_name}"
            log_group_end
            EVAL_EXIT_CODE=2
            EVAL_PASSED="false"
            return 1
        fi

        PLAN_JSON_FILE="${TF_PLAN_JSON_FILE}"
        EVAL_MODE="${TF_PLAN_MODE}"
        plan_s3_url="${TF_PLAN_S3_URL}"
        state_json_file="${TF_STATE_JSON_FILE}"
        plan_digest="${TF_PLAN_DIGEST}"
        canon_version="${TF_CANON_VERSION}"
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
    )

    # Preview mode: pass --preview to the CLI (read-only policy resolution,
    # no submission). Otherwise: --resolve-policies (writeful resolution).
    if [[ "${PREVIEW_MODE:-false}" == "true" ]]; then
        cmd+=(--preview)
    else
        cmd+=(--resolve-policies)
    fi

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

    # Provenance: record the canonical plan digest under this run_id. The flags
    # are produced by provenance_eval_flags and are empty unless attestation
    # captured a digest, so this preserves prior behaviour when disabled.
    provenance_eval_flags "${plan_digest:-}" "${canon_version:-}"
    if [[ ${#PROVENANCE_EVAL_FLAGS[@]} -gt 0 ]]; then
        cmd+=("${PROVENANCE_EVAL_FLAGS[@]}")
    fi

    # Note: Upload happens via Compliance API using scan_id from policy resolution
    # No --skip-upload needed - the CLI handles this automatically

    log_info "Running: ${cmd[*]}"
    set +e
    "${cmd[@]}"
    EVAL_EXIT_CODE=$?
    set -e

    PLAN_URL="${plan_s3_url:-}"
    EVAL_PLAN_DIGEST="${plan_digest:-}"
    EVAL_CANON_VERSION="${canon_version:-}"

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
