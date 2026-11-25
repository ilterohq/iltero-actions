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
  # The step for one stage gets only the inputs its step gives, as a workflow
  # would pass them. This wrapper clears the file inputs set below that the
  # stage's step does not give, when they still hold their default value.
  RECORD="${BATS_TEST_TMPDIR}/record-stage.sh"
  cat > "${RECORD}" << STAGE
#!/bin/bash
declare -A unused=(
  [plan]="APPLY_LOG STATE REFRESH_ONLY_PLANS"
  [pre_deploy]="PLAN SAVED_PLAN APPLY_LOG STATE REFRESH_ONLY_PLANS"
  [post_deploy]="REFRESH_ONLY_PLANS"
  [post_verify]="PLAN SAVED_PLAN APPLY_LOG"
)
declare -A defaults=(
  [PLAN]="plan.json" [SAVED_PLAN]="tfplan" [APPLY_LOG]="apply.ndjson" [STATE]="state.json"
  [REFRESH_ONLY_PLANS]=\$'first.json\nsecond.json\n'
)
# The action passes every input, as an empty string when it is not given.
for name in \${unused[\${2:-none}]:-}; do
  [[ "\${!name:-}" != "\${defaults[\${name}]}" ]] || export "\${name}="
done
exec "${REPO_ROOT}/scripts/iac/record.sh" "\$@"
STAGE
  chmod +x "${RECORD}"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  export MARKS="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${TOOLS}/venv/bin" "${MARKS}"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for the CLI. MARKS/exit-<stage> holds a stage's exit code,
  # MARKS/exit-scanners the scanner install's, MARKS/exit-state the state
  # check's and MARKS/in-scope-exit the answer of `record in-scope`.
  # MARKS/no-report makes the report exit 5 without writing. Each stage writes
  # the unit's record, which expects pre_deploy with MARKS/expects-pre-deploy,
  # and post_verify with MARKS/expects-post-verify.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
if [[ "$1 $2" == "scanners install" ]]; then
  echo "scanners install ILTERO_CACHE_DIR=${ILTERO_CACHE_DIR}" >> "${STUB_LOG}"
  echo "Trivy <installed>"
  [[ ! -e "${MARKS}/exit-scanners" ]] || exit "$(cat "${MARKS}/exit-scanners")"
  exit 0
fi
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
elif [[ -e "${MARKS}/expects-post-verify" ]]; then
  echo '{"expected_stages": ["plan", "post_deploy", "post_verify"]}' > "${out}/units/${unit}/car.json"
else
  echo '{"expected_stages": ["plan", "post_deploy"]}' > "${out}/units/${unit}/car.json"
fi
echo "::warning::${stage} <checked> for ${unit}"
# A post-deploy check given --state-unreadable exits 6, unless the test
# marks it as passing.
[[ " $* " != *" --state-unreadable "* || -e "${MARKS}/state-unreadable-passes" ]] || exit 6
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
  export REFRESH_ONLY_PLANS=$'first.json\nsecond.json\n'
  # The name the actions give this stack's work folder.
  STACK_FOLDER="$(stack_folder_name)"
  RECORDS="${RUNNER_TEMP}/iltero-records/production/${STACK_FOLDER}"
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
    [[ "${output}" == *"On pull request events, record-iac records only the plan stage, checked locally. Record the other stages after the merge, for example on push events."* ]]
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
    [[ "${output}" == *"Iltero actions do not run on '${event}' events. Run them on pull_request events for a pull request, or after the merge."* ]]
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
  grep -q "Result: state check failed." "${GITHUB_STEP_SUMMARY}"
}

