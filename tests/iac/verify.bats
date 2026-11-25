#!/usr/bin/env bats
#
# Tests for scripts/iac/verify.sh, the body of the `verify` action.

load ../test_helper

setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  : > "${GITHUB_STEP_SUMMARY}"
  VERIFY="${REPO_ROOT}/scripts/iac/verify.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  export MARKS="${BATS_TEST_TMPDIR}/marks"
  export OUT="${BATS_TEST_TMPDIR}/out"
  # The CLI stand-in lists these units when a test writes this file.
  export UNITS_JSON="${BATS_TEST_TMPDIR}/units.json"
  export WRITE_REPORT="true"
  export ENVIRONMENT="production"
  mkdir -p "${TOOLS}/venv/bin" "${MARKS}" "${OUT}"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for the CLI. `record build` makes the unit's bundle unless
  # MARKS/exit-build-<unit> gives its exit code or MARKS/no-bundle-<unit>
  # exists; `record verify` exits with
  # MARKS/exit-verify-<unit> or 0; `record report` writes record-report.<format>
  # into --out and exits with MARKS/exit-report-<unit> or 0, or exits 5
  # without writing when MARKS/no-report-<unit> exists. With
  # MARKS/no-markdown-<unit>, it writes only the HTML page.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $* ILTERO_OPA_PATH=${ILTERO_OPA_PATH}" >> "${STUB_LOG}"
if [[ "$1 $2" == "units list" ]]; then
  [[ ! -e "${UNITS_JSON:-}" ]] || { cat "${UNITS_JSON}"; exit 0; }
  echo '[{"name": "network", "working_directory": "units/network"}, {"name": "compute", "working_directory": "units/compute"}]'
  exit 0
fi
if [[ "$1 $2" == "record build" ]]; then
  unit="${4#--unit=}"
  [[ ! -e "${MARKS}/exit-build-${unit}" ]] || exit "$(cat "${MARKS}/exit-build-${unit}")"
  [[ -e "${MARKS}/no-bundle-${unit}" ]] || mkdir -p "${3#--out=}/units/${unit}/car-0001"
  echo "built <${unit}>"
  exit 0
fi
if [[ "$1 $2" == "record report" ]]; then
  unit="$(basename "$(dirname "$3")")" format="${4#--format=}" dir="${5#--out=}"
  [[ "${format}" == markdown ]] && extension=md || extension="${format}"
  [[ -e "${MARKS}/no-report-${unit}" ]] && exit 5
  [[ -e "${MARKS}/no-markdown-${unit}" && "${format}" == markdown ]] && exit 0
  echo "report <${format}> of ${unit}" > "${dir}/record-report.${extension}"
  echo "report written for ${unit}"
  [[ ! -e "${MARKS}/exit-report-${unit}" ]] || exit "$(cat "${MARKS}/exit-report-${unit}")"
  exit 0
fi
if [[ "$1 $2" == "record verify" ]]; then
  unit="$(basename "$(dirname "$3")")"
  [[ ! -e "${MARKS}/exit-verify-${unit}" ]] || exit "$(cat "${MARKS}/exit-verify-${unit}")"
  exit 0
fi
STUB
  chmod +x "${TOOLS}/venv/bin/iltero"

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/compute"
  cd "${STACK}" || return
  # The name the actions give this stack's work folder.
  STACK_FOLDER="$(stack_folder_name)"
}

@test "check refuses pull_request_target and workflow_run events, and needs setup" {
  GITHUB_EVENT_NAME=pull_request_target run "${VERIFY}" check
  [ "${status}" -eq 1 ]
  GITHUB_EVENT_NAME=workflow_run run "${VERIFY}" check
  [ "${status}" -eq 1 ]
  run "${VERIFY}" check
  [ "${status}" -eq 0 ]
  rm "${TOOLS}/venv/bin/iltero"
  run "${VERIFY}" check
  [ "${status}" -eq 1 ]
}

