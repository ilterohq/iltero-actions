#!/usr/bin/env bats
#
# Tests for scripts/iac/record.sh, the body of the `record-iac` action.

load ../test_helper


setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export LINKED="true"
  export WRITE_REPORT="true"
  export STORE_RECORDS="false"
  export ENVIRONMENT="production"
  export STATE_UNREADABLE="false"
  export UNIT="network"
  : > "${GITHUB_STEP_SUMMARY}"
  RECORD="${REPO_ROOT}/scripts/iac/record.sh"
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
if [[ "$1 $2" == "record in-scope" ]]; then
  echo "::error::injected by the record"
  [[ ! -e "${MARKS}/in-scope-exit" ]] || exit "$(cat "${MARKS}/in-scope-exit")"
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
    if [[ -e "${MARKS}/dash-directory" ]]; then
      echo '[{"name": "network", "working_directory": "-L"}]'
      exit 0
    fi
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
if [[ -e "${MARKS}/expects-pre-deploy" ]]; then
  echo '{"expected_stages": ["plan", "pre_deploy", "post_deploy"]}' > "${out}/units/${unit}/car.json"
else
  echo '{"expected_stages": ["plan", "post_deploy"]}' > "${out}/units/${unit}/car.json"
fi
echo "::warning::${stage} <checked> for ${unit}"
# A post-deploy check given --state-unreadable always exits 6.
[[ " $* " != *" --state-unreadable "* ]] || exit 6
[[ ! -e "${MARKS}/exit-${stage}" ]] || exit "$(cat "${MARKS}/exit-${stage}")"
exit 0
STUB
  chmod +x "${TOOLS}/venv/bin/iltero"
  # The stub's variables expand when it runs, not here.
  # shellcheck disable=SC2016
  stub terraform 'echo "terraform $*" >> "${STUB_LOG}"'

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/app-db"
  cd "${STACK}" || return
  echo '{}' > plan.json
  echo 'binary' > tfplan
  echo '{}' > apply.ndjson
  echo '{}' > state.json
  echo '{}' > first.json
  echo '{}' > second.json
  export PLAN="plan.json" SAVED_PLAN="tfplan" APPLY_LOG="apply.ndjson" STATE="state.json"
  export REFRESH_PLANS=$'first.json\nsecond.json\n'
  RECORDS="${RUNNER_TEMP}/iltero-records/production"
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
    [[ "${output}" == *"On pull request events, record-iac records only the plan stage, checked locally."* ]]
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

@test "run also refuses pull_request_target and workflow_run events" {
  local event
  for event in pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${RECORD}" run plan
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Iltero actions do not run on '${event}' events."* ]]
  done
  ! grep -q "^iltero" "${STUB_LOG}" || false
}

@test "check refuses a stage input that names two stages" {
  run "${RECORD}" check "plan pre_deploy"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stage input must be one of:"* ]]
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
  LINKED=false run "${RECORD}" run plan
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice::A project with no platform section does not run the pre-deploy stage. Nothing was checked."* ]]
  ! stage_call pre_deploy || false
  grep -q "Result: not in scope." "${GITHUB_STEP_SUMMARY}"
}

@test "a local pre_deploy with no record of the unit stops and says where the record comes from" {
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory holds no record of unit 'network'. Run the plan stage first. In another job, download the plan job's records artifact and pass its directory as records-directory."* ]]
  [[ "${output}" != *"does not run the pre-deploy stage"* ]]
  ! grep -q "Result: not in scope." "${GITHUB_STEP_SUMMARY}" || false
}

@test "a local pre_deploy whose record cannot be read fails the step and says so in the summary" {
  LINKED=false run "${RECORD}" run plan
  echo "not a record" > "${RECORDS}/units/network/car.json"
  : > "${GITHUB_STEP_SUMMARY}"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 9 ]
  [[ "${output}" == *"The CLI could not say whether the record of unit 'network' expects the pre-deploy stage (exit 9)."* ]]
  grep -q "Result: record does not verify." "${GITHUB_STEP_SUMMARY}"
}

@test "a unit name that breaks the unit-name rule is refused before the artifact is named" {
  UNIT="../x" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit name '../x' does not follow the unit-name rule."* ]]
}

@test "a local pre_deploy asks the CLI, keeps its answer and shows it paused and in the summary" {
  LINKED=false run "${RECORD}" run plan
  : > "${GITHUB_STEP_SUMMARY}"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope ${RECORDS}/units/network --stage=pre_deploy$" "${STUB_LOG}"
  grep -qx "The pre_deploy stage is out of scope." "${RUNNER_TEMP}/iltero-record-iac/production/units/network/pre_deploy/in-scope-pre_deploy.txt"
  commands_paused_around "::error::injected by the record"
  grep -q "<summary>network: in-scope-pre-deploy</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "any other answer than in or out of scope fails a local pre_deploy with the CLI's code" {
  LINKED=false run "${RECORD}" run plan
  echo 2 > "${MARKS}/in-scope-exit"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 2 ]
  grep -q "Result: record unreadable." "${GITHUB_STEP_SUMMARY}"
}

