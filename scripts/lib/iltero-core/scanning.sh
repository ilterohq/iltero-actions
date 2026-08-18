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
# Exit codes returned by run_static_scan (the CLI's, passed through):
#   0       - scan completed; nothing at or above the threshold
#   1       - scan completed; findings at or above the threshold
#   anything else - the scan did not run to a compliance verdict
#
# Exports after run_static_scan():
#   SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_STATUS, SCAN_VIOLATIONS,
#   SCAN_EXIT_CODE, SCAN_RESULTS_FILE
#   SCAN_PLAN_JSON_FILE       - absolute path to the plan JSON (plan-mode)
#   SCAN_PLAN_STATE_JSON_FILE - pre-plan state JSON (plan-mode), or empty
#   SCAN_PLAN_S3_URL          - s3:// URL of uploaded plan (plan-mode), or empty
#   SCAN_PLAN_MODE            - "full" | "best_effort" (plan-mode), or empty
#   SCAN_PLAN_DIGEST          - canonical plan digest (provenance), or empty
#   SCAN_PLAN_CANON_VERSION   - canonicalization spec version, or empty
# All SCAN_PLAN_* are empty when source-mode is used.
#
# SCAN_STATUS values. A superset of SCAN_PASSED (pass <=> SCAN_PASSED=true)
# that lets the caller tell a compliance verdict apart from a scan that never
# produced one — the distinction block_on_violations turns on:
#   "pass"        - exit 0: the scan ran and nothing was at or above threshold
#   "violations"  - exit 1 with results recorded: findings at or above the
#                   threshold. The ONLY state block_on_violations may waive
#   "infra_error" - no verdict was produced: any other exit code, or exit 1 with no
#                   results file (the CLI stopped before scanning). Always
#                   blocks — there are no findings to accept
#
# The exit code decides first. A results file can exist alongside a failure, so
# its presence is only used to disambiguate exit 1, which the CLI uses both for
# "findings above threshold" and for "could not start".
# =============================================================================

