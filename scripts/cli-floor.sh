#!/bin/bash
# =============================================================================
# Iltero CLI version floor
# =============================================================================
# The oldest Iltero CLI this action's compliance gate can rely on, enforced
# right after the CLI is installed.
#
# Why there is a floor at all: below 0.7.0 the CLI exits cleanly in states where
# no compliance verdict was reached — a policy resolution that failed, results
# the service never recorded. This action decides whether a deployment may
# proceed from the CLI's exit code, so on an older CLI those states are
# indistinguishable from a clean pass and the gate silently stops gating.
# Failing the job is the only honest answer: a gate that cannot see the failure
# it exists to catch should not report success.
#
# Usage:
#   cli-floor.sh enforce-floor
#
# Exit codes:
#   0 - the installed CLI satisfies the floor
#   2 - it does not, or its version could not be determined
#
# ILTERO_CLI_VERSION_OVERRIDE substitutes the version, so tests need no install.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

FLOOR="0.7.0"

# Echo the installed CLI version, or nothing.
#
# Read from the installed package's own record rather than by asking the program
# to describe itself: the record is what the installer wrote, and it cannot
# contain anything but a version string.
installed_cli_version() {
    if [[ -n "${ILTERO_CLI_VERSION_OVERRIDE:-}" ]]; then
        printf '%s' "${ILTERO_CLI_VERSION_OVERRIDE}"
        return 0
    fi
    python -c 'import importlib.metadata as m; print(m.version("iltero-cli"))' 2>/dev/null || true
}

# version_below <version> <floor>
# Returns 0 when version is below floor, 1 when at or above, 2 when unparseable.
version_below() {
    local v="${1#v}" f="${2#v}"
    v="${v%%[-+]*}"   # drop -prerelease / +build metadata
    f="${f%%[-+]*}"

    local IFS=.
    local -a vp fp
    read -ra vp <<< "${v}"
    read -ra fp <<< "${f}"

    local i a b
    for i in 0 1 2; do
        a="${vp[i]:-0}"
        b="${fp[i]:-0}"
        # A pre-release attaches without a separator (0.7.0rc1), and the version
        # input accepts that form, so the floor must read it rather than refuse
        # it. Trim from the first non-digit: a release candidate for a version
        # that satisfies the floor counts as satisfying it.
        a="${a%%[!0-9]*}"
        b="${b%%[!0-9]*}"
        [[ "${a}" =~ ^[0-9]+$ ]] || return 2
        [[ "${b}" =~ ^[0-9]+$ ]] || return 2
        # 10# forces base 10, so a zero-padded component is not read as octal.
        if (( 10#${a} < 10#${b} )); then return 0; fi
        if (( 10#${a} > 10#${b} )); then return 1; fi
    done
    return 1  # equal to the floor is not below it
}

cmd_enforce_floor() {
    local version rc=0
    version="$(installed_cli_version)"

    if [[ -z "${version}" ]]; then
        log_error "Could not determine the installed Iltero CLI version."
        log_error "  This action requires Iltero CLI >= ${FLOOR}; without a version it cannot confirm that."
        return 2
    fi

    version_below "${version}" "${FLOOR}" || rc=$?
    case "${rc}" in
        0)
            log_error "Iltero CLI ${version} is installed; this action requires >= ${FLOOR}."
            log_error "  Below ${FLOOR} the CLI exits cleanly when a scan reached no compliance"
            log_error "  verdict, so this action cannot tell that apart from a pass."
            log_error "  Set the CLI version input to ${FLOOR} or newer."
            return 2
            ;;
        2)
            log_error "Could not read the installed Iltero CLI version ('${version}')."
            log_error "  This action requires Iltero CLI >= ${FLOOR}."
            return 2
            ;;
    esac

    log_info "Iltero CLI ${version} satisfies the >= ${FLOOR} floor"
    return 0
}

main() {
    case "${1:-}" in
        enforce-floor) cmd_enforce_floor ;;
        *)
            log_error "usage: cli-floor.sh enforce-floor"
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
