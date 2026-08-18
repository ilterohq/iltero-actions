#!/usr/bin/env bats
# =============================================================================
# Tests that execute a composite action's script body
# =============================================================================
# Nothing else in this suite runs an action's `run:` block. That gap let the
# scan and evaluate actions ship requiring two variables neither of them set,
# so every invocation aborted before reaching the CLI.
#
# These extract the real script out of action.yml and run it, so the action's
# own wiring is under test rather than only the library it calls.
# =============================================================================

load 'test_helper'

setup() {
    mkdir -p "${TEST_TEMP}"
    export GITHUB_OUTPUT="${TEST_TEMP}/github_output"
    export GITHUB_STEP_SUMMARY="${TEST_TEMP}/github_summary"
    touch "${GITHUB_OUTPUT}" "${GITHUB_STEP_SUMMARY}"
    cd "${TEST_TEMP}"
}

teardown() {
    rm -rf "${TEST_TEMP}"
}

# =============================================================================
# Helpers
# =============================================================================

# Extract a step's `run:` script from an action.yml.
# Args: $1=action dir (e.g. "scan")  $2=step id
_action_script() {
    local script
    script=$(yq eval ".runs.steps[] | select(.id == \"${2}\") | .run" "${PROJECT_ROOT}/${1}/action.yml")
    # yq exits 0 with empty output when no step matches, which would make every
    # negative assertion below pass against a script that never ran.
    if [[ -z "${script}" ]] || [[ "${script}" == "null" ]]; then
        echo "no run: body found for step '${2}' in ${1}/action.yml" >&2
        return 1
    fi
    printf '%s\n' "${script}"
}

# Run a step's script with the action's own path wiring in place.
# Args: $1=action dir  $2=step id
_run_action_step() {
    local action_dir="${1}" step_id="${2}"
    _action_script "${action_dir}" "${step_id}" > "${TEST_TEMP}/step.sh"
    GITHUB_ACTION_PATH="${PROJECT_ROOT}/${action_dir}" bash "${TEST_TEMP}/step.sh"
}

# A self-contained unit the structure validator accepts.
_make_unit() {
    mkdir -p "${TEST_TEMP}/unit"
    touch "${TEST_TEMP}/unit"/{main.tf,providers.tf,versions.tf,backend.tf}
}

# CLI stub that records argv and succeeds.
_stub_cli() {
    export ILTERO_ARGV_FILE="${TEST_TEMP}/argv"
    : > "${ILTERO_ARGV_FILE}"
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "${ILTERO_ARGV_FILE}"
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && echo '{"run_id":"r1","scan_id":"s1","violations_count":0,"violations":[]}' > "${of}"
exit 0
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero"
}

# A config.yml declaring one environment.
# Args: $1=environment name  $2=extra compliance YAML (optional)
_make_config() {
    local env_name="${1}" extra="${2:-}"
    cat > "${TEST_TEMP}/config.yml" << EOF
stack:
  id: 0b278217-a809-465a-b9df-00eda8414cb8
  name: demo
environments:
  ${env_name}:
    git_ref:
      type: branch
      name: main
    compliance:
      scan_types: [static]
${extra}
EOF
}

_scan_env() {
    export SCAN_PATH="${TEST_TEMP}/unit"
    export STACK_ID="0b278217-a809-465a-b9df-00eda8414cb8"
    export STACK_NAME="demo"
    export STACKS_CONFIG=".iltero/stacks"
    export UNIT_NAME="network"
    export ENVIRONMENT="production"
    export FAIL_ON="high"
    export CHAIN_RUN_ID=""
    export CONFIG_PATH=""
    export FRAMEWORKS=""
    export PREVIEW_MODE="false"
}

# =============================================================================
# The defect that made every invocation abort
# =============================================================================

@test "scan action: the step runs to the CLI instead of aborting on unset variables" {
    _make_unit
    _stub_cli
    _scan_env

    run _run_action_step "scan" "scan"

    [ "${status}" -eq 0 ]
    # It reached the CLI at all — this is what used to abort at scanning.sh.
    grep -q "static" "${ILTERO_ARGV_FILE}"
    [[ "${output}" != *"STACKS_CONFIG must be set"* ]] || return 1
    [[ "${output}" != *"ILTERO_STACK_NAME not set"* ]] || return 1
}

