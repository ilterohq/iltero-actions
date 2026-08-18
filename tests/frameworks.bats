#!/usr/bin/env bats
# =============================================================================
# Tests for compliance frameworks — config.yml → --frameworks on the CLI
# =============================================================================
# A stack names the compliance frameworks it must be checked against, per
# environment, in its config.yml. That list has to survive the whole way to the
# Iltero CLI as a single `--frameworks A,B,C` argument. If it goes missing the
# scan still succeeds — against the wrong policy set — so these tests assert the
# exact arguments the CLI receives rather than just an exit code.
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    export GITHUB_ENV="${TEST_TEMP}/github_env"
    touch "${GITHUB_OUTPUT}" "${GITHUB_STEP_SUMMARY}" "${GITHUB_ENV}"

    unset ILTERO_RESULTS_SOURCED
    unset ILTERO_RESULTS_BASE

    cd "${TEST_TEMP}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
}

# =============================================================================
# Helpers
# =============================================================================

# Writes a config.yml whose production environment carries <frameworks-yaml> as
# its compliance.frameworks value. Pass the literal YAML so a test can supply a
# deliberately wrong shape (a plain string, a map, …).
_write_config() {
    local frameworks_yaml="$1"
    local config="${TEST_TEMP}/config.yml"
    cat > "${config}" << EOF
stack:
  id: 0b278217-a809-465a-b9df-00eda8414cb8
  name: demo
  slug: demo
environments:
  production:
    git_ref:
      type: branch
      name: main
    compliance:
      scan_types: [static]
${frameworks_yaml}
EOF
    printf '%s' "${config}"
}

# Iltero CLI stub that records its arguments ONE PER LINE, so a value
# containing a space is still visible as a single argument.
_stub_cli() {
    export ILTERO_ARGV_FILE="${TEST_TEMP}/cli_argv"
    : > "${ILTERO_ARGV_FILE}"

    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "${ILTERO_ARGV_FILE}"
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && echo '{"run_id":"r1","scan_id":"s1","violations_count":0,"summary":{"total_checks":1,"passed":1,"failed":0,"critical":0,"high":0,"medium":0,"low":0}}' > "${of}"
echo '{}'
exit 0
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
}

# Terraform stub that produces a plan with one resource change.
_stub_terraform() {
    cat > "${TEST_TEMP}/terraform" << 'STUB'
#!/bin/bash
case "${1}" in
    init) exit 0 ;;
    plan) touch "${PWD}/tfplan"; exit 0 ;;
    show) echo '{"resource_changes":[{"address":"aws_s3_bucket.x","mode":"managed","change":{"actions":["create"]}}]}'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${TEST_TEMP}/terraform"
}

_stub_unit() {
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit/main.tf" "${TEST_TEMP}/unit/versions.tf" "${TEST_TEMP}/unit/backend.tf"
    printf 'provider "aws" {}\n' > "${TEST_TEMP}/unit/providers.tf"
}

# True when the recorded argument list contains <value> as a whole argument.
_argv_has() {
    grep -Fxq -- "$1" "${ILTERO_ARGV_FILE}"
}

# Prints the argument that directly follows <flag> in the recorded list.
_argv_value_after() {
    local flag="$1"
    awk -v flag="${flag}" 'prev == flag { print; exit } { prev = $0 }' "${ILTERO_ARGV_FILE}"
}

# =============================================================================
# Reading config.yml — the shape of `frameworks` decides pass or hard failure
# =============================================================================

@test "frameworks: a list becomes one comma-separated value" {
    local config
    config=$(_write_config "      frameworks: [SOC2, ISO27001, CIS-AWS]")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -eq 0 ]
    [ "${output}" = "SOC2,ISO27001,CIS-AWS" ]
}

@test "frameworks: a single value written without brackets is a hard error" {
    # `frameworks: SOC2` instead of `frameworks: [SOC2]`. Before, this produced
    # an empty list and the scan passed having checked nothing.
    local config
    config=$(_write_config "      frameworks: SOC2")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"compliance.frameworks"* ]] || return 1
    [[ "${output}" == *"must be a list"* ]] || return 1
    [[ "${output}" == *"[SOC2, ISO27001]"* ]] || return 1
}

@test "frameworks: a map value is a hard error" {
    local config
    config=$(_write_config "      frameworks:
        soc2: true")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a list"* ]] || return 1
}

