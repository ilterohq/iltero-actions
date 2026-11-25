#!/usr/bin/env bats
#
# Tests for scripts/iac/deploy.sh, the body of the `deploy` action.

load ../test_helper

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
  export WRITE_REPORT="true"
  export STORE_RECORDS="false"
  : > "${GITHUB_STEP_SUMMARY}"
  DEPLOY="${REPO_ROOT}/scripts/iac/deploy.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  MARKS="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin" "${MARKS}"

  # A stand-in for Terraform. It records each call, and its environment at
  # init and plan. A file under MARKS named fail-<command>-<unit> makes that
  # command fail for that unit; fail-refresh-<unit> fails only its readings,
  # and fail-second-<unit> only its second reading; fail-replan-<unit> fails
  # only its plan made again before pre-deploy; fail-state-<unit> fails
  # only the read of the state after the apply; apply-error-<unit> makes the
  # apply log an error, then fail. A plan writes its -out file, unless
  # no-saved-plan-<unit> exists.
  cat > "${TOOLS}/bin/terraform" << STUB
#!/bin/bash
unit="\$(basename "\${PWD}")"
echo "terraform \${unit} \$*" >> "${STUB_LOG}"
# A fail mark may hold the exit code to fail with; an empty one fails with 1.
if [[ -e "${MARKS}/fail-\$1-\${unit}" ]]; then code="\$(cat "${MARKS}/fail-\$1-\${unit}")"; exit "\${code:-1}"; fi
[[ "\$*" != "show -json" || ! -e "${MARKS}/fail-state-\${unit}" ]] || exit 1
if [[ "\$1" == apply && -e "${MARKS}/apply-error-\${unit}" ]]; then
  echo '{"@level":"error","@message":"Error: creating bucket","type":"diagnostic","diagnostic":{"detail":"Access denied."}}'
  exit 1
fi
[[ "\$*" != *-refresh-only* || ! -e "${MARKS}/fail-refresh-\${unit}" ]] || exit 1
[[ "\$*" != *reading-second.tfplan* || ! -e "${MARKS}/fail-second-\${unit}" ]] || exit 1
[[ "\$*" != *replan.tfplan* || ! -e "${MARKS}/fail-replan-\${unit}" ]] || exit 1
case "\$1" in
  init | plan)
    env | sort > "${BATS_TEST_TMPDIR}/terraform-env-\$1-\${unit}"; echo "terraform says \$1"
    [[ -e "${MARKS}/no-saved-plan-\${unit}" ]] || for arg in "\$@"; do [[ "\${arg}" != -out=* ]] || echo "saved plan of \${unit}" > "\${arg#-out=}"; done
    ;;
  apply) echo '{"@level":"info","@message":"Apply complete! Resources: 1 added."}'; echo "terraform warns on apply" >&2 ;;
  show) echo '{}'; echo "terraform warns on show" >&2 ;;
esac
STUB

  # A stand-in for the CLI. A file under MARKS named exit-<stage>-<unit> holds
  # the exit code of that stage for that unit, and exit-scanners the scanner
  # install's; exit-state-<unit> holds the state check's, and
  # exit-report-<unit> the report's. no-report-<unit> makes
  # the report exit 5 without writing, and no-markdown-<unit> makes it write
  # only the HTML page. Each stage writes the unit's record, which expects
  # post-verify when expects-post-verify-<unit> exists and is unreadable when
  # bad-record-<unit> does, and absent when no-record-<unit> does. The record
  # leaves pre-deploy out when no-pre-deploy-<unit> exists. in-scope-exit-<stage>
  # and in-scope-exit-<stage>-<unit> hold the exit code of `record in-scope`.
  # The report writes record-report.<format> into --out. With change-plan-<unit>, the plan stage
  # changes the saved plan it was given; with change-json-<unit>, it changes
  # the plan's JSON; with remove-plan-<unit>, it removes the saved plan.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
if [[ "$1 $2" == "scanners install" ]]; then
  echo "scanners install ILTERO_CACHE_DIR=${ILTERO_CACHE_DIR}" >> "${STUB_LOG}"
  echo "Trivy <installed>"
  [[ ! -e "${MARKS}/exit-scanners" ]] || exit "$(cat "${MARKS}/exit-scanners")"
  exit 0
fi
if [[ "$1 $2" == "state check" ]]; then
  unit="$(basename "${3#--working-directory=}")"
  echo "state check data ${TF_DATA_DIR}" >> "${STUB_LOG}"
  echo "state <checked> for ${unit}"
  mark="${MARKS}/exit-state-${unit}"
  [[ -e "${mark}" ]] && exit "$(cat "${mark}")"
  exit 0
fi
if [[ "$1 $2" == "record report" ]]; then
  unit="$(basename "$3")" format="${4#--format=}" dir="${5#--out=}"
  [[ "${format}" == markdown ]] && extension=md || extension="${format}"
  [[ -e "${MARKS}/no-report-${unit}" ]] && exit 5
  [[ -e "${MARKS}/no-markdown-${unit}" && "${format}" == markdown ]] && exit 0
  echo "report <${format}> of ${unit}" > "${dir}/record-report.${extension}"
  echo "report written for ${unit}"
  mark="${MARKS}/exit-report-${unit}"
  [[ -e "${mark}" ]] && exit "$(cat "${mark}")"
  exit 0
fi
if [[ "$1 $2" == "record in-scope" ]]; then
  echo "::error::injected by the record"
  for mark in "${MARKS}/in-scope-exit-${4#--stage=}" "${MARKS}/in-scope-exit-${4#--stage=}-${3##*/}"; do
    [[ ! -e "${mark}" ]] || exit "$(cat "${mark}")"
  done
  [[ -f "$3/car.json" ]] || exit 5
  python3 -I -c 'import json, sys
try:
    stages = json.load(open(sys.argv[1]))["expected_stages"]
except Exception:
    sys.exit(9)
in_scope = sys.argv[2] in stages
print("The " + sys.argv[2] + " stage is " + ("in" if in_scope else "out of") + " scope.")
sys.exit(0 if in_scope else 3)' "$3/car.json" "${4#--stage=}"
  exit $?
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
stage="" unit="" out="" saved_plan="" plan_json=""
for arg in "$@"; do
  case "${arg}" in
    --stage=*) stage="${arg#--stage=}" ;;
    --unit=*) unit="${arg#--unit=}" ;;
    --out=*) out="${arg#--out=}" ;;
    --saved-plan=*) saved_plan="${arg#--saved-plan=}" ;;
    --plan=*) plan_json="${arg#--plan=}" ;;
  esac