@test "scan action: results land under stacks-config/stack-name" {
    _make_unit
    _stub_cli
    _scan_env

    _run_action_step "scan" "scan"

    [ -d "${TEST_TEMP}/.iltero/stacks/demo/static" ]
}

@test "scan action: stack-name falls back to the stack id" {
    _make_unit
    _stub_cli
    _scan_env
    export STACK_NAME=""

    _run_action_step "scan" "scan"

    [ -d "${TEST_TEMP}/.iltero/stacks/0b278217-a809-465a-b9df-00eda8414cb8/static" ]
}

# =============================================================================
# Masked defect: a wrong config path silently disabled framework scoping
# =============================================================================

@test "scan action: a config-path that does not exist stops the run" {
    _make_unit
    _stub_cli
    _scan_env
    export CONFIG_PATH="nope.yml"

    run _run_action_step "scan" "scan"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"config-path not found"* ]] || return 1
}

@test "scan action: an environment the config does not declare stops the run" {
    _make_unit
    _stub_cli
    _scan_env
    _make_config "staging" "      frameworks: [SOC2]"
    export CONFIG_PATH="config.yml"
    export ENVIRONMENT="production"

    run _run_action_step "scan" "scan"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not declared"* ]] || return 1
}

@test "scan action: frameworks declared for the environment reach the CLI" {
    _make_unit
    _stub_cli
    _scan_env
    _make_config "production" "      frameworks: [SOC2, ISO27001]"
    export CONFIG_PATH="config.yml"

    _run_action_step "scan" "scan"

    grep -q "SOC2,ISO27001" "${ILTERO_ARGV_FILE}"
}

@test "scan action: an absent framework scope is stated, not silent" {
    _make_unit
    _stub_cli
    _scan_env

    run _run_action_step "scan" "scan"

    [[ "${output}" == *"No framework scope"* ]] || return 1
}

# =============================================================================
# Masked defect: the scan step rewrote the stack's tracked config.yml
# =============================================================================

@test "scan action: never asks the CLI to write the config file" {
    _make_unit
    _stub_cli
    _scan_env
    _make_config "production" "      frameworks: [SOC2]"
    export CONFIG_PATH="config.yml"

    _run_action_step "scan" "scan"

    ! grep -q -- "--config-path" "${ILTERO_ARGV_FILE}"
}

# =============================================================================
# Masked defect: a malformed depends-on read as "all dependencies available"
# =============================================================================

@test "evaluate action: a depends-on that is not a JSON array stops the run" {
    _make_unit
    _stub_cli
    export EVAL_PATH="${TEST_TEMP}/unit"
    export STACK_ID="0b278217-a809-465a-b9df-00eda8414cb8"
    export STACK_NAME="demo"
    export STACKS_CONFIG=".iltero/stacks"
    export UNIT_NAME="network"
    export ENVIRONMENT="production"
    export FAIL_ON="high"
    export CHAIN_RUN_ID=""
    export EXISTING_PLAN=""
    export ILTERO_ATTEST="false"
    export ILTERO_S3_SSE=""
    export CONFIG_PATH=""
    export FRAMEWORKS=""
    export DEPENDS_ON="network"

    run _run_action_step "evaluate" "evaluate"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be a JSON array"* ]] || return 1
}

# =============================================================================
# Path inputs must not escape the workspace
# =============================================================================

@test "scan action: a traversing stacks-config is rejected" {
    _make_unit
    _stub_cli
    _scan_env
    export STACKS_CONFIG="../outside/stacks"

    run _run_action_step "scan" "scan"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"simple relative path"* ]] || return 1
    [ ! -d "${TEST_TEMP}/../outside" ]
}

