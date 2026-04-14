#!/bin/bash
# =============================================================================
# Iltero Core - Static Compliance Scanning
# =============================================================================
# Functions for running static compliance scans via Iltero CLI.
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Scan passed, no violations above threshold
#   EXIT_VIOLATIONS (1) - Scan found violations above fail_on threshold
#   EXIT_ERROR (2)      - Scan failed to execute (API error, timeout, etc.)
#
# Exports after run_compliance_scan():
#   SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_VIOLATIONS, SCAN_EXIT_CODE
# =============================================================================

# Run compliance scan using iltero CLI
# Args: $1=path $2=stack_id $3=unit $4=environment $5=fail_on $6=run_id (optional) $7=frameworks (optional) $8=config_path (optional)
# Sets: SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_VIOLATIONS, SCAN_EXIT_CODE
run_compliance_scan() {
    local scan_path="$1"
    local stack_id="$2"
    local unit_name="$3"
    local environment="$4"
    local fail_on="${5:-high}"
    local chain_run_id="${6:-}"
    local frameworks="${7:-}"
    local config_path="${8:-}"

    local results_file
    local results_dir
    results_dir="$(pwd)/.iltero/${ILTERO_STACK_NAME:?ILTERO_STACK_NAME not set}/static"
    mkdir -p "$results_dir"
    results_file="${results_dir}/compliance-${unit_name}-$(date +%s).json"

    # Reset outputs
    SCAN_RUN_ID=""
    SCAN_ID=""
    SCAN_PASSED="false"
    SCAN_VIOLATIONS="0"
    SCAN_EXIT_CODE=0

    log_group "Static Analysis: ${unit_name}"

    # Build command array
    local cmd=(
        iltero scan static "$scan_path"
        --stack-id "$stack_id"
        --unit "$unit_name"
        --environment "$environment"
        --fail-on "$fail_on"
        --output json
        --output-file "$results_file"
        --resolve-policies
    )

    # Add GitHub context if available
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        cmd+=(--external-run-id "$GITHUB_RUN_ID")
        cmd+=(--external-run-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}")
    fi

    # Chain to existing run if provided
    if [[ -n "$chain_run_id" ]]; then
        cmd+=(--run-id "$chain_run_id")
    fi

    # Pass frameworks if configured
    if [[ -n "$frameworks" ]]; then
        cmd+=(--frameworks "$frameworks")
    fi

    # Pass config path for stack config.yml update
    if [[ -n "$config_path" ]]; then
        cmd+=(--config-path "$config_path")
    fi

    # Note: Upload happens via Compliance API using scan_id from policy resolution
    # No --skip-upload needed - the CLI handles this automatically

    # Execute scan
    set +e
    "${cmd[@]}"
    SCAN_EXIT_CODE=$?
    set -e

    # Initialize severity counts (must be set before referencing in messages)
    local critical_count=0 high_count=0 medium_count=0 low_count=0

    # Extract results
    if [[ -f "$results_file" ]]; then
        SCAN_RUN_ID=$(jq -r '.run_id // empty' "$results_file" 2>/dev/null || echo "")
        # Extract scan_id from policy resolution (required for apply phase)
        SCAN_ID=$(jq -r '.scan_id // empty' "$results_file" 2>/dev/null || echo "")
        # Try violations_count first, fallback to counting violations array
        SCAN_VIOLATIONS=$(jq -r '.violations_count // (.violations | length) // 0' "$results_file" 2>/dev/null || echo "0")
        
        # Extract severity breakdown for better messaging
        critical_count=$(jq -r '[.violations[]? | select(.severity == "critical")] | length' "$results_file" 2>/dev/null || echo "0")
        high_count=$(jq -r '[.violations[]? | select(.severity == "high")] | length' "$results_file" 2>/dev/null || echo "0")
        medium_count=$(jq -r '[.violations[]? | select(.severity == "medium")] | length' "$results_file" 2>/dev/null || echo "0")
        low_count=$(jq -r '[.violations[]? | select(.severity == "low")] | length' "$results_file" 2>/dev/null || echo "0")
        
        if [[ -n "$SCAN_ID" ]]; then
            log_info "Scan ID: $SCAN_ID"
        fi
    fi

    # Structured severity breakdown
    log_info "Threshold: ${fail_on}"
    echo ""
    log_info "Findings: $SCAN_VIOLATIONS total"
    log_info "  critical  ${critical_count}"
    log_info "  high      ${high_count}"
    log_info "  medium    ${medium_count}"
    log_info "  low       ${low_count}"
    echo ""

    if [[ $SCAN_EXIT_CODE -eq 0 ]]; then
        SCAN_PASSED="true"
        local above_threshold=$((critical_count + high_count))
        if [[ "$fail_on" == "critical" ]]; then
            above_threshold=$critical_count
        elif [[ "$fail_on" == "medium" ]]; then
            above_threshold=$((critical_count + high_count + medium_count))
        elif [[ "$fail_on" == "low" ]]; then
            above_threshold=$SCAN_VIOLATIONS
        fi
        log_result "PASS" "Static analysis passed (${above_threshold} findings at or above '${fail_on}')"
    else
        log_result "FAIL" "${SCAN_VIOLATIONS} findings at or above '${fail_on}' threshold (${critical_count} critical, ${high_count} high)"
    fi

    log_group_end
    return $SCAN_EXIT_CODE
}
