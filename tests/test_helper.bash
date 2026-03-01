#!/usr/bin/env bash
# =============================================================================
# Test Helper - Common setup for all bats tests
# =============================================================================

# Get the project root directory
export PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
export LIB_DIR="${PROJECT_ROOT}/scripts/lib"
export CORE_DIR="${LIB_DIR}/iltero-core"

# Temp directory for test artifacts
export TEST_TEMP="${BATS_TEST_TMPDIR:-/tmp/bats-test-$$}"

# =============================================================================
# Setup/Teardown
# =============================================================================

# Run before each test
setup() {
    mkdir -p "$TEST_TEMP"
    
    # Reset sourcing flags for fresh test environment
    unset ILTERO_UTILS_SOURCED
    unset ILTERO_LOGGING_SOURCED
    unset ILTERO_CORE_SOURCED
    unset ILTERO_VALIDATION_SOURCED
    
    # Mock GITHUB_OUTPUT for testing
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    touch "$GITHUB_OUTPUT"
    
    # Mock GITHUB_STEP_SUMMARY for testing
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "$GITHUB_STEP_SUMMARY"
}

# Run after each test
teardown() {
    rm -rf "$TEST_TEMP"
}

# =============================================================================
# Helper Functions
# =============================================================================

# Source iltero-core modules (with mocked logging)
source_iltero_core() {
    # Source logging first with mocked output
    source "${LIB_DIR}/logging.sh"
    export ILTERO_LOGGING_SOURCED=1
    
    # Always source utils first (provides exit codes)
    source "${CORE_DIR}/utils.sh"
        # Source requested module or all
    if [[ -n "${1:-}" ]]; then
        source "${CORE_DIR}/$1"
    else
        source "${CORE_DIR}/index.sh"
    fi
}

# Assert file contains text
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    
    if ! grep -q "$pattern" "$file"; then
        echo "Expected file '$file' to contain: $pattern"
        echo "Actual content:"
        cat "$file"
        return 1
    fi
}

# Assert output contains text
assert_output_contains() {
    local pattern="$1"
    
    if [[ ! "$output" =~ $pattern ]]; then
        echo "Expected output to contain: $pattern"
        echo "Actual output: $output"
        return 1
    fi
}

# Assert exit code
assert_exit_code() {
    local expected="$1"
    
    if [[ "$status" -ne "$expected" ]]; then
        echo "Expected exit code $expected, got $status"
        echo "Output: $output"
        return 1
    fi
}

# Create a mock terraform unit for testing
create_mock_unit() {
    local unit_dir="${TEST_TEMP}/${1:-test-unit}"
    mkdir -p "$unit_dir"
    
    touch "$unit_dir/main.tf"
    touch "$unit_dir/providers.tf"
    touch "$unit_dir/versions.tf"
    touch "$unit_dir/backend.tf"
    
    echo "$unit_dir"
}

# Mock iltero CLI command
mock_iltero() {
    local mock_script="${TEST_TEMP}/iltero"
    cat > "$mock_script" << 'EOF'
#!/bin/bash
# Mock iltero CLI for testing
echo '{"run_id": "mock-run-123", "scan_id": "mock-scan-456", "passed": true, "violations_count": 0}'
EOF
    chmod +x "$mock_script"
    export PATH="${TEST_TEMP}:$PATH"
}