@test "each unit's record is built, then its bundle verified, in the CLI's order" {
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^iltero record (build|verify) [^ ]+' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "iltero record build --out=${OUT},iltero record verify ${OUT}/units/network/car-0001/,iltero record build --out=${OUT},iltero record verify ${OUT}/units/compute/car-0001/," ]
  grep -q "iltero record build --out=${OUT} --unit=network ILTERO_OPA_PATH=${TOOLS}/bin/opa" "${STUB_LOG}"
}

@test "an empty records directory is refused" {
  run "${VERIFY}" run ""
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory is empty. Pass the records-directory output of the deploy or record-iac action."* ]]
  ! grep -q "^bundles-path=" "${GITHUB_OUTPUT}" || false
  ! grep -q "record build" "${STUB_LOG}" || false
}

@test "a missing relative records directory is named as given" {
  run "${VERIFY}" run "nowhere"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The records directory 'nowhere' does not exist."* ]]
  ! grep -q "^bundles-path=" "${GITHUB_OUTPUT}" || false
  ! grep -q "record build" "${STUB_LOG}" || false
}

@test "a missing records directory is refused" {
  run "${VERIFY}" run "${BATS_TEST_TMPDIR}/nowhere"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not exist"* ]]
}

@test "the step fails with the first failing unit's exit code" {
  echo 4 > "${MARKS}/exit-build-network"
  echo 9 > "${MARKS}/exit-verify-compute"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 4 ]
}

@test "a stack with no unit stops the step" {
  echo '[]' > "${UNITS_JSON}"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The CLI lists no units in this stack, so there is nothing to check."* ]]
}

@test "the bundles artifact is named after the environment unless a name is given" {
  run "${VERIFY}" run "${OUT}"
  [ "$(output_value artifact-name)" = "iltero-record-bundles-production-attempt-1" ]
  : > "${GITHUB_OUTPUT}"
  ARTIFACT_NAME=network-bundles run "${VERIFY}" run "${OUT}"
  [ "$(output_value artifact-name)" = "network-bundles-attempt-1" ]
}

@test "the summary names the environment" {
  run "${VERIFY}" run "${OUT}"
  grep -q "^## Iltero record bundles: production$" "${GITHUB_STEP_SUMMARY}"
}

@test "an environment with a space is refused before anything runs" {
  ENVIRONMENT="prod env" run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot name a directory or a file. Use only letters, digits"* ]]
}

@test "an environment that cannot name a directory or a file is refused before anything is written" {
  local name
  for name in .. . a/b ../x; do
    : > "${GITHUB_OUTPUT}"
    ENVIRONMENT="${name}" run "${VERIFY}" run "${OUT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot name a directory or a file"* ]]
    [ ! -s "${GITHUB_OUTPUT}" ]
  done
  ! grep -q "record build" "${STUB_LOG}" || false
}

@test "verify needs the environment" {
  ENVIRONMENT="" run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input is required."* ]]
  ! grep -q "record build" "${STUB_LOG}" || false
}

@test "check refuses an artifact name that is not a valid name" {
  ARTIFACT_NAME="records/../x" run "${VERIFY}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name 'records/../x'."* ]]
}

@test "a relative records directory is given to the upload as an absolute path" {
  mkdir -p records
  run "${VERIFY}" run records
  [ "$(output_value bundles-path)" = "${STACK}/records/units/*/car-*/" ]
}

@test "the bundles are uploaded from the path the step checked, and only when it ran" {
  grep -qF "if: always() && steps.verify.outputs.bundles-path != ''" "${REPO_ROOT}/verify/action.yml"
  # The action's own text is matched as written.
  # shellcheck disable=SC2016
  grep -qF 'path: ${{ steps.verify.outputs.bundles-path }}' "${REPO_ROOT}/verify/action.yml"
}

@test "each unit starts with an empty work directory" {
  mkdir -p "${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}/units/network"
  echo "old output" > "${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}/units/network/verify.txt"
  touch "${MARKS}/no-bundle-network"
  run "${VERIFY}" run "${OUT}"
  ! grep -q "old output" "${GITHUB_STEP_SUMMARY}" || false
}

@test "a failed build is reported, the other units are still checked, and the step fails" {
  echo 1 > "${MARKS}/exit-build-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "| network | build failed | not run |" "${GITHUB_STEP_SUMMARY}"
  grep -q "| compute | built | verified |" "${GITHUB_STEP_SUMMARY}"
}

