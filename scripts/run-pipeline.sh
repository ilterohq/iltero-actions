#!/bin/bash
# =============================================================================
# Iltero Actions - Main Pipeline Script
# =============================================================================
# This script orchestrates the complete infrastructure compliance pipeline:
#   1. Detect environment from git ref (or use override)
#   2. Detect stacks from changed files (or use manual input)
#   3. For each stack: parse config, run compliance, evaluate plans, deploy
#
# Usage:
#   run-pipeline.sh [OPTIONS]
#
# Modes:
#   --scan-only         Run compliance scan only
#   --evaluate-only     Run plan evaluation only
#   --deploy-only       Run deployment only (requires --run-id)
#   (default)           Run full pipeline
#
# Options:
#   --stacks-path PATH  Path to stacks directory (required unless env STACKS_PATH set)
#   --stack NAME        Process specific stack
#   --unit NAME         Process specific unit within stack
#   --environment ENV   Override environment detection
#   --run-id ID         Chain to existing Iltero run
#   --dry-run           Skip deployment phase
#   --skip-compliance   Skip compliance scanning
#   --verify-auth       Verify deployment authorization (default: true)
#   --no-verify-auth    Skip authorization verification
#   --debug             Enable debug output
#   -h, --help          Show help
#
# Environment Variables (backward compatible with action.yml):
#   STACKS_PATH          - Path to stacks directory
#   ENVIRONMENT_OVERRIDE - Optional environment override
#   MANUAL_STACK         - Optional specific stack to process
#   DRY_RUN              - Skip deployment if true
#   SKIP_COMPLIANCE      - Skip compliance scanning if true
#   DEPLOY_ONLY          - Skip compliance, run deployment only
#   RUN_ID               - Existing run ID
#   VERIFY_AUTHORIZATION - Verify deployment authorization
#   DEBUG                - Enable debug output
#   REGISTRY_HOST        - Hostname for private module registry
#   ILTERO_REGISTRY_TOKEN - Token for private module authentication
#   GITHUB_*             - GitHub Actions context variables
# =============================================================================

set -euo pipefail

# Get script directory for sourcing other scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper scripts
source "${SCRIPT_DIR}/lib/iltero-core/index.sh"
source "${SCRIPT_DIR}/lib/config-parser.sh"
source "${SCRIPT_DIR}/detect-environment.sh"
source "${SCRIPT_DIR}/detect-stacks.sh"

# =============================================================================
# CLI Usage
# =============================================================================
usage() {
    cat << 'EOF'
Usage: run-pipeline.sh [OPTIONS]

Iltero Infrastructure Compliance Pipeline

Modes:
  --scan-only         Run compliance scan only
  --evaluate-only     Run plan evaluation only
  --deploy-only       Run deployment only (requires --run-id)
  (default)           Run full pipeline

Options:
  --stacks-path PATH  Path to stacks directory (required)
  --stack NAME        Process specific stack
  --unit NAME         Process specific unit within stack
  --environment ENV   Override environment detection
  --run-id ID         Chain to existing Iltero run
  --dry-run           Skip deployment phase
  --skip-compliance   Skip compliance scanning
  --verify-auth       Verify deployment authorization (default)
  --no-verify-auth    Skip authorization verification
  --debug             Enable debug output
  -h, --help          Show this help

Examples:
  # Full pipeline for specific stack
  run-pipeline.sh --stacks-path infra/stacks --stack my-infra --environment production

  # Scan only (CI check)
  run-pipeline.sh --scan-only --stacks-path infra/stacks

  # Deploy after approval
  run-pipeline.sh --deploy-only --run-id abc123 --stacks-path infra/stacks --stack my-infra

EOF
}

# =============================================================================
# Configuration (defaults from environment for backward compatibility)
# =============================================================================
MODE="full"
STACKS_PATH="${STACKS_PATH:-}"
PIPELINE_MODE="${PIPELINE_MODE:-}"
CONFIG_PATH="${CONFIG_PATH:-.iltero/config.yml}"
STACK="${MANUAL_STACK:-}"
UNIT_FILTER=""
ENVIRONMENT="${ENVIRONMENT_OVERRIDE:-}"
GLOBAL_RUN_ID="${RUN_ID:-}"
GLOBAL_SCAN_ID="${SCAN_ID:-}"  # Scan ID from policy resolution (required for apply phase)
DRY_RUN="${DRY_RUN:-false}"
SKIP_COMPLIANCE="${SKIP_COMPLIANCE:-false}"
VERIFY_AUTHORIZATION="${VERIFY_AUTHORIZATION:-true}"
DEBUG="${DEBUG:-false}"