done
[[ "${stage}" != plan || ! -e "${MARKS}/change-plan-${unit}" ]] || echo "changed" >> "${saved_plan}"
[[ "${stage}" != plan || ! -e "${MARKS}/change-json-${unit}" ]] || echo "changed" >> "${plan_json}"
[[ "${stage}" != plan || ! -e "${MARKS}/remove-plan-${unit}" ]] || rm -f "${saved_plan}"
mkdir -p "${out}/units/${unit}"
expected='"plan", "pre_deploy", "post_deploy"'
[[ ! -e "${MARKS}/no-pre-deploy-${unit}" ]] || expected='"plan", "post_deploy"'
[[ ! -e "${MARKS}/expects-post-verify-${unit}" ]] || expected="${expected}, \"post_verify\""
echo "{\"expected_stages\": [${expected}]}" > "${out}/units/${unit}/car.json"
[[ ! -e "${MARKS}/bad-record-${unit}" ]] || echo "not a record" > "${out}/units/${unit}/car.json"
[[ ! -e "${MARKS}/no-record-${unit}" ]] || rm -f "${out}/units/${unit}/car.json"
echo "${stage} <checked> for ${unit}"
# A post-deploy check given --state-unreadable exits 6, unless the test
# marks it as passing.
[[ " $* " != *" --state-unreadable "* || -e "${MARKS}/state-unreadable-passes" ]] || exit 6
mark="${MARKS}/exit-${stage}-${unit}"
[[ -e "${mark}" ]] && exit "$(cat "${mark}")"
exit 0
STUB

  # The CLI's Python. The identity-token request is answered with a fake
  # token naming its audience; anything else runs the real interpreter.
  cat > "${TOOLS}/venv/bin/python" << 'STUB'
#!/bin/bash
if [[ "$1" == "-I" && "$2" == "-c" && "$3" == *ACTIONS_ID_TOKEN_REQUEST_URL* ]]; then
  [[ -z "${MINT_FAILS:-}" ]] || exit 1
  echo "audience ${AUDIENCE}" >> "${STUB_LOG}"
  echo "id-token-for-${AUDIENCE}"
  exit 0
fi
exec python3 "$@"
STUB
  chmod +x "${TOOLS}/bin/terraform" "${TOOLS}/venv/bin/iltero" "${TOOLS}/venv/bin/python"
  # The Python installation the virtual environment runs on.
  mkdir -p "${BATS_TEST_TMPDIR}/python/bin"
  echo "home = ${BATS_TEST_TMPDIR}/python/bin" > "${TOOLS}/venv/pyvenv.cfg"
  # The stub's variables expand when it runs, not here.
  # shellcheck disable=SC2016
  stub sleep 'echo "sleep $*" >> "${STUB_LOG}"'
  # A clock that moves on one second at each call, so the deploy never needs
  # to wait before it plans a unit again.
  # shellcheck disable=SC2016
  stub date 'count="$(cat "${MARKS}/clock" 2>/dev/null || echo 1000)"; echo $((count + 1)) > "${MARKS}/clock"; echo "${count}"'
  export MARKS

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/compute"
  touch "${STACK}/units/network/main.tf" "${STACK}/units/compute/main.tf"
  cd "${STACK}" || return
  # The name the actions give this stack's work folder.
  STACK_FOLDER="$(stack_folder_name)"
  export UNITS_JSON="${BATS_TEST_TMPDIR}/units.json"
  cat > "${UNITS_JSON}" << 'JSON'
[
  {"name": "network", "depends_on": [], "working_directory": "units/network"},
  {"name": "compute", "depends_on": ["network"], "working_directory": "units/compute"}
]
JSON
}

deploy() {
  run "${DEPLOY}" run production
}

# --- check -------------------------------------------------------------------

@test "check refuses pull request, pull_request_target and workflow_run events" {
  local event
  for event in pull_request pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${DEPLOY}" check
    [ "${status}" -eq 1 ]
  done
}

@test "check refuses every event other than push, workflow_dispatch and schedule" {
  local event
  for event in issue_comment merge_group repository_dispatch; do
    GITHUB_EVENT_NAME="${event}" run "${DEPLOY}" check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"runs only on push, workflow_dispatch and schedule events"* ]]
  done
  for event in push workflow_dispatch schedule; do
    GITHUB_EVENT_NAME="${event}" run "${DEPLOY}" check
    [ "${status}" -eq 0 ]
  done
}

@test "deploy refuses a tool it has no adapter for, and any path in the tool's name" {
  local tool
  for tool in pulumi ../../x terraform/../x "" /tmp; do
    TOOL="${tool}" run "${DEPLOY}" check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The tool input must be one of: terraform. It is '${tool}'."* ]]
  done
}

@test "the post-verify readings run with workflow commands paused" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 0 ]
  [ "$(grep -c -- "-refresh-only" "${STUB_LOG}")" -eq 2 ]
  commands_paused_around "terraform says plan"
}

@test "check requires the CLI" {
  run "${DEPLOY}" check
  [ "${status}" -eq 0 ]
  rm "${TOOLS}/venv/bin/iltero"
  run "${DEPLOY}" check
  [ "${status}" -eq 1 ]
}

# --- linked or local ---------------------------------------------------------

@test "a linked project needs id-token: write" {
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="" deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id-token: write"* ]]
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

@test "an unreadable config report stops the deploy before Terraform runs" {
  LINKED='"yes"' deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"config report could not be read"* ]]
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

@test "an environment that cannot name a directory or a file is refused before anything runs" {
  local name
  for name in ../production . .. a/b 'prod*' 'prod uction' 'prod?'; do
    run "${DEPLOY}" run "${name}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
  done
  ! grep -q "^terraform" "${STUB_LOG}" || false
  [ ! -e "${RUNNER_TEMP}/iltero-deploy" ]
}

@test "run takes only the environment" {
  run "${DEPLOY}" run
  [ "${status}" -eq 1 ]
  run "${DEPLOY}" run production extra
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Usage: iac/deploy.sh run ENVIRONMENT"* ]]
}

@test "a local deploy whose record requires the pre-deploy stage fails before the apply" {
  LINKED=false deploy
  [ "${status}" -eq 1 ]
  grep -q "| network | passed | required, needs the server | not run | not run |" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>network: is the pre-deploy stage required?</summary>" "${GITHUB_STEP_SUMMARY}"
  [[ "${output}" == *"::error::The record of unit 'network' requires the pre-deploy stage, which only a project linked to the server can run."* ]]
  [[ "${output}" != *"out_of_scope"* ]]
  ! grep -q -- "iac check --stage=pre_deploy" "${STUB_LOG}" || false
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
}

@test "a project without a platform section cannot use the Iltero registry" {
  LINKED=false REGISTRY_HOST="registry.example.io" deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"module registry"* ]]
}

