#!/usr/bin/env bats
#
# Tests for scripts/preview.sh, the body of the `preview` action.

load test_helper

setup() {
  make_runner
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example"
  export ACTIONS_RUNTIME_TOKEN="runtime-token"
  export TF_TOKEN_registry_example="registry-token"
  export ASSURE_EXIT=0
  export ASSURE_OUTPUT="verdict <b>fail</b> & more"
  export GITHUB_SERVER_URL="https://github.example"
  export GITHUB_REPOSITORY="octo/stack"
  export GITHUB_RUN_ID="99"
  export HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
  export UNITS_JSON="${BATS_TEST_TMPDIR}/units.json"
  : > "${GITHUB_STEP_SUMMARY}"
  PREVIEW="${REPO_ROOT}/scripts/preview.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for Terraform. It records its arguments, its environment and
  # the override file, and writes a lock file on init as Terraform does.
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
    touch .terraform.lock.hcl
    ;;
  plan)
    [[ ! -e "${BATS_TEST_TMPDIR}/plan-fails-\${unit}" ]] || { echo "Error: no credentials"; exit 1; }
    ;;
  show) echo '{}' ;;
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
if [[ "$1" == "assure" ]]; then
  echo "${ASSURE_OUTPUT}"
  exit "${ASSURE_EXIT}"
fi
EOF
  chmod +x "${TOOLS}/bin/terraform" "${TOOLS}/venv/bin/iltero"

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}"
  cd "${STACK}"
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
}

# --- check -------------------------------------------------------------------

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

@test "check refuses an artifact name the comment action could not use" {
  run "${PREVIEW}" check 'x -->'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name"* ]]
}

@test "check requires Terraform and the CLI from setup" {
  rm "${TOOLS}/bin/terraform"
  run "${PREVIEW}" check iltero-preview
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform is not installed"* ]]
}

# --- environment -------------------------------------------------------------

@test "environment asks the CLI, which writes the output" {
  run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  grep -q "iltero environment detect --format=github-actions" "${STUB_LOG}"
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

@test "a unit that breaks the unit-name rule is refused" {
  aws_unit units/Network
  echo '[{"name": "Network", "working_directory": "units/Network"}]' > "${UNITS_JSON}"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not follow the unit-name rule"* ]]
}

# --- planning without credentials --------------------------------------------

@test "Terraform runs with a scrubbed environment and mock AWS keys" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local env_file="${BATS_TEST_TMPDIR}/terraform-env-network"
  ! grep -qE '^(GITHUB_ENV|GITHUB_OUTPUT|GITHUB_PATH|GITHUB_STEP_SUMMARY|ACTIONS_ID_TOKEN_REQUEST_URL|ACTIONS_RUNTIME_TOKEN|TF_TOKEN_[^=]*)=' "${env_file}"
  grep -qx "AWS_ACCESS_KEY_ID=iltero-preview-mock" "${env_file}"
  grep -qx "AWS_EC2_METADATA_DISABLED=true" "${env_file}"
  grep -q "^TF_DATA_DIR=${RUNNER_TEMP}/iltero-preview/units/network/" "${env_file}"
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
  ! grep -q "assume_role" "${BATS_TEST_TMPDIR}/override-network.tf"
}

@test "the AWS adapter drops the role only for a unit that assumes one" {
  aws_unit units/network role
  run "${PREVIEW}" run production
  grep -q "assume_role {}" "${BATS_TEST_TMPDIR}/override-network.tf"
}

@test "the environment's variables file is used when it exists" {
  aws_unit units/network
  mkdir -p config && touch config/production.tfvars
  run "${PREVIEW}" run production
  grep -q -- "-var-file=${STACK}/config/production.tfvars" "${STUB_LOG}"
}

