#!/usr/bin/env bats
# =============================================================================
# Tests for runtime.sh - Drift detection and runtime compliance
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"

    # runtime.sh has `set -euo pipefail` at module scope, so an undefined
    # function (e.g. `log_warn` instead of `log_warning`) aborts the
    # subshell at command_not_found. These tests guard against regressions.
    source "${LIB_DIR}/logging.sh"
    export ILTERO_LOGGING_SOURCED=1
    source "${CORE_DIR}/utils.sh"
    source "${CORE_DIR}/ci-credential.sh"
    source "${CORE_DIR}/runtime.sh"
}

teardown() {
    rm -rf "${TEST_TEMP}"
    if [[ "${PATH}" == "${TEST_TEMP}:"* ]]; then
        export PATH="${PATH#"${TEST_TEMP}:"}"
    fi
}

# Install a fake `iltero` that emits the configured drift JSON on `scan drift`.
_mock_iltero_drift() {
    local drift_count="$1"
    local mock="${TEST_TEMP}/iltero"
    cat > "${mock}" <<EOF
#!/bin/bash
case "\$2" in
    drift)
        cat <<'JSON'
{"drift_count": ${drift_count}, "drifted_resources": [{"resource_type":"aws_s3_bucket","resource_name":"x","drift_type":"modified"}]}
JSON
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "${mock}"
    export PATH="${TEST_TEMP}:${PATH}"
}

@test "detect_drift returns 0 when no drift" {
    _mock_iltero_drift 0

    run detect_drift "unit-x"
    assert_exit_code 0
}

@test "detect_drift returns 1 when drift found and does not crash on log_warning" {
    # Regression: a typo of log_warning -> log_warn would abort the function
    # under set -euo pipefail with command_not_found (exit 127).
    _mock_iltero_drift 3

    run detect_drift "unit-x"
    assert_exit_code 1
    assert_output_contains "Drift detected: 3"
}