@test "frameworks: a list with a blank entry is a hard error" {
    # An empty entry would otherwise be sent as an empty framework name.
    local config
    config=$(_write_config "      frameworks: [SOC2, \"\"]")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"non-empty framework names"* ]] || return 1
}

@test "frameworks: a numeric entry is a hard error" {
    # `frameworks: [27001]` reads as a number, not the name of a framework.
    local config
    config=$(_write_config "      frameworks: [SOC2, 27001]")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"non-empty framework names"* ]] || return 1
}

@test "frameworks: an absent key yields nothing and succeeds" {
    local config
    config=$(_write_config "      block_on_violations: true")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "frameworks: an empty list yields nothing and succeeds" {
    local config
    config=$(_write_config "      frameworks: []")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "frameworks: an unknown environment yields nothing and succeeds" {
    local config
    config=$(_write_config "      frameworks: [SOC2]")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "staging"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "frameworks: a missing config file is an error" {
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${TEST_TEMP}/absent.yml" "production"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found"* ]] || return 1
}

@test "frameworks: a name containing a space is preserved" {
    local config
    config=$(_write_config "      frameworks: [\"CIS AWS\", SOC2]")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -eq 0 ]
    [ "${output}" = "CIS AWS,SOC2" ]
}

@test "frameworks: no default is invented when the key is absent" {
    # There is deliberately no client-side guess (e.g. "this looks like AWS, so
    # CIS-AWS"). Iltero decides which policies apply from the stack's own
    # registration, which knows the real provider.
    local config
    config=$(_write_config "      block_on_violations: true")
    source_iltero_core "compliance-config.sh"

    run read_environment_frameworks "${config}" "production"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"CIS"* ]] || return 1
}

# =============================================================================
# Static scan — what actually reaches the CLI
# =============================================================================

@test "scan: configured frameworks arrive as a single --frameworks argument" {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "SOC2,ISO27001,CIS-AWS" "" || true

    _argv_has "--frameworks"
    [ "$(_argv_value_after '--frameworks')" = "SOC2,ISO27001,CIS-AWS" ]
}

@test "scan: a framework name containing a space stays one argument" {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "CIS AWS,SOC2" "" || true

    [ "$(_argv_value_after '--frameworks')" = "CIS AWS,SOC2" ]
}

@test "scan: no frameworks means no --frameworks argument" {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "" "" || true

    run _argv_has "--frameworks"
    [ "${status}" -ne 0 ]
}

@test "scan: config.yml path arrives as --config-path" {
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    local config
    config=$(_write_config "      frameworks: [SOC2]")
    source_iltero_core "scanning.sh"

    run_static_scan "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "SOC2" "${config}" || true

    [ "$(_argv_value_after '--config-path')" = "${config}" ]
}

# =============================================================================
# Plan evaluation — what actually reaches the CLI
# =============================================================================

@test "evaluation: configured frameworks arrive as a single --frameworks argument" {
    export PREVIEW_MODE="false"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core
    _stub_terraform
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "" "[]" "SOC2,ISO27001,CIS-AWS" || true

    [ "$(_argv_value_after '--frameworks')" = "SOC2,ISO27001,CIS-AWS" ]
}

@test "evaluation: no frameworks means no --frameworks argument" {
    export PREVIEW_MODE="false"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core
    _stub_terraform
    init_remote_state_tracking "test-stack"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "" "[]" "" || true

    run _argv_has "--frameworks"
    [ "${status}" -ne 0 ]
}

# =============================================================================
# CLI binary resolution
# =============================================================================
# setup/action.yml resolves the CLI to an absolute path and publishes it as
# ILTERO_CLI_BIN so later steps do not depend on PATH lookup. Every command that
# invokes the CLI must honour it.

@test "evaluation: both CLI invocations honour ILTERO_CLI_BIN" {
    export PREVIEW_MODE="false"
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    _stub_cli
    _stub_unit
    source_iltero_core
    _stub_terraform
    init_remote_state_tracking "test-stack"

    # Move the stub off PATH and point ILTERO_CLI_BIN at it. Anything still
    # calling a bare `iltero` now records nothing.
    mkdir -p "${TEST_TEMP}/offpath"
    mv "${TEST_TEMP}/iltero" "${TEST_TEMP}/offpath/iltero-cli-under-test"
    export ILTERO_CLI_BIN="${TEST_TEMP}/offpath/iltero-cli-under-test"

    run_plan_evaluation "${TEST_TEMP}/unit" "stack-123" "vpc" "production" "high" "" "" "[]" "SOC2" || true

    _argv_has "evaluation"
    _argv_has "generate-source-map"
}

