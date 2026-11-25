#!/usr/bin/env bats
#
# Tests for the Terraform adapter, scripts/iac/tools/terraform/tool.sh: what it
# gives Terraform on each call, and what it reads from a unit.

load ../../test_helper

setup() {
  make_runner
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"
  # The Python installation the virtual environment runs on.
  mkdir -p "${BATS_TEST_TMPDIR}/python/bin"
  echo "home = ${BATS_TEST_TMPDIR}/python/bin" > "${TOOLS}/venv/pyvenv.cfg"
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
  source "${REPO_ROOT}/scripts/iac/lib/guard.sh"
  source "${REPO_ROOT}/scripts/iac/lib/tool.sh"
  load_tool terraform
}

@test "Terraform gets only PATH, HOME, its own settings and the pairs given" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" "TF_TOKEN_x=secret value" -- plan -input=false
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TF_TOKEN_x=secret value"* ]]
  [[ "${output}" == *"TF_DATA_DIR=${BATS_TEST_TMPDIR}/work/terraform-data"* ]]
  [[ "${output}" == *"TF_IN_AUTOMATION=1"* ]]
  [[ "${output}" == *"args plan -input=false"* ]]
  run grep -vE '^(PATH|HOME|TF_IN_AUTOMATION|TF_INPUT|TF_DATA_DIR|TF_CLI_CONFIG_FILE|TF_PLUGIN_CACHE_DIR|CHECKPOINT_DISABLE|TF_TOKEN_x)=|^args ' <<< "${output}"
  [ "${status}" -eq 1 ]
}

@test "Terraform's arguments must follow --" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" "A=1"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"terraform_run needs -- before Terraform's arguments."* ]]
}

@test "the remote-state switch is found only as a variable declaration" {
  local unit="${BATS_TEST_TMPDIR}/unit"
  mkdir -p "${unit}"
  echo 'variable "enable_remote_state_dependencies" {}' > "${unit}/variables.tf"
  run terraform_declares_remote_state_switch "${unit}"
  [ "${status}" -eq 0 ]
  echo '# enable_remote_state_dependencies' > "${unit}/variables.tf"
  run terraform_declares_remote_state_switch "${unit}"
  [ "${status}" -eq 1 ]
  rm "${unit}/variables.tf"
  run terraform_declares_remote_state_switch "${unit}"
  [ "${status}" -eq 1 ]
}

@test "Terraform reads a new, empty CLI configuration file in the unit's work folder" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TF_CLI_CONFIG_FILE=${BATS_TEST_TMPDIR}/work/terraform-cli-config.tfrc"* ]]
  [ ! -s "${BATS_TEST_TMPDIR}/work/terraform-cli-config.tfrc" ]
}

@test "the CLI configuration file is made anew, never written through a link" {
  mkdir -p "${BATS_TEST_TMPDIR}/work"
  echo "keep" > "${BATS_TEST_TMPDIR}/target"
  ln -s "${BATS_TEST_TMPDIR}/target" "${BATS_TEST_TMPDIR}/work/terraform-cli-config.tfrc"
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/target")" = "keep" ]
  [ ! -L "${BATS_TEST_TMPDIR}/work/terraform-cli-config.tfrc" ]
}

@test "the step stops when Terraform adds a provider to its folders in the home folder" {
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  printf '#!/bin/bash\nmkdir -p "%s/.terraform.d/plugins"\n' "${HOME}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "Terraform's version check is turned off, so it writes nothing into the home folder" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CHECKPOINT_DISABLE=1"* ]]
}

@test "Terraform's input variables are the job's TF_VAR_ variables, and only those" {
  TF_VAR_region=eu OTHER=x run tool_input_variable_names
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TF_VAR_region"* ]]
  [[ "${output}" != *"OTHER"* ]]
}

@test "a reading stops when the variables files of its plan cannot be read" {
  mkdir -p "${BATS_TEST_TMPDIR}/work" "${BATS_TEST_TMPDIR}/unit"
  run tool_take_reading "${BATS_TEST_TMPDIR}/work" "${BATS_TEST_TMPDIR}/unit" "${BATS_TEST_TMPDIR}/first.json"
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/first.json" ]
  [[ "${output}" != *"args plan"* ]]
}

@test "a plan made again stops when the variables files of the saved plan cannot be read" {
  mkdir -p "${BATS_TEST_TMPDIR}/work" "${BATS_TEST_TMPDIR}/unit"
  run tool_replan "${BATS_TEST_TMPDIR}/work" "${BATS_TEST_TMPDIR}/unit" "${BATS_TEST_TMPDIR}/replan.json"
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/replan.json" ]
  [[ "${output}" != *"args plan"* ]]
}

@test "the state check gets Terraform's data folder" {
  run tool_state_check_environment "${BATS_TEST_TMPDIR}/work"
  [ "${output}" = "TF_DATA_DIR=${BATS_TEST_TMPDIR}/work/terraform-data" ]
}

@test "a unit with backend settings for other environments but not this one is not set up for it" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit/config/backend && touch unit/config/backend/staging.hcl
  run tool_check_environment_settings unit production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit in folder 'unit' has backend settings for other environments but none for 'production': unit/config/backend/production.hcl is missing."* ]]
  touch unit/config/backend/production.hcl
  run tool_check_environment_settings unit production
  [ "${status}" -eq 0 ]
}