@test "a project without a platform section deploys locally: no run, no upload, no pre-deploy, no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  touch "${MARKS}/no-pre-deploy-network" "${MARKS}/no-pre-deploy-compute"
  LINKED=false deploy
  [ "${status}" -eq 0 ]
  ! grep -qE -- "--run-id|--run-settings-digest|--upload|iac check --stage=pre_deploy" "${STUB_LOG}" || false
  grep -q "iltero iac check --stage=plan .*--unit=network --out=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out --environment=production$" "${STUB_LOG}"
  grep -q "iltero iac check --stage=post_deploy .*--unit=network --out=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out --environment=production$" "${STUB_LOG}"
  grep -q "terraform network apply" "${STUB_LOG}"
  grep -q "| network | passed | not required | applied | passed |" "${GITHUB_STEP_SUMMARY}"
}

@test "a config the CLI cannot report never falls back to a local deploy" {
  CONFIG_EXIT=2 deploy
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"The CLI could not read the project's .iltero/config.yml. Its message above says why."* ]]
  [ "$(grep -v '^iltero config show' "${STUB_LOG}")" = "" ]
}

@test "the deploy stops with the CLI's own code when the CLI finds no valid config" {
  CONFIG_EXIT=4 deploy
  [ "${status}" -eq 4 ]
  [[ "${output}" == *"could not read the project's .iltero/config.yml"* ]]
  [ "$(grep -v '^iltero config show' "${STUB_LOG}")" = "" ]
}

# --- units -------------------------------------------------------------------

@test "units are deployed in the order the CLI prints, from the directory it prints" {
  deploy
  [ "${status}" -eq 0 ]
  grep -q "iltero units list --format=json" "${STUB_LOG}"
  [ "$(grep -o 'terraform [a-z]* init' "${STUB_LOG}" | cut -d' ' -f2 | tr '\n' ' ')" = "network compute " ]
}

@test "a unit list whose directory holds a tab or a line break stops before anything runs" {
  local listing
  for listing in \
    '[{"name": "network", "working_directory": "units/network\tcompute"}]' \
    '[{"name": "network", "working_directory": "units/network\ncompute\tunits/compute"}]'; do
    echo "${listing}" > "${UNITS_JSON}"
    : > "${STUB_LOG}"
    deploy
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The CLI's unit list could not be read."* ]]
    ! grep -q "^terraform" "${STUB_LOG}" || false
  done
}

@test "a unit list with a name that cannot name a directory, an escaping directory or a missing directory stops before anything runs" {
  local listing
  for listing in \
    '[{"name": "net/work", "working_directory": "units/network"}]' \
    '[{"name": "network", "working_directory": "../elsewhere"}]' \
    '[{"name": "network", "working_directory": "/etc"}]' \
    '[{"name": "network", "working_directory": "units/missing"}]' \
    '{"name": "network"}'; do
    echo "${listing}" > "${UNITS_JSON}"
    : > "${STUB_LOG}"
    deploy
    [ "${status}" -eq 1 ]
    ! grep -q "^terraform" "${STUB_LOG}" || false
  done
}

@test "the deploy stops before anything runs when the CLI cannot list the units" {
  rm "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

# --- one unit, in order --------------------------------------------------------

@test "each unit is initialized, state checked, planned, checked, planned again, pre-deploy checked, applied and post-deploy checked, in that order" {
  echo '[{"name": "network", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^(terraform network [a-z]+|iltero iac check --stage=[a-z_]+|iltero state check)' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "terraform network init,iltero state check,terraform network plan,terraform network show,iltero iac check --stage=plan,terraform network plan,terraform network show,iltero iac check --stage=pre_deploy,terraform network apply,terraform network show,iltero iac check --stage=post_deploy," ]
}

@test "every stage in a linked project names the environment, joins the run and uploads" {
  deploy
  local work="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network"
  local run_args="--unit=network --out=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out --environment=production --upload"
  grep -qx "iltero iac check --stage=plan --plan=${work}/plan.json --saved-plan=${work}/tfplan ${run_args}" "${STUB_LOG}"
  grep -qx "iltero iac check --stage=pre_deploy --plan=${work}/plan.json --saved-plan=${work}/tfplan --replan=${work}/replan.json ${run_args}" "${STUB_LOG}"
  grep -qx "iltero iac check --stage=post_deploy --plan=${work}/plan.json --saved-plan=${work}/tfplan --apply-log=${work}/apply.ndjson --state=${work}/state.json ${run_args}" "${STUB_LOG}"
}

@test "with store-records true, every stage keeps its record in the run's artifact store" {
  touch "${MARKS}/expects-post-verify-network"
  STORE_RECORDS=true deploy
  [ "${status}" -eq 0 ]
  grep -q "^iltero iac check --stage=post_verify " "${STUB_LOG}"
  [ "$(grep -c "^iltero iac check " "${STUB_LOG}")" -eq "$(grep -c "^iltero iac check --stage=.* --upload --store$" "${STUB_LOG}")" ]
}

@test "in a project without a platform section, store-records is passed on for the CLI to refuse" {
  LINKED=false STORE_RECORDS=true deploy
  grep -q "^iltero iac check --stage=plan .*--environment=production --store$" "${STUB_LOG}"
}

@test "a store-records value other than true or false is refused" {
  STORE_RECORDS=yes deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The store-records input must be true or false, not 'yes'."* ]]
}

@test "the apply uses the saved plan and its output is kept unchanged for the CLI" {
  deploy
  local work="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network"
  grep -q "terraform network apply -input=false -json -lock-timeout=5m ${work}/tfplan" "${STUB_LOG}"
  [ "$(cat "${work}/apply.ndjson")" = '{"@level":"info","@message":"Apply complete! Resources: 1 added."}' ]
}

@test "the apply's messages are shown in the log" {
  deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Apply complete! Resources: 1 added."* ]]
}

@test "a failed apply's error and its detail are shown in the log" {
  touch "${MARKS}/apply-error-network"
  deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Error: creating bucket"* ]]
  [[ "${output}" == *"Access denied."* ]]
}

@test "init, plan and apply wait a set time for another run's lock on the state" {
  deploy
  grep -q "terraform network init .*-lock-timeout=5m" "${STUB_LOG}"
  grep -q "terraform network plan -input=false -no-color -lock-timeout=5m -out=" "${STUB_LOG}"
  grep -q "terraform network apply .*-lock-timeout=5m" "${STUB_LOG}"
}

@test "init uses the lock file as committed and the unit's backend settings for the environment" {
  mkdir -p units/network/config/backend && touch units/network/config/backend/production.hcl
  deploy
  grep -q "terraform network init -input=false -no-color -lockfile=readonly -lock-timeout=5m -backend-config=${STACK}/units/network/config/backend/production.hcl" "${STUB_LOG}"
}

