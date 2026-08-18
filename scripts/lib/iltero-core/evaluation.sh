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
#   4. Credential-less preview (PREVIEW_MODE + no creds) → init with a
#      local-backend override and a mock-credential plan; advisory only, never
#      provenance-bound. See prepare_terraform_plan in terraform.sh.
#   5. Update the unit's remote state status for downstream dependencies.
#   6. Always run plan and evaluate (never skip the unit entirely).
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Evaluation passed, no violations above threshold
#   EXIT_VIOLATIONS (1) - Evaluation found violations above fail_on threshold
#   EXIT_ERROR (2)      - Evaluation failed (Terraform error, API error, etc.)
#
# Exports after run_plan_evaluation():
#   EVAL_RUN_ID, EVAL_SCAN_ID, EVAL_PASSED, EVAL_STATUS, EVAL_VIOLATIONS,
#   EVAL_EXIT_CODE, APPROVAL_ID, PLAN_JSON_FILE, PLAN_URL, EVAL_MODE,
#   EVAL_PLAN_DIGEST, EVAL_CANON_VERSION  (provenance; "" when disabled)
#
# EVAL_STATUS values (derived from the evaluator's exit code + confirmed-check
# count; see the CLI->runner contract):
#   "pass"         - Evaluated >=1 check, none failing above threshold (exit 0)
#   "violations"   - OPA policy and/or native check{} failures (exit 1, count>0);
#                    waivable via block_on_violations
#   "needs_review" - Nothing confirmable: resource-less+check-less plan, all-
#                    unknown checks (exit 1, count 0), or exit 0 with no results
#                    — never treated as a pass, always blocks
#   "infra_error"  - no verdict: a scanner, config, input or terraform error,
#                    or any exit code this contract does not name
#
# EVAL_MODE values:
#   "full"        - Full evaluation with backend (remote state available)
#   "best_effort" - Evaluation with the real backend but remote state deps
#                   disabled (upstream state unavailable)
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
    # EVAL_STATUS: pass | violations | needs_review | infra_error. A superset of
    # EVAL_PASSED (pass <=> EVAL_PASSED=true) that lets the pipeline distinguish
    # "nothing to evaluate" (needs_review) from policy violations or infra errors.
    # Defaults to infra_error so any early return that doesn't set it fails closed
    # as an error rather than as a pass.
    EVAL_STATUS="infra_error"
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
            # Terraform could not produce a plan, so nothing was evaluated.
            log_result "ERROR" "Plan evaluation aborted: ${failure_step} failed for ${unit_name}. No compliance verdict was produced."
            log_group_end
            EVAL_EXIT_CODE=2
            EVAL_PASSED="false"
            EVAL_STATUS="infra_error"
            return 1
        fi

        PLAN_JSON_FILE="${TF_PLAN_JSON_FILE}"
        EVAL_MODE="${TF_PLAN_MODE}"
        plan_s3_url="${TF_PLAN_S3_URL}"
        state_json_file="${TF_STATE_JSON_FILE}"
        plan_digest="${TF_PLAN_DIGEST}"
        canon_version="${TF_CANON_VERSION}"
    fi

    # =====================================================================
    # Nothing-to-evaluate gate
    # =====================================================================
    # The evaluator scores resource changes and native check{} blocks. A plan
    # that carries NEITHER has nothing to evaluate: mark it needs-review (never a
    # pass) and short-circuit BEFORE the evaluator so no result is recorded. A
    # resource-less plan that DOES carry check{} blocks still flows to the
    # evaluator, which scores those controls. Compute from the plan JSON directly
    # so both the generated- and existing-plan paths are covered.
    local eval_has_resources="true"
    local eval_has_checks="false"
    if [[ -n "${PLAN_JSON_FILE}" ]] && [[ -f "${PLAN_JSON_FILE}" ]]; then
        plan_has_resources "${PLAN_JSON_FILE}" || eval_has_resources="false"
        plan_has_checks "${PLAN_JSON_FILE}" && eval_has_checks="true"
    fi

    if [[ "${eval_has_resources}" == "false" ]] && [[ "${eval_has_checks}" == "false" ]]; then
        EVAL_STATUS="needs_review"
        EVAL_PASSED="false"
        EVAL_VIOLATIONS="0"
        EVAL_EXIT_CODE=2
        log_result "NEEDS_REVIEW" "Unit '${unit_name}' plans no resource changes and defines no checks — nothing to evaluate. If this unit should create infrastructure, enable or add resources (e.g. set the relevant enable_* flags and inputs), then re-run. Marked needs-review, not passed."
        log_group_end
        return "${EVAL_EXIT_CODE}"
    fi

    if [[ "${eval_has_resources}" == "false" ]]; then
        log_info "Unit '${unit_name}' plans no resource changes; evaluating its control check(s)"
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
    "${ILTERO_CLI_BIN:-iltero}" scan generate-source-map --path "${eval_path}" --output "${source_map_file}"
    local source_map_exit=$?
    set -e

    if [[ ${source_map_exit} -ne 0 ]] || [[ ! -f "${source_map_file}" ]]; then
        log_warning "Source map generation failed (violations will use 'plan.json')"
        source_map_file=""
    fi

    # Run evaluation
    local cmd=(
        "${ILTERO_CLI_BIN:-iltero}" scan evaluation "${PLAN_JSON_FILE}"
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

    # Opt-in: fail the run when a compliance framework declared for this
    # environment was not evaluated. Off by default, matching the CLI — a gap
    # can also mean Iltero has no policy content for that framework yet, and
    # blocking on that would turn our shortfall into the caller's outage. The
    # shortfall is reported either way.
    if [[ "${STRICT_FRAMEWORK_SCOPE:-false}" == "true" ]]; then
        cmd+=(--strict-framework-scope)
    fi

    log_info "Running: ${cmd[*]}"
    # Keep a copy of what it said: when no verdict is produced the evaluator's
    # own last line is the only thing that names the cause.
    local cli_log cli_rc_file
    cli_log=$(mktemp)
    cli_rc_file=$(mktemp)
    set +e
    # The command records its own status rather than the shell reading
    # PIPESTATUS afterwards: anything that runs between the pipeline and the
    # read — a debug trap, for one — replaces PIPESTATUS, and the evaluator's
    # exit code is what decides the verdict. Piping keeps the output live.
    { "${cmd[@]}"; echo $? > "${cli_rc_file}"; } 2>&1 | tee "${cli_log}"
    set -e
    # Fail closed: no recorded status means no verdict, never a pass.
    EVAL_EXIT_CODE=$(cat "${cli_rc_file}" 2>/dev/null)
    [[ "${EVAL_EXIT_CODE}" =~ ^[0-9]+$ ]] || EVAL_EXIT_CODE="${EXIT_ERROR}"
    rm -f "${cli_rc_file}"

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
        # The evaluator reports the count of evaluated checks (OPA policies over
        # resources + native check{} blocks) as summary.total_checks.
        total_evaluated=$(jq -r '.summary.total_checks // 0' "${results_file}" 2>/dev/null || echo "0")
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

    # Derive the verdict from the evaluator's exit code and the confirmed-check
    # count (summary.total_checks counts only pass/fail; unknown is excluded),
    # per the CLI->runner contract:
    #   exit 0                  -> evaluated and passed (CLI invariant: total>0)
    #   exit 1 and total == 0   -> nothing confirmable (incl. all-unknown checks)
    #                              -> needs_review (never a pass, not an error)
    #   exit 1                  -> OPA and/or native check{} failure(s) -> waivable
    #   any other code          -> no verdict was produced -> infra_error.
#                              Deliberately open-ended: a code this contract
#                              does not name must block here without an edit.
    local evaluated_total="${total_evaluated:-0}"
    local native_failed
    native_failed=$(jq -r '[.native_checks[]? | select(.status == "fail")] | length' "${results_file}" 2>/dev/null || echo "0")

    if [[ ${EVAL_EXIT_CODE} -eq 0 ]] && [[ -f "${results_file}" ]] && [[ "${evaluated_total}" -gt 0 ]]; then
        EVAL_PASSED="true"
        EVAL_STATUS="pass"
        if [[ "${EVAL_MODE}" == "best_effort" ]]; then
            log_result "PASS" "Plan evaluation passed (best-effort mode, ${EVAL_VIOLATIONS} violations)"
        else
            log_result "PASS" "Plan evaluation passed (${EVAL_VIOLATIONS} policy violations)"
        fi
    elif [[ ${EVAL_EXIT_CODE} -eq 0 ]]; then
        # exit 0 but no results file / nothing evaluated — belt-and-suspenders
        # (the CLI's invariant is that exit 0 implies total_checks > 0).
        EVAL_PASSED="false"
        EVAL_STATUS="needs_review"
        EVAL_EXIT_CODE=2
        log_result "NEEDS_REVIEW" "Evaluation exited 0 but nothing was evaluated for ${unit_name} (no results or empty policy set); marked needs-review, not passed."
    elif [[ ${EVAL_EXIT_CODE} -eq 1 ]] && [[ "${evaluated_total}" -eq 0 ]]; then
        # Compliance verdict, not an error: nothing could be confirmed at plan
        # time (e.g. every native check is unknown until apply).
        EVAL_PASSED="false"
        EVAL_STATUS="needs_review"
        log_result "NEEDS_REVIEW" "Nothing could be evaluated for ${unit_name} (no confirmable policy or check result); marked needs-review, not passed."
    elif [[ ${EVAL_EXIT_CODE} -eq 1 ]]; then
        # Compliance failure: OPA policy violations and/or native check failures.
        EVAL_PASSED="false"
        EVAL_STATUS="violations"
        EVAL_VIOLATIONS=$((EVAL_VIOLATIONS + native_failed))
        log_result "FAIL" "${EVAL_VIOLATIONS} violation(s) at or above '${fail_on}' threshold (incl. ${native_failed} failing control check(s))"
    else
        # Any other code — no compliance verdict was produced.
        EVAL_PASSED="false"
        EVAL_STATUS="infra_error"
        local cli_detail
        cli_detail=$(last_diagnostic_line "${cli_log}")
        log_result "ERROR" "Plan evaluation produced no compliance verdict for ${unit_name} (exit ${EVAL_EXIT_CODE}) — this is not a clean evaluation.${cli_detail:+ Reported: ${cli_detail}}"
    fi

    if [[ -n "${APPROVAL_ID}" ]]; then
        log_info "Approval ID: ${APPROVAL_ID}"
    fi

    log_group_end
    rm -f "${cli_log}"
    return "${EVAL_EXIT_CODE}"
}
