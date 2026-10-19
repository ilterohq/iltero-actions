#!/usr/bin/env bats
#
# Tests for scripts/deploy.sh, the body of the `deploy` action.

load test_helper

readonly RUN_ID="7d8e9f00-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
readonly PINS="sha256:abc"

setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export ACTIONS_RUNTIME_TOKEN="runtime-token"
  export TF_TOKEN_other_example="other-token"
  export AWS_ACCESS_KEY_ID="deploy-role-key"
  export TF_VAR_owner="platform-team"
  export TF_CLI_ARGS_plan="-refresh=false"
  export TERRAFORM_CONFIG="${BATS_TEST_TMPDIR}/terraformrc"
  export ILTERO_API_URL="https://api.example/v1"
  export REGISTRY_HOST=""
  export LINKED="true"
  export REPORT="true"
  : > "${GITHUB_STEP_SUMMARY}"
  DEPLOY="${REPO_ROOT}/scripts/deploy.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  MARKS="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin" "${MARKS}"

  # A stand-in for Terraform. It records each call, and its environment at
  # init and plan. A file under MARKS named fail-<command>-<unit> makes that
  # command fail for that unit.
  cat > "${TOOLS}/bin/terraform" << STUB
#!/bin/bash
unit="\$(basename "\${PWD}")"
echo "terraform \${unit} \$*" >> "${STUB_LOG}"
[[ ! -e "${MARKS}/fail-\$1-\${unit}" ]] || exit 1
case "\$1" in
  init | plan) env | sort > "${BATS_TEST_TMPDIR}/terraform-env-\$1-\${unit}"; echo "terraform says \$1" ;;
  apply) echo '{"@level":"info"}'; echo "terraform warns on apply" >&2 ;;
  show) echo '{}'; echo "terraform warns on show" >&2 ;;
esac
STUB

  # A stand-in for the CLI. A file under MARKS named exit-<stage>-<unit> holds
  # the exit code of that stage for that unit; exit-state-<unit> holds the
  # state check's, and exit-report-<unit> the report's; no-report-<unit> makes
# the report exit 5 without writing. Each stage writes the
  # unit's record; the report writes car-report.<format> into --out.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
if [[ "$1 $2" == "state check" ]]; then
  unit="$(basename "${3#--dir=}")"
  echo "state check data ${TF_DATA_DIR}" >> "${STUB_LOG}"
  echo "state <checked> for ${unit}"
  mark="${MARKS}/exit-state-${unit}"
  [[ -e "${mark}" ]] && exit "$(cat "${mark}")"
  exit 0
fi
if [[ "$1 $2" == "car report" ]]; then
  unit="$(basename "$3")" format="${4#--format=}" dir="${5#--out=}"
  [[ "${format}" == markdown ]] && extension=md || extension="${format}"
  [[ -e "${MARKS}/no-report-${unit}" ]] && exit 5
  echo "report <${format}> of ${unit}" > "${dir}/car-report.${extension}"
  echo "report written for ${unit}"
  mark="${MARKS}/exit-report-${unit}"
  [[ -e "${mark}" ]] && exit "$(cat "${mark}")"
  exit 0
fi
if [[ "$1 $2" == "units list" ]]; then
  cat "${UNITS_JSON}"
  exit 0
fi
if [[ "$1 $2" == "config show" ]]; then
  [[ -z "${CONFIG_EXIT:-}" ]] || exit "${CONFIG_EXIT}"
  echo "{\"linked\": ${LINKED}, \"stack_id\": null}"
  exit 0
fi
stage="" unit="" out=""
for arg in "$@"; do
  case "${arg}" in
    --stage=*) stage="${arg#--stage=}" ;;
    --unit=*) unit="${arg#--unit=}" ;;
    --out=*) out="${arg#--out=}" ;;
  esac
done
mkdir -p "${out}/units/${unit}"
touch "${out}/units/${unit}/car.json"
echo "${stage} <checked> for ${unit}"
mark="${MARKS}/exit-${stage}-${unit}"
[[ -e "${mark}" ]] && exit "$(cat "${mark}")"
exit 0
STUB

  # The CLI's Python. The identity-token request is answered with a fake
  # token naming its audience; anything else runs the real interpreter.
  cat > "${TOOLS}/venv/bin/python" << 'STUB'
