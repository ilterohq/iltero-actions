#!/bin/bash
# =============================================================================
# Iltero Core - Results Aggregation
# =============================================================================
# Functions for aggregating and checking violations across multiple scans.
# =============================================================================

# Check if there are any violations in batch scan results
# Args: $1=comma_separated_scan_ids
# Returns: 0=all passed, 1=violations found, 2=error
check_batch_violations() {
    local scan_ids="$1"

    if [[ -z "$scan_ids" ]]; then
        log_error "scan_ids is required"
        return 2
    fi

    log_info "Checking violations for scans: $scan_ids"

    set +e
    local result
    result=$(iltero scan batch-status --scan-ids "$scan_ids" --output json 2>&1)
    local exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to get batch status: $result"
        return 2
    fi

    local has_violations failed_count
    has_violations=$(echo "$result" | jq -r '.has_violations // false' 2>/dev/null)
    failed_count=$(echo "$result" | jq -r '.failed_scans // 0' 2>/dev/null)

    if [[ "$failed_count" -gt 0 ]]; then
        log_error "Batch contains $failed_count failed scan(s)"
        return 2
    elif [[ "$has_violations" == "true" ]]; then
        log_warning "Batch contains compliance violations"
        return 1
    else
        log_success "No compliance violations found"
        return 0
    fi
}

# Aggregate scan results with severity breakdown
# Args: $1=comma_separated_scan_ids $2=output_file (optional)
# Sets: AGG_TOTAL, AGG_HIGH, AGG_MEDIUM, AGG_LOW, AGG_PASSED
aggregate_scan_results() {
    local scan_ids="$1"
    local output_file="${2:-/tmp/scan-aggregate-$(date +%s).json}"

    # Reset outputs
    AGG_TOTAL=0
    AGG_HIGH=0
    AGG_MEDIUM=0
    AGG_LOW=0
    AGG_PASSED="false"

    if [[ -z "$scan_ids" ]]; then
        log_error "scan_ids is required"
        return 1
    fi

    log_group "Aggregate Results"

    # Get batch status with details
    set +e
    local batch_result
    batch_result=$(iltero scan batch-status --scan-ids "$scan_ids" --detailed --output json 2>&1)
    local batch_exit=$?
    set -e

    if [[ $batch_exit -ne 0 ]]; then
        log_error "Failed to get batch status: $batch_result"
        log_group_end
        return 1
    fi

    # Save raw result
    echo "$batch_result" > "$output_file"
    log_debug "Aggregate results saved to: $output_file"

    # Parse summary
    local overall_status total_scans completed_scans failed_scans progress has_violations
    overall_status=$(echo "$batch_result" | jq -r '.overall_status // "UNKNOWN"' 2>/dev/null)
    total_scans=$(echo "$batch_result" | jq -r '.total_scans // 0' 2>/dev/null)
    completed_scans=$(echo "$batch_result" | jq -r '.completed_scans // 0' 2>/dev/null)
    failed_scans=$(echo "$batch_result" | jq -r '.failed_scans // 0' 2>/dev/null)
    progress=$(echo "$batch_result" | jq -r '.progress // 0' 2>/dev/null)
    has_violations=$(echo "$batch_result" | jq -r '.has_violations // false' 2>/dev/null)

    # Log summary
    log_info "Overall Status: $overall_status"
    log_info "Progress: ${progress}% ($completed_scans/$total_scans completed)"
    log_info "Failed Scans: $failed_scans"
    log_info "Has Violations: $has_violations"

    # Get violation breakdown if available
    if [[ "$has_violations" == "true" ]]; then
        set +e
        local violations_result
        violations_result=$(iltero scan batch-violations --scan-ids "$scan_ids" --output json 2>&1)
        set -e

        if [[ $? -eq 0 ]]; then
            AGG_TOTAL=$(echo "$violations_result" | jq -r '.summary.total // 0' 2>/dev/null)
            AGG_HIGH=$(echo "$violations_result" | jq -r '.summary.high // 0' 2>/dev/null)
            AGG_MEDIUM=$(echo "$violations_result" | jq -r '.summary.medium // 0' 2>/dev/null)
            AGG_LOW=$(echo "$violations_result" | jq -r '.summary.low // 0' 2>/dev/null)

            log_info "Findings: $AGG_TOTAL total ($AGG_HIGH high, $AGG_MEDIUM medium, $AGG_LOW low)"

            # Top violations by rule
            echo ""
            log_info "Top findings by rule:"
            echo "$violations_result" | jq -r '.violations_by_rule[0:5][] | "    \(.rule_id) (\(.severity)): \(.count) occurrences"' 2>/dev/null || true
        fi
    fi

    # Determine pass/fail
    if [[ "$overall_status" == "COMPLETED" ]] && [[ "$has_violations" == "false" ]] && [[ "$failed_scans" == "0" ]]; then
        AGG_PASSED="true"
        log_result "PASS" "All scans completed with no findings"
    else
        log_result "FAIL" "Aggregation complete: ${failed_scans} failed, ${AGG_TOTAL} findings"
    fi

    log_group_end
    return 0
}

# Generate summary for multiple scan IDs
# Args: $1=comma_separated_scan_ids
# Outputs: Human-readable summary to stdout
print_scan_summary() {
    local scan_ids="$1"

    aggregate_scan_results "$scan_ids" > /dev/null 2>&1

    echo ""
    echo "--- Static Analysis Summary ---------------------------------------------------"
    echo ""

    if [[ "$AGG_PASSED" == "true" ]]; then
        echo "  Status:   PASSED"
    else
        echo "  Status:   FAILED"
    fi

    echo "  Findings: $AGG_TOTAL total ($AGG_HIGH high, $AGG_MEDIUM medium, $AGG_LOW low)"
    echo ""
    echo "-------------------------------------------------------------------------------"
    echo ""
}