@test "the remote-state switch file comes after the environment's variables file" {
  aws_unit units/compute
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  mkdir -p config && touch config/production.tfvars
  run "${PREVIEW}" run production
  grep -q -- "-var-file=${STACK}/config/production.tfvars -var-file=${RUNNER_TEMP}/iltero-preview/units/compute/without-upstream.tfvars" "${STUB_LOG}"
}

@test "the checkout is left as it was" {
  aws_unit units/network
  aws_unit units/compute
  touch units/compute/.terraform.lock.hcl
  run "${PREVIEW}" run production
  [ ! -e units/network/zzz_iltero_preview_override.tf ]
  [ ! -e units/network/.terraform.lock.hcl ]
  [ -e units/compute/.terraform.lock.hcl ]
}

# --- planning without upstream state ----------------------------------------

@test "a unit with the remote-state switch is planned with it off and labelled best effort" {
  aws_unit units/compute
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 0 ]
  local switch="${RUNNER_TEMP}/iltero-preview/units/compute/without-upstream.tfvars"
  grep -q "terraform compute plan .*-var-file=${switch}" "${STUB_LOG}"
  [ "$(cat "${switch}")" = "enable_remote_state_dependencies = false" ]
  grep -q "| compute | exit 0 (best effort: planned without upstream state) |" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit without the remote-state switch is planned as it is" {
  aws_unit units/network
  run "${PREVIEW}" run production
  ! grep -q "enable_remote_state_dependencies" "${STUB_LOG}"
  grep -q "| network | exit 0 |" "${GITHUB_STEP_SUMMARY}"
}

# --- not evaluated -----------------------------------------------------------

@test "a unit that cannot be planned is not evaluated and fails the step" {
  aws_unit units/network
  aws_unit units/compute
  touch "${BATS_TEST_TMPDIR}/plan-fails-compute"
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  ! grep -q -- "--unit=compute " "${STUB_LOG}"
  grep -q -- "--unit=network " "${STUB_LOG}"
  grep -q "| compute | not evaluated" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit with a provider that has no adapter is not evaluated" {
  mkdir -p units/app
  echo 'provider "google" {}' > units/app/main.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"No preview adapter for provider 'google'"* ]]
  ! grep -q "terraform app" "${STUB_LOG}"
}

@test "a unit that already has the override file name is not evaluated" {
  aws_unit units/network
  touch units/network/zzz_iltero_preview_override.tf
  run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [ -e units/network/zzz_iltero_preview_override.tf ]
}

# --- checking ----------------------------------------------------------------

@test "each plan is checked by the CLI with the pinned evaluator" {
  aws_unit units/network
  run "${PREVIEW}" run production
  local work="${RUNNER_TEMP}/iltero-preview/units/network"
  grep -q "iltero assure --stage=plan --plan=${work}/plan.json --plan-binary=${work}/tfplan --environment=production --unit=network --out=${RUNNER_TEMP}/iltero-preview/out ILTERO_OPA_PATH=${TOOLS}/bin/opa" "${STUB_LOG}"
}

@test "a failing check fails the step and the summary shows the CLI's exit code" {
  aws_unit units/network
  ASSURE_EXIT=1 run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  grep -q "| network | exit 1 |" "${GITHUB_STEP_SUMMARY}"
}

@test "the summary shows the CLI's output with HTML escaped" {
  aws_unit units/network
  run "${PREVIEW}" run production
  grep -q "verdict &lt;b&gt;fail&lt;/b&gt; &amp; more" "${GITHUB_STEP_SUMMARY}"
}

@test "the records directory is an output" {
  aws_unit units/network
  run "${PREVIEW}" run production
  [ "$(output_value out-dir)" = "${RUNNER_TEMP}/iltero-preview/out" ]
}

@test "the comment holds the summary, the escaped output and a link to the run" {
  aws_unit units/network
  run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/comment/comment.md"
  grep -q "^| network | exit 0 |$" "${comment}"
  grep -q "verdict &lt;b&gt;fail&lt;/b&gt; &amp; more" "${comment}"
  grep -qF "Commit ${HEAD_SHA}. [See the job summary](https://github.example/octo/stack/actions/runs/99)" "${comment}"
  ! grep -q "has not finished" "${comment}"
}

