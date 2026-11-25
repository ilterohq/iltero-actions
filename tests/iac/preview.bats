#!/usr/bin/env bats
#
# Tests for scripts/iac/preview.sh, the body of the `preview` action.

load ../test_helper

setup() {
  make_runner
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export REGISTRY_HOST=""
  export UPLOAD_RECORDS="false"
  export LINKED="true"
  export ACTIONS_RUNTIME_TOKEN="runtime-token"
  export TF_TOKEN_registry_example="registry-token"
  export CHECK_EXIT=0
  export CHECK_OUTPUT="verdict <b>fail</b> & more"
  export GITHUB_SERVER_URL="https://github.example"
  export GITHUB_REPOSITORY="octo/stack"
  export GITHUB_RUN_ID="99"
  export HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
  export UNITS_JSON="${BATS_TEST_TMPDIR}/units.json"
  : > "${GITHUB_STEP_SUMMARY}"
  PREVIEW="${REPO_ROOT}/scripts/iac/preview.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin"
  # The CLI's Python. The identity-token request is answered with a fake
  # token naming its audience; anything else runs the real interpreter.
  cat > "${TOOLS}/venv/bin/python" << 'STUB'
#!/bin/bash
if [[ "$1" == "-I" && "$2" == "-c" && "$3" == *ACTIONS_ID_TOKEN_REQUEST_URL* ]]; then
  echo "audience ${AUDIENCE}" >> "${STUB_LOG}"
  [[ -z "${MINT_FAILS:-}" ]] || exit 1
  echo "id-token-for-${AUDIENCE}"
  exit 0
fi
exec python3 "$@"
STUB

  # A stand-in for Terraform. It records its arguments, its environment and
  # the override file. Like Terraform with -lockfile=readonly, its init fails
  # when a unit that uses a provider has no lock file.
  # Terraform runs with an emptied environment, so the paths it writes to are
  # fixed in the stand-in when it is created.
  cat > "${TOOLS}/bin/terraform" << STUB
#!/bin/bash
unit="\$(basename "\${PWD}")"
echo "terraform \${unit} \$*" >> "${STUB_LOG}"
case "\$1" in
  init)
    env | sort > "${BATS_TEST_TMPDIR}/terraform-env-\${unit}"
    cp zzz_iltero_preview_override.tf "${BATS_TEST_TMPDIR}/override-\${unit}.tf"
    if [[ ! -e .terraform.lock.hcl ]] && grep -qs provider ./*.tf; then
      echo "Error: the lock file is read-only and has no entry for the provider"
      exit 1
    fi
    ;;
  plan)
    env | sort > "${BATS_TEST_TMPDIR}/terraform-env-plan-\${unit}"
    [[ ! -e "${BATS_TEST_TMPDIR}/plan-fails-\${unit}" ]] || { echo "Error: no credentials"; exit 1; }
    ;;
  show)
    env | sort > "${BATS_TEST_TMPDIR}/terraform-env-show-\${unit}"
    echo '{}'
    ;;
esac
STUB
  # A stand-in for the CLI. `units list` prints UNITS_JSON when it exists,
  # and otherwise one unit per directory under units/.
  cat > "${TOOLS}/venv/bin/iltero" << 'EOF'
#!/bin/bash
echo "iltero $* ILTERO_OPA_PATH=${ILTERO_OPA_PATH}" >> "${STUB_LOG}"
if [[ "$1 $2" == "units list" ]]; then
  [[ ! -e "${UNITS_JSON}" ]] || { cat "${UNITS_JSON}"; exit 0; }
  separator=""
  printf '['
  for dir in units/*/; do
    [[ -d "${dir}" ]] || continue
    name="$(basename "${dir}")"
    printf '%s{"name": "%s", "working_directory": "units/%s"}' "${separator}" "${name}" "${name}"
    separator=", "
  done
  echo ']'
  exit 0