@test "the plan stage's exit code is the step's" {
  echo 6 > "${MARKS}/exit-plan"
  run "${RECORD}" run plan
  [ "${status}" -eq 6 ]
  grep -q "Result: failed." "${GITHUB_STEP_SUMMARY}"
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

@test "plan passes each scan report to the CLI, in the order given, after the saved plan" {
  echo '{}' > checkov.json
  echo '{}' > trivy.json
  # The CLI refuses scan reports in a project linked to the server, outside pull
  # requests, so this test runs unlinked.
  LINKED=false SCAN_REPORTS=$'  checkov   checkov.json  \n\ntrivy trivy.json\n' run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  stage_call plan | grep -qx "iltero iac check --stage=plan --plan=plan.json --saved-plan=tfplan --scanner=checkov --scanner-report=checkov.json --scanner=trivy --scanner-report=trivy.json --unit=network --out=${RECORDS} --environment=production"
}

@test "plan refuses a scan-reports line that does not name checkov or trivy and a report" {
  local line
  echo '{}' > report.json
  for line in 'grype report.json' 'checkov' 'Checkov report.json' 'checkov:report.json'; do
    SCAN_REPORTS="${line}" run "${RECORD}" run plan
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Each line of the scan-reports input must be a scanner (checkov trivy), a space and the report's path. One line is '${line}'."* ]]
  done
  ! stage_call plan || false
}

@test "plan refuses a scan report that is not a file" {
  SCAN_REPORTS="checkov missing.json" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The scan-reports input names no file: 'missing.json'."* ]]
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
  RECORDS_DIRECTORY="${BATS_TEST_TMPDIR}/from-plan-job" run "${RECORD}" run plan
  : > "${STUB_LOG}"
  RECORDS_DIRECTORY="${BATS_TEST_TMPDIR}/from-plan-job" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy | grep -qx "iltero iac check --stage=pre_deploy --unit=network --out=${BATS_TEST_TMPDIR}/from-plan-job --environment=production --upload"
  ! grep -q "state check" "${STUB_LOG}" || false
  # A linked project asks the server first. It asks whether the record
  # requires the stage only after the CLI passed it, to word the summary.
  [ "$(grep -E "^iltero (iac check --stage=pre_deploy|record in-scope) " "${STUB_LOG}" | cut -d" " -f2-3)" == $'iac check\nrecord in-scope' ]
}

@test "a linked pre_deploy that the record leaves out reads not required in the summary" {
  run "${RECORD}" run plan
  : > "${GITHUB_STEP_SUMMARY}"
  run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy
  grep -q "^iltero record in-scope ${RECORDS}/units/network --stage=pre_deploy$" "${STUB_LOG}"
  grep -q "Result: not required." "${GITHUB_STEP_SUMMARY}"
  # The details show the check before the question, in the order they ran.
  [ "$(grep -o "<summary>network: [a-z -]*" "${GITHUB_STEP_SUMMARY}" | head -2)" == $'<summary>network: pre-deploy\n<summary>network: is the pre-deploy stage required' ]
}

@test "a linked pre_deploy that the record requires reads passed in the summary" {
  touch "${MARKS}/expects-pre-deploy"
  run "${RECORD}" run plan
  : > "${GITHUB_STEP_SUMMARY}"
  run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  grep -q "Result: passed." "${GITHUB_STEP_SUMMARY}"
}

@test "a linked pre_deploy that fails does not ask whether the record requires the stage" {
  touch "${MARKS}/expects-pre-deploy"
  run "${RECORD}" run plan
  : > "${STUB_LOG}"
  echo 1 > "${MARKS}/exit-pre_deploy"
  run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  ! grep -q "record in-scope" "${STUB_LOG}" || false
  grep -q "Result: failed." "${GITHUB_STEP_SUMMARY}"
}

@test "a linked pre_deploy that passed fails when the CLI then cannot say whether the record requires the stage" {
  run "${RECORD}" run plan
  : > "${GITHUB_STEP_SUMMARY}"
  echo 9 > "${MARKS}/in-scope-exit"
  run "${RECORD}" run pre_deploy
  [ "${status}" -eq 9 ]
  [[ "${output}" == *"The CLI could not say whether the record of unit 'network' requires the pre-deploy stage."* ]]
  grep -q "Result: record does not verify." "${GITHUB_STEP_SUMMARY}"
}

@test "a linked pre_deploy passes the plan, the saved plan and the new plan to the CLI when the step gives them" {
  run "${RECORD}" run plan
  : > "${STUB_LOG}"
  echo '{}' > "${BATS_TEST_TMPDIR}/rendered.json"
  echo plan > "${BATS_TEST_TMPDIR}/apply.tfplan"
  echo '{}' > "${BATS_TEST_TMPDIR}/replan.json"
  PLAN="${BATS_TEST_TMPDIR}/rendered.json" SAVED_PLAN="${BATS_TEST_TMPDIR}/apply.tfplan" REPLAN="${BATS_TEST_TMPDIR}/replan.json" \
    run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy | grep -qF -- "--stage=pre_deploy --plan=${BATS_TEST_TMPDIR}/rendered.json --saved-plan=${BATS_TEST_TMPDIR}/apply.tfplan --replan=${BATS_TEST_TMPDIR}/replan.json "
}

@test "a linked pre_deploy passes only the plan file its step gives" {
  run "${RECORD}" run plan
  : > "${STUB_LOG}"
  echo plan > "${BATS_TEST_TMPDIR}/apply.tfplan"
  SAVED_PLAN="${BATS_TEST_TMPDIR}/apply.tfplan" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  stage_call pre_deploy | grep -qF -- "--saved-plan=${BATS_TEST_TMPDIR}/apply.tfplan "
  ! stage_call pre_deploy | grep -qE -- "--(re)?plan=" || false
}

@test "a linked pre_deploy refuses a plan, saved-plan or replan input that names no file" {
  run "${RECORD}" run plan
  PLAN="${BATS_TEST_TMPDIR}/missing.json" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The plan input names no file: '${BATS_TEST_TMPDIR}/missing.json'."* ]]
  SAVED_PLAN="${BATS_TEST_TMPDIR}/missing.tfplan" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The saved-plan input names no file: '${BATS_TEST_TMPDIR}/missing.tfplan'."* ]]
  REPLAN="${BATS_TEST_TMPDIR}/missing-replan.json" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The replan input names no file: '${BATS_TEST_TMPDIR}/missing-replan.json'."* ]]
  ! stage_call pre_deploy || false
}

@test "a local pre_deploy refuses the plan, saved-plan and replan inputs, which it does not read" {
  LINKED=false run "${RECORD}" run plan
  echo '{}' > "${BATS_TEST_TMPDIR}/rendered.json"
  echo plan > "${BATS_TEST_TMPDIR}/apply.tfplan"
  echo '{}' > "${BATS_TEST_TMPDIR}/replan.json"
  local inputs
  for inputs in "PLAN=${BATS_TEST_TMPDIR}/rendered.json" "SAVED_PLAN=${BATS_TEST_TMPDIR}/apply.tfplan" "REPLAN=${BATS_TEST_TMPDIR}/replan.json"; do
    LINKED=false env "${inputs}" "${RECORD}" run pre_deploy > "${BATS_TEST_TMPDIR}/refused.txt" 2>&1 && return 1
    grep -qF "In a project not linked to the server, pre_deploy does not read the plan, saved-plan or replan input. Remove them from this step." "${BATS_TEST_TMPDIR}/refused.txt"
  done
  ! grep -q "record in-scope" "${STUB_LOG}" || false
}

@test "pre_deploy is not required for a local record, and checks nothing" {
  LINKED=false run "${RECORD}" run plan
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::notice::A project not linked to the server does not run the pre-deploy stage, and this unit's record does not require it. Nothing was checked."* ]]
  ! stage_call pre_deploy || false
  grep -q "Result: not required." "${GITHUB_STEP_SUMMARY}"
}

@test "a local pre_deploy with no record of the unit stops and says where the record comes from" {
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory holds no record of unit 'network'. Run the plan stage first. In another job, download the plan job's records artifact and pass its directory as records-directory."* ]]
  [[ "${output}" != *"does not run the pre-deploy stage"* ]]
  ! grep -q "Result: not required." "${GITHUB_STEP_SUMMARY}" || false
}

@test "a local pre_deploy whose record cannot be read fails the step and says so in the summary" {
  LINKED=false run "${RECORD}" run plan
  echo "not a record" > "${RECORDS}/units/network/car.json"
  : > "${GITHUB_STEP_SUMMARY}"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 9 ]
  [[ "${output}" == *"The CLI could not say whether the record of unit 'network' requires the pre-deploy stage. See the CLI's output in the log."* ]]
  grep -q "Result: record does not verify." "${GITHUB_STEP_SUMMARY}"
}

