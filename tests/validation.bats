#!/usr/bin/env bats
# =============================================================================
# Tests for validation.sh - Unit structure validation
# =============================================================================

load 'test_helper'

setup() {
    # Create temp directory
    mkdir -p "$TEST_TEMP"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    touch "$GITHUB_OUTPUT"
    
    # Source all needed modules at once
    source_iltero_core "validation.sh"
}

teardown() {
    rm -rf "$TEST_TEMP"
}

# =============================================================================
# validate_unit_structure
# =============================================================================

@test "validate_unit_structure succeeds with all required files" {
    local unit_dir
    unit_dir=$(create_mock_unit "valid-unit")
    
    run validate_unit_structure "$unit_dir"
    assert_exit_code 0
}

@test "validate_unit_structure fails for missing directory" {
    run validate_unit_structure "/nonexistent/path"
    assert_exit_code 2
}

@test "validate_unit_structure fails for empty path" {
    run validate_unit_structure ""
    assert_exit_code 2
}

@test "validate_unit_structure fails when main.tf is missing" {
    local unit_dir="${BATS_TEST_TMPDIR}/incomplete-unit"
    mkdir -p "$unit_dir"
    touch "$unit_dir/providers.tf"
    touch "$unit_dir/versions.tf"
    touch "$unit_dir/backend.tf"
    # main.tf is missing
    
    run validate_unit_structure "$unit_dir"
    assert_exit_code 1
}

@test "validate_unit_structure reports missing files" {
    local unit_dir="${BATS_TEST_TMPDIR}/empty-unit"
    mkdir -p "$unit_dir"
    # All files missing
    
    run validate_unit_structure "$unit_dir"
    assert_exit_code 1
    assert_output_contains "main.tf"
}

# =============================================================================
# check_env_config
# =============================================================================

@test "check_env_config finds tfvars file" {
    local unit_dir="${TEST_TEMP}/unit-with-config"
    mkdir -p "$unit_dir/config"
    echo 'environment = "prod"' > "$unit_dir/config/prod.tfvars"
    
    check_env_config "$unit_dir" "prod"
    
    [[ "$TFVARS_FILE" == "$unit_dir/config/prod.tfvars" ]]
}

@test "check_env_config finds backend hcl file" {
    local unit_dir="${TEST_TEMP}/unit-with-backend"
    mkdir -p "$unit_dir/config/backend"
    echo 'bucket = "my-state"' > "$unit_dir/config/backend/prod.hcl"
    
    check_env_config "$unit_dir" "prod"
    
    [[ "$BACKEND_HCL" == "$unit_dir/config/backend/prod.hcl" ]]
}

@test "check_env_config clears vars when files don't exist" {
    local unit_dir="${TEST_TEMP}/unit-no-config"
    mkdir -p "$unit_dir"
    
    check_env_config "$unit_dir" "staging"
    
    [[ -z "$TFVARS_FILE" ]]
    [[ -z "$BACKEND_HCL" ]]
}