fi
if [[ "$1 $2" == "config show" ]]; then
  echo "{\"linked\": ${LINKED}, \"stack_id\": null}"
  exit 0
fi
if [[ "$1 $2" == "iac check" ]]; then
  echo "${CHECK_OUTPUT}"
  exit "${CHECK_EXIT}"
fi
if [[ "$1 $2" == "environment detect" ]]; then
  exit "${DETECT_EXIT:-0}"
fi
EOF
  chmod +x "${TOOLS}/bin/terraform" "${TOOLS}/venv/bin/iltero" "${TOOLS}/venv/bin/python"
  # The Python installation the virtual environment runs on.
  mkdir -p "${BATS_TEST_TMPDIR}/python/bin"
  echo "home = ${BATS_TEST_TMPDIR}/python/bin" > "${TOOLS}/venv/pyvenv.cfg"

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}"
  cd "${STACK}" || return
  # The name the actions give this stack's work folder.
  STACK_FOLDER="$(stack_folder_name)"
}

# Writes a unit with an AWS provider. With "role", the provider assumes a role.
aws_unit() {
  local dir="$1"
  local role="${2:-}"
  mkdir -p "${dir}"
  {
    echo 'provider "aws" {'
    echo '  region = "eu-west-1"'
    [[ -z "${role}" ]] || echo '  assume_role { role_arn = "arn:aws:iam::123456789012:role/deploy" }'
    echo '}'
  } > "${dir}/main.tf"
  touch "${dir}/.terraform.lock.hcl"
}

# --- check -------------------------------------------------------------------

@test "preview refuses a tool it has no adapter for" {
  TOOL=pulumi run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The tool input must be one of: terraform. It is 'pulumi'."* ]]
}

@test "check refuses pull_request_target and workflow_run events" {
  GITHUB_EVENT_NAME=pull_request_target run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  GITHUB_EVENT_NAME=workflow_run run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
}

@test "check accepts pull request events" {
  run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 0 ]
}

@test "check refuses events other than pull_request" {
  local event
  for event in push pull_request_review workflow_dispatch; do
    GITHUB_EVENT_NAME="${event}" run "${PREVIEW}" check iltero-preview
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"runs only on pull_request events"* ]]
  done
}

@test "check refuses an artifact name the comment action could not use" {
  run "${PREVIEW}" check 'x -->'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name"* ]]
}

@test "check requires the CLI from setup" {
  rm "${TOOLS}/venv/bin/iltero"
  run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Run the setup action first"* ]]
}

@test "check refuses an upload-records value other than true or false" {
  UPLOAD_RECORDS=yes run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The upload-records input must be true or false, not 'yes'."* ]]
  UPLOAD_RECORDS=true run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 0 ]
}

@test "the records are uploaded only when upload-records is true, which is not the default" {
  local action="${REPO_ROOT}/preview/action.yml"
  grep -A6 '^  upload-records:' "${action}" | grep -qx '    default: "false"'
  grep -A1 'name: Upload the records' "${action}" | grep -qF "inputs.upload-records == 'true'"
}

@test "check with a registry host needs the job's identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
  REGISTRY_HOST="registry.example.io" run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot request its identity token for the module registry"* ]]
}

@test "check refuses an invalid registry host" {
  REGISTRY_HOST="Registry.example.io" run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid registry host"* ]]
}

@test "check without a registry host needs no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 0 ]
}

# --- environment -------------------------------------------------------------

@test "environment asks the CLI, which writes the output" {
  run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  grep -q "iltero environment detect --format=github-actions" "${STUB_LOG}"
}

@test "a named environment is the output, and the CLI is not asked" {
  ENVIRONMENT=production run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  [ "$(output_value environment)" = production ]
  ! grep -q "environment detect" "${STUB_LOG}" || false
}

@test "a named environment that spans several lines is refused" {
  ENVIRONMENT=$'production\nstaging' run "${PREVIEW}" environment
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input must be one line, with no tab or other control character."* ]]
  grep -q "The preview stopped before it checked every unit." "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
}

