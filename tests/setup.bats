#!/usr/bin/env bats
#
# Tests for scripts/setup.sh, the body of the `setup` action.

# The stubs and scripts these tests write expand their variables when they
# run, not here.
# shellcheck disable=SC2016

load test_helper

readonly CLI_COMMIT="1111111111111111111111111111111111111111"
readonly SCHEMAS_COMMIT="2222222222222222222222222222222222222222"

setup() {
  make_runner
  stub_curl
  export GITHUB_ACTION_PATH="${BATS_TEST_TMPDIR}/setup"
  mkdir -p "${GITHUB_ACTION_PATH}"
  SETUP="${REPO_ROOT}/scripts/setup.sh"
}

# Pins and stubs for the CLI install. The python3 stub creates a virtual
# environment whose python and iltero commands are stubs too.
cli_release() {
  printf 'iltero-schemas %s\niltero-cli %s\n' "${SCHEMAS_COMMIT}" "${CLI_COMMIT}" > "${GITHUB_ACTION_PATH}/cli-sources.txt"
  printf 'typer==0.27.2 \\\n    --hash=sha256:%s\n' "$(printf 'a%.0s' {1..64})" > "${GITHUB_ACTION_PATH}/cli-requirements.txt"
  echo "opa evaluator" > "${FIXTURES}/opa_linux_amd64_static"
  OPA_SHA="$(sha256_of "${FIXTURES}/opa_linux_amd64_static")"
  export OPA_SHA
  export INSTALLED_COMMIT="${CLI_COMMIT}"
  export INSTALLED_SCHEMAS_COMMIT="${SCHEMAS_COMMIT}"
  export PIP_EXIT=0
  export DOCTOR_EXIT=0
  stub python3 '
[[ "$1 $2 $3" == "-I -m venv" ]] || exit 99
mkdir -p "$4/bin"
cat > "$4/bin/python" << "EOF"
#!/bin/bash
if [[ "$1 $2 $3" == "-I -m pip" ]]; then
  echo "pip $*" >> "${STUB_LOG}"
  echo "pip failure detail"
  exit "${PIP_EXIT}"
fi
if [[ "$1" == "-I" && "$2" == "-c" && "$3" == *"direct_url"* ]]; then
  [[ "$4" == iltero-schemas ]] && echo "${INSTALLED_SCHEMAS_COMMIT}" || echo "${INSTALLED_COMMIT}"
  exit 0
fi
exit 98
EOF
cat > "$4/bin/iltero" << "EOF"
#!/bin/bash
echo "iltero $* ILTERO_OPA_PATH=${ILTERO_OPA_PATH}" >> "${STUB_LOG}"
if [[ "$1 $2" == "evaluator pin" ]]; then
  [[ -z "${PIN_EXIT:-}" ]] || exit "${PIN_EXIT}"
  echo "${PIN_LINE:-v1.20.2 opa_linux_amd64_static ${OPA_SHA}}"
  exit 0
fi
exit "${DOCTOR_EXIT}"
EOF
chmod +x "$4/bin/python" "$4/bin/iltero"'
}

# --- check -------------------------------------------------------------------

@test "check refuses pull_request_target events" {
  GITHUB_EVENT_NAME=pull_request_target run "${SETUP}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"do not run on 'pull_request_target' events"* ]]
}

@test "check refuses workflow_run events" {
  GITHUB_EVENT_NAME=workflow_run run "${SETUP}" check
  [ "${status}" -eq 1 ]
}

@test "check refuses a missing event name" {
  GITHUB_EVENT_NAME="" run "${SETUP}" check
  [ "${status}" -eq 1 ]
}

@test "check refuses a non-Linux runner" {
  RUNNER_OS=macOS run "${SETUP}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Use a Linux runner"* ]]
}

@test "check refuses an unsupported architecture" {
  RUNNER_ARCH=ARM run "${SETUP}" check
  [ "${status}" -eq 1 ]
}

@test "check accepts push and pull_request events on Linux X64 and ARM64" {
  run "${SETUP}" check
  [ "${status}" -eq 0 ]
  GITHUB_EVENT_NAME=pull_request RUNNER_ARCH=ARM64 run "${SETUP}" check
  [ "${status}" -eq 0 ]
}