# Handle DEPLOY_ONLY env var for backward compatibility
if [[ "${DEPLOY_ONLY:-false}" == "true" ]]; then
    MODE="deploy"
fi

# Pipeline state
COMPLIANCE_FAILED=false
EVALUATION_FAILED=false
DEPLOY_FAILED=false
AUTHORIZATION_FAILED=false
PROCESSED_STACKS=()
APPROVAL_ID=""
declare -A FAILED_UNITS  # Track failed units for dependency checking

# =============================================================================
# Parse CLI Arguments
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --scan-only)
                MODE="scan"
                shift
                ;;
            --evaluate-only)
                MODE="evaluate"
                shift
                ;;
            --deploy-only)
                MODE="deploy"
                shift
                ;;
            --stacks-path)
                STACKS_PATH="$2"
                shift 2
                ;;
            --stack)
                STACK="$2"
                shift 2
                ;;
            --unit)
                UNIT_FILTER="$2"
                shift 2
                ;;
            --environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --run-id)
                GLOBAL_RUN_ID="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-compliance)
                SKIP_COMPLIANCE=true
                shift
                ;;
            --verify-auth)
                VERIFY_AUTHORIZATION=true
                shift
                ;;
            --no-verify-auth)
                VERIFY_AUTHORIZATION=false
                shift
                ;;
            --debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ "$PIPELINE_MODE" != "brownfield" ]] && [[ -z "$STACKS_PATH" ]]; then
        log_error "stacks-path is required (--stacks-path or STACKS_PATH env var)"
        exit 1
    fi

    if [[ "$MODE" == "deploy" ]] && [[ -z "$GLOBAL_RUN_ID" ]]; then
        log_error "run-id is required for deploy-only mode"
        exit 1
    fi
}