@test "plan uses the unit's variables for the environment and sets the remote-state switch to true from a file, last" {
  mkdir -p units/compute/config && touch units/compute/config/production.tfvars.json
  echo 'variable "enable_remote_state_dependencies" { type = bool }' > units/compute/variables.tf
  deploy
  local switch="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/compute/with-upstream.tfvars"
  grep -q "terraform compute plan .* -var-file=${STACK}/units/compute/config/production.tfvars.json -var-file=${switch}$" "${STUB_LOG}"
  [ "$(cat "${switch}")" = "enable_remote_state_dependencies = true" ]
  ! grep -q "terraform network plan .*with-upstream" "${STUB_LOG}" || false
}

@test "a unit with settings for other environments but not this one stops the deploy before Terraform runs" {
  mkdir -p units/network/config/backend && touch units/network/config/backend/staging.hcl
  deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"units/network/config/backend/production.hcl is missing."* ]]
  [[ "${output}" == *"::error::Unit 'network' is not set up for environment 'production'. See the log."* ]]
  grep -q "| network | not set up for this environment | not run |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "terraform network" "${STUB_LOG}" || false
}

@test "a unit with variables for other environments but not this one stops the deploy before Terraform runs" {
  mkdir -p units/network/config && touch units/network/config/staging.tfvars.json
  REGISTRY_HOST="registry.iltero-test.io" deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"units/network/config/production.tfvars.json is missing."* ]]
  ! grep -q "^audience " "${STUB_LOG}" || false
  ! grep -q "terraform network" "${STUB_LOG}" || false
}

@test "a job that sets TF_WORKSPACE stops the deploy before Terraform runs" {
  TF_WORKSPACE=production deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"The job sets TF_WORKSPACE"* ]]
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "settings outside the unit's config folder are not used" {
  mkdir -p config/backend units/network/config
  touch config/backend/production.hcl config/production.tfvars config/production.tfvars.json units/network/config/production.tfvars
  deploy
  ! grep -q -- "-backend-config" "${STUB_LOG}" || false
  ! grep -q -- "-var-file=${STACK}/" "${STUB_LOG}" || false
}

# --- what Terraform can reach ------------------------------------------------

@test "Terraform gets only PATH, HOME, its own settings, cloud credentials and TF_VAR_ values" {
  deploy
  local env_file
  for env_file in "${BATS_TEST_TMPDIR}"/terraform-env-*; do
    grep -qx "AWS_ACCESS_KEY_ID=deploy-role-key" "${env_file}"
    grep -qx "TF_VAR_owner=platform-team" "${env_file}"
    ! grep -vE '^(PATH|HOME|PWD|SHLVL|_|OLDPWD|TF_IN_AUTOMATION|TF_INPUT|TF_DATA_DIR|TF_CLI_CONFIG_FILE|TF_PLUGIN_CACHE_DIR|CHECKPOINT_DISABLE|AWS_ACCESS_KEY_ID|TF_VAR_owner)=' "${env_file}" || false
  done
}

@test "Terraform gets AWS's settings files and certificate bundle when the job names them" {
  AWS_CONFIG_FILE="/etc/aws/config" AWS_SHARED_CREDENTIALS_FILE="/etc/aws/credentials" \
    AWS_CA_BUNDLE="/etc/ssl/aws.pem" deploy
  [ "${status}" -eq 0 ]
  local env_file="${BATS_TEST_TMPDIR}/terraform-env-plan-network"
  grep -qx "AWS_CONFIG_FILE=/etc/aws/config" "${env_file}"
  grep -qx "AWS_SHARED_CREDENTIALS_FILE=/etc/aws/credentials" "${env_file}"
  grep -qx "AWS_CA_BUNDLE=/etc/ssl/aws.pem" "${env_file}"
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
  ! grep -q "^TF_TOKEN_registry" "${BATS_TEST_TMPDIR}/terraform-env-plan-network" || false
  [[ "${output}" == *"::add-mask::id-token-for-https://registry.iltero-test.io"* ]]
  [ "$(grep -c '^audience' "${STUB_LOG}")" -eq 2 ]
  ! grep -rq "id-token-for" "${GITHUB_ENV}" "${GITHUB_OUTPUT}" "${RUNNER_TEMP}/iltero-deploy" 2> /dev/null || false
}

@test "no registry token is made when no registry host is given" {
  deploy
  ! grep -q "^audience" "${STUB_LOG}" || false
}

@test "a registry token needs no ILTERO_API_URL" {
  unset ILTERO_API_URL
  REGISTRY_HOST="registry.iltero-test.io" deploy
  [ "${status}" -eq 0 ]
  grep -qx "audience https://registry.iltero-test.io" "${STUB_LOG}"
}

# --- failures ----------------------------------------------------------------

@test "a saved plan that changed after its check is not applied" {
  touch "${MARKS}/change-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved plan of unit 'network' changed after it was checked, so the unit was not applied."* ]]
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | plan changed | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a plan whose JSON changed after its check is not applied" {
  touch "${MARKS}/change-json-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved plan of unit 'network' changed after it was checked, so the unit was not applied."* ]]
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | plan changed | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a saved plan that cannot be read stops the unit before its check" {
  touch "${MARKS}/no-saved-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved plan of unit 'network' could not be read."* ]]
  ! grep -q "stage=plan" "${STUB_LOG}" || false
  grep -q "| network | plan unreadable | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a saved plan that cannot be read after its check is not applied" {
  touch "${MARKS}/remove-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved plan of unit 'network' could not be read, so the unit was not applied."* ]]
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | plan unreadable | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "Python files in the stack do not replace the modules the action imports" {
  echo 'raise SystemExit("stack module ran")' > "${STACK}/json.py"
  echo 'raise SystemExit("stack module ran")' > "${STACK}/hashlib.py"
  deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"stack module ran"* ]]
}

@test "a stack with no unit stops the deploy" {
  echo '[]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The CLI lists no units in this stack, so there is nothing to check."* ]]
}

