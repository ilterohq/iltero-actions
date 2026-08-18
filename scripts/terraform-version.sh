#!/bin/bash
# =============================================================================
# Iltero Actions - Terraform Version Management
# =============================================================================
# Single entry point for Terraform version selection and validation, invoked
# with a subcommand:
#
#   resolve         Pick the version to install and normalize it into the
#                   semver-range syntax hashicorp/setup-terraform expects.
#                   Runs BEFORE the install (detection is git + YAML only).
#                   Precedence: action input > config.yml terraform.version >
#                   default (~1.10, newest 1.10.x). Fails closed (exit 2) when
#                   selected stacks pin different versions. Writes
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
#     STACKS_PATH              Greenfield stacks code dir (empty => brownfield)
#     STACKS_CONFIG            Greenfield stacks metadata dir
#     CONFIG_PATH              Brownfield config file
#     STACK                    Manual single stack (optional)
#     GITHUB_EVENT_NAME, GITHUB_BASE_REF  Consumed by stack detection
#   enforce-floor:
#     TF_VERSION_OVERRIDE      Test hook: version to check instead of invoking
#                              `terraform`.
#
# Exit codes:
#   0 - Success
#   2 - resolve: conflicting versions across stacks; enforce-floor: below floor;
#       or unknown subcommand
# =============================================================================

set -euo pipefail

TF_VERSION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/logging.sh
source "${TF_VERSION_SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/detect-stacks.sh
source "${TF_VERSION_SCRIPT_DIR}/detect-stacks.sh"
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

# collect_config_files
# Echoes the config.yml paths whose terraform.version should be considered,
# one per line. Greenfield: the changed (or manually selected) stacks under
# STACKS_CONFIG. Brownfield: the single CONFIG_PATH file.
collect_config_files() {
    if [[ -z "${STACKS_PATH:-}" ]]; then
        local cfg="${CONFIG_PATH:-.iltero/config.yml}"
        [[ -f "${cfg}" ]] && printf '%s\n' "${cfg}"
        return 0
    fi

    # Greenfield: resolve the config dir the same way run-pipeline.sh does.
    local stacks_config="${STACKS_CONFIG:-.iltero/stacks}"
    export STACKS_CONFIG="${stacks_config}"

    local stacks_json
    if [[ -n "${STACK:-}" ]]; then
        stacks_json="$(jq -nc --arg s "${STACK}" '[$s]')"
    elif [[ -d "${STACKS_PATH}" ]]; then
        stacks_json="$(detect_stacks "${STACKS_PATH}")"
    else
        stacks_json="[]"
    fi

    local stack cfg
    while IFS= read -r stack; do
        [[ -z "${stack}" ]] && continue
        cfg="${stacks_config%/}/${stack}/config.yml"
        [[ -f "${cfg}" ]] && printf '%s\n' "${cfg}"
    done < <(printf '%s' "${stacks_json}" | jq -r '.[]?' 2>/dev/null || true)
}

# resolve_terraform_version
# Applies the documented precedence and sets RESOLVED_TF_VERSION.
# Returns 0 on success, 2 on a multi-stack version conflict.
resolve_terraform_version() {
    RESOLVED_TF_VERSION=""

    # 1. Explicit action input wins (CI-wide override).
    local input
    input="$(trim "${INPUT_TERRAFORM_VERSION:-}")"
    if [[ -n "${input}" ]]; then
        log_info "Terraform version from action input: ${input}"
        RESOLVED_TF_VERSION="$(normalize_tf_version "${input}")"
        return 0
    fi

    # 2. config.yml terraform.version across the selected stacks. Conflict
    # detection is scoped to the stacks selected for THIS run (changed, or the
    # manual STACK) — a single job installs one binary, so only co-running
    # stacks can conflict. Dedup on the NORMALIZED form so equivalent
    # constraints written differently (e.g. "~> 1.10" vs "~>1.10") are not
    # mistaken for a conflict.
    local -a versions=()
    local seen="" cfg raw nrm
    while IFS= read -r cfg; do
        [[ -z "${cfg}" ]] && continue
        # A yq that cannot run returns nothing, which reads as "no version
        # declared" — a stack pinning 1.12 would silently get the default and
        # the recorded version would not be the declared one.
        if ! raw="$(yq eval '.terraform.version // ""' "${cfg}" 2>/dev/null)"; then
            log_error "Could not read terraform.version from ${cfg}"
            return "${EXIT_ERROR}"
        fi
        raw="$(trim "${raw}")"
        [[ -z "${raw}" || "${raw}" == "null" ]] && continue
        nrm="$(normalize_tf_version "${raw}")"
        if [[ "${seen}" != *"|${nrm}|"* ]]; then
            versions+=("${nrm}")
            seen="${seen}|${nrm}|"
        fi
    done < <(collect_config_files)

    # 3. Nothing declared -> default.
    if [[ "${#versions[@]}" -eq 0 ]]; then
        log_info "No terraform.version declared; using default ${DEFAULT_TF_VERSION}"
        RESOLVED_TF_VERSION="${DEFAULT_TF_VERSION}"
        return 0
    fi

    # A single job installs one Terraform binary — divergent pins are a hard error.
    if [[ "${#versions[@]}" -gt 1 ]]; then
        log_error "Selected stacks declare different terraform.version values: ${versions[*]}"
        log_error "One job installs a single Terraform binary. Pin an explicit version via the 'terraform_version' input, or split these stacks into separate jobs."
        return 2
    fi

    log_info "Terraform version from config.yml: ${versions[0]}"
    RESOLVED_TF_VERSION="${versions[0]}"  # already normalized above
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
