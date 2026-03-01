#!/usr/bin/env bats
# =============================================================================
# Tests for aggregation.sh - Multi-unit result aggregation
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "$TEST_TEMP"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    touch "$GITHUB_OUTPUT"
    
    mock_iltero
    source_iltero_core "utils.sh"
    source_iltero_core "aggregation.sh"
}

teardown() {
    rm -rf "$TEST_TEMP"
}

# =============================================================================
# check_batch_violations (with mocked iltero)
# =============================================================================

@test "check_batch_violations returns 0 when no violations" {
    # Override mock to return no violations
    cat > "${TEST_TEMP}/iltero" << 'EOF'
#!/bin/bash
echo '{"has_violations": false, "failed_scans": 0}'
EOF
    chmod +x "${TEST_TEMP}/iltero"
    
    run check_batch_violations "scan-1,scan-2,scan-3"
    assert_exit_code 0
}

@test "check_batch_violations returns 1 when violations found" {
    cat > "${TEST_TEMP}/iltero" << 'EOF'
#!/bin/bash
echo '{"has_violations": true, "failed_scans": 0}'
EOF
    chmod +x "${TEST_TEMP}/iltero"
    
    run check_batch_violations "scan-1,scan-2"
    assert_exit_code 1
}

@test "check_batch_violations returns 2 when scans failed" {
    cat > "${TEST_TEMP}/iltero" << 'EOF'
#!/bin/bash
echo '{"has_violations": false, "failed_scans": 2}'
EOF
    chmod +x "${TEST_TEMP}/iltero"
    
    run check_batch_violations "scan-1,scan-2"
    assert_exit_code 2
}

@test "check_batch_violations requires scan_ids argument" {
    run check_batch_violations ""
    assert_exit_code 2
}

# =============================================================================
# aggregate_scan_results
# =============================================================================

@test "aggregate_scan_results creates output file" {
    cat > "${TEST_TEMP}/iltero" << 'EOF'
#!/bin/bash
echo '{"summary": {"total": 10, "high": 2, "medium": 5, "low": 3}}'
EOF
    chmod +x "${TEST_TEMP}/iltero"
    
    local output_file="${TEST_TEMP}/aggregate.json"
    run aggregate_scan_results "scan-1,scan-2" "$output_file"
    
    [[ -f "$output_file" ]]
}

@test "aggregate_scan_results logs severity breakdown" {
    cat > "${TEST_TEMP}/iltero" << 'EOF'
#!/bin/bash
echo '{"summary": {"total": 15, "high": 3, "medium": 7, "low": 5}}'
EOF
    chmod +x "${TEST_TEMP}/iltero"
    
    run aggregate_scan_results "scan-1"
    # The aggregation output should contain violation counts
    assert_output_contains "Aggregat"
}