@test "a named environment that cannot name a settings file is refused before anything runs" {
  local name
  for name in ../prod prod/x . ..; do
    ENVIRONMENT="${name}" run "${PREVIEW}" environment
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
    run "${PREVIEW}" run "${name}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
  done
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

@test "when the CLI cannot choose an environment, the step names the environment input and keeps its exit code" {
  DETECT_EXIT=2 run "${PREVIEW}" environment
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"name one with the preview action's environment input"* ]]
  DETECT_EXIT=3 run "${PREVIEW}" environment
  [ "${status}" -eq 3 ]
  [[ "${output}" != *"environment input"* ]]
}

@test "the environment input reaches the step that finds the environment" {
  run awk '/- name: Find the environment/ { inside = 1; next } inside && /ENVIRONMENT:/ { sub(/^ +/, ""); print; exit }' \
    "${REPO_ROOT}/preview/action.yml"
  # The action's own text is matched as written.
  # shellcheck disable=SC2016
  [ "${output}" = 'ENVIRONMENT: ${{ inputs.environment }}' ]
}

# --- units -------------------------------------------------------------------

@test "the units, and their order, are the ones the CLI lists" {
  aws_unit units/network
  aws_unit units/compute
  aws_unit units/unlisted
  echo '[{"name": "network", "working_directory": "units/network"}, {"name": "compute", "working_directory": "units/compute"}]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  [ "$(grep -o -- '--unit=[a-z]*' "${STUB_LOG}" | tr '\n' ' ')" == "--unit=network --unit=compute " ]
}

@test "a unit whose name cannot name a directory is refused" {
  aws_unit units/network
  echo '[{"name": "net work", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit name 'net work' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."* ]]
  # No output is written, so the upload step does not run.
  ! grep -q "^records-directory=" "${GITHUB_OUTPUT}" || false
}

# --- planning without credentials --------------------------------------------

@test "Terraform runs with a scrubbed environment and mock AWS keys" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local env_file="${BATS_TEST_TMPDIR}/terraform-env-network"
  ! grep -qE '^(GITHUB_ENV|GITHUB_OUTPUT|GITHUB_PATH|GITHUB_STEP_SUMMARY|ACTIONS_ID_TOKEN_REQUEST_URL|ACTIONS_RUNTIME_TOKEN|TF_TOKEN_[^=]*)=' "${env_file}" || false
  grep -qx "AWS_ACCESS_KEY_ID=iltero-preview-mock" "${env_file}"
  grep -qx "AWS_EC2_METADATA_DISABLED=true" "${env_file}"
  grep -q "^TF_DATA_DIR=${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/network/" "${env_file}"
}

@test "Terraform gets the job's proxy settings in a preview, but not AWS's settings files" {
  aws_unit units/network
  HTTPS_PROXY="http://proxy.example:3128" AWS_CONFIG_FILE="/etc/aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="/etc/aws/credentials" AWS_CA_BUNDLE="/etc/ssl/aws.pem" run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  grep -qx "HTTPS_PROXY=http://proxy.example:3128" "${BATS_TEST_TMPDIR}/terraform-env-plan-network"
  ! grep -qE "^(AWS_CONFIG_FILE|AWS_SHARED_CREDENTIALS_FILE|AWS_CA_BUNDLE)=" "${BATS_TEST_TMPDIR}/terraform-env-plan-network" || false
}

@test "the job's real credentials and input variables never reach Terraform in a preview" {
  aws_unit units/network
  AWS_SECRET_ACCESS_KEY=real-secret AWS_SESSION_TOKEN=real-session TF_VAR_x=real-value run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local env_file="${BATS_TEST_TMPDIR}/terraform-env-network"
  ! grep -qE 'real-(secret|session|value)' "${env_file}" || false
  grep -qx "AWS_SECRET_ACCESS_KEY=iltero-preview-mock" "${env_file}"
}

