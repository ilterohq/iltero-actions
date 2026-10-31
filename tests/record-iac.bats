#!/usr/bin/env bats
#
# Tests for scripts/record-iac.sh, the body of the `record-iac` action.

load test_helper


setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export LINKED="true"
  export WRITE_REPORT="true"
  export ENVIRONMENT="production"
  export UNIT="network"
  : > "${GITHUB_STEP_SUMMARY}"
  RECORD="${REPO_ROOT}/scripts/record-iac.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  export MARKS="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${TOOLS}/venv/bin" "${MARKS}"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for the CLI. MARKS/exit-<stage> holds a stage's exit code and
  # MARKS/exit-state the state check's. MARKS/no-report makes the report exit
  # 5 without writing. Each stage writes the unit's record.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
case "$1 $2" in
  "state check")
    echo "state check data ${TF_DATA_DIR:-default}" >> "${STUB_LOG}"
    echo "state <checked>"
    [[ ! -e "${MARKS}/exit-state" ]] || exit "$(cat "${MARKS}/exit-state")"
    exit 0
    ;;
  "record report")
    [[ ! -e "${MARKS}/no-report" ]] || exit 5
    format="${4#--format=}" dir="${5#--out=}"
    [[ "${format}" == markdown ]] && extension=md || extension="${format}"
    echo "report <${format}>" > "${dir}/record-report.${extension}"
    exit 0
    ;;
  "units list")
    [[ ! -e "${MARKS}/no-units" ]] || exit 3
    echo '[{"name": "network", "working_directory": "units/network"}, {"name": "app-db", "working_directory": "units/app-db"}]'
    exit 0
    ;;
  "config show")
    echo "{\"linked\": ${LINKED}}"
    exit 0
    ;;
esac
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
echo "::warning::${stage} <checked> for ${unit}"
[[ ! -e "${MARKS}/exit-${stage}" ]] || exit "$(cat "${MARKS}/exit-${stage}")"
exit 0
STUB
  chmod +x "${TOOLS}/venv/bin/iltero"
  stub terraform 'echo "terraform $*" >> "${STUB_LOG}"'

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/app-db"
  cd "${STACK}"
  echo '{}' > plan.json
  echo 'binary' > tfplan
  echo '{}' > apply.ndjson
  echo '{}' > state.json
  echo '{}' > first.json
  echo '{}' > second.json
  export PLAN="plan.json" SAVED_PLAN="tfplan" APPLY_LOG="apply.ndjson" STATE="state.json"
  export REFRESH_PLANS=$'first.json\nsecond.json\n'
  RECORDS="${RUNNER_TEMP}/iltero-records"
}

# Prints the CLI's stage call for STAGE from the stub log.
stage_call() {
  grep "^iltero iac check --stage=$1 " "${STUB_LOG}"
}

# --- check -------------------------------------------------------------------

@test "check refuses pull_request_target and workflow_run events" {
  local event
  for event in pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${RECORD}" check plan
    [ "${status}" -eq 1 ]
  done
}

@test "check refuses a stage record-iac does not record" {
  run "${RECORD}" check deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stage input must be one of: plan pre_deploy post_deploy post_verify. It is 'deploy'."* ]]
}

@test "check accepts each stage on a push" {
  local stage
  for stage in plan pre_deploy post_deploy post_verify; do
    run "${RECORD}" check "${stage}"
    [ "${status}" -eq 0 ]
  done
}

@test "on a pull_request event, check accepts only plan" {
  local stage
  for stage in pre_deploy post_deploy post_verify; do
    GITHUB_EVENT_NAME=pull_request run "${RECORD}" check "${stage}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"On pull request events, record-iac records only the plan stage, as a local preview."* ]]
  done
  GITHUB_EVENT_NAME=pull_request run "${RECORD}" check plan
  [ "${status}" -eq 0 ]
}

@test "check refuses an artifact name that is not a valid name" {
  ARTIFACT_NAME="records/../x" run "${RECORD}" check plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name 'records/../x'."* ]]
}

@test "run checks the stage again" {
  run "${RECORD}" run deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stage input must be one of: plan pre_deploy post_deploy post_verify."* ]]
  ! grep -q "^iltero" "${STUB_LOG}" || false
}

@test "check needs setup" {
  rm "${TOOLS}/venv/bin/iltero"
  run "${RECORD}" check plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Run the setup action first"* ]]
}

# --- plan --------------------------------------------------------------------