# =============================================================================
# Process a single infrastructure unit (using shared library)
# =============================================================================
process_unit() {
    local stack="$1"
    local unit_name="$2"
    local unit_path="$3"
    local stack_id="$4"
    local environment="$5"
    local severity_threshold="$6"
    local scan_types="$7"
    local depends_on="$8"  # JSON array of dependencies
    local frameworks="${9:-}"  # Comma-separated compliance
    local config_path="${10:-}"  # Path for --config-path flag

    local full_path="${STACKS_PATH}/${stack}/${unit_path}"

    # Skip if unit filter is set and doesn't match
    if [[ -n "$UNIT_FILTER" ]] && [[ "$UNIT_FILTER" != "$unit_name" ]]; then
        log_debug "Skipping unit $unit_name (filter: $UNIT_FILTER)"
        return 0
    fi

    # Per-unit result collectors (JSON objects or "null" for skipped phases)
    local scan_result_json="null"
    local eval_result_json="null"
    local deploy_result_json="null"

    # Check dependency status (warn but never skip — scan everything)
    local dep_has_failures=false
    if [[ -n "$depends_on" ]] && [[ "$depends_on" != "[]" ]] && [[ "$depends_on" != "null" ]]; then
        for dep in $(echo "$depends_on" | jq -r '.[]' 2>/dev/null); do
            if [[ -n "${FAILED_UNITS[$dep]:-}" ]]; then
                local dep_failure_type="${FAILED_UNITS[$dep]}"
                log_warning "Dependency '$dep' has status '$dep_failure_type' — $unit_name will still be scanned/evaluated"
                dep_has_failures=true
            fi
        done
    fi

    # Validate unit structure first
    if ! validate_unit_structure "$full_path"; then
        scan_result_json=$(jq -n --arg unit "$unit_name" \
            '{passed: false, skipped: false, violations: 0, error: "validation_failed"}')
        append_unit_result "$stack" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
        FAILED_UNITS["$unit_name"]="validation_failed"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Compliance Scan (if enabled) — always runs regardless of dep failures
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "scan" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$SKIP_COMPLIANCE" != "true" ]] && echo "$scan_types" | jq -e 'contains(["static"])' > /dev/null 2>&1; then
            set +e
            run_compliance_scan "$full_path" "$stack_id" "$unit_name" "$environment" "$severity_threshold" "$GLOBAL_RUN_ID" "$frameworks" "$config_path"
            local scan_exit=$?
            set -e

            # Update global run ID for chaining
            if [[ -n "$SCAN_RUN_ID" ]]; then
                if [[ -n "$GLOBAL_RUN_ID" ]] && [[ "$SCAN_RUN_ID" != "$GLOBAL_RUN_ID" ]]; then
                    log_warning "Run ID mismatch after scan: expected=$GLOBAL_RUN_ID, got=$SCAN_RUN_ID"
                fi
                log_info "Setting global run ID from static scan: $SCAN_RUN_ID"
                GLOBAL_RUN_ID="$SCAN_RUN_ID"
            fi

            # Update global scan ID for apply phase (scan_id from policy resolution)
            if [[ -n "${SCAN_ID:-}" ]]; then
                GLOBAL_SCAN_ID="$SCAN_ID"
            fi

            # Collect scan result
            local scan_passed="true"
            if [[ $scan_exit -ne 0 ]]; then
                COMPLIANCE_FAILED=true
                FAILED_UNITS["$unit_name"]="compliance_failed"
                scan_passed="false"
            fi

            scan_result_json=$(jq -n \
                --arg passed "$scan_passed" \
                --argjson violations "${SCAN_VIOLATIONS:-0}" \
                --arg scan_id "${SCAN_ID:-}" \
                --arg run_id "${SCAN_RUN_ID:-}" \
                '{passed: ($passed == "true"), skipped: false, violations: $violations, scan_id: $scan_id, run_id: $run_id}')
        else
            scan_result_json=$(jq -n '{passed: true, skipped: true, violations: 0}')
        fi
    fi

    # -------------------------------------------------------------------------
    # Plan Evaluation (if enabled) — always runs regardless of dep failures
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "evaluate" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$SKIP_COMPLIANCE" != "true" ]] && echo "$scan_types" | jq -e 'contains(["evaluation"])' > /dev/null 2>&1; then
            set +e
            run_plan_evaluation "$full_path" "$stack_id" "$unit_name" "$environment" "$severity_threshold" "$GLOBAL_RUN_ID" "" "$depends_on" "$frameworks"
            local eval_exit=$?
            set -e

            # Update global run ID and approval ID
            if [[ -n "$EVAL_RUN_ID" ]]; then
                if [[ -n "$GLOBAL_RUN_ID" ]] && [[ "$EVAL_RUN_ID" != "$GLOBAL_RUN_ID" ]]; then
                    log_warning "Run ID mismatch after evaluation: expected=$GLOBAL_RUN_ID, got=$EVAL_RUN_ID"
                fi
                log_info "Setting global run ID from evaluation: $EVAL_RUN_ID"
                GLOBAL_RUN_ID="$EVAL_RUN_ID"
            fi

            # Update global scan ID for apply phase (scan_id from policy resolution)
            if [[ -n "${EVAL_SCAN_ID:-}" ]]; then
                GLOBAL_SCAN_ID="$EVAL_SCAN_ID"
            fi

            if [[ -n "${APPROVAL_ID:-}" ]] && [[ -z "$APPROVAL_ID" ]]; then
                APPROVAL_ID="$APPROVAL_ID"
            fi

            local eval_passed="true"
            if [[ $eval_exit -ne 0 ]]; then
                EVALUATION_FAILED=true
                if [[ "${EVAL_VIOLATIONS:-0}" -gt 0 ]]; then
                    FAILED_UNITS["$unit_name"]="evaluation_failed"
                    log_warning "Unit $unit_name has $EVAL_VIOLATIONS policy violations"
                else
                    FAILED_UNITS["$unit_name"]="infra_error"
                    log_warning "Unit $unit_name had infrastructure errors but no policy violations"
                fi
                eval_passed="false"
            fi

            eval_result_json=$(jq -n \
                --arg passed "$eval_passed" \
                --argjson violations "${EVAL_VIOLATIONS:-0}" \
                --arg eval_mode "${EVAL_MODE:-full}" \
                --arg run_id "${EVAL_RUN_ID:-}" \
                --arg scan_id "${EVAL_SCAN_ID:-}" \
                --arg approval_id "${APPROVAL_ID:-}" \
                '{passed: ($passed == "true"), skipped: false, violations: $violations, eval_mode: $eval_mode, run_id: $run_id, scan_id: $scan_id, approval_id: $approval_id}')
        else
            eval_result_json=$(jq -n '{passed: true, skipped: true, violations: 0}')
        fi
    fi

    # -------------------------------------------------------------------------
    # Deployment (if enabled and NO failures anywhere)
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "deploy" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$DRY_RUN" != "true" ]] && \
           [[ "$COMPLIANCE_FAILED" != "true" ]] && \
           [[ "$EVALUATION_FAILED" != "true" ]]; then

            # Only deploy in deploy mode or if specifically enabled in full mode
            local should_deploy=false
            if [[ "$MODE" == "deploy" ]]; then
                should_deploy=true
            fi

            if [[ "$should_deploy" == "true" ]]; then
                # Verify authorization before deployment
                if [[ "$VERIFY_AUTHORIZATION" == "true" ]]; then
                    if ! verify_authorization "$GLOBAL_RUN_ID" "$stack_id" "$environment" "$unit_name"; then
                        AUTHORIZATION_FAILED=true
                        deploy_result_json=$(jq -n '{success: false, skipped: false, error: "authorization_failed"}')
                        append_unit_result "$stack" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
                        return 1
                    fi
                fi

                # Run deployment with scan_id for apply phase API notification
                set +e
                run_deployment "$full_path" "$unit_name" "$environment" "$GLOBAL_RUN_ID" "$GLOBAL_SCAN_ID"
                local deploy_exit=$?
                set -e

                local deploy_success="true"
                if [[ $deploy_exit -ne 0 ]]; then
                    DEPLOY_FAILED=true
                    deploy_success="false"
                fi

                deploy_result_json=$(jq -n \
                    --arg success "$deploy_success" \
                    '{success: ($success == "true"), skipped: false}')
            else
                deploy_result_json=$(jq -n '{success: true, skipped: true}')
                log_debug "Deployment skipped for ${unit_name} (use --deploy-only or MODE=deploy)"
            fi
        else
            deploy_result_json=$(jq -n '{success: false, skipped: true, reason: "compliance_or_evaluation_failed"}')
        fi
    fi

    # Append collected results for this unit
    append_unit_result "$stack" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
}

