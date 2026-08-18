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
    [[ "${DETECT_ENV_MATCHED}" -eq 0 ]] || return 1
    [[ "${DETECT_ENV_ERROR}" -eq 2 ]] || return 1
    [[ "${DETECT_ENV_NO_MATCH}" -eq 3 ]] || return 1
}

# =============================================================================
# MATCHED (0)
# =============================================================================

@test "matched branch returns MATCHED (0) with the env key on stdout" {
    local out rc=0
    out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
        detect_environment "${CONFIG}" 2>/dev/null) || rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    [[ "${out}" == "production" ]] || return 1
}

# =============================================================================
# NO_MATCH (3) — benign, callers skip
# =============================================================================

@test "unmapped branch returns NO_MATCH (3) with empty stdout" {
    local out rc=0
    out=$(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/feature-x \
        detect_environment "${CONFIG}" 2>/dev/null) || rc=$?
    [[ "${rc}" -eq 3 ]] || return 1
    [[ -z "${out}" ]] || return 1
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
    [[ "${rc}" -eq 2 ]] || return 1
}

@test "missing config file returns ERROR (2)" {
    local rc=0
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
        detect_environment "${BATS_TEST_TMPDIR}/does-not-exist.yml" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
}

@test "undeterminable branch returns ERROR (2)" {
    local rc=0
    GITHUB_EVENT_NAME=push GITHUB_REF= \
        detect_environment "${CONFIG}" >/dev/null 2>&1 || rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
}

# =============================================================================
# Environment names containing a dot
# =============================================================================
# The name used to be spliced into the yq query, so `prod.eu` was read as a
# two-level path and matched nothing. Auto-detection is the reachable path for
# such a name — the action's `environment` input rejects a dot — and there it
# returned NO_MATCH, which the pipeline treats as a benign skip: the stack was
# never scanned and the run still reported success.

_dotted_config() {
    DOTTED="${BATS_TEST_TMPDIR}/dotted.yml"
    cat > "${DOTTED}" <<'EOF'
environments:
  "prod.eu":
    git_ref:
      name: main
      type: branch
EOF
}

@test "dotted name: detect_environment matches it instead of skipping the stack" {
    _dotted_config
    export GITHUB_REF="refs/heads/main"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${DOTTED}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "prod.eu" ]
}

@test "dotted name: validate_environment accepts it" {
    _dotted_config

    run validate_environment "${DOTTED}" "prod.eu"

    [ "${status}" -eq 0 ]
}

@test "dotted name: an environment that is genuinely absent is still not matched" {
    _dotted_config

    run validate_environment "${DOTTED}" "prod.us"

    [ "${status}" -ne 0 ]
}

@test "dotted name: a branch mapping to no environment is still a benign skip" {
    _dotted_config
    export GITHUB_REF="refs/heads/nowhere"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${DOTTED}"

    [ "${status}" -eq "${DETECT_ENV_NO_MATCH}" ]
}

@test "spaced name: an environment name with a space is not split into two" {
    # The key list was iterated with an unquoted expansion, so a name with a
    # space became two names — matching nothing, and inventing environments in
    # the diagnostic listing.
    SPACED="${BATS_TEST_TMPDIR}/spaced.yml"
    cat > "${SPACED}" <<'EOF'
environments:
  "prod eu":
    git_ref:
      name: main
      type: branch
EOF
    export GITHUB_REF="refs/heads/main"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${SPACED}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "prod eu" ]
}

@test "crafted name: a name that is not a plain scalar is not treated as declared" {
    # env() parses its value as YAML, so names like these made yq fail. An
    # unchecked failure left the result empty, which the old comparison read as
    # "declared" — every downstream setting then resolved to its permissive
    # default. These must all be rejected.
    _dotted_config

    local name
    for name in '*' '@' '%YAML' '#c' '`x`' '*a' 'a b'; do
        run validate_environment "${DOTTED}" "${name}"
        [ "${status}" -ne 0 ] || {
            echo "name '${name}' was accepted as a declared environment"
            return 1
        }
    done
}

@test "crafted name: a wildcard does not match every declared environment" {
    # yq's [] indexing globs, so "*" would answer for an environment the caller
    # never named.
    MULTI="${BATS_TEST_TMPDIR}/multi.yml"
    cat > "${MULTI}" <<'EOF'
environments:
  production:
    git_ref: {name: main, type: branch}
  staging:
    git_ref: {name: develop, type: branch}
EOF

    run validate_environment "${MULTI}" '*'

    [ "${status}" -ne 0 ]
}

@test "crafted name: a declared name yq would parse as YAML reads its own settings" {
    # env() parsed its value as YAML, so a declared name like this resolved to
    # nothing and the environment was skipped. strenv() takes it literally.
    CRAFTED="${BATS_TEST_TMPDIR}/crafted.yml"
    cat > "${CRAFTED}" <<'EOF'
environments:
  "&blue":
    git_ref:
      name: main
      type: branch
EOF
    export GITHUB_REF="refs/heads/main"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${CRAFTED}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "&blue" ]
}

@test "crafted name: a declared name containing a wildcard halts detection" {
    # yq matches keys by glob, so this name reads its own settings and prod1's
    # together. Every setting then resolves to its permissive default, so stop.
    GLOBBED="${BATS_TEST_TMPDIR}/globbed.yml"
    cat > "${GLOBBED}" <<'EOF'
environments:
  prod1:
    git_ref: {name: main, type: branch}
  "prod?":
    git_ref: {name: main, type: branch}
EOF
    export GITHUB_REF="refs/heads/main"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${GLOBBED}"

    [ "${status}" -eq "${DETECT_ENV_ERROR}" ]
}

@test "crafted name: a wildcard name is rejected even when it is declared" {
    GLOBBED="${BATS_TEST_TMPDIR}/globbed.yml"
    cat > "${GLOBBED}" <<'EOF'
environments:
  "prod*":
    git_ref: {name: main, type: branch}
  production:
    git_ref: {name: release, type: branch}
EOF

    run validate_environment "${GLOBBED}" 'prod*'

    [ "${status}" -ne 0 ]
}

@test "empty environments map: no environment is invented and no error leaks" {
    EMPTY="${BATS_TEST_TMPDIR}/empty.yml"
    printf 'environments: {}\n' > "${EMPTY}"
    export GITHUB_REF="refs/heads/main"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${EMPTY}"

    [ "${status}" -eq "${DETECT_ENV_NO_MATCH}" ]
    # A here-string over an empty list still runs the loop once, which listed an
    # environment with an empty name and printed raw yq errors alongside it.
    [[ "${output}" != *"  - :"* ]] || return 1
    [[ "${output}" != *"Error:"* ]] || return 1
}

@test "dotted name: the declared git_ref type is read, not defaulted to branch" {
    PATTERNED="${BATS_TEST_TMPDIR}/patterned.yml"
    cat > "${PATTERNED}" <<'EOF'
environments:
  "prod.eu":
    git_ref:
      name: "release/.*"
      type: pattern
EOF
    export GITHUB_REF="refs/heads/release/1"
    export GITHUB_EVENT_NAME="push"

    run detect_environment "${PATTERNED}"

    [ "${status}" -eq 0 ]
    [ "${output}" = "prod.eu" ]
}