@test "plan checks the state, then runs the plan stage in the run on the server" {
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^iltero (state check|iac check --stage=plan)' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "iltero state check,iltero iac check --stage=plan," ]
  grep -qx "iltero state check --working-directory=units/network" "${STUB_LOG}"
  stage_call plan | grep -qx "iltero iac check --stage=plan --plan=plan.json --saved-plan=tfplan --unit=network --out=${RECORDS} --environment=production --upload"
  grep -qx "records-directory=${RECORDS}" "${GITHUB_OUTPUT}"
}

@test "the state check reads the job's own Terraform data directory" {
  TF_DATA_DIR="/job/terraform-data" run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -qx "state check data /job/terraform-data" "${STUB_LOG}"
}

@test "a failed state check stops before the plan stage, with its code" {
  echo 4 > "${MARKS}/exit-state"
  run "${RECORD}" run plan
  [ "${status}" -eq 4 ]
  ! stage_call plan || false
  grep -q "Result: state check exit 4." "${GITHUB_STEP_SUMMARY}"
}

@test "the plan stage's exit code is the step's" {
  echo 6 > "${MARKS}/exit-plan"
  run "${RECORD}" run plan
  [ "${status}" -eq 6 ]
  grep -q "Result: exit 6." "${GITHUB_STEP_SUMMARY}"
}

@test "plan refuses a missing plan or saved plan" {
  PLAN="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The plan input is required for stage plan."* ]]
  SAVED_PLAN="nowhere/tfplan" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved-plan input names no file: 'nowhere/tfplan'."* ]]
  ! stage_call plan || false
}

@test "record-iac runs no Terraform" {
  run "${RECORD}" run plan
  run "${RECORD}" run post_deploy
  run "${RECORD}" run post_verify
  ! grep -q "^terraform" "${STUB_LOG}" || false
}

# --- pre_deploy --------------------------------------------------------------

@test "pre_deploy runs the stage with the records directory it is given" {
  RECORDS_DIRECTORY="${BATS_TEST_TMPDIR}/from-plan-job" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy | grep -qx "iltero iac check --stage=pre_deploy --unit=network --out=${BATS_TEST_TMPDIR}/from-plan-job --environment=production --upload"
  ! grep -q "state check" "${STUB_LOG}" || false
}

@test "pre_deploy is not in scope for a local record, and checks nothing" {
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice::Pre-deploy is not in scope for a local record."* ]]
  ! stage_call pre_deploy || false
  grep -q "Result: not in scope." "${GITHUB_STEP_SUMMARY}"
}

# --- post_deploy -------------------------------------------------------------

@test "post_deploy passes the plan, the apply log and the state" {
  run "${RECORD}" run post_deploy
  [ "${status}" -eq 0 ]
  stage_call post_deploy | grep -qx "iltero iac check --stage=post_deploy --plan=plan.json --saved-plan=tfplan --apply-log=apply.ndjson --state=state.json --unit=network --out=${RECORDS} --environment=production --upload"
}

@test "post_deploy refuses a missing apply log or state" {
  APPLY_LOG="" run "${RECORD}" run post_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The apply-log input is required for stage post_deploy."* ]]
  STATE="" run "${RECORD}" run post_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The state input is required for stage post_deploy."* ]]
  ! stage_call post_deploy || false
}

# --- post_verify -------------------------------------------------------------

@test "post_verify passes the two readings, in the order given" {
  run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  stage_call post_verify | grep -qx "iltero iac check --stage=post_verify --refresh-plan=first.json --refresh-plan=second.json --unit=network --out=${RECORDS} --environment=production --upload"
}

@test "post_verify skips blank lines between the readings" {
  REFRESH_PLANS=$'\nfirst.json\n  \nsecond.json\n\t\n' run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  stage_call post_verify | grep -q -- "--refresh-plan=first.json --refresh-plan=second.json "
}

@test "post_verify needs exactly two readings" {
  local readings
  for readings in "" "first.json" $'first.json\nsecond.json\nthird.json'; do
    REFRESH_PLANS="${readings}" run "${RECORD}" run post_verify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The refresh-plans input must name two readings, one per line, in the order they were taken."* ]]
  done
  ! stage_call post_verify || false
}

@test "post_verify refuses a reading that is not a file" {
  REFRESH_PLANS=$'first.json\nnowhere.json' run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The refresh-plans input names no file: 'nowhere.json'."* ]]
  ! stage_call post_verify || false
}

@test "the post_verify stage's exit code is the step's" {
  echo 1 > "${MARKS}/exit-post_verify"
  run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  grep -q "Result: exit 1." "${GITHUB_STEP_SUMMARY}"
}

# --- mode --------------------------------------------------------------------

