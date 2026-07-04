#!/bin/bash
# =============================================================================
# Iltero Core - Terraform Plan Preparation
# =============================================================================
# Shared terraform init + plan flow used by both static scanning (when a
# plan is available) and policy evaluation. Handles the dependency
# best-effort fallback, S3 backend extraction, plan-JSON conversion, plan
# upload, and pre-plan state export.
#
# Exit Codes:
#   0 - Success; TF_PLAN_JSON_FILE is set
#   1 - terraform init failed
#   2 - terraform plan failed
#
# Module-level outputs after prepare_terraform_plan():
#   TF_PLAN_JSON_FILE        Absolute path to the plan JSON file
#   TF_STATE_JSON_FILE       Absolute path to the pre-plan state JSON, or ""
#   TF_PLAN_MODE             "full" | "best_effort"
#   TF_PLAN_S3_URL           s3:// URL of the uploaded plan, or ""
#   TF_BACKEND_S3_BUCKET     Bucket name when the unit uses an S3 backend
#   TF_BACKEND_S3_KEY_PREFIX Key prefix derived from the backend key
#   TF_BACKEND_S3_REGION     Backend region
#   TF_PLAN_DIGEST           Canonical plan digest (provenance), or "" when
#                            attestation is disabled / unavailable / unbound
#   TF_CANON_VERSION         Canonicalization spec version, or ""
#   TF_PLAN_BINARY_URL       s3:// URL of the persisted plan binary, or "".
#                            Non-empty only when the unit is provenance-bound.
# =============================================================================

