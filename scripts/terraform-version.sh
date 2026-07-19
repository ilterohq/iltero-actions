#!/bin/bash
# =============================================================================
# Iltero Actions - Terraform Version Management
# =============================================================================
# Single entry point for Terraform version selection and validation, invoked
# with a subcommand:
#
#   resolve         Pick the version to install and normalize it into the
#                   semver-range syntax hashicorp/setup-terraform expects.
#                   Runs BEFORE the install. Precedence: action input
#                   `terraform_version` > default (~1.10, newest 1.10.x). Writes
#                   `terraform-version=<value>` to GITHUB_OUTPUT.
#
#   enforce-floor   Fail the job (exit 2) when the CONCRETE installed Terraform
#                   is older than the minimum Iltero supports. Runs AFTER the
#                   install, so it validates the resolved version — not the
#                   requested range.
#
# Iltero requires Terraform >= 1.10: S3 native state locking (use_lockfile) is
# unavailable below it, and an older CLI silently ignores the setting rather
# than erroring, so a mixed fleet can lose state-lock mutual exclusion. The
# floor is enforced unconditionally.
#
# Environment variables:
#   resolve:
#     INPUT_TERRAFORM_VERSION  Explicit version/constraint (may be empty)
#   enforce-floor:
#     TF_VERSION_OVERRIDE      Test hook: version to check instead of invoking
#                              `terraform`.
#
# Exit codes:
#   0 - Success
#   2 - enforce-floor: below floor; or unknown subcommand
# =============================================================================

set -euo pipefail

TF_VERSION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/logging.sh
source "${TF_VERSION_SCRIPT_DIR}/lib/logging.sh"
# The floor (FLOOR_*, version_below_floor, assert_terraform_floor) lives in the
# core so it is shared with the pipeline; this script owns only resolution.
# shellcheck source=scripts/lib/iltero-core/tf-floor.sh
source "${TF_VERSION_SCRIPT_DIR}/lib/iltero-core/tf-floor.sh"

# Default when nothing is declared: newest FLOOR_MAJOR.FLOOR_MINOR patch.
# Expressed as a semver range (~1.10 == ">=1.10.0 <1.11.0") so setup-terraform
# resolves the latest available patch, without this repo pinning — and having
# to bump — a specific patch number.
DEFAULT_TF_VERSION="~${FLOOR_MAJOR}.${FLOOR_MINOR}"

# Set by resolve_terraform_version().
RESOLVED_TF_VERSION=""

# trim <string>
# Echoes the input with leading/trailing whitespace removed.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

# ---------------------------------------------------------------------------
# resolve
# ---------------------------------------------------------------------------

# normalize_tf_version <version-or-constraint>
# Pure function: echoes a version string in the semver-range syntax that
# setup-terraform accepts. Translates Terraform's pessimistic operator `~>`
# (which has no semver equivalent) and explicit equality `=`. Exact versions,
# `latest`, and standard comparators (>=, >, <=, <) are already valid semver
# ranges and pass through unchanged. Emits NO log output (safe to capture).
normalize_tf_version() {
    local v
    v="$(trim "$1")"
    [[ -z "${v}" ]] && { printf '%s' ""; return 0; }

    # Terraform pessimistic operator `~>` -> explicit semver range.
    if [[ "${v}" =~ ^~\>[[:space:]]*(.+)$ ]]; then
        local ver
        ver="$(trim "${BASH_REMATCH[1]}")"
        local IFS=.
        local -a parts
        read -ra parts <<< "${ver}"
        local major="${parts[0]:-}" minor="${parts[1]:-}"
        # Only translate when the leading components are numeric; otherwise hand
        # the raw string to setup-terraform and let it surface its own error.
        # 10# forces base-10 so a zero-padded component isn't read as octal.
        if [[ "${major}" =~ ^[0-9]+$ ]] && { [[ "${#parts[@]}" -lt 2 ]] || [[ "${minor}" =~ ^[0-9]+$ ]]; }; then
            if [[ "${#parts[@]}" -ge 3 ]]; then
                # ~> X.Y.Z  =>  >=X.Y.Z <X.(Y+1).0
                printf '%s' ">=${ver} <${major}.$((10#${minor} + 1)).0"
            elif [[ "${#parts[@]}" -eq 2 ]]; then
                # ~> X.Y    =>  >=X.Y.0 <(X+1).0.0
                printf '%s' ">=${major}.${minor}.0 <$((10#${major} + 1)).0.0"
            else
                # ~> X      =>  >=X.0.0 <(X+1).0.0
                printf '%s' ">=${major}.0.0 <$((10#${major} + 1)).0.0"
            fi
            return 0
        fi
        printf '%s' "${v}"
        return 0
    fi

    # Explicit equality `= X.Y.Z` -> exact version.
    if [[ "${v}" =~ ^=[[:space:]]*(.+)$ ]]; then
        printf '%s' "$(trim "${BASH_REMATCH[1]}")"
        return 0
    fi

    printf '%s' "${v}"
}

# resolve_terraform_version
# Precedence: action input `terraform_version` > default (~1.10). Sets
# RESOLVED_TF_VERSION. config.yml `terraform.version` is intentionally NOT
# consulted — the Terraform version is a CI/workflow concern set via the action
# input; stale per-stack config values must not drive the install.
resolve_terraform_version() {
    local input
    input="$(trim "${INPUT_TERRAFORM_VERSION:-}")"
    if [[ -n "${input}" ]]; then
        log_info "Terraform version from action input: ${input}"
        RESOLVED_TF_VERSION="$(normalize_tf_version "${input}")"
    else
        log_info "No terraform_version input; using default ${DEFAULT_TF_VERSION}"
        RESOLVED_TF_VERSION="${DEFAULT_TF_VERSION}"
    fi
    return 0
}

cmd_resolve() {
    resolve_terraform_version
    log_info "Resolved Terraform version (for setup-terraform): ${RESOLVED_TF_VERSION}"
    set_output "terraform-version" "${RESOLVED_TF_VERSION}"
}

# ---------------------------------------------------------------------------
# enforce-floor
# ---------------------------------------------------------------------------
# Early, action-level floor check right after install (fast, clear failure on
# the root path). The core pipeline (prepare_terraform_plan / run_deployment)
# gates again at the point terraform is used, so every entrypoint is covered.
# The comparison logic lives in the shared tf-floor.sh.

cmd_enforce_floor() {
    assert_terraform_floor || exit 2
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        resolve)       cmd_resolve ;;
        enforce-floor) cmd_enforce_floor ;;
        *)
            log_error "usage: terraform-version.sh {resolve|enforce-floor}"
            exit 2
            ;;
    esac
}

# Only run main when executed directly, so tests can source and unit-test the
# individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
