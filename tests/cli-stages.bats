#!/usr/bin/env bats
#
# Tests for scripts/lib/cli-stages.sh, the helpers that run the Iltero CLI.

load test_helper

@test "running the CLI stops with its own error when the CLI is not installed" {
  export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner"
  mkdir -p "${RUNNER_TEMP}"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; run_cli_logged "$2" record in-scope x' _ "${REPO_ROOT}" "${BATS_TEST_TMPDIR}/answer.txt"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The Iltero CLI is not installed. Run the setup action first in this job."* ]]
  [[ "${output}" != *"command not found"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/answer.txt" ]
}