# =============================================================================
# Argument-count guard for every call site
# =============================================================================
# These two functions take their inputs positionally, and the framework list is
# the last one. Stopping short simply omits it — no error, no wrong value, just
# a scan against the wrong policy set. This guard compares each call site
# against the number of positional inputs the function declares.

# Highest positional input a function reads ($1, $2, … ${10}).
_declared_arity() {
    local file="$1" fn="$2"
    awk -v fn="${fn}" '
        index($0, fn "() {") == 1 { inside = 1; next }
        inside && /^}/ { exit }
        inside { print }
    ' "${file}" | grep -oE '\$\{?[0-9]+' | tr -d '${' | sort -n | tail -1
}

# Number of arguments a call passes. Every call site quotes each argument, so
# counting quote characters counts arguments.
_call_arity() {
    local call="$1" fn="$2"
    local args="${call#*${fn}}"
    local quotes
    quotes=$(printf '%s' "${args}" | tr -cd '"' | wc -c | tr -d ' ')
    echo $(( quotes / 2 ))
}

# Every place the shipped code calls <fn>, excluding the tests themselves.
_call_sites() {
    local fn="$1"
    grep -rE --include='*.sh' --include='*.yml' "^[[:space:]]*${fn} +\"" "${PROJECT_ROOT}" 2>/dev/null \
        | grep -v "/tests/"
}

_assert_all_call_sites_full_arity() {
    local fn="$1" definition="$2"
    local expected
    expected=$(_declared_arity "${definition}" "${fn}")
    [ -n "${expected}" ]
    [ "${expected}" -gt 0 ]

    local sites=0 line
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        sites=$(( sites + 1 ))
        local actual
        actual=$(_call_arity "${line}" "${fn}")
        if [ "${actual}" -ne "${expected}" ]; then
            echo "call site passes ${actual} arguments, ${fn} declares ${expected}: ${line}"
            return 1
        fi
    done < <(_call_sites "${fn}")

    # A guard that found nothing to check would pass silently.
    [ "${sites}" -gt 0 ]
}

@test "arity: every run_static_scan call site passes all declared arguments" {
    _assert_all_call_sites_full_arity "run_static_scan" "${CORE_DIR}/scanning.sh"
}

@test "arity: every run_plan_evaluation call site passes all declared arguments" {
    _assert_all_call_sites_full_arity "run_plan_evaluation" "${CORE_DIR}/evaluation.sh"
}

# =============================================================================
# Whole-pipeline runs — greenfield and brownfield
# =============================================================================
# The pipeline script uses associative arrays, which need bash 4 or newer. CI
# runs bash 5; a developer machine on bash 3 skips these.

_require_modern_bash() {
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        skip "run-pipeline.sh requires bash 4+ (this shell is ${BASH_VERSION})"
    fi
}

# Builds a repository the pipeline can run against and cds into it.
# Args: $1=greenfield|brownfield  $2=frameworks YAML line(s)
_setup_pipeline_repo() {
    local kind="$1" frameworks_yaml="$2" env_name="${3:-production}"
    local repo="${TEST_TEMP}/repo"

    _stub_cli
    _stub_terraform

    local unit_dir
    if [ "${kind}" = "greenfield" ]; then
        unit_dir="${repo}/infra/stacks/demo/units/network"
    else
        unit_dir="${repo}/terraform"
    fi
    mkdir -p "${unit_dir}"
    touch "${unit_dir}/main.tf" "${unit_dir}/versions.tf" "${unit_dir}/backend.tf"
    printf 'provider "aws" {}\n' > "${unit_dir}/providers.tf"

    local config
    if [ "${kind}" = "greenfield" ]; then
        mkdir -p "${repo}/.iltero/stacks/demo"
        config="${repo}/.iltero/stacks/demo/config.yml"
    else
        mkdir -p "${repo}/.iltero"
        config="${repo}/.iltero/config.yml"
    fi

    cat > "${config}" << EOF
stack:
  id: 0b278217-a809-465a-b9df-00eda8414cb8
  name: demo
  slug: demo
  type: attached
  terraform_working_directory: terraform
environments:
  "${env_name}":
    git_ref:
      type: branch
      name: main
    compliance:
      scan_types: [static]
${frameworks_yaml}
infrastructure_units:
  - name: network
    path: units/network
    enabled: true
EOF

    export MODE="scan"
    export MANUAL_STACK="demo"
    export ENVIRONMENT_OVERRIDE="${env_name}"
    export ILTERO_TOKEN="test-token"
    if [ "${kind}" = "greenfield" ]; then
        export PIPELINE_MODE="greenfield"
        export STACKS_PATH="infra/stacks"
        export STACKS_CONFIG=".iltero/stacks"
    else
        export PIPELINE_MODE="brownfield"
        export STACKS_CONFIG=".iltero"
        unset STACKS_PATH
    fi

    cd "${repo}"
}

@test "pipeline (greenfield): three configured frameworks reach the CLI" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2, ISO27001, CIS-AWS]"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "$(_argv_value_after '--frameworks')" = "SOC2,ISO27001,CIS-AWS" ]
}

