#!/bin/bash
# =============================================================================
# Iltero Core - Remote State Helper
# =============================================================================
# Helper functions for tracking and managing remote state availability
# across units in a dependency chain.
#
# PERSISTENT STATE TRACKING:
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ State is persisted to .iltero/{stack}/state-status/{unit}.json files    │
# │ This allows:                                                            │
# │   - Cross-run persistence (state survives between pipeline executions)  │
# │   - Dependency resolution before running terraform                      │
# │   - Units to check their dependencies' ACTUAL deployed status           │
# └─────────────────────────────────────────────────────────────────────────┘
#
# Flow:
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 1. Unit processing starts                                                │
# │ 2. check_dependency_remote_state() reads deps' status from disk         │
# │    - If ANY dep has "unavailable" status → return "unavailable"         │
# │    - If ALL deps have "available" status → return "available"           │
# │    - If dep status file missing → return "unavailable" (not deployed)   │
# │ 3. Based on result, evaluation runs with or without backend             │
# │ 4. After processing, write_unit_state_status() persists to disk         │
# │ 5. Status is available for subsequent units and future runs             │
# └─────────────────────────────────────────────────────────────────────────┘
#
# State File Format (.iltero/{stack}/state-status/{unit_name}.json):
# {
#   "unit": "network-baseline",
#   "status": "available" | "unavailable",
#   "timestamp": "2026-01-10T12:00:00Z",
#   "reason": "terraform_init_success" | "remote_state_missing" | ...
# }
# =============================================================================

# Directory for persisting state status
export ILTERO_STATE_DIR=""

# Initialize the state tracking directory
# Args: $1=stack_name (stack folder name, e.g. soc2-non-prod)
# State is stored at repo root: .iltero/{stack_name}/state-status/
init_remote_state_tracking() {
    local stack_name="${1:?Stack name is required}"
    
    # Create .iltero/{stack}/state-status directory at repo root
    ILTERO_STATE_DIR="$(pwd)/.iltero/${stack_name}/state-status"
    export ILTERO_STATE_DIR
    mkdir -p "$ILTERO_STATE_DIR"
    
    log_info "Remote state tracking initialized at: $ILTERO_STATE_DIR"
}

# Read a unit's state status from disk
# Args: $1=unit_name
# Returns via echo: "available" | "unavailable" | "unknown"
read_unit_state_status() {
    local unit_name="$1"
    local status_file="${ILTERO_STATE_DIR}/${unit_name}.json"
    
    if [[ ! -f "$status_file" ]]; then
        echo "unknown"
        return 0
    fi
    
    local status
    status=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo "unknown")
    echo "$status"
}

# Write a unit's state status to disk
# Args: $1=unit_name $2=status $3=reason (optional)
write_unit_state_status() {
    local unit_name="$1"
    local status="$2"
    local reason="${3:-unspecified}"
    local status_file="${ILTERO_STATE_DIR}/${unit_name}.json"
    
    # Ensure directory exists
    if [[ -z "$ILTERO_STATE_DIR" ]]; then
        log_warning "ILTERO_STATE_DIR not set - skipping state status write"
        return 0
    fi
    mkdir -p "$ILTERO_STATE_DIR"
    
    # Write status file
    cat > "$status_file" << EOF
{
  "unit": "${unit_name}",
  "status": "${status}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reason": "${reason}"
}
EOF
    
    log_info "Unit '$unit_name' state status: $status ($reason)"
}

