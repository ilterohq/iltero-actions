#!/usr/bin/env bats
# =============================================================================
# Tests for github.sh - GitHub Actions helpers
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "$TEST_TEMP"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "$GITHUB_OUTPUT"
    touch "$GITHUB_STEP_SUMMARY"
    
    source_iltero_core "github.sh"
}

teardown() {
    rm -rf "$TEST_TEMP"
}

# =============================================================================
# set_output
# =============================================================================

@test "set_output writes to GITHUB_OUTPUT" {
    set_output "test_key" "test_value"
    
    assert_file_contains "$GITHUB_OUTPUT" "test_key=test_value"
}

@test "set_output handles special characters" {
    set_output "version" "1.2.3-beta+build.456"
    
    assert_file_contains "$GITHUB_OUTPUT" "version=1.2.3-beta+build.456"
}

@test "set_output does nothing when GITHUB_OUTPUT is unset" {
    unset GITHUB_OUTPUT
    run set_output "key" "value"
    assert_exit_code 0
}

# =============================================================================
# write_summary
# =============================================================================

@test "write_summary appends to GITHUB_STEP_SUMMARY" {
    write_summary "## Test Summary"
    write_summary "This is a test"
    
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Test Summary"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "This is a test"
}

@test "write_summary does nothing when GITHUB_STEP_SUMMARY is unset" {
    unset GITHUB_STEP_SUMMARY
    run write_summary "content"
    assert_exit_code 0
}

# =============================================================================
# write_scan_summary
# =============================================================================

@test "write_scan_summary generates markdown table" {
    local results='[
        {"unit_name": "vpc", "passed": true, "high": 0, "medium": 2, "low": 5, "scan_id": "scan-1"},
        {"unit_name": "rds", "passed": false, "high": 1, "medium": 0, "low": 0, "scan_id": "scan-2"}
    ]'
    
    write_scan_summary "$results"
    
    assert_file_contains "$GITHUB_STEP_SUMMARY" "| Unit | Status |"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "vpc"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "rds"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Pass"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Fail"
}

@test "write_scan_summary calculates totals" {
    local results='[
        {"unit_name": "a", "passed": true, "high": 1, "medium": 2, "low": 3, "scan_id": "s1"},
        {"unit_name": "b", "passed": true, "high": 2, "medium": 3, "low": 4, "scan_id": "s2"}
    ]'
    
    write_scan_summary "$results"
    
    # 1+2=3 high, 2+3=5 medium, 3+4=7 low
    assert_file_contains "$GITHUB_STEP_SUMMARY" "3 high"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "5 medium"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "7 low"
}

# =============================================================================
# sort_units_by_dependency
# =============================================================================

@test "sort_units_by_dependency orders units correctly" {
    local units='[
        {"name": "app", "depends_on": ["database"]},
        {"name": "database", "depends_on": []},
        {"name": "frontend", "depends_on": ["app"]}
    ]'
    
    run sort_units_by_dependency "$units"
    
    # database should come before app, app before frontend
    local result="$output"
    local db_pos=$(echo "$result" | jq 'to_entries | .[] | select(.value.name == "database") | .key')
    local app_pos=$(echo "$result" | jq 'to_entries | .[] | select(.value.name == "app") | .key')
    local fe_pos=$(echo "$result" | jq 'to_entries | .[] | select(.value.name == "frontend") | .key')
    
    [[ $db_pos -lt $app_pos ]]
    [[ $app_pos -lt $fe_pos ]]
}

@test "sort_units_by_dependency handles no dependencies" {
    local units='[
        {"name": "a", "depends_on": []},
        {"name": "b", "depends_on": []},
        {"name": "c", "depends_on": []}
    ]'
    
    run sort_units_by_dependency "$units"
    assert_exit_code 0
    
    # Should contain all three
    [[ "$output" =~ '"name": "a"' ]]
    [[ "$output" =~ '"name": "b"' ]]
    [[ "$output" =~ '"name": "c"' ]]
}

