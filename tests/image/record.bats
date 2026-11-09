#!/usr/bin/env bats
#
# Tests for scripts/image/record.sh, the body of the `record-image` action.

load ../test_helper

setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/?api-version=2.0"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export LINKED="true"
  export STORE_RECORDS="false"
  export ADVISORY="false"
  IMAGE="registry.example.com/acme/api:1.4.2@sha256:$(printf 'a%.0s' {1..64})"
  export IMAGE
  export APPLICATION="api"
  export UNIT="root"
  : > "${GITHUB_STEP_SUMMARY}"
  RECORD="${REPO_ROOT}/scripts/image/record.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  export MARKS="${BATS_TEST_TMPDIR}/marks"
  mkdir -p "${TOOLS}/venv/bin" "${MARKS}"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for the CLI. MARKS/exit-check holds the image check's exit
  # code. The check writes the unit's record.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
case "$1 $2" in
  "config show")
    echo "{\"linked\": ${LINKED}}"
    exit 0
    ;;
esac
unit="" out=""
for arg in "$@"; do
  case "${arg}" in
    --unit=*) unit="${arg#--unit=}" ;;
    --out=*) out="${arg#--out=}" ;;
  esac
done
mkdir -p "${out}/units/${unit}"
touch "${out}/units/${unit}/car.json"
echo "::warning::image <checked> for ${unit}"
[[ ! -e "${MARKS}/exit-check" ]] || exit "$(cat "${MARKS}/exit-check")"
exit 0
STUB
  chmod +x "${TOOLS}/venv/bin/iltero"

  PROJECT="${BATS_TEST_TMPDIR}/project"
  mkdir -p "${PROJECT}"
  cd "${PROJECT}" || return
  echo '{}' > metadata.json
  echo '{}' > index.json
  echo '{}' > provenance.sigstore.json
  echo '<testsuites/>' > junit.xml
  echo '{}' > trivy.json
  echo '{}' > grype.json
  echo '{}' > before.json
  echo '{}' > pods.json
  echo '{}' > owners.json
  echo '{}' > after.json
  RECORDS="${RUNNER_TEMP}/iltero-image-records"
  DEPLOYMENTS="${RUNNER_TEMP}/iltero-image-deployment-records/production"
  DEPLOYED="registry.example.com/acme/api@sha256:$(printf 'a%.0s' {1..64})"
  CLUSTER="0b6a3c1e-5f2d-4e8a-9c7b-1d2e3f4a5b6c"
}

# Prints the CLI's image check call from the stub log.
check_call() {
  grep "^iltero image check " "${STUB_LOG}"
}

# --- check -------------------------------------------------------------------

@test "check refuses pull_request_target and workflow_run events" {
  local event
  for event in pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${RECORD}" check plan
    [ "${status}" -eq 1 ]
  done
}

@test "check refuses pull request review events" {
  local event
  for event in pull_request_review pull_request_review_comment; do
    GITHUB_EVENT_NAME="${event}" run "${RECORD}" check plan
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"record-image does not run on ${event} events. Run it on pull_request events, where it checks the image locally."* ]]
  done
}

@test "check accepts push and pull_request events" {
  local event
  for event in push pull_request workflow_dispatch; do
    GITHUB_EVENT_NAME="${event}" run "${RECORD}" check plan
    [ "${status}" -eq 0 ]
  done
}

@test "check refuses an artifact name that is not a valid name" {
  ARTIFACT_NAME="records/../x" run "${RECORD}" check plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name 'records/../x'."* ]]
}

@test "check needs setup" {
  rm "${TOOLS}/venv/bin/iltero"
  run "${RECORD}" check plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Run the setup action first"* ]]
}

@test "check refuses an unknown stage" {
  run "${RECORD}" check deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stage input must be one of: plan pre_deploy post_deploy post_verify. It is 'deploy'."* ]]
}

@test "check refuses an empty stage" {
  run "${RECORD}" check ""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"It is ''."* ]]
}

@test "check refuses a stage input that names two stages" {
  run "${RECORD}" check "plan pre_deploy"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stage input must be one of:"* ]]
}

@test "check accepts every stage outside a pull request" {
  local stage
  for stage in plan pre_deploy post_deploy post_verify; do
    run "${RECORD}" check "${stage}"
    [ "${status}" -eq 0 ]
  done
}