@test "a fresh registry token reaches only each init, for the registry host's origin, and is masked" {
  aws_unit units/network
  aws_unit units/compute
  REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  [ "$(grep -cx "audience https://registry.iltero-test.io" "${STUB_LOG}")" -eq 2 ]
  local unit
  for unit in network compute; do
    grep -qx "TF_TOKEN_registry_iltero__test_io=id-token-for-https://registry.iltero-test.io" "${BATS_TEST_TMPDIR}/terraform-env-${unit}"
    ! grep -q "^TF_TOKEN_" "${BATS_TEST_TMPDIR}/terraform-env-plan-${unit}" || false
    ! grep -q "^TF_TOKEN_" "${BATS_TEST_TMPDIR}/terraform-env-show-${unit}" || false
  done
  [[ "${output}" == *"::add-mask::id-token-for-https://registry.iltero-test.io"* ]]
}

@test "the registry token is written to no file, output or summary, even when the plan fails" {
  aws_unit units/network
  aws_unit units/compute
  touch "${BATS_TEST_TMPDIR}/plan-fails-compute"
  REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  ! grep -rqF "id-token-for" "${RUNNER_TEMP}/iltero-preview" "${STACK}" "${GITHUB_ENV}" "${GITHUB_OUTPUT}" "${GITHUB_STEP_SUMMARY}" || false
}

@test "a registry token that cannot be had stops the step" {
  aws_unit units/network
  MINT_FAILS=1 REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Could not get an identity token for the registry"* ]]
  ! grep -q "terraform network init" "${STUB_LOG}" || false
}

@test "a project with no platform section cannot use the Iltero registry, and gets no comment" {
  LINKED=false REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" environment
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"This project is not linked to the server, so it cannot use the Iltero module registry. Add a platform section to .iltero/config.yml, or leave registry-host empty."* ]]
  [ ! -e "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md" ]
  ! grep -q "^iltero environment" "${STUB_LOG}" || false
  LINKED=true REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
}

@test "no registry token is made when no registry host is given" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  ! grep -q "^audience " "${STUB_LOG}" || false
  ! grep -q "^iltero config show" "${STUB_LOG}" || false
}

@test "the plan uses a local backend, no refresh and no lock" {
  aws_unit units/network
  run "${PREVIEW}" run production
  grep -q 'backend "local"' "${BATS_TEST_TMPDIR}/override-network.tf"
  grep -q "terraform network plan -no-color -input=false -refresh=false -lock=false" "${STUB_LOG}"
}

@test "the AWS adapter skips credential checks" {
  aws_unit units/network
  run "${PREVIEW}" run production
  grep -q "skip_credentials_validation = true" "${BATS_TEST_TMPDIR}/override-network.tf"
  ! grep -q "assume_role" "${BATS_TEST_TMPDIR}/override-network.tf" || false
}

@test "the AWS adapter drops the role only for a unit that assumes one" {
  aws_unit units/network role
  run "${PREVIEW}" run production
  grep -q "assume_role {}" "${BATS_TEST_TMPDIR}/override-network.tf"
}

@test "the AWS adapter overrides each aliased provider block, and drops the role only where one is assumed" {
  aws_unit units/network
  cat >> units/network/main.tf << 'HCL'
provider "aws" {
  alias  = "east" # the second region
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/deploy"
  }
  default_tags {
    tags = { team = "platform" }
  }
}
provider "aws" { alias = "west" }
HCL
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local override="${BATS_TEST_TMPDIR}/override-network.tf"
  [ "$(grep -c '^provider "aws" {' "${override}")" -eq 3 ]
  [ "$(grep -c 'skip_credentials_validation = true' "${override}")" -eq 3 ]
  grep -q '  alias = "east"' "${override}"
  grep -q '  alias = "west"' "${override}"
  [ "$(grep -c 'assume_role {}' "${override}")" -eq 1 ]
  sed -n '/alias = "east"/,/^}/p' "${override}" | grep -q 'assume_role {}'
}

