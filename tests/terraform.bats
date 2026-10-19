#!/usr/bin/env bats
#
# Tests for scripts/lib/terraform.sh, which runs Terraform for deploy and preview.

load test_helper

setup() {
  make_runner
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"
  # A stand-in for Terraform. It prints exactly the environment it was given,
  # read from /proc as Python may add to its own, then its arguments, and
  # exits with TERRAFORM_EXIT when that is set.
  cat > "${TOOLS}/bin/terraform" << STUB
#!$(command -v python3)
import sys
with open("/proc/self/environ", "rb") as given:
    entries = sorted(entry.decode() for entry in given.read().split(b"\\0") if entry)
print("\\n".join(entries))
print("args " + " ".join(sys.argv[1:]))
code = [entry.split("=", 1)[1] for entry in entries if entry.startswith("TERRAFORM_EXIT=")]
sys.exit(int(code[0]) if code else 0)
STUB
  chmod +x "${TOOLS}/bin/terraform"
  # A stand-in for env that records any call with arguments.
  stub env 'if [[ $# -gt 0 ]]; then echo "env $*" >> "${STUB_LOG}"; fi; exec /usr/bin/env "$@"'
  export JOB_SECRET="job-secret"
  source "${REPO_ROOT}/scripts/lib/common.sh"
  source "${REPO_ROOT}/scripts/lib/terraform.sh"
}

@test "Terraform gets only PATH, HOME, its own settings and the pairs given" {
  run run_terraform "${BATS_TEST_TMPDIR}/work" "TF_TOKEN_x=secret value" -- plan -input=false
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TF_TOKEN_x=secret value"* ]]
  [[ "${output}" == *"TF_DATA_DIR=${BATS_TEST_TMPDIR}/work/terraform-data"* ]]
  [[ "${output}" == *"TF_IN_AUTOMATION=1"* ]]
  [[ "${output}" == *"args plan -input=false"* ]]
  run grep -vE '^(PATH|HOME|TF_IN_AUTOMATION|TF_INPUT|TF_DATA_DIR|TF_TOKEN_x)=|^args ' <<< "${output}"
  [ "${status}" -eq 1 ]
}

@test "Terraform gets no exported function and no variable bash cannot name" {
  hidden() { :; }
  export -f hidden
  run /usr/bin/env "a-b=hyphen" "x.y=dot" "BASH_FUNC_bad%%=x" bash -c \
    "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/lib/terraform.sh'; run_terraform '${BATS_TEST_TMPDIR}/work' -- version"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"args version"* ]]
  [[ "${output}" != *"BASH_FUNC_"* ]]
  [[ "${output}" != *"hyphen"* ]]
  [[ "${output}" != *"x.y="* ]]
}

@test "no value given to Terraform is passed on a command line" {
  run run_terraform "${BATS_TEST_TMPDIR}/work" "TF_TOKEN_x=secret" -- plan
  [ "${status}" -eq 0 ]
  [[ "$(grep '^args ' <<< "${output}")" != *"secret"* ]]
  run grep -q "secret" "${STUB_LOG}"
  [ "${status}" -eq 1 ]
}

@test "Terraform's exit code passes through" {
  run run_terraform "${BATS_TEST_TMPDIR}/work" "TERRAFORM_EXIT=3" -- plan
  [ "${status}" -eq 3 ]
}

@test "Terraform's arguments must follow --" {
  run run_terraform "${BATS_TEST_TMPDIR}/work" "A=1"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"run_terraform needs -- before Terraform's arguments."* ]]
}

@test "only NAME=VALUE pairs may come before --" {
  run run_terraform "${BATS_TEST_TMPDIR}/work" JOB_SECRET -- plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"run_terraform takes NAME=VALUE pairs before --."* ]]
  [[ "${output}" != *"job-secret"* ]]
}

@test "the remote-state switch is found only as a variable declaration" {
  local unit="${BATS_TEST_TMPDIR}/unit"
  mkdir -p "${unit}"
  echo 'variable "enable_remote_state_dependencies" {}' > "${unit}/variables.tf"
  run declares_remote_state_switch "${unit}"
  [ "${status}" -eq 0 ]
  echo '# enable_remote_state_dependencies' > "${unit}/variables.tf"
  run declares_remote_state_switch "${unit}"
  [ "${status}" -eq 1 ]
  rm "${unit}/variables.tf"
  run declares_remote_state_switch "${unit}"
  [ "${status}" -eq 1 ]
}
