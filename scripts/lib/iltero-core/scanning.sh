#!/bin/bash
# =============================================================================
# Iltero Core - Static Compliance Scanning
# =============================================================================
# Functions for running static compliance scans via Iltero CLI.
#
# Plan-mode vs source-mode: when cloud credentials are present in the env
# (any supported provider — see `cloud_credentials_present` in
# `terraform.sh`), the scan runs `terraform init + plan` first and feeds the
# resulting plan JSON to the CLI for higher-fidelity analysis (resolved
# values, real cloud context). When credentials are absent, the CLI falls
# back to scanning the source directory. The plan path is exported so a
# downstream evaluation step can reuse it without re-running terraform.
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Scan passed, no violations above threshold
#   EXIT_VIOLATIONS (1) - Scan found violations above fail_on threshold
#   EXIT_ERROR (2)      - Scan failed to execute (API error, timeout, etc.)
#
# Exports after run_static_scan():
#   SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_VIOLATIONS, SCAN_EXIT_CODE
#   SCAN_PLAN_JSON_FILE       - absolute path to the plan JSON (plan-mode)
#   SCAN_PLAN_STATE_JSON_FILE - pre-plan state JSON (plan-mode), or empty
#   SCAN_PLAN_S3_URL          - s3:// URL of uploaded plan (plan-mode), or empty
#   SCAN_PLAN_MODE            - "full" | "best_effort" (plan-mode), or empty
# All SCAN_PLAN_* are empty when source-mode is used.
# =============================================================================