@test "a local pre_deploy whose record expects the stage says it did not run, and how to leave it out" {
  touch "${MARKS}/expects-pre-deploy"
  LINKED=false run "${RECORD}" run plan
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"List pre_deploy under stages.out_of_scope in .iltero/config.yml."* ]]
  ! stage_call pre_deploy || false
  grep -q "Result: not run." "${GITHUB_STEP_SUMMARY}"
}

# --- post_deploy -------------------------------------------------------------

@test "post_deploy passes the plan, the apply log and the state" {
  run "${RECORD}" run post_deploy
  [ "${status}" -eq 0 ]
  stage_call post_deploy | grep -qx "iltero iac check --stage=post_deploy --plan=plan.json --saved-plan=tfplan --apply-log=apply.ndjson --state=state.json --unit=network --out=${RECORDS} --environment=production --upload"
}

@test "post_deploy records an apply whose state could not be read, and fails with the CLI's code" {
  STATE="" STATE_UNREADABLE=true run "${RECORD}" run post_deploy
  [ "${status}" -eq 6 ]
  stage_call post_deploy | grep -qx "iltero iac check --stage=post_deploy --plan=plan.json --saved-plan=tfplan --apply-log=apply.ndjson --state-unreadable --unit=network --out=${RECORDS} --environment=production --upload"
  grep -q "Result: exit 6, state not read." "${GITHUB_STEP_SUMMARY}"
}

@test "post_deploy refuses both the state and state-unreadable" {
  STATE_UNREADABLE=true run "${RECORD}" run post_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Give either the state input or state-unreadable: true, not both."* ]]
  ! stage_call post_deploy || false
}

@test "state-unreadable applies only to post_deploy, and is true or false" {
  STATE_UNREADABLE=true run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The state-unreadable input applies only to the post_deploy stage."* ]]
  STATE_UNREADABLE=yes run "${RECORD}" run post_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The state-unreadable input must be true or false, not 'yes'."* ]]
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

@test "with store-records true, a linked project's every stage keeps its record in the run's artifact store" {
  STORE_RECORDS=true run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  stage_call plan | grep -q -- " --upload --store$"
  STORE_RECORDS=true run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy | grep -q -- " --upload --store$"
}

@test "on a pull request, store-records is not used" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  GITHUB_EVENT_NAME=pull_request STORE_RECORDS=true run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  stage_call plan | grep -q -- " --local$"
  ! stage_call plan | grep -qE -- "--store|--upload" || false
}

@test "in a project without a platform section, store-records is passed on for the CLI to refuse" {
  LINKED=false STORE_RECORDS=true run "${RECORD}" run plan
  stage_call plan | grep -q -- "--environment=production --store$"
}

@test "a store-records value other than true or false is refused" {
  STORE_RECORDS=yes run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The store-records input must be true or false, not 'yes'."* ]]
  ! stage_call plan || false
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
  [[ "${output}" == *"The environment input must be one line, with no tab or other control character."* ]]
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
  local reports="${RUNNER_TEMP}/iltero-record-iac/production/reports"
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

@test "an environment that cannot name a directory is refused before anything is written" {
  local name
  for name in .. . a/b ../x; do
    : > "${GITHUB_OUTPUT}"
    ENVIRONMENT="${name}" run "${RECORD}" run plan
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
    ENVIRONMENT="${name}" ARTIFACT_NAME=records run "${RECORD}" run plan
    [ "${status}" -eq 1 ]
    ! grep -q "^records-directory=" "${GITHUB_OUTPUT}" || false
  done
}

@test "an environment that cannot name an artifact needs an artifact name" {
  ENVIRONMENT="prod env" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The default artifact name 'iltero-records-prod env-network' is not a valid artifact name. Set the artifact-name input."* ]]
}

@test "the records artifact is named after the environment and the unit unless a name is given" {
  run "${RECORD}" run plan
  grep -qx "artifact-name=iltero-records-production-network" "${GITHUB_OUTPUT}"
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME="network-production" run "${RECORD}" run plan
  grep -qx "artifact-name=network-production" "${GITHUB_OUTPUT}"
}

@test "an artifact name that looks like an option is kept as given" {
  local name
  for name in -n -e -E; do
    : > "${GITHUB_OUTPUT}"
    ARTIFACT_NAME="${name}" run "${RECORD}" run plan
    [ "${status}" -eq 0 ]
    grep -qx -- "artifact-name=${name}" "${GITHUB_OUTPUT}"
  done
}

@test "a unit directory that starts with a dash is refused" {
  touch "${MARKS}/dash-directory"
  run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit 'network' has a directory that starts with '-': '-L'. Rename the directory."* ]]
  ! stage_call plan || false
}

@test "a records directory that looks like an option is a directory in the project" {
  local name
  for name in -- - -e; do
    : > "${GITHUB_OUTPUT}"
    RECORDS_DIRECTORY="${name}" run "${RECORD}" run plan
    [ "${status}" -eq 0 ]
    grep -qx -- "records-directory=${STACK}/${name}" "${GITHUB_OUTPUT}"
  done
}