@test "an unknown command is refused" {
  run "${SETUP}" install
  [ "${status}" -eq 1 ]
  run "${SETUP}" terraform 1.16.5
  [ "${status}" -eq 1 ]
}

@test "the setup action installs no Terraform" {
  ! grep -qi terraform "${REPO_ROOT}/setup/action.yml" || false
}

# --- cli ---------------------------------------------------------------------

@test "cli fails when the release pins no requirements" {
  cli_release
  rm "${GITHUB_ACTION_PATH}/cli-requirements.txt"
  run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pins no Iltero CLI"* ]]
}

@test "cli fails when the release pins no source commits" {
  cli_release
  rm "${GITHUB_ACTION_PATH}/cli-sources.txt"
  run "${SETUP}" cli
  [ "${status}" -eq 1 ]
}

@test "cli refuses a pinned commit that is not a full commit" {
  cli_release
  printf 'iltero-schemas main\niltero-cli %s\n' "${CLI_COMMIT}" > "${GITHUB_ACTION_PATH}/cli-sources.txt"
  run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a full commit"* ]]
}

@test "cli installs locked dependencies by hash, as wheels only" {
  cli_release
  run "${SETUP}" cli
  [ "${status}" -eq 0 ]
  grep -q -- "--require-hashes --no-deps --only-binary :all: -r ${GITHUB_ACTION_PATH}/cli-requirements.txt" "${STUB_LOG}"
}

@test "cli installs the CLI and the contract from their pinned commits" {
  cli_release
  run "${SETUP}" cli
  [ "${status}" -eq 0 ]
  grep -q -- "--no-deps --no-build-isolation git+https://github.com/ilterohq/iltero-schemas.git@${SCHEMAS_COMMIT} git+https://github.com/ilterohq/iltero-cli.git@${CLI_COMMIT}" "${STUB_LOG}"
}

@test "cli shows pip's log and fails when pip fails" {
  cli_release
  PIP_EXIT=1 run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pip failure detail"* ]]
  [[ "${output}" == *"Installing the Iltero CLI failed"* ]]
}

@test "cli refuses an installed CLI from another commit" {
  cli_release
  INSTALLED_COMMIT="3333333333333333333333333333333333333333" run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The installed CLI is commit '3333333333333333333333333333333333333333', not the pinned"* ]]
}

@test "cli refuses an installed iltero-schemas from another commit" {
  cli_release
  INSTALLED_SCHEMAS_COMMIT="4444444444444444444444444444444444444444" run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The installed iltero-schemas is commit '4444444444444444444444444444444444444444', not the pinned"* ]]
}

@test "cli refuses an evaluator that does not match the contract's pin" {
  cli_release
  echo "tampered" >> "${FIXTURES}/opa_linux_amd64_static"
  run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [ ! -e "${RUNNER_TEMP}/iltero-tools/bin/opa" ]
}

@test "cli asks the CLI for the evaluator pin of the runner's platform" {
  cli_release
  run "${SETUP}" cli
  [ "${status}" -eq 0 ]
  grep -q "^iltero evaluator pin --platform linux-x86_64 " "${STUB_LOG}"
}

@test "cli refuses an evaluator pin with a field too many, or one the CLI cannot report" {
  cli_release
  PIN_LINE="v1.20.2 opa_linux_amd64_static ${OPA_SHA} extra" run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The evaluator pin the Iltero CLI reports is malformed."* ]]
  PIN_LINE="$(printf 'v1.20.2 opa_linux_amd64_static %s\nmore' "${OPA_SHA}")" run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The evaluator pin the Iltero CLI reports is malformed."* ]]
  PIN_EXIT=9 run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The Iltero CLI could not report the evaluator pin for linux-x86_64."* ]]
}

@test "cli fails when the CLI reports it is not ready" {
  cli_release
  DOCTOR_EXIT=4 run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not ready to run checks"* ]]
}

@test "cli runs doctor with the pinned evaluator and writes its outputs" {
  cli_release
  run "${SETUP}" cli
  [ "${status}" -eq 0 ]
  grep -q "curl https://github.com/open-policy-agent/opa/releases/download/v1.20.2/opa_linux_amd64_static" "${STUB_LOG}"
  grep -q "iltero doctor ILTERO_OPA_PATH=${RUNNER_TEMP}/iltero-tools/bin/opa" "${STUB_LOG}"
  [ "$(output_value cli-commit)" = "${CLI_COMMIT}" ]
  [ "$(output_value cli-path)" = "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero" ]
  [ "$(output_value evaluator-path)" = "${RUNNER_TEMP}/iltero-tools/bin/opa" ]
}