@test "scan action: a traversing stack-name is rejected" {
    _make_unit
    _stub_cli
    _scan_env
    export STACK_NAME="../../elsewhere"

    run _run_action_step "scan" "scan"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"simple relative path"* ]] || return 1
}

@test "scan action: results-file output points at the file that was written" {
    _make_unit
    _stub_cli
    _scan_env

    _run_action_step "scan" "scan"

    local published
    published=$(grep '^results-file=' "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-)
    [ -n "${published}" ]
    # The real file, not an unexpanded glob pointing at a directory nothing
    # writes to — which is what this output used to publish.
    [ -f "${published}" ]
    [[ "${published}" != *"*"* ]] || return 1
    [[ "${published}" == *"/.iltero/stacks/demo/static/"* ]] || return 1
}

# =============================================================================
# Outputs must survive a non-pass outcome
# =============================================================================
# The library re-enables errexit around its CLI call, which clobbers the
# caller's `set +e`. Without the `|| EXIT_CODE=$?` form below, the step dies on
# any non-zero result and every output — including `status` — is never written.

@test "scan action: a violations verdict still writes its outputs" {
    _make_unit
    _scan_env
    export ILTERO_ARGV_FILE="${TEST_TEMP}/argv"; : > "${ILTERO_ARGV_FILE}"
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
of=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output-file" ]] && of="${a}"; prev="${a}"; done
[[ -n "${of}" ]] && echo '{"run_id":"r1","scan_id":"s1","violations_count":2,"violations":[{"severity":"critical"},{"severity":"high"}]}' > "${of}"
exit 1
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero"

    run _run_action_step "scan" "scan"

    grep -q "^status=violations" "${GITHUB_OUTPUT}"
    grep -q "^passed=false" "${GITHUB_OUTPUT}"
}

@test "scan action: an infra error still writes status=infra_error" {
    _make_unit
    _scan_env
    cat > "${TEST_TEMP}/iltero" << 'STUB'
#!/bin/bash
exit 3
STUB
    chmod +x "${TEST_TEMP}/iltero"
    export PATH="${TEST_TEMP}:${PATH}"
    export ILTERO_CLI_BIN="${TEST_TEMP}/iltero"

    run _run_action_step "scan" "scan"

    grep -q "^status=infra_error" "${GITHUB_OUTPUT}"
}

@test "scan action: a multi-document config is rejected, not read as declared" {
    # yq emits one result per document, so a second document made the
    # environment check answer for a file it had not really inspected.
    _make_unit
    _stub_cli
    _scan_env
    printf 'environments:\n  staging: {}\n---\nother: 1\n' > "${TEST_TEMP}/config.yml"
    export CONFIG_PATH="config.yml"

    run _run_action_step "scan" "scan"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Expected a single result"* ]] || return 1
}

# =============================================================================
# preview must reach the CLI, and must be pinned rather than ambient
# =============================================================================

@test "scan action: preview=true sends --preview, not --resolve-policies" {
    _make_unit
    _stub_cli
    _scan_env
    export PREVIEW_MODE="true"

    _run_action_step "scan" "scan"

    grep -q -- "--preview" "${ILTERO_ARGV_FILE}"
    ! grep -q -- "--resolve-policies" "${ILTERO_ARGV_FILE}"
}

@test "scan action: preview=false sends --resolve-policies" {
    _make_unit
    _stub_cli
    _scan_env

    _run_action_step "scan" "scan"

    grep -q -- "--resolve-policies" "${ILTERO_ARGV_FILE}"
    ! grep -q -- "--preview" "${ILTERO_ARGV_FILE}"
}

@test "actions: both actions pin PREVIEW_MODE from an input" {
    # An ambient PREVIEW_MODE must not be able to decide whether a run submits
    # results — the same rule the file already states for ILTERO_ATTEST.
    for a in scan evaluate; do
        yq eval '.runs.steps[] | select(.env) | .env | has("PREVIEW_MODE")' \
            "${PROJECT_ROOT}/${a}/action.yml" | grep -q true
        yq eval '.inputs | has("preview")' "${PROJECT_ROOT}/${a}/action.yml" | grep -q true
    done
}

# =============================================================================
# The evaluate action's own wiring
# =============================================================================

_eval_env() {
    export EVAL_PATH="${TEST_TEMP}/unit"
    export STACK_ID="0b278217-a809-465a-b9df-00eda8414cb8"
    export STACK_NAME="demo"
    export STACKS_CONFIG=".iltero/stacks"
    export UNIT_NAME="network"
    export ENVIRONMENT="production"
    export FAIL_ON="high"
    export CHAIN_RUN_ID=""
    export EXISTING_PLAN=""
    export ILTERO_ATTEST="false"
    export ILTERO_S3_SSE=""
    export CONFIG_PATH=""
    export FRAMEWORKS=""
    export DEPENDS_ON=""
    export PREVIEW_MODE="false"
}

@test "evaluate action: a config-path that does not exist stops the run" {
    _make_unit
    _stub_cli
    _eval_env
    export CONFIG_PATH="nope.yml"

    run _run_action_step "evaluate" "evaluate"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"config-path not found"* ]] || return 1
}