@test "two units with one name stop the deploy before any unit runs" {
  echo '[{"name": "network", "working_directory": "units/network"}, {"name": "network", "working_directory": "units/compute"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Two units are named 'network'. Give each unit its own name."* ]]
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "an environment of more than one line is refused" {
  run "${DEPLOY}" run $'production\n# heading'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input must be one line, with no tab or other control character."* ]]
}

@test "Terraform's error output is shown with workflow commands paused, on the same stream" {
  run bash -c "'${DEPLOY}' run production 2> /dev/null"
  [ "${status}" -eq 0 ]
  commands_paused_around "terraform warns on apply"
  commands_paused_around "terraform warns on show"
}

@test "a failed plan check stops the deploy with the CLI's exit code" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "stage=pre_deploy" "${STUB_LOG}" || false
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  grep -q "| network | failed | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "before the pre-deploy check, each unit is planned again into its own file, with the saved plan's input variables, and only the saved plan is applied" {
  echo '[{"name": "network", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 0 ]
  local work="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network"
  local plans
  plans="$(grep "^terraform network plan " "${STUB_LOG}")"
  [ "$(echo "${plans}" | wc -l)" -eq 2 ]
  [ "$(echo "${plans}" | head -1 | sed "s| -out=[^ ]*||")" == "$(echo "${plans}" | tail -1 | sed "s| -out=[^ ]*||")" ]
  echo "${plans}" | tail -1 | grep -q -- " -out=${work}/replan.tfplan"
  grep -qx "terraform network show -json ${work}/replan.tfplan" "${STUB_LOG}"
  [ -f "${work}/replan.json" ]
  grep -qx "terraform network apply -input=false -json -lock-timeout=5m ${work}/tfplan" "${STUB_LOG}"
}

@test "when the first plan finished in the current second, the deploy waits a second before it plans again" {
  echo '[{"name": "network", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  stub date 'echo 1000'
  deploy
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^(terraform network (plan|show)|sleep [0-9]+|iltero iac check --stage=(plan|pre_deploy))' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "terraform network plan,terraform network show,iltero iac check --stage=plan,sleep 1,terraform network plan,terraform network show,iltero iac check --stage=pre_deploy,terraform network show," ]
}

@test "when the clock has moved on since the first plan finished, the deploy plans again without waiting" {
  echo '[{"name": "network", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 0 ]
  ! grep -q "^sleep" "${STUB_LOG}" || false
  [ "$(grep -c "^terraform network plan " "${STUB_LOG}")" -eq 2 ]
}

@test "a unit that cannot be planned again stops before the pre-deploy check and the apply" {
  touch "${MARKS}/fail-replan-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform could not plan unit 'network' again before the pre-deploy check."* ]]
  ! grep -q -- "iac check --stage=pre_deploy" "${STUB_LOG}" || false
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  grep -q "| network | passed | Terraform failed | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit whose record leaves pre-deploy out, or a local deploy, does not plan again" {
  touch "${MARKS}/no-pre-deploy-network" "${MARKS}/no-pre-deploy-compute"
  deploy
  [ "${status}" -eq 0 ]
  ! grep -q "replan" "${STUB_LOG}" || false
  : > "${STUB_LOG}"
  LINKED=false deploy
  [ "${status}" -eq 0 ]
  ! grep -q "replan" "${STUB_LOG}" || false
}