@test "a linked project needs the job's identity token" {
  ACTIONS_ID_TOKEN_REQUEST_URL="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Grant it 'permissions: id-token: write'."* ]]
}

@test "an unlinked project records locally, with no run, no upload and no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  LINKED=false run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  stage_call plan | grep -qx "iltero iac check --stage=plan --plan=plan.json --saved-plan=tfplan --unit=network --out=${RECORDS} --environment=production"
}

@test "an unreadable config report stops the stage before the CLI checks it" {
  LINKED='"yes"' run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"config report could not be read"* ]]
  ! grep -q "iac check" "${STUB_LOG}" || false
}

@test "on a pull request, plan runs as a local check, never uploaded, even for a linked project" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  GITHUB_EVENT_NAME=pull_request run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  stage_call plan | grep -qx "iltero iac check --stage=plan --plan=plan.json --saved-plan=tfplan --unit=network --out=${RECORDS} --environment=production --local"
  ! grep -q "config show" "${STUB_LOG}" || false
}

@test "record-iac refuses pull request review events" {
  local event command
  for event in pull_request_review pull_request_review_comment; do
    for command in check run; do
      GITHUB_EVENT_NAME="${event}" run "${RECORD}" "${command}" plan
      [ "${status}" -eq 1 ]
      [[ "${output}" == *"record-iac does not run on ${event} events. Run it on pull_request events, where it checks the plan locally."* ]]
    done
  done
  ! grep -q "iac check" "${STUB_LOG}" || false
}

@test "outside a pull request, plan runs on the server, never as a local check" {
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  ! grep -q -- "--local" "${STUB_LOG}" || false
}

@test "a unit the stack does not have is refused" {
  UNIT="storage" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stack has no unit 'storage'."* ]]
  ! stage_call plan || false
}

@test "a unit list the CLI cannot give stops the step with one error" {
  touch "${MARKS}/no-units"
  run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The CLI could not list the units."* ]]
  [[ "${output}" != *"The stack has no unit"* ]]
}

@test "an environment of more than one line is refused" {
  ENVIRONMENT=$'production\n## heading' run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input must be a single line."* ]]
}

@test "the environment and unit inputs are required" {
  ENVIRONMENT="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input is required."* ]]
  UNIT="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit input is required."* ]]
}

# --- summary and report ------------------------------------------------------

@test "the summary names the unit and stage, and shows the CLI's output escaped" {
  run "${RECORD}" run plan
  grep -q "^## Iltero record: network, plan$" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>network: state-check</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "plan &lt;checked&gt; for network" "${GITHUB_STEP_SUMMARY}"
}

@test "the summary shows a unit name as written" {
  UNIT="app-db" run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -q "<summary>app-db: plan</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "a line of the CLI's output cannot act as a workflow command" {
  run "${RECORD}" run plan
  commands_paused_around "::warning::plan <checked> for network"
}

@test "the unit's record gets a report, in the artifact and the summary" {
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  local reports="${RUNNER_TEMP}/iltero-record-iac/reports"
  grep -qx "report-directory=${reports}" "${GITHUB_OUTPUT}"
  [ -f "${reports}/network/record-report.html" ]
  grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "a report the CLI does not write fails the step" {
  touch "${MARKS}/no-report"
  run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The CLI wrote no report for unit 'network'."* ]]
}

@test "a failed stage keeps its exit code when its report is missing" {
  echo 6 > "${MARKS}/exit-plan"
  touch "${MARKS}/no-report"
  run "${RECORD}" run plan
  [ "${status}" -eq 6 ]
}

@test "a write-report value other than true or false is refused" {
  WRITE_REPORT="yes" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The write-report input must be true or false, not 'yes'."* ]]
  ! stage_call plan || false
}

@test "with write-report false, no report is written" {
  WRITE_REPORT=false run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  ! grep -q "record report" "${STUB_LOG}" || false
  ! grep -q "^report-directory=" "${GITHUB_OUTPUT}" || false
}

# --- records directory and artifact ------------------------------------------

@test "a relative records directory is given to the upload as an absolute path" {
  RECORDS_DIRECTORY="records" run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -qx "records-directory=${STACK}/records" "${GITHUB_OUTPUT}"
  stage_call plan | grep -q -- "--out=${STACK}/records "
}

@test "the records artifact is named after the unit unless a name is given" {
  run "${RECORD}" run plan
  grep -qx "artifact-name=iltero-records-network" "${GITHUB_OUTPUT}"
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME="network-production" run "${RECORD}" run plan
  grep -qx "artifact-name=network-production" "${GITHUB_OUTPUT}"
}