@test "evaluate action: an environment the config does not declare stops the run" {
    _make_unit
    _stub_cli
    _eval_env
    _make_config "staging" "      frameworks: [SOC2]"
    export CONFIG_PATH="config.yml"

    run _run_action_step "evaluate" "evaluate"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not declared"* ]] || return 1
}

@test "evaluate action: a traversing stacks-config is rejected" {
    _make_unit
    _stub_cli
    _eval_env
    export STACKS_CONFIG="../outside/stacks"

    run _run_action_step "evaluate" "evaluate"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"simple relative path"* ]] || return 1
}

@test "evaluate action: declaring a dependency states the reduced scope" {
    _make_unit
    _stub_cli
    _eval_env
    export DEPENDS_ON='["network"]'

    run _run_action_step "evaluate" "evaluate"

    [[ "${output}" == *"remote state dependencies switched off"* ]] || return 1
}

# =============================================================================
# Installing the tools: did the install happen, and which version ran
# =============================================================================
# A compliance gate is only as trustworthy as the tools it runs. An install that
# quietly did not happen must not be reported as one that did, and the version
# recorded must be the version installed rather than the version asked for.

# Stub `python`, which the install steps use for both `-m pip install` and the
# metadata read.
# Args: $1=pip exit status  $2=version the package metadata reports ("" = none)
_stub_python() {
    local pip_exit="${1:-0}" reported="${2-0.6.3}"
    export PIP_ARGV_FILE="${TEST_TEMP}/pip_argv"
    : > "${PIP_ARGV_FILE}"
    cat > "${TEST_TEMP}/python" << STUB
#!/bin/bash
if [ "\$1" = "-m" ] && [ "\$2" = "pip" ]; then
    shift 2
    printf '%s\n' "\$@" >> "${PIP_ARGV_FILE}"
    echo "Collecting a package"
    exit ${pip_exit}
fi
if [ "\$1" = "-c" ]; then
    REPORTED="${reported}"
    [ -n "\${REPORTED}" ] || exit 1
    printf '%s\n' "\${REPORTED}"
    exit 0
fi
exit 0
STUB
    chmod +x "${TEST_TEMP}/python"
}

# An iltero binary already on PATH, as a runner image or an earlier install
# would leave behind.
_stub_installed_cli() {
    printf '#!/bin/bash\nexit 0\n' > "${TEST_TEMP}/iltero"
    chmod +x "${TEST_TEMP}/iltero"
}

# Args: $1=exit status for `checkov --version`
_stub_checkov() {
    printf '#!/bin/bash\necho "3.2.0"\nexit %s\n' "${1:-0}" > "${TEST_TEMP}/checkov"
    chmod +x "${TEST_TEMP}/checkov"
}

_install_env() {
    export PATH="${TEST_TEMP}:${PATH}"
    # The step asserts the resolved binary sits under the Python prefix.
    export pythonLocation="${TEST_TEMP}"
    export GITHUB_ENV="${TEST_TEMP}/github_env"
    : > "${GITHUB_ENV}"
}