@test "the AWS adapter reads an alias only at a block's top level, skips comment lines, and keeps counting braces after a # in a string" {
  mkdir -p units/network
  touch units/network/.terraform.lock.hcl
  cat > units/network/main.tf << 'HCL'
# provider "aws" { alias = "commented" }
provider "aws" {
  region = "us-east-1"
  default_tags { tags = { alias = "a-tag", doc = "https://wiki.example/x#a" } }
  # assume_role {
  // assume_role {
  # a comment with an unbalanced brace {
}
HCL
  cat > units/network/providers.tf << 'HCL'
provider "aws" {
  alias = "second"
}
HCL
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local override="${BATS_TEST_TMPDIR}/override-network.tf"
  [ "$(grep -c '^provider "aws" {' "${override}")" -eq 2 ]
  [ "$(grep -c '  alias = ' "${override}")" -eq 1 ]
  grep -q '  alias = "second"' "${override}"
  ! grep -q 'assume_role' "${override}" || false
}

@test "a unit whose AWS provider alias is not a plain name is not evaluated" {
  aws_unit units/network
  printf 'provider "aws" {\n  alias = "east${var.x}"\n}\n' >> units/network/main.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The preview cannot plan an AWS provider block whose alias is not a plain name."* ]]
  grep -q "| network | not evaluated: the preview could not plan the unit |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "terraform network" "${STUB_LOG}" || false
}

@test "the unit's variables file for the environment is used when it exists" {
  aws_unit units/network
  mkdir -p units/network/config && touch units/network/config/production.tfvars.json
  run "${PREVIEW}" run production
  grep -q -- "-var-file=${STACK}/units/network/config/production.tfvars.json" "${STUB_LOG}"
}

@test "a unit with variables for other environments but not this one is not evaluated, and Terraform does not run for it" {
  aws_unit units/network
  mkdir -p units/network/config && touch units/network/config/staging.tfvars.json
  run "${PREVIEW}" run production
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"units/network/config/production.tfvars.json is missing."* ]]
  grep -q "| network | not evaluated: the unit is not set up for this environment |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^terraform network" "${STUB_LOG}" || false
}

@test "a job that sets TF_WORKSPACE gets no preview" {
  aws_unit units/network
  TF_WORKSPACE=production run "${PREVIEW}" run production
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"The job sets TF_WORKSPACE"* ]]
  grep -q "| network | not evaluated: the unit is not set up for this environment |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "a unit with backend settings for other environments but not this one is not evaluated, and gets no registry token" {
  aws_unit units/network
  mkdir -p units/network/config/backend && touch units/network/config/backend/staging.hcl
  REGISTRY_HOST="registry.iltero-test.io" run "${PREVIEW}" run production
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"units/network/config/backend/production.hcl is missing."* ]]
  ! grep -q "^audience " "${STUB_LOG}" || false
  ! grep -q "^terraform network" "${STUB_LOG}" || false
}

@test "variables files outside the unit's config folder are not used" {
  aws_unit units/network
  mkdir -p config units/network/config
  touch config/production.tfvars config/production.tfvars.json units/network/config/production.tfvars
  run "${PREVIEW}" run production
  ! grep -q -- "-var-file=${STACK}/" "${STUB_LOG}" || false
}

@test "the remote-state switch file comes after the unit's variables file" {
  aws_unit units/compute
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  mkdir -p units/compute/config && touch units/compute/config/production.tfvars.json
  run "${PREVIEW}" run production
  grep -q -- "-var-file=${STACK}/units/compute/config/production.tfvars.json -var-file=${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/compute/without-upstream.tfvars" "${STUB_LOG}"
}

@test "the checkout is left as it was" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  [ ! -e units/network/zzz_iltero_preview_override.tf ]
}