@test "a verification that could not run says so, and fails with the CLI's code" {
  echo 2 > "${MARKS}/exit-verify-compute"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 2 ]
  grep -q "| compute | built | could not verify |" "${GITHUB_STEP_SUMMARY}"
}

@test "a record that does not verify fails the step with the CLI's code" {
  echo 9 > "${MARKS}/exit-verify-compute"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 9 ]
  grep -q "| compute | built | does not verify |" "${GITHUB_STEP_SUMMARY}"
}

@test "more than one bundle for a unit is refused" {
  mkdir -p "${OUT}/units/network/car-0000"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "| network | built | 2 bundles found, expected 1 |" "${GITHUB_STEP_SUMMARY}"
}

@test "a build that writes no bundle is refused and counted as none" {
  touch "${MARKS}/no-bundle-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Expected one record bundle for unit 'network', found 0."* ]]
  grep -q "| network | built | bundle not found |" "${GITHUB_STEP_SUMMARY}"
}

@test "a line of the CLI's output cannot act as a workflow command" {
  run "${VERIFY}" run "${OUT}"
  commands_paused_around "built <network>"
}

@test "the summary shows the CLI's output with HTML escaped" {
  run "${VERIFY}" run "${OUT}"
  grep -q "built &lt;network&gt;" "${GITHUB_STEP_SUMMARY}"
}

# --- report ------------------------------------------------------------------

@test "each unit's bundle gets a report, as an HTML page for the artifact and in the summary" {
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  local reports="${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}/reports"
  grep -qx "report-directory=${reports}" "${GITHUB_OUTPUT}"
  grep -q "^iltero record report ${OUT}/units/network/car-0001/ --format=html --out=${reports}/network " "${STUB_LOG}"
  grep -q "^iltero record report ${OUT}/units/compute/car-0001/ --format=markdown --out=${reports}/compute " "${STUB_LOG}"
  [ -f "${reports}/network/record-report.html" ]
  grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -qx "report <markdown> of compute" "${GITHUB_STEP_SUMMARY}"
  commands_paused_around "report written for network"
}

@test "a bundle that fails verification still gets a report" {
  echo 9 > "${MARKS}/exit-verify-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 9 ]
  grep -q "^iltero record report ${OUT}/units/network/car-0001/ --format=html" "${STUB_LOG}"
}

@test "with report false, verify writes no report" {
  WRITE_REPORT=false run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  ! grep -q "record report" "${STUB_LOG}" || false
  ! grep -q "^report-directory=" "${GITHUB_OUTPUT}" || false
}

@test "verify refuses a report value other than true or false" {
  WRITE_REPORT="" run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The write-report input must be true or false, not ''."* ]]
  ! grep -q "record build" "${STUB_LOG}" || false
}

@test "a report that exits with another code than 0 is a warning, and verify keeps its result" {
  echo 9 > "${MARKS}/exit-report-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::The CLI reported a problem while it wrote the report of unit 'network'. See its output in the log."* ]]
}

@test "a report the CLI does not write fails the step, and the other units are still checked" {
  touch "${MARKS}/no-report-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::The CLI wrote no record-report.html for unit 'network'."* ]]
  [[ "${output}" == *"One or more records failed to build, verify or report."* ]]
  grep -q "record verify ${OUT}/units/compute" "${STUB_LOG}"
}

@test "a report without its Markdown file fails the step" {
  touch "${MARKS}/no-markdown-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::The CLI wrote no record-report.md for unit 'network'."* ]]
}

@test "a unit whose record did not build gets no report" {
  echo 1 > "${MARKS}/exit-build-network"
  run "${VERIFY}" run "${OUT}"
  ! grep -q "record report ${OUT}/units/network" "${STUB_LOG}" || false
  grep -q "record report ${OUT}/units/compute" "${STUB_LOG}"
}

@test "a unit directory that starts with a dash is refused" {
  echo '[{"name": "network", "working_directory": "-L"}]' > "${UNITS_JSON}"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Unit 'network' has a directory that starts with '-': '-L'. Rename the directory."* ]]
}