# =============================================================================
# Process a single stack
# =============================================================================
process_stack() {
    local stack="$1"
    local config_file="${STACKS_PATH}/${stack}/config.yml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    log_group "📦 Processing stack: $stack"

    # Export stack name for use by scanning.sh, evaluation.sh, and state tracking
    export ILTERO_STACK_NAME="$stack"

    # Initialize remote state tracking for this stack (.iltero/{stack}/state-status/)
    init_remote_state_tracking "$stack"

    # Initialize result tracking for this stack (.iltero/{stack}/results.json)
    init_stack_results "$stack"

    # -------------------------------------------------------------------------
    # Extract Stack Configuration (including workspace)
    # -------------------------------------------------------------------------
    local stack_id stack_name workspace
    stack_id=$(yq eval '.stack.id // ""' "$config_file")
    stack_name=$(yq eval '.stack.name // ""' "$config_file")
    workspace=$(yq eval '.stack.workspace // ""' "$config_file")

    if [[ -z "$stack_id" ]]; then
        log_error "stack.id is required in config.yml"
        return 1
    fi

    # Export workspace for CLI commands (used by iltero-cli for API headers)
    if [[ -n "$workspace" ]]; then
        export ILTERO_WORKSPACE="$workspace"
        log_info "Workspace: $workspace"
    fi

    # -------------------------------------------------------------------------
    # Detect Environment
    # -------------------------------------------------------------------------
    local environment
    if [[ -n "$ENVIRONMENT" ]]; then
        environment="$ENVIRONMENT"
        log_info "Using environment override: $environment"
    else
        environment=$(detect_environment "$config_file")
        log_info "Auto-detected environment: $environment"
    fi

    # Validate environment exists in config
    if ! yq eval ".environments.${environment}" "$config_file" > /dev/null 2>&1; then
        log_error "Environment '$environment' not found in config.yml"
        log_info "Available environments:"
        yq eval '.environments | keys | .[]' "$config_file" | while read -r env; do
            log_info "  - $env"
        done
        return 1
    fi

    # -------------------------------------------------------------------------
    # Extract Environment-specific Configuration
    # -------------------------------------------------------------------------
    # Environment-specific settings
    local scan_types severity_threshold require_approval frameworks_csv
    scan_types=$(yq eval ".environments.${environment}.compliance.scan_types // [\"static\"]" "$config_file" -o json)
    severity_threshold=$(yq eval ".environments.${environment}.security.severity_threshold // \"high\"" "$config_file")
    require_approval=$(yq eval ".environments.${environment}.deployment.require_approval // false" "$config_file")
    frameworks_csv=$(yq eval ".environments.${environment}.compliance.frameworks // []" "$config_file" -o json | jq -r 'join(",")' 2>/dev/null || echo "")

    # Default framework based on cloud provider if none explicitly configured
    if [[ -z "$frameworks_csv" ]]; then
        local cloud_provider
        cloud_provider=$(yq eval ".environments.${environment}.cloud.provider // \"\"" "$config_file" 2>/dev/null || echo "")
        case "$cloud_provider" in
            aws)   frameworks_csv="CIS-AWS" ;;
            azure) frameworks_csv="CIS-Azure" ;;
            gcp)   frameworks_csv="CIS-GCP" ;;
        esac
        if [[ -n "$frameworks_csv" ]]; then
            log_info "No frameworks configured, defaulting to ${frameworks_csv} based on provider: ${cloud_provider}"
        fi
    fi

    log_info "Stack ID: $stack_id"
    log_info "Stack Name: $stack_name"
    log_info "Environment: $environment"
    log_info "Mode: $MODE"
    log_info "Severity threshold: $severity_threshold"
    log_info "Compliance frameworks: $frameworks_csv"

    # -------------------------------------------------------------------------
    # Get Units in Dependency Order (using shared library)
    # -------------------------------------------------------------------------
    local units
    units=$(yq eval '.infrastructure_units[] | select(.enabled != false)' "$config_file" -o json | jq -s '.')
    local unit_count
    unit_count=$(echo "$units" | jq 'length')

    if [[ "$unit_count" -eq 0 ]]; then
        log_warning "No enabled infrastructure units found"
        log_group_end
        return 0
    fi

    # Topological sort for dependency ordering
    local ordered_units
    ordered_units=$(sort_units_by_dependency "$units")

    local unit_names
    unit_names=$(echo "$ordered_units" | jq -r '.[].name')
    log_info "Units (in order): $(echo "$unit_names" | tr '\n' ' ')"

    # -------------------------------------------------------------------------
    # Process Each Unit
    # -------------------------------------------------------------------------
    for unit_name in $unit_names; do
        local unit_path
        unit_path=$(echo "$ordered_units" | jq -r ".[] | select(.name == \"$unit_name\") | .path")
        local depends_on
        depends_on=$(echo "$ordered_units" | jq -c ".[] | select(.name == \"$unit_name\") | .depends_on // []")

        process_unit \
            "$stack" \
            "$unit_name" \
            "$unit_path" \
            "$stack_id" \
            "$environment" \
            "$severity_threshold" \
            "$scan_types" \
            "$depends_on" \
            "$frameworks_csv" \
            "$config_file"
    done

    PROCESSED_STACKS+=("$stack")

    # Set outputs
    set_output "environment" "$environment"
    set_output "require_approval" "$require_approval"

    # Output approval info if applicable
    if [[ "$require_approval" == "true" ]] && [[ -n "$APPROVAL_ID" ]]; then
        set_output "approval_id" "$APPROVAL_ID"
        log_success "Approval created: $APPROVAL_ID"
    fi

    log_group_end
}