# Check if a unit's dependencies have remote state available
# Args: $1=depends_on (JSON array of dependency unit names)
# Returns via echo: "available" | "unavailable" | "check_self"
# Sets: DEP_CHECK_DETAILS with list of unavailable dependencies (for logging by caller)
# 
# Logic:
#   - No dependencies → "check_self" (unit needs to verify its own backend)
#   - Any dependency unavailable/unknown → "unavailable" (must use -backend=false)
#   - All dependencies available → "available" (can try with backend)
check_dependency_remote_state() {
    local depends_on="$1"
    
    # Reset details
    DEP_CHECK_DETAILS=""
    
    # No dependencies - need to check own backend availability
    if [[ -z "$depends_on" ]] || [[ "$depends_on" == "[]" ]] || [[ "$depends_on" == "null" ]]; then
        echo "check_self"
        return 0
    fi
    
    # Check each dependency's status from disk
    local dep
    local all_available=true
    local unavailable_deps=""
    
    for dep in $(echo "$depends_on" | jq -r '.[]' 2>/dev/null); do
        local dep_status
        dep_status=$(read_unit_state_status "$dep")
        
        case "$dep_status" in
            "available")
                # This dependency is available, continue checking
                ;;
            "unavailable")
                unavailable_deps="${unavailable_deps}${dep} (unavailable), "
                all_available=false
                ;;
            "unknown"|*)
                # Unknown status means never deployed - treat as unavailable
                unavailable_deps="${unavailable_deps}${dep} (unknown), "
                all_available=false
                ;;
        esac
    done
    
    if [[ "$all_available" == "true" ]]; then
        echo "available"
    else
        # Set details for caller to log (don't log here - pollutes stdout capture)
        DEP_CHECK_DETAILS="${unavailable_deps%, }"
        echo "unavailable"
    fi
    return 0
}

# Update a unit's remote state status (writes to disk for persistence)
# Args: $1=unit_name $2=status ("available" | "unavailable") $3=reason (optional)
update_unit_remote_state_status() {
    local unit_name="$1"
    local status="$2"
    local reason="${3:-unspecified}"
    
    # Write to disk for persistence
    write_unit_state_status "$unit_name" "$status" "$reason"
}

# Check if terraform backend/state is available for a unit
# Args: $1=unit_path
# Returns: 0 if available, 1 if not
# Sets: BACKEND_INIT_OUTPUT with the terraform init output
check_backend_availability() {
    local unit_path="$1"
    
    pushd "$unit_path" > /dev/null
    
    # Try terraform init with backend
    set +e
    BACKEND_INIT_OUTPUT=$(terraform init -input=false 2>&1)
    local init_exit=$?
    set -e
    
    popd > /dev/null
    
    if [[ $init_exit -eq 0 ]]; then
        return 0  # Backend available
    fi
    
    # Check if failure is due to missing remote state
    if echo "$BACKEND_INIT_OUTPUT" | grep -qE "Unable to find remote state|No stored state was found|Error loading state|Backend initialization required|Error configuring the backend|Failed to get existing workspaces|no state"; then
        return 1  # Backend unavailable (remote state issue)
    fi
    
    # Other init errors - still return failure
    return 1
}

# Clear state status for a specific unit (useful for re-runs)
# Args: $1=unit_name
clear_unit_state_status() {
    local unit_name="$1"
    local status_file="${ILTERO_STATE_DIR}/${unit_name}.json"
    
    if [[ -f "$status_file" ]]; then
        rm -f "$status_file"
        log_debug "Cleared state status for unit: $unit_name"
    fi
}

# Clear all state status files (useful for fresh runs)
clear_all_state_status() {
    if [[ -d "$ILTERO_STATE_DIR" ]]; then
        rm -f "${ILTERO_STATE_DIR}"/*.json
        log_debug "Cleared all state status files"
    fi
}

# List all units with their current state status
list_state_status() {
    if [[ ! -d "$ILTERO_STATE_DIR" ]]; then
        log_info "No state status directory found"
        return 0
    fi
    
    log_info "Current unit state status:"
    for status_file in "${ILTERO_STATE_DIR}"/*.json; do
        if [[ -f "$status_file" ]]; then
            local unit status timestamp
            unit=$(jq -r '.unit' "$status_file" 2>/dev/null)
            status=$(jq -r '.status' "$status_file" 2>/dev/null)
            timestamp=$(jq -r '.timestamp' "$status_file" 2>/dev/null)
            log_info "  - $unit: $status (updated: $timestamp)"
        fi
    done
}