@test "root action: a pinned CLI version is the one installed" {
    _stub_python 0 "0.7.0"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="0.7.0"

    run _run_action_step "." "install-cli"

    [ "${status}" -eq 0 ]
    grep -qx 'iltero-cli==0.7.0' "${PIP_ARGV_FILE}"
}

@test "root action: latest asks pip to upgrade" {
    _stub_python 0 "0.7.0"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="latest"

    run _run_action_step "." "install-cli"

    [ "${status}" -eq 0 ]
    grep -qx -- '--upgrade' "${PIP_ARGV_FILE}"
}

@test "root action: a failed install fails the job even when a CLI is already on PATH" {
    # The filter-and-silence form handed the pipeline grep's status and then
    # discarded it, so a failed upgrade ran the whole job on whichever version
    # happened to be installed already.
    _stub_python 1 "0.7.0"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="0.6.3"

    run _run_action_step "." "install-cli"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"install failed"* ]] || return 1
}

@test "root action: the version recorded is the one installed, not the one requested" {
    # The two must be allowed to differ, or the test passes against an
    # implementation that echoes the request back and never reads what landed.
    _stub_python 0 "0.7.1"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="0.8.0"

    run _run_action_step "." "install-cli"

    [ "${status}" -eq 0 ]
    grep -q "0.7.1" "${GITHUB_OUTPUT}"
    ! grep -q "0.8.0" "${GITHUB_OUTPUT}"
}

@test "root action: a version that cannot be read fails the job" {
    _stub_python 0 ""
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="0.6.3"

    run _run_action_step "." "install-cli"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Could not read the installed Iltero CLI version"* ]] || return 1
}

@test "root action: a version input carrying a newline is rejected before use" {
    # The value reaches the run log, where extra lines are read as instructions
    # to the runner rather than as text — ::stop-commands:: would silence every
    # command after it, including a later secret mask.
    _stub_python 0 "0.7.0"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION=$'0.6.3\n::stop-commands::abc'

    run _run_action_step "." "install-cli"

    [ "${status}" -ne 0 ]
    [[ "${output}" != *"::stop-commands::"* ]] || return 1
    [ ! -s "${PIP_ARGV_FILE}" ]
}

@test "root action: a Checkov install failure fails the job" {
    _stub_python 1 "0.7.0"
    _stub_checkov 0
    _install_env

    run _run_action_step "." "install-checkov"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Checkov install failed"* ]] || return 1
}

@test "root action: a Checkov that does not run fails the job" {
    # pip exiting 0 is not evidence that the scanner works, and a missing
    # scanner used to be announced as an installed one.
    _stub_python 0 "0.7.0"
    _stub_checkov 1
    _install_env

    run _run_action_step "." "install-checkov"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not run"* ]] || return 1
}