# Run static scan using iltero CLI
# Args: $1=path $2=stack_id $3=unit $4=environment $5=fail_on $6=run_id (optional) $7=frameworks (optional) $8=config_path (optional)
# Sets: SCAN_RUN_ID, SCAN_ID, SCAN_PASSED, SCAN_STATUS, SCAN_VIOLATIONS,
#       SCAN_EXIT_CODE, SCAN_RESULTS_FILE
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
    # Published so a caller can retain the evidence file it just produced.
    SCAN_RESULTS_FILE="${results_file}"

    # Reset outputs
    SCAN_RUN_ID=""
    SCAN_ID=""
    SCAN_PASSED="false"
    # Fail closed: any path that returns without setting this reads as an error,
    # never as a pass.
    SCAN_STATUS="infra_error"
    SCAN_VIOLATIONS="0"
    SCAN_EXIT_CODE=0
    SCAN_PLAN_JSON_FILE=""
    SCAN_PLAN_STATE_JSON_FILE=""
    SCAN_PLAN_S3_URL=""
    SCAN_PLAN_MODE=""
    SCAN_PLAN_DIGEST=""
    SCAN_PLAN_CANON_VERSION=""

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
            SCAN_PLAN_DIGEST="${TF_PLAN_DIGEST}"
            SCAN_PLAN_CANON_VERSION="${TF_CANON_VERSION}"
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

    # Opt-in: fail the run when a compliance framework declared for this
    # environment was not evaluated. Off by default, matching the CLI — a gap
    # can also mean Iltero has no policy content for that framework yet, and
    # blocking on that would turn our shortfall into the caller's outage. The
    # shortfall is reported either way.
    if [[ "${STRICT_FRAMEWORK_SCOPE:-false}" == "true" ]]; then
        cmd+=(--strict-framework-scope)
    fi

    # Execute scan, keeping a copy of what it said. When no verdict is produced
    # the CLI's own last line is the only thing that names the cause, and a
    # generic "did not complete" in its place sends the reader to re-run a
    # command that will fail identically.
    local cli_log cli_rc_file
    cli_log=$(mktemp)
    cli_rc_file=$(mktemp)
    set +e
    # The command records its own status rather than the shell reading
    # PIPESTATUS afterwards: anything that runs between the pipeline and the
    # read — a debug trap, for one — replaces PIPESTATUS, and the scan's exit
    # code is what decides the verdict. Piping keeps the output live.
    { "${cmd[@]}"; echo $? > "${cli_rc_file}"; } 2>&1 | tee "${cli_log}"
    set -e
    # Fail closed: no recorded status means no verdict, never a pass.
    SCAN_EXIT_CODE=$(cat "${cli_rc_file}" 2>/dev/null)
    [[ "${SCAN_EXIT_CODE}" =~ ^[0-9]+$ ]] || SCAN_EXIT_CODE="${EXIT_ERROR}"
    rm -f "${cli_rc_file}"

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

    # Derive the verdict before rendering anything: the counts are only
    # meaningful once we know a verdict was reached. Printing "Findings: 0
    # total" for a run that never scanned is half of what makes an
    # infrastructure error read as a clean compliance failure — and a failed run
    # can still leave a partially written results file behind, so the file's
    # existence is not the test.
    # Exit 1 means either "findings above threshold" or "could not start", so a
    # usable results file is the tiebreak. It must be readable as JSON, not
    # merely present: a truncated or empty file would otherwise turn a scan that
    # never ran into a waivable verdict reporting zero findings.
    local results_usable="false"
    if [[ -s "${results_file}" ]] && jq -e 'type == "object"' "${results_file}" > /dev/null 2>&1; then
        results_usable="true"
    fi

    if [[ ${SCAN_EXIT_CODE} -eq 0 ]]; then
        SCAN_STATUS="pass"
    elif [[ ${SCAN_EXIT_CODE} -eq 1 ]] && [[ "${results_usable}" == "true" ]]; then
        SCAN_STATUS="violations"
    else
        SCAN_STATUS="infra_error"
    fi

    if [[ "${SCAN_STATUS}" != "infra_error" ]]; then
        log_info "Threshold: ${fail_on}"
        echo ""
        log_info "Findings: ${SCAN_VIOLATIONS} total"
        log_info "  critical  ${critical_count}"
        log_info "  high      ${high_count}"
        log_info "  medium    ${medium_count}"
        log_info "  low       ${low_count}"
        echo ""
    fi

    case "${SCAN_STATUS}" in
        pass)
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
            ;;
        violations)
            log_result "FAIL" "${SCAN_VIOLATIONS} finding(s) at or above '${fail_on}' threshold (${critical_count} critical, ${high_count} high)"
            ;;
        *)
            # Quotes no finding count on purpose: there is no result to count,
            # and a zero here reads as "clean".
            local cli_detail
            cli_detail=$(last_diagnostic_line "${cli_log}")
            log_result "ERROR" "Static analysis produced no compliance verdict for ${unit_name} (exit ${SCAN_EXIT_CODE}) — this is not a clean scan.${cli_detail:+ Reported: ${cli_detail}}"
            ;;
    esac

    rm -f "${cli_log}"
    log_group_end
    return "${SCAN_EXIT_CODE}"
}

# Decide what a non-zero static scan means for the pipeline gate.
# Args: $1=SCAN_STATUS  $2=block_on_violations ("true"|"false")
# Sets: SCAN_GATE_BLOCK  - "true" when the gate must fail
#       SCAN_GATE_REASON - reason recorded against the unit
#
# block_on_violations is a statement about findings: the operator has seen them
# and accepts them. A scan that produced no verdict has no findings to accept,
# so it blocks either way.
apply_static_scan_verdict() {
    local status="${1:-infra_error}"
    local block_on_violations="${2:-true}"

    SCAN_GATE_BLOCK="true"
    case "${status}" in
        violations)
            SCAN_GATE_REASON="static_scan_failed"
            if [[ "${block_on_violations}" != "true" ]]; then
                SCAN_GATE_BLOCK="false"
            fi
            ;;
        *)
            SCAN_GATE_REASON="scan_error"
            ;;
    esac
}
