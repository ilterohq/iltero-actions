#!/bin/bash
# =============================================================================
# Iltero Core - Provenance Attestation
# =============================================================================
# Runner-side helpers for the plan-to-apply provenance attestation feature.
#
# Everything here is gated on ILTERO_ATTEST=true and is otherwise dormant: when
# attestation is disabled (the default) these functions return immediately and
# the pipeline behaves exactly as before.
#
# Canonicalization is owned by the Iltero CLI ('iltero scan plan-digest'), not
# reimplemented here, so the runner and the backend compute byte-identical
# digests.
#
# Module-level outputs after compute_plan_digest():
#   PLAN_DIGEST          Canonical SHA-256 digest of the plan JSON, or ""
#   PLAN_CANON_VERSION   Canonicalization spec version used, or ""
# Module-level outputs after provenance_eval_flags():
#   PROVENANCE_EVAL_FLAGS  Array of evaluate-submission flags (empty if none)
# =============================================================================

if [[ -n "${ILTERO_ATTESTATION_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
export ILTERO_ATTESTATION_SOURCED=1

PLAN_DIGEST=""
PLAN_CANON_VERSION=""
PROVENANCE_EVAL_FLAGS=()

# attestation_enabled
# Single decision point for whether provenance attestation is active this run.
# Returns 0 when enabled, 1 otherwise. Callers stay uniform by branching on this
# rather than reading ILTERO_ATTEST directly.
attestation_enabled() {
    [[ "${ILTERO_ATTEST:-false}" == "true" ]]
}

# compute_plan_digest
# Computes the canonical digest of a plan JSON file via the Iltero CLI, which
# owns the canonicalization rules so the runner and backend never drift.
#
# Fail-soft by design: when attestation is disabled, the plan JSON is missing,
# or the CLI cannot produce a digest (e.g. an older CLI without the subcommand),
# the outputs are left empty and the function returns 0 so the caller proceeds
# unchanged. An empty PLAN_DIGEST simply means this unit is not provenance-bound.
#
# Args:
#   $1 = plan_json   path to the plan JSON (from 'terraform show -json <plan>')
# Sets:
#   PLAN_DIGEST, PLAN_CANON_VERSION (both "" when disabled or on any failure)
compute_plan_digest() {
    local plan_json="${1:-}"
    PLAN_DIGEST=""
    PLAN_CANON_VERSION=""

    attestation_enabled || return 0

    if [[ -z "${plan_json}" || ! -f "${plan_json}" ]]; then
        log_warning "Provenance: plan JSON unavailable; unit will not be provenance-bound"
        return 0
    fi

    local digest_json digest_exit stderr_file
    stderr_file="$(mktemp)"
    set +e
    digest_json=$("${ILTERO_CLI_BIN:-iltero}" scan plan-digest "${plan_json}" --output json 2>"${stderr_file}")
    digest_exit=$?
    set -e

    if [[ ${digest_exit} -ne 0 || -z "${digest_json}" ]]; then
        # Surface the CLI's own error (e.g. unknown subcommand on an older CLI,
        # invalid JSON) so an operator who enabled attestation can diagnose why
        # the unit was not bound. The run summary also reflects this.
        local stderr_tail
        stderr_tail=$(tail -c 300 "${stderr_file}" 2>/dev/null | tr '\n' ' ')
        log_warning "Provenance: plan-digest unavailable (CLI exit ${digest_exit}): ${stderr_tail:-no error output}; unit will not be provenance-bound"
        rm -f "${stderr_file}"
        return 0
    fi
    rm -f "${stderr_file}"

    PLAN_DIGEST=$(jq -r '.plan_digest // empty' <<<"${digest_json}" 2>/dev/null || printf '')
    PLAN_CANON_VERSION=$(jq -r '.canonicalization_version // empty' <<<"${digest_json}" 2>/dev/null || printf '')

    # Defence-in-depth: both values are forwarded as argument values to a later
    # CLI call, so reject anything that isn't the expected shape (lowercase
    # 64-char hex digest; conservative version token) and treat it as
    # unavailable rather than forwarding unexpected bytes. A malformed digest
    # voids the version too, since a version without a digest cannot bind.
    if [[ -n "${PLAN_DIGEST}" && ! "${PLAN_DIGEST}" =~ ^[0-9a-f]{64}$ ]]; then
        log_warning "Provenance: ignoring malformed plan_digest from CLI; unit will not be provenance-bound"
        PLAN_DIGEST=""
        PLAN_CANON_VERSION=""
    fi
    if [[ -n "${PLAN_CANON_VERSION}" && ! "${PLAN_CANON_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_warning "Provenance: ignoring malformed canonicalization_version from CLI"
        PLAN_CANON_VERSION=""
    fi

    if [[ -n "${PLAN_DIGEST}" ]]; then
        log_info "Provenance: plan digest ${PLAN_DIGEST} (canon v${PLAN_CANON_VERSION:-unknown})"
    else
        log_warning "Provenance: CLI returned no usable plan_digest; unit will not be provenance-bound"
    fi
    return 0
}

# provenance_eval_flags
# Builds the evaluate-submission flags that record the plan digest under the
# run. Populates the PROVENANCE_EVAL_FLAGS array (empty when there is no digest
# to submit), so the caller can splice it into its CLI command. Kept here so
# the evaluate-submission contract has one tested home.
#
# Args:
#   $1 = plan_digest               canonical digest, or "" to emit nothing
#   $2 = canonicalization_version  spec version, or "" to omit that flag
# Sets:
#   PROVENANCE_EVAL_FLAGS (array)
provenance_eval_flags() {
    local digest="${1:-}"
    local canon="${2:-}"
    PROVENANCE_EVAL_FLAGS=()

    [[ -n "${digest}" ]] || return 0
    PROVENANCE_EVAL_FLAGS+=(--plan-digest "${digest}")
    if [[ -n "${canon}" ]]; then
        PROVENANCE_EVAL_FLAGS+=(--canonicalization-version "${canon}")
    fi
    return 0
}