@test "no action installs through a filter that discards the installer's status" {
    # Structural guard over every install in every action. Piping an installer
    # into grep replaces its exit status with the filter's, and the `|| true`
    # needed to silence "nothing matched" then hides a real failure. A download
    # additionally needs --fail: without it curl writes an error page to the
    # destination and still exits 0, so a 404 is installed as the tool.
    local files hits
    files=$(find "${PROJECT_ROOT}" -name 'action.yml' -type f \
        -not -path '*/node_modules/*' | sort)
    # Floor: an empty list would make the assertions below pass against nothing.
    [ "$(printf '%s\n' "${files}" | grep -c .)" -ge 8 ] || return 1

    # Join line continuations first: the OPA download spans two lines, so a
    # line-at-a-time match would not see it.
    hits=$(printf '%s\n' "${files}" | tr '\n' '\0' | xargs -0 awk '
        FNR == 1 { buf = ""; start = 0 }
        {
            if (buf == "") start = FNR
            buf = buf $0
            if (sub(/\\$/, "", buf)) next
            if (buf ~ /(pip install|curl).*\|.*grep/) printf "%s:%d: %s\n", FILENAME, start, buf
            buf = ""
        }')

    if [ -n "${hits}" ]; then
        echo "installer status discarded by a pipe into grep:"
        echo "${hits}"
        return 1
    fi
}

@test "every download asks curl to fail on an HTTP error" {
    local files hits
    files=$(find "${PROJECT_ROOT}" -name 'action.yml' -type f \
        -not -path '*/node_modules/*' | sort)
    [ "$(printf '%s\n' "${files}" | grep -c .)" -ge 8 ] || return 1

    # Downloads only: a curl that writes to a file. Without --fail an error
    # page becomes the file, and the step reports success.
    hits=$(printf '%s\n' "${files}" | tr '\n' '\0' | xargs -0 awk '
        FNR == 1 { buf = ""; start = 0 }
        {
            if (buf == "") start = FNR
            buf = buf $0
            if (sub(/\\$/, "", buf)) next
            if (buf ~ /curl/ && buf ~ /-o [^ ]/ && buf !~ /-o \/dev\/null/ &&
                buf !~ /-f/) printf "%s:%d: %s\n", FILENAME, start, buf
            buf = ""
        }')

    if [ -n "${hits}" ]; then
        echo "download without --fail (an HTTP error page would be installed):"
        echo "${hits}"
        return 1
    fi
}

# =============================================================================
# Every published example must reference a pin that can actually be resolved
# =============================================================================
# 40 references pinned this action to a commit that does not exist, and 48 more
# named a tag that has never been created — so no example in the repository
# could be copied and run. Seven different spellings had drifted apart, which is
# what let it go unnoticed.
#
# Scope is what a user copies: the README, the reference docs, the example
# workflows, and the usage blocks in the action files. The contributor guide and
# the release workflow are excluded — they teach the permitted pin styles, so
# they legitimately show more than one.

# Pins from every surface a user copies from.
_user_facing_pins() {
    {
        find "${PROJECT_ROOT}/docs" "${PROJECT_ROOT}/examples" -type f \
            \( -name '*.md' -o -name '*.yml' \) 2>/dev/null
        find "${PROJECT_ROOT}" -maxdepth 2 -name 'action.yml' -type f
        echo "${PROJECT_ROOT}/README.md"
    } | sort -u | tr '\n' '\0' \
        | xargs -0 grep -hoE 'uses: ilterohq/iltero-actions[a-z/-]*@[^ ]+' 2>/dev/null \
        | sed -E 's|.*@||' | sort -u
}

@test "docs: every reference to this action uses one agreed pin" {
    local refs distinct
    refs=$(_user_facing_pins)

    # Floor: no matches would make the assertion below pass against nothing.
    [ -n "${refs}" ] || return 1
    distinct=$(printf '%s\n' "${refs}" | grep -c .)

    if [ "${distinct}" -ne 1 ]; then
        echo "references a user copies use ${distinct} different pins:"
        printf '%s\n' "${refs}"
        return 1
    fi
}

@test "docs: the pin is a commit SHA or the release placeholder, never a bare tag" {
    # A tag can be moved, or may never have existed; both have shipped here.
    # Every pin is checked, not the first: a single bad one among good ones is
    # exactly the state this repository was already in.
    local refs ref
    refs=$(_user_facing_pins)
    [ -n "${refs}" ] || return 1

    while IFS= read -r ref; do
        [ -n "${ref}" ] || continue
        [[ "${ref}" == "RELEASE_COMMIT_SHA" || "${ref}" =~ ^[0-9a-f]{40}$ ]] || {
            echo "pin '${ref}' is neither a 40-character commit SHA nor the release placeholder"
            return 1
        }
    done <<< "${refs}"
}

@test "root action: a CLI below the floor fails the install step" {
    # The gate reads the CLI's exit code; below 0.7.0 the CLI exits cleanly in
    # states where no verdict was reached, so the gate would silently stop
    # gating. Proven through the real step body, not by calling the check.
    _stub_python 0 "0.6.3"
    _stub_installed_cli
    _install_env
    export INPUT_CLI_VERSION="0.6.3"

    run _run_action_step "." "install-cli"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"0.7.0"* ]] || return 1
}