@test "pipeline (brownfield): three configured frameworks reach the CLI" {
    _require_modern_bash
    _setup_pipeline_repo brownfield "      frameworks: [SOC2, ISO27001, CIS-AWS]"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "$(_argv_value_after '--frameworks')" = "SOC2,ISO27001,CIS-AWS" ]
}

@test "pipeline (greenfield): a single value written without brackets fails the run" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: SOC2"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a list"* ]] || return 1
    # It must not have scanned anything on the way to failing.
    run _argv_has "--frameworks"
    [ "${status}" -ne 0 ]
}

@test "pipeline (brownfield): a single value written without brackets fails the run" {
    _require_modern_bash
    _setup_pipeline_repo brownfield "      frameworks: SOC2"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a list"* ]] || return 1
}

@test "pipeline (greenfield): an absent frameworks key invents no default" {
    _require_modern_bash
    # A provider hint in the config must not be turned into a framework guess.
    _setup_pipeline_repo greenfield "      block_on_violations: true
    cloud:
      provider: aws"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    run _argv_has "--frameworks"
    [ "${status}" -ne 0 ]
}

# =============================================================================
# Gate wiring — only findings are waivable, and only via the real call sites
# =============================================================================
# These drive run-pipeline.sh end to end. Unit tests of the verdict helper pass
# even if both call sites stop calling it; these do not.

# CLI stub that exits with a chosen code and optionally writes results.
# Args: $1=exit code  $2="results" to write a usable results file
_stub_cli_exit() {
    export STUB_EXIT="${1}"
    export STUB_WRITE_RESULTS="${2:-none}"
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
if [[ "${STUB_WRITE_RESULTS}" == "results" && -n "${of}" ]]; then
    echo '{"run_id":"r1","scan_id":"s1","violations_count":2,"violations":[{"severity":"critical"},{"severity":"high"}]}' > "${of}"
fi
exit "${STUB_EXIT}"
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero"
}

@test "pipeline: an infra error reports no verdict, not zero findings" {
    # NOTE: this cannot exercise the waiver itself. block_on_violations is read
    # with `yq ... // true`, and yq's `//` treats boolean false as absent, so the
    # setting resolves to "true" for every workspace and the waiver branch is
    # currently unreachable from config.yml. The waiver rule itself is covered in
    # tests/scanning.bats against apply_static_scan_verdict.
    _require_modern_bash
    _setup_pipeline_repo greenfield "      block_on_violations: false"
    _stub_cli_exit 3 none

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no compliance verdict"* ]] || return 1
    [[ "${output}" != *"0 violation(s) detected"* ]] || return 1
}

@test "pipeline: an infra error blocks the deploy gate" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      block_on_violations: false"
    _stub_cli_exit 4 none

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -ne 0 ]
    grep -q "deployment_ready=false" "${GITHUB_OUTPUT}"
    grep -q "static_scan_passed=false" "${GITHUB_OUTPUT}"
}

@test "pipeline: a clean scan still passes" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]"
    _stub_cli_exit 0 results

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -eq 0 ]
    grep -q "static_scan_passed=true" "${GITHUB_OUTPUT}"
}

@test "pipeline: the unit result records the scan status" {
    # Pins the producer→renderer contract: the pipeline must emit `status`, not
    # just derive it internally.
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]"
    _stub_cli_exit 3 none

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    grep -q '"status":"infra_error"' "${GITHUB_OUTPUT}" \
        || grep -q '"status": "infra_error"' "${GITHUB_OUTPUT}"
}