# =============================================================================
# Process a brownfield unit (simplified — no dependency checking)
# =============================================================================
process_brownfield_unit() {
    local stack_name="$1"
    local tf_dir="$2"
    local stack_id="$3"
    local environment="$4"
    local severity_threshold="$5"
    local scan_types="$6"
    local frameworks="${7:-}"
    local config_path="${8:-}"

    # Unit name is the stack name (single "unit")
    local unit_name="$stack_name"

    # Per-unit result collectors
    local scan_result_json="null"
    local eval_result_json="null"
    local deploy_result_json="null"

    # Validate brownfield structure (relaxed — only check .tf files exist)
    if ! validate_brownfield_structure "$tf_dir"; then
        scan_result_json=$(jq -n '{passed: false, skipped: false, violations: 0, error: "validation_failed"}')
        append_unit_result "$stack_name" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
        return 1
    fi

    # -------------------------------------------------------------------------
    # Compliance Scan (if enabled)
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "scan" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$SKIP_COMPLIANCE" != "true" ]] && echo "$scan_types" | jq -e 'contains(["static"])' > /dev/null 2>&1; then
            set +e
            run_compliance_scan "$tf_dir" "$stack_id" "$unit_name" "$environment" "$severity_threshold" "$GLOBAL_RUN_ID" "$frameworks" "$config_path"
            local scan_exit=$?
            set -e

            if [[ -n "$SCAN_RUN_ID" ]]; then
                if [[ -n "$GLOBAL_RUN_ID" ]] && [[ "$SCAN_RUN_ID" != "$GLOBAL_RUN_ID" ]]; then
                    log_warning "Run ID mismatch after scan: expected=$GLOBAL_RUN_ID, got=$SCAN_RUN_ID"
                fi
                GLOBAL_RUN_ID="$SCAN_RUN_ID"
            fi
            if [[ -n "${SCAN_ID:-}" ]]; then
                GLOBAL_SCAN_ID="$SCAN_ID"
            fi

            local scan_passed="true"
            if [[ $scan_exit -ne 0 ]]; then
                COMPLIANCE_FAILED=true
                scan_passed="false"
            fi

            scan_result_json=$(jq -n \
                --arg passed "$scan_passed" \
                --argjson violations "${SCAN_VIOLATIONS:-0}" \
                --arg scan_id "${SCAN_ID:-}" \
                --arg run_id "${SCAN_RUN_ID:-}" \
                '{passed: ($passed == "true"), skipped: false, violations: $violations, scan_id: $scan_id, run_id: $run_id}')
        else
            scan_result_json=$(jq -n '{passed: true, skipped: true, violations: 0}')
        fi
    fi

    # -------------------------------------------------------------------------
    # Plan Evaluation (if enabled)
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "evaluate" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$SKIP_COMPLIANCE" != "true" ]] && echo "$scan_types" | jq -e 'contains(["evaluation"])' > /dev/null 2>&1; then
            set +e
            run_plan_evaluation "$tf_dir" "$stack_id" "$unit_name" "$environment" "$severity_threshold" "$GLOBAL_RUN_ID" "" "[]" "$frameworks"
            local eval_exit=$?
            set -e

            if [[ -n "$EVAL_RUN_ID" ]]; then
                if [[ -n "$GLOBAL_RUN_ID" ]] && [[ "$EVAL_RUN_ID" != "$GLOBAL_RUN_ID" ]]; then
                    log_warning "Run ID mismatch after evaluation: expected=$GLOBAL_RUN_ID, got=$EVAL_RUN_ID"
                fi
                GLOBAL_RUN_ID="$EVAL_RUN_ID"
            fi
            if [[ -n "${EVAL_SCAN_ID:-}" ]]; then
                GLOBAL_SCAN_ID="$EVAL_SCAN_ID"
            fi

            local eval_passed="true"
            if [[ $eval_exit -ne 0 ]]; then
                EVALUATION_FAILED=true
                eval_passed="false"
            fi

            eval_result_json=$(jq -n \
                --arg passed "$eval_passed" \
                --argjson violations "${EVAL_VIOLATIONS:-0}" \
                --arg eval_mode "${EVAL_MODE:-full}" \
                --arg run_id "${EVAL_RUN_ID:-}" \
                --arg scan_id "${EVAL_SCAN_ID:-}" \
                '{passed: ($passed == "true"), skipped: false, violations: $violations, eval_mode: $eval_mode, run_id: $run_id, scan_id: $scan_id}')
        else
            eval_result_json=$(jq -n '{passed: true, skipped: true, violations: 0}')
        fi
    fi

    # -------------------------------------------------------------------------
    # Deployment (if enabled and conditions met)
    # -------------------------------------------------------------------------
    if [[ "$MODE" == "deploy" ]] || [[ "$MODE" == "full" ]]; then
        if [[ "$DRY_RUN" != "true" ]] && \
           [[ "$COMPLIANCE_FAILED" != "true" ]] && \
           [[ "$EVALUATION_FAILED" != "true" ]]; then

            local should_deploy=false
            if [[ "$MODE" == "deploy" ]]; then
                should_deploy=true
            fi

            if [[ "$should_deploy" == "true" ]]; then
                if [[ "$VERIFY_AUTHORIZATION" == "true" ]]; then
                    if ! verify_authorization "$GLOBAL_RUN_ID" "$stack_id" "$environment" "$unit_name"; then
                        AUTHORIZATION_FAILED=true
                        deploy_result_json=$(jq -n '{success: false, skipped: false, error: "authorization_failed"}')
                        append_unit_result "$stack_name" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
                        return 1
                    fi
                fi

                set +e
                run_deployment "$tf_dir" "$unit_name" "$environment" "$GLOBAL_RUN_ID" "$GLOBAL_SCAN_ID"
                local deploy_exit=$?
                set -e

                local deploy_success="true"
                if [[ $deploy_exit -ne 0 ]]; then
                    DEPLOY_FAILED=true
                    deploy_success="false"
                fi

                deploy_result_json=$(jq -n \
                    --arg success "$deploy_success" \
                    '{success: ($success == "true"), skipped: false}')
            else
                deploy_result_json=$(jq -n '{success: true, skipped: true}')
            fi
        else
            deploy_result_json=$(jq -n '{success: false, skipped: true, reason: "compliance_or_evaluation_failed"}')
        fi
    fi

    # Append collected results
    append_unit_result "$stack_name" "$unit_name" "$scan_result_json" "$eval_result_json" "$deploy_result_json"
}