@test "a unit name that cannot name a directory is refused before the artifact is named" {
  UNIT="../x" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit name '../x' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."* ]]
}

@test "a linked pre_deploy with no record of the unit stops and says where the record comes from" {
  run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory holds no record of unit 'network'. Run the plan stage first."* ]]
  ! grep -q "record in-scope" "${STUB_LOG}" || false
  ! stage_call pre_deploy || false
}

@test "a local pre_deploy asks the CLI, keeps its answer and shows it paused and in the summary" {
  LINKED=false run "${RECORD}" run plan
  : > "${GITHUB_STEP_SUMMARY}"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope ${RECORDS}/units/network --stage=pre_deploy$" "${STUB_LOG}"
  grep -qx "The pre_deploy stage is out of scope." "${RUNNER_TEMP}/iltero-record-iac/production/${STACK_FOLDER}/units/network/pre_deploy/in-scope-pre_deploy.txt"
  commands_paused_around "::error::injected by the record"
  grep -q "<summary>network: is the pre-deploy stage required?</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "any other answer than in or out of scope fails a local pre_deploy with the CLI's code" {
  LINKED=false run "${RECORD}" run plan
  echo 2 > "${MARKS}/in-scope-exit"
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 2 ]
  grep -q "Result: record unreadable." "${GITHUB_STEP_SUMMARY}"
}

