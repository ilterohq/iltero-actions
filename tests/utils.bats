#!/usr/bin/env bats
# =============================================================================
# Tests for utils.sh - Exit codes, progress indicators, helpers
# =============================================================================

load 'test_helper'

setup() {
    source_iltero_core "utils.sh"
}

# =============================================================================
# Exit Code Constants
# =============================================================================

@test "EXIT_SUCCESS equals 0" {
    [[ "$EXIT_SUCCESS" -eq 0 ]]
}

@test "EXIT_VIOLATIONS equals 1" {
    [[ "$EXIT_VIOLATIONS" -eq 1 ]]
}

@test "EXIT_ERROR equals 2" {
    [[ "$EXIT_ERROR" -eq 2 ]]
}

# =============================================================================
# require_commands
# =============================================================================

@test "require_commands succeeds for available commands" {
    run require_commands bash cat ls
    assert_exit_code 0
}

@test "require_commands fails for missing command" {
    run require_commands nonexistent_command_xyz
    assert_exit_code 2
}

@test "require_commands reports missing command name" {
    run require_commands nonexistent_command_xyz
    assert_output_contains "nonexistent_command_xyz"
}

# =============================================================================
# require_env_vars
# =============================================================================

@test "require_env_vars succeeds when vars are set" {
    export TEST_VAR_1="value1"
    export TEST_VAR_2="value2"
    run require_env_vars TEST_VAR_1 TEST_VAR_2
    assert_exit_code 0
}

@test "require_env_vars fails when var is missing" {
    unset MISSING_VAR
    run require_env_vars MISSING_VAR
    assert_exit_code 2
}

@test "require_env_vars reports missing var name" {
    unset ANOTHER_MISSING_VAR
    run require_env_vars ANOTHER_MISSING_VAR
    assert_output_contains "ANOTHER_MISSING_VAR"
}

# =============================================================================
# json_get
# =============================================================================

@test "json_get extracts simple value" {
    local json='{"name": "test", "count": 42}'
    run json_get "$json" '.name'
    [[ "$output" == "test" ]]
}

@test "json_get returns default for missing key" {
    local json='{"name": "test"}'
    run json_get "$json" '.missing' "default_value"
    [[ "$output" == "default_value" ]]
}

@test "json_get handles nested paths" {
    local json='{"outer": {"inner": "value"}}'
    run json_get "$json" '.outer.inner'
    [[ "$output" == "value" ]]
}

# =============================================================================
# json_is_true
# =============================================================================

@test "json_is_true returns 0 for true value" {
    local json='{"enabled": true}'
    run json_is_true "$json" "enabled"
    assert_exit_code 0
}

@test "json_is_true returns 1 for false value" {
    local json='{"enabled": false}'
    run json_is_true "$json" "enabled"
    assert_exit_code 1
}

@test "json_is_true returns 1 for missing key" {
    local json='{"other": true}'
    run json_is_true "$json" "enabled"
    assert_exit_code 1
}
