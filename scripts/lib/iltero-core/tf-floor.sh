#!/bin/bash
# =============================================================================
# Iltero Core - Terraform Version Floor
# =============================================================================
# The minimum Terraform version Iltero supports, defined once and enforced at
# every point a terraform binary is about to be used (plan preparation and
# deployment), regardless of entrypoint (root action or granular actions).
#
# Iltero requires Terraform >= 1.10 because S3 native state locking
# (use_lockfile) is unavailable below it, and an older CLI silently ignores the
# setting rather than erroring — so a mixed fleet can lose state-lock mutual
# exclusion. The floor is therefore enforced unconditionally.
#
# Sourced by the core pipeline modules (terraform.sh, deployment.sh) and by the
# standalone resolver (scripts/terraform-version.sh), so the floor lives in one
# place. Depends on logging (log_*) at call time; callers load it first.
# =============================================================================

# Guard is intentionally NOT exported: it must prevent re-sourcing only within a
# single process. Exporting it would let a child process inherit the guard (=1)
# without the functions (functions are not exported), then skip re-sourcing and
# hit "command not found". A child that re-sources instead is correct and cheap.
if [[ -n "${ILTERO_TF_FLOOR_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
ILTERO_TF_FLOOR_SOURCED=1

# The 1.10 floor, defined once. resolve (in terraform-version.sh) builds its
# default (~1.10) from these same numbers.
FLOOR_MAJOR=1
FLOOR_MINOR=10
FLOOR_PATCH=0

# Guard so assert_terraform_floor shells out to `terraform` at most once per run
# (prepare_terraform_plan / run_deployment may be called per unit).
ILTERO_TF_FLOOR_CHECKED=""

# version_below_floor <version>
# Pure comparator. Returns:
#   0 - version is BELOW the floor
#   1 - version is at or above the floor
#   2 - version could not be parsed as numeric major.minor.patch
version_below_floor() {
    local v="$1"
    v="${v#v}"          # strip an optional leading v
    v="${v%%[-+]*}"     # strip -prerelease / +build metadata
    local IFS=.
    local -a parts
    read -ra parts <<< "${v}"

    local -a floor=("${FLOOR_MAJOR}" "${FLOOR_MINOR}" "${FLOOR_PATCH}")
    local i a b
    for i in 0 1 2; do
        a="${parts[i]:-0}"
        b="${floor[i]}"
        [[ "${a}" =~ ^[0-9]+$ ]] || return 2
        # 10# forces base-10 so a zero-padded component isn't read as octal.
        if (( 10#${a} < b )); then return 0; fi
        if (( 10#${a} > b )); then return 1; fi
    done
    return 1  # exactly equal to the floor => not below
}

# installed_terraform_version
# Echoes the concrete version of the terraform binary on PATH (empty if none).
# Honors TF_VERSION_OVERRIDE so tests need no real terraform install.
installed_terraform_version() {
    if [[ -n "${TF_VERSION_OVERRIDE:-}" ]]; then
        printf '%s' "${TF_VERSION_OVERRIDE}"
        return 0
    fi
    # `|| true`: a missing/failing terraform must fall through to the graceful
    # "could not determine version" path, not abort under set -e.
    terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || true
}

# assert_terraform_floor
# Gate called before terraform is used. Returns:
#   0 - installed version satisfies the floor, or could not be determined
#       (the subsequent real terraform call will fail loudly on its own), or is
#       not standard major.minor.patch (warned, not blocked)
#   2 - installed version is below the floor (after logging the fix)
# Shells out to terraform at most once per run (ILTERO_TF_FLOOR_CHECKED).
assert_terraform_floor() {
    [[ -n "${ILTERO_TF_FLOOR_CHECKED}" ]] && return 0

    local version
    version="$(installed_terraform_version)"
    if [[ -z "${version}" || "${version}" == "null" ]]; then
        log_warning "Could not determine the installed Terraform version; skipping floor check"
        ILTERO_TF_FLOOR_CHECKED=1
        return 0
    fi

    local rc=0
    version_below_floor "${version}" || rc=$?
    case "${rc}" in
        0)
            log_error "Terraform ${version} is below the minimum supported version ${FLOOR_MAJOR}.${FLOOR_MINOR}."
            log_error "Iltero requires Terraform >= ${FLOOR_MAJOR}.${FLOOR_MINOR} for S3 native state locking (use_lockfile). Pin a version >= ${FLOOR_MAJOR}.${FLOOR_MINOR} via the 'terraform_version' input or config.yml."
            return 2
            ;;
        2)
            log_warning "Installed Terraform version '${version}' is not a standard major.minor.patch; skipping floor check"
            ;;
        *)
            log_info "Terraform ${version} satisfies the >= ${FLOOR_MAJOR}.${FLOOR_MINOR} floor"
            ;;
    esac
    ILTERO_TF_FLOOR_CHECKED=1
    return 0
}
