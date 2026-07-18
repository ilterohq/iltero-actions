#!/usr/bin/env bats
# =============================================================================
# Tests for tf-floor.sh — the shared Terraform version floor (>= 1.10)
# =============================================================================
# version_below_floor is a pure comparator; assert_terraform_floor is the gate
# called before terraform is used (fail closed below the floor, graceful when
# the version can't be determined, and shells out at most once per run).

load 'test_helper'

setup() {
    source "${LIB_DIR}/logging.sh"
    source "${CORE_DIR}/tf-floor.sh"
    set +e
    ILTERO_TF_FLOOR_CHECKED=""
    unset TF_VERSION_OVERRIDE
}

# =============================================================================
# version_below_floor — 0 below, 1 at/above, 2 unparseable
# =============================================================================

@test "version_below_floor: 1.9.9 is below" {
    run version_below_floor "1.9.9"
    [ "${status}" -eq 0 ]
}

@test "version_below_floor: 1.5.7 is below" {
    run version_below_floor "1.5.7"
    [ "${status}" -eq 0 ]
}

@test "version_below_floor: 0.14.0 is below" {
    run version_below_floor "0.14.0"
    [ "${status}" -eq 0 ]
}

@test "version_below_floor: exactly 1.10.0 is not below" {
    run version_below_floor "1.10.0"
    [ "${status}" -eq 1 ]
}

@test "version_below_floor: 1.10 (two-part) is not below" {
    run version_below_floor "1.10"
    [ "${status}" -eq 1 ]
}

@test "version_below_floor: 1.11.0 is not below" {
    run version_below_floor "1.11.0"
    [ "${status}" -eq 1 ]
}

@test "version_below_floor: 2.0.1 is not below" {
    run version_below_floor "2.0.1"
    [ "${status}" -eq 1 ]
}

@test "version_below_floor: prerelease/build metadata stripped before compare" {
    run version_below_floor "1.15.8-beta1"
    [ "${status}" -eq 1 ]
}

@test "version_below_floor: leading v is stripped" {
    run version_below_floor "v1.9.0"
    [ "${status}" -eq 0 ]
}

@test "version_below_floor: non-numeric version is unparseable" {
    run version_below_floor "latest"
    [ "${status}" -eq 2 ]
}

# =============================================================================
# assert_terraform_floor — the gate
# =============================================================================

@test "assert_terraform_floor: below floor fails closed (return 2)" {
    export TF_VERSION_OVERRIDE="1.9.9"
    run assert_terraform_floor
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"below the minimum"* ]]
}

@test "assert_terraform_floor: at/above floor passes (return 0)" {
    export TF_VERSION_OVERRIDE="1.10.0"
    run assert_terraform_floor
    [ "${status}" -eq 0 ]
}

@test "assert_terraform_floor: unparseable version warns but does not block" {
    export TF_VERSION_OVERRIDE="dev"
    run assert_terraform_floor
    [ "${status}" -eq 0 ]
}

@test "assert_terraform_floor: checked-once guard skips re-evaluation" {
    # Guard already set => returns 0 without consulting the (below-floor) version.
    ILTERO_TF_FLOOR_CHECKED=1
    export TF_VERSION_OVERRIDE="1.9.9"
    run assert_terraform_floor
    [ "${status}" -eq 0 ]
}
