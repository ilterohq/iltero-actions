#!/usr/bin/env bash
# runtime.sh - Runtime and drift scanning capabilities
# Part of iltero-core modular library
#
# Provides post-deployment scanning to detect:
# - Configuration drift from Terraform state
# - Runtime compliance violations
# - Cloud resource misconfigurations

set -euo pipefail

# Run runtime scan against deployed infrastructure
# Usage: run_runtime_scan <unit_name> [cloud_provider] [regions]
# Returns: 0=success, 1=violations, 2=error
run_runtime_scan() {
    local unit_name="$1"
    local cloud_provider="${2:-AWS}"
    local regions="${3:-us-east-1}"
    local output_file="${4:-}"
    
    if [[ -z "$unit_name" ]]; then
        log_error "Unit name required for runtime scan"
        return 2
    fi
    
    log_info "Running runtime scan for '$unit_name' on $cloud_provider ($regions)"
    
    local scan_output
    local scan_result
    
    if [[ -n "$output_file" ]]; then
        scan_output=$(mktemp)
    else
        scan_output="/dev/stdout"
    fi
    
    if ! scan_result=$(iltero scan runtime \
        --unit "$unit_name" \
        --provider "$cloud_provider" \
        --regions "$regions" \
        --output json 2>&1); then
        log_error "Runtime scan failed: $scan_result"
        return 2
    fi
    
    # Parse scan result
    local scan_id
    local has_violations
    
    scan_id=$(echo "$scan_result" | jq -r '.scan_id // empty')
    has_violations=$(echo "$scan_result" | jq -r '.has_violations // false')
    
    if [[ -z "$scan_id" ]]; then
        log_error "No scan_id returned from runtime scan"
        return 2
    fi
    
    log_info "Runtime scan initiated: $scan_id"
    
    # Output scan ID for downstream processing
    if [[ -n "$output_file" ]]; then
        echo "$scan_result" > "$output_file"
    fi
    
    # Set GitHub output if available
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "runtime_scan_id=$scan_id" >> "$GITHUB_OUTPUT"
    fi
    
    if [[ "$has_violations" == "true" ]]; then
        return 1
    fi
    
    return 0
}

# Detect drift between Terraform state and actual cloud resources
# Usage: detect_drift <unit_name> [state_file]
# Returns: 0=no drift, 1=drift detected, 2=error
detect_drift() {
    local unit_name="$1"
    local state_file="${2:-}"
    
    if [[ -z "$unit_name" ]]; then
        log_error "Unit name required for drift detection"
        return 2
    fi
    
    log_info "Checking for drift in '$unit_name'"
    
    local drift_args=(
        --unit "$unit_name"
        --output json
    )
    
    if [[ -n "$state_file" && -f "$state_file" ]]; then
        drift_args+=(--state-file "$state_file")
    fi
    
    local drift_result
    if ! drift_result=$(iltero scan drift "${drift_args[@]}" 2>&1); then
        log_error "Drift detection failed: $drift_result"
        return 2
    fi
    
    local drift_count
    drift_count=$(echo "$drift_result" | jq -r '.drift_count // 0')
    
    if [[ "$drift_count" -gt 0 ]]; then
        log_warn "Drift detected: $drift_count resource(s) have drifted"
        
        # Log drifted resources
        echo "$drift_result" | jq -r '.drifted_resources[]? | "  - \(.resource_type).\(.resource_name): \(.drift_type)"' | while read -r line; do
            log_warn "$line"
        done
        
        return 1
    fi
    
    log_info "No drift detected"
    return 0
}

# Run scheduled compliance check (for cron-triggered workflows)
# Usage: run_scheduled_scan <unit_name> <scan_type> [notification_channel]
# scan_type: runtime|drift|full
run_scheduled_scan() {
    local unit_name="$1"
    local scan_type="${2:-full}"
    local notification_channel="${3:-}"
    
    log_info "Starting scheduled $scan_type scan for '$unit_name'"
    
    local scan_result=0
    local scan_output
    scan_output=$(mktemp)
    
    case "$scan_type" in
        runtime)
            run_runtime_scan "$unit_name" > "$scan_output" 2>&1 || scan_result=$?
            ;;
        drift)
            detect_drift "$unit_name" > "$scan_output" 2>&1 || scan_result=$?
            ;;
        full)
            # Run both scans
            run_runtime_scan "$unit_name" > "$scan_output" 2>&1 || scan_result=$?
            if [[ $scan_result -eq 0 ]]; then
                detect_drift "$unit_name" >> "$scan_output" 2>&1 || scan_result=$?
            fi
            ;;
        *)
            log_error "Unknown scan type: $scan_type"
            rm -f "$scan_output"
            return 2
            ;;
    esac
    
    # Send notification if channel configured and issues found
    if [[ -n "$notification_channel" && $scan_result -ne 0 ]]; then
        _send_scan_notification "$unit_name" "$scan_type" "$scan_result" "$scan_output" "$notification_channel"
    fi
    
    rm -f "$scan_output"
    return $scan_result
}

# Compare runtime state against policy baseline
# Usage: check_runtime_compliance <unit_name> <policy_set>
check_runtime_compliance() {
    local unit_name="$1"
    local policy_set="${2:-default}"
    
    log_info "Checking runtime compliance for '$unit_name' against policy set '$policy_set'"
    
    local result
    if ! result=$(iltero scan runtime-compliance \
        --unit "$unit_name" \
        --policy-set "$policy_set" \
        --output json 2>&1); then
        log_error "Runtime compliance check failed: $result"
        return 2
    fi
    
    local compliant
    local violation_count
    
    compliant=$(echo "$result" | jq -r '.compliant // false')
    violation_count=$(echo "$result" | jq -r '.violation_count // 0')
    
    if [[ "$compliant" != "true" ]]; then
        log_error "Runtime compliance failed: $violation_count violation(s)"
        return 1
    fi
    
    log_info "Runtime compliance check passed"
    return 0
}

# Internal: Send notification for scan results
_send_scan_notification() {
    local unit_name="$1"
    local scan_type="$2"
    local result_code="$3"
    local output_file="$4"
    local channel="$5"
    
    local status="failed"
    [[ $result_code -eq 1 ]] && status="violations_found"
    
    # Notification logic would integrate with Slack/Teams/etc.
    log_info "Would notify $channel: $scan_type scan for $unit_name: $status"
}
