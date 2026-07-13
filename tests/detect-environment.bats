#!/usr/bin/env bats
# =============================================================================
# Tests for detect-environment.sh — the detect_environment() exit-code contract
# =============================================================================
# Verifies the three-way partition: MATCHED (0), NO_MATCH (3, benign skip),
# ERROR (2, hard fail). The distinction is what lets callers skip an unmapped
# branch while failing loud on a malformed config.

load 'test_helper'

setup() {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    source "${PROJECT_ROOT}/scripts/detect-environment.sh"

    CONFIG="${BATS_TEST_TMPDIR}/config.yml"
    cat > "${CONFIG}" <<'EOF'
environments:
  production:
    git_ref:
      name: main
      type: branch
  staging:
    git_ref:
      name: develop
      type: branch
EOF
}

# =============================================================================
# Contract constants
# =============================================================================

@test "exit-code constants have the contract values" {
    [[ "${DETECT_ENV_MATCHED}" -eq 0 ]]
    [[ "${DETECT_ENV_ERROR}" -eq 2 ]]
    [[ "${DETECT_ENV_NO_MATCH}" -eq 3 ]]
}

# =============================================================================
# MATCHED (0)
# =============================================================================

@test "matched branch returns MATCHED (0) with the env key on stdout" {
    local out rc=0
    out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
        detect_environment "${CONFIG}" 2>/dev/null) || rc=$?
    [[ "${rc}" -eq 0 ]]
    [[ "${out}" == "production" ]]
}

# =============================================================================
# NO_MATCH (3) — benign, callers skip
# =============================================================================

@test "unmapped branch returns NO_MATCH (3) with empty stdout" {
    local out rc=0
    out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/feature-x \
        detect_environment "${CONFIG}" 2>/dev/null) || rc=$?
    [[ "${rc}" -eq 3 ]]
    [[ -z "${out}" ]]
}

# =============================================================================
# ERROR (2) — hard fail
# =============================================================================

@test "malformed config returns ERROR (2), not NO_MATCH" {
    local bad="${BATS_TEST_TMPDIR}/bad.yml"
    printf 'environments:\n  prod: {name: main\n' > "${bad}"
    local rc=0
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
        detect_environment "${bad}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 2 ]]
}

@test "missing config file returns ERROR (2)" {
    local rc=0
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
        detect_environment "${BATS_TEST_TMPDIR}/does-not-exist.yml" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 2 ]]
}

@test "undeterminable branch returns ERROR (2)" {
    local rc=0
    GITHUB_EVENT_NAME=push GITHUB_REF= \
        detect_environment "${CONFIG}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 2 ]]
}
