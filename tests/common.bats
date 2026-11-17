#!/usr/bin/env bats
#
# Tests for the shared helpers in scripts/lib/common.sh.

load test_helper

setup() {
  make_runner
  source "${REPO_ROOT}/scripts/lib/common.sh"
}

@test "a stack's work folder name is the same each time it is made in the same folder" {
  mkdir -p "${BATS_TEST_TMPDIR}/stack"
  cd "${BATS_TEST_TMPDIR}/stack"
  local first second
  first="$(stack_work_folder_name)"
  second="$(stack_work_folder_name)"
  [ "${first}" = "${second}" ]
  [[ "${first}" =~ ^stack-[0-9a-f]{12}$ ]]
}

@test "two stacks in different folders get different work folder names" {
  mkdir -p "${BATS_TEST_TMPDIR}/one" "${BATS_TEST_TMPDIR}/two"
  local one two
  one="$(cd "${BATS_TEST_TMPDIR}/one" && stack_work_folder_name)"
  two="$(cd "${BATS_TEST_TMPDIR}/two" && stack_work_folder_name)"
  [ "${one}" != "${two}" ]
}

@test "the runner's temporary folder must be set" {
  RUNNER_TEMP="" run runner_temp
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"RUNNER_TEMP is not set. Run this action inside a GitHub Actions job."* ]]
}