# Run static scan using iltero CLI
# Args: $1=path $2=stack_id $3=unit $4=environment $5=fail_on $6=run_id (optional) $7=frameworks (optional) $8=config_path (optional)
# Sets: SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_VIOLATIONS, SCAN_EXIT_CODE
run_static_scan() {
    local scan_path="${1}"
    local stack_id="${2}"
    local unit_name="${3}"
    local environment="${4}"
    local fail_on="${5:-high}"
    local chain_run_id="${6:-}"
    local frameworks="${7:-}"
    local config_path="${8:-}"

    local results_file
    local results_dir
    results_dir="$(pwd)/${STACKS_CONFIG:?STACKS_CONFIG must be set}/${ILTERO_STACK_NAME:?ILTERO_STACK_NAME not set}/static"
    mkdir -p "${results_dir}"
    results_file="${results_dir}/static-${unit_name}-$(date +%s).json"

    # Reset outputs
    SCAN_RUN_ID=""
    SCAN_ID=""
    SCAN_PASSED="false"
    SCAN_VIOLATIONS="0"
    SCAN_EXIT_CODE=0
    SCAN_PLAN_JSON_FILE=""
    SCAN_PLAN_STATE_JSON_FILE=""
    SCAN_PLAN_S3_URL=""
    SCAN_PLAN_MODE=""

    log_group "Static Analysis: ${unit_name}"

    # Choose scan input: plan JSON (high fidelity) when any supported cloud
    # has credentials in the env; otherwise the source directory (source
    # mode). On a plan-prep failure, fall back to source mode rather than
    # aborting the scan — static scanning is the most permissive of the
    # gates. The cloud-agnostic check lives in terraform.sh so a new
    # provider only requires updating one helper, not this branch.
    local cli_input_path="${scan_path}"
    if cloud_credentials_present; then
        log_info "Cloud credentials detected; preparing plan-mode scan input"
        set +e
        prepare_terraform_plan "${scan_path}" "${unit_name}" "${environment}" "" "${chain_run_id}"
        local prep_exit=$?
        set -e
        if [[ ${prep_exit} -eq 0 ]] && [[ -n "${TF_PLAN_JSON_FILE}" ]] && [[ -f "${TF_PLAN_JSON_FILE}" ]]; then
            cli_input_path="${TF_PLAN_JSON_FILE}"
            # Forward the full prep result so a downstream evaluation can
            # reuse the plan, state JSON, S3 URL, and best-effort mode
            # without re-running terraform.
            SCAN_PLAN_JSON_FILE="${TF_PLAN_JSON_FILE}"
            SCAN_PLAN_STATE_JSON_FILE="${TF_STATE_JSON_FILE}"
            SCAN_PLAN_S3_URL="${TF_PLAN_S3_URL}"
            SCAN_PLAN_MODE="${TF_PLAN_MODE}"
            log_info "Plan-mode scan input: ${TF_PLAN_JSON_FILE}"
        else
            log_warning "Plan-mode prep failed (exit ${prep_exit}); falling back to source-mode scan"
        fi
    else
        log_info "No cloud credentials detected; using source-mode scan"
    fi

    # Build command array
    local cmd=(
        "${ILTERO_CLI_BIN:-iltero}" scan static "${cli_input_path}"
        --stack-id "${stack_id}"
        --unit "${unit_name}"
        --environment "${environment}"
        --fail-on "${fail_on}"
        --output json
        --output-file "${results_file}"
    )

    # Preview mode: pass --preview to the CLI (read-only policy resolution,
    # no submission). Otherwise: --resolve-policies (writeful resolution).
    if [[ "${PREVIEW_MODE:-false}" == "true" ]]; then
        cmd+=(--preview)
    else
        cmd+=(--resolve-policies)
    fi

    # Add GitHub context if available
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        cmd+=(--external-run-id "${GITHUB_RUN_ID}")
        cmd+=(--external-run-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}")
    fi

    # Chain to existing run if provided
    if [[ -n "${chain_run_id}" ]]; then
        cmd+=(--run-id "${chain_run_id}")
    fi

    # Pass frameworks if configured
    if [[ -n "${frameworks}" ]]; then
        cmd+=(--frameworks "${frameworks}")
    fi

    # Pass config path for stack config.yml update
    if [[ -n "${config_path}" ]]; then
        cmd+=(--config-path "${config_path}")
    fi

    # Execute scan
    set +e
    "${cmd[@]}"
    SCAN_EXIT_CODE=$?
    set -e

    # Initialize severity counts (must be set before referencing in messages)
    local critical_count=0 high_count=0 medium_count=0 low_count=0

    # Extract results
    if [[ -f "${results_file}" ]]; then
        SCAN_RUN_ID=$(jq -r '.run_id // empty' "${results_file}" 2>/dev/null || echo "")
        SCAN_ID=$(jq -r '.scan_id // empty' "${results_file}" 2>/dev/null || echo "")
        SCAN_VIOLATIONS=$(jq -r '.violations_count // (.violations | length) // 0' "${results_file}" 2>/dev/null || echo "0")

        critical_count=$(jq -r '[.violations[]? | select(.severity == "critical")] | length' "${results_file}" 2>/dev/null || echo "0")
        high_count=$(jq -r '[.violations[]? | select(.severity == "high")] | length' "${results_file}" 2>/dev/null || echo "0")
        medium_count=$(jq -r '[.violations[]? | select(.severity == "medium")] | length' "${results_file}" 2>/dev/null || echo "0")
        low_count=$(jq -r '[.violations[]? | select(.severity == "low")] | length' "${results_file}" 2>/dev/null || echo "0")

        if [[ -n "${SCAN_ID}" ]]; then
            log_info "Scan ID: ${SCAN_ID}"
        fi
    fi

    # Structured severity breakdown
    log_info "Threshold: ${fail_on}"
    echo ""
    log_info "Findings: ${SCAN_VIOLATIONS} total"
    log_info "  critical  ${critical_count}"
    log_info "  high      ${high_count}"
    log_info "  medium    ${medium_count}"
    log_info "  low       ${low_count}"
    echo ""

    if [[ ${SCAN_EXIT_CODE} -eq 0 ]]; then
        SCAN_PASSED="true"
        local above_threshold=$((critical_count + high_count))
        if [[ "${fail_on}" == "critical" ]]; then
            above_threshold=${critical_count}
        elif [[ "${fail_on}" == "medium" ]]; then
            above_threshold=$((critical_count + high_count + medium_count))
        elif [[ "${fail_on}" == "low" ]]; then
            above_threshold=${SCAN_VIOLATIONS}
        fi
        log_result "PASS" "Static analysis passed (${above_threshold} findings at or above '${fail_on}')"
    else
        log_result "FAIL" "${SCAN_VIOLATIONS} findings at or above '${fail_on}' threshold (${critical_count} critical, ${high_count} high)"
    fi

    log_group_end
    return ${SCAN_EXIT_CODE}
}