# =============================================================================
# CLI resolution — every invocation goes through ILTERO_CLI_BIN
# =============================================================================

@test "cli-resolution: no shipped code invokes a bare iltero" {
    # Structural guard so a bare invocation cannot reappear. Quoted text and
    # comments are stripped first, so a log message naming a command is not
    # mistaken for one — and the canonical "${ILTERO_CLI_BIN:-iltero}" form is
    # itself quoted, so it is removed too. Any subcommand or flag counts, not
    # a fixed list: the next one added must be caught as well.
    local files hits
    files=$( { find "${PROJECT_ROOT}/scripts" -name '*.sh' -type f
               find "${PROJECT_ROOT}" -maxdepth 3 -name 'action.yml' -type f
               find "${PROJECT_ROOT}/examples" "${PROJECT_ROOT}/.github/workflows" \
                    \( -name '*.yml' -o -name '*.yaml' \) -type f
             } 2>/dev/null | grep -v '/tests/' | sort -u)

    # A floor, not just non-empty: either half of the list above could vanish
    # after a rename and the guard would still pass having scanned nothing on
    # that half. The repo has ~38 such files; 30 leaves room to delete a few.
    local file_count
    file_count=$(printf '%s\n' "${files}" | grep -c . || true)
    if [ "${file_count}" -lt 30 ]; then
        echo "guard scanned only ${file_count} files — expected at least 30; the file list is probably broken"
        return 1
    fi

    hits=$(printf '%s\n' "${files}" | tr '\n' '\0' | xargs -0 awk '
        FNR == 1 { buf = "" }
        {
            buf = buf $0
            if (sub(/\\$/, "", buf)) next
            line = buf; buf = ""
            gsub(/"[^"]*"/, "", line)
            gsub(/\047[^\047]*\047/, "", line)
            sub(/#.*$/, "", line)
            if (line ~ /(^|[^\/A-Za-z_.-])iltero[ \t]+[-a-zA-Z]/)
                printf "%s:%d: %s\n", FILENAME, FNR, $0
        }')

    if [ -n "${hits}" ]; then
        echo "bare iltero invocation(s) found — use \"\${ILTERO_CLI_BIN:-iltero}\":"
        echo "${hits}"
        return 1
    fi
}

@test "dotted environment: no shipped code reads an environment by name unsafely" {
    # Structural guard over three ways this has gone wrong:
    #   .environments.${name}    — splicing reads a dotted name as a two-level
    #                              path, so the value silently defaults
    #   .environments["${name}"] — same splice, bracket spelling
    #   .environments[env(...)]  — env() parses its value as YAML, so a name
    #                              that is not a plain scalar resolves to nothing
    # The safe form is strenv(), which takes the name literally.
    #
    # Line continuations are joined first: per-environment reads in this repo
    # span two lines, so a regression in that style would be invisible to a
    # line-at-a-time match. The leading dot is the signature — log messages
    # naming the same key path have no dot before "environments".
    #
    # Composite actions are covered too: they run their own script bodies, and a
    # guard over scripts/ alone would not see a regression there.
    local files hits
    files=$({
        find "${PROJECT_ROOT}/scripts" -name '*.sh' -type f
        find "${PROJECT_ROOT}" -maxdepth 2 -name 'action.yml' -type f
        find "${PROJECT_ROOT}/examples" "${PROJECT_ROOT}/.github/workflows" \
            -name '*.yml' -type f 2>/dev/null
    } | sort -u)
    # Floor: an empty or truncated file list would make every assertion below
    # pass against nothing.
    [ "$(printf '%s\n' "${files}" | grep -c .)" -ge 40 ] || return 1

    hits=$(printf '%s\n' "${files}" | tr '\n' '\0' | xargs -0 awk '
        FNR == 1 { buf = ""; start = 0 }
        {
            if (buf == "") start = FNR
            buf = buf $0
            if (sub(/\\$/, "", buf)) next
            if (buf ~ /\.environments\.\$\{/ ||
                buf ~ /\.environments\[[^]]*\$\{/ ||
                buf ~ /\.environments\[env\(/) printf "%s:%d: %s\n", FILENAME, start, buf
            buf = ""
        }')

    if [ -n "${hits}" ]; then
        echo "environment name read unsafely — index it with strenv() instead:"
        echo "${hits}"
        return 1
    fi
}

@test "cli-resolution: the authorize-deployment gate honours ILTERO_CLI_BIN" {
    # The fail-closed deploy gate is the highest-value site: resolving it
    # through PATH means a shadowed binary decides whether a deploy proceeds.
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    source_iltero_core

    mkdir -p "${TEST_TEMP}/offpath"
    cat > "${TEST_TEMP}/offpath/cli-under-test" << 'STUB'
#!/bin/bash
printf '%s\n' "$@" > "${ILTERO_ARGV_FILE}"
exit 0
STUB
    chmod +x "${TEST_TEMP}/offpath/cli-under-test"
    export ILTERO_ARGV_FILE="${TEST_TEMP}/auth_argv"
    export ILTERO_CLI_BIN="${TEST_TEMP}/offpath/cli-under-test"

    verify_authorization "run-1" "stack-1" "dev" "unit-1" || true

    [ -f "${ILTERO_ARGV_FILE}" ]
    grep -q "authorize-deployment" "${ILTERO_ARGV_FILE}"
}

@test "cli-resolution: the deploy gate denies when no CLI path was recorded" {
    # With ILTERO_CLI_BIN unset the gate would otherwise ask whatever the search
    # path resolves — so a planted binary exiting 0 would authorise the deploy.
    export STACKS_CONFIG=".iltero/stacks"
    export ILTERO_STACK_NAME="test-stack"
    source_iltero_core

    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    unset ILTERO_CLI_BIN

    run verify_authorization "run-1" "stack-1" "dev" "unit-1"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"ILTERO_CLI_BIN"* ]] || return 1
}

# =============================================================================
# Environment names containing a dot, through the whole pipeline
# =============================================================================
# Reachability note: the action's `environment` input rejects a dot, so the
# production route for such a name is branch auto-detection — covered in
# tests/detect-environment.bats, which also runs on bash 3. These drive the
# override path to pin the eight per-environment settings reads.

@test "dotted environment: the stack runs instead of halting" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]" "prod.eu"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "${status}" -eq 0 ]
    [[ "${output}" != *"not found in config.yml"* ]] || return 1
    # Not merely "exited 0": a skipped stack also exits 0. Assert it scanned.
    [ "$(_argv_value_after '--environment')" = "prod.eu" ]
}

@test "dotted environment: the declared frameworks are read, not defaulted away" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2, ISO27001]" "prod.eu"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "$(_argv_value_after '--frameworks')" = "SOC2,ISO27001" ]
}

@test "dotted environment: the declared severity threshold is read, not defaulted away" {
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]" "prod.eu"
    yq eval -i '.environments."prod.eu".security.severity_threshold = "critical"' \
        "${TEST_TEMP}/repo/.iltero/stacks/demo/config.yml"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    [ "$(_argv_value_after '--fail-on')" = "critical" ]
}

