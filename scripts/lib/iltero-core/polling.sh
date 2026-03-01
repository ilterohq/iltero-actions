#!/bin/bash
# =============================================================================
# Iltero Core - Async Polling
# =============================================================================
# Functions for polling scan completion with configurable timeout.
# Prevents indefinite hangs and provides recovery mechanisms.
# =============================================================================

# Default polling configuration
readonly DEFAULT_POLL_TIMEOUT=300    # 5 minutes
readonly DEFAULT_POLL_INTERVAL=10    # 10 seconds

# Poll scan completion with timeout
# Args: $1=scan_id $2=timeout_seconds (optional) $3=poll_interval (optional)
# Returns: 0=completed, 1=failed/timeout, 2=error
poll_scan_completion() {
    local scan_id="$1"
    local timeout="${2:-$DEFAULT_POLL_TIMEOUT}"
    local interval="${3:-$DEFAULT_POLL_INTERVAL}"

    if [[ -z "$scan_id" ]]; then
        log_error "scan_id is required for polling"
        return 2
    fi

    log_info "Polling scan completion: $scan_id (timeout: ${timeout}s)"

    local start_time
    start_time=$(date +%s)
    local dots=""

    while true; do
        local elapsed=$(($(date +%s) - start_time))

        if [[ $elapsed -gt $timeout ]]; then
            echo ""  # newline after dots
            log_error "Scan timeout after ${timeout}s"
            update_scan_status "$scan_id" "FAILED" "Timeout after ${timeout}s"
            return 1
        fi

        # Get scan status
        set +e
        local status_output
        status_output=$(iltero scan status "$scan_id" --output json 2>&1)
        local status_exit=$?
        set -e

        if [[ $status_exit -ne 0 ]]; then
            echo ""
            log_error "Failed to get scan status: $status_output"
            return 2
        fi

        local status
        status=$(echo "$status_output" | jq -r '.status // empty' 2>/dev/null)

        case "$status" in
            COMPLETED)
                echo ""
                log_success "Scan completed successfully"

                # Check for violations
                local violations
                violations=$(echo "$status_output" | jq -r '.violations_count // 0' 2>/dev/null)
                if [[ "$violations" -gt 0 ]]; then
                    log_warning "Scan found $violations violation(s)"
                    return 1
                fi
                return 0
                ;;
            FAILED)
                echo ""
                local error_msg
                error_msg=$(echo "$status_output" | jq -r '.error_message // "Unknown error"' 2>/dev/null)
                log_error "Scan failed: $error_msg"
                return 1
                ;;
            RUNNING|PENDING)
                # Show progress indicator
                dots+="."
                if [[ ${#dots} -gt 60 ]]; then
                    dots=""
                    echo ""
                fi
                printf "\rWaiting for scan completion%s" "$dots"
                sleep "$interval"
                ;;
            "")
                echo ""
                log_error "Empty status returned for scan $scan_id"
                return 2
                ;;
            *)
                echo ""
                log_error "Unknown scan status: $status"
                return 2
                ;;
        esac
    done
}

# Update scan status via API
# Args: $1=scan_id $2=status $3=error_message (optional)
# Returns: 0=success, 1=failure
update_scan_status() {
    local scan_id="$1"
    local status="$2"
    local error_message="${3:-}"

    if [[ -z "$scan_id" ]] || [[ -z "$status" ]]; then
        log_error "scan_id and status are required"
        return 1
    fi

    log_debug "Updating scan $scan_id status to $status"

    local cmd=(
        iltero scan update-status
        --scan-id "$scan_id"
        --status "$status"
        --output json
    )

    if [[ -n "$error_message" ]]; then
        cmd+=(--error-message "$error_message")
    fi

    set +e
    "${cmd[@]}" 2>/dev/null
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        log_debug "Scan status updated to $status"
        return 0
    else
        log_warning "Failed to update scan status"
        return 1
    fi
}

# Wait for multiple scans to complete
# Args: $1=comma_separated_scan_ids $2=timeout_seconds (optional)
# Returns: 0=all completed, 1=some failed, 2=error
wait_for_scans() {
    local scan_ids="$1"
    local timeout="${2:-$DEFAULT_POLL_TIMEOUT}"

    if [[ -z "$scan_ids" ]]; then
        log_error "scan_ids is required"
        return 2
    fi

    log_info "Waiting for scans to complete: $scan_ids"

    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed=$(($(date +%s) - start_time))

        if [[ $elapsed -gt $timeout ]]; then
            log_error "Timeout waiting for scans after ${timeout}s"
            return 1
        fi

        # Check batch status
        set +e
        local batch_output
        batch_output=$(iltero scan batch-status --scan-ids "$scan_ids" --output json 2>&1)
        local batch_exit=$?
        set -e

        if [[ $batch_exit -ne 0 ]]; then
            log_error "Failed to get batch status: $batch_output"
            return 2
        fi

        local overall_status
        overall_status=$(echo "$batch_output" | jq -r '.overall_status // empty' 2>/dev/null)

        case "$overall_status" in
            COMPLETED)
                log_success "All scans completed"
                return 0
                ;;
            FAILED)
                log_error "Some scans failed"
                return 1
                ;;
            RUNNING|PENDING|PARTIAL)
                local progress
                progress=$(echo "$batch_output" | jq -r '.progress // 0' 2>/dev/null)
                log_debug "Scans in progress: ${progress}%"
                sleep "$DEFAULT_POLL_INTERVAL"
                ;;
            *)
                log_error "Unknown batch status: $overall_status"
                return 2
                ;;
        esac
    done
}