# --- errors ------------------------------------------------------------------

@test "an error can exit with the status it is given" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; exit_with_error 7 'stopped'"
  [ "${status}" -eq 7 ]
  [ "${output}" = "::error::stopped" ]
}

@test "a one-line check refuses an input with a tab or other control character" {
  local value
  for value in $'prod\tx' $'prod\rx' $'prod\nx'; do
    run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_one_line environment \"\$1\"" _ "${value}"
    [ "${status}" -eq 1 ]
    [ "${output}" = "::error::The environment input must be one line, with no tab or other control character." ]
  done
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_one_line environment production"
  [ "${status}" -eq 0 ]
}

@test "a true-or-false input refuses any other value" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_true_or_false store-records yes"
  [ "${status}" -eq 1 ]
  [ "${output}" = "::error::The store-records input must be true or false, not 'yes'." ]
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_true_or_false store-records true && require_true_or_false store-records false"
  [ "${status}" -eq 0 ]
}

@test "output too long for the job summary is replaced by a pointer to the log" {
  local details="${BATS_TEST_TMPDIR}/details.md" big="${BATS_TEST_TMPDIR}/big.txt" small="${BATS_TEST_TMPDIR}/small.txt"
  head -c 900000 /dev/zero | tr '\0' 'x' > "${big}"
  echo "small output" > "${small}"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; append_details_block '${details}' network '${small}'; append_details_block '${details}' compute '${big}'"
  [ "${status}" -eq 0 ]
  grep -q "small output" "${details}"
  grep -q "The output of compute is too long for the job summary. It is in the log." "${details}"
  [ "$(wc -c < "${details}")" -lt 800000 ]
}

@test "the summary size limit counts the output as escaped" {
  local details="${BATS_TEST_TMPDIR}/details.md" angled="${BATS_TEST_TMPDIR}/angled.txt"
  head -c 300000 /dev/zero | tr '\0' '<' > "${angled}"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; append_details_block '${details}' network '${angled}'"
  [ "${status}" -eq 0 ]
  grep -q "The output of network is too long for the job summary." "${details}"
  [ "$(wc -c < "${details}")" -lt 800000 ]
}

@test "a summary section escapes its title" {
  local small="${BATS_TEST_TMPDIR}/small.txt"
  echo "output" > "${small}"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; details_block '<b>@t&</b>' '${small}'"
  [[ "${output}" == *"<summary>&lt;b&gt;&#64;t&amp;&lt;/b&gt;</summary>"* ]]
}

@test "the summary section's working file is removed after each section" {
  local details="${BATS_TEST_TMPDIR}/details.md" small="${BATS_TEST_TMPDIR}/small.txt"
  echo "a <b> & c@d" > "${small}"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; append_details_block '${details}' network '${small}'"
  [ ! -e "${details}.block" ]
  grep -qx "a &lt;b&gt; &amp; c&#64;d" "${details}"
}

@test "escaping a large output takes time in proportion to its size" {
  local angled="${BATS_TEST_TMPDIR}/angled.txt"
  head -c 2000000 /dev/zero | tr '\0' '<' > "${angled}"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; SECONDS=0; html_escape_file '${angled}' > /dev/null; echo \"\${SECONDS}\""
  [ "${status}" -eq 0 ]
  [ "${output}" -lt 10 ]
}

# --- escaping ----------------------------------------------------------------

@test "text that looks like an echo option is printed as written" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; html_escape -n; html_escape -e"
  [ "${output}" = $'-n\n-e' ]
}

@test "a line break cannot end a line of Markdown" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; markdown_escape \$'production\n# heading'"
  [ "${#lines[@]}" -eq 1 ]
}

# --- outputs -----------------------------------------------------------------

@test "an output value spanning several lines is refused" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; write_output name \$'one\ntwo'"
  [ "${status}" -eq 1 ]
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "an output with an invalid name is refused" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; write_output 'a=b' value"
  [ "${status}" -eq 1 ]
}