#!/bin/bash
if [[ "$1" == "-c" && "$2" == *ACTIONS_ID_TOKEN_REQUEST_URL* ]]; then
  echo "audience ${AUDIENCE}" >> "${STUB_LOG}"
  echo "id-token-for-${AUDIENCE}"
  exit 0
fi
exec python3 "$@"
STUB
  chmod +x "${TOOLS}/bin/terraform" "${TOOLS}/venv/bin/iltero" "${TOOLS}/venv/bin/python"
  export MARKS

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/compute"
  touch "${STACK}/units/network/main.tf" "${STACK}/units/compute/main.tf"
  cd "${STACK}"
  export UNITS_JSON="${BATS_TEST_TMPDIR}/units.json"
  cat > "${UNITS_JSON}" << 'JSON'
[
  {"name": "network", "depends_on": [], "working_directory": "units/network"},
  {"name": "compute", "depends_on": ["network"], "working_directory": "units/compute"}
]
JSON
}

deploy() {
  run "${DEPLOY}" run production "${RUN_ID}" "${PINS}"
}

deploy_locally() {
  run "${DEPLOY}" run production "" ""
}

# --- check -------------------------------------------------------------------

@test "check refuses pull request, pull_request_target and workflow_run events" {
  local event
  for event in pull_request pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${DEPLOY}" check
    [ "${status}" -eq 1 ]
  done
}

@test "check requires the CLI and Terraform" {
  run "${DEPLOY}" check
  [ "${status}" -eq 0 ]
  rm "${TOOLS}/bin/terraform"
  run "${DEPLOY}" check
  [ "${status}" -eq 1 ]
}

# --- linked or local ---------------------------------------------------------

@test "a linked project deploys only in a governed run" {
  deploy_locally
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"This project is linked to Iltero Platform. Deploy it in a governed run: "* ]]
  ! grep -q "^terraform" "${STUB_LOG}"
}

@test "a governed run needs id-token: write" {
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="" deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id-token: write"* ]]
}

@test "a project without a platform section cannot deploy in a governed run" {
  LINKED=false deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no platform section"* ]]
  ! grep -q "^terraform" "${STUB_LOG}"
}

@test "a project without a platform section cannot use the Iltero registry" {
  LINKED=false REGISTRY_HOST="registry.example.io" deploy_locally
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"module registry"* ]]
}

@test "a project without a platform section deploys locally: no run, no upload, no pre-deploy, no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  LINKED=false deploy_locally
  [ "${status}" -eq 0 ]
  ! grep -qE -- "--run-id|--pins-digest|--upload|--stage=pre-deploy" "${STUB_LOG}"
  grep -q "iltero assure --stage=plan .*--unit=network --out=${RUNNER_TEMP}/iltero-deploy/out$" "${STUB_LOG}"
  grep -q "iltero assure --stage=post-deploy .*--unit=network --out=${RUNNER_TEMP}/iltero-deploy/out$" "${STUB_LOG}"
  grep -q "terraform network apply" "${STUB_LOG}"
  grep -q "| network | exit 0 | not in scope | exit 0 | exit 0 |" "${GITHUB_STEP_SUMMARY}"
}

@test "a config the CLI cannot report never falls back to a local deploy" {
  CONFIG_EXIT=2 run "${DEPLOY}" run production "" ""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no valid .iltero/config.yml"* ]]
  [ "$(grep -v '^iltero config show' "${STUB_LOG}")" = "" ]
}

@test "the deploy stops when the CLI finds no valid config" {
  CONFIG_EXIT=2 deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no valid .iltero/config.yml"* ]]
  [ "$(grep -v '^iltero config show' "${STUB_LOG}")" = "" ]
}

# --- units -------------------------------------------------------------------

@test "units are deployed in the order the CLI prints, from the directory it prints" {
  deploy
  [ "${status}" -eq 0 ]
  grep -q "iltero units list --format=json" "${STUB_LOG}"
  [ "$(grep -o 'terraform [a-z]* init' "${STUB_LOG}" | cut -d' ' -f2 | tr '\n' ' ')" = "network compute " ]
}

