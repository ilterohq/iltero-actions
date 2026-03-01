#!/usr/bin/env bats
# =============================================================================
# Tests for results.sh - Per-stack result accumulation
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "$TEST_TEMP"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "$GITHUB_OUTPUT"
    touch "$GITHUB_STEP_SUMMARY"

    # Change to temp dir so .iltero/ is created there
    cd "$TEST_TEMP"

    source_iltero_core "results.sh"
}

teardown() {
    rm -rf "$TEST_TEMP"
}

# =============================================================================
# init_stack_results
# =============================================================================

@test "init_stack_results creates results.json" {
    init_stack_results "my-stack"

    [[ -f "${TEST_TEMP}/.iltero/my-stack/results.json" ]]
    local content
    content=$(cat "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$content" == "[]" ]]
}

@test "init_stack_results creates separate files per stack" {
    init_stack_results "stack-a"
    init_stack_results "stack-b"

    [[ -f "${TEST_TEMP}/.iltero/stack-a/results.json" ]]
    [[ -f "${TEST_TEMP}/.iltero/stack-b/results.json" ]]
}

@test "init_stack_results resets existing results" {
    init_stack_results "my-stack"
    echo '[{"unit":"old"}]' > "${TEST_TEMP}/.iltero/my-stack/results.json"
    init_stack_results "my-stack"

    local content
    content=$(cat "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$content" == "[]" ]]
}

# =============================================================================
# append_unit_result
# =============================================================================

@test "append_unit_result adds entry to results" {
    init_stack_results "my-stack"

    local scan_json='{"passed": true, "violations": 0}'
    local eval_json='{"passed": true, "violations": 0, "eval_mode": "full"}'

    append_unit_result "my-stack" "vpc" "$scan_json" "$eval_json" "null"

    local count
    count=$(jq 'length' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$count" -eq 1 ]]

    local unit
    unit=$(jq -r '.[0].unit' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$unit" == "vpc" ]]
}

@test "append_unit_result accumulates multiple units" {
    init_stack_results "my-stack"

    append_unit_result "my-stack" "vpc" '{"passed": true, "violations": 0}' "null" "null"
    append_unit_result "my-stack" "rds" '{"passed": false, "violations": 3}' "null" "null"
    append_unit_result "my-stack" "app" '{"passed": true, "violations": 0}' "null" "null"

    local count
    count=$(jq 'length' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$count" -eq 3 ]]

    # Check second unit has violations
    local violations
    violations=$(jq '.[1].scan.violations' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$violations" -eq 3 ]]
}

@test "append_unit_result handles empty strings as null" {
    init_stack_results "my-stack"

    append_unit_result "my-stack" "vpc" "" "" ""

    local scan_val
    scan_val=$(jq '.[0].scan' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$scan_val" == "null" ]]
}

@test "append_unit_result preserves eval_mode field" {
    init_stack_results "my-stack"

    local eval_json='{"passed": true, "violations": 0, "eval_mode": "best_effort"}'
    append_unit_result "my-stack" "app" "null" "$eval_json" "null"

    local eval_mode
    eval_mode=$(jq -r '.[0].evaluation.eval_mode' "${TEST_TEMP}/.iltero/my-stack/results.json")
    [[ "$eval_mode" == "best_effort" ]]
}

# =============================================================================
# get_stack_results
# =============================================================================

@test "get_stack_results returns accumulated results" {
    init_stack_results "my-stack"
    append_unit_result "my-stack" "vpc" '{"passed": true, "violations": 0}' "null" "null"
    append_unit_result "my-stack" "rds" '{"passed": false, "violations": 2}' "null" "null"

    local results
    results=$(get_stack_results "my-stack")

    local count
    count=$(echo "$results" | jq 'length')
    [[ "$count" -eq 2 ]]
}

@test "get_stack_results returns empty array for missing stack" {
    init_stack_results "other"

    local results
    results=$(get_stack_results "nonexistent")

    [[ "$results" == "[]" ]]
}

# =============================================================================
# get_all_results
# =============================================================================

@test "get_all_results aggregates across stacks" {
    init_stack_results "stack-a"
    init_stack_results "stack-b"

    append_unit_result "stack-a" "vpc" '{"passed": true, "violations": 0}' "null" "null"
    append_unit_result "stack-a" "rds" '{"passed": true, "violations": 0}' "null" "null"
    append_unit_result "stack-b" "app" '{"passed": false, "violations": 1}' "null" "null"

    local results
    results=$(get_all_results)

    local count
    count=$(echo "$results" | jq 'length')
    [[ "$count" -eq 3 ]]
}

@test "get_all_results returns empty array when no results" {
    # Don't initialize anything
    ILTERO_RESULTS_BASE=""

    local results
    results=$(get_all_results)

    [[ "$results" == "[]" ]]
}