@test "a failed pre-deploy check stops the deploy before the apply" {
  echo 3 > "${MARKS}/exit-pre_deploy-network"
  deploy
  [ "${status}" -eq 3 ]
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | failed | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "in a linked project, a unit whose record leaves pre-deploy out runs no pre-deploy check and is applied" {
  touch "${MARKS}/no-pre-deploy-network"
  deploy
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope [^ ]*/network --stage=pre_deploy$" "${STUB_LOG}"
  ! grep -q -- "iac check --stage=pre_deploy .*--unit=network " "${STUB_LOG}" || false
  grep -q -- "iac check --stage=pre_deploy .*--unit=compute " "${STUB_LOG}"
  grep -q "terraform network apply" "${STUB_LOG}"
  grep -q "| network | passed | not required | applied | passed |" "${GITHUB_STEP_SUMMARY}"
  grep -q "| compute | passed | passed | applied | passed |" "${GITHUB_STEP_SUMMARY}"
}

@test "in a linked project, the unit stops before the apply when the CLI cannot say whether its record requires pre-deploy" {
  echo 9 > "${MARKS}/in-scope-exit-pre_deploy-network"
  deploy
  [ "${status}" -eq 9 ]
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  ! grep -q -- "iac check --stage=pre_deploy" "${STUB_LOG}" || false
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | record does not verify | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "in a linked project, any answer other than in or out of scope stops the unit before the apply with the CLI's code" {
  echo 5 > "${MARKS}/in-scope-exit-pre_deploy-network"
  deploy
  [ "${status}" -eq 5 ]
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  ! grep -q -- "iac check --stage=pre_deploy" "${STUB_LOG}" || false
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
  grep -q "| network | passed | record unreadable | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed apply is still checked after, and fails with the apply's code" {
  touch "${MARKS}/fail-apply-network"
  deploy
  [ "${status}" -eq 1 ]
  grep -q "stage=post_deploy" "${STUB_LOG}"
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | apply failed | passed |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed post-deploy check fails with the CLI's exit code and stops later units" {
  echo 9 > "${MARKS}/exit-post_deploy-network"
  deploy
  [ "${status}" -eq 9 ]
  ! grep -q "terraform compute" "${STUB_LOG}" || false
}

@test "an apply whose state cannot be read is still recorded, and the unit fails with the CLI's code" {
  touch "${MARKS}/fail-state-network"
  deploy
  [ "${status}" -eq 6 ]
  [[ "${output}" == *"Terraform could not read the state of unit 'network' after the apply."* ]]
  grep -q "iltero iac check --stage=post_deploy .*--apply-log=.*/apply.ndjson --state-unreadable --unit=network" "${STUB_LOG}"
  ! grep -q "iac check --stage=post_deploy .*--state=" "${STUB_LOG}" || false
  grep -qx "| network | passed | passed | applied | failed without the state file | not run |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "terraform compute" "${STUB_LOG}" || false
}

@test "a passed post-deploy check whose state could not be read says so" {
  touch "${MARKS}/fail-state-network" "${MARKS}/state-unreadable-passes"
  deploy
  [ "${status}" -eq 0 ]
  grep -qx "| network | passed | passed | applied | passed without the state file | not required |" "${GITHUB_STEP_SUMMARY}"
}

@test "an apply that failed and whose state cannot be read fails with the apply's code" {
  touch "${MARKS}/fail-state-network"
  echo 4 > "${MARKS}/fail-apply-network"
  deploy
  [ "${status}" -eq 4 ]
  grep -qx "| network | passed | passed | apply failed | failed without the state file | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "the CLI is asked whether a record expects post-verify, and its answer is kept and shown paused" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope ${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out/units/network --stage=post_verify$" "${STUB_LOG}"
  grep -qx "The post_verify stage is in scope." "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network/in-scope-post_verify.txt"
  commands_paused_around "::error::injected by the record"
  grep -q "<summary>network: is the post-verify stage required?</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "the summary lists the units after a failed unit as not run" {
  echo 9 > "${MARKS}/exit-post_deploy-network"
  deploy
  grep -qx "| compute | not run | not run | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "after a failed unit, no unit is read back, and the summary says so" {
  echo 9 > "${MARKS}/exit-post_deploy-compute"
  deploy
  grep -qx "| network | passed | passed | applied | passed | not run |" "${GITHUB_STEP_SUMMARY}"
  grep -qx "| compute | passed | passed | applied | failed | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a registry token that cannot be minted stops the unit, and the summary is still written" {
  MINT_FAILS=1 REGISTRY_HOST="registry.iltero-test.io" deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Could not get an identity token for the registry."* ]]
  grep -qx "| network | could not get registry token | not run | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
  grep -qx "| compute | not run | not run | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "a failed Terraform plan stops the deploy before any check" {
  touch "${MARKS}/fail-plan-compute"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q "unit=compute" "${STUB_LOG}" || false
  grep -q "| compute | Terraform failed | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "the state check reads each unit's directory with the data directory Terraform used" {
  deploy
  [ "${status}" -eq 0 ]
  local unit data
  for unit in network compute; do
    grep -q "^iltero state check --working-directory=units/${unit}$" "${STUB_LOG}"
    data="$(grep "^TF_DATA_DIR=" "${BATS_TEST_TMPDIR}/terraform-env-init-${unit}")"
    grep -qxF "state check data ${data#TF_DATA_DIR=}" "${STUB_LOG}"
  done
  commands_paused_around "state <checked> for network"
}

@test "a unit that keeps its state in its working directory stops the deploy before its plan and later units" {
  echo 5 > "${MARKS}/exit-state-network"
  deploy
  [ "${status}" -eq 5 ]
  ! grep -q "unit=network" "${STUB_LOG}" || false
  ! grep -q "terraform network plan" "${STUB_LOG}" || false
  ! grep -q "terraform compute" "${STUB_LOG}" || false
  grep -q "| network | state check failed | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed Terraform init stops the deploy before the state check" {
  touch "${MARKS}/fail-init-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform could not initialize unit 'network'."* ]]
  ! grep -q "^iltero state check" "${STUB_LOG}" || false
  grep -q "| network | Terraform failed | not run | not run | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "each unit starts with an empty work folder" {
  local work="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network"
  mkdir -p "${work}/terraform-data"
  touch "${work}/terraform-data/left-over"
  deploy
  [ "${status}" -eq 0 ]
  [ ! -e "${work}/terraform-data/left-over" ]
}

@test "the summary shows the state check's output" {
  echo 5 > "${MARKS}/exit-state-network"
  deploy
  grep -q "<summary>network: state check</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "state &lt;checked&gt; for network" "${GITHUB_STEP_SUMMARY}"
}

# --- post_verify -------------------------------------------------------------

@test "a unit whose record does not expect post-verify is not read back" {
  deploy
  [ "${status}" -eq 0 ]
  ! grep -q -- "-refresh-only" "${STUB_LOG}" || false
  ! grep -q "iac check --stage=post_verify" "${STUB_LOG}" || false
  ! grep -q "^sleep" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | applied | passed | not required |" "${GITHUB_STEP_SUMMARY}"
}

@test "every unit deploys and is read back once before any second reading, each the interval after its first" {
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/expects-post-verify-compute"
  deploy
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^(terraform [a-z]+ (apply|plan -input=false -no-color -refresh-only)|sleep [0-9]+|iltero iac check --stage=post_verify --[a-z-]+=[^ ]+/(network|compute)/)' '${STUB_LOG}' | tr '\n' ','"
  [[ "${output}" =~ ^terraform\ network\ apply,terraform\ compute\ apply,terraform\ network\ plan[^,]*,terraform\ compute\ plan[^,]*,sleep\ 6[01],terraform\ network\ plan[^,]*,iltero[^,]*network/,sleep\ 6[01],terraform\ compute\ plan[^,]*,iltero[^,]*compute/,$ ]]
}

@test "post-verify gets both readings in order and the post-deploy state, and joins the run" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 0 ]
  local readings="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/readings/network"
  grep -qx "iltero iac check --stage=post_verify --refresh-plan=${readings}/first.json --refresh-plan=${readings}/second.json --state=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network/state.json --minimum-interval-seconds=60 --unit=network --out=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out --environment=production --upload" "${STUB_LOG}"
  [ "$(cat "${readings}/first.json")" = '{}' ]
  [ "$(cat "${readings}/second.json")" = '{}' ]
  [ "$(output_value readings-directory)" = "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/readings" ]
  grep -q "| network | passed | passed | applied | passed | passed |" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>network: post-verify</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "post-verify gets the same state file that post-deploy got, unchanged by the readings" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 0 ]
  local post_deploy_state post_verify_state
  post_deploy_state="$(grep "^iltero iac check --stage=post_deploy .*--unit=network" "${STUB_LOG}" | grep -oE -- '--state=[^ ]+')"
  post_verify_state="$(grep "^iltero iac check --stage=post_verify .*--unit=network" "${STUB_LOG}" | grep -oE -- '--state=[^ ]+')"
  [ -n "${post_deploy_state}" ]
  [ "${post_verify_state}" = "${post_deploy_state}" ]
  [ "$(cat "${post_deploy_state#--state=}")" = '{}' ]
}

@test "a reading is a saved refresh-only plan with the plan's variables, and is never applied" {
  touch "${MARKS}/expects-post-verify-compute"
  mkdir -p units/compute/config
  echo '{}' > units/compute/config/production.tfvars.json
  echo 'variable "enable_remote_state_dependencies" {}' > units/compute/main.tf
  deploy
  [ "${status}" -eq 0 ]
  local work="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/compute"
  grep -qx "terraform compute plan -input=false -no-color -refresh-only -lock-timeout=5m -out=${work}/reading-first.tfplan -var-file=${STACK}/units/compute/config/production.tfvars.json -var-file=${work}/with-upstream.tfvars" "${STUB_LOG}"
  grep -qx "terraform compute show -json ${work}/reading-second.tfplan" "${STUB_LOG}"
  [ "$(grep -c "^terraform compute apply" "${STUB_LOG}")" -eq 1 ]
}

@test "no unit is read back when a unit failed to deploy" {
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/expects-post-verify-compute"
  echo 1 > "${MARKS}/exit-plan-compute"
  deploy
  [ "${status}" -eq 1 ]
  ! grep -q -- "-refresh-only" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | applied | passed | not run |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed post-verify check fails the step with the CLI's code, after every unit is verified" {
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/expects-post-verify-compute"
  echo 1 > "${MARKS}/exit-post_verify-network"
  deploy
  [ "${status}" -eq 1 ]
  grep -q "stage=post_verify.*--unit=compute" "${STUB_LOG}"
  [[ "${output}" == *"::error::The post-verify stage failed for one or more units. See the job summary."* ]]
  grep -q "| network | passed | passed | applied | passed | failed |" "${GITHUB_STEP_SUMMARY}"
  grep -q "| compute | passed | passed | applied | passed | passed |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed reading fails the step, and the unit gets no post-verify check" {
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/fail-refresh-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::Terraform could not read the deployed resources of unit 'network'."* ]]
  ! grep -q "iac check --stage=post_verify" "${STUB_LOG}" || false
  grep -q "| network | passed | passed | applied | passed | Terraform failed |" "${GITHUB_STEP_SUMMARY}"
}

@test "a unit's report is written after its post-verify stage" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 0 ]
  run bash -c "grep -nE '^iltero (iac check --stage=post_verify .*--unit=network|record report [^ ]*/network )' '${STUB_LOG}' | cut -d: -f2 | cut -c1-30"
  [[ "${output}" == "iltero iac check --stage=post_"*"iltero record report"* ]]
}

@test "a record that does not verify fails the step with the CLI's code" {
  echo 9 > "${MARKS}/in-scope-exit-post_verify-compute"
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [ "${status}" -eq 9 ]
  [[ "${output}" == *"The CLI could not say whether the record of unit 'compute' requires the post-verify stage. See the CLI's output in the log."* ]]
  grep -q "| network | passed | passed | applied | passed | passed |" "${GITHUB_STEP_SUMMARY}"
  grep -q "| compute | passed | passed | applied | passed | record does not verify |" "${GITHUB_STEP_SUMMARY}"
}

@test "any other answer than in or out of scope stops the step with the CLI's code" {
  echo 2 > "${MARKS}/in-scope-exit-post_verify"
  deploy
  [ "${status}" -eq 2 ]
  grep -q "| network | passed | passed | applied | passed | record unreadable |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed second reading fails the step, is not kept, and the unit gets no post-verify check" {
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/fail-second-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::Terraform could not read the deployed resources of unit 'network'."* ]]
  ! grep -q "iac check --stage=post_verify" "${STUB_LOG}" || false
  [ -f "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/readings/network/first.json" ]
  [ ! -e "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/readings/network/second.json" ]
  grep -q "| network | passed | passed | applied | passed | Terraform failed |" "${GITHUB_STEP_SUMMARY}"
}

@test "post-verify in a local deploy neither joins a run nor uploads" {
  LINKED=false
  touch "${MARKS}/expects-post-verify-network" "${MARKS}/no-pre-deploy-network" "${MARKS}/no-pre-deploy-compute"
  deploy
  [ "${status}" -eq 0 ]
  local readings="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/readings/network"
  grep -qx "iltero iac check --stage=post_verify --refresh-plan=${readings}/first.json --refresh-plan=${readings}/second.json --state=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/units/network/state.json --minimum-interval-seconds=60 --unit=network --out=${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out --environment=production" "${STUB_LOG}"
}

@test "the deploy says why it waits before a second reading" {
  touch "${MARKS}/expects-post-verify-network"
  deploy
  [[ "${output}" == *"Waiting 6"[01]" seconds before the second reading of unit 'network'."* ]]
}

# --- summary and outputs -----------------------------------------------------

@test "the summary names each stage's output in words" {
  deploy
  grep -q "<summary>network: plan</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>network: pre-deploy</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>network: post-deploy</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "the summary shows the CLI's output with HTML escaped" {
  deploy
  grep -q "plan &lt;checked&gt; for network" "${GITHUB_STEP_SUMMARY}"
}

@test "a re-run names its records artifact after its own attempt" {
  GITHUB_RUN_ATTEMPT=2 deploy
  [ "$(output_value artifact-name)" = "iltero-deploy-production-attempt-2" ]
}

@test "a re-run adds its own attempt to a given artifact name too" {
  ARTIFACT_NAME=network-records GITHUB_RUN_ATTEMPT=3 deploy
  [ "$(output_value artifact-name)" = "network-records-attempt-3" ]
}

@test "the deploy stops before anything runs without a whole attempt number" {
  local value
  for value in "" 0 x 1a; do
    GITHUB_RUN_ATTEMPT="${value}" deploy
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"GITHUB_RUN_ATTEMPT is missing or not a whole number."* ]]
    ! grep -q "^terraform" "${STUB_LOG}" || false
  done
}