@test "on pull_request events, check refuses every stage but plan" {
  local stage
  for stage in pre_deploy post_deploy post_verify; do
    GITHUB_EVENT_NAME=pull_request run "${RECORD}" check "${stage}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"On pull request events, record-image records only the plan stage, checked locally."* ]]
  done
}

@test "the script takes one stage" {
  run "${RECORD}" run
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Usage: image/record.sh run STAGE"* ]]
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

@test "run checks the event again" {
  GITHUB_EVENT_NAME=pull_request_review run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  ! grep -q "^iltero" "${STUB_LOG}" || false
}

# --- the image check ---------------------------------------------------------

@test "a linked project's image is checked in the build run of its application, and sent" {
  run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=plan --image=${IMAGE} --unit=root --out=${RECORDS} --application=api --upload"
}

@test "the given files are passed to the check, each under its own option" {
  BUILD_METADATA=metadata.json IMAGE_INDEX=index.json ATTESTATION=provenance.sigstore.json \
    TEST_REPORTS=$'junit.xml\n' SCAN_REPORTS=$'trivy trivy.json\ngrype grype.json' run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=plan --build-metadata=metadata.json --image-index=index.json --attestation=provenance.sigstore.json --test-report=junit.xml --scanner=trivy --scanner-report=trivy.json --scanner=grype --scanner-report=grype.json --image=${IMAGE} --unit=root --out=${RECORDS} --application=api --upload"
}

@test "blank lines and spaces around each line of the report lists are skipped" {
  TEST_REPORTS=$'\n  junit.xml \n\n' SCAN_REPORTS=$'  trivy   trivy.json  \n\n' run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -q -- " --test-report=junit.xml --scanner=trivy --scanner-report=trivy.json "
}

@test "a report path that starts with a dash is passed as given" {
  echo '<testsuites/>' > ./-n
  echo '{}' > ./-e
  TEST_REPORTS='-n' SCAN_REPORTS='trivy -e' run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -q -- " --test-report=-n --scanner=trivy --scanner-report=-e "
}

@test "a scan report line without a known scanner and a path is refused" {
  local line
  for line in "trivy" "clair report.json" "trivy.json"; do
    SCAN_REPORTS="${line}" run "${RECORD}" run plan
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Each line of the scan-reports input must be a scanner (trivy grype), a space and the report's path. One line is '${line}'."* ]]
  done
  ! check_call || false
}

@test "a file input that names no file is refused before the check" {
  local input
  for input in BUILD_METADATA IMAGE_INDEX ATTESTATION TEST_REPORTS; do
    env "${input}=missing.json" "${RECORD}" run plan > "${BATS_TEST_TMPDIR}/out" 2>&1 && false
    grep -q "names no file: 'missing.json'" "${BATS_TEST_TMPDIR}/out"
  done
  SCAN_REPORTS="trivy missing.json" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The scan-reports input names no file: 'missing.json'."* ]]
  ! check_call || false
}

@test "the check's exit code is the step's" {
  local code
  for code in 1 2 3 5 7 8 9; do
    echo "${code}" > "${MARKS}/exit-check"
    run "${RECORD}" run plan
    [ "${status}" -eq "${code}" ]
  done
}

@test "a linked project needs the job's identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id-token: write"* ]]
  ! check_call || false
}

@test "an unlinked project records locally, with no upload and no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  LINKED=false APPLICATION="" run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=plan --image=${IMAGE} --unit=root --out=${RECORDS}"
}

@test "outside a pull request, the application is passed as given, for the CLI to check" {
  LINKED=false run "${RECORD}" run plan
  check_call | grep -q -- " --application=api$"
}

@test "on a pull request, the image is checked locally and as advice, with no application and no upload" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  GITHUB_EVENT_NAME=pull_request run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=plan --image=${IMAGE} --unit=root --out=${RECORDS} --local --advisory"
  ! grep -q "config show" "${STUB_LOG}" || false
}

@test "with store-records true, a linked project's image record is kept in the run's artifact store" {
  STORE_RECORDS=true run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -q -- " --application=api --upload --store$"
}