@test "a records directory that looks like an option is a directory in the project" {
  local project="${BATS_TEST_TMPDIR}/project" name
  mkdir -p "${project}/units/network" "${project}/units/compute"
  cd "${project}" || return
  for name in -- - -e; do
    mkdir -p "./${name}"
    : > "${GITHUB_OUTPUT}"
    OLDPWD="${OUT}" run "${VERIFY}" run "${name}"
    [ "${status}" -eq 0 ]
    grep -qxF -- "bundles-path=${project}/${name}/units/*/car-*/" "${GITHUB_OUTPUT}"
  done
}

@test "with a unit, only that unit's record is built and verified" {
  UNIT=compute run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  run bash -c "grep -oE '^iltero record (build|verify) [^ ]+ [^ ]+' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "iltero record build --out=${OUT} --unit=compute,iltero record verify ${OUT}/units/compute/car-0001/ ILTERO_OPA_PATH=${TOOLS}/bin/opa," ]
  grep -q "^| compute | built | verified |$" "${GITHUB_STEP_SUMMARY}"
  ! grep -q "^| network |" "${GITHUB_STEP_SUMMARY}" || false
}

@test "with a unit, the bundles artifact is named after the environment and the unit" {
  UNIT=network run "${VERIFY}" run "${OUT}"
  [ "$(output_value artifact-name)" = "iltero-record-bundles-production-network-attempt-1" ]
  : > "${GITHUB_OUTPUT}"
  UNIT=network ARTIFACT_NAME=network-bundles run "${VERIFY}" run "${OUT}"
  [ "$(output_value artifact-name)" = "network-bundles-attempt-1" ]
}

@test "a unit the stack does not list is refused before anything is built" {
  UNIT=storage run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The stack has no unit 'storage'. Use a name that 'iltero units list' prints."* ]]
  ! grep -q "record build" "${STUB_LOG}" || false
  # No output, so no upload step runs.
  [ ! -s "${GITHUB_OUTPUT}" ]
}

@test "with a unit, the upload takes only that unit's bundles" {
  UNIT=compute run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  [ "$(output_value bundles-path)" = "${OUT}/units/compute/car-*/" ]
}

@test "with a unit, each unit has its own reports directory" {
  UNIT=network run "${VERIFY}" run "${OUT}"
  local network_reports
  network_reports="$(output_value report-directory)"
  : > "${GITHUB_OUTPUT}"
  UNIT=compute run "${VERIFY}" run "${OUT}"
  [ "$(output_value report-directory)" != "${network_reports}" ]
  [ "$(output_value report-directory)" != "${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}/reports" ]
  [ ! -e "$(output_value report-directory)/network" ]
  [ -n "$(ls "${network_reports}")" ]
}

@test "a unit name that cannot name a directory is refused before anything is written" {
  UNIT="../network" run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The unit name '../network' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."* ]]
  ! grep -q "^bundles-path=" "${GITHUB_OUTPUT}" || false
  ! grep -q "units list" "${STUB_LOG}" || false
}

@test "a verify starts from an empty work folder, so no earlier report is taken for one this step wrote" {
  local root="${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}"
  mkdir -p "${root}/reports/retired"
  echo "old report" > "${root}/reports/retired/record-report.md"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  [ ! -e "${root}/reports/retired" ]
}

@test "each stack has its own verify work folder, so two stacks in one job keep their reports apart" {
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  local first
  first="$(output_value report-directory)"
  [ "${first}" = "${RUNNER_TEMP}/iltero-verify/production/${STACK_FOLDER}/reports" ]
  [ -n "$(ls "${first}")" ]
  cp -R "${STACK}" "${BATS_TEST_TMPDIR}/second-stack"
  cd "${BATS_TEST_TMPDIR}/second-stack"
  local second
  second="$(stack_folder_name)"
  [ "${second}" != "${STACK_FOLDER}" ]
  : > "${GITHUB_OUTPUT}"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  [ "$(output_value report-directory)" = "${RUNNER_TEMP}/iltero-verify/production/${second}/reports" ]
  [ -n "$(ls "${first}")" ]
}