@test "a local pre_deploy whose record requires the stage fails" {
  touch "${MARKS}/expects-pre-deploy"
  LINKED=false run "${RECORD}" run plan
  LINKED=false run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::The record of unit 'network' requires the pre-deploy stage, which only a project linked to the server can run."* ]]
  [[ "${output}" != *"out_of_scope"* ]]
  ! stage_call pre_deploy || false
  grep -q "Result: required, needs the server." "${GITHUB_STEP_SUMMARY}"
}

# --- post_deploy -------------------------------------------------------------

@test "post_deploy passes the plan, the apply log and the state" {
  run "${RECORD}" run post_deploy
  [ "${status}" -eq 0 ]
  grep -q "Result: passed." "${GITHUB_STEP_SUMMARY}"
  stage_call post_deploy | grep -qx "iltero iac check --stage=post_deploy --plan=plan.json --saved-plan=tfplan --apply-log=apply.ndjson --state=state.json --unit=network --out=${RECORDS} --environment=production --upload"
}

@test "post_deploy records an apply whose state could not be read, and fails with the CLI's code" {
  STATE="" STATE_UNREADABLE=true run "${RECORD}" run post_deploy
  [ "${status}" -eq 6 ]
  stage_call post_deploy | grep -qx "iltero iac check --stage=post_deploy --plan=plan.json --saved-plan=tfplan --apply-log=apply.ndjson --state-unreadable --unit=network --out=${RECORDS} --environment=production --upload"
  grep -q "Result: failed without the state file." "${GITHUB_STEP_SUMMARY}"
}

