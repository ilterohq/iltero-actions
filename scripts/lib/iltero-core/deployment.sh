#!/bin/bash
# =============================================================================
# Iltero Core - Deployment
# =============================================================================
# Functions for running Terraform deployments and notifying Iltero API.
#
# Exit Codes:
#   EXIT_SUCCESS (0)    - Deployment completed successfully
#   EXIT_VIOLATIONS (1) - Deployment blocked by policy violations
#   EXIT_ERROR (2)      - Deployment failed (Terraform error, API error, etc.)
#
# Exports after run_deployment():
#   DEPLOY_SUCCESS, RESOURCES_COUNT, OUTPUTS_FILE
# =============================================================================

# Run terraform deployment
# Args: $1=path $2=unit $3=environment $4=run_id (optional) $5=scan_id (optional)
#       $6=stack_id (required when ILTERO_ATTEST=true; used for the deploy-time
#          provenance authorization)
# Sets: DEPLOY_SUCCESS, RESOURCES_COUNT, OUTPUTS_FILE, TERRAFORM_STATE_FILE,
#       PROVENANCE_BOUND (applied the saved evaluated plan)
run_deployment() {
    # Hard assertion: deployment must never run in preview mode
    if [[ "${PREVIEW_MODE:-false}" == "true" ]]; then
        log_error "BUG: run_deployment called in preview mode"
        return "${EXIT_ERROR}"
    fi

    local deploy_path
    deploy_path="$(cd "${1}" && pwd)"
    local unit_name="${2}"
    local environment="${3}"
    local run_id="${4:-}"
    local scan_id="${5:-${ILTERO_SCAN_ID:-}}"
    local stack_id="${6:-}"

    # Reset outputs
    DEPLOY_SUCCESS="false"
    RESOURCES_COUNT="0"
    OUTPUTS_FILE=""
    TERRAFORM_STATE_FILE=""
    PROVENANCE_BOUND="false"

    log_group "Deploy: ${unit_name}"

    pushd "${deploy_path}" > /dev/null

    # Check for environment config
    check_env_config "${deploy_path}" "${environment}"

    # Initialize Terraform with backend
    local init_log
    init_log="$(mktemp)"
    set +e
    if [[ -n "${BACKEND_HCL}" ]]; then
        log_info "Initializing with backend config: ${BACKEND_HCL}"
        terraform init -backend-config="${BACKEND_HCL}" -reconfigure -input=false 2>&1 | tee "${init_log}"
    else
        log_info "Initializing without backend config"
        terraform init -input=false 2>&1 | tee "${init_log}"
    fi
    local init_exit=${PIPESTATUS[0]}
    set -e

    if [[ ${init_exit} -ne 0 ]]; then
        emit_cloud_credentials_hint_if_needed "$(<"${init_log}")"
        rm -f "${init_log}"
        popd > /dev/null
        log_group_end
        log_error "Deployment failed: terraform init error for ${unit_name}"
        return 1
    fi
    rm -f "${init_log}"

    # -------------------------------------------------------------------------
    # Provenance (on by default): apply the EXACT evaluated plan, not a fresh one.
    # -------------------------------------------------------------------------
    # When attestation is enabled we fetch the saved plan binary, recompute its
    # canonical digest, and submit it to the authorization gate (the backend is
    # the authority). We submit whatever digest we recomputed (empty when there
    # is no saved binary) and proceed only on an authorize result:
    #   - authorized + saved binary present -> apply the saved plan (no re-plan)
    #   - authorized + no saved binary       -> re-plan (not provenance-bound)
    #   - denied                             -> fail closed
    local plan_file="${unit_name}.tfplan"
    local using_saved_plan="false"
    local saved_plan="${unit_name}.saved.tfplan"
    local recomputed_digest="" recomputed_canon=""
    if attestation_enabled; then
        extract_s3_backend_config
        if download_plan_binary "${run_id}" "${unit_name}" "${saved_plan}"; then
            local saved_plan_json
            saved_plan_json="$(mktemp)"
            set +e
            terraform show -json "${saved_plan}" > "${saved_plan_json}" 2>/dev/null
            set -e
            compute_plan_digest "${saved_plan_json}"
            rm -f "${saved_plan_json}"
            recomputed_digest="${PLAN_DIGEST}"
            recomputed_canon="${PLAN_CANON_VERSION}"
            if [[ -z "${recomputed_digest}" ]]; then
                # The saved binary is present but could not be digested (e.g.
                # provider/version drift breaking `terraform show`). We cannot
                # prove what we would apply, so fail closed rather than apply an
                # unverified plan or silently re-plan a bound unit.
                rm -f "${saved_plan}"
                popd > /dev/null
                log_group_end
                log_error "Provenance: could not recompute the digest of the saved plan for ${unit_name}; refusing to apply an unverified plan"
                return 1
            fi
            using_saved_plan="true"
            plan_file="${saved_plan}"
        else
            # Could be a genuinely unbound unit (no object) or an access/region
            # error; the reason is surfaced so a misconfig is not mistaken for
            # "unbound". Either way we submit the (empty) digest and the backend,
            # which knows whether the unit is bound, makes the call.
            log_info "Provenance: no saved plan fetched for ${unit_name} (${DOWNLOAD_STDERR:-not found}); treating as not provenance-bound, re-planning"
        fi

        set +e
        verify_authorization "${run_id}" "${stack_id}" "${environment}" "${unit_name}" "${recomputed_digest}" "${recomputed_canon}"
        local digest_auth_exit=$?
        set -e
        if [[ ${digest_auth_exit} -ne 0 ]]; then
            rm -f "${saved_plan}"
            popd > /dev/null
            log_group_end
            log_error "Deployment blocked: plan provenance verification failed for ${unit_name}"
            return 1
        fi
    fi

    # Create plan (skipped when applying a saved, provenance-bound plan)
    if [[ "${using_saved_plan}" == "true" ]]; then
        log_info "Provenance: applying the saved evaluated plan for ${unit_name} (no re-plan)"
    elif [[ -n "${TFVARS_FILE}" ]]; then
        terraform plan -var-file="${TFVARS_FILE}" -out="${plan_file}" -input=false
    else
        terraform plan -out="${plan_file}" -input=false
    fi

    # Apply with -json so the CLI can derive the per-resource apply breakdown from
    # the ACTUAL outcome (including partial failures: resources applied before an
    # error, the failing resource, and its diagnostic). The NDJSON stream is tee'd
    # to the console for visibility and captured for `iltero scan apply --apply-json`.
    # stderr is NOT merged in, so it cannot corrupt the NDJSON the CLI parses.
    local apply_json apply_err
    apply_json="$(mktemp)"
    apply_err="$(mktemp)"
    set +e
    terraform apply -json -auto-approve "${plan_file}" 2>"${apply_err}" | tee "${apply_json}"
    local apply_exit=${PIPESTATUS[0]}
    set -e

    # stderr is captured to a sidecar (not merged into the NDJSON, which must stay
    # parseable) and surfaced to the operator console — pre-view errors / plugin
    # panics bypass the JSON view and would otherwise be lost.
    if [[ -s "${apply_err}" ]]; then
        cat "${apply_err}" >&2
    fi

    if [[ ${apply_exit} -ne 0 ]]; then
        # Credential errors surface as NDJSON diagnostics in -json mode; feed stderr
        # too so a pre-view credential failure still triggers the hint.
        emit_cloud_credentials_hint_if_needed "$(<"${apply_json}")"$'\n'"$(<"${apply_err}")"
    fi

    if [[ ${apply_exit} -eq 0 ]]; then
        DEPLOY_SUCCESS="true"

        # Export outputs
        OUTPUTS_FILE="/tmp/${unit_name}_outputs.json"
        terraform output -json > "${OUTPUTS_FILE}"

        # Resource count — human log + GitHub Action output only (not the audit
        # breakdown, which the CLI derives per-resource from the apply-json above).
        RESOURCES_COUNT=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')

        # Export terraform state JSON after apply (for audit trail and drift baseline)
        TERRAFORM_STATE_FILE="/tmp/${unit_name}_state.json"
        set +e
        terraform show -json > "${TERRAFORM_STATE_FILE}" 2>/dev/null
        local state_export_exit=$?
        set -e

        if [[ ${state_export_exit} -ne 0 ]] || [[ ! -s "${TERRAFORM_STATE_FILE}" ]]; then
            log_warning "Could not export terraform state JSON after apply"
            TERRAFORM_STATE_FILE=""
        else
            log_info "Exported terraform state to: ${TERRAFORM_STATE_FILE}"
        fi

        # A unit is provenance-bound when it applied the saved evaluated plan
        # (no re-plan). The plan-to-apply binding is enforced by the deploy-time
        # digest comparison at the authorization gate above.
        PROVENANCE_BOUND="${using_saved_plan}"

        # Notify API with the apply-json breakdown + post-apply state.
        notify_apply_result "${run_id}" "${scan_id}" "${unit_name}" "${environment}" "true" "${apply_json}" "${TERRAFORM_STATE_FILE}"

        log_success "Deployment complete: ${RESOURCES_COUNT} resources"
    else
        # Notify API of failure WITH the apply-json so the partial breakdown
        # (resources applied before the error + the failing resource) is recorded.
        notify_apply_result "${run_id}" "${scan_id}" "${unit_name}" "${environment}" "false" "${apply_json}" ""

        log_error "Deployment failed for ${unit_name}"
    fi
    rm -f "${apply_json}" "${apply_err}"

    # A fetched saved plan binary can contain rendered secret values; remove it
    # so it does not linger on a reused (self-hosted) runner. Re-fetched on retry.
    rm -f "${saved_plan}"

    popd > /dev/null
    log_group_end

    [[ "${DEPLOY_SUCCESS}" == "true" ]] && return 0 || return 1
}