@test "the retention-days input must be empty or a whole number of days" {
  local value
  for value in 0 -1 7d " 7" 1.5; do
    RETENTION_DAYS="${value}" run "${DEPLOY}" check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The retention-days input must be empty or a whole number of days of 1 or more."* ]]
  done
  RETENTION_DAYS=30 run "${DEPLOY}" check
  [ "${status}" -eq 0 ]
}

@test "the records artifact is named after the environment unless a name is given" {
  deploy
  [ "$(output_value artifact-name)" = "iltero-deploy-production-attempt-1" ]
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME=network-records run "${DEPLOY}" run production
  [ "$(output_value artifact-name)" = "network-records-attempt-1" ]
}

@test "each environment has its own work folder" {
  deploy
  run "${DEPLOY}" run staging
  [ "${status}" -eq 0 ]
  [ -f "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out/units/network/car.json" ]
  [ -f "${RUNNER_TEMP}/iltero-deploy/staging/${STACK_FOLDER}/out/units/network/car.json" ]
}

@test "each stack has its own work folder, so two stacks in one job keep their records apart" {
  deploy
  [ "${status}" -eq 0 ]
  cp -R "${STACK}" "${BATS_TEST_TMPDIR}/second-stack"
  cd "${BATS_TEST_TMPDIR}/second-stack"
  local second
  second="$(stack_folder_name)"
  [ "${second}" != "${STACK_FOLDER}" ]
  : > "${GITHUB_OUTPUT}"
  run "${DEPLOY}" run production
  [ "${status}" -eq 0 ]
  [ -f "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out/units/network/car.json" ]
  [ -f "${RUNNER_TEMP}/iltero-deploy/production/${second}/out/units/network/car.json" ]
  [ "$(output_value records-directory)" = "${RUNNER_TEMP}/iltero-deploy/production/${second}/out" ]
}

@test "a deploy starts from an empty work folder, so no earlier record stands in for one it did not write" {
  local root="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}"
  mkdir -p "${root}/out/units/retired" "${root}/readings/retired"
  echo '{}' > "${root}/out/units/retired/car.json"
  deploy
  [ "${status}" -eq 0 ]
  [ ! -e "${root}/out/units/retired" ]
  [ ! -e "${root}/readings/retired" ]
}

