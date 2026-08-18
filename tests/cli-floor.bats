#!/usr/bin/env bats
# =============================================================================
# Tests for the Iltero CLI version floor
# =============================================================================
# This action decides whether a deployment may proceed from the CLI's exit code.
# Below 0.7.0 the CLI exits cleanly in states where no compliance verdict was
# reached, so the gate cannot see them. The floor makes that a job failure
# rather than a silent downgrade.

load 'test_helper'

FLOOR_SH() { printf '%s' "${PROJECT_ROOT}/scripts/cli-floor.sh"; }

@test "cli floor: the released version that first reports these states passes" {
    run env ILTERO_CLI_VERSION_OVERRIDE=0.7.0 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]
}

@test "cli floor: a newer version passes" {
    run env ILTERO_CLI_VERSION_OVERRIDE=0.8.1 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]

    run env ILTERO_CLI_VERSION_OVERRIDE=1.0.0 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]
}

@test "cli floor: the previous release is refused, naming what it cannot do" {
    run env ILTERO_CLI_VERSION_OVERRIDE=0.6.3 "$(FLOOR_SH)" enforce-floor

    [ "${status}" -eq 2 ]
    [[ "${output}" == *"0.7.0"* ]] || return 1
    # The message must say why, not just that a number is too low.
    [[ "${output}" == *"no compliance"* ]] || return 1
}

@test "cli floor: a much older version is refused" {
    run env ILTERO_CLI_VERSION_OVERRIDE=0.3.0 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 2 ]
}

@test "cli floor: an unreadable version fails closed, never passes" {
    local v
    for v in "" "unknown" "not installed" "v" "0.x.0"; do
        run env ILTERO_CLI_VERSION_OVERRIDE="${v}" "$(FLOOR_SH)" enforce-floor
        [ "${status}" -eq 2 ] || {
            echo "version '${v}' was accepted"
            return 1
        }
    done
}

@test "cli floor: a leading v and pre-release metadata are tolerated" {
    run env ILTERO_CLI_VERSION_OVERRIDE=v0.7.0 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]

    # A pre-release of a satisfying version is treated as that version rather
    # than refused: refusing it would block anyone testing a release candidate.
    run env ILTERO_CLI_VERSION_OVERRIDE=0.7.0rc1 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]
}

@test "cli floor: a zero-padded component is read as decimal, not octal" {
    # 0.08.0 must compare as 8, which is above 7. Read as octal it would be 8
    # too, but 0.09.0 would fail to parse — pin the base explicitly.
    run env ILTERO_CLI_VERSION_OVERRIDE=0.09.0 "$(FLOOR_SH)" enforce-floor
    [ "${status}" -eq 0 ]
}

@test "cli floor: an unknown subcommand fails rather than passing silently" {
    run "$(FLOOR_SH)" not-a-command
    [ "${status}" -eq 2 ]

    run "$(FLOOR_SH)"
    [ "${status}" -eq 2 ]
}