# Notify Iltero API of apply result
# Args: $1=run_id $2=scan_id $3=unit $4=environment $5=success $6=apply_json_file
#       $7=terraform_state_file
# The CLI derives the applied-resource breakdown (created/updated/deleted/failed +
# per-resource success/errors) from the `terraform apply -json` NDJSON stream — the
# actual outcome, so partial failures are recorded on the failure path too.
notify_apply_result() {
    local run_id="$1"
    local scan_id="$2"
    local unit_name="$3"
    local environment="$4"
    local success="$5"
    local apply_json_file="$6"
    local terraform_state_file="${7:-}"

    if [[ -z "${run_id}" ]]; then
        log_debug "No run ID, skipping API notification"
        return 0
    fi

    if [[ -z "${scan_id}" ]]; then
        log_warning "No scan ID provided, API notification may fail (scan_id is required)"
    fi

    local cmd=(
        iltero scan apply
        --run-id "${run_id}"
        --unit "${unit_name}"
        --environment "${environment}"
        --output json
    )

    # Add required scan_id parameter
    if [[ -n "${scan_id}" ]]; then
        cmd+=(--scan-id "${scan_id}")
    fi

    # apply -json NDJSON stream — the CLI derives the counts + per-resource results
    # (incl. failures) from it. Present on both success and failure paths.
    if [[ -n "${apply_json_file}" ]] && [[ -f "${apply_json_file}" ]]; then
        cmd+=(--apply-json "${apply_json_file}")
    fi

    # Provide terraform state JSON for audit trail (from 'terraform show -json')
    if [[ -n "${terraform_state_file}" ]] && [[ -f "${terraform_state_file}" ]]; then
        cmd+=(--terraform-state-json "${terraform_state_file}")
        log_info "Including terraform state JSON in apply notification"
    fi

    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        cmd+=(--external-run-id "${GITHUB_RUN_ID}")
        cmd+=(--external-run-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}")
    fi

    if [[ "${success}" == "true" ]]; then
        cmd+=(--success)
    else
        cmd+=(--failed)
    fi

    set +e
    "${cmd[@]}" || log_warning "Failed to notify API of deployment"
    set -e
}