@test "the lock file is only read, as committed" {
  aws_unit units/network
  run "${PREVIEW}" run production
  grep -qx "terraform network init -input=false -no-color -lockfile=readonly" "${STUB_LOG}"
}

@test "a unit with no lock file is not evaluated, as the deploy would refuse it" {
  aws_unit units/network
  rm units/network/.terraform.lock.hcl
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"the lock file is read-only"* ]]
  grep -q "| network | not evaluated: the preview could not plan the unit |" "${GITHUB_STEP_SUMMARY}"
  [ ! -e units/network/.terraform.lock.hcl ]
}

# --- planning without upstream state ----------------------------------------

@test "a unit with the remote-state switch is planned with it off and labelled as planned without upstream state" {
  aws_unit units/compute
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local switch="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/compute/without-upstream.tfvars"
  grep -q "terraform compute plan .*-var-file=${switch}" "${STUB_LOG}"
  [ "$(cat "${switch}")" = "enable_remote_state_dependencies = false" ]
  grep -q "| compute | passed (planned without the state of the units it reads, so the result can differ after the merge) |" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit without the remote-state switch is planned as it is" {
  aws_unit units/network
  run "${PREVIEW}" run production
  ! grep -q "enable_remote_state_dependencies" "${STUB_LOG}" || false
  grep -q "| network | passed |" "${GITHUB_STEP_SUMMARY}"
}

# --- not evaluated -----------------------------------------------------------

@test "a unit that cannot be planned is not evaluated and fails the step" {
  aws_unit units/network
  aws_unit units/compute
  touch "${BATS_TEST_TMPDIR}/plan-fails-compute"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  ! grep -q -- "--unit=compute " "${STUB_LOG}" || false
  grep -q -- "--unit=network " "${STUB_LOG}"
  grep -q "| compute | not evaluated" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit with a provider that has no adapter is not evaluated" {
  mkdir -p units/app
  echo 'provider "google" {}' > units/app/main.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The preview cannot plan provider 'google' without credentials. It supports: aws."* ]]
  ! grep -q "terraform app" "${STUB_LOG}" || false
}

@test "a unit that already has the override file name is not evaluated" {
  aws_unit units/network
  touch units/network/zzz_iltero_preview_override.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The preview adds a file named zzz_iltero_preview_override.tf to each unit, and this unit already has one."* ]]
  [ -e units/network/zzz_iltero_preview_override.tf ]
}

@test "a unit whose override file name is a link to nothing is not evaluated, and nothing is written through it" {
  aws_unit units/network
  ln -s "${BATS_TEST_TMPDIR}/elsewhere.tf" units/network/zzz_iltero_preview_override.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [ ! -e "${BATS_TEST_TMPDIR}/elsewhere.tf" ]
}

@test "a unit that configures no provider of its own still gets mock AWS keys" {
  mkdir -p units/network
  echo 'module "vpc" { source = "./vpc" }' > units/network/main.tf
  run "${PREVIEW}" run production
  local env_file="${BATS_TEST_TMPDIR}/terraform-env-network"
  grep -qx "AWS_ACCESS_KEY_ID=iltero-preview-mock" "${env_file}"
  grep -qx "AWS_EC2_METADATA_DISABLED=true" "${env_file}"
}

# --- checking ----------------------------------------------------------------

@test "each plan is checked locally by the CLI with the pinned evaluator, never on the server" {
  aws_unit units/network
  run "${PREVIEW}" run production
  local work="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/network"
  grep -q "iltero iac check --stage=plan --plan=${work}/plan.json --saved-plan=${work}/tfplan --environment=production --unit=network --out=${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/out --local ILTERO_OPA_PATH=${TOOLS}/bin/opa" "${STUB_LOG}"
}

