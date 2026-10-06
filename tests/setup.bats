#!/usr/bin/env bats
#
# Tests for scripts/setup.sh, the body of the `setup` action.

load test_helper

readonly TF_VERSION="9.8.7"
readonly CLI_COMMIT="1111111111111111111111111111111111111111"
readonly SCHEMAS_COMMIT="2222222222222222222222222222222222222222"

setup() {
  make_runner
  stub_curl
  export GITHUB_ACTION_PATH="${BATS_TEST_TMPDIR}/setup"
  mkdir -p "${GITHUB_ACTION_PATH}"
  SETUP="${REPO_ROOT}/scripts/setup.sh"
}

# A Terraform release archive whose binary reports REPORTED_VERSION, pinned
# under the archive name for this runner.
terraform_release() {
  local reported="${1:-${TF_VERSION}}"
  local build="${BATS_TEST_TMPDIR}/tf-build"
  mkdir -p "${build}"
  printf '#!/bin/bash\necho "Terraform v%s"\necho "on linux_amd64"\n' "${reported}" > "${build}/terraform"
  chmod +x "${build}/terraform"
  (cd "${build}" && zip -q "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip" terraform)
  echo "$(sha256_of "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip")  terraform_${TF_VERSION}_linux_amd64.zip" \
    > "${GITHUB_ACTION_PATH}/terraform.sha256"
}

# Pins and stubs for the CLI install. The python3 stub creates a virtual
# environment whose python and iltero commands are stubs too.
cli_release() {
  printf 'iltero-schemas %s\niltero-cli %s\n' "${SCHEMAS_COMMIT}" "${CLI_COMMIT}" > "${GITHUB_ACTION_PATH}/cli-sources.txt"
  printf 'typer==0.27.2 \\\n    --hash=sha256:%s\n' "$(printf 'a%.0s' {1..64})" > "${GITHUB_ACTION_PATH}/cli-requirements.txt"
  echo "opa evaluator" > "${FIXTURES}/opa_linux_amd64_static"
  export OPA_SHA="$(sha256_of "${FIXTURES}/opa_linux_amd64_static")"
  export INSTALLED_COMMIT="${CLI_COMMIT}"
  export PIP_EXIT=0
  export DOCTOR_EXIT=0
  stub python3 '
[[ "$1 $2" == "-m venv" ]] || exit 99
mkdir -p "$3/bin"
cat > "$3/bin/python" << "EOF"
#!/bin/bash
if [[ "$1 $2" == "-m pip" ]]; then
  echo "pip $*" >> "${STUB_LOG}"
  echo "pip failure detail"
  exit "${PIP_EXIT}"
fi
if [[ "$1" == "-c" && "$2" == *"PIN"* ]]; then
  echo "v1.20.2 opa_linux_amd64_static ${OPA_SHA}"
  exit 0
fi
if [[ "$1" == "-c" && "$2" == *"direct_url"* ]]; then
  echo "${INSTALLED_COMMIT}"
  exit 0
fi
exit 98
EOF
cat > "$3/bin/iltero" << "EOF"
#!/bin/bash
echo "iltero $* ILTERO_OPA_PATH=${ILTERO_OPA_PATH}" >> "${STUB_LOG}"
exit "${DOCTOR_EXIT}"
EOF
chmod +x "$3/bin/python" "$3/bin/iltero"'
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
}

# --- terraform ---------------------------------------------------------------

@test "terraform rejects a malformed version" {
  terraform_release
  run "${SETUP}" terraform "1.16"
  [ "${status}" -eq 1 ]
  run "${SETUP}" terraform "1.16.5; rm -rf /"
  [ "${status}" -eq 1 ]
}

@test "terraform refuses a version that is not pinned" {
  terraform_release
  run "${SETUP}" terraform "1.2.3"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"is not pinned"* ]]
  ! grep -q curl "${STUB_LOG}"
}

@test "terraform installs a pinned version and writes its outputs" {
  terraform_release
  run "${SETUP}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
  grep -q "curl https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" "${STUB_LOG}"
  [ "$(output_value terraform-version)" = "${TF_VERSION}" ]
  [ "$(output_value terraform-path)" = "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
  [ -x "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
}

@test "terraform refuses a download that does not match its checksum" {
  terraform_release
  echo "tampered" >> "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip"
  run "${SETUP}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not match its pinned checksum"* ]]
  [ ! -e "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
  [ -z "$(output_value terraform-path)" ]
}

@test "terraform fails when the download fails" {
  terraform_release
  rm "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip"
  run "${SETUP}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Download failed"* ]]
}

@test "terraform refuses a binary that reports another version" {
  terraform_release "1.0.0"
  run "${SETUP}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not 'Terraform v${TF_VERSION}'"* ]]
}

@test "terraform uses the arm64 archive on ARM64 runners" {
  terraform_release
  RUNNER_ARCH=ARM64 run "${SETUP}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"terraform_${TF_VERSION}_linux_arm64.zip' is not pinned"* ]]
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
  [[ "${output}" == *"not the pinned"* ]]
}

@test "cli refuses an evaluator that does not match the contract's pin" {
  cli_release
  echo "tampered" >> "${FIXTURES}/opa_linux_amd64_static"
  run "${SETUP}" cli
  [ "${status}" -eq 1 ]
  [ ! -e "${RUNNER_TEMP}/iltero-tools/bin/opa" ]
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
  [ "$(output_value opa-path)" = "${RUNNER_TEMP}/iltero-tools/bin/opa" ]
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