@test "post_deploy that passes without the state says so" {
  touch "${MARKS}/state-unreadable-passes"
  STATE="" STATE_UNREADABLE=true run "${RECORD}" run post_deploy
  [ "${status}" -eq 0 ]
  grep -q "Result: passed without the state file." "${GITHUB_STEP_SUMMARY}"
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

@test "post_verify passes the two readings, in the order given, and the state" {
  run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  stage_call post_verify | grep -qx "iltero iac check --stage=post_verify --refresh-plan=first.json --refresh-plan=second.json --state=state.json --unit=network --out=${RECORDS} --environment=production --upload"
}

@test "post_verify skips blank lines between the readings" {
  REFRESH_ONLY_PLANS=$'\nfirst.json\n  \nsecond.json\n\t\n' run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  stage_call post_verify | grep -q -- "--refresh-plan=first.json --refresh-plan=second.json "
}

@test "post_verify trims the spaces around each reading's path" {
  REFRESH_ONLY_PLANS=$'  first.json\t\n second.json  ' run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  stage_call post_verify | grep -q -- "--refresh-plan=first.json --refresh-plan=second.json "
}

@test "a reading's path with a control character inside it is refused" {
  REFRESH_ONLY_PLANS=$'first\tcopy.json\nsecond.json' run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The refresh-only-plans input must be one line, with no tab or other control character."* ]]
}

@test "post_verify needs exactly two readings" {
  local readings
  for readings in "" "first.json" $'first.json\nsecond.json\nthird.json'; do
    REFRESH_ONLY_PLANS="${readings}" run "${RECORD}" run post_verify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The refresh-only-plans input must name two refresh-only plans, one per line, in the order they were taken."* ]]
  done
  ! stage_call post_verify || false
}

@test "post_verify requires the state" {
  STATE="" run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The state input is required for stage post_verify."* ]]
  ! stage_call post_verify || false
}

@test "post_verify refuses a state that is not a file" {
  STATE="nowhere.json" run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The state input names no file: 'nowhere.json'."* ]]
  ! stage_call post_verify || false
}

@test "post_verify refuses a reading that is not a file" {
  REFRESH_ONLY_PLANS=$'first.json\nnowhere.json' run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The refresh-only-plans input names no file: 'nowhere.json'."* ]]
  ! stage_call post_verify || false
}

@test "a linked post_verify that the record leaves out reads not required in the summary" {
  run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope ${RECORDS}/units/network --stage=post_verify$" "${STUB_LOG}"
  grep -q "Result: not required." "${GITHUB_STEP_SUMMARY}"
}

@test "a post_verify in a project not linked to the server reads passed and does not ask whether the record requires the stage" {
  LINKED=false run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  ! grep -q "record in-scope" "${STUB_LOG}" || false
  grep -q "Result: passed." "${GITHUB_STEP_SUMMARY}"
}

@test "a linked post_verify that the record requires reads passed in the summary" {
  touch "${MARKS}/expects-post-verify"
  run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  grep -q "^iltero record in-scope ${RECORDS}/units/network --stage=post_verify$" "${STUB_LOG}"
  grep -q "Result: passed." "${GITHUB_STEP_SUMMARY}"
}

@test "a linked post_verify that passed fails when the CLI then cannot say whether the record requires the stage" {
  echo 2 > "${MARKS}/in-scope-exit"
  run "${RECORD}" run post_verify
  [ "${status}" -eq 2 ]
  grep -q "Result: record unreadable." "${GITHUB_STEP_SUMMARY}"
}

@test "the post_verify stage's exit code is the step's" {
  echo 1 > "${MARKS}/exit-post_verify"
  run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  grep -q "Result: failed." "${GITHUB_STEP_SUMMARY}"
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

@test "on a pull request, plan runs as a local run, never uploaded, even for a linked project" {
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

@test "outside a pull request, plan runs on the server, never as a local run" {
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

@test "a unit list the CLI cannot give stops the step with one error, and the CLI's own code" {
  touch "${MARKS}/no-units"
  run "${RECORD}" run plan
  [ "${status}" -eq 3 ]
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
  grep -q "<summary>network: state check</summary>" "${GITHUB_STEP_SUMMARY}"
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
  local reports="${RUNNER_TEMP}/iltero-record-iac/production/${STACK_FOLDER}/reports"
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

@test "an environment with a space is refused before anything runs" {
  ENVIRONMENT="prod env" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot name a directory or a file. Use only letters, digits"* ]]
}

@test "the records artifact is named after the environment and the unit unless a name is given" {
  run "${RECORD}" run plan
  grep -qx "artifact-name=iltero-records-production-network-attempt-1" "${GITHUB_OUTPUT}"
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME="network-production" run "${RECORD}" run plan
  grep -qx "artifact-name=network-production-attempt-1" "${GITHUB_OUTPUT}"
}

@test "an artifact name that looks like an option is kept, with the attempt added" {
  local name
  for name in -n -e -E; do
    : > "${GITHUB_OUTPUT}"
    ARTIFACT_NAME="${name}" run "${RECORD}" run plan
    [ "${status}" -eq 0 ]
    grep -qx -- "artifact-name=${name}-attempt-1" "${GITHUB_OUTPUT}"
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

@test "each stack has its own default records folder, which every stage of the stack shares" {
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -qx "records-directory=${RECORDS}" "${GITHUB_OUTPUT}"
  cp -R "${STACK}" "${BATS_TEST_TMPDIR}/second-stack"
  cd "${BATS_TEST_TMPDIR}/second-stack"
  local second
  second="$(stack_folder_name)"
  [ "${second}" != "${STACK_FOLDER}" ]
  : > "${GITHUB_OUTPUT}"
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -qx "records-directory=${RUNNER_TEMP}/iltero-records/production/${second}" "${GITHUB_OUTPUT}"
  [ -f "${RECORDS}/units/network/car.json" ]
}

@test "every file input a stage does not read is refused, so no step seems to record a file it ignored" {
  local stage pair variable input
  declare -A read_by=(
    [plan]="plan saved-plan scan-reports"
    [pre_deploy]="plan saved-plan replan"
    [post_deploy]="plan saved-plan apply-log state"
    [post_verify]="refresh-only-plans state"
  )
  for stage in plan pre_deploy post_deploy post_verify; do
    for pair in PLAN:plan SAVED_PLAN:saved-plan REPLAN:replan SCAN_REPORTS:scan-reports APPLY_LOG:apply-log STATE:state REFRESH_ONLY_PLANS:refresh-only-plans; do
      variable="${pair%%:*}"
      input="${pair#*:}"
      [[ " ${read_by[${stage}]} " != *" ${input} "* ]] || continue
      env "${variable}=other-file" "${RECORD}" run "${stage}" > "${BATS_TEST_TMPDIR}/refused.txt" 2>&1 && return 1
      grep -qF "Stage ${stage} does not read the ${input} input. Remove it from this step." "${BATS_TEST_TMPDIR}/refused.txt"
    done
  done
  ! grep -q "^iltero iac check" "${STUB_LOG}" || false
}

@test "in a linked project, the plan stage installs the scanners into the tools folder before its check" {
  export ILTERO_CACHE_DIR="${BATS_TEST_TMPDIR}/elsewhere"
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  [ "$(grep -n '^iltero scanners install$' "${STUB_LOG}" | cut -d: -f1)" -lt "$(grep -n '^iltero iac check --stage=plan ' "${STUB_LOG}" | cut -d: -f1)" ]
  # The action names the folder itself, whatever the job set.
  grep -qx "scanners install ILTERO_CACHE_DIR=${TOOLS}/scanners" "${STUB_LOG}"
  [[ "${output}" == *"::group::Install the scanners"* ]]
}

@test "the scanners are installed only for the plan stage of a linked project, never on a pull request" {
  local stage
  # The pre-deploy stage reads the plan stage's record.
  run "${RECORD}" run plan
  : > "${STUB_LOG}"
  for stage in pre_deploy post_deploy post_verify; do
    run "${RECORD}" run "${stage}"
    [ "${status}" -eq 0 ]
  done
  LINKED=false run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  GITHUB_EVENT_NAME=pull_request run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  ! grep -q "scanners install" "${STUB_LOG}" || false
}

@test "a failed scanner install stops the plan stage with the CLI's exit code, before its check" {
  local code
  for code in 2 4 7 9; do
    echo "${code}" > "${MARKS}/exit-scanners"
    : > "${STUB_LOG}"
    run "${RECORD}" run plan
    [ "${status}" -eq "${code}" ]
    ! grep -q "^iltero iac check " "${STUB_LOG}" || false
    case "${code}" in
      9) [[ "${output}" == *"::error::A scanner or the scanner folder failed the Iltero CLI's integrity check against the pinned digests (fingerprints). The CLI's message above names the file or folder. Find out why before you run the job again."* ]] ;;
      4) [[ "${output}" == *"::error::The Iltero CLI could not install the scanners it pins. The CLI's message above says why. When a download failed, the job must reach github.com, pypi.org and files.pythonhosted.org, through the proxy in HTTPS_PROXY when the runner uses one."* ]] ;;
      *) [[ "${output}" == *"::error::The Iltero CLI could not install the scanners it pins. The CLI's message above says why."* && "${output}" != *"When a download failed"* ]] ;;
    esac
    commands_paused_around "Trivy <installed>"
  done
}

@test "the plan stage checks its own inputs and the state before it installs the scanners" {
  rm tfplan
  run "${RECORD}" run plan
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"saved-plan"* ]]
  echo 1 > "${MARKS}/exit-state"
  touch tfplan
  run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  ! grep -q "scanners install" "${STUB_LOG}" || false
}

@test "an operator-trust-file input that names no file stops the step before the CLI checks the stage" {
  OPERATOR_TRUST_FILE=missing.json run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The operator-trust-file input names no file: 'missing.json'."* ]]
  ! grep -q "^iltero iac check" "${STUB_LOG}" || false
}