@test "until the run finishes, the comment says the preview has not finished" {
  run "${PREVIEW}" environment
  [ "${status}" -eq 0 ]
  [ "$(output_value comment-dir)" = "${RUNNER_TEMP}/iltero-preview/comment" ]
  grep -q "The preview has not finished." "${RUNNER_TEMP}/iltero-preview/comment/comment.md"
  grep -qF "Commit ${HEAD_SHA}." "${RUNNER_TEMP}/iltero-preview/comment/comment.md"
}

@test "the comment needs the pull request's head commit" {
  HEAD_SHA="main" run "${PREVIEW}" environment
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HEAD_SHA is not the pull request's head commit"* ]]
}

@test "the environment's name cannot add Markdown to the heading" {
  aws_unit units/network
  run "${PREVIEW}" run "[x](https://e.test)"
  grep -qF '## Iltero preview: \[x\]\(https\:\/\/e\.test\)' "${GITHUB_STEP_SUMMARY}"
}

@test "the CLI's output cannot mention anyone in the summary or the comment" {
  aws_unit units/network
  ASSURE_OUTPUT="ping @octo/admins" run "${PREVIEW}" run production
  grep -q "ping &#64;octo/admins" "${GITHUB_STEP_SUMMARY}"
  grep -q "ping &#64;octo/admins" "${RUNNER_TEMP}/iltero-preview/comment/comment.md"
}

@test "output too long for a comment is left to the job summary" {
  aws_unit units/network
  ASSURE_OUTPUT="$(printf 'x%.0s' {1..60001})" run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/comment/comment.md"
  grep -q "^| network | exit 0 |$" "${comment}"
  grep -q "The CLI's output is too long for a comment." "${comment}"
  ! grep -q "<details>" "${comment}"
  grep -q "xxxxxxxxxx" "${GITHUB_STEP_SUMMARY}"
}

@test "a run without its GitHub context writes no comment, fails, and still uploads the records" {
  aws_unit units/network
  GITHUB_RUN_ID="" run "${PREVIEW}" run production
  [ "${status}" -eq 1 ]
  [ ! -e "${RUNNER_TEMP}/iltero-preview/comment/comment.md" ]
  [ "$(output_value out-dir)" = "${RUNNER_TEMP}/iltero-preview/out" ]
}

@test "the CLI's output stays inside its block when it has blank lines" {
  aws_unit units/network
  ASSURE_OUTPUT=$'first\n\n[link](https://example.test)' run "${PREVIEW}" run production
  local comment="${RUNNER_TEMP}/iltero-preview/comment/comment.md"
  run awk '/^<pre>$/ { inside = 1; next } /^<\/pre>$/ { inside = 0 } /link\]/ { print (inside ? "inside" : "outside") }' "${comment}"
  [ "${output}" = "inside" ]
}

@test "a line of the CLI's output cannot act as a workflow command" {
  aws_unit units/network
  ASSURE_OUTPUT="::set-output name=out-dir::/elsewhere" run "${PREVIEW}" run production
  commands_paused_around "::set-output name=out-dir::/elsewhere"
}

@test "a line of Terraform's output cannot act as a workflow command" {
  aws_unit units/network
  touch "${BATS_TEST_TMPDIR}/plan-fails-network"
  run "${PREVIEW}" run production
  commands_paused_around "Error: no credentials"
}

@test "the comment artifact is named after the records artifact, and empty without a comment" {
  grep -qF "value: \${{ steps.environment.outputs.comment-dir != '' && format('{0}-comment', inputs.artifact-name) || '' }}" "${REPO_ROOT}/preview/action.yml"
  grep -qF 'name: ${{ inputs.artifact-name }}-comment' "${REPO_ROOT}/preview/action.yml"
}