@test "on a pull request, store-records is not used" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  GITHUB_EVENT_NAME=pull_request STORE_RECORDS=true run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  check_call | grep -q -- " --local --advisory$"
  ! check_call | grep -qE -- "--store|--upload" || false
}

@test "in a project without a platform section, store-records is passed on for the CLI to refuse" {
  LINKED=false APPLICATION="" STORE_RECORDS=true run "${RECORD}" run plan
  check_call | grep -q -- "--out=${RECORDS} --store$"
}

@test "a store-records value other than true or false is refused" {
  STORE_RECORDS=yes run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The store-records input must be true or false, not 'yes'."* ]]
  ! check_call || false
}

@test "the image and unit inputs are required" {
  IMAGE="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The image input is required for stage plan."* ]]
  UNIT="" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit input is required."* ]]
}

@test "an image or application of more than one line is refused" {
  IMAGE=$'a\nb' run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The image input must be one line, with no tab or other control character."* ]]
  APPLICATION=$'api\n--local' run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The application input must be one line, with no tab or other control character."* ]]
  ! check_call || false
}

@test "a unit name that breaks the unit-name rule is refused" {
  UNIT="../api" run "${RECORD}" run plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit name '../api' does not follow the unit-name rule."* ]]
}

@test "the check runs the evaluator setup installed" {
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "opa ${ILTERO_OPA_PATH:-}" >> "${STUB_LOG}"
[[ "$1 $2" != "config show" ]] || echo '{"linked": false}'
STUB
  run "${RECORD}" run plan
  grep -qx "opa ${TOOLS}/bin/opa" "${STUB_LOG}"
}

# --- summary -----------------------------------------------------------------

@test "the summary names the unit and image, and shows the CLI's output escaped" {
  run "${RECORD}" run plan
  grep -q "^## Iltero image record: root, plan$" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>root: image check, plan</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -q "image &lt;checked&gt; for root" "${GITHUB_STEP_SUMMARY}"
}

@test "a line of the CLI's output cannot act as a workflow command" {
  run "${RECORD}" run plan
  commands_paused_around "::warning::image <checked> for root"
}

# --- records directory and artifact ------------------------------------------

@test "by default the records go to their own folder, apart from record-iac's" {
  run "${RECORD}" run plan
  grep -qx "records-directory=${RUNNER_TEMP}/iltero-image-records" "${GITHUB_OUTPUT}"
}

@test "a relative records directory is given to the upload as an absolute path" {
  RECORDS_DIRECTORY="records" run "${RECORD}" run plan
  [ "${status}" -eq 0 ]
  grep -qx "records-directory=${PROJECT}/records" "${GITHUB_OUTPUT}"
  check_call | grep -q -- "--out=${PROJECT}/records "
}

@test "the records artifact is named after the unit unless a name is given" {
  UNIT=api run "${RECORD}" run plan
  grep -qx "artifact-name=iltero-image-records-api" "${GITHUB_OUTPUT}"
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME="api-image" run "${RECORD}" run plan
  grep -qx "artifact-name=api-image" "${GITHUB_OUTPUT}"
}

# --- deployment stages -------------------------------------------------------

@test "pre_deploy checks the image to deploy locally, in the given environment, with no identity token" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  IMAGE="${DEPLOYED}" APPLICATION="" ENVIRONMENT=production run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=pre_deploy --image=${DEPLOYED} --environment=production --unit=root --out=${DEPLOYMENTS}"
  ! grep -q "config show" "${STUB_LOG}" || false
}

@test "post_deploy reports the deployed image, into the same records directory" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" APPLICATION="" run "${RECORD}" run post_deploy
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=post_deploy --image=${DEPLOYED} --environment=production --unit=root --out=${DEPLOYMENTS}"
}

@test "post_verify passes the cluster and the four readings of the workload" {
  IMAGE="" APPLICATION="" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
    ENVIRONMENT=production POD_OWNERS=owners.json WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  check_call | grep -qx -- "iltero image check --stage=post_verify --workload-before-pods-listing=before.json --pods=pods.json --pod-owners=owners.json --workload-after-pods-listing=after.json --cluster-id=${CLUSTER} --environment=production --unit=root --out=${DEPLOYMENTS}"
}