@test "sort_units_by_dependency detects circular dependencies" {
    local units='[
        {"name": "a", "depends_on": ["b"]},
        {"name": "b", "depends_on": ["a"]}
    ]'

    run sort_units_by_dependency "$units"
    assert_exit_code 1
}

# =============================================================================
# write_pipeline_summary (v2 format — eval mode and violation counts)
# =============================================================================

@test "write_pipeline_summary v2 includes eval mode column" {
    local results='{
        "stacks": ["my-stack"],
        "environment": "production",
        "unit_results": [
            {
                "unit": "vpc",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0, "eval_mode": "full"},
                "deploy": null
            },
            {
                "unit": "app",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0, "eval_mode": "best_effort"},
                "deploy": null
            }
        ]
    }'

    write_pipeline_summary "$results"

    assert_file_contains "$GITHUB_STEP_SUMMARY" "Eval Mode"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "full"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "best_effort"
}

@test "write_pipeline_summary v2 shows violation counts in status cells" {
    local results='{
        "stacks": ["infra"],
        "environment": "staging",
        "unit_results": [
            {
                "unit": "vpc",
                "scan": {"passed": false, "skipped": false, "violations": 3},
                "evaluation": {"passed": false, "skipped": false, "violations": 5, "eval_mode": "full"},
                "deploy": null
            }
        ]
    }'

    write_pipeline_summary "$results"

    assert_file_contains "$GITHUB_STEP_SUMMARY" "Fail (3)"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Fail (5)"
}

@test "write_pipeline_summary v2 shows best-effort note" {
    local results='{
        "stacks": ["infra"],
        "environment": "dev",
        "unit_results": [
            {
                "unit": "app",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0, "eval_mode": "best_effort"},
                "deploy": null
            }
        ]
    }'

    write_pipeline_summary "$results"

    assert_file_contains "$GITHUB_STEP_SUMMARY" "best_effort"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "upstream remote state"
}

@test "write_pipeline_summary v2 violations summary table" {
    local results='{
        "stacks": ["infra"],
        "environment": "prod",
        "unit_results": [
            {
                "unit": "vpc",
                "scan": {"passed": false, "skipped": false, "violations": 2},
                "evaluation": {"passed": false, "skipped": false, "violations": 4, "eval_mode": "full"},
                "deploy": null
            },
            {
                "unit": "rds",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0, "eval_mode": "full"},
                "deploy": null
            }
        ]
    }'

    write_pipeline_summary "$results"

    # Violations summary table
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Compliance Scan | 2"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "Plan Evaluation | 4"
    # Use grep -F for fixed string match (** is invalid regex)
    grep -qF '**Total** | **6**' "$GITHUB_STEP_SUMMARY"

    # Per-unit breakdown
    grep -qF '**vpc**: 6 violation(s)' "$GITHUB_STEP_SUMMARY"
}

@test "write_pipeline_summary v2 handles all-pass scenario" {
    local results='{
        "stacks": ["infra"],
        "environment": "prod",
        "unit_results": [
            {
                "unit": "vpc",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0, "eval_mode": "full"},
                "deploy": {"success": true, "skipped": false}
            }
        ]
    }'

    write_pipeline_summary "$results"

    assert_file_contains "$GITHUB_STEP_SUMMARY" "All checks passed"
}

@test "write_pipeline_summary v1 legacy format still works" {
    local results='{
        "stack": "my-stack",
        "environment": "production",
        "units": [
            {
                "name": "vpc",
                "scan": {"passed": true, "skipped": false, "violations": 0},
                "evaluation": {"passed": true, "skipped": false, "violations": 0},
                "deploy": {"success": true, "skipped": false}
            }
        ]
    }'

    write_pipeline_summary "$results"

    assert_file_contains "$GITHUB_STEP_SUMMARY" "All checks passed"
    assert_file_contains "$GITHUB_STEP_SUMMARY" "my-stack"
}