@test "a unit list with a bad name, an escaping directory or a missing directory stops before anything runs" {
  local listing
  for listing in \
    '[{"name": "Network", "working_directory": "units/network"}]' \
    '[{"name": "network", "working_directory": "../elsewhere"}]' \
    '[{"name": "network", "working_directory": "/etc"}]' \
    '[{"name": "network", "working_directory": "units/missing"}]' \
    '{"name": "network"}'; do
    echo "${listing}" > "${UNITS_JSON}"
    : > "${STUB_LOG}"
    deploy
    [ "${status}" -eq 1 ]
    ! grep -q "^terraform" "${STUB_LOG}"
  done
}

@test "the deploy stops before anything runs when the CLI cannot list the units" {
  rm "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "^terraform" "${STUB_LOG}"
}

# --- one unit, in order --------------------------------------------------------

@test "each unit is initialized, state checked, planned, checked, pre-deploy checked, applied and post-deploy checked, in that order" {
  echo '[{"name": "network", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^(terraform network [a-z]+|iltero assure --stage=[a-z-]+|iltero state check)' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "terraform network init,iltero state check,terraform network plan,terraform network show,iltero assure --stage=plan,iltero assure --stage=pre-deploy,terraform network apply,terraform network show,iltero assure --stage=post-deploy," ]
}

@test "every stage joins the run and uploads" {
  deploy
  local work="${RUNNER_TEMP}/iltero-deploy/units/network"
  local run_args="--unit=network --out=${RUNNER_TEMP}/iltero-deploy/out --run-id=${RUN_ID} --pins-digest=${PINS} --upload"
  grep -qx "iltero assure --stage=plan --plan=${work}/plan.json --plan-binary=${work}/tfplan --environment=production ${run_args}" "${STUB_LOG}"
  grep -qx "iltero assure --stage=pre-deploy ${run_args}" "${STUB_LOG}"
  grep -qx "iltero assure --stage=post-deploy --plan=${work}/plan.json --plan-binary=${work}/tfplan --apply-log=${work}/apply.ndjson --state=${work}/state.json ${run_args}" "${STUB_LOG}"
}

@test "the apply uses the saved plan and its output is kept unchanged for the CLI" {
  deploy
  local work="${RUNNER_TEMP}/iltero-deploy/units/network"
  grep -q "terraform network apply -input=false -json ${work}/tfplan" "${STUB_LOG}"
  [ "$(cat "${work}/apply.ndjson")" = '{"@level":"info"}' ]
}

@test "init uses the lock file as committed and the environment's backend settings" {
  mkdir -p config/backend && touch config/backend/production.hcl
  deploy
  grep -q "terraform network init -input=false -no-color -lockfile=readonly -backend-config=${STACK}/config/backend/production.hcl" "${STUB_LOG}"
}

@test "plan uses the environment's variables and sets the remote-state switch to true from a file, last" {
  mkdir -p config && touch config/production.tfvars
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  deploy
  local switch="${RUNNER_TEMP}/iltero-deploy/units/compute/with-upstream.tfvars"
  grep -q "terraform compute plan .* -var-file=${STACK}/config/production.tfvars -var-file=${switch}$" "${STUB_LOG}"
  [ "$(cat "${switch}")" = "enable_remote_state_dependencies = true" ]
  ! grep -q "terraform network plan .*with-upstream" "${STUB_LOG}"
}

# --- what Terraform can reach ------------------------------------------------

@test "Terraform gets only PATH, HOME, its own settings, cloud credentials and TF_VAR_ values" {
  deploy
  local env_file
  for env_file in "${BATS_TEST_TMPDIR}"/terraform-env-*; do
    grep -qx "AWS_ACCESS_KEY_ID=deploy-role-key" "${env_file}"
    grep -qx "TF_VAR_owner=platform-team" "${env_file}"
    ! grep -vE '^(PATH|HOME|PWD|SHLVL|_|OLDPWD|TF_IN_AUTOMATION|TF_INPUT|TF_DATA_DIR|AWS_ACCESS_KEY_ID|TF_VAR_owner)=' "${env_file}"
  done
}

@test "a line of Terraform's or the CLI's output cannot act as a workflow command" {
  deploy
  [ "${status}" -eq 0 ]
  commands_paused_around "plan <checked> for network"
  commands_paused_around "terraform says plan"
  commands_paused_around "terraform warns on apply"
  commands_paused_around "terraform warns on show"
}