@test "a local deploy with no record at pre-deploy stops the unit before the apply" {
  touch "${MARKS}/no-record-network"
  LINKED=false deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory holds no record of unit 'network'."* ]]
  grep -q "| network | passed | no record | not run | not run |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
}

@test "a local deploy whose record cannot be read at pre-deploy stops the unit before the apply" {
  touch "${MARKS}/bad-record-network"
  LINKED=false deploy
  [ "${status}" -eq 9 ]
  grep -q "| network | passed | record does not verify | not run | not run |" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "terraform network apply" "${STUB_LOG}" || false
}

@test "an environment with a space is refused before anything runs" {
  run "${DEPLOY}" run "prod env"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot name a directory or a file. Use only letters, digits"* ]]
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "check refuses a registry host that is not a host name, before any unit runs" {
  REGISTRY_HOST="not a host" run "${DEPLOY}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid registry host 'not a host'."* ]]
}

@test "check refuses an artifact name that is not a valid name" {
  ARTIFACT_NAME="records/../x" run "${DEPLOY}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name 'records/../x'."* ]]
}

@test "the records directory is an output, even when the deploy fails" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "$(output_value records-directory)" = "${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out" ]
}

# --- report ------------------------------------------------------------------

@test "each unit's record gets a report, as an HTML page for the artifact and in the summary" {
  deploy
  [ "${status}" -eq 0 ]
  local reports="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/reports" out="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/out"
  grep -qx "report-directory=${reports}" "${GITHUB_OUTPUT}"
  grep -qx "iltero record report ${out}/units/network --format=html --out=${reports}/network" "${STUB_LOG}"
  grep -qx "iltero record report ${out}/units/compute --format=markdown --out=${reports}/compute" "${STUB_LOG}"
  [ -f "${reports}/network/record-report.html" ]
  grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -qx "report <markdown> of compute" "${GITHUB_STEP_SUMMARY}"
}

@test "with report false, no report is written" {
  WRITE_REPORT=false deploy
  [ "${status}" -eq 0 ]
  ! grep -q "record report" "${STUB_LOG}" || false
  ! grep -q "^report-directory=" "${GITHUB_OUTPUT}" || false
}

@test "a report value other than true or false is refused" {
  WRITE_REPORT=yes deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The write-report input must be true or false, not 'yes'."* ]]
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

@test "a report that exits with another code than 0 is a warning, and the deploy keeps its result" {
  echo 9 > "${MARKS}/exit-report-network"
  deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::The CLI reported a problem while it wrote the report of unit 'network'. See its output in the log."* ]]
  grep -q "iltero record report .*/units/compute --format=html" "${STUB_LOG}"
}

@test "the unit that stopped the deploy gets a report when it has a record, and a unit without one gets none" {
  echo 1 > "${MARKS}/exit-plan-network"
  deploy
  [ "${status}" -eq 1 ]
  grep -q "iltero record report .*/units/network --format=html" "${STUB_LOG}"
  echo 5 > "${MARKS}/exit-state-network"
  rm -rf "${RUNNER_TEMP}/iltero-deploy"
  : > "${STUB_LOG}"
  deploy
  [ "${status}" -eq 5 ]
  ! grep -q "record report" "${STUB_LOG}" || false
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
  ! grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}" || false
}

@test "a report the CLI does not write fails the step after every unit deploys, and no earlier report stays" {
  local old="${RUNNER_TEMP}/iltero-deploy/production/${STACK_FOLDER}/reports/network"
  mkdir -p "${old}"
  echo "old report" > "${old}/record-report.md"
  touch "${MARKS}/no-report-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::The CLI wrote no record-report.html for unit 'network'."* ]]
  [[ "${output}" == *"The CLI wrote no report for one or more units. See the log."* ]]
  grep -q "iltero iac check --stage=post_deploy .*--unit=compute" "${STUB_LOG}"
  ! grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}" || false
  [ ! -e "${old}/record-report.md" ]
}

@test "a report without its Markdown file fails the step" {
  touch "${MARKS}/no-markdown-network"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::The CLI wrote no record-report.md for unit 'network'."* ]]
}

@test "a failed stage keeps its exit code when its report is missing too" {
  echo 3 > "${MARKS}/exit-plan-network"
  touch "${MARKS}/no-report-network"
  deploy
  [ "${status}" -eq 3 ]
}

@test "the report's output cannot act as a workflow command" {
  deploy
  commands_paused_around "report written for network"
}

@test "a unit directory that starts with a dash is refused before any unit runs" {
  echo '[{"name": "network", "depends_on": [], "working_directory": "-L"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit 'network' has a directory that starts with '-': '-L'. Rename the directory."* ]]
  ! grep -q "^terraform " "${STUB_LOG}" || false
}

@test "a unit list with a unit name that cannot name a directory stops the deploy before any output is written" {
  echo '[{"name": "..", "working_directory": "units/network"}]' > "${UNITS_JSON}"
  deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit name '..' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."* ]]
  ! grep -qE "^(records-directory|artifact-name|readings-directory|report-directory)=" "${GITHUB_OUTPUT}" || false
}

# --- scanners ----------------------------------------------------------------

@test "in a linked project, the deploy installs the scanners into the tools folder once, before any Terraform call" {
  export ILTERO_CACHE_DIR="${BATS_TEST_TMPDIR}/elsewhere"
  deploy
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^iltero scanners install$' "${STUB_LOG}")" -eq 1 ]
  [ "$(grep -n '^iltero scanners install$' "${STUB_LOG}" | cut -d: -f1)" -lt "$(grep -n '^terraform ' "${STUB_LOG}" | head -1 | cut -d: -f1)" ]
  # The action names the folder itself, whatever the job set.
  grep -qx "scanners install ILTERO_CACHE_DIR=${TOOLS}/scanners" "${STUB_LOG}"
}

@test "the deploy installs no scanners in a project not linked to the server" {
  touch "${MARKS}/no-pre-deploy-network" "${MARKS}/no-pre-deploy-compute"
  LINKED=false deploy
  [ "${status}" -eq 0 ]
  ! grep -q "scanners install" "${STUB_LOG}" || false
}

@test "a failed scanner install stops the deploy with the CLI's exit code, before Terraform runs and before any output" {
  echo 9 > "${MARKS}/exit-scanners"
  deploy
  [ "${status}" -eq 9 ]
  [[ "${output}" == *"::error::A scanner or the scanner folder failed the Iltero CLI's integrity check against the pinned digests (fingerprints)."* ]]
  ! grep -q "^terraform " "${STUB_LOG}" || false
  [ ! -s "${GITHUB_OUTPUT}" ]
}