@test "post_verify leaves pod-owners out when it is not given, for the CLI to decide by the workload's kind" {
  IMAGE="" APPLICATION="" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
    ENVIRONMENT=production WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run post_verify
  [ "${status}" -eq 0 ]
  ! check_call | grep -q -- "--pod-owners" || false
}

@test "every deployment stage needs the environment" {
  local stage
  for stage in pre_deploy post_deploy post_verify; do
    IMAGE="${DEPLOYED}" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
      WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run "${stage}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The environment input is required for stage ${stage}."* ]]
  done
  ! check_call || false
}

@test "each deployment stage needs its own inputs" {
  ENVIRONMENT=production IMAGE="" run "${RECORD}" run pre_deploy
  [[ "${output}" == *"The image input is required for stage pre_deploy."* ]]
  ENVIRONMENT=production IMAGE="" run "${RECORD}" run post_deploy
  [[ "${output}" == *"The image input is required for stage post_deploy."* ]]
  local input
  for input in CLUSTER_ID WORKLOAD_BEFORE_PODS_LISTING PODS WORKLOAD_AFTER_PODS_LISTING; do
    env ENVIRONMENT=production IMAGE="" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
      WORKLOAD_AFTER_PODS_LISTING=after.json "${input}=" "${RECORD}" run post_verify > "${BATS_TEST_TMPDIR}/out" 2>&1 && false
    grep -q "input is required for stage post_verify." "${BATS_TEST_TMPDIR}/out"
  done
  ! check_call || false
}

@test "a reading of the workload that names no file is refused before the check" {
  IMAGE="" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=missing.json \
    ENVIRONMENT=production WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run post_verify
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The pods input names no file: 'missing.json'."* ]]
  ! check_call || false
}

@test "an environment or cluster id of more than one line is refused" {
  IMAGE="${DEPLOYED}" ENVIRONMENT=$'production\n--local' run "${RECORD}" run pre_deploy
  [[ "${output}" == *"The environment input must be one line, with no tab or other control character."* ]]
  IMAGE="" CLUSTER_ID=$'a\nb' WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
    ENVIRONMENT=production WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run post_verify
  [[ "${output}" == *"The cluster-id input must be one line, with no tab or other control character."* ]]
  ! check_call || false
}

@test "inputs a deployment stage does not take are passed on for the CLI to refuse" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" BUILD_METADATA=metadata.json STORE_RECORDS=true run "${RECORD}" run pre_deploy
  check_call | grep -q -- "--build-metadata=metadata.json "
  check_call | grep -q -- " --application=api --store$"
  ! check_call | grep -q -- "--upload" || false
  : > "${STUB_LOG}"
  IMAGE="${DEPLOYED}" CLUSTER_ID="${CLUSTER}" WORKLOAD_BEFORE_PODS_LISTING=before.json PODS=pods.json \
    ENVIRONMENT=production WORKLOAD_AFTER_PODS_LISTING=after.json run "${RECORD}" run post_verify
  check_call | grep -q -- " --image=${DEPLOYED} "
  : > "${STUB_LOG}"
  ENVIRONMENT=production run "${RECORD}" run plan
  check_call | grep -q -- " --environment=production "
}

@test "with advisory true, pre_deploy checks as advice" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" APPLICATION="" ADVISORY=true run "${RECORD}" run pre_deploy
  [ "${status}" -eq 0 ]
  check_call | grep -q -- "--out=${DEPLOYMENTS} --advisory$"
}

@test "advisory is passed on at every stage, for the CLI to refuse where it does not apply" {
  ADVISORY=true run "${RECORD}" run plan
  check_call | grep -q -- " --application=api --advisory --upload$"
}

@test "the summary says when a stage was checked as advice" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" APPLICATION="" ADVISORY=true run "${RECORD}" run pre_deploy
  grep -q "^Result: exit 0, checked as advice: failed or undecided assertions do not fail the step\.$" "${GITHUB_STEP_SUMMARY}"
  : > "${GITHUB_STEP_SUMMARY}"
  GITHUB_EVENT_NAME=pull_request run "${RECORD}" run plan
  grep -q "^Result: exit 0, checked as advice: failed or undecided assertions do not fail the step\.$" "${GITHUB_STEP_SUMMARY}"
  : > "${GITHUB_STEP_SUMMARY}"
  ENVIRONMENT=production IMAGE="${DEPLOYED}" APPLICATION="" run "${RECORD}" run pre_deploy
  grep -q "^Result: exit 0\.$" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed stage checked as advice shows only its exit code" {
  echo 2 > "${MARKS}/exit-check"
  ENVIRONMENT=production IMAGE="${DEPLOYED}" APPLICATION="" ADVISORY=true run "${RECORD}" run pre_deploy
  grep -q "^Result: exit 2\.$" "${GITHUB_STEP_SUMMARY}"
}