@test "a unit with variables for other environments but not this one is not set up for it" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit/config && touch unit/config/staging.tfvars.json
  run tool_check_environment_settings unit production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit in folder 'unit' has variables for other environments but none for 'production': unit/config/production.tfvars.json is missing."* ]]
  touch unit/config/production.tfvars.json
  run tool_check_environment_settings unit production
  [ "${status}" -eq 0 ]
}

@test "a unit with no settings files for any environment is set up for every environment" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit/config/backend
  touch unit/config/notes.txt
  run tool_check_environment_settings unit production
  [ "${status}" -eq 0 ]
}

@test "a job that sets TF_WORKSPACE is refused" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit
  TF_WORKSPACE=production run tool_check_environment_settings unit production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The job sets TF_WORKSPACE, but the actions do not use Terraform workspaces."* ]]
}

@test "a settings folder that is a link is checked like a folder" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p shared unit/config && touch shared/staging.hcl
  ln -s ../../shared unit/config/backend
  run tool_check_environment_settings unit production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unit/config/backend/production.hcl is missing."* ]]
}

@test "a folder named like a settings file is not a settings file" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit/config/backend/staging.hcl
  run tool_check_environment_settings unit production
  [ "${status}" -eq 0 ]
}

@test "a settings folder that cannot be read stops the check" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p unit/config/backend
  stub find 'exit 1'
  run tool_check_environment_settings unit production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The action could not read the folder unit/config/backend."* ]]
}

@test "the apply log shows each entry's message, each error's or warning's detail, and any other line as it is" {
  local log="${BATS_TEST_TMPDIR}/apply.ndjson"
  {
    echo '{"@message":"aws_s3_bucket.logs: Creating..."}'
    echo '{"@message":"Error: creating bucket","type":"diagnostic","diagnostic":{"detail":"Access denied."}}'
    echo '{"@message":"Warning: argument deprecated","type":"diagnostic","diagnostic":{"detail":"Use the new argument."}}'
    echo '{"@message":null}'
    echo '[1]'
    echo 'not a log entry'
  } > "${log}"
  run terraform_print_apply_log "${log}"
  [ "${status}" -eq 0 ]
  [ "${output}" = $'aws_s3_bucket.logs: Creating...\nError: creating bucket\nAccess denied.\nWarning: argument deprecated\nUse the new argument.\n[1]\nnot a log entry' ]
}

@test "an apply that wrote no log shows nothing" {
  run terraform_print_apply_log "${BATS_TEST_TMPDIR}/missing.ndjson"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "a character that cannot be shown does not cut the apply log short" {
  local log="${BATS_TEST_TMPDIR}/apply.ndjson"
  {
    echo '{"@message":"Error: \ud800 in a provider error"}'
    echo '{"@message":"Apply complete! Resources: 0 added."}'
  } > "${log}"
  run terraform_print_apply_log "${log}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"in a provider error"* ]]
  [[ "${output}" == *"Apply complete! Resources: 0 added."* ]]
}

@test "an apply whose messages cannot be shown says so, and keeps Terraform's exit code" {
  mkdir -p "${BATS_TEST_TMPDIR}/unit" "${BATS_TEST_TMPDIR}/work"
  terraform_print_apply_log() { return 1; }
  TOOL_ENVIRONMENT_PAIRS=(TERRAFORM_EXIT=3)
  run tool_apply "${BATS_TEST_TMPDIR}/work" "${BATS_TEST_TMPDIR}/unit"
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"The action could not show the apply's messages."* ]]
}

@test "Terraform gets the job's proxy and certificate settings when the job sets them, and no other job variable" {
  HTTPS_PROXY="http://proxy.example:3128" no_proxy="localhost" SSL_CERT_FILE="/etc/ssl/custom.pem" \
    UNRELATED_SETTING="no" run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"HTTPS_PROXY=http://proxy.example:3128"* ]]
  [[ "${output}" == *"no_proxy=localhost"* ]]
  [[ "${output}" == *"SSL_CERT_FILE=/etc/ssl/custom.pem"* ]]
  [[ "${output}" != *"UNRELATED_SETTING"* ]]
  [[ "${output}" != *"HTTP_PROXY="* ]]
}

@test "the adapter cannot set a network setting the guard takes from the job" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_prepare_call() { echo HTTPS_PROXY=http://elsewhere.example; }; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"prepared a variable the guard does not accept"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "every Terraform call shares one provider cache in the runner's temporary folder" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TF_PLUGIN_CACHE_DIR=${RUNNER_TEMP}/iltero-terraform-plugin-cache"* ]]
  [ -d "${RUNNER_TEMP}/iltero-terraform-plugin-cache" ]
}

@test "a caller cannot pass its own value for a network setting the guard takes from the job" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" "HTTPS_PROXY=http://elsewhere.example" -- plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"run_guarded takes HTTPS_PROXY from the job's environment, so a NAME=VALUE pair cannot set it."* ]]
}

@test "a provider cache folder that is a link is refused" {
  mkdir -p "${BATS_TEST_TMPDIR}/elsewhere"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${RUNNER_TEMP}/iltero-terraform-plugin-cache"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not prepare the files Terraform reads"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "a job setting that lets Terraform use a cached provider the lock file does not pin never reaches Terraform" {
  TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE"* ]]
}
