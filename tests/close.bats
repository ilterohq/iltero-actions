#!/usr/bin/env bats
#
# Tests for scripts/close.sh, the body of the `close` action.

# The tests match the action's expressions as written.
# shellcheck disable=SC2016

load test_helper

setup() {
  make_runner
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export CLI_EXIT=0
  RUN="${REPO_ROOT}/scripts/close.sh"
  # A stand-in for the CLI that setup installs. It records its arguments.
  mkdir -p "${RUNNER_TEMP}/iltero-tools/venv/bin"
  ln -s "$(command -v python3)" "${RUNNER_TEMP}/iltero-tools/venv/bin/python"
  cat > "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero" << 'EOF'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
exit "${CLI_EXIT}"
EOF
  chmod +x "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero"
}

# --- check -------------------------------------------------------------------

@test "check refuses pull_request_target and workflow_run events" {
  GITHUB_EVENT_NAME=pull_request_target run "${RUN}" check
  [ "${status}" -eq 1 ]
  GITHUB_EVENT_NAME=workflow_run run "${RUN}" check
  [ "${status}" -eq 1 ]
}

@test "check refuses pull request events" {
  GITHUB_EVENT_NAME=pull_request run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Use the preview action instead"* ]]
}

@test "check requires the job to grant id-token: write" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id-token: write"* ]]
}

@test "check requires the CLI that setup installs" {
  rm "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero"
  run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Run the setup action first"* ]]
}

@test "check accepts push, workflow_dispatch and schedule events" {
  local event
  for event in push workflow_dispatch schedule; do
    GITHUB_EVENT_NAME="${event}" run "${RUN}" check
    [ "${status}" -eq 0 ]
  done
}

# --- close -------------------------------------------------------------------

@test "close closes the pipeline run's change run for the environment" {
  ENVIRONMENT=production run "${RUN}" close
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --environment=production" "${STUB_LOG}"
}

@test "close closes the pipeline run's build run for the application" {
  APPLICATION=api run "${RUN}" close
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --application=api" "${STUB_LOG}"
}

@test "close passes a value starting with a dash as a value, not an option" {
  ENVIRONMENT="--help" run "${RUN}" close
  grep -qx "iltero run close --environment=--help" "${STUB_LOG}"
}

@test "close fails with the CLI's exit code" {
  CLI_EXIT=9 ENVIRONMENT=production run "${RUN}" close
  [ "${status}" -eq 9 ]
}

@test "close closes the pipeline run's image deploy run for the application and the environment" {
  ENVIRONMENT=production APPLICATION=api run "${RUN}" close
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --application=api --environment=production" "${STUB_LOG}"
}

@test "close requires the environment, the application or both" {
  run "${RUN}" close
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Give the environment input, the application input, or both."* ]]
  ENVIRONMENT=" " APPLICATION=" " run "${RUN}" close
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Give the environment input, the application input, or both."* ]]
  ! grep -q "^iltero" "${STUB_LOG}" || false
}

@test "close refuses an environment or application of more than one line" {
  ENVIRONMENT=$'production\nx' run "${RUN}" close
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The environment input must be one line, with no tab or other control character."* ]]
  APPLICATION=$'api\nx' run "${RUN}" close
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The application input must be one line, with no tab or other control character."* ]]
  ! grep -q "^iltero" "${STUB_LOG}" || false
}

@test "close treats an input of only spaces as empty" {
  ENVIRONMENT=" " APPLICATION=api run "${RUN}" close
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --application=api" "${STUB_LOG}"
}

@test "the close action passes the environment and application to the script" {
  grep -qx '        ENVIRONMENT: ${{ inputs.environment }}' "${REPO_ROOT}/close/action.yml"
  grep -qx '        APPLICATION: ${{ inputs.application }}' "${REPO_ROOT}/close/action.yml"
}

@test "close takes no arguments" {
  ENVIRONMENT=production run "${RUN}" close production
  [ "${status}" -eq 1 ]
}

@test "the close action closes the run from the stack's working directory" {
  run awk '/- name: Close the run/ { inside = 1; next } inside && /working-directory:/ { sub(/^ +/, ""); print; exit }' \
    "${REPO_ROOT}/close/action.yml"
  [ "${output}" = 'working-directory: ${{ inputs.working-directory }}' ]
}