@test "dotted environment: a declared approval requirement is not lost" {
    # The latent bypass: with the validator fixed but the settings reads still
    # spliced, require_approval collapses to its `false` default.
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]" "prod.eu"
    yq eval -i '.environments."prod.eu".deployment.require_approval = true' \
        "${TEST_TEMP}/repo/.iltero/stacks/demo/config.yml"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    grep -q "require_approval=true" "${GITHUB_OUTPUT}"
}

@test "dotted environment: the declared scan types decide which checks run" {
    # scan_types selects the phases. Read from a spliced query it collapsed to
    # the ["static"] default, so a static scan ran for an environment that
    # asked for none — and the phases the environment did ask for were skipped.
    _require_modern_bash
    _setup_pipeline_repo greenfield "      frameworks: [SOC2]" "prod.eu"
    yq eval -i '.environments."prod.eu".compliance.scan_types = ["evaluation"]' \
        "${TEST_TEMP}/repo/.iltero/stacks/demo/config.yml"

    run bash "${PROJECT_ROOT}/scripts/run-pipeline.sh"

    # Not a skipped stack: the environment resolved and its config was read.
    [[ "${output}" == *"Environment: prod.eu"* ]] || return 1
    grep -qx 'static' "${ILTERO_ARGV_FILE}" && {
        echo "a static scan ran for an environment that does not declare it"
        return 1
    }
    return 0
}
