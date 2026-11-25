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

@test "the operator trust file the input names reaches the CLI as an absolute path" {
  mkdir -p "${BATS_TEST_TMPDIR}/project/trust"
  echo '{}' > "${BATS_TEST_TMPDIR}/project/trust/operator.json"
  cd "${BATS_TEST_TMPDIR}/project"
  OPERATOR_TRUST_FILE=trust/operator.json run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; set_operator_trust_file; echo "${ILTERO_OPERATOR_TRUST_FILE}"' _ "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(pwd -P)/trust/operator.json" ]
}

@test "with no operator-trust-file input, the CLI gets no operator trust file, even one the job set some other way" {
  ILTERO_OPERATOR_TRUST_FILE=/elsewhere/operator.json OPERATOR_TRUST_FILE="" run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; set_operator_trust_file; echo "set=${ILTERO_OPERATOR_TRUST_FILE+yes}"' _ "${REPO_ROOT}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "set=" ]
}

@test "an operator-trust-file input that names no file, or holds a control character, is refused" {
  OPERATOR_TRUST_FILE="${BATS_TEST_TMPDIR}/missing.json" run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; set_operator_trust_file' _ "${REPO_ROOT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The operator-trust-file input names no file: '${BATS_TEST_TMPDIR}/missing.json'."* ]]
  OPERATOR_TRUST_FILE=$'a\nb' run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; set_operator_trust_file' _ "${REPO_ROOT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The operator-trust-file input must be one line"* ]]
}

@test "an operator trust file in a folder named like an option, or with CDPATH set, resolves to that file alone" {
  mkdir -p "${BATS_TEST_TMPDIR}/project/-" "${BATS_TEST_TMPDIR}/elsewhere/-"
  echo '{}' > "${BATS_TEST_TMPDIR}/project/-/operator.json"
  cd "${BATS_TEST_TMPDIR}/project"
  CDPATH="${BATS_TEST_TMPDIR}/elsewhere" OPERATOR_TRUST_FILE=-/operator.json run bash -c 'cd "$2" && cd "$3"; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/cli-stages.sh"; set_operator_trust_file; echo "${ILTERO_OPERATOR_TRUST_FILE}"' _ "${REPO_ROOT}" "${BATS_TEST_TMPDIR}/elsewhere" "${BATS_TEST_TMPDIR}/project"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(pwd -P)/-/operator.json" ]
}