@test "the registry token reaches only init, for the registry host's origin, and is masked" {
  REGISTRY_HOST="registry.iltero-test.io" deploy
  [ "${status}" -eq 0 ]
  grep -qx "audience https://registry.iltero-test.io" "${STUB_LOG}"
  grep -qx "TF_TOKEN_registry_iltero__test_io=id-token-for-https://registry.iltero-test.io" "${BATS_TEST_TMPDIR}/terraform-env-init-network"
  ! grep -q "^TF_TOKEN_registry" "${BATS_TEST_TMPDIR}/terraform-env-plan-network"
  [[ "${output}" == *"::add-mask::id-token-for-https://registry.iltero-test.io"* ]]
  [ "$(grep -c '^audience' "${STUB_LOG}")" -eq 2 ]
  ! grep -rq "id-token-for" "${GITHUB_ENV}" "${GITHUB_OUTPUT}" "${RUNNER_TEMP}/iltero-deploy" 2> /dev/null
}

@test "no registry token is made when no registry host is given" {
  deploy
  ! grep -q "^audience" "${STUB_LOG}"
}

@test "a registry token needs no ILTERO_API_URL" {
  unset ILTERO_API_URL
  REGISTRY_HOST="registry.iltero-test.io" deploy
  [ "${status}" -eq 0 ]
  grep -qx "audience https://registry.iltero-test.io" "${STUB_LOG}"
}

# --- failures ----------------------------------------------------------------

@test "a failed plan check stops the deploy with the CLI's exit code" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "stage=pre-deploy" "${STUB_LOG}"
  ! grep -q "terraform network apply" "${STUB_LOG}"
  ! grep -q "terraform compute" "${STUB_LOG}"
  grep -q "| network | exit 1 | - | - | - |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed pre-deploy check stops the deploy before the apply" {
  echo 3 > "${MARKS}/exit-pre-deploy-network"
  deploy
  [ "${status}" -eq 3 ]
  ! grep -q "terraform network apply" "${STUB_LOG}"
}

@test "a failed apply is still checked after, and fails with the apply's code" {
  touch "${MARKS}/fail-apply-network"
  deploy
  [ "${status}" -eq 1 ]
  grep -q "stage=post-deploy" "${STUB_LOG}"
  ! grep -q "terraform compute" "${STUB_LOG}"
  grep -q "| network | exit 0 | exit 0 | exit 1 | exit 0 |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed post-deploy check fails with the CLI's exit code and stops later units" {
  echo 9 > "${MARKS}/exit-post-deploy-network"
  deploy
  [ "${status}" -eq 9 ]
  ! grep -q "terraform compute" "${STUB_LOG}"
}

@test "a failed Terraform plan stops the deploy before any check" {
  touch "${MARKS}/fail-plan-compute"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "unit=compute" "${STUB_LOG}"
  grep -q "| compute | terraform failed | - | - | - |" "${GITHUB_STEP_SUMMARY}"
}

@test "the state check reads each unit's directory with the data directory Terraform used" {
  deploy
  [ "${status}" -eq 0 ]
  local unit data
  for unit in network compute; do
    grep -q "^iltero state check --dir=units/${unit}$" "${STUB_LOG}"
    data="$(grep "^TF_DATA_DIR=" "${BATS_TEST_TMPDIR}/terraform-env-init-${unit}")"
    grep -qxF "state check data ${data#TF_DATA_DIR=}" "${STUB_LOG}"
  done
  commands_paused_around "state <checked> for network"
}

@test "a unit that keeps its state in its working directory stops the deploy before its plan and later units" {
  echo 5 > "${MARKS}/exit-state-network"
  deploy
  [ "${status}" -eq 5 ]
  ! grep -q "unit=network" "${STUB_LOG}"
  ! grep -q "terraform network plan" "${STUB_LOG}"
  ! grep -q "terraform compute" "${STUB_LOG}"
  grep -q "| network | state check exit 5 | - | - | - |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed Terraform init stops the deploy before the state check" {
  touch "${MARKS}/fail-init-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform could not initialize unit 'network'."* ]]
  ! grep -q "^iltero state check" "${STUB_LOG}"
  grep -q "| network | terraform failed | - | - | - |" "${GITHUB_STEP_SUMMARY}"
}