# =============================================================================
# Process a brownfield stack
# =============================================================================
process_brownfield_stack() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Extract configuration
    local stack_id stack_name stack_slug workspace tf_dir
    stack_id=$(yq eval '.stack.id // ""' "$config_file")
    stack_name=$(yq eval '.stack.name // ""' "$config_file")
    stack_slug=$(yq eval '.stack.slug // ""' "$config_file")
    workspace=$(yq eval '.stack.workspace // ""' "$config_file")
    tf_dir=$(yq eval '.stack.terraform_working_directory // "."' "$config_file")

    if [[ -z "$stack_id" ]]; then
        log_error "stack.id is required in config.yml"
        return 1
    fi

    export ILTERO_STACK_NAME="${stack_slug:-$stack_name}"
    [[ -n "$workspace" ]] && export ILTERO_WORKSPACE="$workspace"

    # Initialize remote state tracking
    init_remote_state_tracking "${stack_slug:-$stack_name}"

    # Initialize result tracking for this stack
    init_stack_results "${stack_slug:-$stack_name}"

    log_group "Processing brownfield stack: $stack_name"

    # Detect environment
    local environment
    if [[ -n "$ENVIRONMENT" ]]; then
        environment="$ENVIRONMENT"
        log_info "Using environment override: $environment"
    else
        environment=$(detect_environment "$config_file")
        log_info "Auto-detected environment: $environment"
    fi

    # Extract environment-specific config
    local scan_types severity_threshold require_approval frameworks_csv
    scan_types=$(yq eval ".environments.${environment}.compliance.scan_types // [\"static\"]" "$config_file" -o json)
    severity_threshold=$(yq eval ".environments.${environment}.security.severity_threshold // \"high\"" "$config_file")
    require_approval=$(yq eval ".environments.${environment}.deployment.require_approval // false" "$config_file")
    frameworks_csv=$(yq eval ".environments.${environment}.compliance.frameworks // []" "$config_file" -o json | jq -r 'join(",")' 2>/dev/null || echo "")

    log_info "Stack ID: $stack_id"
    log_info "Stack Name: $stack_name"
    log_info "Environment: $environment"
    log_info "Terraform Dir: $tf_dir"
    log_info "Mode: $MODE"
    log_info "Severity threshold: $severity_threshold"
    log_info "Compliance frameworks: $frameworks_csv"

    # No unit iteration — process terraform_working_directory directly
    process_brownfield_unit \
        "${stack_slug:-$stack_name}" \
        "$tf_dir" \
        "$stack_id" \
        "$environment" \
        "$severity_threshold" \
        "$scan_types" \
        "$frameworks_csv" \
        "$config_file"

    PROCESSED_STACKS+=("${stack_slug:-$stack_name}")

    # Set outputs
    set_output "environment" "$environment"
    set_output "require_approval" "$require_approval"

    if [[ "$require_approval" == "true" ]] && [[ -n "$APPROVAL_ID" ]]; then
        set_output "approval_id" "$APPROVAL_ID"
        log_success "Approval created: $APPROVAL_ID"
    fi

    log_group_end
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    # Parse CLI arguments (if any)
    parse_args "$@"

    log_banner "Iltero Infrastructure Pipeline"
    log_info "Mode: $MODE"

    # -------------------------------------------------------------------------
    # Configure Registry Credentials (if token provided)
    # -------------------------------------------------------------------------
    configure_registry "${ILTERO_REGISTRY_TOKEN:-}" "${REGISTRY_HOST:-registry.localhost}"

    # -------------------------------------------------------------------------
    # Brownfield vs Greenfield Pipeline
    # -------------------------------------------------------------------------
    if [[ "$PIPELINE_MODE" == "brownfield" ]]; then
        # Brownfield: single config file, no stacks directory
        local stacks_json
        if [[ -n "$STACK" ]]; then
            stacks_json="[\"$STACK\"]"
            log_info "Using manual stack: $STACK"
        else
            stacks_json=$(detect_brownfield_stack "$CONFIG_PATH")
            log_info "Auto-detected brownfield stack: $stacks_json"
        fi

        if [[ "$stacks_json" == "[]" ]] || [[ -z "$stacks_json" ]]; then
            log_info "No stacks to process"
            set_output "stacks_processed" "[]"
            set_output "overall_status" "skipped"
            set_output "compliance_passed" "true"
            set_output "evaluation_passed" "true"
            exit 0
        fi

        # Brownfield always processes the single config file
        process_brownfield_stack "$CONFIG_PATH" || true
    else
        # Greenfield: stacks directory with infrastructure units
        if [[ ! -d "$STACKS_PATH" ]]; then
            log_error "Stacks directory not found: $STACKS_PATH"
            exit 1
        fi

        local stacks_json
        if [[ -n "$STACK" ]]; then
            stacks_json="[\"$STACK\"]"
            log_info "Using manual stack: $STACK"
        else
            stacks_json=$(detect_stacks "$STACKS_PATH")
            log_info "Auto-detected stacks: $stacks_json"
        fi

        if [[ "$stacks_json" == "[]" ]] || [[ -z "$stacks_json" ]]; then
            log_info "No stacks to process"
            set_output "stacks_processed" "[]"
            set_output "overall_status" "skipped"
            set_output "compliance_passed" "true"
            set_output "evaluation_passed" "true"
            exit 0
        fi

        for stack in $(echo "$stacks_json" | jq -r '.[]'); do
            process_stack "$stack" || true
        done
    fi

    # -------------------------------------------------------------------------
    # Aggregate Results & Set Outputs
    # -------------------------------------------------------------------------
    local processed_json
    # Use jq -c for compact single-line JSON to avoid GitHub Actions output formatting issues
    processed_json=$(printf '%s\n' "${PROCESSED_STACKS[@]}" | jq -R . | jq -sc .)
    set_output "stacks_processed" "$processed_json"
    set_output "run_id" "$GLOBAL_RUN_ID"

    # Aggregate per-unit results from all stacks
    local all_unit_results
    all_unit_results=$(get_all_results)
    set_output "unit_results" "$(echo "$all_unit_results" | jq -c .)"

    # Count violations across all units for reporting
    local total_scan_violations total_eval_violations
    total_scan_violations=$(echo "$all_unit_results" | jq '[.[].scan // {} | .violations // 0] | add // 0')
    total_eval_violations=$(echo "$all_unit_results" | jq '[.[].evaluation // {} | .violations // 0] | add // 0')

    # Determine compliance_passed and evaluation_passed independently
    local compliance_passed="true"
    local evaluation_passed="true"
    if [[ "$COMPLIANCE_FAILED" == "true" ]]; then
        compliance_passed="false"
    fi
    if [[ "$EVALUATION_FAILED" == "true" ]]; then
        evaluation_passed="false"
    fi

    set_output "compliance_passed" "$compliance_passed"
    set_output "evaluation_passed" "$evaluation_passed"

    if [[ "$COMPLIANCE_FAILED" == "true" ]] || [[ "$EVALUATION_FAILED" == "true" ]]; then
        if [[ "$COMPLIANCE_FAILED" == "true" ]] && [[ "$EVALUATION_FAILED" == "true" ]]; then
            set_output "overall_status" "compliance_failed"
            log_error "Pipeline failed: $total_scan_violations scan violation(s) and $total_eval_violations evaluation violation(s) detected"
        elif [[ "$COMPLIANCE_FAILED" == "true" ]]; then
            set_output "overall_status" "compliance_failed"
            log_error "Pipeline failed: $total_scan_violations compliance violation(s) detected"
        else
            set_output "overall_status" "evaluation_failed"
            log_error "Pipeline failed: $total_eval_violations plan evaluation violation(s) detected"
        fi
        exit 1
    elif [[ "$AUTHORIZATION_FAILED" == "true" ]]; then
        set_output "overall_status" "authorization_failed"
        set_output "authorization_passed" "false"
        log_error "Pipeline failed: Deployment not authorized"
        exit 1
    elif [[ "$DEPLOY_FAILED" == "true" ]]; then
        set_output "overall_status" "deploy_failed"
        set_output "authorization_passed" "true"
        log_error "Pipeline failed: Deployment failed"
        exit 1
    else
        set_output "overall_status" "success"
        set_output "authorization_passed" "true"
        set_output "deployment_ready" "true"
        log_success "Pipeline completed successfully"
    fi
}

main "$@"