if [[ -n "${ILTERO_TERRAFORM_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ILTERO_TERRAFORM_SOURCED=1

TF_PLAN_JSON_FILE=""
TF_STATE_JSON_FILE=""
TF_PLAN_MODE="full"
TF_PLAN_S3_URL=""
TF_BACKEND_S3_BUCKET=""
TF_BACKEND_S3_KEY_PREFIX=""
TF_BACKEND_S3_REGION=""
TF_PLAN_DIGEST=""
TF_CANON_VERSION=""
TF_PLAN_BINARY_URL=""

# Set by configure_preview_credentials(). PREVIEW_SUPPORTED is true only when
# every provider the unit declares has an adapter.
PREVIEW_SUPPORTED="false"
PREVIEW_OVERRIDE_FILE=""
PREVIEW_CRED_ENV=()
PREVIEW_PLAN_VARS=()

# cloud_credentials_present
# Returns 0 if any supported cloud has credentials present in the
# environment, 1 otherwise. Used to decide whether a terraform init+plan
# attempt has a realistic chance of succeeding (plan-mode) versus skipping
# straight to source-mode.
#
# Each entry is the env var the cloud's official auth Action exports after
# successful authentication. Add new providers here as adapters land —
# this is the single decision point so consumers stay cloud-agnostic. The
# list is function-local because bash arrays do not propagate to subshells
# (which `bats run` and similar test harnesses use).
#
#   AWS_ACCESS_KEY_ID            — aws-actions/configure-aws-credentials
#   GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_GHA_CREDS_PATH
#                                — google-github-actions/auth
#   AZURE_CLIENT_ID              — azure/login
cloud_credentials_present() {
    local var
    local cred_env_vars=(
        AWS_ACCESS_KEY_ID
        GOOGLE_APPLICATION_CREDENTIALS
        GOOGLE_GHA_CREDS_PATH
        AZURE_CLIENT_ID
    )
    for var in "${cred_env_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            return 0
        fi
    done
    return 1
}

# detect_terraform_providers
# Echoes the distinct provider names a unit declares (one per line) from its
# *.tf files. Cloud-neutral; the adapters below decide what to do per provider.
# Args: $1 = unit directory
detect_terraform_providers() {
    local dir="$1"
    grep -rhoE '^[[:space:]]*provider[[:space:]]+"[a-z0-9]+"' "${dir}"/*.tf 2>/dev/null \
        | grep -oE '"[a-z0-9]+"' | tr -d '"' | sort -u
}

# configure_preview_credentials
# Cloud-agnostic dispatch for planning a unit with NO cloud credentials (PR
# preview). Per declared provider, an adapter appends its credential-skip block
# to a runner-owned override, adds mock cred env, and neutralizes role
# assumption via an empty assume_role block. Add a cloud by adding a case arm.
# The override is prefixed to sort after a unit's own *_override.tf files.
# PREVIEW_SUPPORTED is true only if every declared provider has an adapter (else
# preview fails).
# Args: $1 = unit directory
# Sets: PREVIEW_SUPPORTED, PREVIEW_OVERRIDE_FILE, PREVIEW_CRED_ENV, PREVIEW_PLAN_VARS
configure_preview_credentials() {
    local dir="$1"
    PREVIEW_SUPPORTED="false"
    PREVIEW_OVERRIDE_FILE=""
    PREVIEW_CRED_ENV=()
    PREVIEW_PLAN_VARS=()

    local providers
    providers=$(detect_terraform_providers "${dir}")
    if [[ -z "${providers}" ]]; then
        log_warning "Credential-less preview: no provider block found in ${dir}"
        return 0
    fi

    local override="${dir}/zzz_iltero_preview_override.tf"
    : > "${override}"

    # Replace the unit's real backend (e.g. s3) with a local backend so
    # `terraform init` needs no cloud credentials and plan runs against empty
    # state. An override-file backend block always supersedes the base backend
    # block (and may change its type); terraform-block settings otherwise merge
    # individually, so required_version/required_providers are preserved.
    cat >> "${override}" <<'BACKEND_PREVIEW_OVERRIDE'
terraform {
  backend "local" {}
}
BACKEND_PREVIEW_OVERRIDE

    local provider unadapted=""
    while IFS= read -r provider; do
        [[ -z "${provider}" ]] && continue
        case "${provider}" in
            aws)
                # Skips + mock static creds + IMDS off + -refresh=false + an
                # empty assume_role{} (an override nested block replaces the
                # unit's own assume_role, so no role is assumed) => plan with no
                # STS/IMDS call. The empty block is a no-op for units that
                # declare no assume_role.
                cat >> "${override}" <<'AWS_PREVIEW_OVERRIDE'
provider "aws" {
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  assume_role {}
}
AWS_PREVIEW_OVERRIDE
                PREVIEW_CRED_ENV+=(
                    AWS_ACCESS_KEY_ID=iltero-preview-mock
                    AWS_SECRET_ACCESS_KEY=iltero-preview-mock
                    AWS_EC2_METADATA_DISABLED=true
                    AWS_REGION="${AWS_REGION:-us-east-1}"
                )
                PREVIEW_PLAN_VARS+=(-var="assume_role_arn=")
                ;;
            *)
                # No adapter for this cloud yet -> preview fails for the unit.
                unadapted="${unadapted:+${unadapted}, }${provider}"
                ;;
        esac
    done <<< "${providers}"

    if [[ -n "${unadapted}" ]]; then
        log_warning "Credential-less preview: no adapter yet for provider(s): ${unadapted}"
        rm -f "${override}"
        return 0
    fi

    PREVIEW_OVERRIDE_FILE="${override}"
    PREVIEW_SUPPORTED="true"
    return 0
}

# extract_s3_backend_config
# Reads the S3 backend bucket/region/key-prefix from terraform's local state
# (written by `terraform init`) into the TF_BACKEND_S3_* module vars. Safe to
# call from any directory that has been `terraform init`-ed; leaves the vars
# empty for non-S3 backends. Shared by prepare_terraform_plan (evaluate) and the
# deploy job so both derive the same plan-binary key.
extract_s3_backend_config() {
    TF_BACKEND_S3_BUCKET=""
    TF_BACKEND_S3_REGION=""
    TF_BACKEND_S3_KEY_PREFIX=""
    local tf_backend_state=".terraform/terraform.tfstate"
    [[ -f "${tf_backend_state}" ]] || return 0

    local backend_type
    backend_type=$(jq -r '.backend.type // empty' "${tf_backend_state}" 2>/dev/null || echo "")
    if [[ "${backend_type}" == "s3" ]]; then
        TF_BACKEND_S3_BUCKET=$(jq -r '.backend.config.bucket // empty' "${tf_backend_state}")
        TF_BACKEND_S3_REGION=$(jq -r '.backend.config.region // empty' "${tf_backend_state}")
        local s3_key
        s3_key=$(jq -r '.backend.config.key // empty' "${tf_backend_state}")
        TF_BACKEND_S3_KEY_PREFIX="${s3_key%/*}"
    fi
    return 0
}

# download_plan_binary
# Fetches the saved plan binary persisted by upload_plan_binary for this
# (run_id, unit) into the given local path. The key is reconstructed
# deterministically from the TF_BACKEND_S3_* config (which the caller must have
# populated via extract_s3_backend_config after `terraform init`).
#
# Returns 0 on success; non-zero on any unmet precondition or download error
# (e.g. the object does not exist because the unit was never bound). On a
# download error DOWNLOAD_STDERR holds a short tail of aws's stderr so the
# caller can tell a genuinely-unbound unit (NoSuchKey) from a misconfig
# (AccessDenied / wrong region). The caller decides what a failure means
# (unbound -> re-plan; bound -> the backend authorization, not this function,
# fails the deploy closed).
#
# NOTE: region is REQUIRED here (no us-east-1 default, unlike the plan-JSON
# upload). The bound artifact's key must resolve to the exact region it was
# written to; do not add a default that could bind to a guessed region.
#
# Args: $1 = run_id   $2 = unit_name   $3 = dest_path
# Sets: DOWNLOAD_STDERR (on failure)
download_plan_binary() {
    local run_id="${1:-}"
    local unit_name="${2:-}"
    local dest="${3:-}"
    DOWNLOAD_STDERR=""

    if [[ -z "${TF_BACKEND_S3_BUCKET}" || -z "${TF_BACKEND_S3_KEY_PREFIX}" \
          || -z "${TF_BACKEND_S3_REGION}" || -z "${run_id}" || -z "${dest}" ]]; then
        DOWNLOAD_STDERR="missing S3 backend config or run_id"
        return 1
    fi

    local key="${TF_BACKEND_S3_KEY_PREFIX}/plans/${run_id}/${unit_name}.tfplan"
    local url="s3://${TF_BACKEND_S3_BUCKET}/${key}"
    log_info "Provenance: fetching saved plan binary from ${url}"

    local err_file
    err_file="$(mktemp)"
    set +e
    aws s3 cp "${url}" "${dest}" --region "${TF_BACKEND_S3_REGION}" > /dev/null 2>"${err_file}"
    local rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
        DOWNLOAD_STDERR="$(tail -c 300 "${err_file}" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "${err_file}"
    return "${rc}"
}

# s3_cp_with_sse
# Single home for `aws s3 cp` with optional server-side encryption, so the SSE
# behaviour cannot drift between the plan-JSON and plan-binary upload paths.
# Returns aws's own exit code. On failure, S3_CP_STDERR holds a short tail of
# aws's stderr (e.g. AccessDenied / NoSuchBucket) for the caller to log; stdout
# is discarded. aws stderr is error text only, never plan contents.
#
# Args: $1 = src   $2 = dest (s3:// URL)   $3 = region
# Sets: S3_CP_STDERR
s3_cp_with_sse() {
    local src="$1"
    local dest="$2"
    local region="$3"
    S3_CP_STDERR=""

    local cmd=(aws s3 cp "${src}" "${dest}" --region "${region}")
    if [[ -n "${ILTERO_S3_SSE:-}" ]]; then
        cmd+=(--sse "${ILTERO_S3_SSE}")
    fi

    local err_file
    err_file="$(mktemp)"
    set +e
    "${cmd[@]}" > /dev/null 2>"${err_file}"
    local rc=$?
    set -e
    if [[ ${rc} -ne 0 ]]; then
        S3_CP_STDERR="$(tail -c 300 "${err_file}" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "${err_file}"
    return "${rc}"
}

# upload_plan_binary
# Persists the appliable plan binary (tfplan, in the current directory) to the
# unit's S3 backend bucket under a deterministic (run_id, unit)-keyed path, so
# the deploy job can reconstruct the key and apply the exact evaluated plan.
# Server-side encryption follows ILTERO_S3_SSE when set, else S3's default.
#
# Returns 0 and sets PLAN_BINARY_URL on success; non-zero (with PLAN_BINARY_URL
# empty) on any unmet precondition or upload error. The caller treats a failure
# as "unit not bound", never a hard error.
#
# Args: $1 = run_id   $2 = unit_name
# Sets: PLAN_BINARY_URL
upload_plan_binary() {
    local run_id="${1:-}"
    local unit_name="${2:-}"
    PLAN_BINARY_URL=""

    if [[ -z "${TF_BACKEND_S3_BUCKET}" || -z "${TF_BACKEND_S3_KEY_PREFIX}" ]]; then
        log_warning "Provenance: ${unit_name} has no S3 backend; cannot persist plan binary"
        return 1
    fi
    if [[ -z "${run_id}" ]]; then
        log_warning "Provenance: no run_id; cannot key the plan binary deterministically"
        return 1
    fi
    if [[ -z "${TF_BACKEND_S3_REGION}" ]]; then
        log_warning "Provenance: no backend region; cannot persist plan binary"
        return 1
    fi
    if [[ ! -f "tfplan" ]]; then
        log_warning "Provenance: plan binary (tfplan) missing; cannot persist"
        return 1
    fi

    local key="${TF_BACKEND_S3_KEY_PREFIX}/plans/${run_id}/${unit_name}.tfplan"
    local url="s3://${TF_BACKEND_S3_BUCKET}/${key}"
    log_info "Provenance: uploading plan binary to ${url}"

    if s3_cp_with_sse "tfplan" "${url}" "${TF_BACKEND_S3_REGION}"; then
        PLAN_BINARY_URL="${url}"
        return 0
    fi
    log_warning "Provenance: failed to upload plan binary for ${unit_name}: ${S3_CP_STDERR:-no error output}"
    return 1
}

# prepare_terraform_plan
# Args:
#   $1 = eval_path     absolute path to the unit directory
#   $2 = unit_name     unit name for state tracking and log lines
#   $3 = environment   environment slug
#   $4 = depends_on    comma-separated dependency unit names (optional)
#   $5 = chain_run_id  run id used for the plan S3 key (optional)
# Returns: 0 success, 1 init failed, 2 plan failed
prepare_terraform_plan() {
    local eval_path="$1"
    local unit_name="$2"
    local environment="$3"
    local depends_on="${4:-}"
    local chain_run_id="${5:-}"

    TF_PLAN_JSON_FILE=""
    TF_STATE_JSON_FILE=""
    TF_PLAN_MODE="full"
    TF_PLAN_S3_URL=""
    TF_BACKEND_S3_BUCKET=""
    TF_BACKEND_S3_KEY_PREFIX=""
    TF_BACKEND_S3_REGION=""
    TF_PLAN_DIGEST=""
    TF_CANON_VERSION=""
    TF_PLAN_BINARY_URL=""

    if [[ -z "${eval_path}" || ! -d "${eval_path}" ]]; then
        log_error "prepare_terraform_plan: invalid eval_path '${eval_path}'"
        return 1
    fi

    # Credential-less preview: no-creds PR preview runs a real plan (so OPA sees
    # plan JSON) with a local-backend override in place of the real backend.
    # Gated on PREVIEW_MODE (deploy path untouched)
    # AND creds-absent (a same-repo preview with OIDC creds keeps the real
    # backend; the PREVIEW_MODE evidence guards keep it out of the chain).
    # Evaluate once, before any env is mocked (cloud_credentials_present keys on
    # AWS_ACCESS_KEY_ID).
    local credentialless=false
    if [[ "${PREVIEW_MODE:-false}" == "true" ]] && ! cloud_credentials_present; then
        credentialless=true
    fi

    # Mock creds are applied inline per terraform call (below), NEVER exported —
    # an export would flip cloud_credentials_present for the next unit. Empty on
    # the normal path. Populated by configure_preview_credentials.
    local tf_env=()
    local preview_override=""
    local preview_plan_vars=()

    pushd "${eval_path}" > /dev/null

    # Cloud-agnostic — see configure_preview_credentials. The override is removed
    # at every return below (explicit rm, not a RETURN trap, which fires on nested
    # returns under functrace).
    if [[ "${credentialless}" == "true" ]]; then
        configure_preview_credentials "${eval_path}"
        if [[ "${PREVIEW_SUPPORTED}" == "true" ]]; then
            preview_override="${PREVIEW_OVERRIDE_FILE}"
            tf_env=(env ${PREVIEW_CRED_ENV[@]+"${PREVIEW_CRED_ENV[@]}"})
            preview_plan_vars=(${PREVIEW_PLAN_VARS[@]+"${PREVIEW_PLAN_VARS[@]}"})
            log_info "Credential-less preview: ${preview_override##*/} written for detected provider(s)"
        else
            # No adapter for this unit's cloud: cannot plan credential-less.
            log_error "Credential-less preview unsupported for ${unit_name} (no adapter for its provider)"
            popd > /dev/null
            return 2
        fi
    fi

    # -------------------------------------------------------------------------
    # Step 1: Dependency remote-state availability check
    # -------------------------------------------------------------------------
    local dep_state_status
    dep_state_status=$(check_dependency_remote_state "${depends_on}")
    log_info "Dependency remote state check: ${dep_state_status}"

    if [[ "${dep_state_status}" == "unavailable" ]]; then
        if [[ -n "${DEP_CHECK_DETAILS:-}" ]]; then
            log_warning "Dependencies missing remote state: ${DEP_CHECK_DETAILS}"
        fi
        log_info "Will disable remote state dependencies in plan"
        TF_PLAN_MODE="best_effort"
    fi

    # Distinct label: separates "no creds (preview)" from best_effort in EVAL_MODE,
    # and the full-only digest gate below skips it (never the deployable plan).
    if [[ "${credentialless}" == "true" ]]; then
        TF_PLAN_MODE="preview"
    fi

    # -------------------------------------------------------------------------
    # Step 2: terraform init
    # -------------------------------------------------------------------------
    log_info "Working directory: $(pwd)"
    check_env_config "${eval_path}" "${environment}"
    log_info "Resolved: BACKEND_HCL=${BACKEND_HCL:-<empty>} TFVARS_FILE=${TFVARS_FILE:-<empty>}"

    local init_args=(-input=false)
    # Credential-less preview substitutes a local backend via the preview
    # override (see configure_preview_credentials), so init needs no backend
    # config and no credentials. Normal path keeps the unit's real s3 backend.
    if [[ "${credentialless}" != "true" ]] && [[ -n "${BACKEND_HCL}" ]]; then
        init_args+=(-backend-config="${BACKEND_HCL}")
    fi

    log_info "Running: terraform init ${init_args[*]}"
    local init_output
    set +e
    init_output=$(${tf_env[@]+"${tf_env[@]}"} terraform init "${init_args[@]}" 2>&1)
    local init_exit=$?
    set -e

    if [[ ${init_exit} -ne 0 ]]; then
        log_step "terraform init" "FAILED"
        echo ""
        echo "${init_output}" | grep -A 5 "Error:" | head -30 || echo "${init_output}" | tail -20
        emit_cloud_credentials_hint_if_needed "${init_output}"
        update_unit_remote_state_status "${unit_name}" "unavailable" "init_failed"
        [[ -n "${preview_override}" ]] && rm -f "${preview_override}"
        popd > /dev/null
        return 1
    fi

    log_step "terraform init" "ok"

    # -------------------------------------------------------------------------
    # Step 2.5: Extract S3 backend config from terraform's local state
    # -------------------------------------------------------------------------
    extract_s3_backend_config

    # -------------------------------------------------------------------------
    # Step 2.6: Inspect existing backend state for this unit
    # -------------------------------------------------------------------------
    local has_backend_state=false
    set +e
    local state_output
    state_output=$(${tf_env[@]+"${tf_env[@]}"} terraform state list 2>&1)
    local state_exit=$?
    set -e

    if [[ ${state_exit} -eq 0 ]] && [[ -n "${state_output}" ]]; then
        has_backend_state=true
        log_info "Unit has existing backend state ($(echo "${state_output}" | wc -l | tr -d ' ') resources)"
        update_unit_remote_state_status "${unit_name}" "available" "has_backend_state"
    else
        log_info "Unit has no backend state yet (not deployed)"
        update_unit_remote_state_status "${unit_name}" "unavailable" "no_backend_state"
    fi

    # -------------------------------------------------------------------------
    # Step 3: terraform plan
    # -------------------------------------------------------------------------
    local plan_args=(-out=tfplan -input=false)
    if [[ "${TF_PLAN_MODE}" == "best_effort" || "${credentialless}" == "true" ]]; then
        plan_args+=(-var="enable_remote_state_dependencies=false")
        log_info "Disabling remote state dependencies (deps not yet deployed or credential-less preview)"
    fi
    if [[ "${credentialless}" == "true" ]]; then
        # -refresh=false so no data source hits a live API; provider vars drop
        # role assumption (empty value beats any -var-file entry).
        plan_args+=(-refresh=false ${preview_plan_vars[@]+"${preview_plan_vars[@]}"})
    fi
    if [[ -n "${TFVARS_FILE}" ]]; then
        plan_args+=(-var-file="${TFVARS_FILE}")
        log_info "Using tfvars: ${TFVARS_FILE}"
    else
        log_warning "No tfvars file found for environment: ${environment}"
    fi

    log_info "Running: terraform plan ${plan_args[*]}"
    local plan_output
    set +e
    plan_output=$(${tf_env[@]+"${tf_env[@]}"} terraform plan "${plan_args[@]}" 2>&1)
    local plan_exit=$?
    set -e

    if [[ ${plan_exit} -ne 0 ]] || [[ ! -f "tfplan" ]]; then
        if echo "${plan_output}" | grep -qE "Unable to find remote state|No stored state was found|Error loading state"; then
            log_warning "Remote state unavailable for ${unit_name} (upstream dependency not deployed)"
            update_unit_remote_state_status "${unit_name}" "unavailable" "remote_state_reference_error"
        else
            update_unit_remote_state_status "${unit_name}" "unavailable" "plan_failed"
        fi

        log_step "terraform plan" "FAILED"
        echo ""
        echo "${plan_output}" | grep -A 5 "Error:" | head -50 || echo "${plan_output}" | tail -30
        emit_cloud_credentials_hint_if_needed "${plan_output}"

        [[ -n "${preview_override}" ]] && rm -f "${preview_override}"
        popd > /dev/null
        return 2
    fi

    local resource_count
    resource_count=$(echo "${state_output}" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${has_backend_state}" == "true" ]]; then
        log_step "terraform plan" "ok" "${resource_count} existing resources"
    else
        log_step "terraform plan" "ok" "no existing state"
    fi

    # Convert plan to JSON for downstream consumers
    ${tf_env[@]+"${tf_env[@]}"} terraform show -json tfplan > tfplan.json 2>/dev/null
    TF_PLAN_JSON_FILE="$(pwd)/tfplan.json"

    # Provenance: capture the canonical digest of the evaluated plan via the
    # CLI (which owns canonicalization). No-op unless ILTERO_ATTEST=true, and
    # fail-soft otherwise, so existing behaviour is unchanged. A bad or empty
    # tfplan.json (a failed 'terraform show' above) is tolerated: the CLI exits
    # non-zero and the digest is simply left unset. Only FULL-mode plans are
    # eligible — a best-effort plan is deliberately not the deployable plan, so
    # it is never attested.
    if [[ "${TF_PLAN_MODE}" == "full" ]]; then
        compute_plan_digest "${TF_PLAN_JSON_FILE}"
        TF_PLAN_DIGEST="${PLAN_DIGEST}"
        TF_CANON_VERSION="${PLAN_CANON_VERSION}"
    fi

    # Upload plan JSON alongside the state file when an S3 backend is used.
    # Server-side encryption follows ILTERO_S3_SSE when set, else S3's default.
    # Never in preview: a preview plan is advisory and must not persist to the
    # evidence backend, even when it ran credentialed (same-repo PR).
    if [[ "${PREVIEW_MODE:-false}" != "true" ]] \
       && [[ -n "${TF_BACKEND_S3_BUCKET}" ]] && [[ -n "${TF_BACKEND_S3_KEY_PREFIX}" ]]; then
        local plan_s3_key="${TF_BACKEND_S3_KEY_PREFIX}/plans/${chain_run_id:-$(date +%s)}-tfplan.json"
        local plan_s3_dest="s3://${TF_BACKEND_S3_BUCKET}/${plan_s3_key}"
        log_info "Uploading plan JSON to ${plan_s3_dest}"
        if s3_cp_with_sse "${TF_PLAN_JSON_FILE}" "${plan_s3_dest}" "${TF_BACKEND_S3_REGION:-us-east-1}"; then
            TF_PLAN_S3_URL="${plan_s3_dest}"
            log_info "Plan uploaded successfully"
        else
            log_warning "Failed to upload plan JSON to S3 (non-fatal, continuing): ${S3_CP_STDERR:-no error output}"
        fi
    fi

    # Provenance: persist the appliable plan binary so the deploy job can apply
    # the exact evaluated plan. Binding is all-or-nothing: if we have a digest
    # but cannot store the binary, drop the digest so the unit is treated as
    # not-bound (the deploy job will re-plan) rather than failing at apply time.
    # This block must remain the LAST mutation of TF_PLAN_DIGEST in this function
    # so the invariant "binary uploaded => digest kept" holds (no orphan binds).
    if [[ -n "${TF_PLAN_DIGEST}" ]]; then
        if upload_plan_binary "${chain_run_id}" "${unit_name}"; then
            TF_PLAN_BINARY_URL="${PLAN_BINARY_URL}"
        else
            log_warning "Provenance: ${unit_name} will not be provenance-bound (plan binary not persisted)"
            TF_PLAN_DIGEST=""
            TF_CANON_VERSION=""
            TF_PLAN_BINARY_URL=""
        fi
    fi

    # Export pre-plan state JSON (audit trail and drift baseline)
    local state_json_file
    state_json_file="$(pwd)/tfstate-before-plan.json"
    set +e
    ${tf_env[@]+"${tf_env[@]}"} terraform show -json > "${state_json_file}" 2>/dev/null
    local state_export_exit=$?
    set -e

    if [[ ${state_export_exit} -ne 0 ]] || [[ ! -s "${state_json_file}" ]]; then
        log_info "No existing state to export (unit not yet deployed or state is empty)"
        TF_STATE_JSON_FILE=""
    else
        log_info "Exported current state to: ${state_json_file}"
        TF_STATE_JSON_FILE="${state_json_file}"
    fi

    [[ -n "${preview_override}" ]] && rm -f "${preview_override}"
    popd > /dev/null
    return 0
}
