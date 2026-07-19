#!/usr/bin/env bats
# =============================================================================
# Tests for terraform-version.sh (resolve + enforce-floor)
# =============================================================================
# resolve:       precedence (input > config.yml > default), fail-closed on
#                divergent stack pins, and Terraform-constraint -> semver
#                normalization handed to setup-terraform.
# enforce-floor: the >= 1.10 floor — below fails closed (exit 2), at/above
#                passes, unparseable warns without blocking.

load 'test_helper'

setup() {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    # Sourcing does not run main() (guarded on BASH_SOURCE == $0).
    source "${PROJECT_ROOT}/scripts/terraform-version.sh"
    # The script sets `set -euo pipefail` at source time; relax -e so a
    # non-`run` assertion failure reports as a failed test, not an aborted body.
    set +e
    unset INPUT_TERRAFORM_VERSION STACKS_PATH STACKS_CONFIG CONFIG_PATH STACK
}

SCRIPT() { echo "${PROJECT_ROOT}/scripts/terraform-version.sh"; }

# =============================================================================
# normalize_tf_version — Terraform-constraint -> semver-range
# =============================================================================

@test "normalize: exact version passes through" {
    run normalize_tf_version "1.12.3"
    [ "${output}" = "1.12.3" ]
}

@test "normalize: latest passes through" {
    run normalize_tf_version "latest"
    [ "${output}" = "latest" ]
}

@test "normalize: two-part ~> allows minor bumps" {
    run normalize_tf_version "~> 1.10"
    [ "${output}" = ">=1.10.0 <2.0.0" ]
}

@test "normalize: three-part ~> pins to patch range" {
    run normalize_tf_version "~> 1.10.0"
    [ "${output}" = ">=1.10.0 <1.11.0" ]
}

@test "normalize: ~> without space is handled" {
    run normalize_tf_version "~>1.9"
    [ "${output}" = ">=1.9.0 <2.0.0" ]
}

@test "normalize: explicit equality becomes exact" {
    run normalize_tf_version "= 1.11.2"
    [ "${output}" = "1.11.2" ]
}

@test "normalize: comparator range passes through" {
    run normalize_tf_version ">= 1.10"
    [ "${output}" = ">= 1.10" ]
}

@test "normalize: surrounding whitespace trimmed" {
    run normalize_tf_version "  1.10.5  "
    [ "${output}" = "1.10.5" ]
}

@test "normalize: zero-padded component does not crash (base-10)" {
    run normalize_tf_version "~> 1.09.0"
    [ "${status}" -eq 0 ]
    [ "${output}" = ">=1.09.0 <1.10.0" ]
}

@test "normalize: zero-padded single component does not crash" {
    run normalize_tf_version "~> 08"
    [ "${status}" -eq 0 ]
}

# =============================================================================
# resolve_terraform_version — precedence + conflict
# =============================================================================

@test "resolve: default when nothing declared" {
    collect_config_files() { :; }
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = "~1.10" ]
}

@test "resolve: explicit input overrides config" {
    export INPUT_TERRAFORM_VERSION="1.13.2"
    collect_config_files() { printf '%s\n' "/nope/a.yml" "/nope/b.yml"; }
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = "1.13.2" ]
}

@test "resolve: explicit input is normalized" {
    export INPUT_TERRAFORM_VERSION="~> 1.11"
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = ">=1.11.0 <2.0.0" ]
}

@test "resolve: single config.yml version is used and normalized" {
    local cfgfile="${BATS_TEST_TMPDIR}/config.yml"
    printf 'terraform:\n  version: "~> 1.12"\n' > "${cfgfile}"
    collect_config_files() { printf '%s\n' "${cfgfile}"; }
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = ">=1.12.0 <2.0.0" ]
}

@test "resolve: same version across stacks is not a conflict" {
    local a="${BATS_TEST_TMPDIR}/a.yml" b="${BATS_TEST_TMPDIR}/b.yml"
    printf 'terraform:\n  version: "1.12.0"\n' > "${a}"
    printf 'terraform:\n  version: "1.12.0"\n' > "${b}"
    collect_config_files() { printf '%s\n' "${a}" "${b}"; }
    run resolve_terraform_version
    [ "${status}" -eq 0 ]
}

@test "resolve: equivalent constraints written differently do not conflict" {
    local a="${BATS_TEST_TMPDIR}/a.yml" b="${BATS_TEST_TMPDIR}/b.yml"
    printf 'terraform:\n  version: "~> 1.11"\n' > "${a}"
    printf 'terraform:\n  version: "~>1.11"\n' > "${b}"
    collect_config_files() { printf '%s\n' "${a}" "${b}"; }
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = ">=1.11.0 <2.0.0" ]
}

@test "resolve: divergent versions across stacks fail closed (exit 2)" {
    local a="${BATS_TEST_TMPDIR}/a.yml" b="${BATS_TEST_TMPDIR}/b.yml"
    printf 'terraform:\n  version: "1.12.0"\n' > "${a}"
    printf 'terraform:\n  version: "1.13.0"\n' > "${b}"
    collect_config_files() { printf '%s\n' "${a}" "${b}"; }
    run resolve_terraform_version
    [ "${status}" -eq 2 ]
}

@test "resolve: config without terraform.version falls back to default" {
    local cfgfile="${BATS_TEST_TMPDIR}/config.yml"
    printf 'stack:\n  id: abc\n' > "${cfgfile}"
    collect_config_files() { printf '%s\n' "${cfgfile}"; }
    resolve_terraform_version
    [ "${RESOLVED_TF_VERSION}" = "~1.10" ]
}

@test "resolve e2e: writes terraform-version to GITHUB_OUTPUT" {
    local root="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${root}/code/s1" "${root}/cfg/s1"
    printf 'terraform:\n  version: "1.14.1"\n' > "${root}/cfg/s1/config.yml"
    run env INPUT_TERRAFORM_VERSION="" \
        STACKS_PATH="${root}/code" STACKS_CONFIG="${root}/cfg" STACK="s1" \
        GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" \
        bash "$(SCRIPT)" resolve
    [ "${status}" -eq 0 ]
    grep -qx "terraform-version=1.14.1" "${BATS_TEST_TMPDIR}/out"
}

# =============================================================================
# enforce-floor subcommand — delegates to assert_terraform_floor (tf-floor.sh,
# unit-tested in tf-floor.bats); here we cover the subcommand's exit contract.
# =============================================================================

@test "enforce-floor: below floor fails closed (exit 2)" {
    run env TF_VERSION_OVERRIDE="1.9.9" bash "$(SCRIPT)" enforce-floor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"below the minimum"* ]]
}

@test "enforce-floor: at/above floor passes (exit 0)" {
    run env TF_VERSION_OVERRIDE="1.10.0" bash "$(SCRIPT)" enforce-floor
    [ "${status}" -eq 0 ]
}

@test "enforce-floor: unparseable version warns but does not block" {
    run env TF_VERSION_OVERRIDE="dev" bash "$(SCRIPT)" enforce-floor
    [ "${status}" -eq 0 ]
}

# =============================================================================
# dispatch
# =============================================================================

@test "dispatch: unknown subcommand exits 2" {
    run bash "$(SCRIPT)" bogus
    [ "${status}" -eq 2 ]
}