@test "each unit starts with an empty work folder" {
  local work="${RUNNER_TEMP}/iltero-deploy/units/network"
  mkdir -p "${work}/terraform-data"
  touch "${work}/terraform-data/left-over"
  deploy
  [ "${status}" -eq 0 ]
  [ ! -e "${work}/terraform-data/left-over" ]
}

@test "the summary shows the state check's output" {
  echo 5 > "${MARKS}/exit-state-network"
  deploy
  grep -q "<summary>network: state-check</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "state &lt;checked&gt; for network" "${GITHUB_STEP_SUMMARY}"
}

# --- summary and outputs -----------------------------------------------------

@test "the summary shows the CLI's output with HTML escaped" {
  deploy
  grep -q "plan &lt;checked&gt; for network" "${GITHUB_STEP_SUMMARY}"
}

@test "the records directory is an output, even when the deploy fails" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "$(output_value out-dir)" = "${RUNNER_TEMP}/iltero-deploy/out" ]
}

# --- report ------------------------------------------------------------------

@test "each unit's record gets a report, as an HTML page for the artifact and in the summary" {
  deploy
  [ "${status}" -eq 0 ]
  local reports="${RUNNER_TEMP}/iltero-deploy/reports" out="${RUNNER_TEMP}/iltero-deploy/out"
  grep -qx "report-dir=${reports}" "${GITHUB_OUTPUT}"
  grep -qx "iltero car report ${out}/units/network --format=html --out=${reports}/network" "${STUB_LOG}"
  grep -qx "iltero car report ${out}/units/compute --format=markdown --out=${reports}/compute" "${STUB_LOG}"
  [ -f "${reports}/network/car-report.html" ]
  grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -qx "report <markdown> of compute" "${GITHUB_STEP_SUMMARY}"
}

@test "with report false, no report is written" {
  REPORT=false deploy
  [ "${status}" -eq 0 ]
  ! grep -q "car report" "${STUB_LOG}"
  ! grep -q "^report-dir=" "${GITHUB_OUTPUT}"
}

@test "a report value other than true or false is refused" {
  REPORT=yes deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The report input must be true or false, not 'yes'."* ]]
  ! grep -q "^terraform" "${STUB_LOG}"
}

@test "a report that exits with another code than 0 is a warning, and the deploy keeps its result" {
  echo 9 > "${MARKS}/exit-report-network"
  deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::The CLI's report of unit 'network' exited with 9. See its output in the log."* ]]
  grep -q "iltero car report .*/units/compute --format=html" "${STUB_LOG}"
}

@test "the unit that stopped the deploy gets a report when it has a record, and a unit without one gets none" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  grep -q "iltero car report .*/units/network --format=html" "${STUB_LOG}"
  echo 5 > "${MARKS}/exit-state-network"
  rm -rf "${RUNNER_TEMP}/iltero-deploy"
  : > "${STUB_LOG}"
  deploy
  [ "${status}" -eq 5 ]
  ! grep -q "car report" "${STUB_LOG}"
}

@test "a failed stage keeps its exit code when its report fails too" {
  echo 3 > "${MARKS}/exit-plan-network"
  echo 9 > "${MARKS}/exit-report-network"
  deploy
  [ "${status}" -eq 3 ]
}

@test "a report too long for the job summary points to the artifact instead" {
  local big="${BATS_TEST_TMPDIR}/big"
  head -c 800001 /dev/zero | tr '\0' 'x' > "${big}"
  sed -i.bak "s|echo \"report <\${format}> of \${unit}\" > |cat '${big}' > |" "${TOOLS}/venv/bin/iltero"
  deploy
  [ "${status}" -eq 0 ]
  grep -qx "The report of unit network is too long for the job summary. It is in the report artifact." "${GITHUB_STEP_SUMMARY}"
  ! grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "a report the CLI does not write leaves no report in the summary, and no earlier report stays" {
  local old="${RUNNER_TEMP}/iltero-deploy/reports/network"
  mkdir -p "${old}"
  echo "old report" > "${old}/car-report.md"
  touch "${MARKS}/no-report-network"
  deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::The CLI's report of unit 'network' exited with 5."* ]]
  ! grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
  [ ! -e "${old}/car-report.md" ]
}

@test "the report's output cannot act as a workflow command" {
  deploy
  commands_paused_around "report written for network"
}