@test "a failing check fails the step and the summary shows the CLI's exit code" {
  aws_unit units/network
  CHECK_EXIT=1 run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  grep -q "| network | failed |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failing check fails the step with the CLI's own exit code" {
  aws_unit units/network
  CHECK_EXIT=3 run "${PREVIEW}" run production
  [ "${status}" -eq 3 ]
  grep -q "| network | failed |" "${GITHUB_STEP_SUMMARY}"
  grep -q "^| network | failed |$" "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  ! grep -q "preview stopped" "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md" || false
}

@test "a stack with no unit stops the preview" {
  echo '[]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The CLI lists no units in this stack, so there is nothing to check."* ]]
}

@test "a run that stops before its result says so in the comment" {
  run "${PREVIEW}" environment
  grep -q "has not finished" "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  echo '[]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  grep -q "The preview stopped before it checked every unit. See the job summary and the log." "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  ! grep -q "has not finished" "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md" || false
}

@test "an environment the CLI cannot find leaves a comment that says the preview stopped" {
  DETECT_EXIT=2 run "${PREVIEW}" environment
  [ "${status}" -eq 2 ]
  grep -q "The preview stopped before it checked every unit." "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
}

@test "each unit starts with an empty work directory" {
  aws_unit units/network
  mkdir -p "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/network"
  echo "old output" > "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/network/stale.txt"
  run "${PREVIEW}" run production
  [ ! -e "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/units/network/stale.txt" ]
}

@test "the summary shows the CLI's output with HTML escaped" {
  aws_unit units/network
  run "${PREVIEW}" run production
  grep -q "verdict &lt;b&gt;fail&lt;/b&gt; &amp; more" "${GITHUB_STEP_SUMMARY}"
}

@test "the records directory is an output" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "$(output_value records-directory)" = "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/out" ]
}

@test "a preview run starts with no earlier records or unit files, and keeps the comment" {
  aws_unit units/network
  local root="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}"
  mkdir -p "${root}/out/units/retired" "${root}/units/retired" "${root}/comment"
  echo '{}' > "${root}/out/units/retired/car.json"
  echo "from the environment step" > "${root}/comment/kept.md"
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  [ ! -e "${root}/out/units/retired" ]
  [ ! -e "${root}/units/retired" ]
  [ -f "${root}/comment/kept.md" ]
}

@test "each stack has its own preview work folder, so two previews in one job keep their files apart" {
  aws_unit units/network
  run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local first="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}"
  cp -R "${STACK}" "${BATS_TEST_TMPDIR}/second-stack"
  cd "${BATS_TEST_TMPDIR}/second-stack"
  local second
  second="$(stack_folder_name)"
  [ "${second}" != "${STACK_FOLDER}" ]
  : > "${GITHUB_OUTPUT}"
  ENVIRONMENT=production run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  [ "$(output_value comment-directory)" = "${RUNNER_TEMP}/iltero-preview/${second}/comment" ]
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  [ "$(output_value records-directory)" = "${RUNNER_TEMP}/iltero-preview/${second}/out" ]
  [ -d "${first}/out" ]
  [ -f "${first}/comment/comment.md" ]
  [ -f "${RUNNER_TEMP}/iltero-preview/${second}/comment/comment.md" ]
}

@test "the comment holds the summary, the escaped output and a link to the run" {
  aws_unit units/network
  run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  grep -q "^| network | passed |$" "${comment}"
  grep -q "verdict &lt;b&gt;fail&lt;/b&gt; &amp; more" "${comment}"
  grep -qF "Commit ${HEAD_SHA}. [See the job summary](https://github.example/octo/stack/actions/runs/99)" "${comment}"
  ! grep -q "has not finished" "${comment}" || false
}

@test "until the run finishes, the comment says the preview has not finished" {
  run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  [ "$(output_value comment-directory)" = "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment" ]
  grep -q "The preview has not finished." "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  grep -qF "Commit ${HEAD_SHA}." "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
}

@test "the comment needs the pull request's head commit" {
  HEAD_SHA="main" run "${PREVIEW}" environment
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HEAD_SHA is not the pull request's head commit"* ]]
}