@test "an advisory value other than true or false is refused" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" ADVISORY=yes run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The advisory input must be true or false, not 'yes'."* ]]
  ! check_call || false
}

@test "a deployment stage's exit code is the step's" {
  local code
  for code in 1 2 3 5; do
    echo "${code}" > "${MARKS}/exit-check"
    ENVIRONMENT=production IMAGE="${DEPLOYED}" run "${RECORD}" run post_deploy
    [ "${status}" -eq "${code}" ]
  done
}

@test "a deployment's environment that cannot name a directory is refused before anything is written" {
  local name
  for name in .. . a/b ../x; do
    : > "${GITHUB_OUTPUT}"
    ENVIRONMENT="${name}" IMAGE="${DEPLOYED}" ARTIFACT_NAME=records run "${RECORD}" run pre_deploy
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
    ! grep -q "^records-directory=" "${GITHUB_OUTPUT}" || false
  done
  ! check_call || false
}

@test "a deployment's environment that cannot name an artifact needs an artifact name" {
  ENVIRONMENT="prod env" IMAGE="${DEPLOYED}" run "${RECORD}" run pre_deploy
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The default artifact name 'iltero-image-deployment-records-prod env-root' is not a valid artifact name."* ]]
}

@test "a deployment's records and artifact are apart from the build's" {
  ENVIRONMENT=production IMAGE="${DEPLOYED}" UNIT=api run "${RECORD}" run pre_deploy
  grep -qx "records-directory=${DEPLOYMENTS}" "${GITHUB_OUTPUT}"
  grep -qx "artifact-name=iltero-image-deployment-records-production-api" "${GITHUB_OUTPUT}"
}

@test "the summary of a deployment stage names the stage, the image and the environment" {
  IMAGE="${DEPLOYED}" ENVIRONMENT=production run "${RECORD}" run pre_deploy
  grep -q "^## Iltero image record: root, pre-deploy$" "${GITHUB_STEP_SUMMARY}"
  grep -q "^Environment: production\.$" "${GITHUB_STEP_SUMMARY}"
  grep -q "<summary>root: image check, pre-deploy</summary>" "${GITHUB_STEP_SUMMARY}"
}

@test "the action passes every input to the script" {
  local input
  grep -qF "image/record.sh\" check \"\${STAGE}\"" "${REPO_ROOT}/record-image/action.yml"
  grep -qF "image/record.sh\" run \"\${STAGE}\"" "${REPO_ROOT}/record-image/action.yml"
  for input in STAGE IMAGE APPLICATION ENVIRONMENT UNIT BUILD_METADATA IMAGE_INDEX ATTESTATION TEST_REPORTS SCAN_REPORTS CLUSTER_ID WORKLOAD_BEFORE_PODS_LISTING PODS POD_OWNERS WORKLOAD_AFTER_PODS_LISTING RECORDS_DIRECTORY ARTIFACT_NAME STORE_RECORDS ADVISORY; do
    grep -qE "^        ${input}: \\$\\{\\{ inputs\\.[a-z-]+ \\}\\}$" "${REPO_ROOT}/record-image/action.yml"
  done
  for input in stage environment cluster-id workload-before-pods-listing pods pod-owners workload-after-pods-listing advisory; do
    grep -qx "        $(echo "${input}" | tr 'a-z-' 'A-Z_'): \${{ inputs.${input} }}" "${REPO_ROOT}/record-image/action.yml"
  done
}

@test "a records directory that looks like an option is a directory in the project" {
  local name
  for name in -- - -e; do
    : > "${GITHUB_OUTPUT}"
    RECORDS_DIRECTORY="${name}" run "${RECORD}" run plan
    [ "${status}" -eq 0 ]
    grep -qx -- "records-directory=${PROJECT}/${name}" "${GITHUB_OUTPUT}"
  done
}
