#!/usr/bin/env bats
#
# Tests for scripts/verify.sh, the body of the `verify` action.

load test_helper

setup() {
  make_runner
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  : > "${GITHUB_STEP_SUMMARY}"
  VERIFY="${REPO_ROOT}/scripts/verify.sh"
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  export MARKS="${BATS_TEST_TMPDIR}/marks"
  export OUT="${BATS_TEST_TMPDIR}/out"
  export REPORT="true"
  mkdir -p "${TOOLS}/venv/bin" "${MARKS}" "${OUT}"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"

  # A stand-in for the CLI. `car build` makes the unit's bundle unless
  # MARKS/exit-build-<unit> gives its exit code or MARKS/no-bundle-<unit>
  # exists; `car verify` exits with
  # MARKS/exit-verify-<unit> or 0; `car report` writes car-report.<format>
  # into --out and exits with MARKS/exit-report-<unit> or 0, or exits 5
  # without writing when MARKS/no-report-<unit> exists.
  cat > "${TOOLS}/venv/bin/iltero" << 'STUB'
#!/bin/bash
echo "iltero $* ILTERO_OPA_PATH=${ILTERO_OPA_PATH}" >> "${STUB_LOG}"
if [[ "$1 $2" == "units list" ]]; then
  echo '[{"name": "network", "working_directory": "units/network"}, {"name": "compute", "working_directory": "units/compute"}]'
  exit 0
fi
if [[ "$1 $2" == "car build" ]]; then
  unit="${4#--unit=}"
  [[ ! -e "${MARKS}/exit-build-${unit}" ]] || exit "$(cat "${MARKS}/exit-build-${unit}")"
  [[ -e "${MARKS}/no-bundle-${unit}" ]] || mkdir -p "${OUT}/units/${unit}/car-0001"
  echo "built <${unit}>"
  exit 0
fi
if [[ "$1 $2" == "car report" ]]; then
  unit="$(basename "$(dirname "$3")")" format="${4#--format=}" dir="${5#--out=}"
  [[ "${format}" == markdown ]] && extension=md || extension="${format}"
  [[ -e "${MARKS}/no-report-${unit}" ]] && exit 5
  echo "report <${format}> of ${unit}" > "${dir}/car-report.${extension}"
  echo "report written for ${unit}"
  [[ ! -e "${MARKS}/exit-report-${unit}" ]] || exit "$(cat "${MARKS}/exit-report-${unit}")"
  exit 0
fi
if [[ "$1 $2" == "car verify" ]]; then
  unit="$(basename "$(dirname "$3")")"
  [[ ! -e "${MARKS}/exit-verify-${unit}" ]] || exit "$(cat "${MARKS}/exit-verify-${unit}")"
  exit 0
fi
STUB
  chmod +x "${TOOLS}/venv/bin/iltero"

  STACK="${BATS_TEST_TMPDIR}/stack"
  mkdir -p "${STACK}/units/network" "${STACK}/units/compute"
  cd "${STACK}"
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
  run bash -c "grep -oE '^iltero car (build|verify) [^ ]+' '${STUB_LOG}' | tr '\n' ','"
  [ "${output}" = "iltero car build --out=${OUT},iltero car verify ${OUT}/units/network/car-0001/,iltero car build --out=${OUT},iltero car verify ${OUT}/units/compute/car-0001/," ]
  grep -q "iltero car build --out=${OUT} --unit=network ILTERO_OPA_PATH=${TOOLS}/bin/opa" "${STUB_LOG}"
}

@test "a missing records directory is refused" {
  run "${VERIFY}" run "${BATS_TEST_TMPDIR}/nowhere"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not exist"* ]]
}

@test "a failed build is reported, the other units are still checked, and the step fails" {
  echo 1 > "${MARKS}/exit-build-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "| network | exit 1 | - |" "${GITHUB_STEP_SUMMARY}"
  grep -q "| compute | exit 0 | exit 0 |" "${GITHUB_STEP_SUMMARY}"
}

@test "a failed verification fails the step with the CLI's code in the summary" {
  echo 9 > "${MARKS}/exit-verify-compute"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "| compute | exit 0 | exit 9 |" "${GITHUB_STEP_SUMMARY}"
}

@test "more than one bundle for a unit is refused" {
  mkdir -p "${OUT}/units/network/car-0000"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "| network | exit 0 | no bundle |" "${GITHUB_STEP_SUMMARY}"
}

@test "a build that writes no bundle is refused and counted as none" {
  touch "${MARKS}/no-bundle-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Expected one record bundle for unit 'network', found 0."* ]]
  grep -q "| network | exit 0 | no bundle |" "${GITHUB_STEP_SUMMARY}"
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
  local reports="${RUNNER_TEMP}/iltero-verify/reports"
  grep -qx "report-dir=${reports}" "${GITHUB_OUTPUT}"
  grep -q "^iltero car report ${OUT}/units/network/car-0001/ --format=html --out=${reports}/network " "${STUB_LOG}"
  grep -q "^iltero car report ${OUT}/units/compute/car-0001/ --format=markdown --out=${reports}/compute " "${STUB_LOG}"
  [ -f "${reports}/network/car-report.html" ]
  grep -q "<summary>network: report</summary>" "${GITHUB_STEP_SUMMARY}"
  grep -qx "report <markdown> of compute" "${GITHUB_STEP_SUMMARY}"
  commands_paused_around "report written for network"
}

@test "a bundle that fails verification still gets a report" {
  echo 9 > "${MARKS}/exit-verify-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  grep -q "^iltero car report ${OUT}/units/network/car-0001/ --format=html" "${STUB_LOG}"
}

@test "with report false, verify writes no report" {
  REPORT=false run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  ! grep -q "car report" "${STUB_LOG}"
  ! grep -q "^report-dir=" "${GITHUB_OUTPUT}"
}

@test "verify refuses a report value other than true or false" {
  REPORT="" run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The report input must be true or false, not ''."* ]]
  ! grep -q "car build" "${STUB_LOG}"
}

@test "a report that exits with another code than 0 is a warning, and verify keeps its result" {
  echo 9 > "${MARKS}/exit-report-network"
  run "${VERIFY}" run "${OUT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::The CLI's report of unit 'network' exited with 9. See its output in the log."* ]]
}

@test "a unit whose record did not build gets no report" {
  echo 1 > "${MARKS}/exit-build-network"
  run "${VERIFY}" run "${OUT}"
  ! grep -q "car report ${OUT}/units/network" "${STUB_LOG}"
  grep -q "car report ${OUT}/units/compute" "${STUB_LOG}"
}