@test "an environment name with Markdown in it is refused" {
  aws_unit units/network
  run "${PREVIEW}" run "[x](javascript:e.test)"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot name a directory or a file. Use only letters, digits"* ]]
}

@test "the CLI's output cannot mention anyone in the summary or the comment" {
  aws_unit units/network
  CHECK_OUTPUT="ping @octo/admins" run "${PREVIEW}" run production
  grep -q "ping &#64;octo/admins" "${GITHUB_STEP_SUMMARY}"
  grep -q "ping &#64;octo/admins" "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
}

@test "output too long for a comment is left to the job summary" {
  aws_unit units/network
  CHECK_OUTPUT="$(printf 'x%.0s' {1..60001})" run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  grep -q "^| network | passed |$" "${comment}"
  grep -q "The CLI's output is too long for a comment." "${comment}"
  ! grep -q "<details>" "${comment}" || false
  grep -q "xxxxxxxxxx" "${GITHUB_STEP_SUMMARY}"
}

@test "a run without its GitHub context writes no comment, fails, and still sets the records directory" {
  aws_unit units/network
  GITHUB_RUN_ID="" run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [ ! -e "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md" ]
  [ "$(output_value records-directory)" = "${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/out" ]
}

@test "the CLI's output stays inside its block when it has blank lines" {
  aws_unit units/network
  CHECK_OUTPUT=$'first\n\n[link](https://example.test)' run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/${STACK_FOLDER}/comment/comment.md"
  run awk '/^<pre>$/ { inside = 1; next } /^<\/pre>$/ { inside = 0 } /link\]/ { print (inside ? "inside" : "outside") }' "${comment}"
  [ "${output}" = "inside" ]
}

@test "a line of the CLI's output cannot act as a workflow command" {
  aws_unit units/network
  CHECK_OUTPUT="::set-output name=records-directory::/elsewhere" run "${PREVIEW}" run production
  commands_paused_around "::set-output name=records-directory::/elsewhere"
}

@test "a line of Terraform's output cannot act as a workflow command" {
  aws_unit units/network
  touch "${BATS_TEST_TMPDIR}/plan-fails-network"
  run "${PREVIEW}" run production
  commands_paused_around "Error: no credentials"
}

@test "the comment artifact is named after the records artifact, and empty without a comment" {
  grep -qF "value: \${{ steps.environment.outputs.comment-directory != '' && format('{0}-comment', inputs.artifact-name) || '' }}" "${REPO_ROOT}/preview/action.yml"
  # The action's own text is matched as written.
  # shellcheck disable=SC2016
  grep -qF 'name: ${{ inputs.artifact-name }}-comment' "${REPO_ROOT}/preview/action.yml"
}

@test "a unit directory that starts with a dash is refused" {
  echo '[{"name": "network", "working_directory": "-L"}]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit 'network' has a directory that starts with '-': '-L'. Rename the directory."* ]]
}

@test "a result table too long for a comment on its own is left to the job summary" {
  {
    echo "## Iltero preview: production"
    printf '| unit-%s | passed |\n' $(seq 1 4000)
  } > "${BATS_TEST_TMPDIR}/summary.md"
  : > "${BATS_TEST_TMPDIR}/details.md"
  run bash -c "source '${PREVIEW}'; write_result_comment '${BATS_TEST_TMPDIR}/comment' '${BATS_TEST_TMPDIR}/summary.md' '${BATS_TEST_TMPDIR}/details.md'"
  [ "${status}" -eq 0 ]
  local comment="${BATS_TEST_TMPDIR}/comment/comment.md"
  grep -qx "## Iltero preview: production" "${comment}"
  grep -qx "The result is too long for a comment." "${comment}"
  ! grep -q "unit-1 " "${comment}" || false
  [ "$(wc -c < "${comment}")" -lt 60000 ]
}
